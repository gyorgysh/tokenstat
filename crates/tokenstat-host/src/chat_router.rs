// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Durable continuation policy. All decisions share chat's acceptance lock.
use super::*;
use crate::provider_limit::Limit;
use std::fs::File;
use tokenstat_sync::vault::{VaultClient, VaultError};

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Destination {
    pub backend: String,
    pub model: Option<String>,
    pub effort: Option<String>,
}
impl Destination {
    fn apply(&self, chat: &mut Conversation) {
        chat.backend = self.backend.clone();
        chat.model = self.model.clone();
        chat.effort = self.effort.clone();
        chat.fast_mode = false;
        chat.resume_token = chat.resume_tokens.get(&chat.backend).cloned();
    }
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Policy {
    pub enabled: bool,
    pub routes: Vec<Destination>,
    pub wait_for_reset: bool,
    pub return_preferred: bool,
    pub use_as_default: bool,
    pub failover_on_throttle: bool,
    pub failover_on_errors: bool,
    pub failover_on_auth: bool,
    pub failover_on_failures: bool,
    pub notify: Option<bool>,
    pub preferred: Option<Destination>,
}
impl Policy {
    fn handles(&self, limit: &Limit) -> bool {
        (self.enabled
            && match limit.kind.as_str() {
                "usage" => true,
                "throttle" => self.failover_on_throttle,
                "error" => self.failover_on_errors,
                "auth" => self.failover_on_auth,
                "failure" => self.failover_on_failures,
                _ => false,
            })
            || (self.wait_for_reset
                && matches!(limit.kind.as_str(), "usage" | "throttle")
                && limit.resets_at_ms.is_some())
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Pending {
    operation_id: String,
    expected_revision: u64,
    created_at_ms: i64,
    claimed: bool,
    #[serde(default)]
    attachments: Vec<String>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
struct Activity {
    #[serde(default)]
    id: String,
    at_ms: i64,
    kind: String,
    source: Option<Destination>,
    target: Option<Destination>,
    reason: String,
    resets_at_ms: Option<i64>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
struct State {
    policy: Policy,
    limit: Option<Limit>,
    pending: Option<Pending>,
    tried: Vec<Destination>,
    preferred: Option<Destination>,
    preferred_reset_at_ms: Option<i64>,
    owner: String,
    peer: Option<String>,
    note: Option<String>,
    cancelled_run: Option<u64>,
    attachments: Vec<String>,
    activity: Vec<Activity>,
}
impl State {
    fn record(
        &mut self,
        kind: &str,
        source: Option<Destination>,
        target: Option<Destination>,
        reason: &str,
        resets_at_ms: Option<i64>,
    ) {
        self.activity.push(Activity {
            id: format!("{:032x}", rand::random::<u128>()),
            at_ms: now_ms(),
            kind: kind.into(),
            source: source.map(|mut d| {
                d.model = d.model.map(|v| v.chars().take(40).collect());
                d.effort = d.effort.map(|v| v.chars().take(40).collect());
                d.backend = d.backend.chars().take(40).collect();
                d
            }),
            target: target.map(|mut d| {
                d.model = d.model.map(|v| v.chars().take(40).collect());
                d.effort = d.effort.map(|v| v.chars().take(40).collect());
                d.backend = d.backend.chars().take(40).collect();
                d
            }),
            reason: reason.chars().take(160).collect(),
            resets_at_ms,
        });
        if self.activity.len() > 32 {
            self.activity.drain(..self.activity.len() - 32);
        }
    }
    fn destination(&self, chat: &Conversation, now: i64) -> Option<Destination> {
        if self.note.as_deref() == Some("manual") {
            return Some(Destination {
                backend: chat.backend.clone(),
                model: chat.model.clone(),
                effort: chat.effort.clone(),
            });
        }
        let next = if self.policy.enabled
            && self.limit.as_ref().is_some_and(|l| match l.kind.as_str() {
                "usage" => true,
                "throttle" => self.policy.failover_on_throttle,
                "error" => self.policy.failover_on_errors,
                "auth" => self.policy.failover_on_auth,
                "failure" => self.policy.failover_on_failures,
                _ => false,
            }) {
            self.policy
                .routes
                .iter()
                .find(|d| !self.tried.contains(d))
                .cloned()
        } else {
            None
        };
        next.or_else(|| {
            if self.policy.wait_for_reset
                && self
                    .limit
                    .as_ref()
                    .filter(|l| matches!(l.kind.as_str(), "usage" | "throttle"))
                    .and_then(|l| l.resets_at_ms)
                    .is_some_and(|t| now >= t)
            {
                Some(Destination {
                    backend: chat.backend.clone(),
                    model: chat.model.clone(),
                    effort: chat.effort.clone(),
                })
            } else {
                None
            }
        })
    }
    fn view(&self) -> Value {
        json!({"policy":self.policy,"limit":self.limit,"waiting":self.pending.as_ref().is_some_and(|p|!p.claimed),
            "needsDeliveryCheck":self.pending.as_ref().is_some_and(|p|p.claimed),"note":self.note,
            "tried":self.tried,"preferred":self.preferred,"activity":self.activity})
    }
}
fn owner() -> Result<String, String> {
    if crate::vault::SIGNOUTS.load(Ordering::SeqCst) != 0 {
        return Err("The signed-in account is changing.".into());
    }
    match VaultClient::capture() {
        Ok(client) => {
            client.ensure_current().map_err(|e| e.to_string())?;
            Ok(client.authentication_id())
        }
        Err(VaultError::NotSignedIn) => Ok("local".into()),
        Err(e) => Err(e.to_string()),
    }
}
const CONTINUE: &str = "Continue the current task from the last accepted message. Review the conversation and workspace to determine what has already completed. Do not repeat completed tools or changes. Keep the same permissions and ask if the remaining intent is unclear.";

fn save_document(directory: &Path, name: &str, state: &State) -> Result<(), String> {
    let temporary = directory.join(format!(".routing-{:032x}.tmp", rand::random::<u128>()));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
        file.write_all(&serde_json::to_vec(state).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        fs::rename(&temporary, directory.join(name)).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        File::open(directory)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
    })();
    let _ = fs::remove_file(temporary);
    result
}

const ACTIVITY_MAX: u64 = 8 * 1024 * 1024;
fn activity_file(path: &Path, append: bool) -> Result<File, String> {
    if let Ok(meta) = fs::symlink_metadata(path)
        && (!meta.file_type().is_file() || meta.len() > ACTIVITY_MAX)
    {
        return Err("Routing activity is not a bounded regular file.".into());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    if append {
        options.write(true).append(true).create(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path).map_err(|e| e.to_string())?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > ACTIVITY_MAX {
        return Err("Routing activity cannot be read safely.".into());
    }
    Ok(file)
}
fn read_activity(
    path: &Path,
    cursor: Option<&str>,
    limit: usize,
) -> Result<(Vec<Activity>, Option<String>), String> {
    use sha2::{Digest, Sha256};
    use std::io::{BufRead, Read, Seek, SeekFrom};
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Vec::new(), None));
        }
        Err(error) => return Err(error.to_string()),
        Ok(_) => {}
    }
    let mut file = activity_file(path, false)?;
    let len = file.metadata().map_err(|e| e.to_string())?.len();
    let mut first = Vec::new();
    BufReader::new((&mut file).take(256))
        .read_until(b'\n', &mut first)
        .map_err(|e| e.to_string())?;
    let digest = Sha256::digest(&first);
    let generation = u64::from_le_bytes(digest[..8].try_into().unwrap());
    let end = match cursor {
        Some(cursor) => parse_cursor(cursor, len, generation)
            .ok_or("Older routing history expired. Refresh activity.")?,
        None => len,
    };
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(file);
    let mut rows = std::collections::VecDeque::new();
    let mut offset = 0;
    while offset < end {
        let mut line = Vec::new();
        (&mut reader)
            .take(4097)
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if line.is_empty()
            || line.len() > 4096
            || line.last() != Some(&b'\n')
            || offset + line.len() as u64 > end
        {
            return Err("Routing activity changed or is incomplete. Refresh it.".into());
        }
        let entry: Activity = serde_json::from_slice(&line).map_err(|e| e.to_string())?;
        rows.push_back((offset, entry));
        if rows.len() > limit {
            rows.pop_front();
        }
        offset += line.len() as u64;
    }
    let cursor = rows
        .front()
        .filter(|(start, _)| *start > 0)
        .map(|(start, _)| make_cursor(*start, len, generation));
    Ok((rows.into_iter().map(|(_, entry)| entry).collect(), cursor))
}
fn append_activity<'a>(
    directory: &Path,
    entries: impl Iterator<Item = &'a Activity>,
) -> Result<(), String> {
    let entries = entries.collect::<Vec<_>>();
    if entries.is_empty() {
        return Ok(());
    }
    let path = directory.join("routing-activity.ndjson");
    let mut file = activity_file(&path, true)?;
    // Retire an interrupted last append before writing another complete row.
    // The durable state is saved only after this journal is flushed.
    {
        use std::io::{Read, Seek, SeekFrom};
        let len = file.metadata().map_err(|e| e.to_string())?.len();
        let count = len.min(4096);
        if count > 0 {
            file.seek(SeekFrom::End(-(count as i64)))
                .map_err(|e| e.to_string())?;
            let mut tail = vec![0; count as usize];
            file.read_exact(&mut tail).map_err(|e| e.to_string())?;
            if tail.last() != Some(&b'\n') {
                let retained = match tail.iter().rposition(|b| *b == b'\n') {
                    Some(index) => len - count + index as u64 + 1,
                    None if count == len => 0,
                    None => {
                        return Err("Routing activity has an oversized incomplete record.".into());
                    }
                };
                file.set_len(retained)
                    .and_then(|_| file.sync_all())
                    .map_err(|e| e.to_string())?;
            }
        }
    }
    let mut bytes = Vec::new();
    for entry in entries {
        serde_json::to_writer(&mut bytes, entry).map_err(|e| e.to_string())?;
        bytes.push(b'\n');
    }
    if file.metadata().map_err(|e| e.to_string())?.len() + bytes.len() as u64 > ACTIVITY_MAX {
        drop(file);
        let (retained, _) = read_activity(&path, None, 1024)?;
        let mut saved = Vec::new();
        for entry in retained {
            serde_json::to_writer(&mut saved, &entry).map_err(|e| e.to_string())?;
            saved.push(b'\n');
        }
        let temporary = directory.join(format!(
            ".routing-activity-{:032x}.tmp",
            rand::random::<u128>()
        ));
        let result = (|| {
            write_private_file(&temporary, &saved)?;
            OpenOptions::new()
                .write(true)
                .open(&temporary)
                .and_then(|f| f.sync_all())
                .map_err(|e| e.to_string())?;
            fs::rename(&temporary, &path).map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })();
        let _ = fs::remove_file(&temporary);
        result?;
        file = activity_file(&path, true)?;
    }
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())
}

