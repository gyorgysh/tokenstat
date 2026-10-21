// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! A sharing preview is a projection of visible history, never serialized
//! conversation state or the backend's raw/session files.

use super::*;
use sha2::{Digest, Sha256};

const INDEX_LIMIT: u64 = 16 * 1024 * 1024;
const HISTORY_LIMIT: u64 =
    PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Binding {
    pub(crate) id: String,
    pub(crate) history_through: Option<u64>,
    pub(crate) history_bytes: u64,
    pub(crate) initial_fingerprint: String,
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
}

fn invalid() -> DispatchError {
    DispatchError::new(
        "chat_history_unavailable",
        "This chat's history could not be reviewed. Repair it before sharing.",
    )
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
    if !metadata.is_file() || metadata.len() > limit {
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
    pub(crate) fn sharing_history(
        &self,
        workspace: &str,
        id: &str,
    ) -> Result<History, DispatchError> {
        self.review_locked(workspace, id, |_, history| Ok(history))
    }

    pub(crate) fn freeze_sharing(
        &self,
        workspace: &str,
        id: &str,
        share: &str,
        expected: &str,
    ) -> Result<(), DispatchError> {
        if !share.strip_prefix("share_").is_some_and(|suffix| {
            suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
        }) {
            return Err(invalid());
        }
        self.review_locked(workspace, id, |mut index, history| {
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
                Some(current) if current.id == share && current.initial_fingerprint == expected => {
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
            chat.team_share = Some(Binding {
                id: share.into(),
                history_through: history.history_through,
                history_bytes: history.history_bytes,
                initial_fingerprint: expected.into(),
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
        validate_record_id(id).map_err(|_| invalid())?;
        let _acceptance =
            crate::chat_receipts::Operation::conversation(&self.root, id).map_err(|_| invalid())?;
        let lifecycle =
            crate::work_handoff_store::lifecycle_lock(&self.root).map_err(|_| invalid())?;
        self.edit_index_locked(&lifecycle, false, |_, current| {
            let chat = current
                .iter_mut()
                .find(|chat| chat.id == id && chat.workspace_id == workspace)
                .ok_or("This chat is no longer in that checkout.")?;
            match chat.team_share.as_ref() {
                None => return Ok(()),
                Some(current) if current.id == share => {}
                Some(_) => {
                    return Err(
                        "This chat has a different sharing record. Refresh before changing it."
                            .into(),
                    );
                }
            }
            chat.team_share = None;
            chat.send_revision = next_send_revision(chat.send_revision)?;
            chat.updated_at_ms = now_ms();
            Ok(())
        })
        .map_err(|_| invalid())
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
            let marker = chat.team_share.as_ref().ok_or_else(paused)?;
            if marker.id != share || marker.initial_fingerprint != expected {
                return Err(paused());
            }
            let boundary = usize::try_from(marker.history_bytes).map_err(|_| paused())?;
            // Until an authenticated Team writer is installed, any appended
            // record is unapproved. An older client cannot silently publish a
            // private prompt, even if it ignores the conversion marker.
            if boundary != bytes.len() {
                return Err(paused());
            }
            let history = project(chat, bytes)?;
            if history.fingerprint != marker.initial_fingerprint
                || history.history_through != marker.history_through
            {
                return Err(paused());
            }
            Ok(history)
        })
    }

    fn review_locked<T>(
        &self,
        workspace: &str,
        id: &str,
        operation: impl FnOnce(Index, History) -> Result<T, DispatchError>,
    ) -> Result<T, DispatchError> {
        self.source_locked(workspace, id, true, |index, _, bytes| {
            let chat = index
                .conversations
                .iter()
                .find(|chat| chat.id == id)
                .ok_or_else(invalid)?;
            let history = project(chat, bytes)?;
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
        validate_record_id(id).map_err(|_| invalid())?;
        let _acceptance =
            crate::chat_receipts::Operation::conversation(&self.root, id).map_err(|_| invalid())?;
        let _lifecycle =
            crate::work_handoff_store::lifecycle_lock(&self.root).map_err(|_| invalid())?;
        let _transcript = self.transcript_guard().map_err(|_| invalid())?;
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
        if require_idle
            && (chat.running || self.active.lock().map_err(|_| invalid())?.contains_key(id))
        {
            return Err(DispatchError::new(
                "chat_running",
                "Finish or stop this chat's current turn before sharing its history.",
            ));
        }
        let _runner =
            if require_idle {
                Some(crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)
            .map_err(|_| invalid())?
            .ok_or_else(|| {
                DispatchError::new(
                    "chat_running",
                    "Finish or stop this chat's current turn before sharing its history.",
                )
            })?)
            } else {
                None
            };
        let directory = safe_join(&self.root, id).map_err(|_| invalid())?;
        let bytes = read_private(
            &directory.join("events.ndjson"),
            HISTORY_LIMIT,
            chat.last_message_at_ms.is_none(),
        )?;
        let chat = chat.clone();
        operation(index, &chat, &bytes)
    }
}

fn paused() -> DispatchError {
    DispatchError::new(
        "chat_sharing_paused",
        "This chat changed outside its shared view. Ask its publisher to review sharing.",
    )
}

pub(super) fn require_personal_send(chat: &Conversation) -> Result<(), DispatchError> {
    if chat.team_share.is_some() {
        return Err(DispatchError::new(
            "shared_chat_requires_team",
            "This chat is shared with a team. Open its shared view before changing it.",
        ));
    }
    Ok(())
}

fn project(chat: &Conversation, bytes: &[u8]) -> Result<History, DispatchError> {
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
