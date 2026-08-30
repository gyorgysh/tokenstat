// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Workspace-scoped conversations with local agents.
//!
//! The archive never sees this data. Conversations, prompts, and raw backend
//! output live under the host data directory and are intentionally absent from
//! sync. A chat is one short-lived process per turn; the backend's own session
//! token is what joins those processes into a conversation.

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::transcript::{Event, Parser};

const EVENTS_CAP: u64 = 1024 * 1024;
const ATTACHMENT_CAP: usize = 12 * 1024 * 1024;
const APPROVAL_TTL_MS: i64 = 10 * 60 * 1000;
const POLL: Duration = Duration::from_millis(400);
static APPROVAL_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub workspace_id: String,
    pub title: String,
    pub backend: String,
    #[serde(default)]
    pub persona_id: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default = "default_mode")]
    pub mode: String,
    #[serde(default = "default_autonomy")]
    pub autonomy: String,
    #[serde(default)]
    pub resume_token: Option<String>,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub allowed_shell_prefixes: Vec<String>,
    #[serde(default)]
    pub budget_seconds: u64,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    #[serde(default)]
    pub running: bool,
}

/// A locally stored starting point for a conversation, never an autonomous
/// agent. Its fields are copied into a chat at creation time.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Persona {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub mark: String,
    pub backend: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default = "default_mode")]
    pub default_mode: String,
    #[serde(default = "default_autonomy")]
    pub default_autonomy: String,
}

/// A locally staged file. The client only receives this descriptor; bytes
/// never leave the chat's host data directory except when its agent reads it.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub id: String,
    pub name: String,
    pub media_type: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    pub id: String,
    pub conversation_id: String,
    pub verb: String,
    pub preview: String,
    pub shell_prefix: Option<String>,
    pub created_at_ms: i64,
    pub expires_at_ms: i64,
    pub decision: Option<String>,
}

/// The short answer a hook needs after asking the daemon about one tool call.
/// It deliberately contains no transcript text: a hook has one job, to learn
/// whether it may proceed, not to become a second client API.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalDecision {
    pub request_id: String,
    pub decision: Option<String>,
}