impl Store {
    fn router_load(&self, id: &str) -> Result<State, String> {
        let directory = self.verified_append_directory(id)?;
        let path = directory.join("routing.json");
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let default = self.root.join("routing-defaults.json");
                let mut state = State::default();
                if let Ok(meta) = fs::symlink_metadata(&default) {
                    if !meta.file_type().is_file() || meta.len() > 64 * 1024 {
                        return Err("Routing defaults could not be read safely.".into());
                    }
                    let defaults: State =
                        serde_json::from_slice(&fs::read(default).map_err(|e| e.to_string())?)
                            .map_err(|e| e.to_string())?;
                    if defaults.owner == self.router_owner()? {
                        state.policy = defaults.policy;
                    }
                }
                Ok(state)
            }
            Err(e) => Err(e.to_string()),
            Ok(meta) if meta.file_type().is_file() && meta.len() <= 64 * 1024 => {
                serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())
            }
            Ok(_) => Err("Chat routing could not be read safely.".into()),
        }
    }
    fn router_save(&self, id: &str, state: &State) -> Result<(), String> {
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let directory = self.verified_append_directory(id)?;
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        let previous = self.router_load(id)?;
        let mut next = state.clone();
        if next.limit != previous.limit
            && let Some(limit) = next.limit.clone()
        {
            next.record(
                &limit.kind,
                next.tried.last().cloned(),
                None,
                &limit.reason,
                limit.resets_at_ms,
            );
        }
        if next.note != previous.note
            && let Some(note) = next.note.clone()
            && !note.starts_with("Continuing with")
            && note != "manual"
        {
            let kind = if note.starts_with("Continuing with") {
                "continued"
            } else if note.contains("cancelled") {
                "cancelled"
            } else if note.contains("Trying the next") || note.contains("unavailable") {
                "skipped"
            } else {
                "paused"
            };
            next.record(kind, next.tried.last().cloned(), None, &note, None);
        }
        append_activity(
            &directory,
            next.activity
                .iter()
                .filter(|entry| !previous.activity.iter().any(|old| old.id == entry.id)),
        )?;
        save_document(&directory, "routing.json", &next)
    }

    pub fn routing_history(&self, id: &str, cursor: Option<&str>) -> Result<Value, String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|e| e.to_string())?;
        self.current_send_conversation(id)?;
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let directory = self.verified_append_directory(id)?;
        let (entries, cursor) =
            read_activity(&directory.join("routing-activity.ndjson"), cursor, 32)?;
        Ok(json!({"activity":entries,"cursor":cursor}))
    }
    pub(super) fn routing_notifications_enabled(&self, id: &str) -> bool {
        self.router_load(id)
            .map(|state| state.limit.is_none() || state.policy.notify != Some(false))
            .unwrap_or(true)
    }
    pub fn routing(&self, id: &str) -> Result<Value, String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|e| e.to_string())?;
        self.current_send_conversation(id)?;
        self.router_load(id).map(|s| s.view())
    }
    pub fn attach_routing(&self, rows: &mut Value) {
        if let Some(rows) = rows.as_array_mut() {
            for row in rows {
                if let Some(id) = row["id"].as_str().map(str::to_owned)
                    && let Ok(state) = self.routing(&id)
                {
                    row["routing"] = state;
                }
            }
        }
    }
    pub fn routing_update(
        &self,
        id: &str,
        revision: u64,
        mut policy: Policy,
    ) -> Result<Value, String> {
        validate_record_id(id)?;
        for destination in policy.routes.iter_mut().chain(policy.preferred.iter_mut()) {
            if destination.model.as_deref() == Some("") {
                destination.model = None;
            }
            if destination.effort.as_deref() == Some("") {
                destination.effort = None;
            }
        }
        if policy.routes.len() > 8 {
            return Err("Choose up to eight routing destinations.".into());
        }
        let known = crate::automations::backends(false);
        let mut unique = Vec::new();
        for (index, destination) in policy
            .routes
            .iter()
            .chain(policy.preferred.iter())
            .enumerate()
        {
            if !known
                .iter()
                .any(|b| b["id"].as_str() == Some(&destination.backend))
                || destination.backend == "sh"
            {
                return Err("Choose a supported chat agent.".into());
            }
            if destination
                .model
                .as_ref()
                .is_some_and(|m| m.len() > 256 || m.contains(['\n', '\r', '\0']))
                || (index < policy.routes.len() && unique.contains(destination))
            {
                return Err("Choose distinct valid routing destinations.".into());
            }
            if let Some(effort) = &destination.effort
                && (effort.is_empty()
                    || !known.iter().any(|backend| {
                        backend["id"].as_str() == Some(&destination.backend)
                            && backend["efforts"].as_array().is_some_and(|values| {
                                values.iter().any(|value| value.as_str() == Some(effort))
                            })
                    }))
            {
                return Err("Choose an effort supported by this chat agent.".into());
            }
            unique.push(destination.clone());
        }
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|e| e.to_string())?;
        let chat = self.current_send_conversation(id)?;
        if chat.send_revision != revision {
            return Err("The conversation changed. Refresh it before saving routing.".into());
        }
        let mut state = self.router_load(id)?;
        state.policy = policy;
        state.record("settings", None, None, "Routing settings saved.", None);
        let claimed = state.pending.as_ref().is_some_and(|p| p.claimed);
        if !claimed {
            state.owner = self.router_owner()?;
            state.peer = crate::request_context::remote_peer();
        }
        let previous_preferred = state.preferred.clone();
        if state.policy.preferred.is_some() {
            state.preferred = state.policy.preferred.clone();
        } else if state.preferred.is_none() {
            state.preferred = Some(Destination {
                backend: chat.backend,
                model: chat.model,
                effort: chat.effort.clone(),
            });
        }
        if previous_preferred.as_ref().map(|d| &d.backend)
            != state.preferred.as_ref().map(|d| &d.backend)
        {
            state.preferred_reset_at_ms = None;
        }
        let handles = state
            .limit
            .as_ref()
            .is_some_and(|limit| state.policy.handles(limit));
        if !claimed && !handles {
            state.pending = None;
        } else if state.pending.is_none() && handles {
            state.pending = Some(Pending {
                operation_id: format!("route-{}", rand::random::<u64>()),
                expected_revision: revision,
                created_at_ms: now_ms(),
                claimed: false,
                attachments: state.attachments.clone(),
            });
        }
        self.router_save(id, &state)?;
        if state.policy.use_as_default {
            let mut defaults = State {
                policy: state.policy.clone(),
                owner: self.router_owner()?,
                ..State::default()
            };
            defaults.policy.use_as_default = false;
            let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
            save_document(&self.root, "routing-defaults.json", &defaults)?;
        }
        Ok(state.view())
    }
    pub fn routing_action(
        self: &Arc<Self>,
        id: &str,
        revision: u64,
        action: &str,
    ) -> Result<Value, String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|e| e.to_string())?;
        let chat = self.current_send_conversation(id)?;
        if chat.send_revision != revision {
            return Err("The conversation changed. Refresh it before continuing.".into());
        }
        let mut state = self.router_load(id)?;
        match action {
            "cancel" => {
                state.record(
                    "cancelled",
                    None,
                    None,
                    "Automatic continuation cancelled by you.",
                    None,
                );
                if !state.pending.as_ref().is_some_and(|p| p.claimed) {
                    state.pending = None;
                }
                state.note = None;
            }
            "resume" => {
                if chat.running
                    || crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?.is_none()
                {
                    return Err("Finish or stop the active turn before continuing.".into());
                }
                if state.pending.as_ref().is_some_and(|p| p.claimed) {
                    return Err("Check this continuation's delivery before retrying. You can write a new message.".into());
                }
                state.owner = self.router_owner()?;
                state.peer = crate::request_context::remote_peer();
                let attachments = state.attachments.clone();
                state.pending = Some(Pending {
                    operation_id: format!("route-{}-{}", now_ms(), rand::random::<u64>()),
                    expected_revision: revision,
                    created_at_ms: now_ms(),
                    claimed: false,
                    attachments,
                });
                state.note = Some("manual".into());
            }
            _ => return Err("Choose resume or cancel.".into()),
        }
        self.router_save(id, &state)?;
        Ok(state.view())
    }
    pub(super) fn router_cancel_locked(&self, id: &str) -> Result<(), String> {
        let mut state = self.router_load(id)?;
        state.pending = None;
        state.limit = None;
        state.note = None;
        state.cancelled_run = self.current_send_conversation(id)?.run_revision;
        self.router_save(id, &state)
    }
    pub(super) fn router_prefer_locked(&self, id: &str) -> Result<(), String> {
        let chat = self.current_send_conversation(id)?;
        let mut state = self.router_load(id)?;
        state.preferred = state.policy.preferred.clone().or(Some(Destination {
            backend: chat.backend,
            model: chat.model,
            effort: chat.effort.clone(),
        }));
        state.preferred_reset_at_ms = None;
        state.tried.clear();
        self.router_save(id, &state)
    }
    pub(super) fn router_owner(&self) -> Result<String, String> {
        let path = self.root.join("routing-owner-epoch");
        let epoch = match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_file() && metadata.len() == 32 => {
                let bytes = read_fork_file(&path, 32, false)?;
                if bytes.len() != 32 {
                    return Err("Routing account ownership could not be verified.".into());
                }
                String::from_utf8(bytes).map_err(|e| e.to_string())?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => "initial".into(),
            _ => return Err("Routing account ownership could not be verified.".into()),
        };
        Ok(format!("{}:{epoch}", owner()?))
    }
    pub fn routing_cancel_all(&self) -> Result<(), String> {
        // A single durable epoch retires every pending intent without waiting
        // for per-chat launch locks during logout. Other helpers observe it too.
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let temporary = self
            .root
            .join(format!(".routing-owner-{:032x}", rand::random::<u128>()));
        let result = (|| {
            write_private_file(
                &temporary,
                format!("{:032x}", rand::random::<u128>()).as_bytes(),
            )?;
            OpenOptions::new()
                .write(true)
                .open(&temporary)
                .and_then(|f| f.sync_all())
                .map_err(|e| e.to_string())?;
            fs::rename(&temporary, self.root.join("routing-owner-epoch"))
                .map_err(|e| e.to_string())?;
            #[cfg(unix)]
            File::open(&self.root)
                .and_then(|f| f.sync_all())
                .map_err(|e| e.to_string())?;
            Ok(())
        })();
        let _ = fs::remove_file(temporary);
        result
    }
    pub(super) fn router_return_locked(
        &self,
        id: &str,
        chat: Conversation,
    ) -> Result<Conversation, String> {
        let mut state = self.router_load(id)?;
        if !state.policy.return_preferred
            || !state.preferred_reset_at_ms.is_some_and(|t| now_ms() >= t)
        {
            return Ok(chat);
        }
        let Some(preferred) = state.preferred.clone() else {
            return Ok(chat);
        };
        if chat.backend == preferred.backend
            && chat.model == preferred.model
            && chat.effort == preferred.effort
        {
            return Ok(chat);
        }
        if crate::launcher::profile_installed(launcher_profile_id(&preferred.backend))
            == Some(false)
            || (matches!(preferred.backend.as_str(), "muse" | "sh") && chat.autonomy != "bypass")
        {
            return Ok(chat);
        }
        state.record(
            "returned",
            Some(Destination {
                backend: chat.backend.clone(),
                model: chat.model.clone(),
                effort: chat.effort.clone(),
            }),
            Some(preferred.clone()),
            "Returned to the preferred agent at the next turn boundary after its usage reset.",
            None,
        );
        // The next reservation advances the revision. Do not add a second
        // revision here after validating the client's accepted context.
        let result = self.edit_conversation(id, |current| {
            preferred.apply(current);
            Ok(current.clone())
        })?;
        self.router_save(id, &state)?;
        Ok(result)
    }
    pub(super) fn router_arm_locked(
        &self,
        id: &str,
        chat: &Conversation,
        continuation: bool,
    ) -> Result<(), String> {
        let mut state = self.router_load(id)?;
        let owner = self.router_owner()?;
        if continuation {
            if state.owner != owner || state.peer != crate::request_context::remote_peer() {
                return Err("the scheduled continuation account changed".into());
            }
        } else {
            state.owner = owner;
            state.peer = crate::request_context::remote_peer();
            state.cancelled_run = None;
            state.attachments.clear();
            state.pending = None;
            state.limit = None;
            state.tried.clear();
            state.note = None;
            if state.preferred.is_none() {
                state.preferred = state.policy.preferred.clone().or(Some(Destination {
                    backend: chat.backend.clone(),
                    model: chat.model.clone(),
                    effort: chat.effort.clone(),
                }));
            }
        }
        self.router_save(id, &state)
    }
    pub(super) fn router_observe(
        &self,
        id: &str,
        revision: u64,
        mut limit: Limit,
    ) -> Result<(), String> {
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        let chat = self.current_send_conversation(id)?;
        if chat.run_revision != Some(revision) {
            return Ok(());
        }
        let mut state = self.router_load(id)?;
        if state.owner.is_empty() || state.cancelled_run == Some(revision) {
            return Ok(());
        }
        let codex_home = if private_codex_home(chat.autonomy == "standard") {
            Some(self.codex_home(id))
        } else {
            tokenstat_paths::home_dir()
                .and_then(|home| tokenstat_core::sources::codex::discover(&home))
                .and_then(|path| path.parent().map(Path::to_path_buf))
        };
        if limit.provider == "codex"
            && limit.resets_at_ms.is_none()
            && let Some(reading) = codex_home
                .as_deref()
                .and_then(tokenstat_core::limits::codex_limits_for_home)
            && reading.observed_at_ms >= chat.run_started_at_ms.unwrap_or(i64::MAX)
        {
            limit.resets_at_ms = reading
                .windows
                .iter()
                .filter(|w| w.scope.is_none() && w.percent >= 100.0)
                .filter_map(|w| w.resets_at_ms)
                .filter(|t| *t > now_ms())
                .max();
        }
        let current = Destination {
            backend: chat.backend,
            model: chat.model,
            effort: chat.effort.clone(),
        };
        if !state.tried.contains(&current) {
            state.tried.push(current.clone());
        }
        if state
            .preferred
            .as_ref()
            .is_some_and(|preferred| preferred.backend == current.backend)
        {
            state.preferred_reset_at_ms = limit.resets_at_ms;
        }
        let (events, _) = self.events(id, 0)?;
        let mut attachments = Vec::new();
        for event in events.iter().rev() {
            if event["kind"].as_str() == Some("user") {
                break;
            }
            if event["event"]["kind"].as_str() == Some("attachment")
                && let Some(file) = event["event"]["id"].as_str()
                && attachments.len() < 20
                && !attachments.iter().any(|id| id == file)
            {
                attachments.push(file.to_string());
            }
        }
        attachments.reverse();
        state.attachments = attachments.clone();
        let handles = state.policy.handles(&limit);
        state.limit = Some(limit);
        state.pending = handles.then_some(Pending {
            operation_id: format!("route-{revision}-{}", rand::random::<u64>()),
            expected_revision: chat.send_revision,
            created_at_ms: now_ms(),
            claimed: false,
            attachments,
        });
        state.note = None;
        self.router_save(id, &state)
    }
    fn route_one(self: &Arc<Self>, id: &str, now: i64) -> Result<(), String> {
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        let chat = self.current_send_conversation(id)?;
        let state = self.router_load(id)?;
        if state.pending.is_none() {
            return Ok(());
        }
        let snapshot = crate::account_session::AccountSnapshot::capture()?;
        crate::account_session::with_snapshot(Some(snapshot), || {
            if let Some(peer) = state.peer.clone() {
                crate::request_context::with_remote_peer(&peer, || {
                    self.route_locked(id, now, chat, state)
                })
            } else {
                self.route_locked(id, now, chat, state)
            }
        })
    }
    fn route_locked(
        self: &Arc<Self>,
        id: &str,
        now: i64,
        chat: Conversation,
        mut state: State,
    ) -> Result<(), String> {
        let Some(mut pending) = state.pending.clone() else {
            return Ok(());
        };
        if pending.claimed {
            let key = crate::chat_receipts::key(state.peer.as_deref(), &pending.operation_id);
            let ledger = crate::chat_receipts::Ledger::load(self.receipts_path(id), now)?;
            if ledger
                .get(&key)
                .is_some_and(|r| r.state == crate::chat_receipts::ReceiptState::Accepted)
            {
                state.pending = None;
                state.limit = None;
                self.router_save(id, &state)?;
            }
            return Ok(());
        }
        if chat.running {
            return Ok(());
        }
        if pending.expected_revision != chat.send_revision || self.router_owner()? != state.owner {
            state.pending = None;
            state.note = Some(
                "Scheduled continuation cancelled because the conversation or account changed."
                    .into(),
            );
            return self.router_save(id, &state);
        }
        if let Err(error) = crate::workspace_policy::require_current_access() {
            state.pending = None;
            state.note = Some(format!(
                "Scheduled continuation cancelled: {}",
                error.message
            ));
            return self.router_save(id, &state);
        }
        if crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?.is_none() {
            return Ok(());
        }
        let manual = state.note.as_deref() == Some("manual");
        let destination = state.destination(&chat, now);
        let Some(destination) = destination else {
            let waiting_reset = state.policy.wait_for_reset
                && state.limit.as_ref().is_some_and(|limit| {
                    matches!(limit.kind.as_str(), "usage" | "throttle")
                        && limit.resets_at_ms.is_some_and(|reset| reset > now)
                });
            if !waiting_reset {
                state.pending = None;
                state.note = Some(
                    "No eligible routing destination remains. Choose a model or retry manually."
                        .into(),
                );
                self.router_save(id, &state)?;
            }
            return Ok(());
        };
        let readiness =
            crate::agent_readiness::describe(launcher_profile_id(&destination.backend), true);
        if !manual && readiness["readiness"] == "needsSignIn" {
            state.tried.push(destination.clone());
            state.note = Some(format!(
                "{} needs sign-in on this computer. Trying the next destination.",
                destination.backend
            ));
            return self.router_save(id, &state);
        }
        // Never switch into an agent that can only bypass the current gate.
        if (matches!(destination.backend.as_str(), "muse" | "sh") && chat.autonomy != "bypass")
            || crate::launcher::profile_installed(launcher_profile_id(&destination.backend))
                == Some(false)
        {
            state.tried.push(destination.clone());
            state.note = Some(format!(
                "{} is unavailable or cannot keep this chat's permissions.",
                destination.backend
            ));
            return self.router_save(id, &state);
        }
        let mut selected = chat;
        if destination.backend != selected.backend
            || destination.model != selected.model
            || destination.effort != selected.effort
        {
            selected = self.edit_conversation(id, |c| {
                destination.apply(c);
                c.send_revision = next_send_revision(c.send_revision)?;
                Ok(c.clone())
            })?;
        }
        // Durable claim BEFORE spawning: after a crash, uncertain delivery is
        // held for review instead of replayed by a second helper/scheduler.
        pending.created_at_ms = now_ms();
        state.pending = Some(Pending {
            expected_revision: selected.send_revision,
            claimed: true,
            ..pending.clone()
        });
        state.record(
            if destination == state.preferred.clone().unwrap_or_default() {
                "resumed"
            } else {
                "switched"
            },
            state.tried.last().cloned(),
            Some(destination.clone()),
            "Starting one continuation with the accepted history and permissions.",
            None,
        );
        state.note = Some(format!("Continuing with {}", selected.backend));
        self.router_save(id, &state)?;
        match self.send_under_acceptance(
            id,
            CONTINUE,
            &pending.attachments,
            Some(&pending.operation_id),
            Some(pending.created_at_ms),
            Some(selected.send_revision),
            false,
            None,
            true,
        ) {
            Ok(_) => {
                state.pending = None;
                state.limit = None;
                self.router_save(id, &state)?;
            }
            Err(e) => {
                if e.code != "delivery_unknown" {
                    if state.policy.enabled
                        && !manual
                        && matches!(
                            e.code.as_str(),
                            "agent_not_installed" | "agent_sign_in_required" | "call_failed"
                        )
                    {
                        state.tried.push(destination);
                        state.pending = Some(Pending {
                            expected_revision: self.current_send_conversation(id)?.send_revision,
                            operation_id: format!("route-{}", rand::random::<u64>()),
                            claimed: false,
                            created_at_ms: now_ms(),
                            attachments: pending.attachments.clone(),
                        });
                    } else {
                        state.pending = None;
                    }
                }
                state.note = Some(format!("Continuation paused: {}", e.message));
                self.router_save(id, &state)?;
            }
        }
        Ok(())
    }
    pub(super) fn routing_tick(self: &Arc<Self>) {
        if self.refresh_index().is_err() {
            return;
        }
        let ids = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|c| c.id.clone())
            .collect::<Vec<_>>();
        for id in ids {
            let _ = self.route_one(&id, now_ms());
        }
    }
}

