// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! A sharing preview is a projection of visible history, never serialized
//! conversation state or the backend's raw/session files.

use super::*;
use sha2::{Digest, Sha256};

#[path = "chat_sharing/asks.rs"]
mod asks;
#[path = "chat_sharing/journal.rs"]
mod journal;
#[path = "chat_sharing/writer.rs"]
mod writer;
pub(crate) use crate::remote::TeamCommentInput as CommentInput;
pub(crate) use asks::{AskInput, AskPreparation};
pub(crate) use journal::{PageRequest, chain_usage};

#[cfg(test)]
pub(crate) fn select_inline_page(
    events: &[serde_json::Value],
    request: &PageRequest,
) -> Result<(Vec<serde_json::Value>, bool), DispatchError> {
    let page = journal::select_page(std::path::Path::new("."), &[], None, events, request)?;
    Ok((page.events, page.has_more))
}
pub(crate) use writer::SharedSource;
pub(super) use writer::fork_journal;

const INDEX_LIMIT: u64 = 16 * 1024 * 1024;
const HISTORY_LIMIT: u64 =
    PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct ApprovedMetadata {
    pub(crate) title: String,
    pub(crate) backend: String,
}
impl ApprovedMetadata {
    pub(crate) fn valid(&self) -> bool {
        self.title.chars().count() <= 512 && self.backend.chars().count() <= 64
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Binding {
    pub(crate) id: String,
    pub(crate) history_through: Option<u64>,
    pub(crate) history_bytes: u64,
    pub(crate) initial_fingerprint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) source_revision: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) approved: Option<ApprovedMetadata>,
}

pub(crate) struct EventPage {
    pub events: Vec<Value>,
    pub has_more: bool,
    pub history_trimmed: bool,
    pub binding: Binding,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct History {
    pub(crate) title: String,
    pub(crate) backend: String,
    pub(crate) history_trimmed: bool,
    pub(crate) events: Vec<Value>,
    #[serde(skip_serializing)]
    pub(crate) fingerprint: String,
    #[serde(skip_serializing)]
    pub(crate) history_through: Option<u64>,
    #[serde(skip_serializing)]
    pub(crate) history_bytes: u64,
    #[serde(skip_serializing)]
    pub(crate) source_revision: u64,
    #[serde(skip_serializing)]
    pub(crate) binding: Option<Binding>,
}

fn invalid() -> DispatchError {
    DispatchError::new(
        "chat_history_unavailable",
        "This chat's history could not be reviewed. Repair it before sharing.",
    )
}
fn reparse_or_link(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            // FILE_ATTRIBUTE_REPARSE_POINT
            return true;
        }
    }
    metadata.file_type().is_symlink()
}
fn read_private(path: &Path, limit: u64, allow_missing: bool) -> Result<Vec<u8>, DispatchError> {
    use std::io::Read;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if allow_missing && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Vec::new());
        }
        Err(_) => return Err(invalid()),
    };
    let metadata = file.metadata().map_err(|_| invalid())?;
    if !metadata.is_file() || reparse_or_link(&metadata) || metadata.len() > limit {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() as u64 > limit {
        return Err(invalid());
    }
    Ok(bytes)
}

impl Store {
    pub(crate) fn sharing_binding(
        &self,
        workspace: &str,
        id: &str,
    ) -> Result<Option<Binding>, DispatchError> {
        self.sharing_state(workspace, id)
            .map(|(binding, _)| binding)
    }

    pub(crate) fn sharing_state(
        &self,
        workspace: &str,
        id: &str,
    ) -> Result<(Option<Binding>, u64), DispatchError> {
        self.index_locked(workspace, id, |_, chat| {
            Ok((chat.team_share.clone(), chat.send_revision))
        })
    }

    /// The unresolved Team run holding this chat, if any.
    pub(crate) fn team_run_fence(
        &self,
        workspace: &str,
        id: &str,
    ) -> Result<Option<crate::chat_receipts::team_runs::Fence>, DispatchError> {
        self.index_locked(workspace, id, |_, chat| Ok(chat.team_run_fence.clone()))
    }

