// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Admission owns a fresh visible prefix and both local writer leases. It is
//! deliberately separate from the private-send path and provider continuations.

use super::{
    journal::{self, AskRecord, Attribution, Journal, Record},
    writer, *,
};
use crate::{
    chat_receipts::{RunnerLease, team_runs as runs},
    teams::AuthorizedTeamPrincipal,
};
use tokenstat_sync::teams::{RepositoryRole, TeamCapability};

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AskInput {
    pub text: String,
    pub client_message_id: String,
    pub client_message_created_at_ms: i64,
    pub review: String,
}
impl AskInput {
    pub fn validate(&self) -> Result<(), DispatchError> {
        if self.text.trim().is_empty()
            || self.text.len() > 8192
            || !crate::chat_receipts::valid_id(&self.client_message_id)
            || self.client_message_created_at_ms <= 0
            || !serde_json::to_vec(self).is_ok_and(|bytes| bytes.len() <= 14 * 1024)
        {
            return Err(DispatchError::new(
                "invalid_ask",
                "Enter a shorter message and try again.",
            ));
        }
        if self.review.len() != 64
            || !self
                .review
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(changed());
        }
        Ok(())
    }
    fn digest(&self) -> Result<String, DispatchError> {
        hash(&(
            "tokenstat/team-ask/v1",
            &self.text,
            self.client_message_created_at_ms,
            &self.review,
        ))
    }
}
fn hash(value: &impl Serialize) -> Result<String, DispatchError> {
    Ok(tokenstat_identity::hex(&Sha256::digest(
        serde_json::to_vec(value).map_err(|_| unavailable())?,
    )))
}
fn unavailable() -> DispatchError {
    DispatchError::new(
        "team_run_unavailable",
        "This Ask could not be verified. Check the chat before trying again.",
    )
}
fn checkout_unread() -> DispatchError {
    DispatchError::new(
        "team_checkout_unreadable",
        "The checkout's git state could not be read. Review it before asking the agent.",
    )
}
fn changed() -> DispatchError {
    DispatchError::new(
        "team_run_review_changed",
        "The shared conversation or checkout changed. Review it before asking the agent.",
    )
}
fn conflict() -> DispatchError {
    DispatchError::new(
        "team_run_conflict",
        "This message changed after its first attempt. Check the chat before trying again.",
    )
}
fn busy() -> DispatchError {
    DispatchError::new(
        "team_run_busy",
        "An earlier run must finish or be recovered before starting another.",
    )
}
fn run_scope(scope: &journal::Scope) -> runs::Scope {
    runs::Scope {
        issuer: scope.issuer.clone(),
        organization: scope.organization.clone(),
        repository: scope.repository.clone(),
        checkout: scope.checkout.clone(),
        share: scope.share.clone(),
    }
}
fn scope(
    principal: &AuthorizedTeamPrincipal,
) -> Result<(journal::Scope, journal::Actor), DispatchError> {
    let value = principal.value();
    if !value.capabilities.contains(&TeamCapability::Run)
        || value.grant_id.is_none()
        || !matches!(
            value.role,
            RepositoryRole::Contributor | RepositoryRole::Maintainer
        )
    {
        return Err(DispatchError::new(
            "team_run_forbidden",
            "This person and device need an execution grant from the publishing computer.",
        ));
    }
    writer::context(principal, false)
}
fn require_marker(
    chat: &Conversation,
    target: &SharedSource<'_>,
    scope: &journal::Scope,
) -> Result<(), DispatchError> {
    let marker = chat.team_share.as_ref().ok_or_else(paused)?;
    if target.revision.is_none()
        || marker.source_revision != target.revision
        || marker.id != scope.share
        || marker.initial_fingerprint != target.preview
    {
        return Err(paused());
    }
    Ok(())
}
pub(crate) struct AskReview {
    pub digest: String,
    pub worktree: tokenstat_workspace::git::CheckoutReview,
}