pub(super) fn start(store: &Arc<Store>) {
    let weak = Arc::downgrade(store);
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_secs(10));
            let Some(store) = weak.upgrade() else {
                break;
            };
            store.routing_tick();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Arc<Store>) {
        let temp = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(temp.path().join("chat")));
        let conversation:Conversation=serde_json::from_value(json!({"id":"route-test","workspaceId":"workspace-test","title":"Task","backend":"codex","createdAtMs":1,"updatedAtMs":1,"sendRevision":1,"runRevision":1,"running":false})).unwrap();
        store.conversations.lock().unwrap().push(conversation);
        store.save().unwrap();
        (temp, store)
    }
    fn refusal() -> Limit {
        Limit {
            provider: "codex".into(),
            kind: "usage".into(),
            reason: "You've hit your usage limit.".into(),
            resets_at_ms: Some(now_ms() + 60000),
            observed_at_ms: now_ms(),
        }
    }
    #[test]
    fn interrupted_activity_append_does_not_block_future_complete_records() {
        let (_temp, store) = fixture();
        let mut state = State::default();
        state.record("paused", None, None, "first", None);
        store.router_save("route-test", &state).unwrap();
        let path = store
            .verified_append_directory("route-test")
            .unwrap()
            .join("routing-activity.ndjson");
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{\"partial\":")
            .unwrap();
        state.record("paused", None, None, "second", None);
        store.router_save("route-test", &state).unwrap();
        let result = store.routing_history("route-test", None).unwrap();
        assert_eq!(result["activity"].as_array().unwrap().len(), 2);
        assert_eq!(result["activity"][1]["reason"], "second");
    }
    #[cfg(unix)]
    #[test]
    fn activity_symlinks_are_refused_without_touching_the_target() {
        let (_temp, store) = fixture();
        let directory = store.verified_append_directory("route-test").unwrap();
        fs::create_dir_all(&directory).unwrap();
        let outside = store.root.join("outside");
        fs::write(&outside, b"do not touch").unwrap();
        std::os::unix::fs::symlink(&outside, directory.join("routing-activity.ndjson")).unwrap();
        assert!(store.routing_history("route-test", None).is_err());
        let mut state = State::default();
        state.record("paused", None, None, "new", None);
        assert!(store.router_save("route-test", &state).is_err());
        assert_eq!(fs::read(outside).unwrap(), b"do not touch");
    }
    #[test]
    fn activity_retention_bounds_the_archive_and_keeps_recent_records() {
        let (_temp, store) = fixture();
        let directory = store.verified_append_directory("route-test").unwrap();
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("routing-activity.ndjson");
        let mut state = State::default();
        state.record("paused", None, None, &"x".repeat(160), None);
        let mut line = serde_json::to_vec(&state.activity[0]).unwrap();
        line.push(b'\n');
        let count = ACTIVITY_MAX / line.len() as u64;
        let mut file = File::create(&path).unwrap();
        for _ in 0..count {
            file.write_all(&line).unwrap();
        }
        drop(file);
        state.record("paused", None, None, &"y".repeat(160), None);
        append_activity(&directory, state.activity.iter()).unwrap();
        let (rows, _) = read_activity(&path, None, 2000).unwrap();
        assert_eq!(rows.len(), 1026);
        assert_eq!(rows.last().unwrap().id, state.activity.last().unwrap().id);
        assert!(fs::metadata(path).unwrap().len() < ACTIVITY_MAX);
    }
    #[test]
    fn activity_pages_survive_growth_and_reject_replaced_generations() {
        let (_temp, store) = fixture();
        let mut state = State::default();
        for i in 0..70 {
            state.record("paused", None, None, &format!("event {i}"), None);
            store.router_save("route-test", &state).unwrap();
        }
        let first = store.routing_history("route-test", None).unwrap();
        assert_eq!(first["activity"].as_array().unwrap().len(), 32);
        let cursor = first["cursor"].as_str().unwrap().to_owned();
        state.record("paused", None, None, "new event", None);
        store.router_save("route-test", &state).unwrap();
        let second = store.routing_history("route-test", Some(&cursor)).unwrap();
        assert_eq!(second["activity"][31]["reason"], "event 37");
        let third = store
            .routing_history("route-test", second["cursor"].as_str())
            .unwrap();
        assert_eq!(third["activity"].as_array().unwrap().len(), 6);
        assert!(third["cursor"].is_null());
        let path = store
            .verified_append_directory("route-test")
            .unwrap()
            .join("routing-activity.ndjson");
        fs::write(&path, b"replaced archive\n").unwrap();
        assert!(store.routing_history("route-test", Some(&cursor)).is_err());
    }
    #[test]
    fn opt_out_records_errors_without_arming_automatic_work() {
        let (_temp, store) = fixture();
        let chat = store.get("route-test").unwrap();
        store.router_arm_locked("route-test", &chat, false).unwrap();
        store.router_observe("route-test", 1, refusal()).unwrap();
        let state = store.router_load("route-test").unwrap();
        assert!(state.pending.is_none());
        assert!(state.limit.is_some());
        assert_eq!(state.activity.last().unwrap().kind, "usage");
    }
    #[test]
    fn route_effort_is_validated_persisted_and_source_effort_is_preserved() {
        let (_temp, store) = fixture();
        store
            .edit_conversation("route-test", |c| {
                c.effort = Some("high".into());
                Ok(())
            })
            .unwrap();
        let policy = Policy {
            enabled: true,
            routes: vec![Destination {
                backend: "codex".into(),
                model: None,
                effort: Some("low".into()),
            }],
            ..Policy::default()
        };
        store
            .routing_update("route-test", 1, policy.clone())
            .unwrap();
        store.router_observe("route-test", 1, refusal()).unwrap();
        let state = store.router_load("route-test").unwrap();
        assert_eq!(
            state.preferred.as_ref().unwrap().effort.as_deref(),
            Some("high")
        );
        assert_eq!(
            state
                .destination(
                    &store.current_send_conversation("route-test").unwrap(),
                    now_ms()
                )
                .unwrap()
                .effort
                .as_deref(),
            Some("low")
        );
        assert_eq!(state.activity.last().unwrap().kind, "usage");
        let mut invalid = policy;
        invalid.routes[0].effort = Some("unsupported".into());
        assert!(store.routing_update("route-test", 1, invalid).is_err());
        let restored = Store::load_at(store.root.clone());
        assert_eq!(
            restored
                .router_load("route-test")
                .unwrap()
                .activity
                .last()
                .unwrap()
                .reason,
            refusal().reason
        );
    }
    #[test]
    fn audit_history_is_bounded_and_survives_private_state_reload() {
        let (_temp, store) = fixture();
        let mut state = State::default();
        for _ in 0..100 {
            state.record("paused", None, None, &"x".repeat(10000), None);
        }
        store.router_save("route-test", &state).unwrap();
        let state = store.router_load("route-test").unwrap();
        assert_eq!(state.activity.len(), 32);
        assert!(state.activity.iter().all(|e| e.reason.len() == 160));
    }
    #[test]
    fn continuation_cannot_adopt_another_account_or_peer() {
        let (_temp, store) = fixture();
        let chat = store.current_send_conversation("route-test").unwrap();
        store.router_arm_locked("route-test", &chat, false).unwrap();
        let mut state = store.router_load("route-test").unwrap();
        state.owner = "retired-account".into();
        store.router_save("route-test", &state).unwrap();
        assert!(store.router_arm_locked("route-test", &chat, true).is_err());
        state.owner = store.router_owner().unwrap();
        state.peer = Some("revoked-peer".into());
        store.router_save("route-test", &state).unwrap();
        assert!(store.router_arm_locked("route-test", &chat, true).is_err());
        state.pending = Some(Pending {
            operation_id: "revoked".into(),
            expected_revision: 1,
            created_at_ms: now_ms(),
            claimed: false,
            attachments: vec![],
        });
        store.router_save("route-test", &state).unwrap();
        store.route_one("route-test", now_ms()).unwrap();
        assert!(store.router_load("route-test").unwrap().pending.is_none());
    }
    #[test]
    fn policy_and_refusal_survive_reload_and_cancel_is_run_bound() {
        let (_temp, store) = fixture();
        let policy = Policy {
            enabled: true,
            routes: vec![Destination {
                backend: "claude".into(),
                model: None,
                effort: None,
            }],
            ..Policy::default()
        };
        store.routing_update("route-test", 1, policy).unwrap();
        store.router_observe("route-test", 1, refusal()).unwrap();
        let restored = Store::load_at(store.root.clone());
        assert!(
            restored.routing("route-test").unwrap()["waiting"]
                .as_bool()
                .unwrap()
        );
        assert_eq!(
            restored.routing("route-test").unwrap()["limit"]["provider"],
            "codex"
        );
        let lock =
            crate::chat_receipts::Operation::conversation(&store.root, "route-test").unwrap();
        store.router_cancel_locked("route-test").unwrap();
        drop(lock);
        store.router_observe("route-test", 1, refusal()).unwrap();
        assert!(store.routing("route-test").unwrap()["limit"].is_null());
    }
    #[test]
    fn changed_account_or_revision_cancels_and_live_lease_prevents_routing() {
        let (_temp, store) = fixture();
        store
            .routing_update(
                "route-test",
                1,
                Policy {
                    wait_for_reset: true,
                    ..Policy::default()
                },
            )
            .unwrap();
        let chat = store.get("route-test").unwrap();
        store.router_arm_locked("route-test", &chat, false).unwrap();
        store.router_observe("route-test", 1, refusal()).unwrap();
        let mut state = store.router_load("route-test").unwrap();
        state.note = Some("manual".into());
        store.router_save("route-test", &state).unwrap();
        let lease = crate::chat_receipts::RunnerLease::try_acquire(&store.root, "route-test")
            .unwrap()
            .unwrap();
        store.route_one("route-test", now_ms()).unwrap();
        assert!(
            !store
                .router_load("route-test")
                .unwrap()
                .pending
                .unwrap()
                .claimed
        );
        drop(lease);
        store
            .edit_conversation("route-test", |chat| {
                chat.send_revision += 1;
                Ok(())
            })
            .unwrap();
        store.route_one("route-test", now_ms()).unwrap();
        assert!(store.router_load("route-test").unwrap().pending.is_none());
        store
            .edit_conversation("route-test", |chat| {
                chat.send_revision = 1;
                Ok(())
            })
            .unwrap();
        store.router_observe("route-test", 1, refusal()).unwrap();
        let mut state = store.router_load("route-test").unwrap();
        state.owner = "retired-account".into();
        store.router_save("route-test", &state).unwrap();
        store.route_one("route-test", now_ms()).unwrap();
        assert!(store.router_load("route-test").unwrap().pending.is_none());
    }
    #[test]
    fn claimed_unknown_delivery_is_never_launched_by_a_restarted_helper() {
        let (_temp, store) = fixture();
        store
            .routing_update(
                "route-test",
                1,
                Policy {
                    wait_for_reset: true,
                    ..Policy::default()
                },
            )
            .unwrap();
        let chat = store.get("route-test").unwrap();
        store.router_arm_locked("route-test", &chat, false).unwrap();
        store.router_observe("route-test", 1, refusal()).unwrap();
        let mut state = store.router_load("route-test").unwrap();
        state.pending.as_mut().unwrap().claimed = true;
        state.note = Some("manual".into());
        store.router_save("route-test", &state).unwrap();
        let restored = Arc::new(Store::load_at(store.root.clone()));
        restored.route_one("route-test", now_ms()).unwrap();
        assert!(
            restored.routing("route-test").unwrap()["needsDeliveryCheck"]
                .as_bool()
                .unwrap()
        );
        assert!(restored.routing_action("route-test", 1, "resume").is_err());
    }
    #[test]
    fn duplicate_destinations_and_stale_policy_edits_are_refused() {
        let (_temp, store) = fixture();
        let d = Destination {
            backend: "codex".into(),
            model: None,
            effort: None,
        };
        assert!(
            store
                .routing_update(
                    "route-test",
                    1,
                    Policy {
                        routes: vec![d.clone(), d],
                        ..Policy::default()
                    }
                )
                .is_err()
        );
        assert!(
            store
                .routing_update("route-test", 0, Policy::default())
                .is_err()
        );
    }
}

