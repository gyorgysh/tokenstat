// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Hash-only batch proofs for canonical guardian output. Temporary intents are
//! the sole exception; readers may settle written rows, never replay output.

use super::*;
use crate::transcript::Event;

const BATCH_BYTES: usize = 512 * 1024;
const BATCH_ROWS: usize = 128;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Origin {
    scope: Scope,
    actor: Actor,
    run_id: String,
    batch: u32,
    index: u16,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct AgentRecord {
    kind: String,
    seq: u64,
    event: Event,
    at_ms: i64,
    backend: String,
    #[serde(rename = "teamAgent")]
    origin: Origin,
}
pub(crate) fn batch_key(scope: &Scope, run: &str, batch: u32) -> Result<String, &'static str> {
    serde_json::to_vec(&("tokenstat/team-output/v1", scope, run, batch))
        .map(|v| digest(&v))
        .map_err(|_| "Output identity is invalid")
}
impl AgentRecord {
    pub(super) fn sequence(&self) -> u64 {
        self.seq
    }
    pub(super) fn batch(&self) -> u32 {
        self.origin.batch
    }
    pub(super) fn index(&self) -> u16 {
        self.origin.index
    }
    pub(super) fn scope(&self) -> &Scope {
        &self.origin.scope
    }
    pub(super) fn run_id(&self) -> &str {
        &self.origin.run_id
    }
    pub(super) fn backend(&self) -> &str {
        &self.backend
    }
    pub(super) fn projected(&self) -> Result<Value, &'static str> {
        self.encoded()?;
        let mut value = super::super::visible(crate::chat::StoredEvent::Agent {
            event: self.event.clone(),
            at_ms: self.at_ms,
            backend: self.backend.clone(),
        })
        .map_err(|_| "Invalid output")?;
        let actor = &self.origin.actor;
        value["seq"] = json!(self.seq);
        value["mode"] = json!("agent");
        value["author"] = json!({"kind":"agent","backend":self.backend,"runId":self.origin.run_id,"initiatedBy":{"kind":"person","id":actor.id,"name":actor.name,"handle":actor.handle,"avatar":actor.avatar}});
        Ok(value)
    }
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        seq: u64,
        event: Event,
        at_ms: i64,
        backend: String,
        scope: Scope,
        actor: Actor,
        run_id: String,
        batch: u32,
        index: u16,
    ) -> Self {
        Self {
            kind: "agent".into(),
            seq,
            event,
            at_ms,
            backend,
            origin: Origin {
                scope,
                actor,
                run_id,
                batch,
                index,
            },
        }
    }
    fn key(&self) -> Result<String, &'static str> {
        batch_key(&self.origin.scope, &self.origin.run_id, self.origin.batch)
    }
    pub fn encoded(&self) -> Result<Vec<u8>, &'static str> {
        if self.kind != "agent"
            || self.at_ms <= 0
            || self.backend.is_empty()
            || self.backend.len() > 64
            || !self.origin.scope.valid()
            || !self.origin.actor.valid()
            || !self
                .origin
                .run_id
                .strip_prefix("run_")
                .is_some_and(|s| lower_hex(s, 32))
            || matches!(self.event, Event::Session { .. } | Event::Attachment { .. })
        {
            return Err("Output row is invalid");
        }
        let Value::Object(raw) =
            serde_json::to_value(self).map_err(|_| "Output encoding failed")?
        else {
            return Err("Output encoding failed");
        };
        let bytes = crate::work_transcript_identity::encoded(raw, self.seq)?;
        if bytes.len() > MAX_RECORD_BYTES {
            return Err("Output row is too large");
        }
        Ok(bytes)
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct AgentProof {
    request_digest: String,
    scope: Scope,
    rows: Vec<(u64, String)>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PendingAgent {
    rows: Vec<AgentRecord>,
    request_digest: String,
    before_bytes: u64,
    before_digest: String,
}
pub(super) fn batch_bytes(rows: &[AgentRecord]) -> Result<Vec<u8>, &'static str> {
    if rows.is_empty() || rows.len() > BATCH_ROWS {
        return Err("Output batch size is invalid");
    }
    let first = &rows[0];
    let key = first.key()?;
    let mut bytes = Vec::new();
    for (i, row) in rows.iter().enumerate() {
        if row.key()? != key
            || usize::from(row.origin.index) != i
            || (i > 0
                && row.seq
                    != rows[i - 1]
                        .seq
                        .checked_add(1)
                        .ok_or("Output sequence is invalid")?)
            || row.backend != first.backend
            || row.at_ms != first.at_ms
            || serde_json::to_value(&row.origin.actor).ok()
                != serde_json::to_value(&first.origin.actor).ok()
        {
            return Err("Output batch identity is invalid");
        }
        bytes.extend(row.encoded()?);
        if bytes.len() > BATCH_BYTES {
            return Err("Output batch is too large");
        }
    }
    Ok(bytes)
}
impl Journal {
    pub fn agent_recorded(&self, key: &str, request_digest: &str) -> Result<bool, &'static str> {
        if let Some(proof) = self.agent.get(key) {
            if proof.request_digest != request_digest {
                return Err("Output batch changed");
            }
            return Ok(true);
        }
        Ok(false)
    }
    pub(super) fn validate_agent(&self) -> Result<(), &'static str> {
        let pending_count = usize::from(self.pending.is_some())
            + usize::from(self.pending_ask.is_some())
            + usize::from(self.pending_agent.is_some());
        if pending_count > 1 || self.agent.len() > CAPACITY {
            return Err("Output journal is ambiguous");
        }
        for (key, proof) in &self.agent {
            if !lower_hex(key, 64)
                || !lower_hex(&proof.request_digest, 64)
                || !proof.scope.valid()
                || proof.rows.is_empty()
                || proof.rows.len() > BATCH_ROWS
                || proof
                    .rows
                    .iter()
                    .any(|(seq, hash)| *seq > 9_007_199_254_740_991 || !lower_hex(hash, 64))
                || proof
                    .rows
                    .windows(2)
                    .any(|r| r[0].0.checked_add(1) != Some(r[1].0))
            {
                return Err("Output proof is invalid");
            }
        }
        if let Some(pending) = &self.pending_agent {
            batch_bytes(&pending.rows)?;
            if !lower_hex(&pending.before_digest, 64)
                || !lower_hex(&pending.request_digest, 64)
                || pending.before_bytes > super::super::HISTORY_LIMIT
                || self.agent.len() == CAPACITY
                || self.agent.contains_key(&pending.rows[0].key()?)
            {
                return Err("Output intent is invalid");
            }
        }
        Ok(())
    }
    pub(super) fn observe_agent(&mut self, canonical: &[u8]) -> Result<bool, &'static str> {
        let Some(pending) = &self.pending_agent else {
            return Ok(false);
        };
        let before =
            usize::try_from(pending.before_bytes).map_err(|_| "Invalid output position")?;
        if canonical.len() == before && digest(canonical) == pending.before_digest {
            return Ok(false);
        }
        let bytes = batch_bytes(&pending.rows)?;
        let end = before
            .checked_add(bytes.len())
            .ok_or("Invalid output position")?;
        if canonical
            .get(..before)
            .is_none_or(|v| digest(v) != pending.before_digest)
            || canonical.get(before..end) != Some(bytes.as_slice())
        {
            return Err("Output changed during delivery");
        }
        let first = &pending.rows[0];
        let proof = AgentProof {
            request_digest: pending.request_digest.clone(),
            scope: first.origin.scope.clone(),
            rows: pending
                .rows
                .iter()
                .map(|r| Ok((r.seq, digest(&r.encoded()?))))
                .collect::<Result<_, &str>>()?,
        };
        self.agent.insert(first.key()?, proof);
        self.pending_agent = None;
        Ok(true)
    }
    pub(super) fn agent_author(
        &self,
        raw: &Value,
        seq: u64,
    ) -> Result<Option<VerifiedAttribution>, &'static str> {
        if raw.get("teamAsk").is_some() || raw.get("teamComment").is_some() {
            return Err("Ambiguous output authorship");
        }
        let row: AgentRecord =
            serde_json::from_value(raw.clone()).map_err(|_| "Invalid output row")?;
        // Event's ordinary parser tolerates vendor additions. Canonical Team
        // proof does not: even an ignored nested field changes the exact row.
        if serde_json::to_value(&row).map_err(|_| "Invalid output row")? != *raw {
            return Err("Output row contains unproven fields");
        }
        let key = row.key()?;
        let Some(proof) = self.agent.get(&key) else {
            return Ok(None);
        };
        if row.seq != seq
            || proof.scope != row.origin.scope
            || proof.rows.get(usize::from(row.origin.index))
                != Some(&(seq, digest(&row.encoded()?)))
        {
            return Err("Output authorship could not be verified");
        }
        let a = row.origin.actor;
        Ok(Some(VerifiedAttribution {
            key: format!("{key}:{}", row.origin.index),
            scope: row.origin.scope,
            person: json!({"kind":"agent","backend":row.backend,"runId":row.origin.run_id,"initiatedBy":{"kind":"person","id":a.id,"name":a.name,"handle":a.handle,"avatar":a.avatar}}),
            mode: "agent",
        }))
    }
    pub(super) fn require_agent_complete(
        &self,
        share: &str,
        seen: &std::collections::HashSet<String>,
    ) -> Result<(), &'static str> {
        for (key, proof) in &self.agent {
            if proof.scope.share == share
                && (0..proof.rows.len()).any(|i| !seen.contains(&format!("{key}:{i}")))
            {
                return Err("Accepted agent output is missing");
            }
        }
        Ok(())
    }
}
