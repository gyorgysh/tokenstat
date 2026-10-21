// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Durable run metadata beside the canonical transcript. This ledger grants
//! no permission to execute: callers prove current authority, exclusive run
//! ownership and process outcomes before recording transitions. Loading or
//! looking up a receipt never starts, resumes or retries an agent.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};

const CAPACITY: usize = 4096;
pub const MAX_BYTES: usize = 4 * 1024 * 1024;
const JS_MAX: u64 = 9_007_199_254_740_991;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Conflict,
    Busy,
    Full,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Invalid => "Run delivery could not be verified.",
            Self::Conflict => "This attempt changed after it was first recorded.",
            Self::Busy => "An earlier run must finish or be recovered first.",
            Self::Full => "Run receipt storage is full.",
        })
    }
}
impl std::error::Error for Error {}
fn digest(bytes: &[u8]) -> String {
    tokenstat_identity::hex(&Sha256::digest(bytes))
}
fn hex(value: &str, n: usize) -> bool {
    value.len() == n
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn tagged(value: &str, tag: &str) -> bool {
    value.strip_prefix(tag).is_some_and(|s| hex(s, 32))
}
fn id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Source {
    pub conversation: String,
    pub workspace: String,
    pub created_at_ms: i64,
}
impl Source {
    fn valid(&self) -> bool {
        id(&self.conversation)
            && !self.workspace.is_empty()
            && self.workspace.len() <= 4096
            // Workspace identities are local paths. Whitespace and Unicode
            // remain exact; they are not cloud resource identifiers.
            && !self.workspace.contains('\0')
            && self.created_at_ms >= 0
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Scope {
    pub issuer: String,
    pub organization: String,
    pub repository: String,
    pub checkout: String,
    pub share: String,
}
impl Scope {
    fn valid(&self) -> bool {
        let Ok(url) = reqwest::Url::parse(&self.issuer) else {
            return false;
        };
        self.issuer.len() <= 512
            && url.origin().ascii_serialization() == self.issuer
            && url.username().is_empty()
            && url.password().is_none()
            && url.path() == "/"
            && url.query().is_none()
            && url.fragment().is_none()
            && (url.scheme() == "https"
                || url.scheme() == "http"
                    && matches!(
                        url.host_str(),
                        Some("127.0.0.1" | "localhost" | "[::1]" | "::1")
                    ))
            && [&self.organization, &self.repository, &self.checkout]
                .into_iter()
                .all(|v| id(v))
            && tagged(&self.share, "share_")
    }
}
/// The original verified submitting device is permanent. Deduplication uses
/// the person, so another device can settle an attempt without replacing it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Actor {
    pub person: String,
    pub device: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub scope: Scope,
    pub actor: Actor,
    pub client_message_id: String,
    pub client_message_created_at_ms: i64,
    /// Hash of mode, text, attachments and requested agent settings. Text
    /// stays on the canonical timeline, not in a second transcript store.
    pub request_digest: String,
    pub context_digest: String,
    pub checkout_digest: String,
    pub backend: String,
}
impl Request {
    fn valid(&self) -> bool {
        self.scope.valid()
            && id(&self.actor.person)
            && hex(&self.actor.device, 64)
            && super::valid_id(&self.client_message_id)
            && self.client_message_created_at_ms > 0
            && self.client_message_created_at_ms as u64 <= JS_MAX
            && [
                &self.request_digest,
                &self.context_digest,
                &self.checkout_digest,
            ]
            .into_iter()
            .all(|v| hex(v, 64))
            && !self.backend.is_empty()
            && self.backend.len() <= 64
            && self
                .backend
                .bytes()
                .all(|v| v.is_ascii_alphanumeric() || matches!(v, b'_' | b'-'))
    }
    fn key(&self) -> Result<String, Error> {
        key(&self.scope, &self.actor.person, &self.client_message_id)
    }
    fn same_attempt(&self, other: &Self) -> bool {
        self.scope == other.scope
            && self.actor.person == other.actor.person
            && self.client_message_id == other.client_message_id
            && self.client_message_created_at_ms == other.client_message_created_at_ms
            && self.request_digest == other.request_digest
            && self.context_digest == other.context_digest
            && self.checkout_digest == other.checkout_digest
            && self.backend == other.backend
    }
}
fn key(scope: &Scope, person: &str, message: &str) -> Result<String, Error> {
    if !scope.valid() || !id(person) || !super::valid_id(message) {
        return Err(Error::Invalid);
    }
    serde_json::to_vec(&("tokenstat/team-run-receipt/v1", scope, person, message))
        .map(|b| digest(&b))
        .map_err(|_| Error::Invalid)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields, try_from = "WireFence")]
pub struct Fence {
    run_id: String,
    incarnation: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireFence {
    run_id: String,
    incarnation: String,
}
impl TryFrom<WireFence> for Fence {
    type Error = Error;
    fn try_from(value: WireFence) -> Result<Self, Error> {
        Self::new(value.run_id, value.incarnation)
    }
}
impl Fence {
    pub fn new(run_id: String, incarnation: String) -> Result<Self, Error> {
        if !tagged(&run_id, "run_") || !hex(&incarnation, 64) {
            return Err(Error::Invalid);
        }
        Ok(Self {
            run_id,
            incarnation,
        })
    }
    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn incarnation(&self) -> &str {
        &self.incarnation
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    pub fence: Fence,
    pub cloud_reference: String,
    pub grant: String,
}
impl Binding {
    fn valid(&self) -> bool {
        tagged(&self.cloud_reference, "runlease_") && tagged(&self.grant, "grant_")
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Reserved,
    Launching,
    Running,
    Stopping,
    NeedsRecovery,
    NotStarted,
    Succeeded,
    Failed,
    Stopped,
    Recovered,
}
impl State {
    pub fn terminal(self) -> bool {
        matches!(
            self,
            Self::NotStarted | Self::Succeeded | Self::Failed | Self::Stopped | Self::Recovered
        )
    }
    fn allows(self, next: Self) -> bool {
        match self {
            Self::Reserved => matches!(
                next,
                Self::Launching | Self::NotStarted | Self::NeedsRecovery
            ),
            Self::Launching => matches!(
                next,
                Self::Running | Self::NotStarted | Self::Stopping | Self::NeedsRecovery
            ),
            Self::Running => matches!(
                next,
                Self::Stopping | Self::Succeeded | Self::Failed | Self::NeedsRecovery
            ),
            Self::Stopping => matches!(next, Self::Stopped | Self::Failed | Self::NeedsRecovery),
            Self::NeedsRecovery => next == Self::Recovered,
            _ => false,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Canonical {
    pub sequence: u64,
    pub record_digest: String,
}
impl Canonical {
    fn valid(&self) -> bool {
        self.sequence <= JS_MAX && hex(&self.record_digest, 64)
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Record {
    request: Request,
    binding: Binding,
    state: State,
    canonical: Option<Canonical>,
    created_at_ms: i64,
    updated_at_ms: i64,
}
impl Record {
    pub fn request(&self) -> &Request {
        &self.request
    }
    pub fn binding(&self) -> &Binding {
        &self.binding
    }
    pub fn state(&self) -> State {
        self.state
    }
    pub fn canonical(&self) -> Option<&Canonical> {
        self.canonical.as_ref()
    }
    pub fn created_at_ms(&self) -> i64 {
        self.created_at_ms
    }
    pub fn updated_at_ms(&self) -> i64 {
        self.updated_at_ms
    }
    fn valid(&self) -> bool {
        self.request.valid()
            && self.binding.valid()
            && self.created_at_ms > 0
            && self.updated_at_ms >= self.created_at_ms
            && self.updated_at_ms as u64 <= JS_MAX
            && self.canonical.as_ref().is_none_or(Canonical::valid)
            && (matches!(
                self.state,
                State::Reserved | State::NotStarted | State::NeedsRecovery | State::Recovered
            ) || self.canonical.is_some())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reservation {
    New,
    Existing,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", try_from = "WireLedger")]
pub struct Ledger {
    version: u32,
    source: Source,
    records: BTreeMap<String, Record>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireLedger {
    version: u32,
    source: Source,
    records: BTreeMap<String, Record>,
}
impl TryFrom<WireLedger> for Ledger {
    type Error = Error;
    fn try_from(value: WireLedger) -> Result<Self, Error> {
        let ledger = Self {
            version: value.version,
            source: value.source,
            records: value.records,
        };
        ledger.validate(&ledger.source)?;
        Ok(ledger)
    }
}
impl Ledger {
    pub fn new(source: Source) -> Result<Self, Error> {
        if !source.valid() {
            return Err(Error::Invalid);
        }
        Ok(Self {
            version: 1,
            source,
            records: BTreeMap::new(),
        })
    }
    pub fn decode(bytes: &[u8], source: &Source) -> Result<Self, Error> {
        if bytes.len() > MAX_BYTES {
            return Err(Error::Full);
        }
        let ledger: Self = serde_json::from_slice(bytes).map_err(|_| Error::Invalid)?;
        ledger.validate(source)?;
        Ok(ledger)
    }
    pub fn validate(&self, source: &Source) -> Result<(), Error> {
        if self.version != 1
            || &self.source != source
            || !source.valid()
            || self.records.len() > CAPACITY
        {
            return Err(Error::Invalid);
        }
        let mut runs = HashSet::new();
        let mut fences = HashSet::new();
        let mut cloud = HashSet::new();
        let mut active = 0;
        for (key, record) in &self.records {
            if !record.valid()
                || record.request.key()?.as_str() != key
                || !runs.insert(record.binding.fence.run_id())
                || !fences.insert(record.binding.fence.incarnation())
                || !cloud.insert(&record.binding.cloud_reference)
            {
                return Err(Error::Invalid);
            }
            active += usize::from(!record.state.terminal());
        }
        if active > 1 {
            return Err(Error::Invalid);
        }
        Ok(())
    }
    pub fn encoded(&self) -> Result<Vec<u8>, Error> {
        self.validate(&self.source)?;
        let bytes = serde_json::to_vec(self).map_err(|_| Error::Invalid)?;
        if bytes.len() > MAX_BYTES {
            return Err(Error::Full);
        }
        Ok(bytes)
    }
    pub fn status(
        &self,
        scope: &Scope,
        person: &str,
        message: &str,
    ) -> Result<Option<&Record>, Error> {
        Ok(self.records.get(&key(scope, person, message)?))
    }
    pub fn unresolved(&self) -> Option<&Record> {
        self.records.values().find(|r| !r.state.terminal())
    }
    pub fn records(&self) -> impl Iterator<Item = &Record> {
        self.records.values()
    }
    pub fn reserve(
        &mut self,
        request: Request,
        binding: Binding,
        at_ms: i64,
    ) -> Result<Reservation, Error> {
        if !request.valid() || !binding.valid() || at_ms <= 0 || at_ms as u64 > JS_MAX {
            return Err(Error::Invalid);
        }
        let key = request.key()?;
        if let Some(existing) = self.records.get(&key) {
            return if existing.request.same_attempt(&request) {
                Ok(Reservation::Existing)
            } else {
                Err(Error::Conflict)
            };
        }
        if self.unresolved().is_some() {
            return Err(Error::Busy);
        }
        if self.records.len() >= CAPACITY {
            return Err(Error::Full);
        }
        if self.records.values().any(|r| {
            r.binding.fence.run_id() == binding.fence.run_id()
                || r.binding.fence.incarnation() == binding.fence.incarnation()
                || r.binding.cloud_reference == binding.cloud_reference
        }) {
            return Err(Error::Conflict);
        }
        let record = Record {
            request,
            binding,
            state: State::Reserved,
            canonical: None,
            created_at_ms: at_ms,
            updated_at_ms: at_ms,
        };
        self.records.insert(key.clone(), record);
        // Leave room for the active receipt's canonical proof and longest
        // state/time representation before another admission can enter.
        if let Err(error) = self.encoded().and_then(|bytes| {
            if bytes.len() <= MAX_BYTES - 512 {
                Ok(())
            } else {
                Err(Error::Full)
            }
        }) {
            self.records.remove(&key);
            return Err(error);
        }
        Ok(Reservation::New)
    }
    fn exact_mut(
        &mut self,
        scope: &Scope,
        person: &str,
        message: &str,
        fence: &Fence,
    ) -> Result<&mut Record, Error> {
        let record = self
            .records
            .get_mut(&key(scope, person, message)?)
            .ok_or(Error::Invalid)?;
        if &record.binding.fence != fence {
            return Err(Error::Conflict);
        }
        Ok(record)
    }
    /// Attach proof of the durable canonical human row before requesting a
    /// launch. A changed row can never be substituted under an old attempt.
    pub fn bind_canonical(
        &mut self,
        scope: &Scope,
        person: &str,
        message: &str,
        fence: &Fence,
        canonical: Canonical,
    ) -> Result<bool, Error> {
        if !canonical.valid() {
            return Err(Error::Invalid);
        }
        let record = self.exact_mut(scope, person, message, fence)?;
        if let Some(existing) = &record.canonical {
            return if existing == &canonical {
                Ok(false)
            } else {
                Err(Error::Conflict)
            };
        }
        if record.state != State::Reserved {
            return Err(Error::Conflict);
        }
        record.canonical = Some(canonical);
        Ok(true)
    }
    /// Persist Launching before spawn; Running only after exact process
    /// ownership is established. Terminal transitions require proven process
    /// completion (or a definitive spawn failure), never stream EOF alone.
    /// Repeating a transition returns false and is no permission to relaunch.
    pub fn transition(
        &mut self,
        scope: &Scope,
        person: &str,
        message: &str,
        fence: &Fence,
        next: State,
        at_ms: i64,
    ) -> Result<bool, Error> {
        if at_ms <= 0 || at_ms as u64 > JS_MAX {
            return Err(Error::Invalid);
        }
        let record = self.exact_mut(scope, person, message, fence)?;
        if record.state == next {
            return Ok(false);
        }
        if !record.state.allows(next) || next == State::Launching && record.canonical.is_none() {
            return Err(Error::Conflict);
        }
        record.state = next;
        record.updated_at_ms = record.updated_at_ms.max(at_ms);
        Ok(true)
    }
}

#[cfg(test)]
mod tests;