#[cfg(test)]
mod decision_tests {
    use super::*;
    fn chat() -> Conversation {
        serde_json::from_value(json!({"id":"test","workspaceId":"test","backend":"codex","title":"Task","createdAtMs":1,"updatedAtMs":1})).unwrap()
    }
    #[test]
    fn destination_applies_model_and_effort_without_changing_permissions_or_history() {
        let mut c = chat();
        c.autonomy = "standard".into();
        c.mode = "plan".into();
        c.system_prompt = "existing instructions".into();
        c.resume_tokens
            .insert("codex".into(), "existing-session".into());
        c.fast_mode = true;
        Destination {
            backend: "codex".into(),
            model: Some("gpt-6.1-sol".into()),
            effort: Some("high".into()),
        }
        .apply(&mut c);
        assert_eq!(c.effort.as_deref(), Some("high"));
        assert_eq!(c.model.as_deref(), Some("gpt-6.1-sol"));
        assert_eq!(c.resume_token.as_deref(), Some("existing-session"));
        assert_eq!(c.autonomy, "standard");
        assert_eq!(c.mode, "plan");
        assert_eq!(c.system_prompt, "existing instructions");
        assert!(!c.fast_mode);
    }
    #[test]
    fn error_categories_fail_over_only_under_their_explicit_policy() {
        let mut state = State {
            policy: Policy {
                enabled: true,
                routes: vec![Destination {
                    backend: "claude".into(),
                    model: None,
                    effort: Some("low".into()),
                }],
                ..Policy::default()
            },
            limit: Some(Limit {
                provider: "codex".into(),
                kind: "error".into(),
                reason: "unavailable".into(),
                resets_at_ms: None,
                observed_at_ms: 1,
            }),
            ..State::default()
        };
        assert!(state.destination(&chat(), 1000).is_none());
        state.policy.failover_on_errors = true;
        assert!(state.destination(&chat(), 1000).is_some());
        state.limit.as_mut().unwrap().kind = "throttle".into();
        assert!(state.destination(&chat(), 1000).is_none());
        state.policy.failover_on_throttle = true;
        assert!(state.destination(&chat(), 1000).is_some());
        state.limit.as_mut().unwrap().kind = "auth".into();
        state.limit.as_mut().unwrap().resets_at_ms = Some(500);
        state.policy.wait_for_reset = true;
        assert!(state.destination(&chat(), 1000).is_none());
        state.policy.failover_on_auth = true;
        assert!(state.destination(&chat(), 1000).is_some());
        state.limit.as_mut().unwrap().kind = "failure".into();
        assert!(state.destination(&chat(), 1000).is_none());
        state.policy.failover_on_failures = true;
        assert!(state.destination(&chat(), 1000).is_some());
    }
    #[test]
    fn order_is_bounded_and_only_a_trusted_reset_retries_the_source() {
        let chat = chat();
        let source = Destination {
            backend: "codex".into(),
            model: None,
            effort: None,
        };
        let fallback = Destination {
            backend: "claude".into(),
            model: Some("sonnet".into()),
            effort: None,
        };
        let mut state = State {
            policy: Policy {
                enabled: true,
                routes: vec![source.clone(), fallback.clone()],
                wait_for_reset: true,
                ..Policy::default()
            },
            tried: vec![source.clone()],
            limit: Some(Limit {
                provider: "codex".into(),
                kind: "usage".into(),
                reason: "limit".into(),
                resets_at_ms: Some(5000),
                observed_at_ms: 1000,
            }),
            ..State::default()
        };
        assert_eq!(state.destination(&chat, 1000), Some(fallback.clone()));
        state.tried.push(fallback);
        assert_eq!(state.destination(&chat, 4999), None);
        assert_eq!(state.destination(&chat, 5000), Some(source));
        state.limit.as_mut().unwrap().resets_at_ms = None;
        assert_eq!(state.destination(&chat, i64::MAX), None);
    }
    #[test]
    fn throttle_does_not_fail_over_and_opt_out_stays_idle() {
        let chat = chat();
        let mut state = State {
            policy: Policy {
                enabled: true,
                routes: vec![Destination {
                    backend: "claude".into(),
                    model: None,
                    effort: None,
                }],
                ..Policy::default()
            },
            limit: Some(Limit {
                provider: "codex".into(),
                kind: "throttle".into(),
                reason: "slow down".into(),
                resets_at_ms: None,
                observed_at_ms: 1000,
            }),
            ..State::default()
        };
        assert_eq!(state.destination(&chat, 2000), None);
        state.limit.as_mut().unwrap().kind = "usage".into();
        state.policy.enabled = false;
        assert_eq!(state.destination(&chat, 2000), None);
        state.note = Some("manual".into());
        assert_eq!(state.destination(&chat, 2000).unwrap().backend, "codex");
    }
}

