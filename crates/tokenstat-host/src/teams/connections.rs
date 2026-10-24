// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One serialized encrypted connection per exact account and shared resource.
//! This pool never borrows a personal session or accepts an arbitrary RPC.

use super::api_error;
use crate::{
    account_session::AccountSnapshot,
    error::DispatchError,
    remote::{TeamAskMethod, TeamCommentInput, TeamConnection, TeamReadMethod, TeamReadParams},
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CommentRequest {
    target: Target,
    input: TeamCommentInput,
}
impl CommentRequest {
    pub(super) fn validate(self) -> Result<Self, DispatchError> {
        Request {
            target: self.target.clone(),
            method: TeamReadMethod::ChatDetails,
            params: TeamReadParams::default(),
        }
        .validate()?;
        self.input.validate()?;
        Ok(self)
    }
}

/// Writes use a fresh exact Comment proof and one request. They cannot enter
/// the read pool, inherit its retry policy or borrow a personal connection.
pub(super) fn comment(
    owner: &AccountSnapshot,
    client: TeamClient,
    request: CommentRequest,
) -> Result<Value, DispatchError> {
    let request = request.validate()?;
    owner
        .ensure_current()
        .map_err(|_| api_error(TeamError::AccountChanged))?;
    let identity = tokenstat_identity::MachineIdentity::load()
        .map_err(|_| ended())?
        .ok_or_else(ended)?;
    let ticket = RequestTicket {
        organization_id: request.target.organization,
        checkout_id: request.target.checkout,
        capabilities: vec![TeamCapability::Read, TeamCapability::Comment],
        share_id: request.target.share,
    };
    TeamConnection::connect_comment(
        owner.clone(),
        Arc::new(client),
        ticket,
        request.target.repository,
        identity.public_key(),
    )?
    .comment(&request.input)
}

/// Review, send or stop an Ask on a shared chat. `params` is checked again
/// by the publishing computer, which owns the run.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AskRequest {
    target: Target,
    method: TeamAskMethod,
    #[serde(default)]
    params: Value,
}
impl AskRequest {
    pub(super) fn validate(mut self) -> Result<Self, DispatchError> {
        // A new chat is asked of the checkout. Everything else names a share.
        let new = self.method == TeamAskMethod::New;
        if self.target.share.is_none() != new {
            return Err(api_error(TeamError::InvalidRequest));
        }
        Request {
            target: self.target.clone(),
            method: if new {
                TeamReadMethod::ChatCatalog
            } else {
                TeamReadMethod::ChatDetails
            },
            params: TeamReadParams::default(),
        }
        .validate()?;
        if self.params.is_null() {
            self.params = Value::Object(Default::default());
        }
        if !self.params.is_object() {
            return Err(api_error(TeamError::InvalidRequest));
        }
        Ok(self)
    }
}

/// An Ask uses its own Run proof and one request, outside the read pool.
pub(super) fn ask(
    owner: &AccountSnapshot,
    client: TeamClient,
    request: AskRequest,
) -> Result<Value, DispatchError> {
    let request = request.validate()?;
    owner
        .ensure_current()
        .map_err(|_| api_error(TeamError::AccountChanged))?;
    #[cfg(feature = "local-host")]
    if request.method == TeamAskMethod::New
        && let Some(value) = super::chats::start_for_owner(
            owner,
            &client,
            &request.target.organization,
            &request.target.repository,
            &request.target.checkout,
            &serde_json::to_string(&request.params)
                .map_err(|_| api_error(TeamError::InvalidRequest))?,
        )?
    {
        return Ok(value);
    }
    let identity = tokenstat_identity::MachineIdentity::load()
        .map_err(|_| ended())?
        .ok_or_else(ended)?;
    let ticket = RequestTicket {
        organization_id: request.target.organization,
        checkout_id: request.target.checkout,
        capabilities: vec![TeamCapability::Read, TeamCapability::Run],
        share_id: request.target.share,
    };
    TeamConnection::connect_run(
        owner.clone(),
        Arc::new(client),
        ticket,
        request.target.repository,
        identity.public_key(),
    )?
    .ask(request.method, &request.params)
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
        "The computer sharing this project is not reachable right now. It needs to be on, with tokenstat open.",
    )
}
struct Retirement {
    pool: Weak<Pool>,
    key: Key,
    lifetime: Arc<()>,
}
impl Retirement {
    fn retire(&self) {
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
impl Drop for Retirement {
    fn drop(&mut self) {
        self.retire();
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
                let retirement = Retirement {
                    pool,
                    key: worker_key,
                    lifetime: worker_lifetime,
                };
                work_with_retirement(receiver, connector, Some(&retirement));
            })
            .is_err()
        {
            slots.remove(&key);
            return Err(ended());
        }
        Ok(())
    }