fn default_mode() -> String {
    "plan".into()
}
fn default_autonomy() -> String {
    "standard".into()
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Create {
    pub workspace_id: String,
    pub title: Option<String>,
    pub backend: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub mode: Option<String>,
    pub autonomy: Option<String>,
    pub budget_seconds: Option<u64>,
    pub persona_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Update {
    pub title: Option<String>,
    pub backend: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub mode: Option<String>,
    pub autonomy: Option<String>,
    pub allowed_tools: Option<Vec<String>>,
    pub allowed_shell_prefixes: Option<Vec<String>>,
    pub budget_seconds: Option<u64>,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum StoredEvent {
    User {
        text: String,
        at_ms: i64,
    },
    Agent {
        event: Event,
        at_ms: i64,
    },
    /// An approval belongs in the transcript, not in a disconnected modal.
    /// The queue remains the source of truth for its live decision; this
    /// record preserves the place where the agent paused after it is settled.
    Approval {
        approval: Approval,
        at_ms: i64,
    },
}

#[derive(Default, Deserialize, Serialize)]
struct Index {
    #[serde(default)]
    conversations: Vec<Conversation>,
}

pub struct Store {
    root: PathBuf,
    conversations: Mutex<Vec<Conversation>>,
    active: Mutex<HashMap<String, String>>,
    personas: Mutex<Vec<Persona>>,
    approvals: Mutex<Vec<Approval>>,
    /// Per-turn credentials are intentionally memory-only. The 0600 file a
    /// hook reads contains the opaque value, while this map is what binds it
    /// to exactly one live conversation at the daemon boundary.
    turn_tokens: Mutex<HashMap<String, String>>,
}

pub fn shared() -> Arc<Store> {
    static STORE: OnceLock<Arc<Store>> = OnceLock::new();
    Arc::clone(STORE.get_or_init(|| Arc::new(Store::load())))
}

impl Store {
    #[cfg(test)]
    fn at(root: PathBuf) -> Self {
        Self {
            root,
            conversations: Mutex::new(Vec::new()),
            active: Mutex::new(HashMap::new()),
            personas: Mutex::new(Vec::new()),
            approvals: Mutex::new(Vec::new()),
            turn_tokens: Mutex::new(HashMap::new()),
        }
    }

    fn load() -> Self {
        let root = tokenstat_paths::data_dir()
            .map(|path| path.join("chat"))
            .unwrap_or_else(|| PathBuf::from("chat"));
        let conversations = fs::read(root.join("conversations.json"))
            .ok()
            .and_then(|body| serde_json::from_slice::<Index>(&body).ok())
            .map(|index| index.conversations)
            .unwrap_or_default();
        let personas = load_personas(&root);
        Self {
            root,
            conversations: Mutex::new(conversations),
            active: Mutex::new(HashMap::new()),
            personas: Mutex::new(personas),
            approvals: Mutex::new(Vec::new()),
            turn_tokens: Mutex::new(HashMap::new()),
        }
    }

    fn save(&self) -> Result<(), String> {
        let conversations = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let temp = self.root.join("conversations.tmp");
        fs::write(
            &temp,
            serde_json::to_vec_pretty(&Index { conversations }).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        fs::rename(temp, self.root.join("conversations.json")).map_err(|e| e.to_string())
    }

    pub fn list(&self, workspace_id: &str) -> Vec<Conversation> {
        let mut rows: Vec<_> = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|chat| chat.workspace_id == workspace_id)
            .cloned()
            .collect();
        rows.sort_by_key(|chat| std::cmp::Reverse(chat.updated_at_ms));
        rows
    }

    pub fn personas(&self) -> Vec<Persona> {
        self.personas
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn approvals(&self, conversation_id: Option<&str>) -> Vec<Approval> {
        self.prune_approvals();
        self.approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|approval| conversation_id.is_none_or(|id| approval.conversation_id == id))
            .filter(|approval| approval.decision.is_none())
            .cloned()
            .collect()
    }

    /// Register a backend hook request. A saved permission is answered
    /// immediately; otherwise the caller receives an id it can await without
    /// tying up a socket thread.
    pub fn request_approval(
        &self,
        conversation_id: &str,
        verb: &str,
        preview: &str,
        shell_prefix: Option<String>,
    ) -> Result<Approval, String> {
        let chat = self.get(conversation_id)?;
        let allowed = chat.allowed_tools.iter().any(|tool| tool == verb)
            || shell_prefix.as_ref().is_some_and(|prefix| {
                chat.allowed_shell_prefixes
                    .iter()
                    .any(|allowed| prefix.starts_with(allowed))
            });
        let now = now_ms();
        let approval = Approval {
            // A timestamp alone collides for back-to-back tool requests. The
            // sequence keeps request IDs unique for this daemon lifetime,
            // which is all the in-memory approval queue needs.
            id: format!(
                "approval-{now}-{}",
                APPROVAL_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ),
            conversation_id: conversation_id.into(),
            verb: verb.into(),
            preview: preview.into(),
            shell_prefix,
            created_at_ms: now,
            expires_at_ms: now + APPROVAL_TTL_MS,
            decision: allowed.then(|| "allow".into()),
        };
        if !allowed {
            self.approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(approval.clone());
            self.append(
                conversation_id,
                &StoredEvent::Approval {
                    approval: approval.clone(),
                    at_ms: now,
                },
            )?;
            // This fixed reason carries no prompt, path, or tool details.
            // Paired devices learn only that an answer is needed, then fetch
            // the ordinary protected conversation API themselves.
            tokenstat_sync::push::notify_in_background(tokenstat_sync::push::Reason::RunNeedsInput);
        }
        Ok(approval)
    }

    /// The hook-facing form never accepts a conversation id from its stdin.
    /// A leaked workspace identifier must not let an arbitrary process create
    /// approvals in someone else's conversation.
    pub fn request_turn_approval(
        &self,
        turn_token: &str,
        verb: &str,
        preview: &str,
        shell_prefix: Option<String>,
    ) -> Result<Approval, String> {
        let conversation_id = self
            .turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(turn_token)
            .cloned()
            .ok_or("the chat turn credential is invalid or expired")?;
        self.request_approval(&conversation_id, verb, preview, shell_prefix)
    }

    /// Record the outcome reported by a backend post-tool hook. Like an
    /// approval, this resolves the conversation only through the short-lived
    /// turn credential; hook input must never choose the transcript it writes.
    pub fn record_turn_result(
        &self,
        turn_token: &str,
        call_id: &str,
        ok: bool,
        detail: Option<String>,
    ) -> Result<(), String> {
        let conversation_id = self
            .turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(turn_token)
            .cloned()
            .ok_or("the chat turn credential is invalid or expired")?;
        if call_id.trim().is_empty() {
            return Err("chat.toolResult needs callId".into());
        }
        self.append(
            &conversation_id,
            &StoredEvent::Agent {
                event: Event::ToolEnd {
                    call_id: call_id.into(),
                    ok,
                    detail,
                },
                at_ms: now_ms(),
            },
        )
    }

    /// Give one spawned turn an opaque credential. This is separate from the
    /// conversation id so a hook cannot be replayed after the turn finishes.
    fn register_turn_token(&self, conversation_id: &str) -> Result<String, String> {
        let mut bytes = [0u8; 24];
        getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
        let token: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        self.turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(token.clone(), conversation_id.into());
        Ok(token)
    }

    fn revoke_turn_token(&self, token: &str) {
        self.turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(token);
    }

    /// Wait briefly for a single approval without holding the socket's session
    /// lock. Hooks call this repeatedly: a process that cannot reach us, times
    /// out, or receives an unknown request must deny rather than guessing.
    pub fn await_approval(&self, request_id: &str, wait_ms: u64) -> ApprovalDecision {
        let deadline = Instant::now() + Duration::from_millis(wait_ms.min(2_000));
        loop {
            self.prune_approvals();
            if let Some(approval) = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .iter()
                .find(|approval| approval.id == request_id)
            {
                if approval.decision.is_some() {
                    return ApprovalDecision {
                        request_id: request_id.into(),
                        decision: approval.decision.clone(),
                    };
                }
            } else {
                return ApprovalDecision {
                    request_id: request_id.into(),
                    decision: Some("deny".into()),
                };
            }
            if Instant::now() >= deadline {
                return ApprovalDecision {
                    request_id: request_id.into(),
                    decision: None,
                };
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    pub fn resolve_approval(&self, id: &str, choice: &str) -> Result<Approval, String> {
        if !matches!(choice, "allow" | "allowAlways" | "deny" | "denyAlways") {
            return Err("unknown approval choice".into());
        }
        self.prune_approvals();
        let out = {
            let mut approvals = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let approval = approvals
                .iter_mut()
                .find(|approval| approval.id == id)
                .ok_or("no pending approval with that id")?;
            if approval.decision.is_some() {
                return Err("that approval was already answered".into());
            }
            approval.decision = Some(
                if choice.starts_with("allow") {
                    "allow"
                } else {
                    "deny"
                }
                .into(),
            );
            approval.clone()
        };
        if choice.ends_with("Always") {
            let mut chats = self
                .conversations
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let chat = chats
                .iter_mut()
                .find(|chat| chat.id == out.conversation_id)
                .ok_or("no chat with that id")?;
            if let Some(prefix) = &out.shell_prefix {
                if !chat.allowed_shell_prefixes.contains(prefix) {
                    chat.allowed_shell_prefixes.push(prefix.clone());
                }
            } else if !chat.allowed_tools.contains(&out.verb) {
                chat.allowed_tools.push(out.verb.clone());
            }
            drop(chats);
            self.save()?;
        }
        Ok(out)
    }

    pub fn save_persona(&self, mut persona: Persona) -> Result<Persona, String> {
        if persona.name.trim().is_empty() {
            return Err("a persona needs a name".into());
        }
        if persona.backend.trim().is_empty() {
            return Err("a persona needs a backend".into());
        }
        if persona.id.is_empty() {
            persona.id = format!("persona-{}", now_ms());
        }
        let mut personas = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = personas
            .iter_mut()
            .find(|existing| existing.id == persona.id)
        {
            *existing = persona.clone();
        } else {
            personas.push(persona.clone());
        }
        drop(personas);
        self.save_personas()?;
        Ok(persona)
    }

    pub fn remove_persona(&self, id: &str) -> Result<bool, String> {
        let mut personas = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
        let before = personas.len();
        personas.retain(|persona| persona.id != id);
        let removed = personas.len() != before;
        drop(personas);
        if removed {
            self.save_personas()?;
        }
        Ok(removed)
    }

    pub fn create(&self, input: Create) -> Result<Conversation, String> {
        if input.workspace_id.trim().is_empty() {
            return Err("chat.create needs a workspaceId".into());
        }
        crate::workspaces::folder(&input.workspace_id)?;
        let persona = input
            .persona_id
            .as_deref()
            .map(|id| self.persona(id))
            .transpose()?;
        let backend = persona
            .as_ref()
            .map(|persona| persona.backend.clone())
            .unwrap_or(input.backend);
        if backend.trim().is_empty() {
            return Err("chat.create needs a backend".into());
        }
        let id = format!("chat-{}", now_ms());
        let now = now_ms();
        let chat = Conversation {
            id,
            workspace_id: input.workspace_id,
            title: input
                .title
                .filter(|title| !title.trim().is_empty())
                .unwrap_or_else(|| "New chat".into()),
            backend,
            persona_id: persona.as_ref().map(|persona| persona.id.clone()),
            model: persona
                .as_ref()
                .and_then(|persona| persona.model.clone())
                .or(input.model),
            effort: persona
                .as_ref()
                .and_then(|persona| persona.effort.clone())
                .or(input.effort),
            system_prompt: persona
                .as_ref()
                .map(|persona| persona.system_prompt.clone())
                .unwrap_or_default(),
            mode: persona
                .as_ref()
                .map(|persona| persona.default_mode.clone())
                .or(input.mode)
                .unwrap_or_else(default_mode),
            autonomy: persona
                .as_ref()
                .map(|persona| persona.default_autonomy.clone())
                .or(input.autonomy)
                .unwrap_or_else(default_autonomy),
            resume_token: None,
            allowed_tools: Vec::new(),
            allowed_shell_prefixes: Vec::new(),
            budget_seconds: input.budget_seconds.unwrap_or(0),
            created_at_ms: now,
            updated_at_ms: now,
            running: false,
        };
        self.conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(chat.clone());
        self.save()?;
        Ok(chat)
    }

    pub fn update(&self, id: &str, changes: Update) -> Result<Conversation, String> {
        let mut chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let chat = chats
            .iter_mut()
            .find(|chat| chat.id == id)
            .ok_or("no chat with that id")?;
        if chat.running
            && (changes.backend.is_some()
                || changes.model.is_some()
                || changes.effort.is_some()
                || changes.mode.is_some()
                || changes.autonomy.is_some())
        {
            return Err("finish or stop this turn before changing its setup".into());
        }
        if let Some(title) = changes.title.filter(|text| !text.trim().is_empty()) {
            chat.title = title;
        }
        if let Some(backend) = changes.backend {
            chat.backend = backend;
        }
        if changes.model.is_some() {
            chat.model = changes.model;
        }
        if changes.effort.is_some() {
            chat.effort = changes.effort;
        }
        if let Some(mode) = changes.mode {
            chat.mode = mode;
        }
        if let Some(autonomy) = changes.autonomy {
            chat.autonomy = autonomy;
        }
        if let Some(tools) = changes.allowed_tools {
            chat.allowed_tools = tools;
        }
        if let Some(prefixes) = changes.allowed_shell_prefixes {
            chat.allowed_shell_prefixes = prefixes;
        }
        if let Some(budget) = changes.budget_seconds {
            chat.budget_seconds = budget;
        }
        chat.updated_at_ms = now_ms();
        let out = chat.clone();
        drop(chats);
        self.save()?;
        Ok(out)
    }

    pub fn remove(&self, id: &str) -> Result<bool, String> {
        if self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(id)
        {
            return Err("stop this chat before removing it".into());
        }
        let mut chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let before = chats.len();
        chats.retain(|chat| chat.id != id);
        let removed = chats.len() != before;
        drop(chats);
        if removed {
            self.save()?;
            let _ = fs::remove_dir_all(self.root.join(id));
        }
        Ok(removed)
    }

    pub fn events(&self, id: &str, offset: u64) -> Result<(Vec<Value>, u64), String> {
        self.get(id)?;
        let path = self.events_path(id);
        let bytes = fs::read(path).unwrap_or_default();
        let start = (offset as usize).min(bytes.len());
        let end = bytes.len();
        let events = String::from_utf8_lossy(&bytes[start..end])
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect();
        Ok((events, end as u64))
    }

    pub fn attach(
        &self,
        id: &str,
        name: &str,
        data: &str,
        media_type: Option<String>,
    ) -> Result<Attachment, String> {
        self.get(id)?;
        let bytes = crate::base64::decode(data)?;
        if bytes.is_empty() {
            return Err("an attachment cannot be empty".into());
        }
        if bytes.len() > ATTACHMENT_CAP {
            return Err("an attachment is limited to 12 MB".into());
        }
        let attachment = Attachment {
            id: format!("file-{}", now_ms()),
            name: safe_file_name(name),
            media_type,
        };
        let path = self.attachment_path(id, &attachment.id, &attachment.name);
        fs::create_dir_all(path.parent().ok_or("invalid attachment path")?)
            .map_err(|e| e.to_string())?;
        fs::write(path, bytes).map_err(|e| e.to_string())?;
        Ok(attachment)
    }

    pub fn send(
        self: &Arc<Self>,
        id: &str,
        text: &str,
        attachment_ids: &[String],
    ) -> Result<Conversation, String> {
        let prompt = text.trim();
        if prompt.is_empty() {
            return Err("chat.send needs text".into());
        }
        let chat = self.get(id)?;
        if chat.running {
            return Err("this chat is already responding".into());
        }
        let workspace = crate::workspaces::folder(&chat.workspace_id)?;
        let attachments = self.attachment_paths(id, attachment_ids)?;
        let prompt = prompt_with_attachments(
            &prompt_with_system_prompt(prompt, &chat.system_prompt),
            &attachments,
        );
        let hook_command = if chat.autonomy == "standard" {
            std::env::current_exe()
                .ok()
                .and_then(|path| path.to_str().map(str::to_owned))
        } else {
            None
        };
        let argv = crate::automations::chat_agent_command(
            &chat.backend,
            &prompt,
            chat.model.as_deref(),
            chat.effort.as_deref(),
            chat.budget_seconds,
            crate::automations::ChatLaunch {
                resume: chat.resume_token.as_deref(),
                bypass: chat.autonomy == "bypass",
                hook_command: hook_command.as_deref(),
                attachments: &attachments,
            },
        )?;
        let turn = if chat.autonomy == "standard" {
            let token = self.register_turn_token(id)?;
            match self.write_turn_file(id, &token) {
                Ok(file) => Some((token, file)),
                Err(error) => {
                    self.revoke_turn_token(&token);
                    return Err(error);
                }
            }
        } else {
            None
        };
        let mut environment = Vec::new();
        if let Some((_, turn_file)) = &turn {
            environment.push((
                "TOKENSTAT_CHAT_SOCKET".into(),
                crate::server::default_socket_path()?.display().to_string(),
            ));
            environment.push((
                "TOKENSTAT_CHAT_TURN_FILE".into(),
                turn_file.display().to_string(),
            ));
        }
        let codex_hook_home = if chat.backend == "codex" && chat.autonomy == "standard" {
            let home = self.write_codex_hook_home(id, hook_command.as_deref())?;
            environment.push(("CODEX_HOME".into(), home.display().to_string()));
            Some(home)
        } else {
            None
        };
        let info = tokenstat_pty::manager()
            .spawn(&tokenstat_pty::Spawn {
                command: argv[0].clone(),
                args: argv[1..].to_vec(),
                cwd: workspace.path,
                workspace_id: Some(chat.workspace_id.clone()),
                hidden: true,
                rows: 24,
                cols: 120,
                no_color: false,
                dark: None,
                environment,
            })
            .map_err(|e| e.to_string())?;
        self.append(
            id,
            &StoredEvent::User {
                text: text.trim().into(),
                at_ms: now_ms(),
            },
        )?;
        self.active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id.into(), info.id.clone());
        let running = self.set_running(id, true)?;
        let store = Arc::clone(self);
        let chat_id = id.to_string();
        let backend = chat.backend;
        // Preserve the backend's original stream per turn. Structured events
        // are what the UI reads, but raw output lets a parser correction
        // rematerialize an older conversation without rerunning an agent.
        let raw_path = self.raw_path(id, now_ms());
        let turn_token = turn.as_ref().map(|(token, _)| token.clone());
        let turn_file = turn.as_ref().map(|(_, file)| file.clone());
        let codex_hook_home = codex_hook_home.clone();
        std::thread::spawn(move || {
            Arc::clone(&store).drain(&chat_id, &backend, &info.id, &raw_path);
            if let Some(token) = turn_token {
                store.revoke_turn_token(&token);
            }
            if let Some(file) = turn_file {
                let _ = fs::remove_file(file);
            }
            if let Some(home) = codex_hook_home {
                let _ = fs::remove_dir_all(home);
            }
        });
        Ok(running)
    }

    pub fn stop(&self, id: &str) -> Result<(), String> {
        let pty = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned()
            .ok_or("this chat is not responding")?;
        match tokenstat_pty::manager().kill(&pty) {
            Ok(()) | Err(tokenstat_pty::PtyError::NoSession(_)) => Ok(()),
            Err(error) => Err(error.to_string()),
        }
    }

    fn drain(self: Arc<Self>, id: &str, backend: &str, pty: &str, raw_path: &PathBuf) {
        let manager = tokenstat_pty::manager();
        let mut parser = Parser::new(backend);
        let reader = format!("chat:{id}");
        let mut offset = 0;
        let deadline = self.get(id).ok().and_then(|chat| {
            (chat.budget_seconds > 0)
                .then(|| Instant::now() + Duration::from_secs(chat.budget_seconds))
        });
        loop {
            if let Ok(chunk) = manager.read_for_stream(pty, &reader, offset) {
                offset = chunk.next_offset;
                if !chunk.bytes.is_empty() {
                    let _ = append_raw(raw_path, &chunk.bytes);
                    self.record_events(id, parser.push_events(&chunk.bytes));
                }
            }
            if !manager.info(pty).map(|info| info.alive).unwrap_or(false) {
                break;
            }
            if deadline.is_some_and(|when| Instant::now() >= when) {
                let _ = manager.kill(pty);
            }
            std::thread::sleep(POLL);
        }
        // One final read catches output written immediately before exit.
        if let Ok(chunk) = manager.read_for_stream(pty, &reader, offset)
            && !chunk.bytes.is_empty()
        {
            let _ = append_raw(raw_path, &chunk.bytes);
            self.record_events(id, parser.push_events(&chunk.bytes));
        }
        self.record_events(id, parser.finish_events());
        let exit = manager.info(pty).ok().and_then(|info| info.exit_code);
        self.record_events(
            id,
            vec![Event::Done {
                status: if exit == Some(0) {
                    "ok".into()
                } else {
                    "error".into()
                },
                exit_code: exit,
            }],
        );
        manager.forget_reader(pty, &reader);
        let _ = manager.close(pty);
        self.active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        let _ = self.set_running(id, false);
    }

    fn record_events(&self, id: &str, events: Vec<Event>) {
        for event in events {
            if let Event::Session { id: token } = &event {
                let _ = self.set_resume(id, token);
            }
            let _ = self.append(
                id,
                &StoredEvent::Agent {
                    event,
                    at_ms: now_ms(),
                },
            );
        }
    }

    fn append(&self, id: &str, event: &StoredEvent) -> Result<(), String> {
        let path = self.events_path(id);
        fs::create_dir_all(path.parent().ok_or("invalid chat events path")?)
            .map_err(|e| e.to_string())?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut file, event).map_err(|e| e.to_string())?;
        file.write_all(b"\n").map_err(|e| e.to_string())?;
        if file
            .metadata()
            .map(|meta| meta.len() > EVENTS_CAP)
            .unwrap_or(false)
        {
            self.cap_events(&path)?;
        }
        Ok(())
    }

    fn cap_events(&self, path: &PathBuf) -> Result<(), String> {
        let bytes = fs::read(path).map_err(|e| e.to_string())?;
        let start = bytes.len().saturating_sub(EVENTS_CAP as usize);
        let kept = bytes[start..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|at| &bytes[start + at + 1..])
            .unwrap_or(&bytes[start..]);
        fs::write(path, kept).map_err(|e| e.to_string())
    }

    fn get(&self, id: &str) -> Result<Conversation, String> {
        self.conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|chat| chat.id == id)
            .cloned()
            .ok_or_else(|| "no chat with that id".into())
    }
    fn set_running(&self, id: &str, running: bool) -> Result<Conversation, String> {
        let mut chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let chat = chats
            .iter_mut()
            .find(|chat| chat.id == id)
            .ok_or("no chat with that id")?;
        chat.running = running;
        chat.updated_at_ms = now_ms();
        let out = chat.clone();
        drop(chats);
        self.save()?;
        Ok(out)
    }
    fn set_resume(&self, id: &str, token: &str) -> Result<(), String> {
        let mut chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let chat = chats
            .iter_mut()
            .find(|chat| chat.id == id)
            .ok_or("no chat with that id")?;
        chat.resume_token = Some(token.into());
        chat.updated_at_ms = now_ms();
        drop(chats);
        self.save()
    }
    fn events_path(&self, id: &str) -> PathBuf {
        self.root.join(id).join("events.ndjson")
    }

    fn raw_path(&self, id: &str, turn_started_at_ms: i64) -> PathBuf {
        self.root
            .join(id)
            .join("raw")
            .join(format!("{turn_started_at_ms}.ndjson"))
    }

    fn write_turn_file(&self, id: &str, token: &str) -> Result<PathBuf, String> {
        let path = self.root.join(id).join(format!("turn-{}.token", now_ms()));
        fs::create_dir_all(path.parent().ok_or("invalid chat turn path")?)
            .map_err(|error| error.to_string())?;
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            // Set at creation, not afterward: a credential briefly readable
            // under the process umask would defeat the point of this file.
            options.mode(0o600);
        }
        let mut file = options.open(&path).map_err(|error| error.to_string())?;
        file.write_all(token.as_bytes())
            .map_err(|error| error.to_string())?;
        Ok(path)
    }

    fn write_codex_hook_home(&self, id: &str, command: Option<&str>) -> Result<PathBuf, String> {
        let command = command.ok_or("cannot locate the tokenstat host hook")?;
        let home = self.root.join(id).join("codex-hook");
        fs::create_dir_all(&home).map_err(|error| error.to_string())?;
        let hooks = json!({"hooks": {
            "PreToolUse": [{"hooks": [{
                "type": "command", "command": format!("{command} hook codex pre"), "timeout": 5
            }]}],
            "PostToolUse": [{"hooks": [{
                "type": "command", "command": format!("{command} hook codex post"), "timeout": 5
            }]}]
        }});
        fs::write(home.join("hooks.json"), hooks.to_string()).map_err(|error| error.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            if let Ok(user_home) = std::env::var("HOME") {
                let auth = PathBuf::from(user_home).join(".codex").join("auth.json");
                let target = home.join("auth.json");
                if auth.is_file() && !target.exists() {
                    symlink(auth, target).map_err(|error| error.to_string())?;
                }
            }
        }
        Ok(home)
    }

    fn attachment_path(&self, chat_id: &str, attachment_id: &str, name: &str) -> PathBuf {
        self.root
            .join(chat_id)
            .join("files")
            .join(attachment_id)
            .join(name)
    }

    fn attachment_paths(&self, chat_id: &str, ids: &[String]) -> Result<Vec<PathBuf>, String> {
        ids.iter()
            .map(|id| {
                if id.is_empty() || id.contains('/') || id.contains('\\') {
                    return Err("invalid attachment id".into());
                }
                let directory = self.root.join(chat_id).join("files").join(id);
                let mut files =
                    fs::read_dir(&directory).map_err(|_| "an attachment is no longer available")?;
                let file = files
                    .next()
                    .ok_or("an attachment is no longer available")?
                    .map_err(|e| e.to_string())?
                    .path();
                if files.next().is_some() {
                    return Err("invalid attachment directory".into());
                }
                Ok(file)
            })
            .collect()
    }

    fn persona(&self, id: &str) -> Result<Persona, String> {
        self.personas
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|persona| persona.id == id)
            .cloned()
            .ok_or_else(|| "no persona with that id".into())
    }

    fn save_personas(&self) -> Result<(), String> {
        let personas = self
            .personas
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let temporary = self.root.join("personas.tmp");
        fs::write(
            &temporary,
            serde_json::to_vec_pretty(&personas).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        fs::rename(temporary, self.root.join("personas.json")).map_err(|e| e.to_string())
    }

    fn prune_approvals(&self) {
        let now = now_ms();
        let mut approvals = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        for approval in approvals
            .iter_mut()
            .filter(|approval| approval.decision.is_none() && approval.expires_at_ms <= now)
        {
            approval.decision = Some("deny".into());
        }
        approvals.retain(|approval| {
            approval.decision.is_none() || approval.expires_at_ms + APPROVAL_TTL_MS > now
        });
    }
}

fn append_raw(path: &PathBuf, bytes: &[u8]) -> Result<(), String> {
    fs::create_dir_all(path.parent().ok_or("invalid chat raw path")?).map_err(|e| e.to_string())?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    file.write_all(bytes).map_err(|e| e.to_string())
}

fn safe_file_name(name: &str) -> String {
    let leaf = std::path::Path::new(name)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("attachment");
    let cleaned: String = leaf
        .chars()
        .filter(|character| !character.is_control())
        .collect();
    if cleaned.trim().is_empty() {
        "attachment".into()
    } else {
        cleaned
    }
}

fn prompt_with_attachments(prompt: &str, attachments: &[PathBuf]) -> String {
    if attachments.is_empty() {
        return prompt.to_string();
    }
    let paths = attachments
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join("\n");
    format!("{prompt}\n\nThe user attached these local files. Read them when useful:\n{paths}")
}

fn prompt_with_system_prompt(prompt: &str, system_prompt: &str) -> String {
    let system_prompt = system_prompt.trim();
    if system_prompt.is_empty() {
        return prompt.to_string();
    }
    format!("{system_prompt}\n\n---\n\n{prompt}")
}

fn load_personas(root: &Path) -> Vec<Persona> {
    fs::read(root.join("personas.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

pub fn backends() -> Vec<Value> {
    crate::automations::backends()
        .into_iter()
        .map(|mut backend| {
            if let Some(map) = backend.as_object_mut() {
                let id = map.get("id").and_then(Value::as_str).unwrap_or("");
                map.insert(
                    "gateTier".into(),
                    json!(if id == "cursor" {
                        "bypassOnly"
                    } else if id == "grok" {
                        "rules"
                    } else {
                        "full"
                    }),
                );
            }
            backend
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn conversations_are_workspace_scoped_and_events_are_offset_tailable() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        // Unit test the durable mechanics without requiring a registered folder.
        let chat = Conversation {
            id: "chat-test".into(),
            workspace_id: "workspace-a".into(),
            title: "New chat".into(),
            backend: "claude".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: default_mode(),
            autonomy: default_autonomy(),
            resume_token: None,
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        };
        store.conversations.lock().unwrap().push(chat);
        store
            .append(
                "chat-test",
                &StoredEvent::User {
                    text: "Hello".into(),
                    at_ms: 2,
                },
            )
            .unwrap();
        store
            .append(
                "chat-test",
                &StoredEvent::Agent {
                    event: Event::Text { delta: "Hi".into() },
                    at_ms: 3,
                },
            )
            .unwrap();
        let (events, next) = store.events("chat-test", 0).unwrap();
        assert_eq!(events.len(), 2);
        assert!(next > 0);
        assert!(store.list("workspace-b").is_empty());
    }

    #[test]
    fn raw_turns_are_kept_separately_from_the_structured_timeline() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let path = store.raw_path("chat-test", 42);
        append_raw(&path, b"{\"type\":\"text\"").unwrap();
        append_raw(&path, b",\"data\":\"hello\"}\n").unwrap();
        assert_eq!(
            fs::read(&path).unwrap(),
            b"{\"type\":\"text\",\"data\":\"hello\"}\n"
        );
        assert_ne!(
            path.parent().unwrap(),
            store.events_path("chat-test").parent().unwrap()
        );
    }

    #[test]
    fn attachments_are_staged_inside_the_chat_not_the_workspace() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        store.conversations.lock().unwrap().push(Conversation {
            id: "chat-test".into(),
            workspace_id: "workspace-a".into(),
            title: "New chat".into(),
            backend: "claude".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: default_mode(),
            autonomy: default_autonomy(),
            resume_token: None,
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        });
        let attachment = store
            .attach(
                "chat-test",
                "../diagram.png",
                "aGVsbG8=",
                Some("image/png".into()),
            )
            .unwrap();
        assert_eq!(attachment.name, "diagram.png");
        let files = store
            .attachment_paths("chat-test", &[attachment.id])
            .unwrap();
        assert_eq!(fs::read(&files[0]).unwrap(), b"hello");
        assert!(prompt_with_attachments("Inspect this", &files).contains("diagram.png"));
    }

    #[test]
    fn personas_persist_and_keep_existing_conversation_settings_intact() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let saved = store
            .save_persona(Persona {
                id: String::new(),
                name: "Careful reviewer".into(),
                mark: "R".into(),
                backend: "claude".into(),
                model: Some("sonnet".into()),
                effort: Some("high".into()),
                system_prompt: "Review changes carefully.".into(),
                default_mode: "plan".into(),
                default_autonomy: "standard".into(),
            })
            .unwrap();
        assert_eq!(store.personas(), vec![saved.clone()]);
        assert_eq!(
            prompt_with_system_prompt("Check this", &saved.system_prompt),
            "Review changes carefully.\n\n---\n\nCheck this"
        );
        store
            .save_persona(Persona {
                system_prompt: "A new prompt".into(),
                ..saved.clone()
            })
            .unwrap();
        assert_eq!(saved.system_prompt, "Review changes carefully.");
    }

    #[test]
    fn approvals_are_explicit_and_always_allow_is_scoped_to_one_chat() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        store.conversations.lock().unwrap().push(Conversation {
            id: "chat-test".into(),
            workspace_id: "workspace-a".into(),
            title: "New chat".into(),
            backend: "claude".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: default_mode(),
            autonomy: default_autonomy(),
            resume_token: None,
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        });
        let turn_token = store.register_turn_token("chat-test").unwrap();
        let turn_file = store.write_turn_file("chat-test", &turn_token).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&turn_file).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let _ = fs::remove_file(turn_file);
        let codex_home = store
            .write_codex_hook_home("chat-test", Some("/tmp/tokenstat-hostd"))
            .unwrap();
        let hooks = fs::read_to_string(codex_home.join("hooks.json")).unwrap();
        assert!(hooks.contains("PreToolUse"));
        assert!(hooks.contains("hook codex pre"));
        assert!(hooks.contains("PostToolUse"));
        assert!(hooks.contains("hook codex post"));
        let _ = fs::remove_dir_all(codex_home);
        let hook_approval = store
            .request_turn_approval(&turn_token, "Edit", "Edit src/main.rs", None)
            .unwrap();
        store.resolve_approval(&hook_approval.id, "deny").unwrap();
        store
            .record_turn_result(&turn_token, "call-1", false, Some("denied".into()))
            .unwrap();
        store.revoke_turn_token(&turn_token);
        assert!(
            store
                .request_turn_approval(&turn_token, "Edit", "Edit src/main.rs", None)
                .is_err()
        );
        let pending = store
            .request_approval("chat-test", "Edit", "Edit src/main.rs", None)
            .unwrap();
        assert_eq!(store.approvals(Some("chat-test")).len(), 1);
        assert_eq!(
            store.await_approval(&pending.id, 0).decision,
            None,
            "a hook gets pending without parking a connection"
        );
        let (events, _) = store.events("chat-test", 0).unwrap();
        assert_eq!(events.len(), 3);
        let event = &events[1];
        assert_eq!(event["kind"], "agent");
        assert_eq!(event["event"]["kind"], "toolEnd");
        assert_eq!(events[2]["approval"]["id"], pending.id);
        assert_eq!(
            store
                .resolve_approval(&pending.id, "allowAlways")
                .unwrap()
                .decision
                .as_deref(),
            Some("allow")
        );
        assert_eq!(
            store.await_approval(&pending.id, 0).decision.as_deref(),
            Some("allow")
        );
        assert!(store.approvals(Some("chat-test")).is_empty());
        let allowed = store
            .request_approval("chat-test", "Edit", "Edit src/lib.rs", None)
            .unwrap();
        assert_eq!(allowed.decision.as_deref(), Some("allow"));
    }
}
