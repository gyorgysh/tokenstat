// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{journal::*, *};
use crate::teams::AuthorizedTeamPrincipal;
use tokenstat_sync::teams::{RepositoryRole, TeamCapability};

pub(super) const JOURNAL: &str = "team-comments.json";

pub(crate) struct SharedSource<'a> {
    pub workspace: &'a str,
    pub id: &'a str,
    pub preview: &'a str,
    pub revision: Option<u64>,
}

fn unavailable() -> DispatchError {
    DispatchError::new(
        "team_comment_unavailable",
        "Comment delivery could not be verified. Keep your draft and check the chat before sending again.",
    )
}
pub(super) fn source(chat: &Conversation) -> Source {
    Source {
        conversation: chat.id.clone(),
        workspace: chat.workspace_id.clone(),
        created_at_ms: chat.created_at_ms,
    }
}
pub(super) fn context(
    principal: &AuthorizedTeamPrincipal,
    write: bool,
) -> Result<(Scope, Actor), DispatchError> {
    principal.ensure_account_current()?;
    let p = principal.value();
    let share = p
        .share_id
        .as_ref()
        .filter(|_| p.capabilities.contains(&TeamCapability::Read))
        .ok_or_else(paused)?;
    if write
        && (!p.capabilities.contains(&TeamCapability::Comment)
            || !matches!(
                p.role,
                RepositoryRole::Contributor | RepositoryRole::Maintainer
            ))
    {
        return Err(DispatchError::new(
            "team_comment_forbidden",
            "Contributor or Maintainer access is required to comment.",
        ));
    }
    Ok((
        Scope {
            issuer: principal.issuer().into(),
            organization: p.organization_id.clone(),
            repository: p.repository_id.clone(),
            checkout: p.checkout_id.clone(),
            share: share.clone(),
        },
        Actor {
            id: p.person.id.clone(),
            device: p.device_key.clone(),
            name: p.person.name.clone(),
            handle: p.person.handle.clone(),
            avatar: p.person.avatar.clone(),
        },
    ))
}

pub(super) fn save(path: &Path, journal: &Journal) -> Result<(), DispatchError> {
    replace_chat_file(path, &journal.encoded().map_err(|_| unavailable())?)
        .map_err(|_| unavailable())
}

/// The caller already holds source acceptance, lifecycle and transcript locks.
/// Settling an exact row is bookkeeping; no reader appends a missing comment.
pub(super) fn load(
    directory: &Path,
    chat: &Conversation,
    bytes: &[u8],
) -> Result<Option<Journal>, DispatchError> {
    let path = directory.join(JOURNAL);
    match fs::symlink_metadata(&path) {
        Err(error)
            if error.kind() == std::io::ErrorKind::NotFound && !chat.team_journal_initialized =>
        {
            return Ok(None);
        }
        Err(_) => return Err(unavailable()),
        Ok(_) => {}
    }
    let mut journal = Journal::decode(
        &read_private(&path, MAX_JOURNAL_BYTES, false).map_err(|_| unavailable())?,
        &source(chat),
    )
    .map_err(|_| unavailable())?;
    if journal.observe(bytes).map_err(|_| unavailable())? {
        save(&path, &journal)?;
    }
    Ok(Some(journal))
}

/// Recovery must remain available even when receipts are damaged. When they
/// are healthy, settle a written row or retire a provably unwritten intent
/// before private writers can continue beyond its reserved position.
pub(super) fn stop_journal(directory: &Path, chat: &Conversation) {
    let result = (|| {
        let bytes = read_private(
            &directory.join("events.ndjson"),
            HISTORY_LIMIT,
            chat.last_message_at_ms.is_none(),
        )?;
        if let Some(mut journal) = load(directory, chat, &bytes)?
            && journal
                .retire_unwritten(&bytes)
                .map_err(|_| unavailable())?
        {
            save(&directory.join(JOURNAL), &journal)?;
        }
        Ok::<_, DispatchError>(())
    })();
    // A failed journal cannot grant shared access after the canonical marker
    // is cleared. Keep it for repair rather than replacing it with emptiness.
    let _ = result;
}