    pub(crate) fn ensure_sharing_snapshot(
        &self,
        workspace: &str,
        id: &str,
        expected: &Binding,
    ) -> Result<(), DispatchError> {
        self.index_locked(workspace, id, |_, chat| {
            if chat.team_share.as_ref() != Some(expected) {
                return Err(paused());
            }
            Ok(())
        })
    }

    /// A catalog reads canonical metadata once for its bounded candidate page.
    /// There is no transcript read or per-row lifecycle/acceptance lock cycle.
    pub(crate) fn sharing_bindings(
        &self,
        workspace: &str,
        candidates: &[String],
    ) -> Result<HashMap<String, Binding>, DispatchError> {
        if candidates.len() > 100 {
            return Err(invalid());
        }
        if candidates.is_empty() {
            return Ok(HashMap::new());
        }
        for id in candidates {
            validate_record_id(id).map_err(|_| invalid())?;
        }
        let wanted: std::collections::HashSet<_> = candidates.iter().map(String::as_str).collect();
        let _lifecycle =
            crate::work_handoff_store::lifecycle_lock(&self.root).map_err(|_| invalid())?;
        let index: Index = serde_json::from_slice(&read_private(
            &self.root.join("conversations.json"),
            INDEX_LIMIT,
            false,
        )?)
        .map_err(|_| invalid())?;
        let mut result = HashMap::new();
        let mut seen = std::collections::HashSet::new();
        for chat in index
            .conversations
            .iter()
            .filter(|chat| chat.workspace_id == workspace && wanted.contains(chat.id.as_str()))
        {
            if !seen.insert(&chat.id) {
                return Err(invalid());
            }
            if let Some(binding) = &chat.team_share {
                result.insert(chat.id.clone(), binding.clone());
            }
        }
        Ok(result)
    }

    pub(crate) fn sharing_history(
        &self,
        workspace: &str,
        id: &str,
    ) -> Result<History, DispatchError> {
        self.review_locked(workspace, id, |_, history| Ok(history))
    }

    #[cfg(test)]
    pub(crate) fn freeze_sharing(
        &self,
        workspace: &str,
        id: &str,
        share: &str,
        expected: &str,
    ) -> Result<(), DispatchError> {
        let chat = self.current_send_conversation(id).map_err(|_| invalid())?;
        let revision = chat
            .team_share
            .as_ref()
            .and_then(|binding| binding.source_revision)
            .unwrap_or(chat.send_revision);
        self.freeze_sharing_if_current(workspace, id, share, expected, revision, || Ok(()))
    }

    pub(crate) fn freeze_sharing_if_current(
        &self,
        workspace: &str,
        id: &str,
        share: &str,
        expected: &str,
        source_revision: u64,
        current: impl FnOnce() -> Result<(), DispatchError>,
    ) -> Result<(), DispatchError> {
        if !share.strip_prefix("share_").is_some_and(|suffix| {
            suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
        }) {
            return Err(invalid());
        }
        self.review_locked(workspace, id, |mut index, history| {
            // This check belongs under source acceptance. A local withdrawal
            // that already cleared this marker must prevent a delayed
            // publisher from freezing the source again after recovery's ACK.
            current()?;
            if history.fingerprint != expected {
                return Err(DispatchError::new(
                    "chat_history_changed",
                    "This chat changed after its sharing preview. Review the history again.",
                ));
            }
            let chat = index
                .conversations
                .iter_mut()
                .find(|chat| chat.id == id && chat.workspace_id == workspace)
                .ok_or_else(invalid)?;
            match chat.team_share.as_ref() {
                Some(current)
                    if current.id == share
                        && current.initial_fingerprint == expected
                        && current.source_revision == Some(source_revision) =>
                {
                    return Ok(());
                }
                Some(_) => {
                    return Err(DispatchError::new(
                        "chat_already_shared",
                        "This chat already has a different sharing record.",
                    ));
                }
                None => {}
            }
            if chat.send_revision != source_revision {
                return Err(DispatchError::new(
                    "chat_history_changed",
                    "This chat changed after its sharing preview. Review the history again.",
                ));
            }
            chat.team_share = Some(Binding {
                id: share.into(),
                history_through: history.history_through,
                history_bytes: history.history_bytes,
                initial_fingerprint: expected.into(),
                source_revision: Some(source_revision),
                approved: Some(ApprovedMetadata {
                    title: history.title.chars().take(512).collect(),
                    backend: history.backend.chars().take(64).collect(),
                }),
            });
            chat.send_revision = next_send_revision(chat.send_revision).map_err(|_| invalid())?;
            chat.updated_at_ms = now_ms();
            replace_chat_file(
                &self.root.join("conversations.json"),
                &serde_json::to_vec(&index).map_err(|_| invalid())?,
            )
            .map_err(|_| invalid())?;
            *self.conversations.lock().map_err(|_| invalid())? = index.conversations;
            Ok(())
        })
    }

