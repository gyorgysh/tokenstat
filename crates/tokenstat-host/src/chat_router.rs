// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Durable continuation policy. All decisions share chat's acceptance lock.
use super::*;
use crate::provider_limit::Limit;
use tokenstat_sync::vault::{VaultClient, VaultError};

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Destination {
    pub backend: String,
    pub model: Option<String>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Policy {
    pub enabled: bool,
    pub routes: Vec<Destination>,
    pub wait_for_reset: bool,
    pub return_preferred: bool,
    pub use_as_default: bool,
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
}
impl State {
    fn destination(&self, chat: &Conversation, now: i64) -> Option<Destination> {
        if self.note.as_deref() == Some("manual") {
            return Some(Destination {
                backend: chat.backend.clone(),
                model: chat.model.clone(),
            });
        }
        let next = if self.policy.enabled && self.limit.as_ref().is_some_and(|l| l.kind == "usage")
        {
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
                    .and_then(|l| l.resets_at_ms)
                    .is_some_and(|t| now >= t)
            {
                Some(Destination {
                    backend: chat.backend.clone(),
                    model: chat.model.clone(),
                })
            } else {
                None
            }
        })
    }
    fn view(&self) -> Value {
        json!({"policy":self.policy,"limit":self.limit,"waiting":self.pending.as_ref().is_some_and(|p|!p.claimed),
            "needsDeliveryCheck":self.pending.as_ref().is_some_and(|p|p.claimed),"note":self.note,
            "tried":self.tried})
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
        save_document(&directory, "routing.json", state)
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
    pub fn routing_update(&self, id: &str, revision: u64, policy: Policy) -> Result<Value, String> {
        validate_record_id(id)?;
        if policy.routes.len() > 8 {
            return Err("Choose up to eight routing destinations.".into());
        }
        let known = crate::automations::backends(false);
        let mut unique = Vec::new();
        for destination in &policy.routes {
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
                || unique.contains(destination)
            {
                return Err("Choose distinct valid routing destinations.".into());
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
        let claimed = state.pending.as_ref().is_some_and(|p| p.claimed);
        if !claimed {
            state.owner = self.router_owner()?;
            state.peer = crate::request_context::remote_peer();
        }
        if state.preferred.is_none() {
            state.preferred = Some(Destination {
                backend: chat.backend,
                model: chat.model,
            });
        }
        if !claimed && !state.policy.enabled && !state.policy.wait_for_reset {
            state.pending = None;
        } else if state.pending.is_none() && state.limit.is_some() {
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
        state.preferred = Some(Destination {
            backend: chat.backend,
            model: chat.model,
        });
        state.preferred_reset_at_ms = None;
        state.tried.clear();
        self.router_save(id, &state)
    }
    fn router_owner(&self) -> Result<String, String> {
        let epoch = match fs::read(self.root.join("routing-owner-epoch")) {
            Ok(bytes) if bytes.len() == 32 => {
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
        let state = self.router_load(id)?;
        if !state.policy.return_preferred
            || !state.preferred_reset_at_ms.is_some_and(|t| now_ms() >= t)
        {
            return Ok(chat);
        }
        let Some(preferred) = state.preferred else {
            return Ok(chat);
        };
        if chat.backend == preferred.backend && chat.model == preferred.model {
            return Ok(chat);
        }
        if crate::launcher::profile_installed(launcher_profile_id(&preferred.backend))
            == Some(false)
            || (matches!(preferred.backend.as_str(), "muse" | "sh") && chat.autonomy != "bypass")
        {
            return Ok(chat);
        }
        // The next reservation advances the revision. Do not add a second
        // revision here after validating the client's accepted context.
        self.edit_conversation(id, |current| {
            current.backend = preferred.backend;
            current.model = preferred.model;
            current.effort = None;
            current.fast_mode = false;
            current.resume_token = current.resume_tokens.get(&current.backend).cloned();
            Ok(current.clone())
        })
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
                state.preferred = Some(Destination {
                    backend: chat.backend.clone(),
                    model: chat.model.clone(),
                });
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
        };
        if !state.tried.contains(&current) {
            state.tried.push(current.clone());
        }
        if state.preferred.as_ref() == Some(&current) {
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
                && attachments.len() < 16
                && !attachments.iter().any(|id| id == file)
            {
                attachments.push(file.to_string());
            }
        }
        attachments.reverse();
        state.attachments = attachments.clone();
        state.limit = Some(limit);
        state.pending = Some(Pending {
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
            if state.policy.enabled
                && state.limit.as_ref().is_some_and(|l| l.kind == "usage")
                && state.note.is_none()
            {
                state.note=Some("No routing destination is available. Choose a model, or continue when the limit resets.".into());
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
        if destination.backend != selected.backend || destination.model != selected.model {
            selected = self.edit_conversation(id, |c| {
                c.backend = destination.backend.clone();
                c.model = destination.model.clone();
                c.effort = None;
                c.fast_mode = false;
                c.resume_token = c.resume_tokens.get(&c.backend).cloned();
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
    fn order_is_bounded_and_only_a_trusted_reset_retries_the_source() {
        let chat = chat();
        let source = Destination {
            backend: "codex".into(),
            model: None,
        };
        let fallback = Destination {
            backend: "claude".into(),
            model: Some("sonnet".into()),
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