    #[cfg(test)]
    fn call(
        self: &Arc<Self>,
        key: Key,
        connector: Connector,
        method: TeamReadMethod,
        params: TeamReadParams,
    ) -> Result<Value, DispatchError> {
        self.call_until(key, connector, method, params, Instant::now() + CALL_BUDGET)
    }

    /// Only the closed read enum belongs here. Mutations require explicit
    /// receipts and must never inherit this bounded reconnect behavior.
    fn read(
        self: &Arc<Self>,
        key: Key,
        mut connector: impl FnMut() -> Connector,
        method: TeamReadMethod,
        params: TeamReadParams,
    ) -> Result<Value, DispatchError> {
        let deadline = Instant::now() + CALL_BUDGET;
        for attempt in 0..2 {
            if Instant::now() >= deadline {
                return Err(ended());
            }
            let result =
                self.call_until(key.clone(), connector(), method, params.clone(), deadline);
            if attempt == 0
                && result.as_ref().is_err_and(|error| {
                    matches!(
                        error.code.as_str(),
                        "team_connection_unavailable" | "team_access_expired" | "teams_unreachable"
                    )
                })
            {
                continue;
            }
            return result;
        }
        Err(ended())
    }

    fn call_until(
        self: &Arc<Self>,
        key: Key,
        connector: Connector,
        method: TeamReadMethod,
        params: TeamReadParams,
        deadline: Instant,
    ) -> Result<Value, DispatchError> {
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

#[cfg(test)]
fn work(receiver: Receiver<Job>, connector: Connector) {
    work_with_retirement(receiver, connector, None)
}

fn work_with_retirement(
    receiver: Receiver<Job>,
    connector: Connector,
    retirement: Option<&Retirement>,
) {
    let Ok(first) = receiver.recv() else {
        return;
    };
    if Instant::now() >= first.deadline {
        if let Some(retirement) = retirement {
            retirement.retire();
        }
        let _ = first.reply.send(Err(ended()));
        return;
    }
    let mut connection = match connector() {
        Ok(connection) => connection,
        Err(error) => {
            if let Some(retirement) = retirement {
                retirement.retire();
            }
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
        // Publish retirement before waking a retrying reader. The old worker
        // cannot accept that retry or remove a replacement's lifetime later.
        if failed && let Some(retirement) = retirement {
            retirement.retire();
        }
        let _ = job.reply.send(result);
        last_use = Instant::now();
        if failed {
            break;
        }
    }
    if let Some(retirement) = retirement {
        retirement.retire();
    }
    // The failed worker never replays a job. Its read-only caller may make
    // one new connection with the same immutable scope and original deadline.
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
    let connector = || -> Connector {
        let owner = owner.clone();
        let client = Arc::new(client.clone());
        let ticket = RequestTicket {
            organization_id: target.organization.clone(),
            checkout_id: target.checkout.clone(),
            capabilities: vec![TeamCapability::Read],
            share_id: target.share.clone(),
        };
        let repository = target.repository.clone();
        Box::new(move || {
            Ok(Box::new(TeamConnection::connect(
                owner, client, ticket, repository, device,
            )?))
        })
    };
    static POOL: OnceLock<Arc<Pool>> = OnceLock::new();
    POOL.get_or_init(|| Arc::new(Pool::default())).read(
        key,
        connector,
        request.method,
        request.params,
    )
}

#[cfg(test)]
mod tests;