    pub(crate) fn clear_sharing(
        &self,
        workspace: &str,
        id: &str,
        share: &str,
    ) -> Result<(), DispatchError> {
        self.clear_sharing_at_revision(workspace, id, share, None)
    }

    /// Canonical-only recovery is safe even if the publication journal was
    /// lost. Clearing increments source acceptance: a backed-up prepared
    /// publication cannot freeze this source again with the old consent.
    pub(crate) fn clear_sharing_at_revision(
        &self,
        workspace: &str,
        id: &str,
        share: &str,
        expected: Option<u64>,
    ) -> Result<(), DispatchError> {
        validate_record_id(id).map_err(|_| invalid())?;
        let _acceptance =
            crate::chat_receipts::Operation::conversation(&self.root, id).map_err(|_| invalid())?;
        let lifecycle =
            crate::work_handoff_store::lifecycle_lock(&self.root).map_err(|_| invalid())?;
        let _transcript = self.transcript_guard().map_err(|_| invalid())?;
        let mut run_blocked = false;
        self.edit_index_locked(&lifecycle, false, |_, current| {
            let chat = current
                .iter_mut()
                .find(|chat| chat.id == id && chat.workspace_id == workspace)
                .ok_or("This chat is no longer in that checkout.")?;
            if chat.team_run_fence.is_some() {
                run_blocked = true;
                return Err("This chat has an unresolved Team run. Stop or recover it on the publishing computer before continuing.".into());
            }
            match chat.team_share.as_ref() {
                None => match expected {
                    None => return Ok(()),
                    // An earlier stop or another accepted local change already
                    // fenced the old consent. Retrying must not fence a newer
                    // source revision or overwrite a new sharing marker.
                    Some(revision) if revision < chat.send_revision => return Ok(()),
                    Some(revision) if revision == chat.send_revision => {}
                    Some(_) => {
                        return Err("This chat changed. Refresh sharing before stopping it.".into());
                    }
                },
                Some(current) if current.id == share => {}
                Some(_) => {
                    return Err(
                        "This chat has a different sharing record. Refresh before changing it."
                            .into(),
                    );
                }
            }
            if expected.is_some_and(|revision| revision != chat.send_revision) {
                return Err("This chat changed. Refresh sharing before stopping it.".into());
            }
            if let Ok(directory) = safe_join(&self.root, id) {
                writer::stop_journal(&directory, chat);
            }
            chat.team_share = None;
            chat.send_revision = next_send_revision(chat.send_revision)?;
            chat.updated_at_ms = now_ms();
            Ok(())
        })
        .map_err(|_| {
            if run_blocked {
                run_recovery_required()
            } else {
                invalid()
            }
        })
    }

    pub(crate) fn require_private_chat(&self, id: &str) -> Result<(), DispatchError> {
        // Leave missing-resource behavior to the original operation. Existing
        // records are checked against disk so another process's conversion
        // cannot be bypassed through an older in-memory copy.
        if self.get(id).is_err() {
            return Ok(());
        }
        let chat = self.current_send_conversation(id).map_err(|_| invalid())?;
        require_personal_send(&chat)
    }

    /// Guest reads verify the canonical conversion marker and approved bytes.
    /// They never borrow the physical owner's private-history preview path.
    pub(crate) fn shared_history(
        &self,
        workspace: &str,
        id: &str,
        share: &str,
        expected: &str,
    ) -> Result<History, DispatchError> {
        self.source_locked(workspace, id, false, |_, chat, bytes| {
            let directory = safe_join(&self.root, id).map_err(|_| invalid())?;
            let journal = writer::load(&directory, chat, bytes)?;
            shared_project(
                chat,
                bytes,
                share,
                expected,
                journal.as_ref(),
                &directory,
                true,
            )
        })
    }