fn review(
    history: &History,
    scope: &journal::Scope,
    checkout: &str,
    folder: &Path,
) -> Result<AskReview, DispatchError> {
    let worktree =
        tokenstat_workspace::git::checkout_review(folder).map_err(|_| checkout_unread())?;
    Ok(AskReview {
        digest: hash(&(
            "tokenstat/team-ask-review/v2",
            scope,
            checkout,
            &history.title,
            &history.backend,
            history.history_trimmed,
            &history.events,
            &worktree,
        ))?,
        worktree,
    })
}
fn result(record: &runs::Record) -> Value {
    json!({"receipt":{"shareId":record.request().scope.share,"clientMessageId":record.request().client_message_id,
        "runId":record.binding().fence.run_id(),"state":record.state(),"sequence":record.canonical().map(|row|row.sequence),"createdAtMs":record.created_at_ms()}})
}

pub(crate) enum AskPreparation {
    Existing(Value),
    New(Box<PreparedAsk>),
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AskContext {
    title: String,
    backend: String,
    history_trimmed: bool,
    events: Vec<Value>,
    message: Value,
    /// The checkout state covered by this Ask's review.
    worktree: tokenstat_workspace::git::CheckoutReview,
}

/// No Clone/Serialize and no launch method. A future supervised runner takes
/// ownership of these exact leases, the immutable request and frozen context.
pub(crate) struct PreparedAsk {
    source: journal::Source,
    request: runs::Request,
    binding: runs::Binding,
    context: AskContext,
    _runner: RunnerLease,
    writer: tokenstat_workspace::writer::Lease,
    claimed: bool,
    actor: journal::Actor,
}
impl PreparedAsk {
    pub fn binding(&self) -> &runs::Binding {
        &self.binding
    }
    pub fn context(&self) -> &AskContext {
        &self.context
    }
    pub fn backend(&self) -> &str {
        &self.context.backend
    }
    pub fn ensure_writer_current(&self) -> Result<(), DispatchError> {
        self.writer.ensure_current().map_err(|_| changed())
    }
    pub fn claim_writer(&mut self) -> Result<(), DispatchError> {
        self.claimed = true;
        self.writer
            .claim_run(self.binding.fence.incarnation())
            .map_err(|_| unavailable())
    }
}

#[derive(Clone, Copy)]
enum Step {
    Fenced,
    Reserved,
    Canonical,
    Proven,
}

impl Store {
    pub(crate) fn ensure_prepared_ask(
        &self,
        target: SharedSource<'_>,
        prepared: &PreparedAsk,
        current: impl FnMut() -> Result<(), DispatchError>,
    ) -> Result<(), DispatchError> {
        self.ensure_ask_state(target, prepared, runs::State::Reserved, current)
    }
    pub(crate) fn ensure_launching_ask(
        &self,
        target: SharedSource<'_>,
        prepared: &PreparedAsk,
        current: impl FnMut() -> Result<(), DispatchError>,
    ) -> Result<(), DispatchError> {
        self.ensure_ask_state(target, prepared, runs::State::Launching, current)
    }
    fn ensure_ask_state(
        &self,
        target: SharedSource<'_>,
        prepared: &PreparedAsk,
        expected: runs::State,
        mut current: impl FnMut() -> Result<(), DispatchError>,
    ) -> Result<(), DispatchError> {
        prepared.ensure_writer_current()?;
        self.source_locked(target.workspace, target.id, false, |_, chat, bytes| {
            current()?;
            let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
            let journal = writer::load(&directory, chat, bytes)?.ok_or_else(unavailable)?;
            let record = journal
                .run_status(
                    &prepared.request.scope,
                    &prepared.request.actor.person,
                    &prepared.request.client_message_id,
                )
                .map_err(|_| unavailable())?
                .ok_or_else(unavailable)?;
            let marker = chat.team_share.as_ref().ok_or_else(paused)?;
            if marker.id != prepared.request.scope.share
                || writer::source(chat) != prepared.source
                || marker.source_revision != target.revision
                || marker.initial_fingerprint != target.preview
                || record.request() != &prepared.request
                || record.binding() != &prepared.binding
                || record.state() != expected
                || record.canonical().is_none()
                || chat.team_run_fence.as_ref() != Some(&prepared.binding.fence)
            {
                return Err(unavailable());
            }
            // Verify the exact Ask row is still present, not only its receipt.
            shared_project(
                chat,
                bytes,
                &prepared.request.scope.share,
                target.preview,
                Some(&journal),
                &directory,
                false,
            )?;
            prepared.ensure_writer_current()
        })
    }
    pub(crate) fn team_ask_review(
        &self,
        target: SharedSource<'_>,
        principal: &AuthorizedTeamPrincipal,
        folder: &Path,
        checkout: &str,
        mut current: impl FnMut() -> Result<(), DispatchError>,
    ) -> Result<AskReview, DispatchError> {
        let (scope, _) = scope(principal)?;
        self.source_locked(target.workspace, target.id, false, |_, chat, bytes| {
            principal.ensure_account_current()?;
            current()?;
            require_marker(chat, &target, &scope)?;
            let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
            let journal = writer::load(&directory, chat, bytes)?;
            let history = shared_project(
                chat,
                bytes,
                &scope.share,
                target.preview,
                journal.as_ref(),
                &directory,
                true,
            )?;
            review(&history, &scope, checkout, folder)
        })
    }
    pub(crate) fn prepare_team_ask(
        &self,
        target: SharedSource<'_>,
        principal: &AuthorizedTeamPrincipal,
        input: &AskInput,
        folder: &Path,
        checkout: &str,
        current: impl FnMut() -> Result<(), DispatchError>,
    ) -> Result<AskPreparation, DispatchError> {
        self.prepare_team_ask_steps(
            target,
            principal,
            input,
            (folder, checkout),
            current,
            |_| Ok(()),
        )
    }
    fn prepare_team_ask_steps(
        &self,
        target: SharedSource<'_>,
        principal: &AuthorizedTeamPrincipal,
        input: &AskInput,
        checkout: (&Path, &str),
        mut current: impl FnMut() -> Result<(), DispatchError>,
        mut checkpoint: impl FnMut(Step) -> Result<(), DispatchError>,
    ) -> Result<AskPreparation, DispatchError> {
        let (folder, checkout) = checkout;
        input.validate()?;
        let (scope, actor) = scope(principal)?;
        let request_digest = input.digest()?;
        let known = |journal: &Journal| -> Result<Option<Value>, DispatchError> {
            journal
                .require_unused_comment_id(&scope, &actor.id, &input.client_message_id)
                .map_err(|_| conflict())?;
            let existing = journal
                .run_status(&run_scope(&scope), &actor.id, &input.client_message_id)
                .map_err(|_| unavailable())?;
            if let Some(record) = existing {
                if record.request().request_digest != request_digest
                    || record.request().context_digest != input.review
                    || record.request().client_message_created_at_ms
                        != input.client_message_created_at_ms
                {
                    return Err(conflict());
                }
                return Ok(Some(result(record)));
            }
            Ok(None)
        };
        // Settle an immutable prior attempt even while its own writer is busy.
        // No candidate cloud reference or runner is allocated for a retry.
        if let Some(value) =
            self.source_locked(target.workspace, target.id, false, |_, chat, bytes| {
                principal.ensure_account_current()?;
                current()?;
                require_marker(chat, &target, &scope)?;
                let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
                let journal = writer::load(&directory, chat, bytes)?;
                journal.as_ref().map(known).transpose().map(Option::flatten)
            })?
        {
            return Ok(AskPreparation::Existing(value));
        }
        // No canonical/index lock spans filesystem writer acquisition or HTTP.
        let writer = tokenstat_workspace::writer::Lease::acquire(folder).map_err(|e| {
            if e == tokenstat_workspace::writer::Error::RecoveryRequired {
                super::run_recovery_required()
            } else {
                busy()
            }
        })?;
        self.source_locked(
            target.workspace,
            target.id,
            false,
            |mut index, chat, bytes| {
                principal.ensure_account_current()?;
                current()?;
                require_marker(chat, &target, &scope)?;
                writer.ensure_current().map_err(|_| changed())?;
                let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
                let mut journal = writer::load(&directory, chat, bytes)?
                    .unwrap_or_else(|| Journal::new(writer::source(chat)));
                if let Some(value) = known(&journal)? {
                    return Ok(AskPreparation::Existing(value));
                }
                if chat.team_run_fence.is_some()
                    || chat.running
                    || self
                        .active
                        .lock()
                        .map_err(|_| unavailable())?
                        .contains_key(target.id)
                {
                    return Err(busy());
                }
                let runner = RunnerLease::try_acquire(&self.root, target.id)
                    .map_err(|_| unavailable())?
                    .ok_or_else(busy)?;
                let history =
                    shared_project(chat, bytes, &scope.share, target.preview, Some(&journal), &directory, true)?;
                let reviewed = review(&history, &scope, checkout, folder)?;
                if reviewed.digest != input.review {
                    return Err(changed());
                }
                crate::chat_receipts::validate_created_at(
                    Some(input.client_message_created_at_ms),
                    now_ms(),
                )?;
                journal.retire_unwritten(bytes).map_err(|_| unavailable())?;
                let binding = runs::Binding {
                    fence: runs::Fence::new(
                        format!("run_{:032x}", rand::random::<u128>()),
                        format!(
                            "{:032x}{:032x}",
                            rand::random::<u128>(),
                            rand::random::<u128>()
                        ),
                    )
                    .map_err(|_| unavailable())?,
                    cloud_reference: format!("runlease_{:032x}", rand::random::<u128>()),
                    grant: principal.value().grant_id.clone().ok_or_else(unavailable)?,
                };
                let request = runs::Request {
                    scope: run_scope(&scope),
                    actor: runs::Actor {
                        person: actor.id.clone(),
                        device: actor.device.clone(),
                    },
                    client_message_id: input.client_message_id.clone(),
                    client_message_created_at_ms: input.client_message_created_at_ms,
                    request_digest: request_digest.clone(),
                    context_digest: input.review.clone(),
                    checkout_digest: checkout.into(),
                    backend: history.backend.clone(),
                };
                let at_ms = now_ms();
                let row = AskRecord::new(
                    Record::new(
                        journal::next_shared(bytes, &journal::read_chain(&directory)?)
                            .map_err(|_| unavailable())?,
                        input.text.clone(),
                        at_ms,
                        Attribution {
                            scope: scope.clone(),
                            actor: actor.clone(),
                            client_message_id: input.client_message_id.clone(),
                            client_message_created_at_ms: input.client_message_created_at_ms,
                        },
                    ),
                    &request,
                    &binding.fence,
                );
                let encoded = row.encoded().map_err(|_| unavailable())?;
                if bytes.len() as u64 + encoded.len() as u64 > HISTORY_LIMIT {
                    return Err(DispatchError::new(
                        "team_history_limit",
                        "This shared chat is full. Start another chat to continue.",
                    ));
                }
                journal
                    .reserve_ask(row, request.clone(), binding.clone(), bytes)
                    .map_err(|_| unavailable())?;
                if !directory.exists() {
                    fs::create_dir(&directory).map_err(|_| unavailable())?;
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
                            .map_err(|_| unavailable())?;
                    }
                }
                let source = index
                    .conversations
                    .iter_mut()
                    .find(|c| c.id == target.id)
                    .ok_or_else(unavailable)?;
                crate::chat_sessions::remember(&directory, source).map_err(|_| unavailable())?;
                source.resume_token = None;
                source.resume_tokens.clear();
                source.standing_sent.clear();
                // This independent barrier survives a missing or damaged journal.
                source.team_run_fence = Some(binding.fence.clone());
                self.write_team_index(&index)?;
                checkpoint(Step::Fenced)?;
                writer::save(&directory.join(writer::JOURNAL), &journal)?;
                // Set the initialized bit only after a durable journal exists.
                index
                    .conversations
                    .iter_mut()
                    .find(|c| c.id == target.id)
                    .ok_or_else(unavailable)?
                    .team_journal_initialized = true;
                self.write_team_index(&index)?;
                checkpoint(Step::Reserved)?;
                principal.ensure_account_current()?;
                current()?;
                writer.ensure_current().map_err(|_| changed())?;
                let mut canonical = bytes.to_vec();
                canonical.extend_from_slice(&encoded);
                replace_chat_file(&directory.join("events.ndjson"), &canonical)
                    .map_err(|_| unavailable())?;
                checkpoint(Step::Canonical)?;
                journal.observe(&canonical).map_err(|_| unavailable())?;
                writer::save(&directory.join(writer::JOURNAL), &journal)?;
                checkpoint(Step::Proven)?;
                self.record_comment_time(&mut index, target.id, at_ms)?;
                Ok(AskPreparation::New(Box::new(PreparedAsk {
                    source:writer::source(chat),
                    request,
                    binding,
                    context: AskContext {
                        title:history.title, backend:history.backend, history_trimmed:history.history_trimmed, events:history.events,
                        message:json!({"kind":"user","text":input.text,"mode":"ask","author":{"kind":"person","id":actor.id,"name":actor.name,"handle":actor.handle,"avatar":actor.avatar}}),
                        worktree: reviewed.worktree,
                    },
                    _runner: runner,
                    writer,
                    claimed:false,
                    actor:actor.clone(),
                })))
            },
        )
    }

