// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Workspace-scoped conversations with local agents.
//!
//! The archive never sees this data. Conversations, prompts, and raw backend
//! output live under the host data directory and are intentionally absent from
//! sync. A chat is one short-lived process per turn; the backend's own session
//! token is what joins those processes into a conversation.

use std::collections::{HashMap, HashSet};
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
/// How long a pending approval stays answerable.
///
/// Tied to the hook's own deadline rather than picked. The hook stops waiting
/// at [`crate::chat_gate::GATE_DEADLINE_SECONDS`] and denies, so an approval
/// that outlived that is a card which can no longer do anything: pressing
/// Allow on it would report success while the tool had already been refused.
const APPROVAL_TTL_MS: i64 = crate::chat_gate::GATE_DEADLINE_SECONDS as i64 * 1000;
const POLL: Duration = Duration::from_millis(400);
/// A persona draft is one short text transform. Anything past this is a run
/// that has gone wrong, and the wizard says so rather than waiting on it.
const DRAFT_TIMEOUT: Duration = Duration::from_secs(90);
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
    pub resume_tokens: HashMap<String, String>,
    /// Which backends have already been told this conversation's standing
    /// rules, and which version of them, keyed by backend.
    ///
    /// Only backends without a system-prompt flag appear here: the rest are
    /// handed the rules again on every turn, by flag, where repetition costs
    /// nothing. For the others the rules ride inside a turn, so re-sending
    /// them every time is what put a paragraph of plumbing in front of every
    /// sentence the person wrote.
    #[serde(default)]
    pub standing_sent: HashMap<String, String>,
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

/// A voice, not a launcher.
///
/// A persona used to carry a backend, a model, an effort, a mode and an
/// autonomy: a launch preset wearing the word. Every one of those already
/// lives on the conversation and is adjustable there, so the persona was a
/// duplicate that went stale, and a persona tied to one agent could not
/// survive the conversation being handed to another.
///
/// What is left is what the word actually means: a name and a brief. It
/// composes with whatever agent the chat happens to be on, which is also what
/// lets it survive a backend switch.
///
/// Its brief is copied onto a conversation when it is applied, so editing a
/// persona later cannot rewrite a chat that is already running.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Persona {
    pub id: String,
    /// None is a shared legacy persona, available in every workspace. New
    /// records created from a workspace are scoped to that workspace.
    #[serde(default)]
    pub workspace_id: Option<String>,
    pub name: String,
    /// How this persona behaves, in the person's own words. The whole of what
    /// a persona is, beside its name.
    #[serde(default)]
    pub system_prompt: String,
    /// Drives the drawn character, and nothing else. Stable across a rename,
    /// so a persona somebody knows by its face keeps that face.
    #[serde(default)]
    pub seed: u64,
    #[serde(default)]
    pub created_at_ms: i64,
    #[serde(default)]
    pub updated_at_ms: i64,
}

/// On-disk persona file. Older installs stored a bare array. Every write is
/// this object, temporary-file plus rename.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersonaIndex {
    #[serde(default)]
    personas: Vec<Persona>,
    #[serde(default)]
    default_by_workspace: HashMap<String, String>,
}

/// Names for a workspace's first persona.
///
/// One register on purpose: short, soft, and drawn from materials, weather and
/// landscape rather than from people. A persona is a voice, not a colleague,
/// and a list of first names would invite everybody to wonder who Daniel is.
///
/// Long enough that somebody with a folder per project sees a new one each
/// time. `starter_name` walks the list from a hash of the workspace id and
/// steps forward past any name already in use, so a repeat needs more open
/// workspaces than there are names here.
const STARTER_NAMES: [&str; 48] = [
    "Alder", "Alto", "Amber", "Arbor", "Ash", "Aster", "Basil", "Birch", "Cairn", "Cedar",
    "Cinder", "Clay", "Cove", "Delta", "Dune", "Ember", "Fern", "Flint", "Glade", "Harbour",
    "Haven", "Indigo", "Iris", "Ivy", "Juniper", "Lark", "Linden", "Lumen", "Meadow", "Mesa",
    "Mica", "Nimbus", "Nori", "Onyx", "Opal", "Pico", "Pine", "Quill", "Reed", "Ridge", "Rune",
    "Sage", "Slate", "Sora", "Thistle", "Umber", "Vale", "Wren",
];

const STARTER_BRIEF: &str = "Read the code before changing it. The call sites \
and the tests around something say what it really does, which is not always \
what a request assumes. Prefer the smallest complete change, and preserve work \
that is already there. Treat edge cases and failures as seriously as the path \
that works. Reproduce a bug before fixing it. A passing suite is evidence, not \
proof: read what the tests actually assert. Do not stop at the edit. Finish \
when the change is verified, and say plainly what you checked, what you did \
not, and what the real tradeoffs were.";

/// The brief every starter carried before it was sharpened.
///
/// Kept so a starter nobody has touched can be upgraded in place. An exact
/// match means the text is ours and has never been edited, so replacing it
/// takes nothing away from anybody.
const LEGACY_STARTER_BRIEF: &str = "You understand the local context before \
changing anything. Prefer the smallest complete change. Preserve existing \
work. Explain real tradeoffs. Verify what you change.";

/// A locally staged file. The client only receives this descriptor; bytes
/// never leave the chat's host data directory except when its agent reads it.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub id: String,
    pub name: String,
    pub media_type: Option<String>,
    #[serde(default)]
    pub size: Option<u64>,
}

/// Bytes for an attachment requested by a chat client. Keeping the descriptor
/// beside them lets the same endpoint serve an inline image or a download.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentData {
    pub attachment: Attachment,
    pub data: String,
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
    pub system_prompt: Option<String>,
    pub persona_id: Option<String>,
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
        backend: String,
    },
    /// An approval belongs in the transcript, not in a disconnected modal.
    /// The queue remains the source of truth for its live decision; this
    /// record preserves the place where the agent paused after it is settled.
    Approval {
        approval: Approval,
        at_ms: i64,
    },
    /// One agent handing the conversation to another.
    ///
    /// Recorded in full, brief included, for the same reason the instructions
    /// card exists: this is text tokenstat put in front of somebody's agent,
    /// so the conversation is where they can read it.
    Handoff {
        to: String,
        brief: String,
        at_ms: i64,
    },
}

/// What an incoming backend is told, and whether the person is told about it.
struct Handover {
    brief: String,
    /// True only when the previous turn ran on a different agent.
    announce: bool,
}

/// Which agent ran the previous turn, read off the timeline.
///
/// Only `Agent` events carry a backend, so this is the last agent that
/// actually produced anything, which is the thing a handover is measured
/// against. `None` means nothing has run yet, and a first turn hands over
/// nothing.
fn last_backend(events: &[Value]) -> Option<String> {
    events.iter().rev().find_map(|event| {
        event
            .get("backend")
            .and_then(Value::as_str)
            .map(str::to_string)
    })
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
    personas: Mutex<PersonaIndex>,
    approvals: Mutex<Vec<Approval>>,
    /// Per-turn credentials are intentionally memory-only. The 0600 file a
    /// hook reads contains the opaque value, while this map is what binds it
    /// to exactly one live conversation at the daemon boundary.
    turn_tokens: Mutex<HashMap<String, TurnBinding>>,
}

#[derive(Clone)]
struct TurnBinding {
    conversation_id: String,
    backend: String,
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
            personas: Mutex::new(PersonaIndex::default()),
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
        let personas = load_persona_index(&root);
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

    /// How many conversations sit in each workspace, for sidebar badges.
    ///
    /// One pass over the in-memory index. The summary must not open
    /// transcripts or the events file to count a row.
    pub fn counts_by_workspace(&self) -> HashMap<String, usize> {
        let mut counts = HashMap::new();
        for chat in self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
        {
            *counts.entry(chat.workspace_id.clone()).or_default() += 1;
        }
        counts
    }

