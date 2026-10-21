// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Account-server authority only. A host still needs durable per-person Ask
//! admission, reviewed context, a checkout writer and process supervision.

use super::{TeamClient, TeamError, value};
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::Duration;
use tokenstat_identity::lease_clock::{Deadline, Stamp};
use tokenstat_identity::{
    MachineIdentity, hex,
    team_host_proof::{HostChallenge, HostProofBinding},
    teams::{
        TeamCapability, TrustedTeamKeys, VerifiedTeamTicket,
        runs::{MAX_RUN_LEASE_SECONDS, TeamRunBinding, TeamRunLease, VerifiedTeamRunLease},
    },
};

const FEATURE: &str = "host-run-authority-v1";
const JS_MAX: u64 = 9_007_199_254_740_991;
fn expired() -> TeamError {
    TeamError::Rejected {
        status: 403,
        code: "team_run_retired".into(),
        message: "This run's access expired or changed. Review access before starting a new run."
            .into(),
    }
}

#[derive(Clone, Copy)]
pub(super) struct Time {
    pub stamp: Stamp,
    pub wall_ms: i64,
}
impl Time {
    fn now() -> Option<Self> {
        Some(Self {
            stamp: Stamp::now()?,
            wall_ms: jiff::Timestamp::now().as_millisecond(),
        })
    }
    fn seconds(self) -> Result<u64, TeamError> {
        u64::try_from(self.wall_ms.div_euclid(1000)).map_err(|_| expired())
    }
}
pub(super) type Clock = Arc<dyn Fn() -> Option<Time> + Send + Sync>;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Pending {
    expected_revision: u64,
    operation_id: String,
    #[serde(skip)]
    start: Time,
}
impl Pending {
    fn new(revision: u64, start: Time) -> Result<Self, TeamError> {
        let mut raw = [0u8; 16];
        getrandom::fill(&mut raw).map_err(|_| TeamError::InvalidRequest)?;
        Ok(Self {
            expected_revision: revision,
            operation_id: format!("runop_{}", hex(&raw)),
            start,
        })
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Reply {
    id: String,
    revision: u64,
    state: String,
    lease: Option<TeamRunLease>,
    expires_at: Option<String>,
}

/// One host-owned authority, never a viewer connection or a launch permit.
/// No Clone/Serialize: the host run owns renewal and terminal retirement.
pub struct HostRunAuthority {
    client: TeamClient,
    identity: MachineIdentity,
    machine: String,
    publisher: String,
    token: String,
    keys: TrustedTeamKeys,
    initiator: VerifiedTeamTicket,
    run: String,
    lease: VerifiedTeamRunLease,
    deadline: Deadline,
    retired: AtomicBool,
    pending: Option<Pending>,
    stop: Option<Pending>,
    clock: Clock,
}
impl std::fmt::Debug for HostRunAuthority {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HostRunAuthority([redacted])")
    }
}
impl TeamClient {
    /// The caller must hold fresh scoped admission for this original verified
    /// initiator before/after this network call. Nothing here launches work.
    pub fn admit_host_run_authority(
        &self,
        run: &str,
        initiator: &VerifiedTeamTicket,
    ) -> Result<HostRunAuthority, TeamError> {
        let identity = MachineIdentity::load_or_create().map_err(|_| TeamError::InvalidRequest)?;
        let machine = crate::config::ensure_machine_id().map_err(|_| TeamError::InvalidRequest)?;
        admit(
            self.clone(),
            identity,
            machine,
            run,
            initiator.clone(),
            Arc::new(Time::now),
        )
    }
}
pub(super) fn admit(
    client: TeamClient,
    identity: MachineIdentity,
    machine: String,
    run: &str,
    initiator: VerifiedTeamTicket,
    clock: Clock,
) -> Result<HostRunAuthority, TeamError> {
    if !reference(run, "runlease_") {
        return Err(TeamError::InvalidRequest);
    }
    let start = clock().ok_or_else(expired)?;
    let c = initiator.claims();
    if c.iss != client.origin()
        || c.host != identity.public_key_hex()
        || !c.cap.contains(&TeamCapability::Run)
        || c.share.is_none()
        || c.grant.is_none()
        || c.exp <= start.seconds()?
    {
        return Err(TeamError::InvalidRequest);
    }
    let original = Deadline::at(
        start.stamp,
        Duration::from_secs(initiator.lease_seconds(start.seconds()?)),
    )
    .ok_or_else(expired)?;
    let caps = client.capabilities()?;
    if !caps.enabled || caps.version != 1 || !caps.features.iter().any(|f| f == FEATURE) {
        return Err(TeamError::Unsupported);
    }
    let token = client
        .authentication
        .bearer
        .strip_prefix("tsk_")
        .and_then(|s| s.split_once('_'))
        .map(|v| v.0)
        .filter(|v| {
            !v.is_empty()
                && v.len() <= 128
                && v.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
        .ok_or(TeamError::InvalidResponse)?
        .to_owned();
    if !caps.ready()
        || caps.actor_id.as_deref() != Some(c.publisher.as_str())
        || caps.device_key.as_deref() != Some(c.host.as_str())
        || caps.authorization_path.as_deref()
            != Some(format!("/settings/teams/devices/{token}").as_str())
    {
        return Err(TeamError::InvalidResponse);
    }
    let mut keys = client.verification_keys()?;
    let operation = json!({"id":run,"ticket":initiator.ticket().wire_value()});
    let operation_hash = hex(Sha256::digest(
        serde_json::to_vec(&(
            "run.create",
            run,
            hex(Sha256::digest(initiator.ticket().wire_value().as_bytes()).as_slice()),
        ))
        .map_err(|_| TeamError::InvalidRequest)?,
    )
    .as_slice());
    let challenge: HostChallenge = client.request(
        Method::POST,
        &["teams", "runs", "challenge"],
        Some(operation.clone()),
        None,
    )?;
    let now = clock().ok_or_else(expired)?;
    live_original(&client, &original, c.exp, now)?;
    let proof = challenge
        .answer(
            &identity,
            &HostProofBinding {
                issuer: client.origin(),
                actor: &c.publisher,
                token: &token,
                machine: &machine,
                organization: &c.org,
                checkout: &c.checkout,
                operation_hash: &operation_hash,
            },
            now.wall_ms,
        )
        .map_err(|_| TeamError::InvalidResponse)?;
    let mut body = operation;
    body["hostProof"] = value(&proof)?;
    let reply: Reply = client.request(Method::POST, &["teams", "runs"], Some(body), None)?;
    let end = clock().ok_or_else(expired)?;
    live_original(&client, &original, c.exp, end)?;
    if unknown_signer(&keys, &initiator, run, &reply, end.seconds()?) {
        keys = client.verification_keys()?;
        live_original(&client, &original, c.exp, clock().ok_or_else(expired)?)?;
    }
    let finish = clock().ok_or_else(expired)?;
    let lease = verify_reply(&keys, &initiator, run, &reply, 1, finish.seconds()?)?;
    live_original(&client, &original, c.exp, clock().ok_or_else(expired)?)?;
    let deadline = Deadline::at(
        start.stamp,
        Duration::from_secs(lease.lease_seconds(start.seconds()?)),
    )
    .ok_or_else(expired)?;
    if deadline
        .remaining_at(clock().ok_or_else(expired)?.stamp)
        .is_none()
    {
        return Err(expired());
    }
    Ok(HostRunAuthority {
        publisher: c.publisher.clone(),
        client,
        identity,
        machine,
        token,
        keys,
        initiator,
        run: run.to_owned(),
        lease,
        deadline,
        retired: AtomicBool::new(false),
        pending: None,
        stop: None,
        clock,
    })
}
fn live_original(
    client: &TeamClient,
    deadline: &Deadline,
    expiry: u64,
    now: Time,
) -> Result<(), TeamError> {
    client.ensure_current()?;
    if now.seconds()? >= expiry || deadline.remaining_at(now.stamp).is_none() {
        return Err(expired());
    }
    Ok(())
}
fn reference(value: &str, prefix: &str) -> bool {
    value.strip_prefix(prefix).is_some_and(|s| {
        s.len() == 32
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
fn verify_reply(
    keys: &TrustedTeamKeys,
    actor: &VerifiedTeamTicket,
    run: &str,
    reply: &Reply,
    revision: u64,
    now: u64,
) -> Result<VerifiedTeamRunLease, TeamError> {
    if reply.id != run
        || reply.revision != revision
        || reply.revision > JS_MAX
        || reply.state != "active"
    {
        return Err(TeamError::InvalidResponse);
    }
    let lease = keys
        .verify_run_lease(
            reply.lease.as_ref().ok_or(TeamError::InvalidResponse)?,
            &TeamRunBinding {
                run,
                initiator: actor,
            },
            now,
        )
        .map_err(|_| TeamError::InvalidResponse)?;
    let expires: jiff::Timestamp = reply
        .expires_at
        .as_deref()
        .ok_or(TeamError::InvalidResponse)?
        .parse()
        .map_err(|_| TeamError::InvalidResponse)?;
    if lease.claims().revision != reply.revision
        || expires.as_millisecond()
            != i64::try_from(lease.claims().exp)
                .map_err(|_| TeamError::InvalidResponse)?
                .checked_mul(1000)
                .ok_or(TeamError::InvalidResponse)?
    {
        return Err(TeamError::InvalidResponse);
    }
    Ok(lease)
}
fn unknown_signer(
    keys: &TrustedTeamKeys,
    initiator: &VerifiedTeamTicket,
    run: &str,
    reply: &Reply,
    now: u64,
) -> bool {
    reply.lease.as_ref().is_some_and(|lease| {
        matches!(
            keys.verify_run_lease(lease, &TeamRunBinding { run, initiator }, now),
            Err(tokenstat_identity::teams::TeamTicketError::UntrustedAuthority)
        )
    })
}
impl HostRunAuthority {
    fn time(&self) -> Result<Time, TeamError> {
        if let Some(now) = (self.clock)().filter(|t| t.wall_ms >= 0) {
            Ok(now)
        } else {
            self.retired.store(true, Ordering::Release);
            Err(expired())
        }
    }
    pub fn lease(&self) -> &VerifiedTeamRunLease {
        &self.lease
    }
    /// A local launch may pass a shorter one-shot birth window to its trusted
    /// anchor. Never derive that window from signed wall expiry alone: a
    /// suspend or rollback must not extend the original local lease budget.
    pub fn remaining(&self) -> Result<Duration, TeamError> {
        self.ensure_live()?;
        let result = (|| {
            let now = self.time()?;
            let wall = u64::try_from(now.wall_ms).map_err(|_| expired())?;
            let end = self
                .lease
                .claims()
                .exp
                .checked_mul(1000)
                .ok_or_else(expired)?;
            let wall = Duration::from_millis(
                end.checked_sub(wall)
                    .filter(|n| *n > 0)
                    .ok_or_else(expired)?,
            );
            let local = self.deadline.remaining_at(now.stamp).ok_or_else(expired)?;
            Ok(local.min(wall))
        })();
        if result.is_err() {
            self.retired.store(true, Ordering::Release);
        }
        result
    }
    /// Recheck before every run effect. An expired or retired instance cannot
    /// be revived by a new connection, delayed HTTP reply or wall rollback.
    pub fn ensure_live(&self) -> Result<(), TeamError> {
        if self.retired.load(Ordering::Acquire) {
            return Err(expired());
        }
        let result = (|| {
            self.client.ensure_current()?;
            let now = self.time()?;
            if now.seconds()? >= self.lease.claims().exp
                || self.deadline.remaining_at(now.stamp).is_none()
            {
                return Err(expired());
            }
            Ok(())
        })();
        if result.is_err() {
            self.retired.store(true, Ordering::Release);
        }
        result
    }
    pub fn renew(&mut self) -> Result<(), TeamError> {
        self.ensure_live()?;
        let start = self.time()?;
        let pending = match &self.pending {
            Some(p) => p.clone(),
            None => Pending::new(self.lease.claims().revision, start)?,
        };
        self.pending = Some(pending.clone());
        let result = self.operation("renew", &pending);
        self.ensure_live()?;
        let reply = match result {
            Ok(reply) => reply,
            Err(error) => {
                self.retire_on_error(&error);
                return Err(error);
            }
        };
        let end = self.time()?;
        let next = pending
            .expected_revision
            .checked_add(1)
            .filter(|n| *n <= JS_MAX)
            .ok_or(TeamError::InvalidResponse)?;
        if unknown_signer(
            &self.keys,
            &self.initiator,
            &self.run,
            &reply,
            end.seconds()?,
        ) {
            self.ensure_live()?;
            let refreshed = self.client.verification_keys();
            self.ensure_live()?;
            let keys = refreshed.inspect_err(|error| self.retire_on_error(error))?;
            self.keys = keys;
        }
        let verified = verify_reply(
            &self.keys,
            &self.initiator,
            &self.run,
            &reply,
            next,
            self.time()?.seconds()?,
        );
        let lease = match verified {
            Ok(lease) => lease,
            Err(error) => {
                self.retired.store(true, Ordering::Release);
                return Err(error);
            }
        };
        let budget = lease
            .lease_seconds(pending.start.seconds()?)
            .min(MAX_RUN_LEASE_SECONDS);
        self.ensure_live()?;
        let deadline = Deadline::at(pending.start.stamp, Duration::from_secs(budget))
            .filter(|d| {
                self.time()
                    .is_ok_and(|now| d.remaining_at(now.stamp).is_some())
            })
            .ok_or_else(expired);
        match deadline {
            Ok(deadline) => {
                self.deadline = deadline;
                self.lease = lease;
                self.pending = None;
                self.ensure_live()
            }
            Err(error) => {
                self.retired.store(true, Ordering::Release);
                Err(error)
            }
        }
    }
    /// Retires local authority before any network request. This does not stop
    /// the OS process; its owner must do so and prove completion separately.
    pub fn retire(&mut self) -> Result<(), TeamError> {
        self.retired.store(true, Ordering::Release);
        let start = self.time()?;
        let pending = match &self.stop {
            Some(p) => p.clone(),
            None => Pending::new(self.lease.claims().revision, start)?,
        };
        self.stop = Some(pending.clone());
        let reply = self.operation("retire", &pending)?;
        if reply.id != self.run
            || reply.state != "retired"
            || reply.lease.is_some()
            || reply.expires_at.is_some()
            || reply.revision < self.lease.claims().revision
            || reply.revision > JS_MAX
        {
            return Err(TeamError::InvalidResponse);
        }
        Ok(())
    }
    fn operation(&self, action: &str, pending: &Pending) -> Result<Reply, TeamError> {
        let operation_hash = hex(Sha256::digest(
            serde_json::to_vec(&(
                format!("run.{action}"),
                &self.run,
                pending.expected_revision,
                &pending.operation_id,
            ))
            .map_err(|_| TeamError::InvalidRequest)?,
        )
        .as_slice());
        let mut body = value(pending)?;
        let mut challenge_body = body.clone();
        challenge_body["action"] = json!(action);
        let challenge: HostChallenge = self.client.request(
            Method::POST,
            &["teams", "runs", &self.run, "challenge"],
            Some(challenge_body),
            None,
        )?;
        if action == "renew" {
            self.ensure_live()?;
        }
        let now = self.time()?;
        let c = self.initiator.claims();
        let proof = challenge
            .answer(
                &self.identity,
                &HostProofBinding {
                    issuer: self.client.origin(),
                    actor: &self.publisher,
                    token: &self.token,
                    machine: &self.machine,
                    organization: &c.org,
                    checkout: &c.checkout,
                    operation_hash: &operation_hash,
                },
                now.wall_ms,
            )
            .map_err(|_| TeamError::InvalidResponse)?;
        self.client.ensure_current()?;
        if action == "renew" {
            self.ensure_live()?;
        }
        body["hostProof"] = value(&proof)?;
        self.client.request(
            Method::POST,
            &["teams", "runs", &self.run, action],
            Some(body),
            None,
        )
    }
    fn retire_on_error(&self, error: &TeamError) {
        if !matches!(
            error,
            TeamError::Network
                | TeamError::Rejected {
                    status: 429 | 500..=599,
                    ..
                }
        ) {
            self.retired.store(true, Ordering::Release);
        }
    }
}

#[cfg(test)]
mod tests;