    /// One shared-history page. Payload files outside the page stay unread.
    pub(crate) fn shared_event_page(
        &self,
        workspace: &str,
        id: &str,
        share: &str,
        expected: &str,
        request: &PageRequest,
    ) -> Result<EventPage, DispatchError> {
        self.source_locked(workspace, id, false, |_, chat, bytes| {
            let directory = safe_join(&self.root, id).map_err(|_| invalid())?;
            let journal = writer::load(&directory, chat, bytes)?;
            let history = shared_project(
                chat,
                bytes,
                share,
                expected,
                journal.as_ref(),
                &directory,
                false,
            )?;
            let page = journal::select_page(
                &directory,
                &journal::read_chain(&directory)?,
                journal.as_ref(),
                &history.events,
                request,
            )?;
            Ok(EventPage {
                events: page.events,
                has_more: page.has_more,
                history_trimmed: history.history_trimmed,
                binding: history.binding.ok_or_else(paused)?,
            })
        })
    }

    fn review_locked<T>(
        &self,
        workspace: &str,
        id: &str,
        operation: impl FnOnce(Index, History) -> Result<T, DispatchError>,
    ) -> Result<T, DispatchError> {
        self.source_locked(workspace, id, true, |index, chat, bytes| {
            let directory = safe_join(&self.root, id).map_err(|_| invalid())?;
            let journal = writer::load(&directory, chat, bytes)?;
            let history = if let Some(marker) = &chat.team_share {
                shared_project(
                    chat,
                    bytes,
                    &marker.id,
                    &marker.initial_fingerprint,
                    journal.as_ref(),
                    &directory,
                    true,
                )?
            } else {
                project_with_journal(chat, bytes, journal.as_ref())?
            };
            operation(index, history)
        })
    }

    fn source_locked<T>(
        &self,
        workspace: &str,
        id: &str,
        require_idle: bool,
        operation: impl FnOnce(Index, &Conversation, &[u8]) -> Result<T, DispatchError>,
    ) -> Result<T, DispatchError> {
        self.index_locked(workspace, id, |index, chat| {
            let _transcript = self.transcript_guard().map_err(|_| invalid())?;
            if require_idle
                && (chat.team_run_fence.is_some() || chat.running || self.active.lock().map_err(|_| invalid())?.contains_key(id))
            {
                return Err(DispatchError::new(
                    "chat_running",
                    "Finish or stop this chat's current turn before sharing its history.",
                ));
            }
            let _runner = if require_idle {
                Some(
                    crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)
                        .map_err(|_| invalid())?
                        .ok_or_else(|| DispatchError::new("chat_running", "Finish or stop this chat's current turn before sharing its history."))?,
                )
            } else { None };
            let directory = safe_join(&self.root, id).map_err(|_| invalid())?;
            // A bounded regular leaf is insufficient if a conversation's
            // directory was replaced with a symlink or Windows reparse point.
            match fs::symlink_metadata(&directory) {
                Ok(metadata) if metadata.is_dir() && !reparse_or_link(&metadata) => {}
                Err(error) if error.kind()==std::io::ErrorKind::NotFound && chat.last_message_at_ms.is_none() => {}
                _ => return Err(invalid()),
            }
            let bytes = read_private(&directory.join("events.ndjson"), HISTORY_LIMIT, chat.last_message_at_ms.is_none())?;
            operation(index, chat, &bytes)
        })
    }

    fn index_locked<T>(
        &self,
        workspace: &str,
        id: &str,
        operation: impl FnOnce(Index, &Conversation) -> Result<T, DispatchError>,
    ) -> Result<T, DispatchError> {
        validate_record_id(id).map_err(|_| invalid())?;
        let _acceptance =
            crate::chat_receipts::Operation::conversation(&self.root, id).map_err(|_| invalid())?;
        let _lifecycle =
            crate::work_handoff_store::lifecycle_lock(&self.root).map_err(|_| invalid())?;
        let index: Index = serde_json::from_slice(&read_private(
            &self.root.join("conversations.json"),
            INDEX_LIMIT,
            false,
        )?)
        .map_err(|_| invalid())?;
        let chat = index
            .conversations
            .iter()
            .find(|chat| chat.id == id && chat.workspace_id == workspace)
            .ok_or_else(invalid)?;
        let chat = chat.clone();
        operation(index, &chat)
    }
}