    /// A caller which has never spawned a backend can close its own reserved
    /// attempt. This is unavailable for Launching/Running or a stale fence.
    pub(crate) fn refuse_prepared_ask(
        &self,
        target: SharedSource<'_>,
        mut prepared: PreparedAsk,
    ) -> Result<Value, DispatchError> {
        self.source_locked(
            target.workspace,
            target.id,
            false,
            |mut index, chat, bytes| {
                let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
                let mut journal = writer::load(&directory, chat, bytes)?.ok_or_else(unavailable)?;
                let record = journal
                    .run_status(
                        &prepared.request.scope,
                        &prepared.request.actor.person,
                        &prepared.request.client_message_id,
                    )
                    .map_err(|_| unavailable())?
                    .ok_or_else(unavailable)?;
                if record.state() != runs::State::Reserved
                    || record.request() != &prepared.request
                    || record.binding() != &prepared.binding
                    || record.canonical().is_none()
                    || writer::source(chat) != prepared.source
                    || chat.team_run_fence.as_ref() != Some(&prepared.binding.fence)
                {
                    return Err(unavailable());
                }
                journal
                    .transition_run(
                        &prepared.request,
                        &prepared.binding.fence,
                        runs::State::NotStarted,
                        now_ms(),
                    )
                    .map_err(|_| unavailable())?;
                writer::save(&directory.join(writer::JOURNAL), &journal)?;
                if prepared.claimed {
                    // No backend birth is possible while still Reserved.
                    // Durable NotStarted is written before releasing claims.
                    prepared
                        .writer
                        .clear_completed_run(prepared.binding.fence.incarnation())
                        .map_err(|_| unavailable())?;
                }
                index
                    .conversations
                    .iter_mut()
                    .find(|c| c.id == target.id)
                    .ok_or_else(unavailable)?
                    .team_run_fence = None;
                self.write_team_index(&index)?;
                Ok(result(
                    journal
                        .run_status(
                            &prepared.request.scope,
                            &prepared.request.actor.person,
                            &prepared.request.client_message_id,
                        )
                        .map_err(|_| unavailable())?
                        .ok_or_else(unavailable)?,
                ))
            },
        )
    }

