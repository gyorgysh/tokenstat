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
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::transcript::{Event, Parser};

const EVENTS_CAP: u64 = 1024 * 1024;
const POLL: Duration = Duration::from_millis(400);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub workspace_id: String,
    pub title: String,
    pub backend: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
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
    User { text: String, at_ms: i64 },
    Agent { event: Event, at_ms: i64 },
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
        Self {
            root,
            conversations: Mutex::new(conversations),
            active: Mutex::new(HashMap::new()),
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

    pub fn create(&self, input: Create) -> Result<Conversation, String> {
        if input.workspace_id.trim().is_empty() {
            return Err("chat.create needs a workspaceId".into());
        }
        crate::workspaces::folder(&input.workspace_id)?;
        if input.backend.trim().is_empty() {
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
            backend: input.backend,
            model: input.model,
            effort: input.effort,
            mode: input.mode.unwrap_or_else(default_mode),
            autonomy: input.autonomy.unwrap_or_else(default_autonomy),
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

    pub fn send(self: &Arc<Self>, id: &str, text: &str) -> Result<Conversation, String> {
        let prompt = text.trim();
        if prompt.is_empty() {
            return Err("chat.send needs text".into());
        }
        let chat = self.get(id)?;
        if chat.running {
            return Err("this chat is already responding".into());
        }
        let workspace = crate::workspaces::folder(&chat.workspace_id)?;
        let argv = crate::automations::chat_agent_command(
            &chat.backend,
            prompt,
            chat.model.as_deref(),
            chat.effort.as_deref(),
            chat.budget_seconds,
            chat.resume_token.as_deref(),
        )?;
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
                environment: Vec::new(),
            })
            .map_err(|e| e.to_string())?;
        self.append(
            id,
            &StoredEvent::User {
                text: prompt.into(),
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
        std::thread::spawn(move || store.drain(&chat_id, &backend, &info.id, &raw_path));
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
            model: None,
            effort: None,
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
}