fn paused() -> DispatchError {
    DispatchError::new(
        "chat_sharing_paused",
        "This chat changed outside its shared view. Ask its publisher to review sharing.",
    )
}

pub(super) fn require_personal_send(chat: &Conversation) -> Result<(), DispatchError> {
    if chat.team_run_fence.is_some() {
        return Err(run_recovery_required());
    }
    if chat.team_share.is_some() {
        return Err(DispatchError::new(
            "shared_chat_requires_team",
            "This chat is shared with a team. Open its shared view before changing it.",
        ));
    }
    Ok(())
}
fn run_recovery_required() -> DispatchError {
    DispatchError::new(
        "team_run_recovery_required",
        "This chat has an unresolved Team run. Stop or recover it on the publishing computer before continuing.",
    )
}

#[cfg(test)]
fn project(chat: &Conversation, bytes: &[u8]) -> Result<History, DispatchError> {
    project_with_journal(chat, bytes, None)
}

fn merge_events(mut events: Vec<Value>, extra: Vec<Value>) -> Result<Vec<Value>, DispatchError> {
    events.extend(extra);
    events.sort_by_key(|event| event["seq"].as_u64().unwrap_or(u64::MAX));
    let mut previous = None;
    for event in &events {
        let seq = event["seq"].as_u64().ok_or_else(paused)?;
        if previous.is_some_and(|seen| seq <= seen) {
            return Err(paused());
        }
        previous = Some(seq);
    }
    Ok(events)
}

fn shared_project(
    chat: &Conversation,
    bytes: &[u8],
    share: &str,
    expected: &str,
    journal: Option<&journal::Journal>,
    directory: &Path,
    expand: bool,
) -> Result<History, DispatchError> {
    let marker = chat.team_share.as_ref().ok_or_else(paused)?;
    if marker.id != share || marker.initial_fingerprint != expected {
        return Err(paused());
    }
    let boundary = usize::try_from(marker.history_bytes).map_err(|_| paused())?;
    let prefix = bytes.get(..boundary).ok_or_else(paused)?;
    let initial = project_with_journal(chat, prefix, journal)?;
    if initial.fingerprint != marker.initial_fingerprint
        || initial.history_through != marker.history_through
    {
        return Err(paused());
    }
    let mut seen = std::collections::HashSet::new();
    let mut position = boundary;
    for line in bytes[boundary..].split_inclusive(|b| *b == b'\n') {
        let raw: Value = serde_json::from_slice(line).map_err(|_| paused())?;
        let seq = crate::work_transcript_identity::sequence(
            raw.as_object().ok_or_else(paused)?,
            position as u64,
        )
        .map_err(|_| paused())?;
        position += line.len();
        let proof = journal
            .ok_or_else(paused)?
            .author(&raw, seq)
            .map_err(|_| paused())?
            .ok_or_else(paused)?;
        if proof.scope.share != share {
            return Err(paused());
        }
        seen.insert(proof.key);
    }
    if let Some(journal) = journal {
        journal
            .require_complete(share, &seen)
            .map_err(|_| paused())?;
    }
    let mut history = project_with_journal(chat, bytes, journal)?;
    let chain = journal::read_chain(directory)?;
    match journal {
        Some(journal) if expand => {
            history.events = merge_events(
                history.events,
                journal::project_chain(directory, &chain, journal)?,
            )?;
        }
        Some(journal) => journal::accept_chain(&chain, journal)?,
        None if !chain.is_empty() => return Err(paused()),
        None => {}
    }
    if let Some(seq) = history
        .events
        .last()
        .and_then(|event| event["seq"].as_u64())
    {
        history.history_through = Some(seq);
    }
    history.fingerprint = initial.fingerprint;
    history.binding = Some(marker.clone());
    Ok(history)
}

