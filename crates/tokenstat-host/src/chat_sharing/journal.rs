// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Local proof of attributed canonical rows. The journal holds hashes and
//! receipts, plus at most one temporary write intent; settled text lives only
//! in events.ndjson. Callers hold source acceptance and transcript locks.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
#[path = "journal/asks.rs"]
mod asks;
pub(super) use asks::AskRecord;
#[path = "journal/agent.rs"]
mod agent;
pub(super) use agent::{AgentRecord, batch_key as agent_batch_key};

const CAPACITY: usize = 4096;
const MAX_RECORD_BYTES: usize = 64 * 1024;
pub(super) const MAX_JOURNAL_BYTES: u64 = 4 * 1024 * 1024;

fn digest(bytes: &[u8]) -> String {
    tokenstat_identity::hex(&Sha256::digest(bytes))
}

fn lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn opaque_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}
fn share_id(value: &str) -> bool {
    value
        .strip_prefix("share_")
        .is_some_and(|id| lower_hex(id, 32))
}

fn key_for(scope: &Scope, actor: &str, message: &str) -> Result<String, &'static str> {
    serde_json::to_vec(&(scope, actor, message))
        .map(|bytes| digest(&bytes))
        .map_err(|_| "comment identity could not be encoded")
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Status {
    Pending,
    Accepted { seq: u64, at_ms: i64 },
    NotAccepted,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Source {
    pub conversation: String,
    pub workspace: String,
    pub created_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Scope {
    pub issuer: String,
    pub organization: String,
    pub repository: String,
    pub checkout: String,
    pub share: String,
}
impl Scope {
    fn valid(&self) -> bool {
        let Ok(origin) = reqwest::Url::parse(&self.issuer) else {
            return false;
        };
        self.issuer.len() <= 512
            && origin.origin().ascii_serialization() == self.issuer
            && origin.username().is_empty()
            && origin.password().is_none()
            && origin.path() == "/"
            && origin.query().is_none()
            && origin.fragment().is_none()
            && (origin.scheme() == "https"
                || origin.scheme() == "http"
                    && matches!(
                        origin.host_str(),
                        Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
                    ))
            && [&self.organization, &self.repository, &self.checkout]
                .into_iter()
                .all(|id| opaque_id(id))
            && share_id(&self.share)
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Actor {
    pub id: String,
    pub device: String,
    pub name: String,
    pub handle: Option<String>,
    pub avatar: Option<String>,
}
impl Actor {
    fn valid(&self) -> bool {
        opaque_id(&self.id)
            && lower_hex(&self.device, 64)
            && !self.name.trim().is_empty()
            && self.name.chars().count() <= 128
            && self
                .handle
                .as_ref()
                .is_none_or(|handle| handle.len() <= 128)
            && self.avatar.as_ref().is_none_or(|path| {
                path.strip_prefix("/avatar/").is_some_and(|name| {
                    !name.is_empty()
                        && name.len() <= 128
                        && !name.contains("..")
                        && name
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
                })
            })
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Attribution {
    pub scope: Scope,
    pub actor: Actor,
    pub client_message_id: String,
    pub client_message_created_at_ms: i64,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Record {
    kind: String,
    pub seq: u64,
    pub text: String,
    pub at_ms: i64,
    #[serde(rename = "teamComment")]
    pub attribution: Attribution,
}

pub(super) struct VerifiedAttribution {
    pub key: String,
    pub scope: Scope,
    pub person: Value,
    pub mode: &'static str,
}

impl Record {
    pub fn new(seq: u64, text: String, at_ms: i64, attribution: Attribution) -> Self {
        Self {
            kind: "user".into(),
            seq,
            text,
            at_ms,
            attribution,
        }
    }
    pub fn key(&self) -> Result<String, &'static str> {
        let a = &self.attribution;
        // One person's attempt stays the same across their devices. The
        // original verified device remains bound by the canonical row hash;
        // reconnecting from another device cannot post that attempt twice.
        key_for(&a.scope, &a.actor.id, &a.client_message_id)
    }
    pub fn request_digest(&self) -> Result<String, &'static str> {
        serde_json::to_vec(&(&self.text, self.attribution.client_message_created_at_ms))
            .map(|bytes| digest(&bytes))
            .map_err(|_| "comment content could not be encoded")
    }
    pub fn encoded(&self) -> Result<Vec<u8>, &'static str> {
        if self.kind != "user"
            || self.text.trim().is_empty()
            || self.text.len() > 8192
            || !crate::chat_receipts::valid_id(&self.attribution.client_message_id)
            || self.at_ms <= 0
            || self.attribution.client_message_created_at_ms <= 0
            || !self.attribution.scope.valid()
            || !self.attribution.actor.valid()
        {
            return Err("comment record is invalid");
        }
        let Value::Object(value) =
            serde_json::to_value(self).map_err(|_| "comment could not be encoded")?
        else {
            return Err("comment could not be encoded");
        };
        let bytes = crate::work_transcript_identity::encoded(value, self.seq)?;
        if bytes.len() > MAX_RECORD_BYTES {
            return Err("comment record is too large");
        }
        Ok(bytes)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", tag = "state", deny_unknown_fields)]
pub(super) enum Receipt {
    Accepted {
        request_digest: String,
        record_digest: String,
        share: String,
        seq: u64,
        at_ms: i64,
    },
    NotAccepted {
        request_digest: String,
    },
}
impl Receipt {
    pub fn request_digest(&self) -> &str {
        match self {
            Self::Accepted { request_digest, .. } | Self::NotAccepted { request_digest } => {
                request_digest
            }
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Pending {
    record: Record,
    before_bytes: u64,
    before_digest: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Journal {
    version: u32,
    source: Source,
    receipts: BTreeMap<String, Receipt>,
    pending: Option<Pending>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    runs: Option<crate::chat_receipts::team_runs::Ledger>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    asks: BTreeMap<String, Receipt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pending_ask: Option<asks::PendingAsk>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    agent: BTreeMap<String, agent::AgentProof>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pending_agent: Option<agent::PendingAgent>,
}

impl Journal {
    pub fn new(source: Source) -> Self {
        Self {
            version: 1,
            source,
            receipts: BTreeMap::new(),
            pending: None,
            runs: None,
            asks: BTreeMap::new(),
            pending_ask: None,
            agent: BTreeMap::new(),
            pending_agent: None,
        }
    }
    pub fn decode(bytes: &[u8], source: &Source) -> Result<Self, &'static str> {
        if bytes.len() as u64 > MAX_JOURNAL_BYTES {
            return Err("comment journal is too large");
        }
        let journal: Self =
            serde_json::from_slice(bytes).map_err(|_| "comment journal could not be verified")?;
        if journal.version != 1
            || &journal.source != source
            || journal.receipts.len() > CAPACITY
            || journal.pending.is_some() && journal.receipts.len() == CAPACITY
        {
            return Err("comment journal does not match this source");
        }
        journal.validate_runs()?;
        journal.validate_asks()?;
        journal.validate_agent()?;
        if journal.receipts.iter().any(|(key, receipt)| {
            !lower_hex(key, 64)
                || !lower_hex(receipt.request_digest(), 64)
                || matches!(receipt, Receipt::Accepted { record_digest, share, at_ms, .. }
                    if !lower_hex(record_digest, 64) || !share_id(share) || *at_ms <= 0)
        }) {
            return Err("comment receipts could not be verified");
        }
        if let Some(pending) = &journal.pending {
            pending.record.encoded()?;
            if !lower_hex(&pending.before_digest, 64)
                || pending.before_bytes > super::HISTORY_LIMIT
                || journal.receipts.contains_key(&pending.record.key()?)
            {
                return Err("comment receipt is ambiguous");
            }
        }
        Ok(journal)
    }
    pub fn encoded(&self) -> Result<Vec<u8>, &'static str> {
        self.validate_runs()?;
        self.validate_asks()?;
        self.validate_agent()?;
        let bytes = serde_json::to_vec(self).map_err(|_| "comment journal could not be encoded")?;
        if bytes.len() as u64 > MAX_JOURNAL_BYTES {
            return Err("comment journal is full");
        }
        Ok(bytes)
    }
    pub fn receipt(&self, record: &Record) -> Result<Option<&Receipt>, &'static str> {
        let a = &record.attribution;
        if self.asks.contains_key(&record.key()?) {
            return Err("this message id was already used to ask an agent");
        }
        if self
            .runs
            .as_ref()
            .map(|runs| {
                runs.status(
                    &crate::chat_receipts::team_runs::Scope {
                        issuer: a.scope.issuer.clone(),
                        organization: a.scope.organization.clone(),
                        repository: a.scope.repository.clone(),
                        checkout: a.scope.checkout.clone(),
                        share: a.scope.share.clone(),
                    },
                    &a.actor.id,
                    &a.client_message_id,
                )
            })
            .transpose()
            .map_err(|_| "run receipt could not be verified")?
            .flatten()
            .is_some()
        {
            return Err("this message id was already used to ask an agent");
        }
        let receipt = self.receipts.get(&record.key()?);
        let request_digest = record.request_digest()?;
        if receipt.is_some_and(|receipt| receipt.request_digest() != request_digest) {
            return Err("this comment id was used for different content");
        }
        Ok(receipt)
    }
    /// A receipt check needs no message text. Its actor comes from the
    /// verified exact-share principal and may use another of their devices.
    pub fn status(
        &self,
        scope: &Scope,
        actor: &str,
        message: &str,
    ) -> Result<Option<Status>, &'static str> {
        let key = key_for(scope, actor, message)?;
        if let Some(receipt) = self.receipts.get(&key) {
            return Ok(Some(match receipt {
                Receipt::Accepted { seq, at_ms, .. } => Status::Accepted {
                    seq: *seq,
                    at_ms: *at_ms,
                },
                Receipt::NotAccepted { .. } => Status::NotAccepted,
            }));
        }
        if let Some(pending) = &self.pending
            && pending.record.key()? == key
        {
            return Ok(Some(Status::Pending));
        }
        Ok(None)
    }
    /// Reserve before writing the canonical row. No permanent receipt is
    /// evicted to make room, so a repeated id cannot become a new acceptance.
    pub fn reserve(&mut self, record: Record, before: &[u8]) -> Result<(), &'static str> {
        record.encoded()?;
        if before.len() as u64 > super::HISTORY_LIMIT {
            return Err("comment history is too large");
        }
        if self.pending.is_some() || self.pending_ask.is_some() || self.pending_agent.is_some() {
            return Err("an earlier comment needs reconciliation");
        }
        if self.receipt(&record)?.is_some() {
            return Err("this comment already has a receipt");
        }
        if self.receipts.len() >= CAPACITY {
            return Err("comment receipt storage is full");
        }
        self.pending = Some(Pending {
            record,
            before_bytes: before.len() as u64,
            before_digest: digest(before),
        });
        Ok(())
    }
    /// A read can settle an exact row already on disk. It cannot append text
    /// or turn an unresolved reservation into permission to replay a write.
    pub fn observe(&mut self, bytes: &[u8]) -> Result<bool, &'static str> {
        let ask_changed = self.observe_ask(bytes)?;
        let agent_changed = self.observe_agent(bytes)?;
        let Some(pending) = &self.pending else {
            return Ok(ask_changed || agent_changed);
        };
        let before =
            usize::try_from(pending.before_bytes).map_err(|_| "comment position is invalid")?;
        if before == bytes.len() && digest(bytes) == pending.before_digest {
            return Ok(false);
        }
        let record = pending.record.encoded()?;
        let end = before
            .checked_add(record.len())
            .ok_or("comment position is invalid")?;
        if bytes
            .get(..before)
            .is_none_or(|prefix| digest(prefix) != pending.before_digest)
            || bytes.get(before..end) != Some(record.as_slice())
        {
            return Err("comment history changed during delivery");
        }
        let key = pending.record.key()?;
        self.receipts.insert(
            key,
            Receipt::Accepted {
                request_digest: pending.record.request_digest()?,
                record_digest: digest(&record),
                share: pending.record.attribution.scope.share.clone(),
                seq: pending.record.seq,
                at_ms: pending.record.at_ms,
            },
        );
        self.pending = None;
        Ok(true)
    }
    /// Only an explicitly repeated, currently authorized attempt can finish
    /// an unwritten reservation. Use its original verified author and time.
    pub fn pending_record(
        &self,
        request: &Record,
        bytes: &[u8],
    ) -> Result<Option<&Record>, &'static str> {
        let Some(pending) = &self.pending else {
            return Ok(None);
        };
        if pending.record.key()? != request.key()? {
            return Ok(None);
        }
        if pending.record.request_digest()? != request.request_digest()? {
            return Err("this comment id was used for different content");
        }
        if pending.before_bytes != bytes.len() as u64 || pending.before_digest != digest(bytes) {
            return Err("comment history changed during delivery");
        }
        Ok(Some(&pending.record))
    }
    /// A different writer may retire an unwritten reservation after proving
    /// the entire previous canonical prefix is still exact. Its original id
    /// receives a permanent negative receipt, never a fresh acceptance.
    pub fn retire_unwritten(&mut self, bytes: &[u8]) -> Result<bool, &'static str> {
        if self.pending_ask.is_some() || self.pending_agent.is_some() {
            return Err("an earlier Ask needs recovery on the publishing computer");
        }
        let Some(pending) = &self.pending else {
            return Ok(false);
        };
        if pending.before_bytes != bytes.len() as u64 || pending.before_digest != digest(bytes) {
            return Err("comment history changed during delivery");
        }
        self.receipts.insert(
            pending.record.key()?,
            Receipt::NotAccepted {
                request_digest: pending.record.request_digest()?,
            },
        );
        self.pending = None;
        Ok(true)
    }
    /// Raw stored author fields have no authority. Only an exact journaled
    /// canonical row may become a named participant in a shared projection.
    pub fn author(
        &self,
        raw: &Value,
        seq: u64,
    ) -> Result<Option<VerifiedAttribution>, &'static str> {
        if raw.get("teamAgent").is_some() {
            return self.agent_author(raw, seq);
        }
        if raw.get("teamAsk").is_some() {
            if raw.get("teamComment").is_some() {
                return Err("ambiguous message mode");
            }
            return self.ask_author(raw, seq);
        }
        if raw.get("teamComment").is_none() {
            return Ok(None);
        }
        let record: Record = serde_json::from_value(raw.clone())
            .map_err(|_| "comment record could not be verified")?;
        let key = record.key()?;
        let Some(Receipt::Accepted {
            record_digest,
            request_digest,
            share,
            at_ms,
            seq: expected,
        }) = self.receipts.get(&key)
        else {
            return Ok(None);
        };
        if record.seq != seq
            || *expected != seq
            || digest(&record.encoded()?) != *record_digest
            || *request_digest != record.request_digest()?
            || *at_ms != record.at_ms
            || *share != record.attribution.scope.share
        {
            return Err("comment authorship could not be verified");
        }
        let a = record.attribution.actor;
        Ok(Some(VerifiedAttribution {
            key,
            scope: record.attribution.scope,
            person: json!({"kind":"person","id":a.id,"name":a.name,"handle":a.handle,"avatar":a.avatar}),
            mode: "comment",
        }))
    }
    pub fn require_complete(
        &self,
        share: &str,
        seen: &std::collections::HashSet<String>,
    ) -> Result<(), &'static str> {
        self.require_agent_complete(share, seen)?;
        if self.receipts.iter().any(|(key, receipt)| matches!(receipt, Receipt::Accepted { share: bound, .. } if bound == share && !seen.contains(key))) {
            return Err("accepted comments are missing from history");
        }
        if self.asks.iter().any(|(key, receipt)| matches!(receipt, Receipt::Accepted { share: bound, .. } if bound == share && !seen.contains(key))) {
            return Err("accepted Asks are missing from history");
        }
        Ok(())
    }
    pub fn forked(mut self, source: Source) -> Self {
        self.source = source;
        self.pending = None;
        self.pending_ask = None;
        self.pending_agent = None;
        // These are process/admission identities for the original source.
        // A copied conversation cannot inherit its authority or recovery.
        self.runs = None;
        self.receipts
            .retain(|_, receipt| matches!(receipt, Receipt::Accepted { .. }));
        self
    }
    fn validate_runs(&self) -> Result<(), &'static str> {
        if let Some(runs) = &self.runs {
            runs.validate(&crate::chat_receipts::team_runs::Source {
                conversation: self.source.conversation.clone(),
                workspace: self.source.workspace.clone(),
                created_at_ms: self.source.created_at_ms,
            })
            .map_err(|_| "run receipts do not match this source")?;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "journal/tests.rs"]
mod tests;
