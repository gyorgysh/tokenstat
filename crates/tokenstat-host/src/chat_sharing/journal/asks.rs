// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::chat_receipts::team_runs as runs;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AskAttribution {
    attribution: Attribution,
    run_id: String,
    request_digest: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::chat::sharing) struct AskRecord {
    kind: String,
    seq: u64,
    text: String,
    at_ms: i64,
    #[serde(rename = "teamAsk")]
    ask: AskAttribution,
}
impl AskRecord {
    pub fn new(row: Record, request: &runs::Request, fence: &runs::Fence) -> Self {
        Self {
            kind: row.kind,
            seq: row.seq,
            text: row.text,
            at_ms: row.at_ms,
            ask: AskAttribution {
                attribution: row.attribution,
                run_id: fence.run_id().into(),
                request_digest: request.request_digest.clone(),
            },
        }
    }
    fn key(&self) -> Result<String, &'static str> {
        let a = &self.ask.attribution;
        key_for(&a.scope, &a.actor.id, &a.client_message_id)
    }
    pub fn encoded(&self) -> Result<Vec<u8>, &'static str> {
        // Keep the same bounded text/actor validation as ordinary Comments.
        Record::new(
            self.seq,
            self.text.clone(),
            self.at_ms,
            self.ask.attribution.clone(),
        )
        .encoded()?;
        if self.kind != "user"
            || !self
                .ask
                .run_id
                .strip_prefix("run_")
                .is_some_and(|v| lower_hex(v, 32))
            || !lower_hex(&self.ask.request_digest, 64)
        {
            return Err("Ask record is invalid");
        }
        let Value::Object(raw) = serde_json::to_value(self).map_err(|_| "Ask encoding failed")?
        else {
            return Err("Ask encoding failed");
        };
        let bytes = crate::work_transcript_identity::encoded(raw, self.seq)?;
        if bytes.len() > MAX_RECORD_BYTES {
            return Err("Ask record is too large");
        }
        Ok(bytes)
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PendingAsk {
    record: AskRecord,
    fence: runs::Fence,
    before_bytes: u64,
    before_digest: String,
}

fn run_scope(scope: &Scope) -> runs::Scope {
    runs::Scope {
        issuer: scope.issuer.clone(),
        organization: scope.organization.clone(),
        repository: scope.repository.clone(),
        checkout: scope.checkout.clone(),
        share: scope.share.clone(),
    }
}