pub(crate) fn fork_journal(
    source_dir: &Path,
    original: &Conversation,
    destination: &Path,
    fork: &Conversation,
    bytes: &[u8],
) -> Result<bool, String> {
    if let Some(journal) = load(source_dir, original, bytes).map_err(|error| error.to_string())? {
        save(&destination.join(JOURNAL), &journal.forked(source(fork)))
            .map_err(|error| error.to_string())?;
        return Ok(true);
    }
    Ok(false)
}

fn receipt(scope: &Scope, message: &str, status: Option<Status>) -> Value {
    let (state, seq, at) = match status {
        None => ("unknown", None, None),
        Some(Status::Pending) => ("pending", None, None),
        Some(Status::NotAccepted) => ("notAccepted", None, None),
        Some(Status::Accepted { seq, at_ms }) => ("accepted", Some(seq), Some(at_ms)),
    };
    json!({"receipt":{"shareId":scope.share,"clientMessageId":message,"state":state,"sequence":seq,"acceptedAtMs":at}})
}

#[derive(Clone, Copy)]
enum Step {
    Initialized,
    Reserved,
    Canonical,
    Accepted,
}

impl Store {
    pub(super) fn write_team_index(&self, index: &Index) -> Result<(), DispatchError> {
        let bytes = serde_json::to_vec(index).map_err(|_| unavailable())?;
        if bytes.len() as u64 > INDEX_LIMIT {
            return Err(unavailable());
        }
        replace_chat_file(&self.root.join("conversations.json"), &bytes)
            .map_err(|_| unavailable())?;
        *self.conversations.lock().map_err(|_| unavailable())? = index.conversations.clone();
        Ok(())
    }
    pub(super) fn record_comment_time(
        &self,
        index: &mut Index,
        id: &str,
        at_ms: i64,
    ) -> Result<(), DispatchError> {
        let chat = index
            .conversations
            .iter_mut()
            .find(|chat| chat.id == id)
            .ok_or_else(unavailable)?;
        let before = (
            chat.last_message_at_ms,
            chat.last_message_author.clone(),
            chat.updated_at_ms,
        );
        if chat
            .last_message_at_ms
            .is_none_or(|previous| previous <= at_ms)
        {
            chat.last_message_at_ms = Some(at_ms);
            chat.last_message_author = Some("user".into());
        }
        chat.updated_at_ms = chat.updated_at_ms.max(at_ms);
        if before
            == (
                chat.last_message_at_ms,
                chat.last_message_author.clone(),
                chat.updated_at_ms,
            )
        {
            return Ok(());
        }
        self.write_team_index(index)
    }

    /// `current` checks the exact publication/folder snapshot without HTTP.
    /// It runs under source acceptance immediately before canonical mutation.
    pub(crate) fn team_comment(
        &self,
        target: SharedSource<'_>,
        principal: &AuthorizedTeamPrincipal,
        input: &CommentInput,
        current: impl FnMut() -> Result<(), DispatchError>,
    ) -> Result<Value, DispatchError> {
        self.team_comment_steps(target, principal, input, current, |_| Ok(()))
    }