fn project_with_journal(
    chat: &Conversation,
    bytes: &[u8],
    journal: Option<&journal::Journal>,
) -> Result<History, DispatchError> {
    let mut events = Vec::new();
    let mut offset = 0;
    let mut history_through = None;
    for line in bytes.split_inclusive(|b| *b == b'\n') {
        let position = offset;
        offset += line.len() as u64;
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let mut raw: Value = serde_json::from_slice(line).map_err(|_| invalid())?;
        let sequence = crate::work_transcript_identity::sequence(
            raw.as_object().ok_or_else(invalid)?,
            position,
        )
        .map_err(|_| invalid())?;
        if history_through.is_some_and(|previous| sequence <= previous) {
            return Err(invalid());
        }
        history_through = Some(sequence);
        if raw["kind"] == "retainedUsage" {
            continue;
        }
        let author = journal
            .map(|journal| journal.author(&raw, sequence))
            .transpose()
            .map_err(|_| paused())?
            .flatten();
        stored_aliases(raw.as_object_mut().ok_or_else(invalid)?);
        if let Some(Value::Object(agent)) = raw.get_mut("event") {
            stored_aliases(agent);
        }
        let event: StoredEvent = serde_json::from_value(raw.clone()).map_err(|_| invalid())?;
        if matches!(
            &event,
            StoredEvent::Agent {
                event: Event::Session { .. },
                ..
            }
        ) {
            // Session announcements contain vendor continuation identities.
            // They are not shared transcript content.
            continue;
        }
        let mut value = visible(event)?;
        if let Some(author) = author {
            value["author"] = author.person;
            value["mode"] = json!(author.mode);
        }
        value["seq"] = json!(sequence);
        events.push(value);
    }
    // Bind the source and the reviewed content. Private backend state is not
    // part of the shared view or its consent fingerprint. Converting the chat
    // can update its private sharing marker without changing this review.
    let source = json!({"v":1,"source":chat.id,"workspace":chat.workspace_id,"createdAtMs":chat.created_at_ms,
        "title":chat.title,"backend":chat.backend,"historyDigest":tokenstat_identity::hex(&Sha256::digest(bytes))});
    let fingerprint = tokenstat_identity::hex(&Sha256::digest(
        serde_json::to_vec(&source).map_err(|_| invalid())?,
    ));
    Ok(History {
        title: chat.title.clone(),
        backend: chat.backend.clone(),
        history_trimmed: retained_prefix(bytes, 0),
        events,
        fingerprint,
        history_through,
        history_bytes: bytes.len() as u64,
        binding: None,
        source_revision: chat
            .team_share
            .as_ref()
            .and_then(|binding| binding.source_revision)
            .unwrap_or(chat.send_revision),
    })
}

fn visible(event: StoredEvent) -> Result<Value, DispatchError> {
    let mut value = match event {
        // Generated briefs contain host archive and native session inventory
        // references. The shared history keeps the provider transition and
        // the original messages, without exporting continuation machinery.
        StoredEvent::Handoff { to, at_ms, .. } => json!({"kind":"handoff","to":to,"atMs":at_ms}),
        StoredEvent::Approval { approval, at_ms } => {
            json!({"kind":"approval","atMs":at_ms,"approval":{
            "id":approval.id,"verb":approval.verb,"preview":approval.preview,"createdAtMs":approval.created_at_ms,
            "expiresAtMs":approval.expires_at_ms,"decision":approval.decision,"readOnly":true}})
        }
        other => serde_json::to_value(other).map_err(|_| invalid())?,
    };
    let object = value.as_object_mut().ok_or_else(invalid)?;
    alias(object);
    for (from, _) in ALIASES {
        object.remove(from);
    }
    if object.get("kind").and_then(Value::as_str) == Some("user") {
        object.insert("author".into(), json!({"kind":"localBeforeTeams"}));
    }
    if let Some(Value::Object(agent)) = object.get_mut("event") {
        alias(agent);
        for (from, _) in ALIASES {
            agent.remove(from);
        }
    }
    // The output has only the fields declared by StoredEvent/Event and the
    // approval projection above. Unknown raw/backend fields were discarded.
    Ok(value)
}

fn stored_aliases(object: &mut serde_json::Map<String, Value>) {
    for (stored, wire) in ALIASES {
        if !object.contains_key(stored)
            && let Some(value) = object.get(wire).cloned()
        {
            object.insert(stored.into(), value);
        }
    }
}

#[cfg(test)]
#[path = "chat_sharing/tests.rs"]
mod tests;