impl Journal {
    pub fn run_status(
        &self,
        scope: &runs::Scope,
        person: &str,
        message: &str,
    ) -> Result<Option<&runs::Record>, &'static str> {
        self.runs
            .as_ref()
            .map(|runs| runs.status(scope, person, message))
            .transpose()
            .map(Option::flatten)
            .map_err(|_| "Run receipt could not be verified")
    }
    pub fn require_unused_comment_id(
        &self,
        scope: &Scope,
        person: &str,
        message: &str,
    ) -> Result<(), &'static str> {
        if self.status(scope, person, message)?.is_some() {
            return Err("This message id was already used for a Comment");
        }
        Ok(())
    }
    pub fn reserve_ask(
        &mut self,
        row: AskRecord,
        request: runs::Request,
        binding: runs::Binding,
        before: &[u8],
    ) -> Result<(), &'static str> {
        row.encoded()?;
        let a = &row.ask.attribution;
        self.require_unused_comment_id(&a.scope, &a.actor.id, &a.client_message_id)?;
        if self.busy()
            || self.asks.len() >= CAPACITY
            || before.len() as u64 > super::super::HISTORY_LIMIT
        {
            return Err("An earlier message needs recovery or receipt storage is full");
        }
        if request.scope != run_scope(&a.scope)
            || request.actor.person != a.actor.id
            || request.actor.device != a.actor.device
            || request.client_message_id != a.client_message_id
            || request.client_message_created_at_ms != a.client_message_created_at_ms
            || request.request_digest != row.ask.request_digest
            || binding.fence.run_id() != row.ask.run_id
            || self.asks.contains_key(&row.key()?)
        {
            return Err("Ask binding does not match its canonical row");
        }
        let mut ledger = match &self.runs {
            Some(ledger) => ledger.clone(),
            None => runs::Ledger::new(runs::Source {
                conversation: self.source.conversation.clone(),
                workspace: self.source.workspace.clone(),
                created_at_ms: self.source.created_at_ms,
            })
            .map_err(|_| "Run source is invalid")?,
        };
        if ledger
            .reserve(request, binding.clone(), row.at_ms)
            .map_err(|_| "Run reservation failed")?
            != runs::Reservation::New
        {
            return Err("This Ask already has a receipt");
        }
        self.runs = Some(ledger);
        self.pending_ask = Some(PendingAsk {
            record: row,
            fence: binding.fence,
            before_bytes: before.len() as u64,
            before_digest: digest(before),
        });
        // Refuse before the canonical fence or text is written. Headroom is
        // for replacing this temporary intent with its proof and state.
        if self.encoded()?.len() as u64 > MAX_JOURNAL_BYTES - 1024 {
            return Err("Run receipt storage is full");
        }
        Ok(())
    }
    pub(super) fn validate_asks(&self) -> Result<(), &'static str> {
        if self.asks.len() > CAPACITY || self.pending.is_some() && self.pending_ask.is_some() {
            return Err("Ask journal is ambiguous");
        }
        if self.asks.keys().any(|key| self.receipts.contains_key(key)) {
            return Err("A message id has both Ask and Comment proof");
        }
        if self.asks.iter().any(|(key, receipt)| !lower_hex(key, 64) || !matches!(receipt,
            Receipt::Accepted { request_digest, record_digest, share, at_ms, seq }
                if lower_hex(request_digest, 64) && lower_hex(record_digest, 64) && share_id(share) && *at_ms > 0 && *seq<=9_007_199_254_740_991)) {
            return Err("Ask proofs could not be verified");
        }
        if let Some(ledger) = &self.runs {
            for record in ledger.records() {
                let Some(canonical) = record.canonical() else {
                    continue;
                };
                let r = record.request();
                let s = Scope {
                    issuer: r.scope.issuer.clone(),
                    organization: r.scope.organization.clone(),
                    repository: r.scope.repository.clone(),
                    checkout: r.scope.checkout.clone(),
                    share: r.scope.share.clone(),
                };
                let key = key_for(&s, &r.actor.person, &r.client_message_id)?;
                if !matches!(self.asks.get(&key),Some(Receipt::Accepted {request_digest,record_digest,share,seq,at_ms})
                    if *request_digest==r.request_digest && *record_digest==canonical.record_digest && *share==r.scope.share && *seq==canonical.sequence && *at_ms==record.created_at_ms())
                {
                    return Err("Run canonical proof is missing or disagrees with its Ask");
                }
            }
        }
        if let Some(pending) = &self.pending_ask {
            pending.record.encoded()?;
            let a = &pending.record.ask.attribution;
            let run = self
                .run_status(&run_scope(&a.scope), &a.actor.id, &a.client_message_id)?
                .ok_or("Missing Ask reservation")?;
            if pending.before_bytes > super::super::HISTORY_LIMIT
                || !lower_hex(&pending.before_digest, 64)
                || self.asks.len() == CAPACITY
                || self.asks.contains_key(&pending.record.key()?)
                || self.receipts.contains_key(&pending.record.key()?)
                || run.binding().fence != pending.fence
                || run.binding().fence.run_id() != pending.record.ask.run_id
                || run.request().request_digest != pending.record.ask.request_digest
                || run.request().actor.device != a.actor.device
                || run.request().client_message_created_at_ms != a.client_message_created_at_ms
                || run.canonical().is_some()
                || run.state() != runs::State::Reserved
            {
                return Err("Ask intent could not be verified");
            }
        }
        Ok(())
    }
    pub(super) fn observe_ask(&mut self, bytes: &[u8]) -> Result<bool, &'static str> {
        let Some(pending) = &self.pending_ask else {
            return Ok(false);
        };
        let before = usize::try_from(pending.before_bytes).map_err(|_| "Invalid Ask position")?;
        if before == bytes.len() && digest(bytes) == pending.before_digest {
            return Ok(false);
        }
        let row = pending.record.encoded()?;
        let end = before
            .checked_add(row.len())
            .ok_or("Invalid Ask position")?;
        if bytes
            .get(..before)
            .is_none_or(|prefix| digest(prefix) != pending.before_digest)
            || bytes.get(before..end) != Some(row.as_slice())
        {
            return Err("Ask history changed during delivery");
        }
        let a = &pending.record.ask.attribution;
        let record_digest = digest(&row);
        self.runs
            .as_mut()
            .ok_or("Missing Ask reservation")?
            .bind_canonical(
                &run_scope(&a.scope),
                &a.actor.id,
                &a.client_message_id,
                &pending.fence,
                runs::Canonical {
                    sequence: pending.record.seq,
                    record_digest: record_digest.clone(),
                },
            )
            .map_err(|_| "Ask row does not match its run")?;
        self.asks.insert(
            pending.record.key()?,
            Receipt::Accepted {
                request_digest: pending.record.ask.request_digest.clone(),
                record_digest,
                share: a.scope.share.clone(),
                seq: pending.record.seq,
                at_ms: pending.record.at_ms,
            },
        );
        self.pending_ask = None;
        Ok(true)
    }
    pub(super) fn ask_author(
        &self,
        raw: &Value,
        seq: u64,
    ) -> Result<Option<VerifiedAttribution>, &'static str> {
        let row: AskRecord =
            serde_json::from_value(raw.clone()).map_err(|_| "Ask record could not be verified")?;
        let key = row.key()?;
        let Some(Receipt::Accepted {
            request_digest,
            record_digest,
            share,
            seq: expected,
            at_ms,
        }) = self.asks.get(&key)
        else {
            return Ok(None);
        };
        if seq != row.seq
            || seq != *expected
            || digest(&row.encoded()?) != *record_digest
            || row.ask.request_digest != *request_digest
            || row.ask.attribution.scope.share != *share
            || row.at_ms != *at_ms
        {
            return Err("Ask authorship could not be verified");
        }
        let a = row.ask.attribution;
        Ok(Some(VerifiedAttribution {
            key,
            scope: a.scope,
            person: json!({"kind":"person","id":a.actor.id,"name":a.actor.name,"handle":a.actor.handle,"avatar":a.actor.avatar}),
            mode: "ask",
        }))
    }
    /// Close the unresolved run whose processes the caller proved gone. A run
    /// that never reached Launching had no backend and simply did not start.
    pub fn recover_unresolved_run(
        &mut self,
        fence: &runs::Fence,
        started_proven_gone: bool,
        at_ms: i64,
    ) -> Result<runs::State, &'static str> {
        use runs::State;
        let ledger = self.runs.as_mut().ok_or("Run reservation is missing")?;
        // A crash can follow the durable terminal write but precede release
        // of the project claim or canonical fence. Finish that same cleanup.
        if let Some(record) = ledger
            .records()
            .find(|record| &record.binding().fence == fence)
            && record.state().terminal()
        {
            return Ok(record.state());
        }
        let record = ledger.unresolved().ok_or("No run needs recovery")?;
        if &record.binding().fence != fence {
            return Err("A different run holds this chat");
        }
        let request = record.request().clone();
        let path: &[State] = match record.state() {
            State::Reserved => &[State::NotStarted],
            State::Launching | State::Running | State::Stopping if started_proven_gone => {
                &[State::NeedsRecovery, State::Recovered]
            }
            State::NeedsRecovery if started_proven_gone => &[State::Recovered],
            _ => return Err("This run may still have processes"),
        };
        for next in path {
            ledger
                .transition(
                    &request.scope,
                    &request.actor.person,
                    &request.client_message_id,
                    fence,
                    *next,
                    at_ms,
                )
                .map_err(|_| "Run transition could not be verified")?;
        }
        Ok(path[path.len() - 1])
    }
    /// The caller holds the exact source fence and has proved this run's
    /// processes gone. Preserve written output and retire only an exact,
    /// unwritten intent before releasing either durable writer fence.
    pub fn retire_terminal_output(
        &mut self,
        fence: &runs::Fence,
        bytes: &[u8],
        chain: &[u8],
    ) -> Result<(), &'static str> {
        let ledger = self.runs.as_ref().ok_or("Run reservation is missing")?;
        let record = ledger
            .records()
            .find(|record| &record.binding().fence == fence)
            .ok_or("Run reservation is missing")?;
        if !record.state().terminal()
            || ledger.unresolved().is_some()
            || record.canonical().is_none()
            || self.pending.is_some()
            || self.pending_ask.is_some()
        {
            return Err("This run still needs recovery");
        }
        let scope = record.request().scope.clone();
        self.observe_agent(bytes)?;
        self.observe_chain(chain)?;
        self.retire_unwritten_agent(&scope, fence.run_id(), bytes)?;
        // Segment reservations are exclusive to the run behind the source
        // fence. No later Ask can reserve output before this cleanup.
        self.retire_unwritten_segments(chain)
    }
    pub fn transition_run(
        &mut self,
        request: &runs::Request,
        fence: &runs::Fence,
        next: runs::State,
        at_ms: i64,
    ) -> Result<(), &'static str> {
        self.runs
            .as_mut()
            .ok_or("Run reservation is missing")?
            .transition(
                &request.scope,
                &request.actor.person,
                &request.client_message_id,
                fence,
                next,
                at_ms,
            )
            .map(|_| ())
            .map_err(|_| "Run transition could not be verified")
    }
}