    fn team_comment_steps(
        &self,
        target: SharedSource<'_>,
        principal: &AuthorizedTeamPrincipal,
        input: &CommentInput,
        mut current: impl FnMut() -> Result<(), DispatchError>,
        mut checkpoint: impl FnMut(Step) -> Result<(), DispatchError>,
    ) -> Result<Value, DispatchError> {
        let SharedSource {
            workspace,
            id,
            preview,
            revision: source_revision,
        } = target;
        input.validate()?;
        let (scope, actor) = context(principal, true)?;
        self.source_locked(workspace, id, false, |mut index, chat, bytes| {
            principal.ensure_account_current()?; current()?;
            let marker = chat.team_share.as_ref().ok_or_else(paused)?;
            if source_revision.is_none() || marker.source_revision != source_revision || marker.id != scope.share || marker.initial_fingerprint != preview { return Err(paused()); }
            let directory = safe_join(&self.root, id).map_err(|_| unavailable())?;
            let loaded = load(&directory, chat, bytes)?;
            shared_project(chat, bytes, &scope.share, preview, loaded.as_ref())?;
            let mut journal = loaded.unwrap_or_else(|| Journal::new(source(chat)));
            let seq = crate::work_transcript_identity::next_sequence(bytes, 0).map_err(|_| unavailable())?;
            let proposed = Record::new(seq, input.text.clone(), now_ms(), Attribution { scope: scope.clone(), actor: actor.clone(), client_message_id: input.client_message_id.clone(), client_message_created_at_ms: input.client_message_created_at_ms });
            proposed.encoded().map_err(|_| unavailable())?;
            if let Some(known) = journal.receipt(&proposed).map_err(|_| DispatchError::new("team_comment_conflict", "This comment changed after its first attempt. Check the chat before sending again."))? {
                if let Receipt::Accepted { at_ms, .. } = known { self.record_comment_time(&mut index, id, *at_ms)?; }
                principal.ensure_account_current()?; current()?;
                return Ok(receipt(&scope, &input.client_message_id, journal.status(&scope, &actor.id, &input.client_message_id).map_err(|_| unavailable())?));
            }
            crate::chat_receipts::validate_created_at(Some(input.client_message_created_at_ms), now_ms())?;
            let record = if let Some(pending) = journal.pending_record(&proposed, bytes).map_err(|_| unavailable())? { pending.clone() }
                else {
                    journal.retire_unwritten(bytes).map_err(|_| unavailable())?;
                    proposed
                };
            let encoded = record.encoded().map_err(|_| unavailable())?;
            if bytes.len() as u64 + encoded.len() as u64 > HISTORY_LIMIT {
                return Err(DispatchError::new("team_history_limit", "This shared chat is full. Start another chat to continue."));
            }
            if !directory.exists() {
                let mut builder = fs::DirBuilder::new();
                #[cfg(unix)] { use std::os::unix::fs::DirBuilderExt; builder.mode(0o700); }
                builder.create(&directory).map_err(|_| unavailable())?;
            }
            let path = directory.join(JOURNAL);
            if !chat.team_journal_initialized {
                save(&path, &journal)?;
                let source = index.conversations.iter_mut().find(|chat| chat.id == id).ok_or_else(unavailable)?;
                crate::chat_sessions::remember(&directory, source).map_err(|_| unavailable())?;
                source.team_journal_initialized = true;
                // Future turns must rebuild the visible conversation. The old
                // private provider continuation is retained only in inspection.
                source.resume_token = None; source.resume_tokens.clear(); source.standing_sent.clear();
                self.write_team_index(&index)?;
            }
            checkpoint(Step::Initialized)?;
            if journal.pending_record(&record, bytes).map_err(|_| unavailable())?.is_none() { journal.reserve(record.clone(), bytes).map_err(|_| unavailable())?; }
            save(&path, &journal)?;
            checkpoint(Step::Reserved)?;
            principal.ensure_account_current()?; current()?;
            let mut canonical = bytes.to_vec(); canonical.extend_from_slice(&encoded);
            replace_chat_file(&directory.join("events.ndjson"), &canonical).map_err(|_| unavailable())?;
            checkpoint(Step::Canonical)?;
            journal.observe(&canonical).map_err(|_| unavailable())?; save(&path, &journal)?;
            checkpoint(Step::Accepted)?;
            self.record_comment_time(&mut index, id, record.at_ms)?;
            principal.ensure_account_current()?; current()?;
            Ok(receipt(&scope, &input.client_message_id, journal.status(&scope, &actor.id, &input.client_message_id).map_err(|_| unavailable())?))
        })
    }

    pub(crate) fn team_comment_status(
        &self,
        workspace: &str,
        id: &str,
        preview: &str,
        principal: &AuthorizedTeamPrincipal,
        message: &str,
    ) -> Result<Value, DispatchError> {
        if !crate::chat_receipts::valid_id(message) {
            return Err(unavailable());
        }
        let (scope, actor) = context(principal, false)?;
        self.source_locked(workspace, id, false, |mut index, chat, bytes| {
            let directory = safe_join(&self.root, id).map_err(|_| unavailable())?;
            let journal = load(&directory, chat, bytes)?;
            shared_project(chat, bytes, &scope.share, preview, journal.as_ref())?;
            principal.ensure_account_current()?;
            let status = journal
                .as_ref()
                .map(|journal| journal.status(&scope, &actor.id, message))
                .transpose()
                .map_err(|_| unavailable())?
                .flatten();
            if let Some(Status::Accepted { at_ms, .. }) = &status {
                self.record_comment_time(&mut index, id, *at_ms)?;
            }
            Ok(receipt(&scope, message, status))
        })
    }
}

#[cfg(test)]
#[path = "writer/tests.rs"]
mod tests;
