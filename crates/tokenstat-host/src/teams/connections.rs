// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One serialized encrypted connection per exact account and shared resource.
//! This pool never borrows a personal session or accepts an arbitrary RPC.

use super::api_error;
use crate::{
    account_session::AccountSnapshot,
    error::DispatchError,
    remote::{TeamConnection, TeamReadMethod, TeamReadParams},
};
use serde::Deserialize;
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex, OnceLock, Weak,
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
    time::{Duration, Instant},
};
use tokenstat_identity::PublicKey;
use tokenstat_sync::teams::{RequestTicket, TeamCapability, TeamClient, TeamError};

const MAX_CONNECTIONS: usize = 16;
const MAX_QUEUED: usize = 8;
const CALL_BUDGET: Duration = Duration::from_secs(120);
const IDLE: Duration = Duration::from_secs(30);
const RENEW: Duration = Duration::from_secs(20);

#[derive(Clone, Debug, Deserialize, Hash, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(super) struct Target {
    organization: String,
    repository: String,
    checkout: String,
    #[serde(default)]
    share: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Request {
    target: Target,
    method: TeamReadMethod,
    #[serde(default)]
    params: TeamReadParams,
}
impl Request {
    pub(super) fn validate(self) -> Result<Self, DispatchError> {
        if [
            &self.target.organization,
            &self.target.repository,
            &self.target.checkout,
        ]
        .into_iter()
        .chain(self.target.share.iter())
        .any(|id| {
            id.is_empty()
                || id.len() > 128
                || !id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }) {
            return Err(api_error(TeamError::InvalidRequest));
        }
        if !self
            .params
            .validate(self.method, self.target.share.as_deref())
        {
            return Err(api_error(TeamError::InvalidRequest));
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct Key {
    owner: String,
    issuer: String,
    device: PublicKey,
    target: Target,
}
trait Transport: Send {
    fn call(
        &mut self,
        method: TeamReadMethod,
        params: &TeamReadParams,
    ) -> Result<Value, DispatchError>;
    fn renew(&mut self) -> Result<(), DispatchError>;
    fn ensure_current(&self) -> Result<(), DispatchError>;
}
impl Transport for TeamConnection {
    fn call(
        &mut self,
        method: TeamReadMethod,
        params: &TeamReadParams,
    ) -> Result<Value, DispatchError> {
        self.call(method, params)
    }
    fn renew(&mut self) -> Result<(), DispatchError> {
        self.renew()
    }
    fn ensure_current(&self) -> Result<(), DispatchError> {
        self.ensure_current()
    }
}
type Connector = Box<dyn FnOnce() -> Result<Box<dyn Transport>, DispatchError> + Send>;
struct Job {
    method: TeamReadMethod,
    params: TeamReadParams,
    deadline: Instant,
    reply: SyncSender<Result<Value, DispatchError>>,
}
#[derive(Clone)]
struct Slot {
    sender: SyncSender<Job>,
    lifetime: Arc<()>,
}
#[derive(Default)]
struct Pool {
    slots: Mutex<HashMap<Key, Slot>>,
}

fn busy() -> DispatchError {
    DispatchError::new(
        "teams_busy",
        "Too many Team requests are waiting. Try again shortly.",
    )
}
fn ended() -> DispatchError {
    DispatchError::new(
        "team_connection_unavailable",
        "This shared checkout could not be reached. Refresh and try again.",
    )
}
struct Retirement {
    pool: Weak<Pool>,
    key: Key,
    lifetime: Arc<()>,
}
impl Drop for Retirement {
    fn drop(&mut self) {
        if let Some(pool) = self.pool.upgrade()
            && let Ok(mut slots) = pool.slots.lock()
            && slots
                .get(&self.key)
                .is_some_and(|slot| Arc::ptr_eq(&slot.lifetime, &self.lifetime))
        {
            slots.remove(&self.key);
        }
    }
}
impl Pool {
    fn enqueue(
        self: &Arc<Self>,
        key: Key,
        connector: Connector,
        job: Job,
    ) -> Result<(), DispatchError> {
        let mut slots = self.slots.lock().map_err(|_| ended())?;
        if let Some(slot) = slots.get(&key) {
            return match slot.sender.try_send(job) {
                Ok(()) => Ok(()),
                Err(TrySendError::Full(_)) => Err(busy()),
                // A worker that is retiring cannot accept another call. Its
                // non-reused lifetime prevents it removing a replacement.
                Err(TrySendError::Disconnected(job)) => {
                    slots.remove(&key);
                    self.start(&mut slots, key, connector, job)
                }
            };
        }
        self.start(&mut slots, key, connector, job)
    }

    fn start(
        self: &Arc<Self>,
        slots: &mut HashMap<Key, Slot>,
        key: Key,
        connector: Connector,
        job: Job,
    ) -> Result<(), DispatchError> {
        if slots.len() >= MAX_CONNECTIONS {
            return Err(busy());
        }
        let (sender, receiver) = mpsc::sync_channel(MAX_QUEUED);
        sender.try_send(job).map_err(|_| ended())?;
        let lifetime = Arc::new(());
        let pool = Arc::downgrade(self);
        let worker_key = key.clone();
        let worker_lifetime = lifetime.clone();
        // Reserve before starting. The worker owns network I/O; the caller
        // never waits for a socket, account request, or join under this lock.
        slots.insert(key.clone(), Slot { sender, lifetime });
        if std::thread::Builder::new()
            .name("team-connection".into())
            .spawn(move || {
                let _retirement = Retirement {
                    pool,
                    key: worker_key,
                    lifetime: worker_lifetime,
                };
                work(receiver, connector);
            })
            .is_err()
        {
            slots.remove(&key);
            return Err(ended());
        }
        Ok(())
    }

    fn call(
        self: &Arc<Self>,
        key: Key,
        connector: Connector,
        method: TeamReadMethod,
        params: TeamReadParams,
    ) -> Result<Value, DispatchError> {
        let deadline = Instant::now() + CALL_BUDGET;
        let (reply, receive) = mpsc::sync_channel(1);
        self.enqueue(
            key,
            connector,
            Job {
                method,
                params,
                deadline,
                reply,
            },
        )?;
        receive
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .map_err(|_| ended())?
    }
}

fn work(receiver: Receiver<Job>, connector: Connector) {
    let Ok(first) = receiver.recv() else {
        return;
    };
    if Instant::now() >= first.deadline {
        let _ = first.reply.send(Err(ended()));
        return;
    }
    let mut connection = match connector() {
        Ok(connection) => connection,
        Err(error) => {
            let _ = first.reply.send(Err(error));
            return;
        }
    };
    let mut next = Some(first);
    let mut last_use = Instant::now();
    let mut renewal = last_use + RENEW;
    loop {
        if connection.ensure_current().is_err() {
            break;
        }
        let now = Instant::now();
        if now >= last_use + IDLE {
            break;
        }
        if now >= renewal {
            if connection.renew().is_err() {
                break;
            }
            renewal = Instant::now() + RENEW;
        }
        let job = match next.take() {
            Some(job) => job,
            None => match receiver.recv_timeout(
                renewal
                    .min(last_use + IDLE)
                    .saturating_duration_since(Instant::now()),
            ) {
                Ok(job) => job,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
        };
        if Instant::now() >= job.deadline {
            let _ = job.reply.send(Err(ended()));
            continue;
        }
        let result = connection.call(job.method, &job.params);
        let failed = result.is_err();
        let _ = job.reply.send(result);
        last_use = Instant::now();
        if failed {
            break;
        }
    }
    // A failed connection has no transparent replay, including for requests
    // accepted before retirement. A caller can explicitly refresh a read.
    for job in receiver.try_iter() {
        let _ = job.reply.send(Err(ended()));
    }
}

pub(super) fn perform(
    owner: &AccountSnapshot,
    client: TeamClient,
    request: Request,
) -> Result<Value, DispatchError> {
    let request = request.validate()?;
    owner
        .ensure_current()
        .map_err(|_| api_error(TeamError::AccountChanged))?;
    let identity = tokenstat_identity::MachineIdentity::load()
        .map_err(|_| ended())?
        .ok_or_else(ended)?;
    let device = identity.public_key();
    let key = Key {
        owner: owner.id.clone(),
        issuer: client.origin().into(),
        device,
        target: request.target.clone(),
    };
    let owner = owner.clone();
    let target = request.target;
    let ticket = RequestTicket {
        organization_id: target.organization,
        checkout_id: target.checkout,
        capabilities: vec![TeamCapability::Read],
        share_id: target.share,
    };
    let connector: Connector = Box::new(move || {
        Ok(Box::new(TeamConnection::connect(
            owner,
            Arc::new(client),
            ticket,
            target.repository,
            device,
        )?))
    });
    static POOL: OnceLock<Arc<Pool>> = OnceLock::new();
    POOL.get_or_init(|| Arc::new(Pool::default())).call(
        key,
        connector,
        request.method,
        request.params,
    )
}

#[cfg(test)]
mod tests;