    pub(crate) fn transition_owned_run(
        &self,
        target: SharedSource<'_>,
        prepared: &PreparedAsk,
        next: runs::State,
    ) -> Result<Value, DispatchError> {
        if next.terminal() {
            return Err(unavailable());
        }
        self.record_owned_run_state(target, prepared, next)
    }
    fn record_owned_run_state(
        &self,
        target: SharedSource<'_>,
        prepared: &PreparedAsk,
        next: runs::State,
    ) -> Result<Value, DispatchError> {
        self.source_locked(
            target.workspace,
            target.id,
            false,
            |mut index, chat, bytes| {
                let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
                let mut journal = writer::load(&directory, chat, bytes)?.ok_or_else(unavailable)?;
                let record = journal
                    .run_status(
                        &prepared.request.scope,
                        &prepared.request.actor.person,
                        &prepared.request.client_message_id,
                    )
                    .map_err(|_| unavailable())?
                    .ok_or_else(unavailable)?;
                if writer::source(chat) != prepared.source
                    || record.request() != &prepared.request
                    || record.binding() != &prepared.binding
                    || record.canonical().is_none()
                    || chat.team_run_fence.as_ref() != Some(&prepared.binding.fence)
                {
                    return Err(unavailable());
                }
                journal
                    .transition_run(&prepared.request, &prepared.binding.fence, next, now_ms())
                    .map_err(|_| unavailable())?;
                writer::save(&directory.join(writer::JOURNAL), &journal)?;
                let source = index
                    .conversations
                    .iter_mut()
                    .find(|c| c.id == target.id)
                    .ok_or_else(unavailable)?;
                source.running = matches!(
                    next,
                    runs::State::Launching | runs::State::Running | runs::State::Stopping
                );
                self.write_team_index(&index)?;
                Ok(result(
                    journal
                        .run_status(
                            &prepared.request.scope,
                            &prepared.request.actor.person,
                            &prepared.request.client_message_id,
                        )
                        .map_err(|_| unavailable())?
                        .ok_or_else(unavailable)?,
                ))
            },
        )
    }
    pub(crate) fn complete_owned_run(
        &self,
        target: SharedSource<'_>,
        mut prepared: PreparedAsk,
        _proof: crate::team_process::Completion,
        next: runs::State,
    ) -> Result<Value, DispatchError> {
        if !matches!(
            next,
            runs::State::Succeeded
                | runs::State::Failed
                | runs::State::Stopped
                | runs::State::NotStarted
        ) {
            return Err(unavailable());
        }
        let result = self.record_owned_run_state(
            SharedSource {
                workspace: target.workspace,
                id: target.id,
                preview: target.preview,
                revision: target.revision,
            },
            &prepared,
            next,
        )?;
        if prepared.claimed {
            prepared
                .writer
                .clear_completed_run(prepared.binding.fence.incarnation())
                .map_err(|_| unavailable())?;
        }
        self.source_locked(
            target.workspace,
            target.id,
            false,
            |mut index, chat, bytes| {
                let directory = safe_join(&self.root, target.id).map_err(|_| unavailable())?;
                let journal = writer::load(&directory, chat, bytes)?.ok_or_else(unavailable)?;
                let record = journal
                    .run_status(
                        &prepared.request.scope,
                        &prepared.request.actor.person,
                        &prepared.request.client_message_id,
                    )
                    .map_err(|_| unavailable())?
                    .ok_or_else(unavailable)?;
                if record.state() != next
                    || record.request() != &prepared.request
                    || record.binding() != &prepared.binding
                    || writer::source(chat) != prepared.source
                    || chat.team_run_fence.as_ref() != Some(&prepared.binding.fence)
                {
                    return Err(unavailable());
                }
                index
                    .conversations
                    .iter_mut()
                    .find(|c| c.id == target.id)
                    .ok_or_else(unavailable)?
                    .team_run_fence = None;
                self.write_team_index(&index)?;
                Ok(result)
            },
        )
    }
}

#[path = "asks/output.rs"]
mod output;

#[cfg(test)]
#[path = "asks/tests.rs"]
mod tests;