#[cfg(test)]
mod retirement_tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Arc<Store>) {
        let temp = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(temp.path().join("chat")));
        for id in ["original", "fresh"] {
            store.conversations.lock().unwrap().push(serde_json::from_value(json!({"id":id,"workspaceId":"test","title":"Task","backend":"codex","createdAtMs":1,"updatedAtMs":1,"sendRevision":1,"runRevision":1})).unwrap());
        }
        store.save().unwrap();
        (temp, store)
    }
    #[test]
    fn new_chat_defaults_are_account_owned_and_do_not_change_a_saved_policy() {
        let (_temp, store) = fixture();
        store
            .routing_update(
                "original",
                1,
                Policy {
                    enabled: true,
                    use_as_default: true,
                    routes: vec![Destination {
                        backend: "claude".into(),
                        model: None,
                        effort: None,
                    }],
                    ..Policy::default()
                },
            )
            .unwrap();
        assert!(store.router_load("fresh").unwrap().policy.enabled);
        assert!(!store.router_load("fresh").unwrap().policy.use_as_default);
        store.routing_cancel_all().unwrap();
        assert!(!store.router_load("fresh").unwrap().policy.enabled);
        assert!(store.router_load("original").unwrap().policy.enabled);
    }
    #[test]
    fn disabling_or_cancelling_policy_does_not_discard_uncertain_delivery() {
        let (_temp, store) = fixture();
        let chat = store.get("original").unwrap();
        store.router_arm_locked("original", &chat, false).unwrap();
        let mut state = store.router_load("original").unwrap();
        state.pending = Some(Pending {
            operation_id: "route-held".into(),
            expected_revision: 1,
            created_at_ms: now_ms(),
            claimed: true,
            attachments: vec![],
        });
        state.limit = Some(Limit {
            provider: "codex".into(),
            kind: "usage".into(),
            reason: "limit".into(),
            resets_at_ms: None,
            observed_at_ms: now_ms(),
        });
        store.router_save("original", &state).unwrap();
        store
            .routing_update("original", 1, Policy::default())
            .unwrap();
        store.routing_action("original", 1, "cancel").unwrap();
        assert_eq!(
            store
                .router_load("original")
                .unwrap()
                .pending
                .unwrap()
                .operation_id,
            "route-held"
        );
        assert!(store.routing_action("original", 1, "resume").is_err());
        let key = crate::chat_receipts::key(None, "route-held");
        store
            .write_receipt(
                "original",
                &key,
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Accepted,
                    digest: crate::chat_receipts::digest(CONTINUE, &[]),
                    at_ms: now_ms(),
                    event_at_ms: Some(now_ms()),
                },
            )
            .unwrap();
        let helper = Arc::new(Store::load_at(store.root.clone()));
        helper.route_one("original", now_ms()).unwrap();
        assert!(helper.router_load("original").unwrap().pending.is_none());
        assert!(helper.router_load("original").unwrap().limit.is_none());
    }
    #[test]
    fn continuation_keeps_files_from_the_failed_turn_only() {
        let (_temp, store) = fixture();
        store
            .routing_update(
                "original",
                1,
                Policy {
                    enabled: true,
                    ..Policy::default()
                },
            )
            .unwrap();
        let chat = store.get("original").unwrap();
        store.router_arm_locked("original", &chat, false).unwrap();
        store
            .append(
                "original",
                &StoredEvent::User {
                    text: "Earlier task".into(),
                    at_ms: 1,
                },
            )
            .unwrap();
        store.record_events(
            "original",
            "codex",
            vec![Event::Attachment {
                id: "earlier-file".into(),
                name: "old.zip".into(),
                media_type: None,
                size: 1,
            }],
        );
        store
            .append(
                "original",
                &StoredEvent::User {
                    text: "Current task".into(),
                    at_ms: 2,
                },
            )
            .unwrap();
        store.record_events(
            "original",
            "codex",
            vec![
                Event::Attachment {
                    id: "current-file".into(),
                    name: "video.mp4".into(),
                    media_type: None,
                    size: 1,
                },
                Event::Text {
                    delta: "Partial work".into(),
                },
            ],
        );
        store
            .router_observe(
                "original",
                1,
                Limit {
                    provider: "codex".into(),
                    kind: "usage".into(),
                    reason: "limit".into(),
                    resets_at_ms: None,
                    observed_at_ms: now_ms(),
                },
            )
            .unwrap();
        assert_eq!(
            store
                .router_load("original")
                .unwrap()
                .pending
                .unwrap()
                .attachments,
            vec!["current-file"]
        );
        store.routing_action("original", 1, "cancel").unwrap();
        store.routing_action("original", 1, "resume").unwrap();
        assert_eq!(
            store
                .router_load("original")
                .unwrap()
                .pending
                .unwrap()
                .attachments,
            vec!["current-file"]
        );
    }
    #[test]
    fn logout_epoch_retires_another_helpers_pending_intent() {
        let (_temp, store) = fixture();
        let chat = store.get("original").unwrap();
        store.router_arm_locked("original", &chat, false).unwrap();
        let mut state = store.router_load("original").unwrap();
        state.pending = Some(Pending {
            operation_id: "route-pending".into(),
            expected_revision: 1,
            created_at_ms: now_ms(),
            claimed: false,
            attachments: vec![],
        });
        store.router_save("original", &state).unwrap();
        let helper = Arc::new(Store::load_at(store.root.clone()));
        store.routing_cancel_all().unwrap();
        helper.route_one("original", now_ms()).unwrap();
        assert!(helper.router_load("original").unwrap().pending.is_none());
    }
}