    /// Personas visible in this workspace, plus its default.
    ///
    /// Shared legacy records (`workspace_id` is none) remain available. New
    /// records belong to the workspace that created them. The first load of a
    /// workspace that has no default creates one locally, without calling an
    /// agent.
    pub fn personas(&self, workspace_id: &str) -> Result<Value, String> {
        let default = self.ensure_workspace_persona(workspace_id)?;
        let index = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
        let personas: Vec<Persona> = index
            .personas
            .iter()
            .filter(|persona| persona_visible(persona, workspace_id))
            .cloned()
            .collect();
        Ok(json!({
            "personas": personas,
            // Empty means this workspace has chosen to have none, which is a
            // different answer from "we have not looked yet".
            "defaultId": default.map(|persona| persona.id).unwrap_or_default(),
        }))
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
                    .any(|allowed| prefix == allowed)
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
        let binding = self
            .turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(turn_token)
            .cloned()
            .ok_or("the chat turn credential is invalid or expired")?;
        self.request_approval(&binding.conversation_id, verb, preview, shell_prefix)
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
        let binding = self
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
            &binding.conversation_id,
            &StoredEvent::Agent {
                event: Event::ToolEnd {
                    call_id: call_id.into(),
                    ok,
                    detail,
                },
                at_ms: now_ms(),
                backend: binding.backend,
            },
        )
    }

    /// Give one spawned turn an opaque credential. This is separate from the
    /// conversation id so a hook cannot be replayed after the turn finishes.
    fn register_turn_token(&self, conversation_id: &str, backend: &str) -> Result<String, String> {
        let mut bytes = [0u8; 24];
        getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
        let token: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        self.turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(
                token.clone(),
                TurnBinding {
                    conversation_id: conversation_id.into(),
                    backend: backend.into(),
                },
            );
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
        if !matches!(choice, "allow" | "allowAlways" | "deny") {
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
        if choice == "allowAlways" {
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
        // Write the answer back to the timeline. The queue holds the live
        // decision only until the request expires, so without this a
        // conversation reopened tomorrow shows a card that looks like it is
        // still waiting for an answer somebody already gave. The transcript is
        // where "what happened here" has to survive.
        self.append(
            &out.conversation_id,
            &StoredEvent::Approval {
                approval: out.clone(),
                at_ms: now_ms(),
            },
        )?;
        Ok(out)
    }

    pub fn save_persona(&self, mut persona: Persona) -> Result<Persona, String> {
        if persona.name.trim().is_empty() {
            return Err("a persona needs a name".into());
        }
        let now = now_ms();
        let mut index = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
        if persona.id.is_empty() {
            persona.id = mint_persona_id(&index.personas);
            persona.created_at_ms = now;
        }
        persona.updated_at_ms = now;
        // Derived from the id, so a persona keeps its face through a rename
        // and through every edit of its brief. A caller that wants a different
        // one sends a different seed; zero means "give me the usual one".
        if persona.seed == 0 {
            persona.seed = face_seed(&persona.id);
        }
        if let Some(existing) = index
            .personas
            .iter_mut()
            .find(|existing| existing.id == persona.id)
        {
            *existing = persona.clone();
        } else {
            index.personas.push(persona.clone());
        }
        drop(index);
        self.save_personas()?;
        Ok(persona)
    }

    /// Point this workspace's default at a persona available in it, or at
    /// nothing. Existing conversations are not rewritten.
    ///
    /// An empty id means "no persona", and it is stored rather than ignored.
    /// Without that, choosing no persona lasted exactly one conversation:
    /// `ensure_workspace_persona` saw a workspace with no default, decided
    /// that meant nobody had looked yet, and minted one again for the next
    /// chat. A workspace that wants no voice has to be able to say so.
    pub fn set_default_persona(
        &self,
        workspace_id: &str,
        persona_id: &str,
    ) -> Result<Option<Persona>, String> {
        if workspace_id.trim().is_empty() {
            return Err("chat.personaDefault needs a workspaceId".into());
        }
        if persona_id.trim().is_empty() {
            let mut index = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
            index
                .default_by_workspace
                .insert(workspace_id.to_string(), String::new());
            drop(index);
            self.save_personas()?;
            return Ok(None);
        }
        let persona = self.persona(persona_id)?;
        if !persona_visible(&persona, workspace_id) {
            return Err("that persona is not available in this workspace".into());
        }
        let mut index = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
        index
            .default_by_workspace
            .insert(workspace_id.to_string(), persona.id.clone());
        drop(index);
        self.save_personas()?;
        Ok(Some(persona))
    }

    pub fn remove_persona(&self, id: &str) -> Result<bool, String> {
        let mut index = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
        if index
            .default_by_workspace
            .values()
            .any(|default| default == id)
        {
            return Err("make another persona the default before deleting this one".into());
        }
        let before = index.personas.len();
        index.personas.retain(|persona| persona.id != id);
        let removed = index.personas.len() != before;
        drop(index);
        if removed {
            self.save_personas()?;
        }
        Ok(removed)
    }

    /// Draft a persona from a sentence about what it should be good at.
    ///
    /// One short turn on an installed agent, run to completion here rather
    /// than streamed, because a wizard step needs its answer in one press and
    /// there is nothing worth watching. Bypass, in a temporary directory, and
    /// with a hard cap: this is a text transform, it has no business touching
    /// anybody's project and no business running for a minute.
    ///
    /// **The result is a draft in a form, never a saved persona.** Generated
    /// text goes into fields the person can edit and has to press Save on.
    pub fn draft_persona(
        &self,
        brief: &str,
        backend: &str,
        name: Option<&str>,
    ) -> Result<Value, String> {
        let brief = brief.trim();
        if brief.is_empty() {
            return Err("say what this persona should be good at".into());
        }
        if backend.trim().is_empty() || backend == "sh" {
            return Err("pick an agent to write the draft".into());
        }
        let argv = crate::automations::agent_command(
            backend,
            &draft_prompt(brief, name),
            None,
            None,
            DRAFT_TIMEOUT.as_secs(),
        )?;
        // Its own directory, not the workspace. A draft is a sentence in and a
        // sentence out; giving it somebody's repository to sit in would be
        // handing it a chance to do something nobody asked for.
        let cwd = std::env::temp_dir().join("tokenstat-persona-draft");
        fs::create_dir_all(&cwd).map_err(|error| error.to_string())?;
        let manager = tokenstat_pty::manager();
        let info = manager
            .spawn(&tokenstat_pty::Spawn {
                command: argv[0].clone(),
                args: argv[1..].to_vec(),
                cwd,
                workspace_id: None,
                hidden: true,
                rows: 24,
                cols: 120,
                no_color: false,
                dark: None,
                environment: Vec::new(),
            })
            .map_err(|error| error.to_string())?;

        let mut parser = Parser::new(backend);
        let reader = format!("persona-draft:{}", info.id);
        let mut offset = 0;
        let mut text = String::new();
        let deadline = Instant::now() + DRAFT_TIMEOUT;
        loop {
            if let Ok(chunk) = manager.read_for_stream(&info.id, &reader, offset) {
                offset = chunk.next_offset;
                if !chunk.bytes.is_empty() {
                    collect_agent_text(&parser.push_events(&chunk.bytes), &mut text);
                }
            }
            if !manager.info(&info.id).map(|it| it.alive).unwrap_or(false) {
                break;
            }
            if Instant::now() >= deadline {
                let _ = manager.kill(&info.id);
                return Err("the draft took too long, so nothing was written".into());
            }
            std::thread::sleep(POLL);
        }
        if let Ok(chunk) = manager.read_for_stream(&info.id, &reader, offset) {
            collect_agent_text(&parser.push_events(&chunk.bytes), &mut text);
        }
        collect_agent_text(&parser.finish_events(), &mut text);
        finish_draft(&text, brief, name)
    }

    pub fn create(&self, input: Create) -> Result<Conversation, String> {
        if input.workspace_id.trim().is_empty() {
            return Err("chat.create needs a workspaceId".into());
        }
        crate::workspaces::folder(&input.workspace_id)?;
        // Omitted means the workspace default. An explicit empty id is No
        // persona. Either way, existing chats are left alone.
        let persona =
            self.resolve_create_persona(&input.workspace_id, input.persona_id.as_deref())?;
        // A persona no longer names an agent, so the agent is the caller's
        // choice or the conversation's default. That is what lets one persona
        // be used with any backend, and survive a switch mid-conversation.
        let backend = input.backend;
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
            model: input.model,
            effort: input.effort,
            system_prompt: persona
                .as_ref()
                .map(|persona| persona.system_prompt.clone())
                .unwrap_or_default(),
            mode: input.mode.unwrap_or_else(default_mode),
            autonomy: input.autonomy.unwrap_or_else(default_autonomy),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
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
            if backend != chat.backend {
                chat.backend = backend;
                // A model/effort value and a backend session are backend-
                // specific. Do not send stale setup or a legacy token to the
                // newly selected agent. A previously used backend can still
                // recover its own token from `resume_tokens`.
                chat.model = None;
                chat.effort = None;
                chat.resume_token = chat.resume_tokens.get(&chat.backend).cloned();
            }
        }
        if let Some(model) = changes.model {
            chat.model = Some(model).filter(|value| !value.trim().is_empty());
        }
        if let Some(effort) = changes.effort {
            chat.effort = Some(effort).filter(|value| !value.trim().is_empty());
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
        if let Some(prompt) = changes.system_prompt {
            chat.system_prompt = prompt;
        }
        if let Some(persona_id) = changes.persona_id {
            let trimmed = persona_id.trim();
            chat.persona_id = if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            };
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

    pub fn remove_all(&self, workspace_id: &str) -> Result<usize, String> {
        let targets: Vec<String> = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|chat| chat.workspace_id == workspace_id)
            .map(|chat| chat.id.clone())
            .collect();
        let active = self.active.lock().unwrap_or_else(PoisonError::into_inner);
        if targets.iter().any(|id| active.contains_key(id)) {
            return Err("stop the running chats before removing them".into());
        }
        drop(active);
        if targets.is_empty() {
            return Ok(0);
        }
        let target_set: HashSet<&str> = targets.iter().map(String::as_str).collect();
        self.conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|chat| !target_set.contains(chat.id.as_str()));
        self.save()?;
        for id in &targets {
            let _ = fs::remove_dir_all(self.root.join(id));
        }
        Ok(targets.len())
    }

    /// What this conversation tells its agent before it hears the person.
    ///
    /// Split into the two halves deliberately. `brief` is the person's own
    /// words and is theirs to edit. `added` is the one rule tokenstat puts in
    /// every conversation, and it is shown rather than hidden: a product that
    /// quietly appends instructions to somebody's chat should at minimum let
    /// them read what it appended.
    /// What this conversation's persona is called, or empty.
    ///
    /// Read live from the persona rather than copied onto the conversation
    /// the way its brief is. A brief is a copy on purpose, so editing a
    /// persona does not rewrite what old conversations were told. A name is
    /// identity: rename Lumen and the chats wearing that face are talking to
    /// the renamed one, because that is the name on screen beside them.
    fn persona_name(&self, chat: &Conversation) -> String {
        chat.persona_id
            .as_deref()
            .and_then(|id| self.persona(id).ok())
            .map(|persona| persona.name)
            .unwrap_or_default()
    }

    pub fn instructions(&self, id: &str) -> Result<Value, String> {
        let chat = self.get(id)?;
        let name = self.persona_name(&chat);
        // What tokenstat adds, shown exactly as the agent gets it. The name
        // belongs on this side rather than in the brief: it is ours, not
        // something the person wrote, and it must not become editable text
        // that can drift from the name on the persona.
        let mut added = String::new();
        if !name.trim().is_empty() {
            added.push_str(&crate::chat_turn::name_rule(name.trim()));
            added.push_str("\n\n");
        }
        added.push_str(&crate::chat_turn::file_rule(&self.response_output_dir(id)));
        Ok(json!({
            "brief": chat.system_prompt,
            "added": added,
            "channel": if crate::chat_turn::accepts_system_prompt(&chat.backend) {
                "systemPrompt"
            } else {
                "turnPrefix"
            },
        }))
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

    /// The handover an incoming backend should be given, if any.
    ///
    /// Due whenever this conversation has history and the backend about to run
    /// has no session of its own to resume. That is not the same question as
    /// whether the conversation changed hands, which is why `announce` is
    /// separate: an agent that cannot resume itself needs the summary on every
    /// turn, and saying "handed to" every turn described a switch that never
    /// happened.
    fn handover(&self, chat: &Conversation) -> Result<Option<Handover>, String> {
        if chat.resume_tokens.contains_key(&chat.backend) {
            return Ok(None);
        }
        let (events, _) = self.events(&chat.id, 0)?;
        let folder = crate::workspaces::folder(&chat.workspace_id)
            .map(|workspace| workspace.path.display().to_string())
            .unwrap_or_default();
        let brief = crate::chat_brain::brief(&events, &folder, crate::chat_brain::BUDGET);
        if brief.is_empty() {
            return Ok(None);
        }
        let previous = last_backend(&events);
        Ok(Some(Handover {
            announce: previous.is_some_and(|name| name != chat.backend),
            brief,
        }))
    }

    /// Keep the handover on disk beside the timeline it was folded from.
    ///
    /// Three reasons, all real: a person can read what their agent was told,
    /// a later parser fix can regenerate it, and a backend with a file-reading
    /// tool can be pointed at the path rather than handed the whole text.
    fn write_brain(&self, id: &str, brief: &str) -> Result<(), String> {
        let path = self.root.join(id).join("brain.md");
        fs::create_dir_all(path.parent().ok_or("invalid chat path")?)
            .map_err(|error| error.to_string())?;
        fs::write(path, brief).map_err(|error| error.to_string())
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
            size: Some(bytes.len() as u64),
        };
        let path = self.attachment_path(id, &attachment.id, &attachment.name);
        fs::create_dir_all(path.parent().ok_or("invalid attachment path")?)
            .map_err(|e| e.to_string())?;
        fs::write(path, bytes).map_err(|e| e.to_string())?;
        Ok(attachment)
    }

    pub fn attachment_data(&self, id: &str, attachment_id: &str) -> Result<AttachmentData, String> {
        self.get(id)?;
        let path = self.single_attachment_path(id, attachment_id)?;
        let bytes = fs::read(&path).map_err(|_| "the attachment is no longer available")?;
        if bytes.len() > ATTACHMENT_CAP {
            return Err("the attachment is too large to transfer".into());
        }
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .map(safe_file_name)
            .unwrap_or_else(|| "attachment".into());
        Ok(AttachmentData {
            attachment: Attachment {
                id: attachment_id.into(),
                media_type: media_type_for_path(&path),
                size: Some(bytes.len() as u64),
                name,
            },
            data: crate::base64::encode(&bytes),
        })
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
        let response_output_dir = self.response_output_dir(id);
        fs::create_dir_all(&response_output_dir).map_err(|e| e.to_string())?;
        let resume_token = chat
            .resume_tokens
            .get(&chat.backend)
            .map(String::as_str)
            .or_else(|| {
                // Existing conversations predate the per-backend map. Their
                // legacy token is safe only until the first backend switch,
                // which clears it above.
                chat.resume_tokens
                    .is_empty()
                    .then_some(chat.resume_token.as_deref())
                    .flatten()
            });
        let composed = crate::chat_turn::compose(crate::chat_turn::Inputs {
            prompt,
            persona_name: &self.persona_name(&chat),
            persona_brief: &chat.system_prompt,
            attachments: &attachments,
            output_dir: &response_output_dir,
            backend: &chat.backend,
        });
        // Two separate things ride the same channel this turn. The standing
        // rules repeat for as long as they are unchanged; the handover is sent
        // exactly once, to the agent that has just been handed a conversation
        // it did not have.
        let standing_due = standing_is_due(&chat, &composed.standing_fingerprint);
        let handover = self.handover(&chat)?;
        let mut instructions = String::new();
        if standing_due {
            instructions.push_str(&composed.standing_text);
        }
        if let Some(handover) = &handover {
            if !instructions.is_empty() {
                instructions.push_str("\n\n");
            }
            instructions.push_str(&handover.brief);
        }
        let system_append = (!instructions.is_empty()).then_some(instructions.as_str());
        let prompt = composed.user_text.as_str();
        // The daemon asks its own tool calls back through itself. A relative
        // PATH lookup would be wrong under launchd and inside the private
        // environment an agent CLI runs in, so this is the absolute path and
        // `chat_gate` is what turns it into a runnable command line.
        let helper = if chat.autonomy == "standard" {
            Some(std::env::current_exe().map_err(|_| "cannot locate the tokenstat host hook")?)
        } else {
            None
        };
        let agy_customization_dir =
            (chat.backend == "agy" && chat.autonomy == "standard").then(|| self.agy_hook_home(id));
        let grok_allow_rules = grok_allow_rules(&chat);
        let argv = crate::automations::chat_agent_command(
            &chat.backend,
            prompt,
            chat.model.as_deref(),
            chat.effort.as_deref(),
            chat.budget_seconds,
            crate::automations::ChatLaunch {
                resume: resume_token,
                bypass: chat.autonomy == "bypass",
                mode: &chat.mode,
                hook_helper: helper.as_deref(),
                system_append,
                agy_customization_dir: agy_customization_dir.as_deref(),
                grok_allow_rules: &grok_allow_rules,
                attachments: &attachments,
            },
        )?;
        let turn = if chat.autonomy == "standard" {
            let token = self.register_turn_token(id, &chat.backend)?;
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
            // The hook must decide before the CLI's own timeout kills it. A
            // killed hook is a non-blocking error to every one of these
            // backends, which means the tool runs.
            environment.push((
                crate::chat_gate::DEADLINE_ENV.into(),
                crate::chat_gate::GATE_DEADLINE_SECONDS.to_string(),
            ));
        }
        let codex_hook_home = if chat.backend == "codex"
            && let Some(helper) = &helper
        {
            let home = self.root.join(id).join("codex-hook");
            crate::chat_gate::write_codex_home(&home, helper)?;
            environment.push(("CODEX_HOME".into(), home.display().to_string()));
            Some(home)
        } else {
            None
        };
        // Grok is the one home that outlives its turn. Its sessions live under
        // `$GROK_HOME`, so rebuilding it per turn would take `--resume` with
        // it and every message would start a new conversation.
        if chat.backend == "grok"
            && let Some(helper) = &helper
        {
            let home = self.grok_hook_home(id);
            crate::chat_gate::write_grok_home(&home, helper)?;
            environment.push(("GROK_HOME".into(), home.display().to_string()));
        }
        let agy_hook_home = if chat.backend == "agy"
            && let Some(helper) = &helper
        {
            let home = self.agy_hook_home(id);
            crate::chat_gate::write_agy_home(&home, helper)?;
            Some(home)
        } else {
            None
        };
        let opencode_hook_home = if matches!(chat.backend.as_str(), "opencode" | "opencode2")
            && let Some(helper) = &helper
        {
            let (home, plugin) = self.write_opencode_hook_home(id)?;
            environment.push(("OPENCODE_CONFIG_DIR".into(), home.display().to_string()));
            environment.push((
                "OPENCODE_CONFIG_CONTENT".into(),
                json!({
                    "plugin": [plugin.display().to_string()],
                    "permission": {
                        "edit": "allow",
                        "bash": "allow",
                        "webfetch": "allow",
                        "external_directory": "allow"
                    }
                })
                .to_string(),
            ));
            // The raw path, not a command line. The plugin spawns this as
            // argv rather than through a shell, so the quoting every other
            // backend needs would become part of the filename here. The
            // variable is named for which of the two it carries.
            environment.push((
                crate::chat_gate::HELPER_PATH_ENV.into(),
                helper.display().to_string(),
            ));
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
        // Only once the process exists. A spawn that failed delivered nothing,
        // and marking it sent would silently drop this conversation's rules
        // from every later turn on that backend.
        if standing_due {
            self.mark_standing_sent(id, &chat.backend, &composed.standing_fingerprint)?;
        }
        // The handover goes on the timeline, brief and all. It is text
        // tokenstat put in front of somebody's agent, so their conversation is
        // where it should be readable. Only when the conversation actually
        // changed hands, though: the same agent being handed its own history
        // again is plumbing, and a row saying so after every reply reads as
        // the chat talking to itself. `brain.md` is still written either way,
        // so what the agent was told is always on disk.
        if let Some(handover) = &handover {
            self.write_brain(id, &handover.brief)?;
            if handover.announce {
                self.append(
                    id,
                    &StoredEvent::Handoff {
                        to: chat.backend.clone(),
                        brief: handover.brief.clone(),
                        at_ms: now_ms(),
                    },
                )?;
            }
        }
        self.append(
            id,
            &StoredEvent::User {
                text: text.trim().into(),
                at_ms: now_ms(),
            },
        )?;
        self.retitle_if_untitled(id, text.trim())?;
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
        let agy_hook_home = agy_hook_home.clone();
        let opencode_hook_home = opencode_hook_home.clone();
        let response_output_dir = response_output_dir.clone();
        std::thread::spawn(move || {
            Arc::clone(&store).drain(
                &chat_id,
                &backend,
                &info.id,
                &raw_path,
                &response_output_dir,
            );
            let _ = fs::remove_dir_all(&response_output_dir);
            if let Some(token) = turn_token {
                store.revoke_turn_token(&token);
            }
            if let Some(file) = turn_file {
                let _ = fs::remove_file(file);
            }
            if let Some(home) = codex_hook_home {
                let _ = fs::remove_dir_all(home);
            }
            if let Some(home) = agy_hook_home {
                let _ = fs::remove_dir_all(home);
            }
            if let Some(home) = opencode_hook_home {
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
            .cloned();
        if let Some(pty) = pty {
            match tokenstat_pty::manager().kill(&pty) {
                Ok(()) | Err(tokenstat_pty::PtyError::NoSession(_)) => {}
                Err(error) => return Err(error.to_string()),
            }
        } else {
            // A daemon restart can leave the persisted bit behind without an
            // in-memory PTY. Clear that stale state, but keep a live turn
            // marked running until its drain thread observes process exit.
            self.set_running(id, false)?;
        }
        Ok(())
    }

    fn drain(
        self: Arc<Self>,
        id: &str,
        backend: &str,
        pty: &str,
        raw_path: &PathBuf,
        response_output_dir: &Path,
    ) {
        let manager = tokenstat_pty::manager();
        let mut parser = Parser::new(backend);
        let reader = format!("chat:{id}");
        let mut offset = 0;
        let mut assistant_text = String::new();
        let deadline = self.get(id).ok().and_then(|chat| {
            (chat.budget_seconds > 0)
                .then(|| Instant::now() + Duration::from_secs(chat.budget_seconds))
        });
        loop {
            if let Ok(chunk) = manager.read_for_stream(pty, &reader, offset) {
                offset = chunk.next_offset;
                if !chunk.bytes.is_empty() {
                    let _ = append_raw(raw_path, &chunk.bytes);
                    let events = parser.push_events(&chunk.bytes);
                    collect_agent_text(&events, &mut assistant_text);
                    self.record_events(id, backend, events);
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
            let events = parser.push_events(&chunk.bytes);
            collect_agent_text(&events, &mut assistant_text);
            self.record_events(id, backend, events);
        }
        let events = parser.finish_events();
        collect_agent_text(&events, &mut assistant_text);
        self.record_events(id, backend, events);
        self.record_response_attachments(id, backend, &assistant_text, response_output_dir);
        let exit = manager.info(pty).ok().and_then(|info| info.exit_code);
        self.record_events(
            id,
            backend,
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

    fn record_events(&self, id: &str, backend: &str, events: Vec<Event>) {
        for event in events {
            if let Event::Session { id: token } = &event {
                let _ = self.set_resume(id, backend, token);
            }
            let _ = self.append(
                id,
                &StoredEvent::Agent {
                    event,
                    at_ms: now_ms(),
                    backend: backend.into(),
                },
            );
        }
    }

    /// Turn explicit local-file links in the final reply into durable chat
    /// attachments. The link is the agent's declaration of intent; arbitrary
    /// paths mentioned in prose or printed by a tool are never copied.
    fn record_response_attachments(
        &self,
        id: &str,
        backend: &str,
        text: &str,
        response_output_dir: &Path,
    ) {
        let Ok(output_root) = fs::canonicalize(response_output_dir) else {
            return;
        };
        for (index, source) in response_file_paths(text).into_iter().enumerate() {
            let Ok(source) = fs::canonicalize(&source) else {
                continue;
            };
            if source == output_root || !source.starts_with(&output_root) {
                continue;
            }
            let Ok(link_metadata) = fs::symlink_metadata(&source) else {
                continue;
            };
            if !link_metadata.file_type().is_file() {
                continue;
            }
            let Ok(metadata) = fs::metadata(&source) else {
                continue;
            };
            if !metadata.is_file() || metadata.len() == 0 || metadata.len() > ATTACHMENT_CAP as u64
            {
                continue;
            }
            let Some(source_name) = source.file_name().and_then(|value| value.to_str()) else {
                continue;
            };
            let name = safe_file_name(source_name);
            let attachment_id = format!("output-{}-{index}", now_ms());
            let destination = self.attachment_path(id, &attachment_id, &name);
            let Some(parent) = destination.parent() else {
                continue;
            };
            if fs::create_dir_all(parent).is_err() || fs::copy(&source, &destination).is_err() {
                continue;
            }
            let _ = self.append(
                id,
                &StoredEvent::Agent {
                    event: Event::Attachment {
                        id: attachment_id,
                        name,
                        media_type: media_type_for_path(&source),
                        size: metadata.len(),
                    },
                    at_ms: now_ms(),
                    backend: backend.into(),
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
    fn retitle_if_untitled(&self, id: &str, prompt: &str) -> Result<(), String> {
        let mut chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let chat = chats
            .iter_mut()
            .find(|chat| chat.id == id)
            .ok_or("no chat with that id")?;
        if chat.title == "New chat" {
            chat.title = title_from_prompt(prompt);
            chat.updated_at_ms = now_ms();
        }
        drop(chats);
        self.save()
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
    fn set_resume(&self, id: &str, backend: &str, token: &str) -> Result<(), String> {
        let mut chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let chat = chats
            .iter_mut()
            .find(|chat| chat.id == id)
            .ok_or("no chat with that id")?;
        chat.resume_tokens.insert(backend.into(), token.into());
        chat.resume_token = Some(token.into());
        chat.updated_at_ms = now_ms();
        drop(chats);
        self.save()
    }
    /// Remember that one backend now holds this version of the conversation's
    /// standing rules, so the next turn on it can be the person's words alone.
    fn mark_standing_sent(&self, id: &str, backend: &str, fingerprint: &str) -> Result<(), String> {
        let mut chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let chat = chats
            .iter_mut()
            .find(|chat| chat.id == id)
            .ok_or("no chat with that id")?;
        chat.standing_sent
            .insert(backend.into(), fingerprint.into());
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

    fn response_output_dir(&self, id: &str) -> PathBuf {
        std::env::temp_dir()
            .join("tokenstat-chat-output")
            .join(safe_file_name(id))
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

    fn agy_hook_home(&self, id: &str) -> PathBuf {
        self.root.join(id).join("agy-hook")
    }

    /// Persistent for the life of the conversation, unlike the other homes.
    /// See `chat_gate::write_grok_home`: grok keeps its sessions in here, so
    /// deleting it after a turn would delete the thing `--resume` needs.
    fn grok_hook_home(&self, id: &str) -> PathBuf {
        self.root.join(id).join("grok-home")
    }

    fn write_opencode_hook_home(&self, id: &str) -> Result<(PathBuf, PathBuf), String> {
        let home = self.root.join(id).join("opencode-hook");
        fs::create_dir_all(&home).map_err(|error| error.to_string())?;
        let plugin = home.join("tokenstat-gate.js");
        fs::write(
            &plugin,
            include_str!("../../../scripts/cli-bridge/opencode-plugin.js"),
        )
        .map_err(|error| error.to_string())?;
        Ok((home, plugin))
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
            .map(|id| self.single_attachment_path(chat_id, id))
            .collect()
    }

    fn single_attachment_path(&self, chat_id: &str, id: &str) -> Result<PathBuf, String> {
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
        if files.next().is_some() || !file.is_file() {
            return Err("invalid attachment directory".into());
        }
        Ok(file)
    }

    fn resolve_create_persona(
        &self,
        workspace_id: &str,
        persona_id: Option<&str>,
    ) -> Result<Option<Persona>, String> {
        match persona_id {
            None => self.ensure_workspace_persona(workspace_id),
            Some(id) if id.trim().is_empty() => Ok(None),
            Some(id) => Ok(Some(self.persona(id)?)),
        }
    }

    fn persona(&self, id: &str) -> Result<Persona, String> {
        self.personas
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .personas
            .iter()
            .find(|persona| persona.id == id)
            .cloned()
            .ok_or_else(|| "no persona with that id".into())
    }

    /// The workspace default, creating a local starter if this folder has
    /// never had one. `None` when the workspace has chosen to have none.
    ///
    /// Never calls an agent. The name is picked from a product-owned set from
    /// the workspace id, and a collision advances through that set.
    pub fn ensure_workspace_persona(&self, workspace_id: &str) -> Result<Option<Persona>, String> {
        if workspace_id.trim().is_empty() {
            return Err("chat.personas needs a workspaceId".into());
        }
        let mut index = self.personas.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(id) = index.default_by_workspace.get(workspace_id).cloned() {
            // A stored empty id is a decision, not a gap. Nothing is minted
            // and nothing is adopted: this workspace wants no persona.
            if id.is_empty() {
                return Ok(None);
            }
            if let Some(persona) = index
                .personas
                .iter()
                .find(|persona| persona.id == id && persona_visible(persona, workspace_id))
                .cloned()
            {
                return Ok(Some(persona));
            }
        }
        if let Some(persona) = index
            .personas
            .iter()
            .find(|persona| persona.workspace_id.as_deref() == Some(workspace_id))
            .cloned()
        {
            index
                .default_by_workspace
                .insert(workspace_id.to_string(), persona.id.clone());
            drop(index);
            self.save_personas()?;
            return Ok(Some(persona));
        }
        let taken: HashSet<String> = index
            .personas
            .iter()
            .filter(|persona| persona_visible(persona, workspace_id))
            .map(|persona| persona.name.clone())
            .collect();
        let name = starter_name(workspace_id, &taken);
        let now = now_ms();
        let id = mint_persona_id(&index.personas);
        let persona = Persona {
            id: id.clone(),
            workspace_id: Some(workspace_id.to_string()),
            name: name.to_string(),
            system_prompt: STARTER_BRIEF.to_string(),
            seed: face_seed(&id),
            created_at_ms: now,
            updated_at_ms: now,
        };
        index.personas.push(persona.clone());
        index
            .default_by_workspace
            .insert(workspace_id.to_string(), id);
        drop(index);
        self.save_personas()?;
        Ok(Some(persona))
    }

    fn save_personas(&self) -> Result<(), String> {
        let index = self
            .personas
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let temporary = self.root.join("personas.tmp");
        fs::write(
            &temporary,
            serde_json::to_vec_pretty(&index).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        fs::rename(temporary, self.root.join("personas.json")).map_err(|e| e.to_string())
    }

    /// Settle anything nobody answered, and forget what is long settled.
    ///
    /// A timeout is a denial, and it goes onto the timeline like any other, so
    /// a person coming back to the conversation reads "this was refused
    /// because nobody was here" rather than a card frozen mid-question.
    fn prune_approvals(&self) {
        let now = now_ms();
        let expired: Vec<Approval> = {
            let mut approvals = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let expired = approvals
                .iter_mut()
                .filter(|approval| approval.decision.is_none() && approval.expires_at_ms <= now)
                .map(|approval| {
                    approval.decision = Some("deny".into());
                    approval.clone()
                })
                .collect();
            approvals.retain(|approval| {
                approval.decision.is_none() || approval.expires_at_ms + APPROVAL_TTL_MS > now
            });
            expired
        };
        for approval in expired {
            let conversation_id = approval.conversation_id.clone();
            let _ = self.append(
                &conversation_id,
                &StoredEvent::Approval {
                    approval,
                    at_ms: now,
                },
            );
        }
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

fn collect_agent_text(events: &[Event], text: &mut String) {
    for event in events {
        if let Event::Text { delta } = event {
            text.push_str(delta);
        }
    }
}

/// Extract only Markdown destinations that unambiguously name a local file.
/// Plain paths in prose and command output do not count as consent to copy.
fn response_file_paths(text: &str) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    let mut seen = HashSet::new();
    let mut rest = text;
    while let Some(open) = rest.find("](") {
        rest = &rest[open + 2..];
        let Some(close) = rest.find(')') else { break };
        let raw = rest[..close].trim();
        rest = &rest[close + 1..];
        let destination = if raw.starts_with('<') && raw.ends_with('>') {
            &raw[1..raw.len() - 1]
        } else if raw.contains(char::is_whitespace) {
            // Markdown titles and unwrapped paths with spaces are ambiguous.
            // The prompt tells agents to use angle brackets for that case.
            continue;
        } else {
            raw
        };
        let local = destination
            .strip_prefix("file://")
            .or_else(|| destination.strip_prefix("sandbox:"))
            .unwrap_or(destination);
        if !local.starts_with('/') {
            continue;
        }
        let decoded = percent_decode_path(local);
        let path = PathBuf::from(decoded);
        let key = path.to_string_lossy().to_string();
        if seen.insert(key) {
            paths.push(path);
        }
    }
    paths
}

fn percent_decode_path(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && let (Some(high), Some(low)) =
                (hex_digit(bytes[index + 1]), hex_digit(bytes[index + 2]))
        {
            output.push(high * 16 + low);
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn hex_digit(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn media_type_for_path(path: &Path) -> Option<String> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(
        match extension.as_str() {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "webp" => "image/webp",
            "heic" | "heif" => "image/heic",
            "svg" => "image/svg+xml",
            "pdf" => "application/pdf",
            "txt" | "log" => "text/plain",
            "md" | "markdown" => "text/markdown",
            "json" => "application/json",
            "csv" => "text/csv",
            "html" | "htm" => "text/html",
            "mp3" => "audio/mpeg",
            "wav" => "audio/wav",
            "m4a" => "audio/mp4",
            "mp4" => "video/mp4",
            "mov" => "video/quicktime",
            "zip" => "application/zip",
            _ => "application/octet-stream",
        }
        .into(),
    )
}

/// Whether this turn has to carry the conversation's standing rules.
///
/// A backend with a system-prompt flag is given them every turn, because a
/// flag costs nothing and re-sending is what makes editing a persona take
/// effect immediately. A backend without one has them prepended to the turn,
/// so it is told only when it has not already seen this exact version. Sending
/// them every time is what put a paragraph of plumbing in front of every
/// sentence somebody wrote.
fn standing_is_due(chat: &Conversation, fingerprint: &str) -> bool {
    crate::chat_turn::accepts_system_prompt(&chat.backend)
        || chat.standing_sent.get(&chat.backend).map(String::as_str) != Some(fingerprint)
}

fn title_from_prompt(prompt: &str) -> String {
    let line = prompt
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("New chat");
    let mut chars = line.chars();
    let title: String = chars.by_ref().take(48).collect();
    if chars.next().is_some() {
        format!("{title}…")
    } else {
        title.to_string()
    }
}

/// Read the saved personas, bringing older ones forward.
///
/// A persona used to carry a backend, model, effort, mark and autonomy. Serde
/// drops those on the way in, which is the whole migration for them: they were
/// duplicates of conversation state and there is nothing to preserve. The one
/// field that has to be filled is the face seed, because a persona saved
/// before faces existed must not get a different one on every launch.
///
/// The file used to be a bare array. Missing `workspace_id` is the shared
/// legacy case: those records stay available everywhere and are never
/// reassigned.
fn load_persona_index(root: &Path) -> PersonaIndex {
    let bytes = match fs::read(root.join("personas.json")) {
        Ok(bytes) => bytes,
        Err(_) => return PersonaIndex::default(),
    };
    let mut index = if let Ok(index) = serde_json::from_slice::<PersonaIndex>(&bytes) {
        index
    } else if let Ok(personas) = serde_json::from_slice::<Vec<Persona>>(&bytes) {
        PersonaIndex {
            personas,
            default_by_workspace: HashMap::new(),
        }
    } else {
        PersonaIndex::default()
    };
    for persona in &mut index.personas {
        if persona.seed == 0 {
            persona.seed = face_seed(&persona.id);
        }
        // Only an exact match, so a brief somebody has written a single word
        // into is left exactly as they left it.
        if persona.system_prompt == LEGACY_STARTER_BRIEF {
            persona.system_prompt = STARTER_BRIEF.to_string();
        }
    }
    index
}

fn persona_visible(persona: &Persona, workspace_id: &str) -> bool {
    match persona.workspace_id.as_deref() {
        None => true,
        Some(owner) => owner == workspace_id,
    }
}

fn mint_persona_id(existing: &[Persona]) -> String {
    let now = now_ms();
    let mut n = 0u32;
    loop {
        let id = if n == 0 {
            format!("persona-{now}")
        } else {
            format!("persona-{now}-{n}")
        };
        if !existing.iter().any(|persona| persona.id == id) {
            return id;
        }
        n = n.saturating_add(1);
    }
}

fn starter_name(workspace_id: &str, taken: &HashSet<String>) -> &'static str {
    let start = (crate::chat_turn::stable_hash(workspace_id) as usize) % STARTER_NAMES.len();
    for offset in 0..STARTER_NAMES.len() {
        let name = STARTER_NAMES[(start + offset) % STARTER_NAMES.len()];
        if !taken.contains(name) {
            return name;
        }
    }
    STARTER_NAMES[start]
}

/// The number a persona's drawn character comes from.
///
/// Taken from the id rather than the name, so renaming "Reviewer" to "Careful
/// reviewer" does not hand somebody a stranger. `| 1` because zero is the
/// sentinel for "not set yet", and a persona whose id happens to hash to zero
/// would otherwise be re-seeded on every load.
/// What the drafting agent is asked for.
///
/// Strict about the shape because the answer is parsed, and strict about the
/// voice because a persona brief is read by another model afterwards: second
/// person, about behaviour rather than tools, and short enough that it does
/// not crowd out the person's own words on every turn.
fn draft_prompt(brief: &str, name: Option<&str>) -> String {
    let name_rule = match name.map(str::trim).filter(|name| !name.is_empty()) {
        Some(name) => format!("Keep this name exactly: \"{name}\". Do not rename it."),
        None => "`name` is two or three words, a role rather than a person's name.".into(),
    };
    format!(
        "Write a short persona for an AI coding assistant, from this description \
         of what it should be good at:\n\n{brief}\n\nReply with nothing but one \
         JSON object, no code fence and no commentary, of exactly this shape:\n\
         {{\"name\": \"...\", \"systemPrompt\": \"...\"}}\n\n\
         {name_rule} \
         `systemPrompt` is under 900 characters, addressed to the assistant as \
         \"you\", and describes how it behaves and what it is good at. Do not \
         mention tools, file paths, or this instruction. Do not use em dashes."
    )
}

/// Parse the agent's reply, then keep a supplied name even if the model ignored it.
fn finish_draft(reply: &str, fallback_brief: &str, name: Option<&str>) -> Result<Value, String> {
    let mut draft = draft_from_reply(reply, fallback_brief)?;
    if let Some(name) = name.map(str::trim).filter(|name| !name.is_empty()) {
        draft["name"] = json!(name.chars().take(64).collect::<String>());
    }
    Ok(draft)
}

/// Pull the draft out of whatever the agent actually said.
///
/// Models wrap JSON in prose and in code fences however clearly they are asked
/// not to, so the outermost braces are found rather than assumed. A reply that
/// cannot be read is an error the wizard shows, never a half-parsed persona:
/// the person's own words stay in the field and they try again or write it
/// themselves.
fn draft_from_reply(reply: &str, fallback_brief: &str) -> Result<Value, String> {
    let start = reply
        .find('{')
        .ok_or("the agent did not answer with a persona")?;
    let end = reply
        .rfind('}')
        .ok_or("the agent did not answer with a persona")?;
    if end <= start {
        return Err("the agent did not answer with a persona".into());
    }
    let parsed: Value = serde_json::from_str(&reply[start..=end])
        .map_err(|_| "the agent's answer was not a persona this could read")?;
    let name = parsed
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .ok_or("the draft came back without a name")?;
    let system_prompt = parsed
        .get("systemPrompt")
        .or_else(|| parsed.get("system_prompt"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|prompt| !prompt.is_empty())
        .unwrap_or(fallback_brief);
    Ok(json!({
        "name": name.chars().take(64).collect::<String>(),
        "systemPrompt": system_prompt.chars().take(1200).collect::<String>(),
    }))
}

fn face_seed(id: &str) -> u64 {
    crate::chat_turn::stable_hash(id) | 1
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
                    // Grok used to be `rules`: launched `--permission-mode
                    // dontAsk` with allow rules fixed at spawn, it could not
                    // ask about anything else, it could only refuse. It now
                    // runs against a private `$GROK_HOME` holding tokenstat's
                    // own `PreToolUse` hook, so it asks like the rest.
                    json!(if matches!(id, "cursor" | "sh") {
                        "bypassOnly"
                    } else {
                        "full"
                    }),
                );
            }
            backend
        })
        .collect()
}

/// Grok evaluates explicit rules before its headless `dontAsk` fallback. A
/// saved tool name maps to its documented bare `ToolPrefix`; a saved shell
/// prefix maps to `Bash(glob)`. Never turn arbitrary labels into rule syntax.
fn grok_allow_rules(chat: &Conversation) -> Vec<String> {
    let mut rules: Vec<String> = chat
        .allowed_tools
        .iter()
        .filter(|tool| {
            !tool.is_empty()
                && tool
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '_')
        })
        .cloned()
        .collect();
    rules.extend(
        chat.allowed_shell_prefixes
            .iter()
            .filter(|prefix| !prefix.is_empty() && !prefix.contains(['(', ')', '\n', '\r']))
            .map(|prefix| format!("Bash({prefix}*)")),
    );
    rules.sort();
    rules.dedup();
    rules
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stop_without_an_active_session_clears_running() {
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
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: true,
        });
        store.stop("chat-test").unwrap();
        assert!(!store.list("workspace-a")[0].running);
    }

    #[test]
    fn counts_are_per_workspace() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let sample = |id: &str, workspace: &str| Conversation {
            id: id.into(),
            workspace_id: workspace.into(),
            title: "New chat".into(),
            backend: "claude".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: default_mode(),
            autonomy: default_autonomy(),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        };
        store.conversations.lock().unwrap().extend([
            sample("chat-a1", "workspace-a"),
            sample("chat-a2", "workspace-a"),
            sample("chat-b1", "workspace-b"),
        ]);
        let counts = store.counts_by_workspace();
        assert_eq!(counts.get("workspace-a"), Some(&2));
        assert_eq!(counts.get("workspace-b"), Some(&1));
        assert_eq!(counts.get("workspace-c"), None);
    }

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
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
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
                    backend: "claude".into(),
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
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
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
        // A backend with no image flag is told the path; one with a flag is
        // handed the file and told nothing, so it cannot describe its own
        // attachment back to the person.
        let spoken = crate::chat_turn::compose(crate::chat_turn::Inputs {
            persona_name: "",
            prompt: "Inspect this",
            persona_brief: "",
            attachments: &files,
            output_dir: root.path(),
            backend: "claude",
        });
        assert!(spoken.user_text.contains("diagram.png"));
    }

    #[test]
    fn personas_persist_and_keep_existing_conversation_settings_intact() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let saved = store
            .save_persona(Persona {
                id: String::new(),
                workspace_id: None,
                name: "Careful reviewer".into(),
                system_prompt: "Review changes carefully.".into(),
                seed: 0,
                created_at_ms: 0,
                updated_at_ms: 0,
            })
            .unwrap();
        assert_eq!(store.personas.lock().unwrap().personas, vec![saved.clone()]);
        assert_ne!(saved.seed, 0, "a persona must have a face");

        // A persona brief is standing text, not part of the turn. The
        // person's message stays exactly what they typed.
        let composed = crate::chat_turn::compose(crate::chat_turn::Inputs {
            persona_name: "",
            prompt: "Check this",
            persona_brief: &saved.system_prompt,
            attachments: &[],
            output_dir: root.path(),
            backend: "claude",
        });
        assert_eq!(composed.user_text, "Check this");
        assert!(
            composed
                .standing_text
                .starts_with("Review changes carefully.")
        );

        // Editing a persona cannot reach back into a copy already taken.
        let edited = store
            .save_persona(Persona {
                name: "Careful reviewer of Rust".into(),
                system_prompt: "A new prompt".into(),
                ..saved.clone()
            })
            .unwrap();
        assert_eq!(saved.system_prompt, "Review changes carefully.");
        // A rename must not hand somebody a stranger.
        assert_eq!(edited.seed, saved.seed);
    }

    /// A persona saved before this shrank carried a backend, model, effort,
    /// mark and autonomy. Those were duplicates of conversation state and go
    /// away. The face is the one thing that has to be invented, and it has to
    /// be invented the same way every time.
    #[test]
    fn old_personas_migrate_and_keep_a_stable_face() {
        let root = tempfile::tempdir().unwrap();
        let store = root.path().join("chat");
        fs::create_dir_all(&store).unwrap();
        fs::write(
            store.join("personas.json"),
            serde_json::to_string(&json!([{
                "id": "persona-1700000000000",
                "name": "Careful reviewer",
                "mark": "R",
                "backend": "claude",
                "model": "sonnet",
                "effort": "high",
                "systemPrompt": "Review changes carefully.",
                "defaultMode": "plan",
                "defaultAutonomy": "standard"
            }]))
            .unwrap(),
        )
        .unwrap();

        let personas = load_persona_index(&store).personas;
        assert_eq!(personas.len(), 1);
        assert_eq!(personas[0].name, "Careful reviewer");
        assert_eq!(personas[0].system_prompt, "Review changes carefully.");
        assert!(personas[0].workspace_id.is_none());
        assert_ne!(personas[0].seed, 0);
        // Loaded twice, same face. Otherwise every launch is a new character.
        assert_eq!(
            load_persona_index(&store).personas[0].seed,
            personas[0].seed
        );
    }

    #[test]
    fn a_supplied_name_survives_a_draft_that_renames() {
        let draft = finish_draft(
            "{\"name\": \"Wrong\", \"systemPrompt\": \"You review.\"}",
            "fallback",
            Some("Reviewer"),
        )
        .unwrap();
        assert_eq!(draft["name"], "Reviewer");
        assert_eq!(draft["systemPrompt"], "You review.");
        let unnamed = finish_draft(
            "{\"name\": \"Rust explainer\", \"systemPrompt\": \"You explain.\"}",
            "fallback",
            None,
        )
        .unwrap();
        assert_eq!(unnamed["name"], "Rust explainer");
    }

    #[test]
    fn draft_prompt_keeps_a_supplied_name() {
        let kept = draft_prompt("Reviews diffs.", Some("Reviewer"));
        assert!(kept.contains("Keep this name exactly: \"Reviewer\""));
        let open = draft_prompt("Reviews diffs.", None);
        assert!(open.contains("two or three words"));
    }

    /// A model wraps JSON in prose and in fences however clearly it is asked
    /// not to, and a draft that cannot be read must never become a persona.
    #[test]
    fn a_persona_draft_is_read_out_of_whatever_the_agent_said() {
        let wrapped = draft_from_reply(
            "Sure! Here you go:\n```json\n{\"name\": \"Rust explainer\", \
             \"systemPrompt\": \"You explain Rust errors patiently.\"}\n```\nHope that helps.",
            "fallback",
        )
        .unwrap();
        assert_eq!(wrapped["name"], "Rust explainer");
        assert_eq!(
            wrapped["systemPrompt"],
            "You explain Rust errors patiently."
        );

        // Snake case, because half of them answer that way.
        let snake = draft_from_reply(
            r#"{"name":"Reviewer","system_prompt":"You review."}"#,
            "fallback",
        )
        .unwrap();
        assert_eq!(snake["systemPrompt"], "You review.");

        // Unreadable is an error the wizard shows, not a half-built persona.
        assert!(draft_from_reply("I could not do that.", "fallback").is_err());
        assert!(draft_from_reply(r#"{"systemPrompt":"no name"}"#, "fallback").is_err());
    }

    #[test]
    fn backends_declare_a_gate_tier_and_keep_the_agent_label() {
        let rows = backends();
        let grok = rows
            .iter()
            .find(|backend| backend["id"] == "grok")
            .expect("grok");
        assert_eq!(grok["gateTier"], "full");
        assert_eq!(grok["label"], "Grok");
        let cursor = rows
            .iter()
            .find(|backend| backend["id"] == "cursor")
            .expect("cursor");
        assert_eq!(cursor["gateTier"], "bypassOnly");
        let claude = rows
            .iter()
            .find(|backend| backend["id"] == "claude")
            .expect("claude");
        assert_eq!(claude["gateTier"], "full");
        assert!(claude.get("models").is_some());
        assert!(claude.get("efforts").is_some());
    }

    /// A handover is due exactly when somebody switched agent mid-conversation.
    /// Not on a first turn, which has nothing to hand over, and not on a
    /// resume, where the agent already remembers.
    #[test]
    fn a_handover_is_due_only_when_a_conversation_changes_hands() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let mut chat = Conversation {
            id: "chat-handoff".into(),
            workspace_id: "ws".into(),
            title: "Handoff".into(),
            backend: "claude".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: "execute".into(),
            autonomy: default_autonomy(),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        };
        store.conversations.lock().unwrap().push(chat.clone());

        // Nothing has happened yet, so there is nothing to hand over.
        assert!(store.handover(&chat).unwrap().is_none());

        store
            .append(
                "chat-handoff",
                &StoredEvent::User {
                    text: "Add a retry to the uploader".into(),
                    at_ms: 1,
                },
            )
            .unwrap();
        store
            .append(
                "chat-handoff",
                &StoredEvent::Agent {
                    event: Event::Edit {
                        call_id: "c1".into(),
                        path: "src/upload.rs".into(),
                        added: 12,
                        removed: 3,
                        patch: String::new(),
                    },
                    at_ms: 2,
                    backend: "claude".into(),
                },
            )
            .unwrap();

        // Claude has run and holds its own session, so it needs no summary.
        chat.resume_tokens
            .insert("claude".into(), "session-1".into());
        assert!(store.handover(&chat).unwrap().is_none());

        // Switching to an agent with no session of its own is the whole point.
        chat.backend = "codex".into();
        let handover = store
            .handover(&chat)
            .unwrap()
            .expect("an incoming agent must be told what happened");
        assert!(handover.brief.contains("Add a retry to the uploader"));
        assert!(handover.brief.contains("src/upload.rs +12 −3"));
        assert!(
            handover.announce,
            "a real change of agent belongs on the timeline"
        );

        // And once codex has its own session, it stops being handed one.
        chat.resume_tokens.insert("codex".into(), "thread-1".into());
        assert!(store.handover(&chat).unwrap().is_none());
    }

    /// An agent that cannot resume itself is handed its own history on every
    /// turn, and that is correct. Saying "handed to" about it is not: nothing
    /// changed hands, and the transcript filled with rows describing a switch
    /// that never happened.
    #[test]
    fn re_briefing_the_same_agent_is_not_announced() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let chat = Conversation {
            id: "chat-rebrief".into(),
            workspace_id: "ws".into(),
            title: "Rebrief".into(),
            backend: "agy".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: "execute".into(),
            autonomy: default_autonomy(),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        };
        store.conversations.lock().unwrap().push(chat.clone());
        store
            .append(
                "chat-rebrief",
                &StoredEvent::User {
                    text: "Add a retry to the uploader".into(),
                    at_ms: 1,
                },
            )
            .unwrap();
        store
            .append(
                "chat-rebrief",
                &StoredEvent::Agent {
                    event: Event::Text {
                        delta: "Done.".into(),
                    },
                    at_ms: 2,
                    backend: "agy".into(),
                },
            )
            .unwrap();

        let handover = store
            .handover(&chat)
            .unwrap()
            .expect("an agent with no session still needs its history");
        assert!(handover.brief.contains("Add a retry to the uploader"));
        assert!(
            !handover.announce,
            "the same agent being re-briefed is plumbing, not a handover"
        );
    }

    /// Choosing no persona has to survive the next chat.
    ///
    /// It did not: a workspace with no default read as one nobody had set up,
    /// so the next conversation minted a starter and the choice was gone.
    #[test]
    fn a_workspace_may_choose_to_have_no_persona() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));

        let starter = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        assert_eq!(store.set_default_persona("workspace-a", "").unwrap(), None);

        // The decision sticks, and nothing is minted to replace it.
        assert_eq!(store.ensure_workspace_persona("workspace-a").unwrap(), None);
        assert_eq!(store.ensure_workspace_persona("workspace-a").unwrap(), None);
        let listed = store.personas("workspace-a").unwrap();
        assert_eq!(listed["defaultId"], "");
        assert_eq!(listed["personas"].as_array().unwrap().len(), 1);

        // And it can be taken back.
        let again = store
            .set_default_persona("workspace-a", &starter.id)
            .unwrap()
            .expect("naming a persona returns it");
        assert_eq!(again.id, starter.id);
        assert_eq!(
            store
                .ensure_workspace_persona("workspace-a")
                .unwrap()
                .map(|persona| persona.id),
            Some(starter.id)
        );
    }

    /// A persona with no folder of its own belongs to all of them. The host
    /// has always allowed it; nothing surfaced it until the editor did.
    #[test]
    fn a_persona_without_a_folder_is_visible_in_every_folder() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let shared = store
            .save_persona(Persona {
                id: String::new(),
                workspace_id: None,
                name: "Reviewer".into(),
                system_prompt: "You review.".into(),
                seed: 0,
                created_at_ms: 0,
                updated_at_ms: 0,
            })
            .unwrap();

        for workspace in ["workspace-a", "workspace-b"] {
            let listed = store.personas(workspace).unwrap();
            let names: Vec<String> = listed["personas"]
                .as_array()
                .unwrap()
                .iter()
                .map(|persona| persona["name"].as_str().unwrap().to_string())
                .collect();
            assert!(names.contains(&"Reviewer".to_string()), "{names:?}");
        }

        // And either folder may adopt it as its own default.
        assert_eq!(
            store
                .set_default_persona("workspace-b", &shared.id)
                .unwrap()
                .map(|persona| persona.id),
            Some(shared.id)
        );
    }

    #[test]
    fn the_file_contract_is_sent_once_per_backend() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let mut chat = Conversation {
            id: "chat-standing".into(),
            workspace_id: "ws".into(),
            title: "Standing".into(),
            backend: "codex".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: "execute".into(),
            autonomy: default_autonomy(),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        };
        store.conversations.lock().unwrap().push(chat.clone());
        let composed = crate::chat_turn::compose(crate::chat_turn::Inputs {
            persona_name: "",
            prompt: "Hey",
            persona_brief: "",
            attachments: &[],
            output_dir: root.path(),
            backend: "codex",
        });

        // Codex has no system-prompt flag, so its first turn carries the
        // rules and every later turn is the person's words alone.
        assert!(standing_is_due(&chat, &composed.standing_fingerprint));
        store
            .mark_standing_sent("chat-standing", "codex", &composed.standing_fingerprint)
            .unwrap();
        chat = store.get("chat-standing").unwrap();
        assert!(!standing_is_due(&chat, &composed.standing_fingerprint));

        // A backend that has not been told yet still needs them, even though
        // the rules themselves have not changed.
        chat.backend = "cursor".into();
        assert!(standing_is_due(&chat, &composed.standing_fingerprint));

        // Editing the persona changes the rules, so the backend that already
        // had the old ones is told the new ones.
        chat.backend = "codex".into();
        let edited = crate::chat_turn::compose(crate::chat_turn::Inputs {
            persona_name: "",
            prompt: "Hey",
            persona_brief: "Be brief.",
            attachments: &[],
            output_dir: root.path(),
            backend: "codex",
        });
        assert!(standing_is_due(&chat, &edited.standing_fingerprint));

        // Claude takes a flag, so repeating costs nothing and it is always due.
        chat.backend = "claude".into();
        store
            .mark_standing_sent("chat-standing", "claude", &composed.standing_fingerprint)
            .unwrap();
        assert!(standing_is_due(&chat, &composed.standing_fingerprint));
    }

    #[test]
    fn the_first_prompt_names_an_untitled_chat() {
        assert_eq!(title_from_prompt("Fix the inspector"), "Fix the inspector");
        assert_eq!(
            title_from_prompt("\n  Plan the checkout flow  \nmore"),
            "Plan the checkout flow"
        );
        let long = "a".repeat(60);
        let titled = title_from_prompt(&long);
        assert!(titled.ends_with('…'));
        assert_eq!(titled.chars().count(), 49);
    }

    #[test]
    fn only_explicit_local_markdown_links_become_response_files() {
        let paths = response_file_paths(
            "See [report](</tmp/a report.txt>), [image](file:///tmp/picture%20one.png), \
             [remote](https://example.com/file.txt), and the unlinked /tmp/secret.txt.",
        );
        assert_eq!(
            paths,
            vec![
                PathBuf::from("/tmp/a report.txt"),
                PathBuf::from("/tmp/picture one.png")
            ]
        );
    }

    #[test]
    fn response_files_are_copied_and_can_be_fetched() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        store.conversations.lock().unwrap().push(Conversation {
            id: "chat-test".into(),
            workspace_id: "workspace-a".into(),
            title: "New chat".into(),
            backend: "codex".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: default_mode(),
            autonomy: default_autonomy(),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        });
        let source = root.path().join("answer.txt");
        fs::write(&source, b"hello from the agent").unwrap();
        let output_dir = store.response_output_dir("chat-test");
        fs::create_dir_all(&output_dir).unwrap();
        store.record_response_attachments(
            "chat-test",
            "codex",
            &format!("[secret.txt](<{}>)", source.display()),
            &output_dir,
        );
        assert!(store.events("chat-test", 0).unwrap().0.is_empty());
        let output = output_dir.join("answer.txt");
        fs::copy(&source, &output).unwrap();
        store.record_response_attachments(
            "chat-test",
            "codex",
            &format!("[answer.txt](<{}>)", output.display()),
            &output_dir,
        );
        let (events, _) = store.events("chat-test", 0).unwrap();
        let event = events.first().unwrap().pointer("/event").unwrap();
        assert_eq!(event["kind"], "attachment");
        assert_eq!(event["mediaType"], "text/plain");
        let id = event["id"].as_str().unwrap();
        fs::remove_file(source).unwrap();
        let fetched = store.attachment_data("chat-test", id).unwrap();
        assert_eq!(
            crate::base64::decode(&fetched.data).unwrap(),
            b"hello from the agent"
        );
    }

    #[test]
    fn agent_events_keep_the_backend_that_emitted_them() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        store.conversations.lock().unwrap().push(Conversation {
            id: "chat-test".into(),
            workspace_id: "workspace-a".into(),
            title: "New chat".into(),
            backend: "codex".into(),
            persona_id: None,
            model: None,
            effort: None,
            system_prompt: String::new(),
            mode: default_mode(),
            autonomy: default_autonomy(),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        });
        store.record_events(
            "chat-test",
            "codex",
            vec![Event::Text {
                delta: "hello".into(),
            }],
        );
        let event = store.events("chat-test", 0).unwrap().0.remove(0);
        assert_eq!(event["backend"], "codex");
        assert_eq!(event["event"]["kind"], "text");
    }

    #[test]
    fn setup_changes_apply_a_persona_without_rewriting_a_running_turn() {
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
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        });
        {
            let mut chats = store.conversations.lock().unwrap();
            chats[0]
                .resume_tokens
                .insert("claude".into(), "claude-thread".into());
            chats[0].resume_token = Some("claude-thread".into());
        }
        let updated = store
            .update(
                "chat-test",
                Update {
                    backend: Some("grok".into()),
                    model: Some("grok-4.6".into()),
                    mode: Some("execute".into()),
                    system_prompt: Some("Be concise.".into()),
                    persona_id: Some("persona-1".into()),
                    ..Update::default()
                },
            )
            .unwrap();
        assert_eq!(updated.backend, "grok");
        assert_eq!(updated.model.as_deref(), Some("grok-4.6"));
        assert!(updated.resume_token.is_none());
        let switched_back = store
            .update(
                "chat-test",
                Update {
                    backend: Some("claude".into()),
                    ..Update::default()
                },
            )
            .unwrap();
        assert_eq!(switched_back.resume_token.as_deref(), Some("claude-thread"));
        assert_eq!(updated.system_prompt, "Be concise.");
        assert_eq!(updated.persona_id.as_deref(), Some("persona-1"));
        store.conversations.lock().unwrap()[0].running = true;
        let err = store
            .update(
                "chat-test",
                Update {
                    backend: Some("claude".into()),
                    ..Update::default()
                },
            )
            .unwrap_err();
        assert!(err.contains("stop this turn") || err.contains("before changing"));
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
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        });
        let turn_token = store.register_turn_token("chat-test", "claude").unwrap();
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
        let helper = Path::new("/tmp/tokenstat-hostd");
        let codex_home = store.root.join("chat-test").join("codex-hook");
        crate::chat_gate::write_codex_home(&codex_home, helper).unwrap();
        let hooks = fs::read_to_string(codex_home.join("hooks.json")).unwrap();
        assert!(hooks.contains("PreToolUse"));
        assert!(hooks.contains("hook codex pre"));
        assert!(hooks.contains("PostToolUse"));
        assert!(hooks.contains("hook codex post"));
        let _ = fs::remove_dir_all(codex_home);
        let agy_home = store.agy_hook_home("chat-test");
        crate::chat_gate::write_agy_home(&agy_home, helper).unwrap();
        let agy_hooks = fs::read_to_string(agy_home.join(".agents/hooks.json")).unwrap();
        assert!(agy_hooks.contains("hook agy pre"));
        assert!(agy_hooks.contains("hook agy post"));
        let _ = fs::remove_dir_all(agy_home);
        // Grok's home is the one that must survive the turn, because its
        // sessions live inside it and `--resume` needs them.
        let grok_home = store.grok_hook_home("chat-test");
        crate::chat_gate::write_grok_home(&grok_home, helper).unwrap();
        let grok_hooks = fs::read_to_string(grok_home.join("hooks/tokenstat.json")).unwrap();
        assert!(grok_hooks.contains("hook grok pre"));
        let _ = fs::remove_dir_all(grok_home);
        let (opencode_home, opencode_plugin) = store.write_opencode_hook_home("chat-test").unwrap();
        let plugin = fs::read_to_string(opencode_plugin).unwrap();
        assert!(plugin.contains("tool.execute.before"));
        assert!(plugin.contains(crate::chat_gate::HELPER_PATH_ENV));
        let _ = fs::remove_dir_all(opencode_home);
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
        // An approval is written twice on purpose: where the agent paused,
        // and again with the answer, so a conversation reopened later shows
        // the outcome instead of a question frozen mid-ask.
        let (events, _) = store.events("chat-test", 0).unwrap();
        assert_eq!(events.len(), 4);
        assert_eq!(events[0]["approval"]["id"], hook_approval.id);
        assert_eq!(events[0]["approval"]["decision"], Value::Null);
        assert_eq!(events[1]["approval"]["id"], hook_approval.id);
        assert_eq!(events[1]["approval"]["decision"], "deny");
        assert_eq!(events[2]["kind"], "agent");
        assert_eq!(events[2]["event"]["kind"], "toolEnd");
        assert_eq!(events[3]["approval"]["id"], pending.id);
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

        let rejected = store
            .request_approval("chat-test", "Read", "Read secrets.txt", None)
            .unwrap();
        assert!(store.resolve_approval(&rejected.id, "denyAlways").is_err());
        assert_eq!(store.await_approval(&rejected.id, 0).decision, None);
        store.resolve_approval(&rejected.id, "deny").unwrap();

        let shell = store
            .request_approval(
                "chat-test",
                "Bash",
                "Bash git status",
                Some("git status".into()),
            )
            .unwrap();
        store.resolve_approval(&shell.id, "allowAlways").unwrap();
        let exact = store
            .request_approval(
                "chat-test",
                "Bash",
                "Bash git status",
                Some("git status".into()),
            )
            .unwrap();
        assert_eq!(exact.decision.as_deref(), Some("allow"));
        let broader = store
            .request_approval(
                "chat-test",
                "Bash",
                "Bash git status --short",
                Some("git status --short".into()),
            )
            .unwrap();
        assert_eq!(broader.decision, None);
    }

    #[test]
    fn first_workspace_load_creates_one_starter_and_is_idempotent() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let first = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        let second = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        assert_eq!(first.id, second.id);
        assert_eq!(first.name, second.name);
        assert_eq!(store.personas.lock().unwrap().personas.len(), 1);
        assert!(STARTER_NAMES.contains(&first.name.as_str()));
        assert_eq!(first.system_prompt, STARTER_BRIEF);
        assert_eq!(first.workspace_id.as_deref(), Some("workspace-a"));
        let listed = store.personas("workspace-a").unwrap();
        assert_eq!(listed["defaultId"], first.id);
        assert_eq!(listed["personas"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn different_workspaces_get_their_own_default() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let a = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        let b = store
            .ensure_workspace_persona("workspace-b")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        assert_ne!(a.id, b.id);
        assert_eq!(a.workspace_id.as_deref(), Some("workspace-a"));
        assert_eq!(b.workspace_id.as_deref(), Some("workspace-b"));
        let listed_a = store.personas("workspace-a").unwrap();
        assert_eq!(listed_a["personas"].as_array().unwrap().len(), 1);
        assert_eq!(listed_a["defaultId"], a.id);
    }

    #[test]
    fn changing_a_default_does_not_rewrite_an_existing_chat() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let first = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        store.conversations.lock().unwrap().push(Conversation {
            id: "chat-test".into(),
            workspace_id: "workspace-a".into(),
            title: "New chat".into(),
            backend: "claude".into(),
            persona_id: Some(first.id.clone()),
            model: None,
            effort: None,
            system_prompt: first.system_prompt.clone(),
            mode: default_mode(),
            autonomy: default_autonomy(),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: vec![],
            allowed_shell_prefixes: vec![],
            budget_seconds: 0,
            created_at_ms: 1,
            updated_at_ms: 1,
            running: false,
        });
        let other = store
            .save_persona(Persona {
                id: String::new(),
                workspace_id: Some("workspace-a".into()),
                name: "Reviewer".into(),
                system_prompt: "You review.".into(),
                seed: 0,
                created_at_ms: 0,
                updated_at_ms: 0,
            })
            .unwrap();
        store.set_default_persona("workspace-a", &other.id).unwrap();
        let chat = store.conversations.lock().unwrap()[0].clone();
        assert_eq!(chat.persona_id.as_deref(), Some(first.id.as_str()));
        assert_eq!(chat.system_prompt, first.system_prompt);
        let listed = store.personas("workspace-a").unwrap();
        assert_eq!(listed["defaultId"], other.id);
    }

    #[test]
    fn omitted_persona_uses_the_default_and_empty_means_none() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let default = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        let omitted = store
            .resolve_create_persona("workspace-a", None)
            .unwrap()
            .unwrap();
        assert_eq!(omitted.id, default.id);
        assert!(
            store
                .resolve_create_persona("workspace-a", Some(""))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn a_missing_default_repairs_without_creating_two() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let first = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        store
            .personas
            .lock()
            .unwrap()
            .default_by_workspace
            .insert("workspace-a".into(), "persona-gone".into());
        let repaired = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        assert_eq!(repaired.id, first.id);
        assert_eq!(store.personas.lock().unwrap().personas.len(), 1);
    }

    #[test]
    fn removing_the_active_default_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let default = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        let err = store.remove_persona(&default.id).unwrap_err();
        assert!(err.contains("default"));
        assert_eq!(store.personas.lock().unwrap().personas.len(), 1);
    }

    #[test]
    fn a_shared_legacy_persona_stays_visible() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let shared = store
            .save_persona(Persona {
                id: String::new(),
                workspace_id: None,
                name: "Careful reviewer".into(),
                system_prompt: "Review changes carefully.".into(),
                seed: 0,
                created_at_ms: 0,
                updated_at_ms: 0,
            })
            .unwrap();
        let starter = store
            .ensure_workspace_persona("workspace-a")
            .unwrap()
            .expect("a workspace with no choice recorded gets a starter");
        let listed = store.personas("workspace-a").unwrap();
        let ids: Vec<&str> = listed["personas"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["id"].as_str().unwrap())
            .collect();
        assert!(ids.contains(&shared.id.as_str()));
        assert!(ids.contains(&starter.id.as_str()));
        let other = store.personas("workspace-b").unwrap();
        let other_ids: Vec<&str> = other["personas"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["id"].as_str().unwrap())
            .collect();
        assert!(other_ids.contains(&shared.id.as_str()));
        assert!(!other_ids.contains(&starter.id.as_str()));
    }
}
