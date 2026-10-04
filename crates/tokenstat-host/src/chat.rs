// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Workspace-scoped conversations with local agents.
//!
//! The archive never sees this data. Conversations, prompts, and raw backend
//! output live under the host data directory and are intentionally absent from
//! sync. A chat is one short-lived process per turn; the backend's own session
//! token is what joins those processes into a conversation.

use std::collections::{HashMap, HashSet};
#[cfg(unix)]
use std::fs::File;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::DispatchError;
use crate::transcript::{Event, Parser};

const EVENTS_CAP: u64 = 1024 * 1024;
/// How many events one page carries when the client does not say.
const PAGE_EVENTS: usize = 300;
/// The most a client may ask for in one page. A client that wants more than
/// this wants the whole archive, which is what the cap exists to prevent.
/// `ChatPaging.hostPageEventsMax` in the Apple client mirrors this. Move
/// both together.
const PAGE_EVENTS_MAX: usize = 2_000;
/// How much is read from disk at a time while walking backwards.
const PAGE_CHUNK: u64 = 64 * 1024;
/// The most one page may weigh, whatever its event count. A conversation full
/// of long patches reaches this long before it reaches `PAGE_EVENTS_MAX`, so
/// this moves with the client's page sizes: triple those and leave this, and
/// dense pages stop where they always did.
const PAGE_BYTES: u64 = 768 * 1024;
/// The most that will be read to find a single record's beginning. A record
/// longer than this is one nothing can display anyway, and the read stops
/// rather than pulling the whole archive into memory looking for a newline.
const PAGE_RECORD_BYTES: u64 = 4 * 1024 * 1024;
const ATTACHMENT_CAP: usize = 12 * 1024 * 1024;
/// Short enough to ride the next step. A longer note is its own message.
const STEER_NOTE_MAX_CHARS: usize = 1_500;
/// The most assistant text the end-of-turn output-link pass reads. Links are
/// taken from the final reply, so only its tail has to survive.
const ASSISTANT_TEXT_TAIL: usize = 512 * 1024;
/// The most raw backend spill kept for one turn, and how much of it survives
/// a truncation. The spill exists so a parser fix can rematerialize a turn,
/// not so one runaway turn can grow without bound.
const RAW_CAP: u64 = 8 * 1024 * 1024;
const RAW_RETAIN: u64 = 4 * 1024 * 1024;
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
/// Separates records made inside the same millisecond.
///
/// A timestamp is useful when looking through the on-disk chat directory, but
/// it is not an identifier: dropping two files or opening two chats quickly
/// enough used to give them the same name and let the latter overwrite the
/// former. The sequence is process-wide, so it also covers simultaneous
/// clients without making an id depend on a filesystem round trip.
static RECORD_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn validate_record_id(id: &str) -> Result<(), String> {
    if id.is_empty()
        || id.contains('/')
        || id.contains('\\')
        || id.contains('\0')
        || id == "."
        || id == ".."
    {
        return Err("invalid id".into());
    }
    Ok(())
}

fn safe_join(root: &Path, id: &str) -> Result<PathBuf, String> {
    validate_record_id(id)?;
    Ok(root.join(id))
}

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
    /// Changes when setup is edited or a turn is reserved, not for streamed
    /// output. An old conversation starts at zero until its next such change.
    #[serde(default)]
    pub send_revision: u64,
    /// The last human or agent event, separate from `updated_at_ms`: changing
    /// a title or setup must not make a conversation look unread.
    #[serde(default)]
    pub last_message_at_ms: Option<i64>,
    /// `"user"` or `"agent"`. A client only marks an unseen agent message
    /// unread; its own most recent prompt is not news.
    #[serde(default)]
    pub last_message_author: Option<String>,
    #[serde(default)]
    pub running: bool,
    /// The branch the workspace was on when a turn last started or ended.
    /// Agents create branches and open pull requests, so this is what ties
    /// a conversation to its pull request. None for a folder that is not a
    /// repository, a detached HEAD, or a chat from before this was kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
}

/// The only conversation metadata needed by a host-wide recent-chat list.
///
/// Keep this separate from [`Conversation`]. A conversation carries prompts,
/// permissions and backend resume tokens which belong on the full chat route,
/// not in a sidebar summary fetched whenever a phone opens Workspaces.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentConversation {
    pub id: String,
    pub workspace_id: String,
    pub title: String,
    pub backend: String,
    pub last_message_at_ms: Option<i64>,
    pub last_message_author: Option<String>,
    pub running: bool,
    pub needs_attention: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
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
/// Long enough that somebody with a folder per project sees a new one each
/// time. `starter_name` walks the list from a hash of the workspace id and
/// steps forward past any name already in use, so a repeat needs more open
/// workspaces than there are names here.
const STARTER_NAMES: [&str; 48] = [
    "Abby", "Ada", "Alfie", "Anna", "Archie", "Ben", "Charlie", "Clara", "Daisy", "Danny", "Ellie",
    "Emma", "Eva", "Felix", "Finn", "Freddie", "George", "Grace", "Harry", "Hazel", "Henry",
    "Jack", "Jamie", "Jess", "Katie", "Leo", "Lily", "Lola", "Lucy", "Maisie", "Max", "Mia",
    "Milo", "Molly", "Nell", "Nora", "Oliver", "Oscar", "Penny", "Polly", "Rosie", "Ruby", "Sam",
    "Sophie", "Teddy", "Theo", "Tom", "Zoe",
];

/// Recognizes untouched starters from the previous naming set.
const LEGACY_STARTER_NAMES: [&str; 48] = [
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
/// The mode for a chat created without one. Execute, like the clients: a
/// new conversation exists to get something done, and a planning turn does
/// nothing that was asked for. Stored records with no mode keep reading as
/// plan, so no existing conversation changes underneath anyone.
fn default_new_chat_mode() -> String {
    "execute".into()
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

#[derive(Deserialize, Serialize)]
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
    /// A question the agent asked in its reply, found while it streamed.
    /// See `chat_question`. The block stays in the reply text too.
    Question {
        id: String,
        question: String,
        options: Vec<String>,
        multiple: bool,
        default: Option<String>,
        blocking: bool,
        backend: String,
        at_ms: i64,
    },
    /// The person's answer, and how it was sent on: `note` rode a running
    /// turn, `queued` waits for the turn to end, `sent` started a turn.
    Answer {
        #[serde(rename = "questionId")]
        question_id: String,
        text: String,
        delivery: String,
        at_ms: i64,
    },
    /// An answer that was parked for the agent and never reached it: Stop,
    /// a cleared note, a new message, or a restart dropped it. The question
    /// is open again on every device.
    AnswerWithdrawn {
        #[serde(rename = "questionId")]
        question_id: String,
        at_ms: i64,
    },
}

/// One answer riding a parked note, until the agent takes the note.
struct ParkedAnswer {
    question_id: String,
    /// The words the answer added to the note, so a replaced or restored
    /// note can be checked for whether it still carries them.
    note: String,
    /// A dropped answer stays journaled until its withdrawal is written.
    withdrawn: bool,
}

/// Answers riding parked notes in this process, by conversation.
///
/// Mirrored by question id to a file beside a lease this process holds, so
/// the next process can tell which answers died with this one and reopen
/// their questions. See [`Store::withdraw_orphaned_answers`].
#[derive(Default)]
struct ParkedAnswers {
    by_chat: HashMap<String, Vec<ParkedAnswer>>,
    owner: Option<(crate::chat_receipts::OwnerLease, PathBuf)>,
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

/// Deliberately not serializable: raw events are converted into allowlisted
/// readable search documents before anything can cross the host boundary.
#[derive(Debug)]
pub struct SearchSnapshot {
    pub title: String,
    pub backend: String,
    pub updated_at_ms: i64,
    pub revision: String,
    pub events: Vec<Value>,
    pub partial: bool,
}

pub struct Store {
    root: PathBuf,
    conversations: Mutex<Vec<Conversation>>,
    active: Mutex<HashMap<String, String>>,
    /// Conversations whose live process the person explicitly stopped.
    /// Memory-only and consumed by drain: a persisted `running` bit after a
    /// daemon restart is stale state, not evidence that somebody pressed Stop.
    killed: Mutex<HashSet<String>>,
    personas: Mutex<PersonaIndex>,
    approvals: Mutex<Vec<Approval>>,
    /// Per-turn credentials are intentionally memory-only. The 0600 file a
    /// hook reads contains the opaque value, while this map is what binds it
    /// to exactly one live conversation at the daemon boundary.
    turn_tokens: Mutex<HashMap<String, TurnBinding>>,
    /// One short note the person added while a turn was running. Memory only.
    /// It rides the next step, or becomes the next message if the turn ends
    /// first. A restart drops it rather than sending it later unasked.
    steers: Mutex<HashMap<String, String>>,
    /// Conversations whose parked note must not start a turn. Stop and a
    /// removed note set this so a delivery that already holds the text comes
    /// back without launching. A person's own send, or a newer note, clears it.
    suppress_follow_up: Mutex<HashSet<String>>,
    /// Answers that ride the parked note in `steers`. Never locked together
    /// with `steers`, for the same reason as `suppress_follow_up`.
    parked_answers: Mutex<ParkedAnswers>,
}

/// How `send` finished. A suppressed follow-up is a note Stop already retired,
/// so the caller must not treat it as a turn that started.
enum SendOutcome {
    Started(Conversation),
    Suppressed(Conversation),
}

impl SendOutcome {
    fn into_conversation(self) -> Conversation {
        match self {
            Self::Started(chat) | Self::Suppressed(chat) => chat,
        }
    }
}

#[derive(Clone)]
struct TurnBinding {
    conversation_id: String,
    backend: String,
}

/// Retires a turn credential that never reached the drain thread owning it.
///
/// Every fallible step between minting the token and a successful spawn runs
/// with this guard alive. Missing one would leave a token in the map that
/// hooks could still present, and its file on disk, after the send refused.
struct PendingTurnCredential {
    store: Arc<Store>,
    token: Option<String>,
    file: Option<PathBuf>,
}

impl PendingTurnCredential {
    fn new(store: &Arc<Store>, token: String, file: PathBuf) -> Self {
        Self {
            store: Arc::clone(store),
            token: Some(token),
            file: Some(file),
        }
    }

    /// The spawned turn's drain thread now owns cleanup. Disarm.
    fn release(&mut self) {
        self.token = None;
        self.file = None;
    }
}

impl Drop for PendingTurnCredential {
    fn drop(&mut self) {
        if let Some(token) = self.token.take() {
            self.store.revoke_turn_token(&token);
        }
        if let Some(file) = self.file.take() {
            let _ = fs::remove_file(file);
        }
    }
}

/// Retires a private muse hook home that never reached the drain thread.
///
/// Every fallible step between installing that home and a successful spawn
/// runs with this guard alive. Missing one would leave the home on disk
/// after the send refused.
struct PendingMuseHome {
    root: Option<PathBuf>,
}

impl PendingMuseHome {
    fn idle() -> Self {
        Self { root: None }
    }

    fn arm(&mut self, root: PathBuf) {
        self.root = Some(root);
    }

    /// The spawned turn's drain thread now owns cleanup.
    fn release(&mut self) -> Option<PathBuf> {
        self.root.take()
    }
}

impl Drop for PendingMuseHome {
    fn drop(&mut self) {
        if let Some(root) = self.root.take() {
            crate::chat_gate::remove_muse_home(&root);
        }
    }
}

/// Muse takes its note through a private hook home, which only a unix host
/// builds. Elsewhere a note would never ride a step, so it is refused and
/// the client queues the words instead.
fn note_backend(backend: &str) -> bool {
    matches!(backend, "claude" | "codex") || (backend == "muse" && cfg!(unix))
}

/// Whether a turn of this chat reads a parked note on its next step. Muse
/// takes one on every model step. The others only stop at a step when they
/// ask before tools. Steering, answering and the standing question rule all
/// ask this one place, so they cannot disagree about it.
fn takes_notes_mid_turn(chat: &Conversation) -> bool {
    note_backend(&chat.backend) && (chat.backend == "muse" || chat.autonomy == "standard")
}

/// A Windows bypass turn keeps the tool's own home, where it was signed in,
/// rather than relocate at all. Hooked turns use the private home everywhere:
/// its credential link carries the sign-in along.
fn private_codex_home(has_hooks: bool) -> bool {
    cfg!(unix) || has_hooks
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
            killed: Mutex::new(HashSet::new()),
            personas: Mutex::new(PersonaIndex::default()),
            approvals: Mutex::new(Vec::new()),
            turn_tokens: Mutex::new(HashMap::new()),
            steers: Mutex::new(HashMap::new()),
            suppress_follow_up: Mutex::new(HashSet::new()),
            parked_answers: Mutex::new(ParkedAnswers::default()),
        }
    }

    fn load() -> Self {
        let root = tokenstat_paths::data_dir()
            .map(|path| path.join("chat"))
            .unwrap_or_else(|| PathBuf::from("chat"));
        Self::load_at(root)
    }

    fn load_at(root: PathBuf) -> Self {
        // Freeze acceptance while deciding which persisted turns lost their
        // owner. Failure to obtain the gate is not proof of an interruption.
        let recovery = crate::chat_receipts::Operation::removal(&root).ok();
        let mut conversations = fs::read(root.join("conversations.json"))
            .ok()
            .and_then(|body| serde_json::from_slice::<Index>(&body).ok())
            .map(|index| index.conversations)
            .unwrap_or_default();
        let original_conversations = conversations.clone();
        let mut migrated = false;
        let mut interrupted = Vec::new();
        for chat in &mut conversations {
            // Another daemon or in-process host may still own this turn.
            if chat.running
                && recovery.is_some()
                && crate::chat_receipts::RunnerLease::try_acquire(&root, &chat.id)
                    .is_ok_and(|lease| lease.is_some())
            {
                chat.running = false;
                interrupted.push((chat.id.clone(), chat.backend.clone()));
                migrated = true;
            }
            if chat.last_message_at_ms.is_some() {
                continue;
            }
            if let Some((at_ms, author)) =
                last_message_in(&root.join(safe_file_name(&chat.id)).join("events.ndjson"))
            {
                chat.last_message_at_ms = Some(at_ms);
                chat.last_message_author = Some(author.into());
                migrated = true;
            }
        }
        let personas = load_persona_index(&root);
        let store = Self {
            root,
            conversations: Mutex::new(conversations),
            active: Mutex::new(HashMap::new()),
            killed: Mutex::new(HashSet::new()),
            personas: Mutex::new(personas),
            approvals: Mutex::new(Vec::new()),
            turn_tokens: Mutex::new(HashMap::new()),
            steers: Mutex::new(HashMap::new()),
            suppress_follow_up: Mutex::new(HashSet::new()),
            parked_answers: Mutex::new(ParkedAnswers::default()),
        };
        if recovery.is_some() {
            store.withdraw_orphaned_answers();
        }
        for (id, backend) in interrupted {
            store.record_events(
                &id,
                &backend,
                vec![Event::Done {
                    status: "interrupted".into(),
                    exit_code: None,
                }],
            );
        }
        if migrated {
            let migrated_chats = store
                .conversations
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone();
            if let Ok(lifecycle) = crate::work_handoff_store::lifecycle_lock(&store.root) {
                let _ = store.edit_index_locked(&lifecycle, false, |_, current| {
                    for (original, migrated) in original_conversations.iter().zip(&migrated_chats) {
                        if let Some(chat) = current.iter_mut().find(|chat| chat.id == original.id)
                            && serde_json::to_value(&*chat).map_err(|e| e.to_string())?
                                == serde_json::to_value(original).map_err(|e| e.to_string())?
                        {
                            *chat = migrated.clone();
                        }
                    }
                    Ok(())
                });
            }
        }
        store
    }

    /// Apply one operation to the current durable index, never a stale snapshot.
    /// Publish to memory only after the replacement succeeds.
    fn edit_index_locked<T>(
        &self,
        _lifecycle: &crate::work_handoff_store::Guard,
        allow_missing: bool,
        edit: impl FnOnce(&[Conversation], &mut Vec<Conversation>) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut memory = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let path = self.root.join("conversations.json");
        let mut index: Index = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| "conversation index could not be verified")?,
            Err(error) if allow_missing && error.kind() == std::io::ErrorKind::NotFound => {
                Index::default()
            }
            Err(error) => return Err(error.to_string()),
        };
        let out = edit(&memory, &mut index.conversations)?;
        let bytes = serde_json::to_vec_pretty(&index).map_err(|e| e.to_string())?;
        replace_chat_file(&path, &bytes)?;
        *memory = index.conversations;
        Ok(out)
    }

    fn edit_conversation<T>(
        &self,
        id: &str,
        edit: impl FnOnce(&mut Conversation) -> Result<T, String>,
    ) -> Result<T, String> {
        validate_record_id(id)?;
        let lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        self.edit_index_locked(&lifecycle, false, |memory, current| {
            let selected = memory
                .iter()
                .find(|chat| chat.id == id)
                .ok_or("no chat with that id")?;
            let chat = current
                .iter_mut()
                .find(|chat| chat.id == id && chat.workspace_id == selected.workspace_id)
                .ok_or("this conversation is no longer in that workspace")?;
            edit(chat)
        })
    }

    #[cfg(test)]
    fn save(&self) -> Result<(), String> {
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        self.edit_index_locked(&lifecycle, true, |memory, current| {
            *current = memory.to_vec();
            Ok(())
        })
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

    /// The conversations most recently spoken in, across every workspace.
    ///
    /// One pass over the in-memory index. The transcript is not opened here:
    /// old indexes are hydrated once at daemon startup, and new turns update
    /// the two message fields when they are written.
    pub fn recent(&self, limit: usize) -> Vec<RecentConversation> {
        let now = now_ms();
        let needs_attention: HashSet<String> = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|approval| approval.decision.is_none() && approval.expires_at_ms > now)
            .map(|approval| approval.conversation_id.clone())
            .collect();
        let mut rows: Vec<_> = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|chat| chat.last_message_at_ms.is_some())
            .map(|chat| RecentConversation {
                id: chat.id.clone(),
                workspace_id: chat.workspace_id.clone(),
                title: chat.title.clone(),
                backend: chat.backend.clone(),
                last_message_at_ms: chat.last_message_at_ms,
                last_message_author: chat.last_message_author.clone(),
                running: chat.running,
                needs_attention: needs_attention.contains(&chat.id),
                branch: chat.branch.clone(),
            })
            .collect();
        // An approval that is waiting must survive the host cap even when an
        // old conversation needs it. Work in progress follows, then ordinary
        // recency. The phone applies its device-local unread priority after
        // this because read receipts intentionally never leave that device.
        rows.sort_by(|left, right| {
            right
                .needs_attention
                .cmp(&left.needs_attention)
                .then_with(|| right.running.cmp(&left.running))
                .then_with(|| right.last_message_at_ms.cmp(&left.last_message_at_ms))
        });
        rows.truncate(limit.min(50));
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
        // A shell tool is never allowed by its bare name. The verb names the
        // tool, not the command, so matching it would approve anything the
        // agent later runs through it. Shell approval is exact: a saved
        // two-word prefix has to equal the prefix this request derived, and a
        // command too compound to have one always comes back as a card.
        let shell_call = shell_prefix.is_some() || crate::chat_brain::is_shell(verb);
        let allowed = if shell_call {
            shell_prefix.as_ref().is_some_and(|prefix| {
                chat.allowed_shell_prefixes
                    .iter()
                    .any(|allowed| prefix == allowed)
            })
        } else {
            chat.allowed_tools.iter().any(|tool| tool == verb)
        };
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
            let already_waiting = {
                let mut approvals = self
                    .approvals
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner);
                let found = has_live_approval(&approvals, conversation_id, now);
                approvals.push(approval.clone());
                found
            };
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
            //
            // Not while somebody has this conversation on screen. The approval
            // card is already in front of them, and a phone buzzing about the
            // question its own screen is asking is the app talking over
            // itself. See `crate::presence`.
            if !already_waiting && !crate::presence::is_watched(conversation_id) {
                tokenstat_sync::push::notify_in_background(
                    tokenstat_sync::push::Reason::RunNeedsInput,
                );
            }
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

    /// Take the parked note for a live turn, once, and only when that turn's
    /// agent can take a note. Any other backend leaves the note in place. An
    /// invalid credential is an error so the caller can ignore it without
    /// failing a result that was already recorded.
    pub fn take_steer_for_token(&self, turn_token: &str) -> Result<Option<String>, String> {
        let id = self
            .turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(turn_token)
            .map(|binding| binding.conversation_id.clone())
            .ok_or("the chat turn credential is invalid or expired")?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, &id)?;
        // A turn may finish while this waits behind a send or Stop. Resolve
        // the credential again before taking any newer turn's note.
        let binding = self
            .turn_tokens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(turn_token)
            .cloned()
            .ok_or("the chat turn credential is invalid or expired")?;
        if !note_backend(&binding.backend) {
            return Ok(None);
        }
        let note = self
            .steers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .cloned();
        let Some(note) = note else { return Ok(None) };
        // The note becomes a user message when the agent takes it. Keep it
        // parked if writing fails, and serialize consumption with replacement,
        // cancellation and idle delivery so it appears exactly once.
        let at_ms = now_ms();
        self.append(
            &id,
            &StoredEvent::User {
                text: note.clone(),
                at_ms,
            },
        )?;
        self.steers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&id);
        // The agent has the note, and every answer riding it.
        self.take_parked_answers(&id);
        let _ = self.mark_last_message(&id, at_ms, "user");
        Ok(Some(note))
    }

    /// Park one short note on the next step of a turn that is already running.
    ///
    /// A parked note is not yet a chat message. The next step records it and
    /// hands it over, and the turn keeps going. A second note replaces the
    /// first. Stop drops it.
    pub fn steer(&self, id: &str, text: &str) -> Result<(), String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        if !self.turn_is_live(id)? {
            return Err("This chat is not in the middle of a turn.".into());
        }
        let chat = self.get(id)?;
        if !note_backend(&chat.backend) {
            return Err("This agent cannot take a note mid-turn.".into());
        }
        if !takes_notes_mid_turn(&chat) {
            return Err(
                "This chat is not asking before tools, so a note cannot ride the next step.".into(),
            );
        }
        let note = text.trim();
        if note.is_empty() {
            return Err("Write the note you want on the next step.".into());
        }
        if note.chars().count() > STEER_NOTE_MAX_CHARS {
            return Err(
                "That note is too long to ride the next step. Send it as its own message.".into(),
            );
        }
        // A new note replaces the person's last one, never an answer riding
        // beside it: the answer is already recorded against its question.
        let parked = match self.parked_answer_notes(id) {
            Some(answers) => format!("{note}\n\n{answers}"),
            None => note.to_string(),
        };
        self.steers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id.to_string(), parked);
        self.suppress_follow_up
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        Ok(())
    }

    /// Answer one question the agent asked. See `chat_question`.
    ///
    /// A running turn gets the answer the way it would get a steer note: on
    /// its next step where the backend reads notes mid-turn, otherwise as the
    /// next message once it ends, which the client sends like any parked note.
    /// An idle conversation gets it as a message now. Either way the answer is
    /// recorded against its question, so every device shows it as answered.
    pub fn answer_question(
        self: &Arc<Self>,
        id: &str,
        question_id: &str,
        text: &str,
    ) -> Result<Value, DispatchError> {
        validate_record_id(id)?;
        let answer = text.trim();
        if answer.is_empty() {
            return Err("Pick one of the choices or write an answer.".into());
        }
        if answer.chars().count() > crate::chat_question::ANSWER_MAX_CHARS {
            return Err("That answer is too long for one note. Send it as its own message.".into());
        }
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        let mut answer = answer.to_string();
        let note = {
            crate::workspace_policy::require_current_access()?;
            self.withdraw_pending_answers(id);
            let question = self.open_question(id, question_id)?;
            // An earlier idle answer may already have launched even though its
            // answer row could not be written. Replay its shared receipt before
            // deciding to park a note on that very same running turn.
            let ledger = crate::chat_receipts::Ledger::load(self.receipts_path(id), now_ms())
                .map_err(DispatchError::delivery_unknown)?;
            let receipt = ledger.get(&crate::chat_receipts::question_key(question_id));
            // The agent already has that earlier answer, whatever is typed now.
            // Record what it was given, or the card could only ever be closed
            // by retyping those exact words.
            if let Some(sent) =
                receipt.and_then(|receipt| self.delivered_answer(id, &question, receipt))
            {
                answer = sent;
            }
            let replay = receipt.is_some();
            let answer = answer.as_str();
            let note = crate::chat_question::answer_note(&question, answer);
            if !replay && self.turn_is_live(id)? {
                let chat = self.get(id)?;
                let delivery = if takes_notes_mid_turn(&chat) {
                    "note"
                } else {
                    "queued"
                };
                self.append(
                    id,
                    &StoredEvent::Answer {
                        question_id: question_id.into(),
                        text: answer.into(),
                        delivery: delivery.into(),
                        at_ms: now_ms(),
                    },
                )?;
                // Beside a note the person already parked, never instead of it.
                {
                    let mut steers = self.steers.lock().unwrap_or_else(PoisonError::into_inner);
                    let merged = match steers.get(id) {
                        Some(existing) => format!("{existing}\n\n{note}"),
                        None => note.clone(),
                    };
                    steers.insert(id.to_string(), merged);
                }
                self.park_answer(id, question_id, note);
                self.suppress_follow_up
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(id);
                return Ok(json!({ "delivery": delivery }));
            }
            note
        };
        // Sent first and recorded after: a send that did not start leaves the
        // question open, so the person can try again.
        // Keep acceptance through launch and recording the answer. Otherwise
        // a second device can accept the same question between those steps.
        let outcome =
            self.send_under_acceptance(id, &note, &[], None, None, None, false, Some(question_id))?;
        self.append(
            id,
            &StoredEvent::Answer {
                question_id: question_id.into(),
                text: answer,
                delivery: "sent".into(),
                at_ms: now_ms(),
            },
        )
        .map_err(DispatchError::delivery_unknown)?;
        // The question's own durable answer now prevents replays. Only retire
        // the receipt after syncing that proof, keeping incomplete answers
        // protected even past the normal message receipt retention window.
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(self.events_path(id))
            .and_then(|file| file.sync_all())
            .map_err(|error| DispatchError::delivery_unknown(error.to_string()))?;
        let _ = self.drop_receipt(id, &crate::chat_receipts::question_key(question_id));
        Ok(json!({ "delivery": "sent", "conversation": outcome.into_conversation() }))
    }

    /// The answer an accepted idle launch already gave the agent, read back
    /// from the message it put on the timeline. None when the receipt is not
    /// settled or that row is not there to read.
    fn delivered_answer(
        &self,
        id: &str,
        question: &str,
        receipt: &crate::chat_receipts::Receipt,
    ) -> Option<String> {
        if receipt.state != crate::chat_receipts::ReceiptState::Accepted {
            return None;
        }
        let at_ms = receipt.event_at_ms?;
        let prefix = crate::chat_question::answer_note(question, "");
        let (events, _) = self.events(id, 0).ok()?;
        events
            .iter()
            .filter(|row| row["kind"] == "user" && record_at_ms(row) == Some(at_ms))
            .find_map(|row| row["text"].as_str()?.strip_prefix(&prefix))
            .map(str::to_owned)
    }

    /// The text of a question in this conversation that nobody has answered.
    fn open_question(&self, id: &str, question_id: &str) -> Result<String, String> {
        let (events, _) = self.events(id, 0)?;
        let mut asked = None;
        let mut answered = false;
        for event in &events {
            let about_it = event.get("questionId").and_then(Value::as_str) == Some(question_id);
            match event.get("kind").and_then(Value::as_str) {
                Some("question")
                    if event.get("id").and_then(Value::as_str) == Some(question_id) =>
                {
                    asked = event
                        .get("question")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                }
                Some("answer") if about_it => answered = true,
                // The answer never reached the agent, so the question is open.
                Some("answerWithdrawn") if about_it => answered = false,
                _ => {}
            }
        }
        if answered {
            return Err("This question already has an answer.".into());
        }
        asked.ok_or_else(|| "That question is no longer in this conversation.".into())
    }

    /// Drop a parked note so it cannot ride the next step or start a turn.
    pub fn steer_clear(&self, id: &str) -> Result<(), String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        self.get(id)?;
        self.retire_steer(id);
        Ok(())
    }

    /// Send a parked note as the next message once the turn has finished.
    ///
    /// Called by the client that still shows the note. If the turn is still
    /// going, this refuses and leaves the note where it is. If Stop already
    /// retired it, the answer is that nothing was sent.
    pub fn steer_deliver(self: &Arc<Self>, id: &str) -> Result<Value, DispatchError> {
        let Some(note) = self.claim_idle_steer(id)? else {
            return Ok(json!({ "delivered": false }));
        };
        // Keep finalization with the send. A hook or another device must not
        // park a new answer between launch and forgetting the delivered ones.
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        match self.send_under_acceptance(id, &note, &[], None, None, None, true, None) {
            Ok(SendOutcome::Started(chat)) => {
                self.take_parked_answers(id);
                Ok(json!({
                    "delivered": true,
                    "conversation": chat,
                }))
            }
            Ok(SendOutcome::Suppressed(_)) => {
                self.reconcile_parked_answers(id);
                Ok(json!({ "delivered": false }))
            }
            Err(error) => {
                self.restore_steer_under_acceptance(id, &note, &error);
                if error.code == crate::error::DELIVERY_UNKNOWN {
                    // It may well have launched. Reopening the question then
                    // would invite the same answer twice.
                    self.take_parked_answers(id);
                } else {
                    self.reconcile_parked_answers(id);
                }
                Err(error)
            }
        }
    }

    /// Copy parked notes onto a `chat.list` payload. They stay out of the
    /// conversation record. A restart cannot send one the person no longer sees.
    pub fn attach_pending_steers(&self, value: &mut Value) {
        let Some(rows) = value.as_array_mut() else {
            return;
        };
        let steers = self.steers.lock().unwrap_or_else(PoisonError::into_inner);
        for row in rows {
            let Some(id) = row.get("id").and_then(Value::as_str) else {
                continue;
            };
            let Some(note) = steers.get(id) else {
                continue;
            };
            let Some(object) = row.as_object_mut() else {
                continue;
            };
            object.insert("pendingSteer".into(), Value::String(note.clone()));
        }
    }

    /// Forget a parked note and refuse a delivery that already holds its text.
    ///
    /// The two maps are never locked together. Holding both is how a Stop and
    /// a delivery would wait on each other.
    fn retire_steer(&self, id: &str) {
        self.steers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        self.suppress_follow_up
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id.to_string());
        self.reconcile_parked_answers(id);
    }

    /// Remember an answer riding the parked note until the agent takes it.
    fn park_answer(&self, id: &str, question_id: &str, note: String) {
        let mut parked = self
            .parked_answers
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        parked
            .by_chat
            .entry(id.to_string())
            .or_default()
            .push(ParkedAnswer {
                question_id: question_id.to_string(),
                note,
                withdrawn: false,
            });
        self.persist_parked_answers(&mut parked);
    }

    /// Forget this conversation's parked answers, because the agent has them.
    fn take_parked_answers(&self, id: &str) -> Vec<ParkedAnswer> {
        let mut parked = self
            .parked_answers
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let Some(answers) = parked.by_chat.remove(id) else {
            return Vec::new();
        };
        let (pending, taken): (Vec<_>, Vec<_>) =
            answers.into_iter().partition(|answer| answer.withdrawn);
        if !pending.is_empty() {
            parked.by_chat.insert(id.to_string(), pending);
        }
        self.persist_parked_answers(&mut parked);
        taken
    }

    /// The words of this conversation's parked answers, to keep beside a
    /// note that replaces the person's last one.
    fn parked_answer_notes(&self, id: &str) -> Option<String> {
        let parked = self
            .parked_answers
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let answers = parked
            .by_chat
            .get(id)
            .filter(|answers| !answers.is_empty())?;
        let notes: Vec<_> = answers
            .iter()
            .filter(|answer| !answer.withdrawn)
            .map(|answer| answer.note.as_str())
            .collect();
        (!notes.is_empty()).then(|| notes.join("\n\n"))
    }

    /// Reopen every parked answer whose words are no longer in the parked
    /// note. Stop, a cleared note and a new message all drop the note, and an
    /// answer recorded against its question would otherwise read as given to
    /// an agent that never saw it.
    fn reconcile_parked_answers(&self, id: &str) {
        let note = self
            .steers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned();
        {
            let mut parked = self
                .parked_answers
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let Some(answers) = parked.by_chat.get_mut(id) else {
                return;
            };
            for answer in answers.iter_mut() {
                if !note
                    .as_deref()
                    .is_some_and(|note| note.contains(&answer.note))
                {
                    answer.withdrawn = true;
                }
            }
            self.persist_parked_answers(&mut parked);
        }
        self.withdraw_pending_answers(id);
    }

    /// Called under conversation acceptance (or the startup recovery gate).
    /// Failed appends keep their journal entry for another attempt.
    fn withdraw_pending_answers(&self, id: &str) {
        let dropped: Vec<_> = {
            let parked = self
                .parked_answers
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            parked
                .by_chat
                .get(id)
                .into_iter()
                .flatten()
                .filter(|answer| answer.withdrawn)
                .map(|answer| answer.question_id.clone())
                .collect()
        };
        if dropped.is_empty() {
            return;
        }
        let mut recorded = HashSet::new();
        for question_id in dropped {
            if self
                .append(
                    id,
                    &StoredEvent::AnswerWithdrawn {
                        question_id: question_id.clone(),
                        at_ms: now_ms(),
                    },
                )
                .is_ok()
            {
                recorded.insert(question_id);
            }
        }
        let mut parked = self
            .parked_answers
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(answers) = parked.by_chat.get_mut(id) {
            answers.retain(|answer| !answer.withdrawn || !recorded.contains(&answer.question_id));
            if answers.is_empty() {
                parked.by_chat.remove(id);
            }
        }
        self.persist_parked_answers(&mut parked);
    }

    /// Mirror this process's parked answers, by question id, to its own file.
    ///
    /// Best effort. A file that cannot be written costs only the reopening
    /// after a restart, never the answer itself.
    fn persist_parked_answers(&self, parked: &mut ParkedAnswers) {
        if parked.owner.is_none() {
            if parked.by_chat.is_empty() {
                return;
            }
            let dir = self.root.join("parked-answers");
            let mut bytes = [0u8; 12];
            if fs::create_dir_all(&dir).is_err() || getrandom::fill(&mut bytes).is_err() {
                return;
            }
            let name: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
            let Ok(Some(lease)) =
                crate::chat_receipts::OwnerLease::try_acquire(&dir.join(format!("{name}.lock")))
            else {
                return;
            };
            parked.owner = Some((lease, dir.join(format!("{name}.json"))));
        }
        let Some((_, path)) = &parked.owner else {
            return;
        };
        let ids: HashMap<&str, Vec<&str>> = parked
            .by_chat
            .iter()
            .map(|(id, answers)| {
                (
                    id.as_str(),
                    answers
                        .iter()
                        .map(|answer| answer.question_id.as_str())
                        .collect(),
                )
            })
            .collect();
        if let Ok(body) = serde_json::to_vec(&ids) {
            let _ = replace_chat_file(path, &body);
        }
    }

    /// Reopen the questions whose answers were parked by a process that has
    /// since ended. Its lease is free exactly when it is gone, and a parked
    /// note never outlives the process that held it.
    fn withdraw_orphaned_answers(&self) {
        let dir = self.root.join("parked-answers");
        let Ok(entries) = fs::read_dir(&dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let lock = path.with_extension("lock");
            // A live owner still holds its lease and may yet deliver these.
            let Ok(Some(lease)) = crate::chat_receipts::OwnerLease::try_acquire(&lock) else {
                continue;
            };
            let Some(parked): Option<HashMap<String, Vec<String>>> = fs::read(&path)
                .ok()
                .and_then(|body| serde_json::from_slice(&body).ok())
            else {
                continue;
            };
            let mut remaining: HashMap<String, Vec<String>> = HashMap::new();
            for (id, questions) in parked {
                // A removed conversation has nothing left to reopen.
                if self.get(&id).is_err() {
                    continue;
                }
                for question_id in questions {
                    if self
                        .append(
                            &id,
                            &StoredEvent::AnswerWithdrawn {
                                question_id: question_id.clone(),
                                at_ms: now_ms(),
                            },
                        )
                        .is_err()
                    {
                        remaining.entry(id.clone()).or_default().push(question_id);
                    }
                }
            }
            let recovered = if remaining.is_empty() {
                fs::remove_file(&path).is_ok()
            } else {
                if let Ok(body) = serde_json::to_vec(&remaining) {
                    let _ = replace_chat_file(&path, &body);
                }
                false
            };
            drop(lease);
            // A journal awaiting another attempt keeps the same lock inode.
            if recovered {
                let _ = fs::remove_file(&lock);
            }
        }
    }

    /// A follow-up is the note Stop may already have retired. A person's own
    /// send clears that refusal and is never skipped.
    ///
    /// A newer note parked after this text was taken also skips the launch.
    /// The newer words stay in the map for the next step.
    fn follow_up_should_skip(&self, id: &str, follow_up: bool) -> bool {
        if !follow_up {
            self.suppress_follow_up
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(id);
            return false;
        }
        let suppressed = self
            .suppress_follow_up
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        let replaced = self
            .steers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(id);
        suppressed || replaced
    }

    fn turn_is_live(&self, id: &str) -> Result<bool, String> {
        let running = self.get(id)?.running;
        let active = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(id);
        Ok(running || active)
    }

    /// Take the note only while nothing is running. The acceptance lock is
    /// dropped with this function, before a delivery tries to send.
    fn claim_idle_steer(&self, id: &str) -> Result<Option<String>, String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        if self.turn_is_live(id)? {
            return Err("This chat is still in the middle of a turn.".into());
        }
        Ok(self
            .steers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id))
    }

    /// Put a note back when the send that was supposed to carry it did not
    /// start, and the turn is still idle. A newer note, a Stop, or a turn
    /// that started in between wins, and this copy is dropped.
    #[cfg(test)]
    fn restore_steer_if_idle(&self, id: &str, note: &str, error: &DispatchError) {
        let Ok(_acceptance) = crate::chat_receipts::Operation::conversation(&self.root, id) else {
            return;
        };
        self.restore_steer_under_acceptance(id, note, error);
    }

    fn restore_steer_under_acceptance(&self, id: &str, note: &str, error: &DispatchError) {
        // The process can finish before this retry decision runs. An idle
        // conversation does not prove a failed acknowledgement never launched.
        if error.code == crate::error::DELIVERY_UNKNOWN {
            return;
        }
        let suppressed = self
            .suppress_follow_up
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(id);
        if suppressed || self.turn_is_live(id).unwrap_or(true) {
            return;
        }
        let mut steers = self.steers.lock().unwrap_or_else(PoisonError::into_inner);
        if !steers.contains_key(id) {
            steers.insert(id.to_string(), note.to_string());
        }
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
            self.edit_conversation(&out.conversation_id, |chat| {
                if let Some(prefix) = &out.shell_prefix {
                    if !chat.allowed_shell_prefixes.contains(prefix) {
                        chat.allowed_shell_prefixes.push(prefix.clone());
                    }
                } else if !crate::chat_brain::is_shell(&out.verb) {
                    // A compound shell command has no prefix worth saving, and
                    // saving the bare tool verb would allow every future
                    // command through that tool. The answer still stands for
                    // this call; nothing is remembered.
                    if !chat.allowed_tools.contains(&out.verb) {
                        chat.allowed_tools.push(out.verb.clone());
                    }
                }
                Ok(())
            })?;
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
    /// there is nothing worth watching. Read-only/plan mode, in a temporary
    /// directory, and with a hard cap: this is a text transform, it has no
    /// business changing anybody's project or running for a minute.
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
        let mut argv = crate::automations::persona_draft_command(
            backend,
            &draft_prompt(brief, name),
            DRAFT_TIMEOUT.as_secs(),
        )?;
        // Its own directory, not the workspace. A draft is a sentence in and a
        // sentence out; giving it somebody's repository to sit in would be
        // handing it a chance to do something nobody asked for.
        let cwd = std::env::temp_dir().join("tokenstat-persona-draft");
        fs::create_dir_all(&cwd).map_err(|error| error.to_string())?;
        let _prompt_file =
            crate::chat_turn::PromptFile::for_windows_muse(backend, &mut argv, &cwd)?;
        let manager = tokenstat_pty::manager();
        let info = manager
            .spawn(&tokenstat_pty::Spawn {
                command: crate::launcher::spawn_command(&argv[0]),
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
                manager.forget_reader(&info.id, &reader);
                let _ = manager.close(&info.id);
                return Err("the draft took too long, so nothing was written".into());
            }
            std::thread::sleep(POLL);
        }
        if let Ok(chunk) = manager.read_for_stream(&info.id, &reader, offset) {
            collect_agent_text(&parser.push_events(&chunk.bytes), &mut text);
        }
        collect_agent_text(&parser.finish_events(), &mut text);
        manager.forget_reader(&info.id, &reader);
        let _ = manager.close(&info.id);
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
        let id = mint_record_id("chat");
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
            mode: input.mode.unwrap_or_else(default_new_chat_mode),
            autonomy: input.autonomy.unwrap_or_else(default_autonomy),
            resume_token: None,
            resume_tokens: HashMap::new(),
            standing_sent: HashMap::new(),
            allowed_tools: Vec::new(),
            allowed_shell_prefixes: Vec::new(),
            budget_seconds: input.budget_seconds.unwrap_or(0),
            created_at_ms: now,
            updated_at_ms: now,
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        };
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        self.edit_index_locked(&lifecycle, true, |_, current| {
            current.push(chat.clone());
            Ok(chat)
        })
    }

    /// Copy the saved transcript into a new conversation with its own future.
    /// Backend sessions, receipts, pending notes and live permissions stay with
    /// the original. Its stored setup and attachments belong to the copy too.
    pub fn fork(&self, id: &str) -> Result<Conversation, String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        let lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let _transcript = self.transcript_guard()?;
        let (source, mut fork) = {
            let chats = self
                .conversations
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let original = chats
                .iter()
                .find(|chat| chat.id == id)
                .ok_or("no chat with that id")?;
            self.verified_conversation(&original.workspace_id, id, &chats)?
        };
        if fork.running
            || self
                .active
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains_key(id)
        {
            return Err("finish or stop this turn before forking the chat".into());
        }
        let _runner = crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?
            .ok_or("finish or stop this turn before forking the chat")?;
        match fs::symlink_metadata(&source) {
            Ok(metadata) if !metadata.is_dir() => return Err("invalid chat directory".into()),
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                return Err(error.to_string());
            }
            _ => {}
        }
        let source_usage = self.conversation_usage(&fork, &source.join("events.ndjson"))?;
        let stored_usage = usage_totals(&source.join("events.ndjson"))?;
        fork.id = mint_record_id("chat");
        fork.title = format!("{} (fork)", fork.title);
        fork.created_at_ms = now_ms();
        fork.updated_at_ms = fork.created_at_ms;
        fork.send_revision = 0;
        fork.resume_token = None;
        fork.resume_tokens.clear();
        fork.standing_sent.clear();
        fork.allowed_tools.clear();
        fork.allowed_shell_prefixes.clear();
        fork.running = false;
        let destination = safe_join(&self.root, &fork.id)?;
        fs::create_dir(&destination).map_err(|error| error.to_string())?;
        let result = (|| {
            let bytes = read_fork_file(
                &source.join("events.ndjson"),
                PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64,
                true,
            )?;
            if !bytes.is_empty() && !bytes.ends_with(b"\n") {
                return Err("the transcript is incomplete and cannot be copied".into());
            }
            let mut copied = Vec::new();
            for line in bytes
                .split(|byte| *byte == b'\n')
                .filter(|line| !line.is_empty())
            {
                let mut record: Value = serde_json::from_slice(line)
                    .map_err(|_| "the transcript could not be verified for copying")?;
                if record["kind"] == "agent" && record["event"]["kind"] == "session" {
                    continue;
                }
                if record["kind"] == "approval" {
                    let approval = &mut record["approval"];
                    let original = approval["id"].as_str().ok_or("invalid stored approval")?;
                    approval["id"] = json!(format!("{}-{original}", fork.id));
                    approval["conversationId"] = json!(fork.id);
                    approval["expiresAtMs"] = json!(0);
                    if approval["decision"].is_null() {
                        approval["decision"] = json!("deny");
                    }
                }
                serde_json::to_writer(&mut copied, &record).map_err(|error| error.to_string())?;
                copied.push(b'\n');
            }
            if let Some(extra) = usage_difference(&source_usage, &stored_usage)? {
                let seq = crate::work_transcript_identity::next_sequence(&copied, 0)?;
                let Value::Object(record) = json!({"kind":"retainedUsage", "usage":extra}) else {
                    return Err("invalid copied usage".into());
                };
                copied.extend(crate::work_transcript_identity::encoded(record, seq)?);
            }
            replace_chat_file(&destination.join("events.ndjson"), &copied)?;
            copy_fork_files(&source.join("files"), &destination.join("files"))?;
            self.edit_index_locked(&lifecycle, false, |_, current| {
                current.push(fork.clone());
                Ok(fork.clone())
            })
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(&destination);
        }
        result
    }

    pub fn update(&self, id: &str, changes: Update) -> Result<Conversation, String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        self.edit_conversation(id, |chat| {
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
            if let Some(backend) = changes.backend
                && backend != chat.backend
            {
                chat.backend = backend;
                // A model/effort value and a backend session are backend-
                // specific. Do not send stale setup or a legacy token to the
                // newly selected agent. A previously used backend can still
                // recover its own token from `resume_tokens`.
                chat.model = None;
                chat.effort = None;
                chat.resume_token = chat.resume_tokens.get(&chat.backend).cloned();
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
            chat.send_revision = next_send_revision(chat.send_revision)?;
            chat.updated_at_ms = now_ms();
            Ok(chat.clone())
        })
    }

    pub fn remove(&self, id: &str) -> Result<bool, String> {
        validate_record_id(id)?;
        if !self.root.exists() {
            return Ok(false);
        }
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        let lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        if self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(id)
        {
            return Err("stop this chat before removing it".into());
        }
        if crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?.is_none() {
            return Err("Another instance of tokenstat is running this conversation. Stop it there before removing it.".into());
        }
        let _transcript = self.transcript_guard()?;
        let removed = self.edit_index_locked(&lifecycle, false, |memory, current| {
            let Some(selected) = memory.iter().find(|chat| chat.id == id) else {
                return Ok(false);
            };
            if let Some(chat) = current.iter().find(|chat| chat.id == id)
                && chat.workspace_id != selected.workspace_id
            {
                return Err("this conversation is no longer in that workspace".into());
            }
            let before = current.len();
            current.retain(|chat| chat.id != id);
            Ok(current.len() != before)
        })?;
        if removed {
            let _ = fs::remove_dir_all(safe_join(&self.root, id)?);
        }
        Ok(removed)
    }

    /// Both the in-memory selection and the persisted index must still name
    /// this exact conversation. The lifecycle lock is held by the caller, so
    /// another process cannot delete it between this check and a handoff write.
    fn handoff_conversation(
        &self,
        workspace_id: &str,
        id: &str,
        chats: &[Conversation],
    ) -> Result<PathBuf, String> {
        self.verified_conversation(workspace_id, id, chats)
            .map(|(path, _)| path)
    }

    fn verified_conversation(
        &self,
        workspace_id: &str,
        id: &str,
        chats: &[Conversation],
    ) -> Result<(PathBuf, Conversation), String> {
        validate_record_id(id)?;
        if !chats
            .iter()
            .any(|chat| chat.id == id && chat.workspace_id == workspace_id)
        {
            return Err("this conversation is no longer in that workspace".into());
        }
        let index: Index = serde_json::from_slice(
            &fs::read(self.root.join("conversations.json")).map_err(|e| e.to_string())?,
        )
        .map_err(|_| "conversation index could not be verified")?;
        let chat = index
            .conversations
            .into_iter()
            .find(|chat| chat.id == id && chat.workspace_id == workspace_id)
            .ok_or("this conversation is no longer in that workspace")?;
        Ok((safe_join(&self.root, id)?, chat))
    }

    pub fn handoff(
        &self,
        workspace_id: &str,
        id: &str,
    ) -> Result<Option<crate::work_handoff::Handoff>, String> {
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let directory = self.handoff_conversation(workspace_id, id, &chats)?;
        if !directory.exists() {
            return Ok(None);
        }
        crate::work_handoff_store::read(&directory)
    }

    /// Descriptors only: previewing a shared draft must not download its files.
    /// Keep the same ownership/deletion lock as the handoff record itself.
    pub fn handoff_attachments(
        &self,
        workspace_id: &str,
        id: &str,
        ids: &[String],
    ) -> Result<Vec<Attachment>, String> {
        if ids.len() > 20 {
            return Err("a handoff can include at most 20 attachments".into());
        }
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        self.handoff_conversation(workspace_id, id, &chats)?;
        ids.iter()
            .map(|attachment_id| {
                validate_record_id(attachment_id)?;
                let conversation = self.root.join(id);
                let files = conversation.join("files");
                for directory in [&conversation, &files, &files.join(attachment_id)] {
                    if !fs::symlink_metadata(directory)
                        .map_err(|_| "an attachment is no longer available")?
                        .is_dir()
                    {
                        return Err("invalid attachment directory".into());
                    }
                }
                let path = self.single_attachment_path(id, attachment_id)?;
                let metadata = fs::symlink_metadata(&path)
                    .map_err(|_| "an attachment is no longer available")?;
                if !metadata.is_file() {
                    return Err("invalid attachment file".into());
                }
                Ok(Attachment {
                    id: attachment_id.clone(),
                    name: path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .map(safe_file_name)
                        .unwrap_or_else(|| "attachment".into()),
                    media_type: media_type_for_path(&path),
                    size: Some(metadata.len()),
                })
            })
            .collect()
    }

    pub fn put_handoff(
        &self,
        workspace_id: &str,
        id: &str,
        request: &crate::work_handoff::PutHandoff,
        authenticated_device: &str,
    ) -> Result<crate::work_handoff::PutResult, String> {
        crate::work_handoff::validate(request, authenticated_device)?;
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let directory = self.handoff_conversation(workspace_id, id, &chats)?;
        if let Some(draft) = &request.draft {
            self.attachment_paths(id, &draft.attachment_ids)?;
        }
        // A new conversation has an index entry before it has any events.
        // Initialize only while ownership is locked and verified; the storage
        // layer itself must never recreate a deleted conversation directory.
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        crate::work_handoff_store::put(&directory, request, authenticated_device, now_ms())
    }

    pub fn remove_all(&self, workspace_id: &str) -> Result<usize, String> {
        if !self.root.exists() {
            return Ok(0);
        }
        let _acceptance = crate::chat_receipts::Operation::removal(&self.root)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        let lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let _transcript = self.transcript_guard()?;
        let active: HashSet<String> = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .keys()
            .cloned()
            .collect();
        let targets = self.edit_index_locked(&lifecycle, false, |_, current| {
            let targets: Vec<String> = current
                .iter()
                .filter(|chat| chat.workspace_id == workspace_id)
                .map(|chat| chat.id.clone())
                .collect();
            if targets.iter().any(|id| active.contains(id)) {
                return Err("stop the running chats before removing them".into());
            }
            for id in &targets {
                if crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?.is_none() {
                    return Err("Another instance of tokenstat is running one of these conversations. Stop it there before removing them.".into());
                }
            }
            current.retain(|chat| chat.workspace_id != workspace_id);
            Ok(targets)
        })?;
        for id in &targets {
            if let Ok(path) = safe_join(&self.root, id) {
                let _ = fs::remove_dir_all(path);
            }
        }
        Ok(targets.len())
    }

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
        added.push_str("\n\n");
        added.push_str(crate::chat_turn::browser_rule());
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

    /// Everything written after `offset`, for live tailing.
    ///
    /// Only the region asked for is read. This runs on every poll of a
    /// running turn, and reading the whole archive to hand back the last two
    /// hundred bytes of it was work paid for four hundred milliseconds at a
    /// time.
    pub fn events(&self, id: &str, offset: u64) -> Result<(Vec<Value>, u64), String> {
        let chunk = self.tail_events(id, offset, None)?;
        Ok((chunk.events, chunk.next_offset))
    }

    /// A live cursor binds the physical offset to the retained archive. After
    /// compaction the client reloads a bounded newest page, rather than missing
    /// deltas or appending a slice from the middle of another record.
    pub fn tail_events(
        &self,
        id: &str,
        offset: u64,
        cursor: Option<&str>,
    ) -> Result<EventChunk, String> {
        self.tail_events_positions(id, offset, cursor, true)
    }

    /// Older clients compare row positions with physical usage offsets. Keep
    /// that representation until a client opts into durable message positions.
    pub fn tail_events_positions(
        &self,
        id: &str,
        offset: u64,
        cursor: Option<&str>,
        stable: bool,
    ) -> Result<EventChunk, String> {
        let _guard = self.transcript_guard()?;
        self.get(id)?;
        let path = self.events_path(id);
        let end = file_len(&path);
        let first = archive_generation(&path)?;
        let reset = cursor.is_some_and(|raw| parse_cursor(raw, end, first) != Some(offset));
        let start = offset.min(end);
        let events = if reset {
            Vec::new()
        } else {
            records_with_positions(
                &read_region(&path, start, end).unwrap_or_default(),
                start,
                stable,
            )
        };
        Ok(EventChunk {
            events,
            next_offset: end,
            tail_cursor: make_cursor(end, end, first),
            reset,
        })
    }

    /// One bounded page of the timeline, newest first.
    ///
    /// The page a conversation opens on, and every older page behind it. No
    /// cursor means the end of the file, and the cursor in the answer asks
    /// for the page before this one. It is opaque on purpose: it names a byte
    /// boundary and the size the archive was when it was issued, and a client
    /// that read either of those would be a client this store could no longer
    /// change.
    ///
    /// The archive is capped (see `append`), which rewrites the file from
    /// the front and moves every offset in it. A cursor issued before that
    /// cannot be honoured, so the answer is the newest page again with
    /// `reset` set, rather than an error or a page of the wrong records.
    pub fn event_page(
        &self,
        id: &str,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<EventPage, String> {
        self.event_page_positions(id, cursor, limit, true)
    }

    /// Wire compatibility for clients whose usage watermark is still a byte
    /// offset. Paging cursors stay opaque in either representation.
    pub fn event_page_positions(
        &self,
        id: &str,
        cursor: Option<&str>,
        limit: usize,
        stable: bool,
    ) -> Result<EventPage, String> {
        let _guard = self.transcript_guard()?;
        let chat = self.get(id)?;
        let path = self.events_path(id);
        let len = file_len(&path);
        let first = archive_generation(&path)?;
        let limit = if limit == 0 {
            PAGE_EVENTS
        } else {
            limit.clamp(1, PAGE_EVENTS_MAX)
        };
        let (end, reset) = match cursor {
            None => (len, false),
            Some(raw) => match parse_cursor(raw, len, first) {
                Some(end) => (end, false),
                None => (len, true),
            },
        };
        let (start, bytes) = read_back(&path, end, limit)?;
        Ok(EventPage {
            events: records_with_positions(&bytes, start, stable),
            history_trimmed: retained_prefix(&bytes, start),
            start,
            next_offset: end,
            tail_cursor: make_cursor(end, len, first),
            cursor: (start > 0).then(|| make_cursor(start, len, first)),
            has_earlier: start > 0,
            reset,
            // Only with the newest page. It is the whole conversation's
            // figure, it does not change as somebody reads backwards, and it
            // is the one thing here that has to look past the window.
            usage: if cursor.is_none() || reset {
                Some(self.conversation_usage(&chat, &path)?)
            } else {
                None
            },
        })
    }

    /// Saved vendor counts fill gaps left by older live-stream parsers. The
    /// numeric snapshot is bounded and never includes prompts in the reply.
    fn conversation_usage(&self, chat: &Conversation, path: &Path) -> Result<Value, String> {
        let muse_root = if chat.resume_tokens.contains_key("muse")
            || (chat.backend == "muse" && chat.resume_token.is_some())
        {
            tokenstat_paths::home_dir()
                .and_then(|home| tokenstat_core::sources::muse::discover(&home))
        } else {
            None
        };
        self.conversation_usage_with_muse_root(chat, path, muse_root.as_deref())
    }

    fn conversation_usage_with_muse_root(
        &self,
        chat: &Conversation,
        path: &Path,
        muse_root: Option<&Path>,
    ) -> Result<Value, String> {
        let baseline = usage_totals(path)?;
        let bytes = read_fork_file(
            path,
            PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64,
            true,
        )?;
        let records: Vec<Value> = bytes
            .split(|byte| *byte == b'\n')
            .filter_map(|line| serde_json::from_slice(line).ok())
            .collect();
        let mut totals = baseline.clone();
        // Only Codex raw output carries `turn.completed`. Without this gate
        // every first-page read of any other chat scanned its raw folder.
        let used_codex = chat.backend == "codex"
            || chat.resume_tokens.contains_key("codex")
            || records.iter().any(|row| row["backend"] == "codex");
        if used_codex
            && !records.iter().any(|row| {
                row["kind"] == "retainedUsage" && row["usage"]["turns"].as_u64().unwrap_or(0) > 0
            })
        {
            let times: Vec<i64> = records
                .iter()
                .filter(|row| row["backend"] == "codex" && row["event"]["kind"] == "usage")
                .filter_map(|row| row["at_ms"].as_i64().or_else(|| row["atMs"].as_i64()))
                .collect();
            let recovered = legacy_codex_usage(
                &path.parent().ok_or("invalid transcript path")?.join("raw"),
                &times,
            );
            // Vendor logs are optional repair inputs. Their size, permissions
            // or availability must not make a verified transcript unreadable.
            if let Ok(recovered) = recovered {
                let _ = add_usage_value(&mut totals, &recovered);
            }
        }
        let muse = chat
            .resume_tokens
            .get("muse")
            .map(String::as_str)
            .or_else(|| {
                (chat.backend == "muse")
                    .then_some(chat.resume_token.as_deref())
                    .flatten()
            });
        if let Some(token) = muse.filter(|token| validate_record_id(token).is_ok()) {
            let directory = if let Some(root) = muse_root {
                muse_session_directory(root, token).ok().flatten()
            } else {
                None
            };
            // A retained summary already includes its discarded prefix, and
            // a fork's copied history belongs to the original vendor session.
            // Only reconcile complete visible turns created in this conversation.
            // The older aggregate has no per-backend attribution, so repairing
            // it from the full vendor log would count those tokens twice.
            // A partial turn before the first surviving user stays at its
            // recorded total until there is a complete turn to reconcile.
            let since_ms = records
                .iter()
                .rposition(|record| record["kind"] == "retainedUsage")
                .map(|index| {
                    records[index + 1..]
                        .iter()
                        .filter(|record| record["kind"] == "user")
                        .find_map(record_at_ms)
                        .unwrap_or(i64::MAX)
                })
                .unwrap_or(chat.created_at_ms)
                .max(chat.created_at_ms);
            if let Some(directory) = directory
                && let Ok(recovered) = muse_log_usage(&directory, since_ms)
            {
                let mut stored = crate::work_transcript_identity::UsageTotals::default();
                // A fork strips old Session markers. The current token's
                // marker distinguishes inherited records even when their
                // timestamp equals the fork's creation millisecond. Older
                // transcripts without markers retain the timestamp fallback.
                let mut current_session = !records.iter().any(|record| {
                    record["backend"] == "muse" && record["event"]["kind"] == "session"
                });
                for record in &records {
                    if record["backend"] == "muse" && record["event"]["kind"] == "session" {
                        current_session = record["event"]["id"].as_str() == Some(token);
                    }
                    if current_session
                        && record["backend"] == "muse"
                        && record_at_ms(record).is_some_and(|at| at >= since_ms)
                        && let Some(record) = record.as_object()
                    {
                        stored.add(&crate::work_transcript_identity::UsageTotals::from_record(
                            record,
                        )?)?;
                    }
                }
                // A missing or older vendor log does not erase already recorded usage.
                if let Some(extra) = usage_difference(&recovered, &stored.value())? {
                    let _ = add_usage_value(&mut totals, &extra);
                }
            }
        }
        Ok(totals)
    }

    /// A bounded, server-internal input for live search. The caller must first
    /// authorize the workspace; this additionally checks current durable
    /// ownership under the same lifecycle lock used by deletion. No usage
    /// totals, attachment bytes, system prompts or resume credentials enter the snapshot.
    pub fn search_snapshot(&self, workspace_id: &str, id: &str) -> Result<SearchSnapshot, String> {
        use sha2::{Digest, Sha256};
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let (_, chat) = self.verified_conversation(workspace_id, id, &chats)?;
        drop(chats);
        let _guard = self.transcript_guard()?;
        let path = self.events_path(id);
        let end = match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_file() => metadata.len(),
            Ok(_) => return Err("conversation transcript is not a regular file".into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
            Err(_) => return Err("conversation transcript could not be read".into()),
        };
        let (start, bytes) = read_back_checked(&path, end, PAGE_EVENTS_MAX, true)?;
        let mut digest = Sha256::new();
        digest.update((chat.title.len() as u64).to_le_bytes());
        digest.update(chat.title.as_bytes());
        digest.update((chat.backend.len() as u64).to_le_bytes());
        digest.update(chat.backend.as_bytes());
        digest.update(chat.updated_at_ms.to_le_bytes());
        digest.update(start.to_le_bytes());
        digest.update(end.to_le_bytes());
        digest.update(&bytes);
        let events = records(&bytes, start);
        let record_count = bytes
            .split(|byte| *byte == b'\n')
            .filter(|line| line.iter().any(|byte| !byte.is_ascii_whitespace()))
            .count();
        let partial = start > 0 || events.len() != record_count || retained_prefix(&bytes, start);
        Ok(SearchSnapshot {
            title: chat.title.clone(),
            backend: chat.backend.clone(),
            updated_at_ms: chat.updated_at_ms,
            revision: digest
                .finalize()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
            events,
            partial,
        })
    }

    /// The handover an incoming backend should be given, if any.
    ///
    /// Due whenever this conversation has history the selected backend has not
    /// seen: either it has no session of its own, or another backend owns the
    /// latest agent event. That is not the same question as whether the
    /// conversation changed hands, which is why `announce` is separate: an
    /// agent that cannot resume itself needs the summary on every turn, and
    /// saying "handed to" every turn described a switch that never happened.
    fn handover(&self, chat: &Conversation) -> Result<Option<Handover>, String> {
        let (events, _) = self.events(&chat.id, 0)?;
        let previous = last_backend(&events);
        // A resume token proves only that this backend remembers the point at
        // which it last ran. If another backend has spoken since then, that
        // old session is precisely the one that needs a handover. It is current
        // only when it also owns the latest agent event.
        if chat.resume_tokens.contains_key(&chat.backend)
            && previous.as_deref() == Some(chat.backend.as_str())
        {
            return Ok(None);
        }
        let folder = crate::workspaces::folder(&chat.workspace_id)
            .map(|workspace| workspace.path.display().to_string())
            .unwrap_or_default();
        let mut brief = crate::chat_brain::brief(&events, &folder, crate::chat_brain::BUDGET);
        if brief.is_empty() {
            return Ok(None);
        }
        // The inline brief is bounded; a long conversation drops early turns.
        // Point the new agent at the full export exactly then, so depth is
        // one file read away and the handover still works when it never reads.
        if crate::chat_brain::dropped_turns(&events, crate::chat_brain::BUDGET) > 0 {
            let history = crate::chat_brain::export_markdown(&events, &folder);
            let path = self.write_history(&chat.id, &history)?;
            brief.push_str(&format!(
                "\nFull history: {path}. Read it if the summary above is missing what you need.\n"
            ));
        }
        Ok(Some(Handover {
            announce: previous.is_some_and(|name| name != chat.backend),
            brief,
        }))
    }

    /// Keep the handover on disk beside the timeline it was folded from.
    ///
    /// Three reasons, all real: a person can read what their agent was told,
    /// a later parser fix can regenerate it, and the full export beside it
    /// (`history.md`) is what long handovers point the new agent at.
    fn write_brain(&self, id: &str, brief: &str) -> Result<(), String> {
        let path = safe_join(&self.root, id)?.join("brain.md");
        fs::create_dir_all(path.parent().ok_or("invalid chat path")?)
            .map_err(|error| error.to_string())?;
        write_private_file(&path, brief.as_bytes())
    }

    /// Keep the full export beside the brief it outgrew. Returns the absolute
    /// path, which is what the handover points the new agent at.
    fn write_history(&self, id: &str, markdown: &str) -> Result<String, String> {
        let path = safe_join(&self.root, id)?.join("history.md");
        fs::create_dir_all(path.parent().ok_or("invalid chat path")?)
            .map_err(|error| error.to_string())?;
        write_private_file(&path, markdown.as_bytes())?;
        Ok(path.display().to_string())
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
            id: mint_record_id("file"),
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

    fn receipts_path(&self, id: &str) -> PathBuf {
        crate::chat_receipts::path_for(&self.root.join(safe_file_name(id)))
    }

    fn write_receipt(
        &self,
        id: &str,
        key: &str,
        receipt: crate::chat_receipts::Receipt,
    ) -> Result<(), String> {
        // Read back before writing: two sends into the same conversation
        // would otherwise write the file over each other's entries.
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let directory = self.verified_append_directory(id)?;
        fs::create_dir_all(directory).map_err(|e| e.to_string())?;
        let mut ledger = crate::chat_receipts::Ledger::load(self.receipts_path(id), now_ms())?;
        ledger.put(key.to_string(), receipt)?;
        ledger.save()?;
        // A first send may have created the conversation directory. Persist
        // that parent entry too, before allowing the agent to start.
        #[cfg(unix)]
        File::open(&self.root)
            .and_then(|directory| directory.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn drop_receipt(&self, id: &str, key: &str) -> Result<(), String> {
        let mut ledger = crate::chat_receipts::Ledger::load(self.receipts_path(id), now_ms())?;
        ledger.remove(key);
        ledger.save()
    }

    /// What the host already knows about one client's message.
    ///
    /// A client whose answer went missing asks this before deciding whether
    /// to send again. It reports, it never runs anything.
    pub fn receipt(
        &self,
        id: &str,
        client_message_id: &str,
    ) -> Result<Option<crate::chat_receipts::Receipt>, String> {
        if !crate::chat_receipts::valid_id(client_message_id) {
            return Err("that clientMessageId is not usable".into());
        }
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        self.current_send_conversation(id)?;
        let key = crate::chat_receipts::key(
            crate::request_context::remote_peer().as_deref(),
            client_message_id,
        );
        let ledger = crate::chat_receipts::Ledger::load(self.receipts_path(id), now_ms())?;
        let mut receipt = ledger.get(&key).cloned();
        if let Some(receipt) = &mut receipt
            && receipt.state == crate::chat_receipts::ReceiptState::Pending
            && !self
                .active
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains_key(id)
            && crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?.is_some()
        {
            receipt.state = crate::chat_receipts::ReceiptState::NeedsRecovery;
        }
        Ok(receipt)
    }

    /// Send setup uses the current durable conversation after acquiring the
    /// acceptance lock, not a snapshot from a different Store or before deletion.
    fn current_send_conversation(&self, id: &str) -> Result<Conversation, String> {
        let _lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        let chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let selected = chats
            .iter()
            .find(|chat| chat.id == id)
            .ok_or("no chat with that id")?;
        self.verified_conversation(&selected.workspace_id, id, &chats)
            .map(|(_, chat)| chat)
    }

    pub fn send(
        self: &Arc<Self>,
        id: &str,
        text: &str,
        attachment_ids: &[String],
        client_message_id: Option<&str>,
        client_message_created_at_ms: Option<i64>,
        expected_revision: Option<u64>,
    ) -> Result<Conversation, DispatchError> {
        self.send_inner(
            id,
            text,
            attachment_ids,
            client_message_id,
            client_message_created_at_ms,
            expected_revision,
            false,
        )
        .map(SendOutcome::into_conversation)
    }

    /// `follow_up` is a parked note being sent after its turn ended. Stop can
    /// retire that note after it was already taken, and this returns the
    /// conversation without launching. A person's own send is never that path.
    #[allow(clippy::too_many_arguments)]
    fn send_inner(
        self: &Arc<Self>,
        id: &str,
        text: &str,
        attachment_ids: &[String],
        client_message_id: Option<&str>,
        client_message_created_at_ms: Option<i64>,
        expected_revision: Option<u64>,
        follow_up: bool,
    ) -> Result<SendOutcome, DispatchError> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        self.send_under_acceptance(
            id,
            text,
            attachment_ids,
            client_message_id,
            client_message_created_at_ms,
            expected_revision,
            follow_up,
            None,
        )
    }

    /// The caller holds the conversation acceptance lock through any related
    /// timeline writes, such as marking a question answered.
    #[allow(clippy::too_many_arguments)]
    fn send_under_acceptance(
        self: &Arc<Self>,
        id: &str,
        text: &str,
        attachment_ids: &[String],
        client_message_id: Option<&str>,
        client_message_created_at_ms: Option<i64>,
        expected_revision: Option<u64>,
        follow_up: bool,
        question_id: Option<&str>,
    ) -> Result<SendOutcome, DispatchError> {
        crate::workspace_policy::require_current_access()?;
        let typed = text.trim();
        if typed.is_empty() && attachment_ids.is_empty() {
            return Err("chat.send needs text or an attachment".into());
        }
        // An image can be the whole message. The CLIs still need words on
        // argv, so an empty caption sends a neutral viewing prompt. The
        // timeline records what actually went out, attachments included.
        let viewing;
        let prompt = if typed.is_empty() {
            viewing = "What is shown in the attached images?".to_string();
            viewing.as_str()
        } else {
            typed
        };
        let mut chat = self.current_send_conversation(id)?;
        // Before the running guard, deliberately. The case this exists for is
        // a send whose answer went missing, and the turn it started is
        // usually still going: "this chat is already responding" would be a
        // failure where the truth is that the message was taken.
        //
        // The device is the authenticated peer rather than anything in the
        // body, so one client cannot claim another's receipt and skip a send.
        let receipt_key = if let Some(question_id) = question_id {
            // One question can be answered from any device. Its acceptance
            // belongs to the question, rather than to a particular peer.
            Some(crate::chat_receipts::question_key(question_id))
        } else {
            match client_message_id {
                Some(client_message_id) => {
                    if !crate::chat_receipts::valid_id(client_message_id) {
                        return Err("that clientMessageId is not usable".into());
                    }
                    Some(crate::chat_receipts::key(
                        crate::request_context::remote_peer().as_deref(),
                        client_message_id,
                    ))
                }
                None => None,
            }
        };
        let digest = crate::chat_receipts::digest(text, attachment_ids);
        if let Some(key) = &receipt_key {
            let ledger = crate::chat_receipts::Ledger::load(self.receipts_path(id), now_ms())
                .map_err(DispatchError::delivery_unknown)?;
            if let Some(receipt) = ledger.get(key) {
                if !receipt.digest.starts_with("v2:") {
                    return Err(DispatchError::delivery_unknown(
                        "This older send needs a delivery check. Its receipt is still available; do not resend it.",
                    ));
                }
                if receipt.digest != digest {
                    return Err("that message id was already used for a different message".into());
                }
                match receipt.state {
                    crate::chat_receipts::ReceiptState::Accepted => {
                        return Ok(SendOutcome::Started(chat));
                    }
                    // A missing transcript row cannot prove that spawn never
                    // happened. Preserve this receipt for explicit review.
                    crate::chat_receipts::ReceiptState::Pending
                    | crate::chat_receipts::ReceiptState::NeedsRecovery => {
                        return Err(DispatchError::delivery_unknown(
                            "This message may already have started. Check the conversation before copying it into a new draft.",
                        ));
                    }
                }
            }
        }
        if client_message_id.is_some() {
            crate::chat_receipts::validate_created_at(client_message_created_at_ms, now_ms())?;
            if expected_revision.is_none() {
                return Err(DispatchError::new(
                    "send_upgrade_required",
                    "Update this client and review the conversation before sending. Its saved message is missing the conversation revision.",
                ));
            }
        }
        if expected_revision.is_some_and(|expected| expected != chat.send_revision) {
            return Err(DispatchError::new(
                "conversation_changed",
                "This conversation changed before your message was sent. Review the latest conversation and try again. Your pending copy stays here.",
            ));
        }
        // After a receipt replay, which must not clear a Stop, and before the
        // running guard, which would turn a retired note into an error the
        // caller then puts back.
        if self.follow_up_should_skip(id, follow_up) {
            return Ok(SendOutcome::Suppressed(chat));
        }
        if chat.running
            || self
                .active
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains_key(id)
        {
            return Err("this chat is already responding".into());
        }
        // Lease before install. Another instance holding the runner is the
        // sharper truth than "agent not installed" on a machine that does
        // not have this backend on PATH, and CI runners often have none.
        let runner = crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?
            .ok_or("This conversation is already running in another instance of tokenstat.")?;
        if crate::launcher::profile_installed(launcher_profile_id(&chat.backend)) == Some(false) {
            return Err(DispatchError::new(
                "agent_not_installed",
                format!(
                    "{} is not installed on this host. Set it up or choose another agent. Your draft stays on your device.",
                    chat.backend
                ),
            ));
        }
        let attachments = self.attachment_paths(id, attachment_ids)?;
        let response_output_dir = self.prepare_response_output_dir(id)?;
        self.recover_codex_session(&mut chat);
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
        let mut composed = crate::chat_turn::compose(crate::chat_turn::Inputs {
            prompt,
            persona_name: &self.persona_name(&chat),
            persona_brief: &chat.system_prompt,
            attachments: &attachments,
            output_dir: &response_output_dir,
            backend: &chat.backend,
        });
        // How to ask the person something, for this kind of turn: a turn that
        // does not ask before tools must never wait, and one whose agent can
        // take a note mid-turn can be answered without stopping.
        composed.append_standing(&crate::chat_question::rule(
            chat.autonomy == "standard",
            takes_notes_mid_turn(&chat),
        ));
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
        // Muse still needs the helper on a bypass turn. Its note rides a model
        // step whether or not the turn asks first.
        let asks_before_tools = chat.autonomy == "standard";
        let muse_note = chat.backend == "muse" && note_backend("muse");
        let helper = if asks_before_tools || muse_note {
            Some(std::env::current_exe().map_err(|_| "cannot locate the tokenstat host hook")?)
        } else {
            None
        };
        let agy_customization_dir =
            (chat.backend == "agy" && chat.autonomy == "standard").then(|| self.agy_hook_home(id));
        let grok_allow_rules = grok_allow_rules(&chat);
        let mut argv = crate::automations::chat_agent_command(
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
        let turn = if asks_before_tools || muse_note {
            let token = self.register_turn_token(id, &chat.backend)?;
            match self.write_turn_file(id, &token) {
                Ok(file) => Some((token, file)),
                Err(error) => {
                    self.revoke_turn_token(&token);
                    return Err(error.into());
                }
            }
        } else {
            None
        };
        // Until a process is spawned, this credential is this function's to
        // retire. Any `?` below would otherwise leave its token registered and
        // its file on disk after the send has already failed.
        let mut pending_credential = turn
            .as_ref()
            .map(|(token, file)| PendingTurnCredential::new(self, token.clone(), file.clone()));
        let mut pending_muse = PendingMuseHome::idle();
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
        let codex_home = if chat.backend == "codex" && private_codex_home(helper.is_some()) {
            let home = self.codex_home(id);
            crate::chat_gate::write_codex_home(&home, helper.as_deref())?;
            environment.push(("CODEX_HOME".into(), home.display().to_string()));
            Some(home)
        } else {
            None
        };
        // Like Codex, Grok keeps its sessions inside its private home, so the
        // home must outlive the turn for the next message to resume it.
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
        if muse_note {
            let hook_helper = helper
                .as_deref()
                .ok_or(crate::chat_gate::MUSE_NOTE_PREPARE)?;
            let turn_file = turn
                .as_ref()
                .map(|(_, file)| file.as_path())
                .ok_or(crate::chat_gate::MUSE_NOTE_PREPARE)?;
            let socket = crate::server::default_socket_path()?;
            // Mirror the same config root Muse inherited before this turn's
            // override. A customized XDG home can hold its sign-in as well as
            // its settings, and the login shell can supply it to a daemon.
            let login = tokenstat_pty::login_env();
            let config_root = match &login {
                Some(environment) => environment.vars.get("XDG_CONFIG_HOME").map(PathBuf::from),
                None => std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from),
            };
            let user_home = login
                .as_ref()
                .and_then(|environment| environment.vars.get("HOME"))
                .filter(|home| !home.is_empty())
                .map(PathBuf::from)
                .or_else(tokenstat_paths::home_dir);
            let user_config = crate::chat_gate::muse_config_directory(
                config_root.as_deref(),
                user_home.as_deref(),
            );
            if let Some(root) = crate::chat_gate::install_muse_note_home(
                user_config.as_deref(),
                hook_helper,
                &socket,
                turn_file,
            )? {
                environment.push(("XDG_CONFIG_HOME".into(), root.display().to_string()));
                pending_muse.arm(root);
            }
        }
        // Read last of the things that can refuse this send, so a repeat of a
        // message the host already took is answered even if the folder has
        // since been unregistered.
        let workspace = crate::workspaces::folder(&chat.workspace_id)?;
        let prompt_file = crate::chat_turn::PromptFile::for_windows_muse(
            &chat.backend,
            &mut argv,
            &response_output_dir,
        )?;
        // Written before anything is started, so a host that dies between the
        // spawn and its answer leaves a record to reconcile against rather
        // than a message the next attempt would run a second time.
        crate::workspace_policy::require_current_access()?;
        // Reserve a new revision durably before launch. Even a failed spawn
        // consumes it: another client must review the changed launch intent.
        let branch = tokenstat_workspace::git::current_branch(&workspace.path);
        self.edit_conversation(id, |current| {
            current.send_revision = next_send_revision(current.send_revision)?;
            current.branch = branch;
            Ok(())
        })?;
        let accepted_at = now_ms();
        if let Some(key) = &receipt_key {
            self.write_receipt(
                id,
                key,
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Pending,
                    digest: digest.clone(),
                    at_ms: accepted_at,
                    event_at_ms: None,
                },
            )?;
        }
        let info = match tokenstat_pty::manager()
            .spawn(&tokenstat_pty::Spawn {
                command: crate::launcher::spawn_command(&argv[0]),
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
            .map_err(|e| e.to_string())
        {
            Ok(info) => info,
            Err(error) => {
                // Nothing was delivered, so the receipt has to go with it or
                // the next attempt would be refused as a repeat.
                if let Some(key) = &receipt_key {
                    let _ = self.drop_receipt(id, key);
                }
                return Err(error.into());
            }
        };
        // The process exists and its drain thread will retire the credential.
        if let Some(pending) = pending_credential.as_mut() {
            pending.release();
        }
        let muse_hook_home = pending_muse.release();
        self.active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id.into(), info.id.clone());
        let recorded = (|| -> Result<Conversation, String> {
            let running = self.set_running(id, true)?;
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
            let user_at = now_ms();
            self.append(
                id,
                &StoredEvent::User {
                    text: prompt.into(),
                    at_ms: user_at,
                },
            )?;
            // What the person attached rides the timeline as its own rows, so a
            // sent image stays visible instead of vanishing into the turn. The
            // bytes already live beside the chat; these records are only the
            // names the rows render and the ids they fetch by.
            debug_assert_eq!(
                attachment_ids.len(),
                attachments.len(),
                "attachment ids and staged paths travel 1:1"
            );
            for (attachment_id, path) in attachment_ids.iter().zip(attachments.iter()) {
                self.append(
                    id,
                    &StoredEvent::Agent {
                        event: attachment_event(attachment_id, path),
                        at_ms: now_ms(),
                        backend: chat.backend.clone(),
                    },
                )?;
            }
            self.mark_last_message(id, user_at, "user")?;
            self.retitle_if_untitled(id, prompt)?;
            // The person's own message is on the timeline. A note parked for
            // the turn this replaces must not ride the next tool of the new
            // one. A follow-up is that note, so it is left for the hooks.
            if !follow_up {
                self.steers
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(id);
                self.reconcile_parked_answers(id);
            }
            OpenOptions::new()
                .read(true)
                .write(true)
                .open(self.events_path(id))
                .and_then(|file| file.sync_all())
                .map_err(|e| e.to_string())?;
            // The turn is running and the message is on the timeline. A repeat of
            // this id now gets the conversation back and starts nothing.
            if let Some(key) = &receipt_key {
                self.write_receipt(
                    id,
                    key,
                    crate::chat_receipts::Receipt {
                        state: crate::chat_receipts::ReceiptState::Accepted,
                        digest,
                        at_ms: accepted_at,
                        event_at_ms: Some(user_at),
                    },
                )?;
            }
            Ok(running)
        })();
        let store = Arc::clone(self);
        let chat_id = id.to_string();
        let backend = chat.backend;
        // Preserve the backend's original stream per turn. Structured events
        // are what the UI reads, but raw output lets a parser correction
        // rematerialize an older conversation without rerunning an agent.
        let raw_path = self.raw_path(id, now_ms());
        let turn_token = turn.as_ref().map(|(token, _)| token.clone());
        let turn_file = turn.as_ref().map(|(_, file)| file.clone());
        let codex_home = codex_home.clone();
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
            drop(prompt_file);
            let _ = store.finish_turn(
                &chat_id,
                &info.id,
                Some(runner),
                || {
                    if let Some(token) = turn_token {
                        store.revoke_turn_token(&token);
                    }
                    if let Some(file) = turn_file {
                        let _ = fs::remove_file(file);
                    }
                },
                || {
                    let _ = fs::remove_dir_all(&response_output_dir);
                    if let Some(home) = codex_home {
                        let _ = crate::chat_gate::clear_codex_hooks(&home);
                    }
                    if let Some(home) = agy_hook_home {
                        let _ = fs::remove_dir_all(home);
                    }
                    if let Some(home) = opencode_hook_home {
                        let _ = fs::remove_dir_all(home);
                    }
                    if let Some(home) = muse_hook_home {
                        crate::chat_gate::remove_muse_home(&home);
                    }
                },
            );
        });
        recorded
            .map(SendOutcome::Started)
            .map_err(DispatchError::delivery_unknown)
    }

    pub fn stop(&self, id: &str) -> Result<(), String> {
        validate_record_id(id)?;
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        crate::workspace_policy::require_current_access().map_err(|error| error.to_string())?;
        let pty = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned();
        if let Some(pty) = pty {
            // Before kill, and before any path that clears `running`. A poll
            // must not see a finished turn that still carries the note.
            self.retire_steer(id);
            self.killed
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(id.into());
            match tokenstat_pty::manager().kill(&pty) {
                Ok(()) | Err(tokenstat_pty::PtyError::NoSession(_)) => {}
                Err(error) => {
                    self.killed
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .remove(id);
                    return Err(error.to_string());
                }
            }
            // A session the manager no longer knows has no drain thread coming
            // to reap it, so waiting for one wedges the composer until the
            // daemon restarts. Release the guard here instead. A session that
            // is still registered is left alone: its drain owns the ending and
            // the cleanup, and finish_turn ignores a guard that no longer
            // names its own session. No ending is appended: the drain wrote
            // one on its way out, when there was a drain.
            if tokenstat_pty::manager().info(&pty).is_err()
                && self
                    .active
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .get(id)
                    .is_some_and(|current| current == &pty)
            {
                self.active
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(id);
                // Nothing was killed: there was no session. Leaving the mark
                // would end the next turn as stopped.
                self.killed
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(id);
                // Best effort: the guard is already gone, so a failed write is
                // healable through the no-session path below on a retry.
                let _ = self.set_running(id, false);
            }
        } else {
            if crate::chat_receipts::RunnerLease::try_acquire(&self.root, id)?.is_none() {
                return Err(
                    "Another instance of tokenstat is running this conversation. Stop it there."
                        .into(),
                );
            }
            // After the conversation is known to be this instance's, and
            // before `running` is cleared. A missing id still takes the
            // existing error and leaves any note alone.
            let chat = self.get(id)?;
            self.retire_steer(id);
            self.append(
                id,
                &StoredEvent::Agent {
                    event: Event::Done {
                        status: "stopped".into(),
                        exit_code: None,
                    },
                    at_ms: now_ms(),
                    backend: chat.backend,
                },
            )?;
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
        let mut questions = crate::chat_question::Scanner::default();
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
                    questions.shift(collect_agent_text(&events, &mut assistant_text));
                    self.record_events(id, backend, events);
                    // Mid-turn, so the card is in front of the person while
                    // an answer can still reach this turn.
                    self.record_questions(id, backend, questions.scan(&assistant_text));
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
            questions.shift(collect_agent_text(&events, &mut assistant_text));
            self.record_events(id, backend, events);
        }
        let events = parser.finish_events();
        questions.shift(collect_agent_text(&events, &mut assistant_text));
        self.record_events(id, backend, events);
        self.record_questions(id, backend, questions.finish(&assistant_text));
        self.record_response_attachments(id, backend, &assistant_text, response_output_dir);
        let exit = manager.info(pty).ok().and_then(|info| info.exit_code);
        let stopped = self
            .killed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        let status = turn_status(exit, stopped);
        self.record_events(
            id,
            backend,
            vec![Event::Done {
                status: status.into(),
                exit_code: exit,
            }],
        );
        let _ = self.mark_last_message(id, now_ms(), "agent");
        // Same rule as the approval above: a turn that ended in front of
        // somebody has already told them.
        if let Some(reason) = chat_notification(status).filter(|_| !crate::presence::is_watched(id))
        {
            tokenstat_sync::push::notify_in_background(reason);
        }
        manager.forget_reader(pty, &reader);
        let _ = manager.close(pty);
    }

    // A following send must not reuse turn directories until their previous
    // owner has finished cleanup. A late drainer cannot retire a newer turn.
    fn finish_turn(
        &self,
        id: &str,
        pty: &str,
        runner: Option<crate::chat_receipts::RunnerLease>,
        retire_credentials: impl FnOnce(),
        cleanup: impl FnOnce(),
    ) -> Result<(), String> {
        // This turn's credential and turn file are its own whatever the
        // conversation is doing now. A newer turn owning the conversation
        // must not keep a dead turn's token or file alive.
        retire_credentials();
        let _acceptance = crate::chat_receipts::Operation::conversation(&self.root, id)?;
        // Hands off only when a newer turn owns the conversation. An unowned
        // one is still this drainer's to retire: its cleanup must run even
        // when the guard below was already released elsewhere.
        if self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .is_some_and(|current| current != pty)
        {
            return Ok(());
        }
        cleanup();
        let status = self.stop_running(id);
        // The guard goes even when that write fails, or every later send is
        // refused as already responding while Stop reports success without
        // changing anything. A newer turn cannot have appeared in between:
        // sends are refused while this entry is present.
        self.active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        drop(runner);
        status.map(|_| ())
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

    fn record_questions(
        &self,
        id: &str,
        backend: &str,
        found: Vec<crate::chat_question::Question>,
    ) {
        for question in found {
            let _ = self.append(
                id,
                &StoredEvent::Question {
                    id: mint_record_id("question"),
                    question: question.question,
                    options: question.options,
                    multiple: question.multiple,
                    default: question.default,
                    blocking: question.blocking,
                    backend: backend.into(),
                    at_ms: now_ms(),
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
        let Ok(lifecycle) = crate::work_handoff_store::lifecycle_lock(&self.root) else {
            return;
        };
        if self.verified_append_directory(id).is_err() {
            return;
        }
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
            let attachment_id = format!("{}-{index}", mint_record_id("output"));
            let destination = self.attachment_path(id, &attachment_id, &name);
            let Some(parent) = destination.parent() else {
                continue;
            };
            if fs::create_dir_all(parent).is_err() {
                continue;
            }
            if fs::copy(&source, &destination).is_err() {
                let _ = fs::remove_file(&destination);
                let _ = fs::remove_dir(parent);
                continue;
            }
            let written = self.append_with_lifecycle(
                &lifecycle,
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
            if written.is_err() {
                let _ = fs::remove_file(&destination);
                let _ = fs::remove_dir(parent);
            }
        }
    }

    /// The caller holds the root lifecycle lock until all writes finish.
    fn verified_append_directory(&self, id: &str) -> Result<PathBuf, String> {
        validate_record_id(id)?;
        let chats = self
            .conversations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let chat = chats
            .iter()
            .find(|chat| chat.id == id)
            .ok_or("this conversation is no longer available")?;
        self.verified_conversation(&chat.workspace_id, id, &chats)
            .map(|(path, _)| path)
    }

    fn append(&self, id: &str, event: &StoredEvent) -> Result<(), String> {
        let lifecycle = crate::work_handoff_store::lifecycle_lock(&self.root)?;
        self.append_with_lifecycle(&lifecycle, id, event)
    }

    fn append_with_lifecycle(
        &self,
        _lifecycle: &crate::work_handoff_store::Guard,
        id: &str,
        event: &StoredEvent,
    ) -> Result<(), String> {
        use std::io::Read;
        let _guard = crate::work_handoff_store::transcript_lock(&self.root)?;
        let directory = self.verified_append_directory(id)?;
        let path = directory.join("events.ndjson");
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        let mut options = OpenOptions::new();
        options.create(true).read(true).append(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&path).map_err(|e| e.to_string())?;
        let metadata = file.metadata().map_err(|e| e.to_string())?;
        if !metadata.is_file()
            || metadata.len()
                > PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64
        {
            return Err("conversation transcript is not a bounded regular file".into());
        }
        let end = metadata.len();
        let (base, tail) = read_back_checked(&path, end, 1, true)?;
        let seq = crate::work_transcript_identity::next_sequence(&tail, base)?;
        let Value::Object(record) = serde_json::to_value(event).map_err(|e| e.to_string())? else {
            return Err("conversation event could not be encoded".into());
        };
        let encoded = crate::work_transcript_identity::encoded(record, seq)?;
        if encoded.len() as u64 > PAGE_RECORD_BYTES {
            return Err("conversation event exceeds the record limit".into());
        }
        if end + encoded.len() as u64 > EVENTS_CAP {
            let mut bytes = Vec::new();
            (&mut file)
                .take(PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            if bytes.len() as u64 != end {
                return Err("conversation transcript changed while reading".into());
            }
            bytes.extend_from_slice(&encoded);
            // Leave room for streamed deltas instead of rewriting on every
            // token. A single readable large record is retained in full.
            let cap = (EVENTS_CAP as usize * 3 / 4)
                .max(encoded.len() + crate::work_transcript_identity::SUMMARY_BYTES);
            let kept = crate::work_transcript_identity::retained(&bytes, cap)?;
            drop(file);
            replace_chat_file(&path, &kept)?;
        } else if let Err(error) = file.write_all(&encoded) {
            // An ordinary I/O failure must not leave half a JSON record.
            // A process crash is detected by the complete-tail check above.
            file.set_len(end).map_err(|e| e.to_string())?;
            return Err(error.to_string());
        }
        Ok(())
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
        self.edit_conversation(id, |chat| {
            if chat.title == "New chat" {
                chat.title = title_from_prompt(prompt);
                chat.updated_at_ms = now_ms();
            }
            Ok(())
        })
    }

    /// The turn is over: clear the running bit, and note the branch the
    /// agent left the folder on, which may be one it just created.
    fn stop_running(&self, id: &str) -> Result<Conversation, String> {
        let branch = self
            .get(id)
            .ok()
            .and_then(|chat| crate::workspaces::folder(&chat.workspace_id).ok())
            .map(|workspace| tokenstat_workspace::git::current_branch(&workspace.path));
        self.edit_conversation(id, |chat| {
            chat.running = false;
            chat.updated_at_ms = now_ms();
            if let Some(branch) = branch {
                chat.branch = branch;
            }
            Ok(chat.clone())
        })
    }

    fn set_running(&self, id: &str, running: bool) -> Result<Conversation, String> {
        self.edit_conversation(id, |chat| {
            chat.running = running;
            chat.updated_at_ms = now_ms();
            Ok(chat.clone())
        })
    }
    fn mark_last_message(&self, id: &str, at_ms: i64, author: &str) -> Result<(), String> {
        self.edit_conversation(id, |chat| {
            chat.last_message_at_ms = Some(at_ms);
            chat.last_message_author = Some(author.into());
            chat.updated_at_ms = chat.updated_at_ms.max(at_ms);
            Ok(())
        })
    }
    fn set_resume(&self, id: &str, backend: &str, token: &str) -> Result<(), String> {
        self.edit_conversation(id, |chat| {
            chat.resume_tokens.insert(backend.into(), token.into());
            chat.resume_token = Some(token.into());
            chat.updated_at_ms = now_ms();
            Ok(())
        })
    }
    /// Remember that one backend now holds this version of the conversation's
    /// standing rules, so the next turn on it can be the person's words alone.
    fn mark_standing_sent(&self, id: &str, backend: &str, fingerprint: &str) -> Result<(), String> {
        self.edit_conversation(id, |chat| {
            chat.standing_sent
                .insert(backend.into(), fingerprint.into());
            Ok(())
        })
    }

    fn transcript_guard(&self) -> Result<Option<crate::work_handoff_store::Guard>, String> {
        if self.root.exists() {
            crate::work_handoff_store::transcript_lock(&self.root).map(Some)
        } else {
            Ok(None)
        }
    }

    fn events_path(&self, id: &str) -> PathBuf {
        // `id` is validated at every public entry point; this is internal.
        // Fall back to a safe name if called with an unexpected value.
        let safe = safe_file_name(id);
        self.root.join(safe).join("events.ndjson")
    }

    fn raw_path(&self, id: &str, turn_started_at_ms: i64) -> PathBuf {
        let safe = safe_file_name(id);
        self.root
            .join(safe)
            .join("raw")
            .join(format!("{turn_started_at_ms}.ndjson"))
    }

    fn codex_home(&self, id: &str) -> PathBuf {
        self.root.join(safe_file_name(id)).join("codex-hook")
    }

    /// Older turns deleted this home during cleanup. Give a fresh Codex
    /// session the stored conversation instead of resuming a missing rollout.
    /// Keep this decision local until the new session reports its own token.
    fn recover_codex_session(&self, chat: &mut Conversation) {
        if chat.backend == "codex"
            && private_codex_home(chat.autonomy == "standard")
            && !self.codex_home(&chat.id).join("sessions").is_dir()
        {
            chat.resume_tokens.remove("codex");
            chat.resume_token = None;
            chat.standing_sent.remove("codex");
        }
    }

    /// The folder this conversation's outputs are staged in.
    ///
    /// The path stays stable for the life of the conversation because it is
    /// named inside the standing file rule, and a path that moved every turn
    /// would move the standing fingerprint with it and re-send the rules on
    /// every turn. It lives under the private data directory rather than the
    /// shared temp directory, and `prepare_response_output_dir` empties and
    /// recreates it fresh for each turn.
    fn response_output_dir(&self, id: &str) -> PathBuf {
        self.root.join(safe_file_name(id)).join("output")
    }

    /// Create this turn's staging directory fresh, accessible only to the
    /// user. A leftover from a crashed turn is removed first so its files can
    /// never be mistaken for this turn's output.
    fn prepare_response_output_dir(&self, id: &str) -> Result<PathBuf, String> {
        let directory = self.response_output_dir(id);
        if fs::symlink_metadata(&directory).is_ok() {
            fs::remove_dir_all(&directory).map_err(|error| error.to_string())?;
        }
        let parent = directory.parent().ok_or("invalid chat output path")?;
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            let mut builder = fs::DirBuilder::new();
            builder.mode(0o700);
            builder
                .create(&directory)
                .map_err(|error| error.to_string())?;
        }
        #[cfg(not(unix))]
        fs::create_dir(&directory).map_err(|error| error.to_string())?;
        Ok(directory)
    }

    fn write_turn_file(&self, id: &str, token: &str) -> Result<PathBuf, String> {
        let path = safe_join(&self.root, id)?.join(format!("turn-{}.token", now_ms()));
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
        if let Err(error) = file.write_all(token.as_bytes()) {
            // A half-written credential file is still a credential-shaped
            // file; the send has failed, so it must not stay behind.
            let _ = fs::remove_file(&path);
            return Err(error.to_string());
        }
        Ok(path)
    }

    fn agy_hook_home(&self, id: &str) -> PathBuf {
        self.root.join(safe_file_name(id)).join("agy-hook")
    }

    /// Persistent for the life of the conversation, unlike the other homes.
    /// See `chat_gate::write_grok_home`: grok keeps its sessions in here, so
    /// deleting it after a turn would delete the thing `--resume` needs.
    fn grok_hook_home(&self, id: &str) -> PathBuf {
        self.root.join(safe_file_name(id)).join("grok-home")
    }

    fn write_opencode_hook_home(&self, id: &str) -> Result<(PathBuf, PathBuf), String> {
        let home = safe_join(&self.root, id)?.join("opencode-hook");
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
            .join(safe_file_name(chat_id))
            .join("files")
            .join(safe_file_name(attachment_id))
            .join(safe_file_name(name))
    }

    fn attachment_paths(&self, chat_id: &str, ids: &[String]) -> Result<Vec<PathBuf>, String> {
        ids.iter()
            .map(|id| self.single_attachment_path(chat_id, id))
            .collect()
    }

    fn single_attachment_path(&self, chat_id: &str, id: &str) -> Result<PathBuf, String> {
        validate_record_id(chat_id)?;
        validate_record_id(id)?;
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
        // Two saves can overlap. A fixed temp name let the second writer
        // rename the first writer's half-written file into place, and a crash
        // could leave that truncated file where the next load would trust it.
        // The pid plus a process-wide counter gives each attempt its own file.
        let temporary = ChatTemporary(self.root.join(format!(
            ".personas-{}-{:x}.tmp",
            std::process::id(),
            RECORD_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        )));
        fs::write(
            &temporary.0,
            serde_json::to_vec_pretty(&index).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        fs::rename(&temporary.0, self.root.join("personas.json")).map_err(|e| e.to_string())
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

fn turn_status(exit: Option<i32>, stopped: bool) -> &'static str {
    if stopped {
        "stopped"
    } else if exit == Some(0) {
        "ok"
    } else {
        "error"
    }
}

fn chat_notification(status: &str) -> Option<tokenstat_sync::push::Reason> {
    match status {
        "ok" => Some(tokenstat_sync::push::Reason::ChatFinished),
        "error" => Some(tokenstat_sync::push::Reason::ChatFailed),
        // Stop came from the person at a keyboard. It is not news to them and
        // must never be narrated as a failed turn on another device.
        _ => None,
    }
}

fn has_live_approval(approvals: &[Approval], conversation_id: &str, now: i64) -> bool {
    approvals.iter().any(|pending| {
        pending.conversation_id == conversation_id
            && pending.decision.is_none()
            && pending.expires_at_ms > now
    })
}

/// Append one backend chunk to the turn's raw spill, keeping the file bounded.
///
/// Raw output is what lets a parser correction rematerialize an old turn, so
/// it is kept rather than dropped. The cap keeps one runaway turn from filling
/// the data directory: when the file would pass it, the oldest bytes go and a
/// marker line records that they did.
fn append_raw(path: &PathBuf, bytes: &[u8]) -> Result<(), String> {
    use std::io::{Read, Seek, SeekFrom};
    fs::create_dir_all(path.parent().ok_or("invalid chat raw path")?).map_err(|e| e.to_string())?;
    let mut options = OpenOptions::new();
    options.create(true).read(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // A spill from an older build may predate the 0600 creation mode.
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
    }
    let len = file.metadata().map_err(|e| e.to_string())?.len();
    if len + bytes.len() as u64 <= RAW_CAP {
        return file.write_all(bytes).map_err(|e| e.to_string());
    }
    let keep = RAW_RETAIN.saturating_sub(bytes.len() as u64).min(len);
    let start = len - keep;
    let mut tail = vec![0u8; keep as usize];
    file.seek(SeekFrom::Start(start))
        .map_err(|e| e.to_string())?;
    file.read_exact(&mut tail).map_err(|e| e.to_string())?;
    // A chunk boundary can land mid-line. Drop the partial first line rather
    // than keep a record no reader can parse.
    match tail.iter().position(|byte| *byte == b'\n') {
        Some(newline) => drop(tail.drain(..=newline)),
        None => tail.clear(),
    }
    let marker = format!(
        "{{\"tokenstat\":\"raw truncated\",\"droppedBytes\":{start},\"atMs\":{}}}\n",
        now_ms()
    );
    file.set_len(0).map_err(|e| e.to_string())?;
    file.write_all(marker.as_bytes())
        .map_err(|e| e.to_string())?;
    file.write_all(&tail).map_err(|e| e.to_string())?;
    file.write_all(bytes).map_err(|e| e.to_string())
}

fn read_fork_file(path: &Path, maximum: u64, missing_is_empty: bool) -> Result<Vec<u8>, String> {
    use std::io::Read;
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.is_file() || metadata.len() > maximum => {
            return Err("the chat file cannot be copied".into());
        }
        Err(error) if missing_is_empty && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Vec::new());
        }
        Err(error) => return Err(error.to_string()),
        _ => {}
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if missing_is_empty && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Vec::new());
        }
        Err(error) => return Err(error.to_string()),
    };
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file() || metadata.len() > maximum {
        return Err("the chat file cannot be copied".into());
    }
    let mut bytes = Vec::new();
    file.take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() as u64 > maximum {
        return Err("the chat file exceeds the copying limit".into());
    }
    Ok(bytes)
}

fn copy_fork_files(source: &Path, destination: &Path) -> Result<(), String> {
    let metadata = match fs::symlink_metadata(source) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    if !metadata.is_dir() {
        return Err("invalid chat attachment directory".into());
    }
    for attachment in fs::read_dir(source).map_err(|error| error.to_string())? {
        let attachment = attachment.map_err(|error| error.to_string())?;
        if !attachment
            .file_type()
            .map_err(|error| error.to_string())?
            .is_dir()
        {
            return Err("invalid chat attachment directory".into());
        }
        let directory = destination.join(attachment.file_name());
        fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
        for file in fs::read_dir(attachment.path()).map_err(|error| error.to_string())? {
            let file = file.map_err(|error| error.to_string())?;
            let bytes = read_fork_file(&file.path(), ATTACHMENT_CAP as u64, false)?;
            write_private_file(&directory.join(file.file_name()), &bytes)?;
        }
    }
    Ok(())
}

/// Write a chat-owned file at user-only permissions, refusing to follow a
/// symlink at the path. Raw output, `brain.md` and `history.md` are private
/// records; the process umask is not a permission model.
fn write_private_file(path: &Path, contents: &[u8]) -> Result<(), String> {
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // A file from an older build may predate the 0600 creation mode.
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
    }
    file.write_all(contents).map_err(|error| error.to_string())
}

/// One timeline row for a file the person attached to their own message.
///
/// Derived from the staged file, never from client text: the name is the
/// leaf on disk, the size is measured, and the media type comes from the
/// extension table, so a row cannot claim an image it does not have.
fn attachment_event(id: &str, path: &Path) -> Event {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .map(safe_file_name)
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "attachment".into());
    let size = fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
    Event::Attachment {
        id: id.into(),
        name,
        media_type: media_type_for_path(path),
        size,
    }
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

/// Append the turn's reply text, and say how many bytes were dropped from the
/// front, so anything holding an offset into the text can move it along.
///
/// Any other event between two runs of text ends a line: a tool call, an
/// edit, a thought, a usage report or an attachment. The agent wrote them as
/// separate blocks, every client draws them as separate rows, and joined back
/// to back a fence that closed one block or opened the next would sit
/// mid-line, where the question scanner rightly refuses to see a fence. A
/// client would still strip that block from the reply, and the question
/// would be lost from both places.
fn collect_agent_text(events: &[Event], text: &mut String) -> usize {
    for event in events {
        match event {
            Event::Text { delta } => text.push_str(delta),
            _ if !text.is_empty() && !text.ends_with('\n') => text.push('\n'),
            _ => {}
        }
    }
    // Trim in one pass once the buffer is twice the tail, rather than moving
    // it on every delta.
    if text.len() > ASSISTANT_TEXT_TAIL * 2 {
        let mut cut = text.len() - ASSISTANT_TEXT_TAIL;
        while cut < text.len() && !text.is_char_boundary(cut) {
            cut += 1;
        }
        text.drain(..cut);
        return cut;
    }
    0
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
        // Markdown links may contain either POSIX paths or native Windows
        // paths. Keep the absolute-path boundary: relative links and URLs do
        // not grant permission to read from the machine.
        let is_absolute = local.starts_with('/') || Path::new(local).is_absolute();
        if !is_absolute {
            continue;
        }
        let decoded = percent_decode_path(local);
        // `file:///C:/...` is the URL spelling Windows commonly emits. The
        // leading slash is a URL separator, not part of the drive path.
        let decoded = if cfg!(windows)
            && decoded.starts_with('/')
            && decoded.as_bytes().get(2) == Some(&b':')
        {
            &decoded[1..]
        } else {
            &decoded
        };
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
    String::from_utf8_lossy_owned(output)
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
    migrate_starter_names(&mut index);
    index
}

fn migrate_starter_names(index: &mut PersonaIndex) {
    for position in 0..index.personas.len() {
        let persona = &index.personas[position];
        let Some(workspace) = persona.workspace_id.as_deref() else {
            continue;
        };
        // A saved edit or a custom brief belongs to the person who wrote it.
        if persona.created_at_ms <= 0
            || persona.created_at_ms != persona.updated_at_ms
            || persona.system_prompt != STARTER_BRIEF
        {
            continue;
        }
        let Some(legacy) = LEGACY_STARTER_NAMES
            .iter()
            .position(|name| *name == persona.name)
        else {
            continue;
        };
        let taken: HashSet<String> = index
            .personas
            .iter()
            .enumerate()
            .filter(|(other, persona)| *other != position && persona_visible(persona, workspace))
            .map(|(_, persona)| persona.name.clone())
            .collect();
        let preferred = STARTER_NAMES[legacy];
        let name = if taken.contains(preferred) {
            starter_name(workspace, &taken)
        } else {
            preferred
        };
        index.personas[position].name = name.to_string();
    }
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

/// A human-sortable, process-unique id for chat records that become paths.
fn mint_record_id(prefix: &str) -> String {
    let sequence = RECORD_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}-{}-{sequence}", now_ms())
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
        None => {
            "`name` is a short, friendly, familiar human first name, such as Nora, Milo or Lucy. \
                 Avoid role titles, nature words and invented names."
                .into()
        }
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

/// Recover message metadata for an index written before those fields existed.
/// Event archives are capped, so this is a bounded startup read performed once
/// per legacy conversation and persisted back into the index immediately.
fn last_message_in(path: &Path) -> Option<(i64, &'static str)> {
    let bytes = fs::read(path).ok()?;
    let text = std::str::from_utf8(&bytes).ok()?;
    text.lines().rev().find_map(|line| {
        let event: StoredEvent = serde_json::from_str(line).ok()?;
        match event {
            StoredEvent::User { at_ms, .. } => Some((at_ms, "user")),
            StoredEvent::Agent { at_ms, .. } => Some((at_ms, "agent")),
            // A question rides an agent reply and an answer rides a message,
            // and each of those is counted where it is recorded.
            StoredEvent::Approval { .. }
            | StoredEvent::Handoff { .. }
            | StoredEvent::Question { .. }
            | StoredEvent::Answer { .. }
            | StoredEvent::AnswerWithdrawn { .. } => None,
        }
    })
}

fn launcher_profile_id(backend: &str) -> &str {
    match backend {
        "sh" => "shell",
        "claude" => "claude_code",
        "cursor" => "cursor_agent",
        "agy" => "antigravity",
        other => other,
    }
}

pub fn backends(force: bool) -> Vec<Value> {
    let catalog = crate::launcher::catalog();
    crate::automations::backends(force)
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
                    // Muse's headless approval UI is not tokenstat's hook
                    // protocol, so expose it as an explicit Bypass choice.
                    // Bypass invokes Muse's `--yolo` mode: no approvals and
                    // no workspace sandbox for that explicitly trusted run.
                    json!(if matches!(id, "cursor" | "sh" | "muse") {
                        "bypassOnly"
                    } else {
                        "full"
                    }),
                );
            }
            let id = backend["id"].as_str().unwrap_or("").to_string();
            if let Some(profile) = catalog.as_array().and_then(|profiles| {
                profiles
                    .iter()
                    .find(|profile| profile["id"].as_str() == Some(launcher_profile_id(&id)))
            }) {
                backend["installed"] = profile["installed"].clone();
                backend["launcherId"] = profile["id"].clone();
                backend["canInstall"] = json!(
                    profile["installCommand"]
                        .as_str()
                        .is_some_and(|s| !s.is_empty())
                );
                backend["readiness"] = profile["readiness"].clone();
                backend["signIn"] = profile["signIn"].clone();
                backend["canCheckSignIn"] = profile["canCheckSignIn"].clone();
            }
            // Chat advertises the live list where enumeration works and the
            // curated list where it cannot (Claude's aliases, Muse's Spark
            // set): both arrive from `automations::backends` already merged.
            // Only a missing agent advertises nothing. The agent's own
            // default remains usable when enumeration is unsupported or fails.
            backend["modelListStatus"] = json!(crate::agent_models::list_status(&id));
            if backend["installed"] == false {
                backend["models"] = json!(Vec::<String>::new());
            }
            backend
        })
        .collect()
}

/// Grok evaluates explicit rules before its headless `dontAsk` fallback. A
/// saved non-shell tool name maps to its documented bare `ToolPrefix`.
///
/// Shell calls are deliberately left out. `Bash(prefix*)` matched anything
/// that merely began with the prefix, so an appended `; curl …` passed an
/// allow meant for `git status`. An exact rule would instead refuse the
/// ordinary flags that made the prefix worth saving. So the `PreToolUse` hook
/// stays the one gate for shells, where `request_approval` matches the
/// derived prefix exactly and answers a repeat without a card.
fn grok_allow_rules(chat: &Conversation) -> Vec<String> {
    let mut rules: Vec<String> = chat
        .allowed_tools
        .iter()
        .filter(|tool| {
            !tool.is_empty()
                && !crate::chat_brain::is_shell(tool)
                && tool
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '_')
        })
        .cloned()
        .collect();
    rules.sort();
    rules.dedup();
    rules
}

/// A physical tail position with enough identity to detect history trimming.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventChunk {
    pub events: Vec<Value>,
    pub next_offset: u64,
    pub tail_cursor: String,
    pub reset: bool,
}

/// One bounded page of a conversation's timeline.
pub struct EventPage {
    pub events: Vec<Value>,
    /// This is the earliest retained window, not the conversation's origin.
    pub history_trimmed: bool,
    /// Byte offset of the first record in this page.
    pub start: u64,
    /// Byte offset just past the last record. The newest page's is where live
    /// tailing carries on from.
    pub next_offset: u64,
    /// Opaque cursor for live polling from this page's end.
    pub tail_cursor: String,
    /// Asks for the page before this one. Absent at the beginning.
    pub cursor: Option<String>,
    pub has_earlier: bool,
    /// The cursor could not be honoured, because the archive was trimmed
    /// under it. This page is the newest one, not the one that was asked for,
    /// and a client should replace what it holds rather than prepend.
    pub reset: bool,
    /// What the whole conversation has spent, with the newest page only.
    pub usage: Option<Value>,
}

/// Fold every usage record in the archive.
///
/// The meter says "this conversation", so it cannot be added up from the page
/// somebody happens to be looking at: reading backwards would make the number
/// climb. Counted here once, when a conversation opens.
///
/// Cheap despite reading the file, because usage is a few dozen records out
/// of thousands and a substring test skips the rest without parsing them.
/// No unbounded vendor-file walks on a sidebar hover.
const VENDOR_USAGE_BYTES: u64 = 32 * 1024 * 1024;
const VENDOR_USAGE_FILES: usize = 256;
const VENDOR_USAGE_ENTRIES: usize = VENDOR_USAGE_FILES * 4;

fn add_usage_value(total: &mut Value, extra: &Value) -> Result<(), String> {
    let mut sum = crate::work_transcript_identity::UsageTotals::from_record(
        json!({"kind":"retainedUsage", "usage":total})
            .as_object()
            .ok_or("invalid usage")?,
    )?;
    sum.add(&crate::work_transcript_identity::UsageTotals::from_record(
        json!({"kind":"retainedUsage", "usage":extra})
            .as_object()
            .ok_or("invalid usage")?,
    )?)?;
    *total = sum.value();
    Ok(())
}

fn usage_difference(total: &Value, recorded: &Value) -> Result<Option<Value>, String> {
    let mut extra = crate::work_transcript_identity::UsageTotals::default().value();
    for key in ["turns", "input", "output", "cacheRead", "cacheWrite"] {
        let count = total[key].as_u64().ok_or("invalid vendor usage")?;
        let previous = recorded[key].as_u64().ok_or("invalid recorded usage")?;
        // Logs may lag a live stream while the vendor is still flushing.
        extra[key] = json!(count.saturating_sub(previous));
    }
    extra["cost"] = json!(
        (total["cost"].as_f64().ok_or("invalid vendor cost")?
            - recorded["cost"].as_f64().ok_or("invalid recorded cost")?)
        .max(0.0)
    );
    Ok((extra["turns"].as_u64().unwrap_or(0) > 0
        || extra["input"].as_u64().unwrap_or(0) > 0
        || extra["output"].as_u64().unwrap_or(0) > 0
        || extra["cacheRead"].as_u64().unwrap_or(0) > 0
        || extra["cacheWrite"].as_u64().unwrap_or(0) > 0
        || extra["cost"].as_f64().unwrap_or(0.0) > 0.0)
        .then_some(extra))
}

fn legacy_codex_usage(directory: &Path, recorded_at: &[i64]) -> Result<Value, String> {
    let mut totals = crate::work_transcript_identity::UsageTotals::default();
    let mut files = match fs::read_dir(directory) {
        Ok(entries) => entries
            .filter_map(Result::ok)
            .filter_map(|entry| {
                let path = entry.path();
                if path.extension()?.to_str()? != "ndjson" {
                    return None;
                }
                Some((path.file_stem()?.to_str()?.parse::<i64>().ok()?, path))
            })
            .collect::<Vec<_>>(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(totals.value()),
        Err(error) => return Err(error.to_string()),
    };
    if files.len() > VENDOR_USAGE_FILES {
        return Err("saved usage exceeds the reading limit".into());
    }
    files.sort_by_key(|(time, _)| *time);
    let mut remaining = VENDOR_USAGE_BYTES;
    for (index, (start, path)) in files.iter().enumerate() {
        let end = files
            .get(index + 1)
            .map(|(time, _)| *time)
            .unwrap_or(i64::MAX);
        if recorded_at
            .iter()
            .any(|time| *time >= *start && *time < end)
        {
            continue;
        }
        let bytes = read_fork_file(path, remaining.min(RAW_CAP), false)?;
        remaining = remaining.saturating_sub(bytes.len() as u64);
        for line in bytes.split(|byte| *byte == b'\n') {
            if !line
                .windows(b"turn.completed".len())
                .any(|chunk| chunk == b"turn.completed")
            {
                continue;
            }
            let Ok(value) = serde_json::from_slice::<Value>(line) else {
                continue;
            };
            if value["type"] != "turn.completed" {
                continue;
            }
            let usage = &value["usage"];
            let Some(input) = usage["input_tokens"].as_u64() else {
                continue;
            };
            let cached = usage["cached_input_tokens"].as_u64().unwrap_or(0);
            let write = usage["cache_write_input_tokens"].as_u64().unwrap_or(0);
            let record = json!({"event":Event::Usage { input: input.saturating_sub(cached).saturating_sub(write),
                output: usage["output_tokens"].as_u64().unwrap_or(0), cache_read: cached, cache_write: write, cost_usd: None }});
            totals.add(&crate::work_transcript_identity::UsageTotals::from_record(
                record.as_object().ok_or("invalid usage")?,
            )?)?;
        }
    }
    Ok(totals.value())
}

/// Muse keeps sessions under year/month/day, independently of the project's
/// creation date. Probe date directories rather than reading unrelated logs.
fn muse_session_directory(root: &Path, token: &str) -> Result<Option<PathBuf>, String> {
    validate_record_id(token)?;
    let direct = root.join(token);
    if fs::symlink_metadata(&direct).is_ok_and(|metadata| metadata.is_dir()) {
        return Ok(Some(direct));
    }
    let date_parts = |directory: &Path,
                      width: usize,
                      maximum: u32,
                      remaining: &mut usize|
     -> Result<Vec<PathBuf>, String> {
        let entries = match fs::read_dir(directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error.to_string()),
        };
        let mut paths = Vec::new();
        for entry in entries {
            charge_vendor_entry(remaining)?;
            let entry = entry.map_err(|error| error.to_string())?;
            let name = entry.file_name();
            let Some(name) = name.to_str().filter(|name| name.len() == width) else {
                continue;
            };
            if name.bytes().all(|byte| byte.is_ascii_digit())
                && name
                    .parse::<u32>()
                    .is_ok_and(|value| value > 0 && value <= maximum)
                && entry
                    .file_type()
                    .map_err(|error| error.to_string())?
                    .is_dir()
            {
                paths.push(entry.path());
            }
        }
        paths.sort_unstable_by(|a, b| b.cmp(a));
        Ok(paths)
    };
    let mut remaining = VENDOR_USAGE_ENTRIES;
    for year in date_parts(root, 4, 9999, &mut remaining)? {
        for month in date_parts(&year, 2, 12, &mut remaining)? {
            for day in date_parts(&month, 2, 31, &mut remaining)? {
                let directory = day.join(token);
                if fs::symlink_metadata(&directory).is_ok_and(|metadata| metadata.is_dir()) {
                    return Ok(Some(directory));
                }
            }
        }
    }
    Ok(None)
}

fn record_at_ms(record: &Value) -> Option<i64> {
    record["at_ms"].as_i64().or_else(|| record["atMs"].as_i64())
}

fn charge_vendor_entry(remaining: &mut usize) -> Result<(), String> {
    *remaining = remaining
        .checked_sub(1)
        .ok_or("saved usage exceeds the directory reading limit")?;
    Ok(())
}

/// Bound discovery itself, including unrelated files and directories. Applying
/// the file cap after a recursive walk still lets that walk block a chat read.
fn muse_usage_files(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let mut directories = vec![directory.to_path_buf()];
    let mut remaining = VENDOR_USAGE_ENTRIES;
    let mut files = Vec::new();
    while let Some(directory) = directories.pop() {
        for entry in fs::read_dir(directory).map_err(|error| error.to_string())? {
            charge_vendor_entry(&mut remaining)?;
            let entry = entry.map_err(|error| error.to_string())?;
            let kind = entry.file_type().map_err(|error| error.to_string())?;
            if kind.is_dir() {
                directories.push(entry.path());
            } else if kind.is_file() && entry.file_name() == "session.jsonl" {
                files.push(entry.path());
                if files.len() > VENDOR_USAGE_FILES {
                    return Err("saved usage exceeds the reading limit".into());
                }
            }
        }
    }
    Ok(files)
}

fn muse_log_usage(directory: &Path, since_ms: i64) -> Result<Value, String> {
    let mut totals = crate::work_transcript_identity::UsageTotals::default();
    if !directory.is_dir() {
        return Ok(totals.value());
    }
    let files = muse_usage_files(directory)?;
    let mut remaining = VENDOR_USAGE_BYTES;
    let mut seen = HashSet::new();
    for path in files {
        let bytes = read_fork_file(&path, remaining, false)?;
        remaining = remaining.saturating_sub(bytes.len() as u64);
        let parsed =
            tokenstat_core::sources::muse::parse_file(&path, &String::from_utf8_lossy(&bytes));
        for event in parsed.events {
            if event.ts.utc_ms < since_ms || !seen.insert(event.id) {
                continue;
            }
            let counters = event.counters;
            let record = json!({"event":Event::Usage { input: counters.input_fresh.unwrap_or(0),
                output: counters.output.unwrap_or(0), cache_read: counters.cache_read.unwrap_or(0),
                cache_write: counters.cache_write_5m.unwrap_or(0).saturating_add(counters.cache_write_1h.unwrap_or(0)), cost_usd: None }});
            totals.add(&crate::work_transcript_identity::UsageTotals::from_record(
                record.as_object().ok_or("invalid usage")?,
            )?)?;
        }
    }
    Ok(totals.value())
}

fn usage_totals(path: &Path) -> Result<Value, String> {
    use std::io::Read;
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A missing transcript is a new conversation, which genuinely has
            // no usage. But an ancestor that exists and is not a directory
            // means the transcript is unreachable rather than absent, and
            // that must error instead of reporting a zero that is not real.
            // The open error alone cannot tell them apart: Unix reports a
            // file used as a directory distinctly, Windows reports both
            // cases as not found.
            if blocked_ancestor(path) {
                return Err("conversation transcript is not reachable".into());
            }
            return Ok(crate::work_transcript_identity::UsageTotals::default().value());
        }
        Err(error) => return Err(error.to_string()),
    };
    let maximum = PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file() || metadata.len() > maximum {
        return Err("conversation transcript is not a bounded regular file".into());
    }
    let mut bytes = Vec::new();
    file.take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() as u64 > maximum {
        return Err("conversation transcript exceeds the usage reading limit".into());
    }
    let text = String::from_utf8_lossy(&bytes);
    let mut totals = crate::work_transcript_identity::UsageTotals::default();
    for line in text.lines() {
        if !line.contains("\"usage\"") {
            continue;
        }
        let Ok(Value::Object(record)) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        totals.add(&crate::work_transcript_identity::UsageTotals::from_record(
            &record,
        )?)?;
    }
    Ok(totals.value())
}

/// Whether `path` can never name a file because something above it exists
/// and is not a directory.
///
/// Follows links: a symlink to a directory is a way through, not a wall.
/// A dangling link reads as missing rather than blocked, which keeps a new
/// conversation's empty totals rather than erroring on a path that simply
/// is not there yet.
fn blocked_ancestor(path: &Path) -> bool {
    let mut current = path.parent();
    while let Some(ancestor) = current {
        match fs::metadata(ancestor) {
            Ok(metadata) if !metadata.is_dir() => return true,
            _ => {}
        }
        current = ancestor.parent();
    }
    false
}

struct ChatTemporary(PathBuf);
impl Drop for ChatTemporary {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn replace_chat_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let directory = path.parent().ok_or("invalid chat events path")?;
    let temporary =
        ChatTemporary(directory.join(format!(".chat-{:032x}.tmp", rand::random::<u128>())));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(&temporary.0).map_err(|e| e.to_string())?;
    file.write_all(bytes).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    fs::rename(&temporary.0, path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    fs::File::open(directory)
        .and_then(|dir| dir.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn file_len(path: &Path) -> u64 {
    fs::metadata(path).map(|meta| meta.len()).unwrap_or(0)
}

/// Read exactly `[start, end)`.
fn read_region(path: &Path, start: u64, end: u64) -> Option<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    if end <= start {
        return Some(Vec::new());
    }
    let mut file = fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut buffer = vec![0u8; (end - start) as usize];
    file.read_exact(&mut buffer).ok()?;
    Some(buffer)
}

fn retained_prefix(bytes: &[u8], base: u64) -> bool {
    if base != 0 {
        return false;
    }
    let Some(line) = bytes.split_inclusive(|byte| *byte == b'\n').next() else {
        return false;
    };
    let Ok(record) = serde_json::from_slice::<Value>(line) else {
        return false;
    };
    record
        .get("seq")
        .and_then(Value::as_u64)
        .is_some_and(|seq| seq > 0)
        || record.get("kind").and_then(Value::as_str) == Some("retainedUsage")
}

/// Parse whole records out of a region, stamping each with where it starts.
///
/// `seq` is a persisted logical position, or the original byte offset for a
/// legacy record. Retention materializes legacy positions before moving them,
/// so loading older pages and trimming history both preserve row identity.
/// A line that is not an object is skipped. The file is written one JSON
/// object per line, and anything else in it is damage.
fn records(bytes: &[u8], base: u64) -> Vec<Value> {
    records_with_positions(bytes, base, true)
}

fn records_with_positions(bytes: &[u8], base: u64, stable: bool) -> Vec<Value> {
    let mut out = Vec::new();
    let mut at = base;
    for line in bytes.split_inclusive(|byte| *byte == b'\n') {
        let start = at;
        at += line.len() as u64;
        let text = std::str::from_utf8(line).unwrap_or_default().trim_end();
        if text.is_empty() {
            continue;
        }
        let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(text) else {
            continue;
        };
        let Ok(seq) = crate::work_transcript_identity::sequence(&object, start) else {
            continue;
        };
        object.insert("seq".into(), json!(if stable { seq } else { start }));
        alias(&mut object);
        if let Some(Value::Object(event)) = object.get_mut("event") {
            alias(event);
        }
        out.push(Value::Object(object));
    }
    out
}

/// Names a client reads, written beside the ones the archive holds.
///
/// `Event` and `StoredEvent` are tagged enums carrying
/// `rename_all = "camelCase"`, which renames the *variants* and not their
/// fields. So the archive holds `at_ms`, `call_id`, `cache_read`,
/// `cache_write`, `cost_usd` and `exit_code`, while every client reads those
/// in camel case and has been getting nothing for them: a tool call never
/// matched its own end and drew twice, a tool had no start to measure a
/// duration from, and cache and cost were always zero.
///
/// Fixed on the way out rather than on the way in. Every archive already on
/// disk carries the old spelling, so a client would have to accept both
/// whatever the store did next, and this is the one place both the page and
/// the tail pass through.
const ALIASES: [(&str, &str); 6] = [
    ("at_ms", "atMs"),
    ("call_id", "callId"),
    ("cache_read", "cacheRead"),
    ("cache_write", "cacheWrite"),
    ("cost_usd", "costUsd"),
    ("exit_code", "exitCode"),
];

/// Added beside the original, never instead of it: the host's own readers,
/// the handover brief among them, come through here too.
fn alias(object: &mut serde_json::Map<String, Value>) {
    for (from, to) in ALIASES {
        if object.contains_key(to) {
            continue;
        }
        if let Some(value) = object.get(from).cloned() {
            object.insert(to.into(), value);
        }
    }
}

/// Walk backwards from `end` until `limit` whole records are in hand.
///
/// Answers where the page starts and the bytes from there to `end`. The walk
/// is bounded three ways: by the record count, by `PAGE_BYTES`, and by
/// `PAGE_RECORD_BYTES` for the pathological case of one enormous record. It
/// never reads the whole archive to hand back the end of it.
fn read_back(path: &Path, end: u64, limit: usize) -> Result<(u64, Vec<u8>), String> {
    read_back_checked(path, end, limit, false)
}

fn read_back_checked(
    path: &Path,
    end: u64,
    limit: usize,
    strict: bool,
) -> Result<(u64, Vec<u8>), String> {
    let mut start = end;
    let mut buffer: Vec<u8> = Vec::new();
    loop {
        if start == 0 {
            break;
        }
        let whole = alignment(&buffer, start)
            .map(|at| count_records(&buffer[at..]))
            .unwrap_or(0);
        if whole >= limit {
            break;
        }
        // The weight bound only applies once there is something to hand
        // back. A single record longer than a page has to be read to its
        // beginning or it could never be shown at all.
        if whole > 0 && buffer.len() as u64 >= PAGE_BYTES {
            break;
        }
        // One byte before a maximum-size row establishes its boundary when
        // the archive also contains a retained usage summary.
        if buffer.len() as u64 > PAGE_RECORD_BYTES {
            break;
        }
        let chunk = PAGE_CHUNK
            .min(start)
            .min(PAGE_RECORD_BYTES + 1 - buffer.len() as u64);
        start -= chunk;
        let region = read_region(path, start, start + chunk);
        if strict && region.is_none() {
            return Err("conversation changed or could not be read; retry search".into());
        }
        let mut head = region.unwrap_or_default();
        head.extend_from_slice(&buffer);
        buffer = head;
    }
    // Everything before the first newline belongs to a record that began
    // earlier, unless the walk reached the beginning of the file.
    let at = alignment(&buffer, start).unwrap_or(0);
    let text = &buffer[at..];
    if count_records(text) == 0 {
        // A window with nothing whole in it, which only a record past
        // `PAGE_RECORD_BYTES` can produce. Answer with where the window
        // begins so the walk still moves backwards: handing back the offset
        // it was given would ask the same question again forever.
        return Ok((start, Vec::new()));
    }
    // More records than were asked for, because reading happens in chunks.
    // Keep the newest `limit` of them.
    let mut starts = vec![0usize];
    for (index, byte) in text.iter().enumerate() {
        if *byte == b'\n' && index + 1 < text.len() {
            starts.push(index + 1);
        }
    }
    let first = starts.len().saturating_sub(limit);
    let cut = starts.get(first).copied().unwrap_or(0);
    Ok((start + at as u64 + cut as u64, text[cut..].to_vec()))
}

/// Where the first whole record in the buffer begins, if there is one.
fn alignment(buffer: &[u8], start: u64) -> Option<usize> {
    if start == 0 {
        return Some(0);
    }
    buffer
        .iter()
        .position(|byte| *byte == b'\n')
        .map(|at| at + 1)
}

fn count_records(bytes: &[u8]) -> usize {
    bytes
        .split_inclusive(|byte| *byte == b'\n')
        .filter(|line| !line.iter().all(|byte| byte.is_ascii_whitespace()))
        .count()
}

/// The first record identifies a retained generation even after the file
/// grows past its pre-trim size. New and compacted records start with their
/// unique sequence, so a bounded prefix suffices even for a large first row.
/// Legacy bytes stay unchanged until compaction writes that sequence prefix.
fn archive_generation(path: &Path) -> Result<u64, String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error.to_string()),
    };
    let mut first = Vec::new();
    BufReader::new(file.take(256))
        .read_until(b'\n', &mut first)
        .map_err(|e| e.to_string())?;
    if first.is_empty() {
        return Ok(0);
    }
    let digest = Sha256::digest(first);
    let mut generation = [0; 8];
    generation.copy_from_slice(&digest[..8]);
    Ok(u64::from_le_bytes(generation))
}

fn make_cursor(start: u64, len: u64, first: u64) -> String {
    format!("e2.{start:x}.{len:x}.{first:x}")
}

fn parse_cursor(raw: &str, len: u64, first: u64) -> Option<u64> {
    let mut parts = raw.split('.');
    if parts.next()? != "e2" {
        return None;
    }
    let start = u64::from_str_radix(parts.next()?, 16).ok()?;
    let issued = u64::from_str_radix(parts.next()?, 16).ok()?;
    let generation = u64::from_str_radix(parts.next()?, 16).ok()?;
    if parts.next().is_some() || len < issued || start > len || first != generation {
        return None;
    }
    Some(start)
}

fn next_send_revision(revision: u64) -> Result<u64, String> {
    revision
        .checked_add(1)
        .ok_or_else(|| "This conversation cannot accept another revision.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_reader_bounds_files_and_does_not_hide_read_errors() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("events.ndjson");
        assert_eq!(usage_totals(&path).unwrap()["turns"], 0);
        fs::write(&path, b"{\"event\":{\"kind\":\"usage\",\"input\":42}}\n").unwrap();
        assert_eq!(usage_totals(&path).unwrap()["input"], 42);
        let maximum = PAGE_RECORD_BYTES + crate::work_transcript_identity::SUMMARY_BYTES as u64;
        OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(maximum + 1)
            .unwrap();
        assert!(usage_totals(&path).is_err());
        assert_eq!(fs::metadata(&path).unwrap().len(), maximum + 1);
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(usage_totals(&path).is_err());
        let not_directory = root.path().join("file");
        fs::write(&not_directory, b"file").unwrap();
        assert!(usage_totals(&not_directory.join("events.ndjson")).is_err());
    }

    /// A throwaway archive of `count` records, each a little different in
    /// length and some of them multi-byte, so a page boundary that split a
    /// character or a record would show up as a missing or broken row.
    fn archive(name: &str, lines: &[String]) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "tokenstat-chat-page-{}-{}-{}.ndjson",
            name,
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let mut body = String::new();
        for line in lines {
            body.push_str(line);
            body.push('\n');
        }
        fs::write(&path, body).expect("write archive");
        path
    }

    fn lines(count: usize) -> Vec<String> {
        (0..count)
            .map(|n| {
                let padding = "é".repeat(n % 17);
                json!({"kind": "user", "atMs": n, "text": format!("{padding}{n}")}).to_string()
            })
            .collect()
    }

    fn page(path: &Path, end: u64, limit: usize) -> (u64, Vec<Value>) {
        let (start, bytes) = read_back(path, end, limit).expect("read");
        (start, records(&bytes, start))
    }

    #[test]
    fn a_page_is_the_newest_records_and_nothing_is_split() {
        let written = lines(500);
        let path = archive("newest", &written);
        let len = file_len(&path);
        let (start, events) = page(&path, len, 80);
        assert_eq!(events.len(), 80);
        assert_eq!(events[79]["atMs"], json!(499));
        assert_eq!(events[0]["atMs"], json!(420));
        assert_eq!(
            events[0]["seq"],
            json!(start),
            "the first record is stamped with where the page starts"
        );
        // Every record's text survived, accents and all.
        for (index, event) in events.iter().enumerate() {
            let n = 420 + index;
            let padding = "é".repeat(n % 17);
            assert_eq!(event["text"], json!(format!("{padding}{n}")));
        }
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn older_pages_walk_back_to_the_beginning_without_gaps_or_repeats() {
        let written = lines(437);
        let path = archive("walk", &written);
        let len = file_len(&path);
        let mut end = len;
        let mut seen: Vec<i64> = Vec::new();
        loop {
            let (start, events) = page(&path, end, 60);
            let mut ours: Vec<i64> = events
                .iter()
                .map(|event| event["atMs"].as_i64().expect("stamp"))
                .collect();
            ours.append(&mut seen);
            seen = ours;
            if start == 0 {
                break;
            }
            end = start;
        }
        assert_eq!(seen, (0..437).collect::<Vec<i64>>());
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_page_that_lands_exactly_on_a_boundary_repeats_nothing() {
        let written = lines(120);
        let path = archive("boundary", &written);
        let len = file_len(&path);
        let (start, first) = page(&path, len, 40);
        let (_, second) = page(&path, start, 40);
        assert_eq!(first.len(), 40);
        assert_eq!(second.len(), 40);
        assert_eq!(second[39]["atMs"], json!(79));
        assert_eq!(first[0]["atMs"], json!(80), "no record is in both pages");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn asking_for_more_than_there_is_gives_everything_once() {
        let path = archive("short", &lines(7));
        let len = file_len(&path);
        let (start, events) = page(&path, len, 300);
        assert_eq!(start, 0);
        assert_eq!(events.len(), 7);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn an_empty_or_missing_archive_is_an_empty_page() {
        let path = archive("empty", &[]);
        assert_eq!(page(&path, 0, 80), (0, vec![]));
        let _ = fs::remove_file(&path);
        assert_eq!(page(&path, 0, 80), (0, vec![]), "missing reads the same");
    }

    #[test]
    fn one_record_larger_than_a_page_still_arrives_whole_and_once() {
        let huge = json!({"kind": "user", "text": "x".repeat(400 * 1024)}).to_string();
        let mut written = lines(20);
        written.insert(10, huge);
        let path = archive("huge", &written);
        let len = file_len(&path);
        let mut end = len;
        let mut seen = 0usize;
        let mut long = 0usize;
        let mut pages = 0usize;
        loop {
            pages += 1;
            assert!(pages < 50, "the walk has to reach the beginning");
            let (start, events) = page(&path, end, 300);
            seen += events.len();
            long += events
                .iter()
                .filter(|event| event["text"].as_str().map(str::len) == Some(400 * 1024))
                .count();
            if start == 0 {
                break;
            }
            assert!(start < end, "every page moves backwards");
            end = start;
        }
        assert_eq!(seen, 21);
        assert_eq!(long, 1, "the long record arrives whole, exactly once");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_page_carries_the_full_opening_window_the_client_asks_for() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "opening-window");
        store.save().unwrap();
        for n in 0..1500 {
            store
                .append(
                    "opening-window",
                    &StoredEvent::User {
                        text: format!("hello {n}"),
                        at_ms: n as i64,
                    },
                )
                .unwrap();
        }
        let page = store.event_page("opening-window", None, 1500).unwrap();
        assert_eq!(page.events.len(), 1500);
        assert!(
            !page.has_earlier,
            "small records must not stop a page early"
        );
        assert_eq!(page.events[0]["text"], "hello 0");
        assert_eq!(page.events[1499]["text"], "hello 1499");
    }

    #[test]
    fn a_page_weighs_three_quarters_of_a_megabyte_before_it_stops() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "heavy-window");
        store.save().unwrap();
        for n in 0..70 {
            store
                .append(
                    "heavy-window",
                    &StoredEvent::User {
                        text: format!("{:04}:{}\n", n, "x".repeat(12 * 1024)),
                        at_ms: n as i64,
                    },
                )
                .unwrap();
        }
        let page = store
            .event_page("heavy-window", None, PAGE_EVENTS_MAX)
            .unwrap();
        assert!(page.has_earlier, "weight still bounds a page");
        assert!(page.start > 0);
        // The old quarter-megabyte bound could hold at most 26 of these
        // records. Carrying at least 50 proves the bound moved with the
        // tripled client pages, while stopping short of all 70 proves a
        // bound is still there.
        assert!(
            (50..70).contains(&page.events.len()),
            "expected most but not all of the heavy records, got {}",
            page.events.len()
        );
        let newest = page.events.last().unwrap()["text"].as_str().unwrap();
        assert!(
            newest.starts_with("0069:"),
            "the page holds the newest records"
        );
    }

    #[test]
    fn every_record_arrives_with_the_names_a_client_reads() {
        let written = vec![
            json!({"kind":"user","text":"Hi","at_ms":7}).to_string(),
            json!({"kind":"agent","at_ms":8,"backend":"claude","event":{
                "kind":"toolStart","call_id":"call-1","verb":"Read","target":"a"
            }})
            .to_string(),
            json!({"kind":"agent","at_ms":9,"backend":"claude","event":{
                "kind":"usage","input":10,"output":2,"cache_read":5,
                "cache_write":1,"cost_usd":0.25
            }})
            .to_string(),
            json!({"kind":"agent","at_ms":10,"backend":"claude","event":{
                "kind":"done","status":"ok","exit_code":0
            }})
            .to_string(),
        ];
        let path = archive("names", &written);
        let (_, events) = page(&path, file_len(&path), 300);
        assert_eq!(events[0]["atMs"], json!(7));
        assert_eq!(
            events[0]["at_ms"],
            json!(7),
            "the archive's own spelling stays, so nothing that read it breaks"
        );
        assert_eq!(events[1]["event"]["callId"], json!("call-1"));
        assert_eq!(events[2]["event"]["cacheRead"], json!(5));
        assert_eq!(events[2]["event"]["cacheWrite"], json!(1));
        assert_eq!(events[2]["event"]["costUsd"], json!(0.25));
        assert_eq!(events[3]["event"]["exitCode"], json!(0));
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_damaged_line_is_skipped_and_the_rest_still_reads() {
        let mut written = lines(6);
        written.insert(3, "{not json".into());
        written.insert(5, "\"a string, not a record\"".into());
        let path = archive("damaged", &written);
        let len = file_len(&path);
        let (_, events) = page(&path, len, 300);
        assert_eq!(events.len(), 6);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_cursor_survives_growth_and_not_a_trim() {
        let cursor = make_cursor(4_096, 10_000, 25);
        assert_eq!(parse_cursor(&cursor, 10_000, 25), Some(4_096));
        assert_eq!(parse_cursor(&cursor, 40_000, 25), Some(4_096));
        assert_eq!(parse_cursor(&cursor, 9_000, 25), None);
        assert_eq!(parse_cursor(&cursor, 40_000, 50), None, "trim then growth");
        assert_eq!(parse_cursor("e2.ffffffff.10.0", 16, 0), None);
        assert_eq!(parse_cursor("nonsense", 10_000, 0), None);
        assert_eq!(
            parse_cursor("e1.10.20", 10_000, 0),
            None,
            "legacy cursor resets safely"
        );
        assert_eq!(parse_cursor("e2.10.20.0.extra", 10_000, 0), None);
    }

    #[test]
    fn process_exit_is_the_only_turn_outcome() {
        assert_eq!(turn_status(Some(0), false), "ok");
        assert_eq!(turn_status(Some(1), false), "error");
        assert_eq!(turn_status(None, false), "error");
        assert_eq!(turn_status(Some(0), true), "stopped");
        assert_eq!(turn_status(Some(137), true), "stopped");
    }

    #[test]
    fn only_unprompted_chat_outcomes_notify() {
        assert_eq!(
            chat_notification("ok"),
            Some(tokenstat_sync::push::Reason::ChatFinished)
        );
        assert_eq!(
            chat_notification("error"),
            Some(tokenstat_sync::push::Reason::ChatFailed)
        );
        assert_eq!(chat_notification("stopped"), None);
        assert_eq!(chat_notification("cancelled"), None);
    }

    #[test]
    fn one_live_approval_suppresses_another_waiting_notification() {
        let approval = Approval {
            id: "approval-1".into(),
            conversation_id: "chat-a".into(),
            verb: "Shell".into(),
            preview: "Run tests".into(),
            shell_prefix: None,
            created_at_ms: 10,
            expires_at_ms: 100,
            decision: None,
        };
        assert!(has_live_approval(
            std::slice::from_ref(&approval),
            "chat-a",
            50
        ));
        assert!(!has_live_approval(
            std::slice::from_ref(&approval),
            "chat-b",
            50
        ));
        assert!(!has_live_approval(&[approval], "chat-a", 100));
    }

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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: true,
            branch: None,
        });
        store.save().unwrap();
        store.record_events(
            "chat-test",
            "muse",
            vec![Event::ToolStart {
                call_id: "orphan".into(),
                verb: "Bash".into(),
                target: "".into(),
                input: Value::Null,
            }],
        );
        store.stop("chat-test").unwrap();
        assert!(!store.list("workspace-a")[0].running);
        let rows = fs::read_to_string(store.events_path("chat-test")).unwrap();
        let last: StoredEvent = serde_json::from_str(rows.lines().last().unwrap()).unwrap();
        assert!(matches!(last, StoredEvent::Agent {
            event: Event::Done { ref status, .. }, ..
        } if status == "stopped"));
    }

    fn parked_note(store: &Store, id: &str) -> Option<String> {
        store.steers.lock().unwrap().get(id).cloned()
    }

    fn prepare_live_chat(store: &Store, id: &str) {
        conversation_for_receipts(store, id);
        store.set_running(id, true).unwrap();
    }

    #[test]
    fn a_new_chat_starts_in_execute_and_an_old_record_stays_plan() {
        // `create` reaches for this when the request names no mode.
        assert_eq!(default_new_chat_mode(), "execute");
        // A stored record that never had a mode still reads as plan, so no
        // existing conversation changes underneath anyone. Deserialized for
        // real, so the test follows the record's own default.
        let old: Result<Conversation, _> = serde_json::from_value(serde_json::json!({
            "id": "chat-old",
            "workspaceId": "workspace-old",
            "title": "Old",
            "backend": "claude",
            "createdAtMs": 1,
            "updatedAtMs": 1,
        }));
        match old {
            Ok(old) => assert_eq!(old.mode, "plan"),
            Err(error) => panic!("an old record no longer reads: {error}"),
        }
    }

    fn retune_chat(store: &Store, id: &str, backend: &str, autonomy: &str) {
        store
            .edit_conversation(id, |chat| {
                chat.backend = backend.into();
                chat.autonomy = autonomy.into();
                Ok(())
            })
            .unwrap();
    }

    fn ask(store: &Store, id: &str, question: &str) -> String {
        store.record_questions(
            id,
            "claude",
            crate::chat_question::Scanner::default().finish(&format!(
                "```{}\n{{\"question\":\"{question}\",\"options\":[\"A\",\"B\"],\"default\":\"A\"}}\n```",
                crate::chat_question::FENCE
            )),
        );
        let (events, _) = store.events(id, 0).unwrap();
        events
            .iter()
            .rev()
            .find(|event| event["kind"] == "question")
            .and_then(|event| event["id"].as_str())
            .unwrap()
            .to_string()
    }

    #[test]
    fn an_answer_to_a_running_turn_rides_its_next_step_once() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        retune_chat(&store, "chat-test", "claude", "standard");
        let question = ask(&store, "chat-test", "Which database?");
        let (events, _) = store.events("chat-test", 0).unwrap();
        let recorded = events
            .iter()
            .find(|event| event["kind"] == "question")
            .unwrap();
        assert_eq!(recorded["options"], json!(["A", "B"]));
        assert_eq!(recorded["default"], "A");
        assert_eq!(recorded["blocking"], false);

        store.steer("chat-test", "also check the tests").unwrap();
        let answer = store
            .answer_question("chat-test", &question, "  B  ")
            .unwrap();
        assert_eq!(answer["delivery"], "note");
        let parked = parked_note(&store, "chat-test").unwrap();
        assert!(
            parked.starts_with("also check the tests\n\n"),
            "a parked note stays: {parked}"
        );
        assert!(parked.ends_with("Answer to your question \"Which database?\": B"));
        let (events, _) = store.events("chat-test", 0).unwrap();
        let recorded = events
            .iter()
            .find(|event| event["kind"] == "answer")
            .unwrap();
        assert_eq!(recorded["questionId"], question.as_str());
        assert_eq!(recorded["text"], "B");

        let again = store
            .answer_question("chat-test", &question, "A")
            .unwrap_err();
        assert!(again.to_string().contains("already has an answer"));
    }

    #[test]
    fn an_answer_to_a_turn_that_cannot_take_notes_waits_for_it_to_end() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        retune_chat(&store, "chat-test", "claude", "bypass");
        let question = ask(&store, "chat-test", "Ship it?");
        let answer = store
            .answer_question("chat-test", &question, "yes")
            .unwrap();
        assert_eq!(answer["delivery"], "queued");
        assert!(parked_note(&store, "chat-test").unwrap().contains("yes"));
    }

    fn withdrawn(store: &Store, id: &str, question: &str) -> usize {
        let (events, _) = store.events(id, 0).unwrap();
        events
            .iter()
            .filter(|event| event["kind"] == "answerWithdrawn" && event["questionId"] == question)
            .count()
    }

    #[test]
    fn a_dropped_answer_reopens_its_question() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        retune_chat(&store, "chat-test", "claude", "standard");
        let question = ask(&store, "chat-test", "Which database?");
        store.answer_question("chat-test", &question, "B").unwrap();
        assert_eq!(withdrawn(&store, "chat-test", &question), 0);

        // Clearing the note, like Stop, takes the answer with it.
        store.steer_clear("chat-test").unwrap();
        assert_eq!(withdrawn(&store, "chat-test", &question), 1);
        let again = store.answer_question("chat-test", &question, "A").unwrap();
        assert_eq!(again["delivery"], "note", "the question is open again");
    }

    #[test]
    fn a_new_note_keeps_a_parked_answer_and_the_agent_takes_both() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        retune_chat(&store, "chat-test", "claude", "standard");
        let question = ask(&store, "chat-test", "Which database?");
        store.answer_question("chat-test", &question, "B").unwrap();
        store.steer("chat-test", "also check the tests").unwrap();
        let parked = parked_note(&store, "chat-test").unwrap();
        assert!(parked.starts_with("also check the tests\n\n"), "{parked}");
        assert!(parked.ends_with("Answer to your question \"Which database?\": B"));

        let token = store.register_turn_token("chat-test", "claude").unwrap();
        assert_eq!(store.take_steer_for_token(&token).unwrap(), Some(parked));
        // Delivered: nothing is left to withdraw, whatever happens next.
        store.steer_clear("chat-test").unwrap();
        assert_eq!(withdrawn(&store, "chat-test", &question), 0);
    }

    #[test]
    fn answers_left_parked_by_an_ended_process_are_reopened_once() {
        let root = tempfile::tempdir().unwrap();
        let reader = Store::at(root.path().join("chat"));
        conversation_for_receipts(&reader, "chat-test");
        let owner = Store::at(root.path().join("chat"));
        owner.park_answer("chat-test", "question-1", "note".into());

        // The owner still holds its lease, so its answers may yet arrive.
        reader.withdraw_orphaned_answers();
        assert_eq!(withdrawn(&reader, "chat-test", "question-1"), 0);

        drop(owner);
        reader.withdraw_orphaned_answers();
        assert_eq!(withdrawn(&reader, "chat-test", "question-1"), 1);
        reader.withdraw_orphaned_answers();
        assert_eq!(
            withdrawn(&reader, "chat-test", "question-1"),
            1,
            "only once"
        );
    }

    #[test]
    fn a_failed_withdrawal_survives_until_the_transcript_can_be_written() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        let question = ask(&store, "chat-test", "Which database?");
        store.answer_question("chat-test", &question, "B").unwrap();
        let path = store.events_path("chat-test");
        let saved = path.with_extension("saved");
        fs::rename(&path, &saved).unwrap();
        fs::create_dir(&path).unwrap();

        store.steer_clear("chat-test").unwrap();
        assert!(parked_note(&store, "chat-test").is_none());
        fs::remove_dir(&path).unwrap();
        fs::rename(&saved, &path).unwrap();
        store.steer_clear("chat-test").unwrap();
        assert_eq!(withdrawn(&store, "chat-test", &question), 1);
        assert!(store.open_question("chat-test", &question).is_ok());
    }

    #[test]
    fn orphan_recovery_keeps_the_questions_it_could_not_reopen() {
        let root = tempfile::tempdir().unwrap();
        let reader = Store::at(root.path().join("chat"));
        conversation_for_receipts(&reader, "chat-test");
        conversation_for_receipts(&reader, "ready-chat");
        let owner = Store::at(root.path().join("chat"));
        owner.park_answer("chat-test", "question-1", "note".into());
        owner.park_answer("ready-chat", "question-2", "another note".into());
        drop(owner);
        let path = reader.events_path("chat-test");
        fs::create_dir_all(&path).unwrap();
        reader.withdraw_orphaned_answers();
        assert_eq!(withdrawn(&reader, "ready-chat", "question-2"), 1);
        fs::remove_dir(&path).unwrap();
        reader.withdraw_orphaned_answers();
        assert_eq!(withdrawn(&reader, "chat-test", "question-1"), 1);
        assert_eq!(
            withdrawn(&reader, "ready-chat", "question-2"),
            1,
            "a partially recovered journal cannot repeat successful withdrawals"
        );
        reader.withdraw_orphaned_answers();
        assert_eq!(withdrawn(&reader, "chat-test", "question-1"), 1);
    }

    #[test]
    fn steer_delivery_finalizes_answers_before_releasing_acceptance() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        conversation_for_receipts(&store, "chat-test");
        store
            .steers
            .lock()
            .unwrap()
            .insert("chat-test".into(), "note".into());
        store
            .suppress_follow_up
            .lock()
            .unwrap()
            .insert("chat-test".into());
        // Pause finalization after the send has consumed Stop's marker.
        let parked = store.parked_answers.lock().unwrap();
        let delivering = Arc::clone(&store);
        let delivery = std::thread::spawn(move || delivering.steer_deliver("chat-test"));
        let deadline = Instant::now() + Duration::from_secs(5);
        while store
            .suppress_follow_up
            .lock()
            .unwrap()
            .contains("chat-test")
        {
            assert!(
                Instant::now() < deadline,
                "the send did not reach finalization"
            );
            std::thread::yield_now();
        }
        let root = store.root.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let next = std::thread::spawn(move || {
            let _acceptance =
                crate::chat_receipts::Operation::conversation(&root, "chat-test").unwrap();
            tx.send(()).unwrap();
        });
        let held = rx.recv_timeout(Duration::from_millis(100)).is_err();
        drop(parked);
        assert_eq!(delivery.join().unwrap().unwrap()["delivered"], false);
        rx.recv_timeout(Duration::from_secs(5)).unwrap();
        next.join().unwrap();
        assert!(
            held,
            "another answer was accepted before delivery bookkeeping finished"
        );
    }

    #[test]
    fn a_question_beside_a_tool_call_is_still_found() {
        let fence = crate::chat_question::FENCE;
        let tool = || Event::ToolStart {
            call_id: "t1".into(),
            verb: "Read".into(),
            target: "schema.sql".into(),
            input: Value::Null,
        };
        let text = |delta: &str| Event::Text {
            delta: delta.into(),
        };
        let mut reply = String::new();
        let mut scanner = crate::chat_question::Scanner::default();
        let mut found = Vec::new();
        for batch in [
            vec![text("Checking the schema.")],
            vec![tool()],
            vec![text(&format!(
                "```{fence}\n{{\"question\":\"Which database?\",\"default\":\"SQLite\"}}\n```"
            ))],
            vec![tool()],
            vec![text("Going with SQLite.")],
        ] {
            scanner.shift(collect_agent_text(&batch, &mut reply));
            found.extend(scanner.scan(&reply));
        }
        found.extend(scanner.finish(&reply));
        assert_eq!(found.len(), 1, "{reply:?}");
        assert_eq!(found[0].question, "Which database?");

        // Clients draw a usage report as its own row, so a block right after
        // one opens its own line here too.
        let mut reply = String::new();
        let usage = Event::Usage {
            input: 1,
            output: 1,
            cache_read: 0,
            cache_write: 0,
            cost_usd: None,
        };
        collect_agent_text(
            &[
                text("Step one done."),
                usage,
                text(&format!("```{fence}\n{{\"question\":\"Next?\"}}\n```\n")),
            ],
            &mut reply,
        );
        assert_eq!(
            crate::chat_question::Scanner::default().scan(&reply).len(),
            1
        );
    }

    #[test]
    fn an_answer_needs_words_and_a_question_that_is_still_there() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        let question = ask(&store, "chat-test", "Name?");
        assert!(
            store
                .answer_question("chat-test", &question, "   ")
                .is_err()
        );
        let long = "x".repeat(crate::chat_question::ANSWER_MAX_CHARS + 1);
        assert!(
            store
                .answer_question("chat-test", &question, &long)
                .is_err()
        );
        let missing = store
            .answer_question("chat-test", "question-gone", "hi")
            .unwrap_err();
        assert!(
            missing
                .to_string()
                .contains("no longer in this conversation")
        );
        assert!(
            parked_note(&store, "chat-test").is_none(),
            "a refused answer parks nothing"
        );
    }

    #[test]
    fn simultaneous_answers_accept_only_one_note() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        retune_chat(&store, "chat-test", "claude", "standard");
        let question = ask(&store, "chat-test", "Pick one?");
        let barrier = std::sync::Barrier::new(2);
        let results = std::thread::scope(|scope| {
            let first = scope.spawn(|| {
                barrier.wait();
                store.answer_question("chat-test", &question, "A")
            });
            let second = scope.spawn(|| {
                barrier.wait();
                store.answer_question("chat-test", &question, "B")
            });
            [first.join().unwrap(), second.join().unwrap()]
        });
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        let (events, _) = store.events("chat-test", 0).unwrap();
        assert_eq!(
            events
                .iter()
                .filter(|event| event["kind"] == "answer")
                .count(),
            1
        );
    }

    #[test]
    fn an_idle_answer_that_cannot_launch_leaves_the_question_open() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        let question = ask(&store, "chat-test", "Pick one?");
        store.set_running("chat-test", false).unwrap();
        // The fixture's workspace does not exist, so no CLI is started.
        assert!(store.answer_question("chat-test", &question, "B").is_err());
        assert_eq!(
            store.open_question("chat-test", &question).unwrap(),
            "Pick one?"
        );
    }

    #[test]
    fn a_confirmed_question_answer_replays_its_receipt_before_parking_on_a_live_turn() {
        for running in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let store = Arc::new(Store::at(root.path().join("chat")));
            prepare_live_chat(&store, "chat-test");
            let question = ask(&store, "chat-test", "Pick one?");
            store.set_running("chat-test", running).unwrap();
            let key = crate::chat_receipts::question_key(&question);
            store
                .write_receipt(
                    "chat-test",
                    &key,
                    crate::chat_receipts::Receipt {
                        state: crate::chat_receipts::ReceiptState::Accepted,
                        digest: crate::chat_receipts::digest(
                            &crate::chat_question::answer_note("Pick one?", "B"),
                            &[],
                        ),
                        at_ms: now_ms() - crate::chat_receipts::RETENTION_MS * 2,
                        event_at_ms: Some(1),
                    },
                )
                .unwrap();
            // The fixture has no workspace, so attempting a new launch would
            // fail. Only a replay of the question's acceptance can succeed.
            let delivery = store.answer_question("chat-test", &question, "B").unwrap();
            assert_eq!(delivery["delivery"], "sent");
            assert!(parked_note(&store, "chat-test").is_none());
            let (events, _) = store.events("chat-test", 0).unwrap();
            assert_eq!(
                events.iter().filter(|row| row["kind"] == "answer").count(),
                1
            );
            assert!(!events.iter().any(|row| row["kind"] == "user"));
            assert!(store.open_question("chat-test", &question).is_err());
            assert!(
                crate::chat_receipts::Ledger::load(store.receipts_path("chat-test"), now_ms())
                    .unwrap()
                    .get(&key)
                    .is_none(),
                "a durable answer retires its receipt"
            );
        }
    }

    #[test]
    fn a_confirmed_question_answer_records_what_reached_the_agent_whatever_is_typed_now() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        prepare_live_chat(&store, "chat-test");
        let question = ask(&store, "chat-test", "Pick one?");
        store.set_running("chat-test", false).unwrap();
        // The launch's message is on the timeline, its answer row is not.
        let note = crate::chat_question::answer_note("Pick one?", "B");
        let user_at = now_ms();
        store
            .append(
                "chat-test",
                &StoredEvent::User {
                    text: note.clone(),
                    at_ms: user_at,
                },
            )
            .unwrap();
        let key = crate::chat_receipts::question_key(&question);
        store
            .write_receipt(
                "chat-test",
                &key,
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Accepted,
                    digest: crate::chat_receipts::digest(&note, &[]),
                    at_ms: user_at,
                    event_at_ms: Some(user_at),
                },
            )
            .unwrap();
        let delivery = store.answer_question("chat-test", &question, "A").unwrap();
        assert_eq!(delivery["delivery"], "sent");
        let (events, _) = store.events("chat-test", 0).unwrap();
        let answers: Vec<_> = events
            .iter()
            .filter(|row| row["kind"] == "answer")
            .collect();
        assert_eq!(answers.len(), 1);
        assert_eq!(answers[0]["text"], "B");
        assert!(store.open_question("chat-test", &question).is_err());
    }

    #[test]
    fn an_uncertain_question_answer_cannot_launch_or_park_a_duplicate() {
        for running in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let store = Arc::new(Store::at(root.path().join("chat")));
            prepare_live_chat(&store, "chat-test");
            let question = ask(&store, "chat-test", "Pick one?");
            store.set_running("chat-test", running).unwrap();
            let key = crate::chat_receipts::question_key(&question);
            store
                .write_receipt(
                    "chat-test",
                    &key,
                    crate::chat_receipts::Receipt {
                        state: crate::chat_receipts::ReceiptState::Pending,
                        digest: crate::chat_receipts::digest(
                            &crate::chat_question::answer_note("Pick one?", "B"),
                            &[],
                        ),
                        at_ms: now_ms(),
                        event_at_ms: None,
                    },
                )
                .unwrap();
            let error = store
                .answer_question("chat-test", &question, "B")
                .unwrap_err();
            assert_eq!(error.code, crate::error::DELIVERY_UNKNOWN);
            assert!(store.answer_question("chat-test", &question, "A").is_err());
            assert!(parked_note(&store, "chat-test").is_none());
            let (events, _) = store.events("chat-test", 0).unwrap();
            assert!(
                !events
                    .iter()
                    .any(|row| row["kind"] == "answer" || row["kind"] == "user")
            );
            assert_eq!(
                crate::chat_receipts::Ledger::load(store.receipts_path("chat-test"), now_ms())
                    .unwrap()
                    .get(&key)
                    .unwrap()
                    .state,
                crate::chat_receipts::ReceiptState::Pending
            );
        }
    }

    #[test]
    fn steer_parks_one_note_and_a_later_note_replaces_it() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "  look left  ").unwrap();
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("look left")
        );
        store.steer("chat-test", "look right").unwrap();
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("look right")
        );

        store.set_running("chat-test", false).unwrap();
        store
            .active
            .lock()
            .unwrap()
            .insert("chat-test".into(), "not-a-session".into());
        store.steer("chat-test", "still live").unwrap();
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("still live")
        );
    }

    #[test]
    fn steer_refuses_an_idle_turn_the_wrong_agent_and_a_note_that_cannot_ride() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "chat-test");
        let idle = store.steer("chat-test", "hello").unwrap_err();
        assert!(idle.contains("not in the middle of a turn"), "{idle}");

        prepare_live_chat(&store, "other");
        retune_chat(&store, "other", "grok", "standard");
        let backend = store.steer("other", "hello").unwrap_err();
        assert!(backend.contains("cannot take a note mid-turn"), "{backend}");

        retune_chat(&store, "other", "claude", "bypass");
        let autonomy = store.steer("other", "hello").unwrap_err();
        assert!(autonomy.contains("not asking before tools"), "{autonomy}");

        retune_chat(&store, "other", "codex", "standard");
        let empty = store.steer("other", "   ").unwrap_err();
        assert!(empty.contains("Write the note"), "{empty}");
        let long = "n".repeat(STEER_NOTE_MAX_CHARS + 1);
        let too_long = store.steer("other", &long).unwrap_err();
        assert!(too_long.contains("too long"), "{too_long}");
        let edge = "n".repeat(STEER_NOTE_MAX_CHARS);
        store.steer("other", &edge).unwrap();
        assert_eq!(
            parked_note(&store, "other").unwrap().chars().count(),
            STEER_NOTE_MAX_CHARS
        );
    }

    #[test]
    fn steer_stop_drops_a_parked_note_and_a_missing_chat_does_not() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "hold this").unwrap();
        store.stop("chat-test").unwrap();
        assert!(parked_note(&store, "chat-test").is_none());
        assert!(store.follow_up_should_skip("chat-test", true));
        assert!(!store.follow_up_should_skip("chat-test", true));

        prepare_live_chat(&store, "kept");
        store.steer("kept", "stay").unwrap();
        assert!(store.stop("missing").is_err());
        assert_eq!(parked_note(&store, "kept").as_deref(), Some("stay"));
        assert!(!store.suppress_follow_up.lock().unwrap().contains("kept"));
    }

    #[test]
    fn steer_tool_result_takes_the_note_once_and_only_for_claude_codex_or_muse() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "use the left door").unwrap();
        let claude = store.register_turn_token("chat-test", "claude").unwrap();
        assert_eq!(
            store.take_steer_for_token(&claude).unwrap().as_deref(),
            Some("use the left door")
        );
        assert!(store.take_steer_for_token(&claude).unwrap().is_none());

        store.steer("chat-test", "stay").unwrap();
        let grok = store.register_turn_token("chat-test", "grok").unwrap();
        assert!(store.take_steer_for_token(&grok).unwrap().is_none());
        assert_eq!(parked_note(&store, "chat-test").as_deref(), Some("stay"));
        let codex = store.register_turn_token("chat-test", "codex").unwrap();
        assert_eq!(
            store.take_steer_for_token(&codex).unwrap().as_deref(),
            Some("stay")
        );

        let invalid = store.take_steer_for_token("no-such-token").unwrap_err();
        assert!(invalid.contains("invalid or expired"), "{invalid}");

        store.steer("chat-test", "pear").unwrap();
        let muse = store.register_turn_token("chat-test", "muse").unwrap();
        if cfg!(unix) {
            assert_eq!(
                store.take_steer_for_token(&muse).unwrap().as_deref(),
                Some("pear")
            );
        } else {
            assert!(store.take_steer_for_token(&muse).unwrap().is_none());
            store.steers.lock().unwrap().remove("chat-test");
        }
        assert!(store.take_steer_for_token(&muse).unwrap().is_none());
        let events = store.events_path("chat-test");
        if events.exists() {
            let body = fs::read_to_string(&events).unwrap();
            assert!(!body.contains("toolEnd"), "{body}");
        }
        store.steer("chat-test", "stay put").unwrap();
        let opencode = store.register_turn_token("chat-test", "opencode").unwrap();
        assert!(store.take_steer_for_token(&opencode).unwrap().is_none());
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("stay put")
        );
    }

    #[test]
    fn steer_consumption_persists_one_user_message_for_each_supported_backend() {
        for backend in ["claude", "codex", "muse"] {
            if !note_backend(backend) {
                continue;
            }
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("chat");
            let store = Store::at(path.clone());
            prepare_live_chat(&store, "chat-test");
            retune_chat(&store, "chat-test", backend, "standard");
            let rich = "## Result\n\n**Kept** `code`\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet value = 1\n```";
            store.record_events(
                "chat-test",
                backend,
                vec![Event::Text { delta: rich.into() }],
            );
            let (_, before) = store.events("chat-test", 0).unwrap();
            store.steer("chat-test", "replaced").unwrap();
            store.steer("chat-test", "cancelled").unwrap();
            store.steer_clear("chat-test").unwrap();
            store
                .steer("chat-test", "  Keep the table and code.  ")
                .unwrap();
            let token = store.register_turn_token("chat-test", backend).unwrap();
            assert_eq!(
                store.take_steer_for_token(&token).unwrap().as_deref(),
                Some("Keep the table and code.")
            );
            assert!(store.take_steer_for_token(&token).unwrap().is_none());
            assert!(parked_note(&store, "chat-test").is_none());
            let (live, _) = store.events("chat-test", before).unwrap();
            assert_eq!(live.len(), 1, "{backend}: {live:?}");
            assert_eq!(live[0]["kind"], "user");
            assert_eq!(live[0]["text"], "Keep the table and code.");
            assert_eq!(
                store
                    .get("chat-test")
                    .unwrap()
                    .last_message_author
                    .as_deref(),
                Some("user")
            );
            store.set_running("chat-test", false).unwrap();
            let reopened = Store::load_at(path);
            let (history, _) = reopened.events("chat-test", 0).unwrap();
            assert_eq!(history.len(), 2, "{backend}: {history:?}");
            assert_eq!(history[0]["event"]["delta"], rich);
            assert_eq!(history[1], live[0]);
        }
    }

    #[test]
    fn codex_missing_session_rebuilds_context_without_forgetting_other_backends() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        retune_chat(&store, "chat-test", "codex", "standard");
        store
            .set_resume("chat-test", "claude", "claude-session")
            .unwrap();
        store
            .set_resume("chat-test", "codex", "codex-session")
            .unwrap();
        store
            .mark_standing_sent("chat-test", "codex", "rules")
            .unwrap();
        store
            .append(
                "chat-test",
                &StoredEvent::User {
                    text: "Previous question".into(),
                    at_ms: now_ms(),
                },
            )
            .unwrap();
        store.record_events(
            "chat-test",
            "codex",
            vec![Event::Text {
                delta: "Previous answer".into(),
            }],
        );
        let original = store.get("chat-test").unwrap();
        let mut missing = original.clone();
        store.recover_codex_session(&mut missing);
        assert!(!missing.resume_tokens.contains_key("codex"));
        assert!(missing.resume_token.is_none());
        assert!(!missing.standing_sent.contains_key("codex"));
        assert_eq!(
            missing.resume_tokens.get("claude").map(String::as_str),
            Some("claude-session")
        );
        let handover = store.handover(&missing).unwrap().unwrap();
        assert!(handover.brief.contains("Previous answer"));
        assert!(!handover.announce);
        assert_eq!(
            store.get("chat-test").unwrap().resume_token,
            original.resume_token
        );
        fs::create_dir_all(store.codex_home("chat-test").join("sessions")).unwrap();
        let mut retained = original.clone();
        store.recover_codex_session(&mut retained);
        assert_eq!(retained.resume_tokens, original.resume_tokens);
        assert_eq!(retained.standing_sent, original.standing_sent);
        assert!(store.handover(&retained).unwrap().is_none());
        let mut other = original;
        other.backend = "claude".into();
        store.recover_codex_session(&mut other);
        assert!(other.resume_tokens.contains_key("claude"));
    }

    #[test]
    #[cfg(not(unix))]
    fn codex_bypass_keeps_the_signed_in_default_home_and_its_resume_token() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "chat-test");
        retune_chat(&store, "chat-test", "codex", "bypass");
        store
            .set_resume("chat-test", "codex", "codex-session")
            .unwrap();
        let mut chat = store.get("chat-test").unwrap();
        assert!(!private_codex_home(false));
        store.recover_codex_session(&mut chat);
        assert_eq!(chat.resume_tokens["codex"], "codex-session");
        assert_eq!(chat.resume_token.as_deref(), Some("codex-session"));
    }

    #[test]
    fn steer_consumption_keeps_the_note_when_the_transcript_cannot_be_written() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "Keep this note.").unwrap();
        let token = store.register_turn_token("chat-test", "codex").unwrap();
        let path = store.events_path("chat-test");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(store.take_steer_for_token(&token).is_err());
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("Keep this note.")
        );
        fs::remove_dir(&path).unwrap();
        assert_eq!(
            store.take_steer_for_token(&token).unwrap().as_deref(),
            Some("Keep this note.")
        );
        assert!(store.take_steer_for_token(&token).unwrap().is_none());
        let (history, _) = store.events("chat-test", 0).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0]["text"], "Keep this note.");
    }

    #[test]
    #[cfg(unix)]
    fn steer_lets_muse_park_on_any_autonomy_and_refuses_opencode() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");

        retune_chat(&store, "chat-test", "muse", "bypass");
        store.steer("chat-test", "pear").unwrap();
        assert_eq!(parked_note(&store, "chat-test").as_deref(), Some("pear"));

        retune_chat(&store, "chat-test", "muse", "plan");
        store.steer("chat-test", "plan note").unwrap();
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("plan note")
        );

        retune_chat(&store, "chat-test", "muse", "standard");
        store.steer("chat-test", "ask first").unwrap();
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("ask first")
        );

        retune_chat(&store, "chat-test", "opencode", "standard");
        let opencode = store.steer("chat-test", "nope").unwrap_err();
        assert!(
            opencode.contains("cannot take a note mid-turn"),
            "{opencode}"
        );
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("ask first")
        );

        retune_chat(&store, "chat-test", "grok", "standard");
        let grok = store.steer("chat-test", "nope").unwrap_err();
        assert!(grok.contains("cannot take a note mid-turn"), "{grok}");
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("ask first")
        );

        retune_chat(&store, "chat-test", "claude", "bypass");
        let claude = store.steer("chat-test", "nope").unwrap_err();
        assert!(claude.contains("not asking before tools"), "{claude}");
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("ask first")
        );
    }

    #[test]
    fn steer_idle_claim_takes_the_note_and_a_live_turn_keeps_it() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "after this").unwrap();
        let live = store.claim_idle_steer("chat-test").unwrap_err();
        assert!(live.contains("still in the middle of a turn"), "{live}");
        assert_eq!(
            parked_note(&store, "chat-test").as_deref(),
            Some("after this")
        );

        store.set_running("chat-test", false).unwrap();
        assert_eq!(
            store.claim_idle_steer("chat-test").unwrap().as_deref(),
            Some("after this")
        );
        assert!(store.claim_idle_steer("chat-test").unwrap().is_none());
    }

    #[test]
    fn steer_delivery_does_not_retry_an_uncertain_send_that_already_finished() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "Send once.").unwrap();
        store.set_running("chat-test", false).unwrap();
        let note = store.claim_idle_steer("chat-test").unwrap().unwrap();
        // A spawned turn may have drained before its failed transcript or
        // receipt write returns to steerDeliver. It is already idle here.
        store.restore_steer_if_idle(
            "chat-test",
            &note,
            &DispatchError::delivery_unknown("acknowledgement failed"),
        );
        assert!(store.claim_idle_steer("chat-test").unwrap().is_none());
        store.restore_steer_if_idle("chat-test", &note, &"spawn failed".into());
        assert_eq!(
            store.claim_idle_steer("chat-test").unwrap().as_deref(),
            Some("Send once.")
        );
    }

    #[test]
    fn steer_follow_up_skips_when_stop_retired_the_note_or_a_newer_one_arrived() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.retire_steer("chat-test");
        assert!(store.follow_up_should_skip("chat-test", true));
        assert!(!store.follow_up_should_skip("chat-test", true));

        store.retire_steer("chat-test");
        assert!(!store.follow_up_should_skip("chat-test", false));
        assert!(!store.follow_up_should_skip("chat-test", true));

        store.retire_steer("chat-test");
        store.steer("chat-test", "newer").unwrap();
        assert!(store.follow_up_should_skip("chat-test", true));
        assert_eq!(parked_note(&store, "chat-test").as_deref(), Some("newer"));
        store.steers.lock().unwrap().remove("chat-test");
        assert!(!store.follow_up_should_skip("chat-test", true));
    }

    #[test]
    fn steer_clear_retires_it() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "drop me").unwrap();
        store.steer_clear("chat-test").unwrap();
        assert!(parked_note(&store, "chat-test").is_none());
        assert!(
            store
                .suppress_follow_up
                .lock()
                .unwrap()
                .contains("chat-test")
        );
    }

    #[test]
    fn steer_list_shows_a_parked_note_without_writing_it_into_the_conversation() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        prepare_live_chat(&store, "chat-test");
        store.steer("chat-test", "on the next step").unwrap();
        let mut value = serde_json::to_value(store.list("workspace-a")).unwrap();
        store.attach_pending_steers(&mut value);
        assert_eq!(value[0]["pendingSteer"], "on the next step");
        let disk = fs::read_to_string(store.root.join("conversations.json")).unwrap();
        assert!(!disk.contains("pendingSteer"));
        assert!(!disk.contains("on the next step"));
    }

    #[test]
    #[ignore = "isolated runner ownership helper invoked by parent"]
    fn runner_lease_process() {
        use std::io::Read;
        let root = PathBuf::from(std::env::var_os("TOKENSTAT_RUNNER_TEST_ROOT").unwrap());
        let _runner = crate::chat_receipts::RunnerLease::try_acquire(&root, "owned-turn")
            .unwrap()
            .unwrap();
        fs::write(root.join("runner-ready"), b"ready").unwrap();
        let mut release = [0];
        std::io::stdin().read_exact(&mut release).unwrap();
        // No Rust destructors: the kernel must release ownership after a crash.
        std::process::exit(23);
    }

    #[test]
    fn another_process_cannot_recover_stop_or_remove_a_live_runner() {
        use std::io::Write;
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "owned-turn");
        store.set_running("owned-turn", true).unwrap();
        store
            .write_receipt(
                "owned-turn",
                &crate::chat_receipts::key(None, "pending"),
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Pending,
                    digest: crate::chat_receipts::digest("words", &[]),
                    at_ms: now_ms(),
                    event_at_ms: None,
                },
            )
            .unwrap();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "chat::tests::runner_lease_process", "--ignored"])
            .env("TOKENSTAT_RUNNER_TEST_ROOT", &store.root)
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !store.root.join("runner-ready").exists() {
            assert!(child.try_wait().unwrap().is_none());
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let foreign = Arc::new(Store::load_at(store.root.clone()));
        assert!(foreign.get("owned-turn").unwrap().running);
        assert_eq!(
            foreign
                .receipt("owned-turn", "pending")
                .unwrap()
                .unwrap()
                .state,
            crate::chat_receipts::ReceiptState::Pending
        );
        assert!(foreign.stop("owned-turn").is_err());
        assert!(foreign.remove("owned-turn").is_err());
        assert!(foreign.remove_all("workspace-a").is_err());
        assert!(!store.events_path("owned-turn").exists());
        // Even a failed running-bit write cannot make the live lease disappear.
        store.set_running("owned-turn", false).unwrap();
        let error = foreign
            .send(
                "owned-turn",
                "new words",
                &[],
                Some("new-send"),
                Some(now_ms()),
                Some(0),
            )
            .unwrap_err();
        assert!(error.message.contains("another instance of tokenstat"));
        store.set_running("owned-turn", true).unwrap();
        child.stdin.take().unwrap().write_all(b"x").unwrap();
        assert_eq!(child.wait().unwrap().code(), Some(23));
        let recovered = Store::load_at(store.root.clone());
        assert!(!recovered.get("owned-turn").unwrap().running);
        assert_eq!(
            recovered
                .receipt("owned-turn", "pending")
                .unwrap()
                .unwrap()
                .state,
            crate::chat_receipts::ReceiptState::NeedsRecovery
        );
        let rows = fs::read_to_string(recovered.events_path("owned-turn")).unwrap();
        assert!(rows.contains("interrupted"));
    }

    #[test]
    fn restarting_settles_a_turn_without_a_process() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chat");
        let store = Store::at(path.clone());
        conversation_for_receipts(&store, "interrupted");
        store.set_running("interrupted", true).unwrap();
        let recovered = Store::load_at(path.clone());
        assert!(!recovered.get("interrupted").unwrap().running);
        let rows = fs::read_to_string(recovered.events_path("interrupted")).unwrap();
        let last: StoredEvent = serde_json::from_str(rows.lines().last().unwrap()).unwrap();
        assert!(matches!(last, StoredEvent::Agent {
            event: Event::Done { ref status, .. }, ..
        } if status == "interrupted"));
        // Recovery persists once; a second restart adds no duplicate ending.
        let again = Store::load_at(path);
        assert_eq!(
            rows,
            fs::read_to_string(again.events_path("interrupted")).unwrap()
        );
    }

    #[test]
    fn finish_turn_releases_its_guard_when_the_running_bit_write_fails() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "stuck-finish");
        store.set_running("stuck-finish", true).unwrap();
        store
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert("stuck-finish".into(), "dead-pty".into());
        // The running-bit write now fails: the index it would update is gone.
        fs::remove_file(store.root.join("conversations.json")).unwrap();
        let cleaned = std::cell::Cell::new(false);
        let result = store.finish_turn(
            "stuck-finish",
            "dead-pty",
            None,
            || {},
            || cleaned.set(true),
        );
        assert!(result.is_err());
        assert!(cleaned.get(), "turn cleanup still runs");
        assert!(
            !store
                .active
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains_key("stuck-finish"),
            "a failed write must not leave every later send refused as already responding"
        );
    }

    #[test]
    fn stop_with_a_dead_session_releases_the_conversation() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "dead-session");
        store.set_running("dead-session", true).unwrap();
        // No drain thread is coming for this one: the manager never knew it.
        store
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert("dead-session".into(), "no-such-session".into());
        store.stop("dead-session").unwrap();
        assert!(!store.get("dead-session").unwrap().running);
        assert!(
            !store
                .active
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains_key("dead-session")
        );
        assert!(
            !store.events_path("dead-session").exists(),
            "no ending is invented for a turn whose drain already wrote one"
        );
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
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

        {
            let mut chats = store.conversations.lock().unwrap();
            chats[0].last_message_at_ms = Some(3);
            chats[0].last_message_author = Some("user".into());
            // A setup-only conversation stays out of recents.
            chats[1].updated_at_ms = 99;
            chats[2].last_message_at_ms = Some(5);
            chats[2].last_message_author = Some("agent".into());
        }
        store.approvals.lock().unwrap().push(Approval {
            id: "approval-a1".into(),
            conversation_id: "chat-a1".into(),
            verb: "run command".into(),
            preview: "cargo test".into(),
            shell_prefix: Some("cargo test".into()),
            created_at_ms: now_ms(),
            expires_at_ms: now_ms() + 60_000,
            decision: None,
        });
        let recent = store.recent(20);
        assert_eq!(
            recent
                .iter()
                .map(|chat| chat.id.as_str())
                .collect::<Vec<_>>(),
            vec!["chat-a1", "chat-b1"]
        );
        assert!(recent[0].needs_attention);
        assert_eq!(store.recent(1)[0].id, "chat-a1");

        // A recents fetch must not serialize the sensitive/full conversation
        // record. These are the complete keys allowed on that route.
        let value = serde_json::to_value(&recent[0]).unwrap();
        let keys: HashSet<_> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(
            keys,
            HashSet::from([
                "id",
                "workspaceId",
                "title",
                "backend",
                "lastMessageAtMs",
                "lastMessageAuthor",
                "running",
                "needsAttention",
            ])
        );
        assert!(value.get("systemPrompt").is_none());
        assert!(value.get("resumeToken").is_none());
        assert!(value.get("allowedShellPrefixes").is_none());
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        };
        store.conversations.lock().unwrap().push(chat);
        store.save().unwrap();
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
        assert_eq!(
            last_message_in(&store.events_path("chat-test")),
            Some((3, "agent"))
        );
        let (events, next) = store.events("chat-test", 0).unwrap();
        assert_eq!(events.len(), 2);
        assert!(next > 0);
        assert!(store.list("workspace-b").is_empty());

        // The same two records, read from the end instead of the beginning.
        let page = store.event_page("chat-test", None, 1).unwrap();
        assert_eq!(page.events.len(), 1);
        assert_eq!(page.next_offset, next, "live tailing carries on from here");
        assert!(page.has_earlier);
        assert!(!page.reset);
        let earlier = store
            .event_page("chat-test", page.cursor.as_deref(), 10)
            .unwrap();
        assert_eq!(earlier.events.len(), 1);
        assert_eq!(earlier.events[0]["text"], json!("Hello"));
        assert!(!earlier.has_earlier, "that was the beginning");
        assert!(earlier.cursor.is_none());
        assert_eq!(
            earlier.events[0]["seq"],
            json!(0),
            "every record says where it is, so a row keeps its name"
        );

        // A cursor from an archive that has since been trimmed cannot be
        // honoured, and the answer says so rather than paging the wrong
        // records.
        let stale = make_cursor(0, u64::MAX, 0);
        let answer = store.event_page("chat-test", Some(&stale), 10).unwrap();
        assert!(answer.reset);
        assert_eq!(answer.next_offset, next);
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
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

    /// A conversation with nothing behind it, for the receipt paths, which
    /// all decide before anything is spawned.
    fn conversation_for_receipts(store: &Store, id: &str) {
        store.conversations.lock().unwrap().push(Conversation {
            id: id.into(),
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        });
        store.save().unwrap();
    }

    #[test]
    fn legacy_codex_usage_is_recovered_once_and_survives_forking() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        let raw = store.root.join("original/raw");
        fs::create_dir_all(&raw).unwrap();
        let first = json!({"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20}});
        let second = json!({"type":"turn.completed","usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":30}});
        fs::write(raw.join("100.ndjson"), format!("{first}\n")).unwrap();
        fs::write(raw.join("200.ndjson"), format!("{second}\n")).unwrap();
        store
            .append(
                "original",
                &StoredEvent::Agent {
                    event: Event::Usage {
                        input: 100,
                        output: 30,
                        cache_read: 100,
                        cache_write: 0,
                        cost_usd: None,
                    },
                    backend: "codex".into(),
                    at_ms: 250,
                },
            )
            .unwrap();
        // Retention can leave logical positions above physical offsets.
        let path = store.events_path("original");
        let mut record: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        record["seq"] = json!(900_000);
        fs::write(&path, format!("{record}\n")).unwrap();
        let expected =
            json!({"turns":2,"input":140,"output":50,"cacheRead":160,"cacheWrite":0,"cost":0.0});
        assert_eq!(
            store
                .event_page("original", None, 1)
                .unwrap()
                .usage
                .unwrap(),
            expected
        );
        assert_eq!(
            store
                .event_page("original", None, 1)
                .unwrap()
                .usage
                .unwrap(),
            expected
        );
        let fork = store.fork("original").unwrap();
        assert!(!store.root.join(&fork.id).join("raw").exists());
        assert_eq!(
            store.event_page(&fork.id, None, 1).unwrap().usage.unwrap(),
            expected
        );
        assert_eq!(
            store
                .event_page(&fork.id, None, 100)
                .unwrap()
                .history_trimmed,
            store
                .event_page("original", None, 100)
                .unwrap()
                .history_trimmed
        );
        store
            .append(
                &fork.id,
                &StoredEvent::User {
                    text: "Independent follow-up".into(),
                    at_ms: 300,
                },
            )
            .unwrap();
        fs::write(raw.join("100.ndjson"), "").unwrap();
        assert_eq!(
            store.event_page(&fork.id, None, 1).unwrap().usage.unwrap(),
            expected
        );
    }

    #[test]
    fn optional_vendor_usage_limits_do_not_block_transcript_reading_or_forking() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        store.record_events(
            "original",
            "claude",
            vec![Event::Usage {
                input: 100,
                output: 20,
                cache_read: 5,
                cache_write: 0,
                cost_usd: None,
            }],
        );
        let expected = usage_totals(&store.events_path("original")).unwrap();
        let raw = store.root.join("original/raw");
        fs::create_dir_all(&raw).unwrap();
        for turn in 0..=VENDOR_USAGE_FILES {
            fs::write(raw.join(format!("{turn}.ndjson")), b"{}\n").unwrap();
        }
        assert_eq!(
            store
                .event_page("original", None, 100)
                .unwrap()
                .usage
                .unwrap(),
            expected
        );
        let fork = store.fork("original").unwrap();
        assert_eq!(
            store
                .event_page(&fork.id, None, 100)
                .unwrap()
                .usage
                .unwrap(),
            expected
        );
        fs::remove_dir_all(&raw).unwrap();
        fs::write(&raw, b"not a directory").unwrap();
        assert_eq!(
            store
                .event_page("original", None, 100)
                .unwrap()
                .usage
                .unwrap(),
            expected
        );
    }

    #[test]
    fn compacted_muse_usage_does_not_recount_the_retained_prefix() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        retune_chat(&store, "original", "muse", "standard");
        store.set_resume("original", "muse", "session-a").unwrap();
        let directory = root.path().join("muse/session-a");
        fs::create_dir_all(&directory).unwrap();
        let vendor = |id: &str, time: i64, input: u64| {
            json!({"id":id,"recorded_at":time * 1000,
                "payload":{"event":{"kind":"model_completed","model":"test-model",
                    "usage":{"input_tokens":input,"output_tokens":20}}}})
        };
        fs::write(
            directory.join("session.jsonl"),
            format!("{}\n{}\n", vendor("old", 100, 100), vendor("new", 200, 200)),
        )
        .unwrap();
        let path = store.events_path("original");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, concat!(
            "{\"kind\":\"retainedUsage\",\"usage\":{\"turns\":1,\"input\":100,\"output\":20,\"cacheRead\":0,\"cacheWrite\":0,\"cost\":0.0},\"seq\":1}\n",
            "{\"kind\":\"user\",\"text\":\"continue\",\"at_ms\":150,\"seq\":2}\n",
            "{\"kind\":\"agent\",\"backend\":\"muse\",\"event\":{\"kind\":\"usage\",\"input\":200,\"output\":20},\"at_ms\":250,\"seq\":3}\n"
        )).unwrap();
        let expected = usage_totals(&path).unwrap();
        assert_eq!(expected["input"], 300);
        assert_eq!(
            store
                .conversation_usage_with_muse_root(
                    &store.get("original").unwrap(),
                    &path,
                    Some(&root.path().join("muse")),
                )
                .unwrap(),
            expected,
        );
    }

    #[test]
    fn compacted_muse_usage_repairs_only_complete_following_turns() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        retune_chat(&store, "original", "muse", "standard");
        store.set_resume("original", "muse", "session-a").unwrap();
        let directory = root.path().join("muse/session-a");
        fs::create_dir_all(&directory).unwrap();
        let vendor = |id: &str, time: i64, input: u64| {
            json!({"id":id,"recorded_at":time * 1000,
                "payload":{"event":{"kind":"model_completed","model":"test-model",
                    "usage":{"input_tokens":input,"output_tokens":20}}}})
        };
        fs::write(
            directory.join("session.jsonl"),
            format!(
                "{}\n{}\n{}\n{}\n",
                vendor("old", 100, 100),
                vendor("partial", 200, 200),
                vendor("complete", 400, 100),
                vendor("missing", 500, 50),
            ),
        )
        .unwrap();
        let path = store.events_path("original");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, concat!(
            "{\"kind\":\"retainedUsage\",\"usage\":{\"turns\":1,\"input\":100,\"output\":20,\"cacheRead\":0,\"cacheWrite\":0,\"cost\":0.0},\"seq\":1}\n",
            "{\"kind\":\"agent\",\"backend\":\"muse\",\"event\":{\"kind\":\"usage\",\"input\":200,\"output\":20},\"at_ms\":250,\"seq\":2}\n",
            "{\"kind\":\"user\",\"text\":\"continue\",\"at_ms\":350,\"seq\":3}\n",
            "{\"kind\":\"agent\",\"backend\":\"muse\",\"event\":{\"kind\":\"usage\",\"input\":100,\"output\":20},\"at_ms\":450,\"seq\":4}\n"
        )).unwrap();
        let usage = store
            .conversation_usage_with_muse_root(
                &store.get("original").unwrap(),
                &path,
                Some(&root.path().join("muse")),
            )
            .unwrap();
        assert_eq!(usage["input"], 450);
        assert_eq!(usage["turns"], 4);
    }

    #[test]
    fn a_fork_recovers_new_muse_usage_without_subtracting_copied_history() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        store
            .append(
                "original",
                &StoredEvent::Agent {
                    event: Event::Usage {
                        input: 100,
                        output: 20,
                        cache_read: 0,
                        cache_write: 0,
                        cost_usd: None,
                    },
                    backend: "muse".into(),
                    at_ms: 100,
                },
            )
            .unwrap();
        let fork = store.fork("original").unwrap();
        retune_chat(&store, &fork.id, "muse", "standard");
        store.set_resume(&fork.id, "muse", "session-new").unwrap();
        // A copied record can share the fork's creation millisecond. Its
        // logical position still precedes the new vendor Session marker.
        let path = store.events_path(&fork.id);
        let mut copied: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        copied["at_ms"] = json!(fork.created_at_ms);
        fs::write(&path, format!("{copied}\n")).unwrap();
        store
            .append(
                &fork.id,
                &StoredEvent::Agent {
                    event: Event::Session {
                        id: "session-new".into(),
                    },
                    backend: "muse".into(),
                    at_ms: fork.created_at_ms + 1,
                },
            )
            .unwrap();
        let directory = root.path().join("muse/session-new");
        fs::create_dir_all(&directory).unwrap();
        let vendor = json!({"id":"new","recorded_at":(fork.created_at_ms + 10) * 1000,
            "payload":{"event":{"kind":"model_completed","model":"test-model",
                "usage":{"input_tokens":100,"output_tokens":20}}}});
        fs::write(directory.join("session.jsonl"), format!("{vendor}\n")).unwrap();
        let usage = store
            .conversation_usage_with_muse_root(
                &store.get(&fork.id).unwrap(),
                &store.events_path(&fork.id),
                Some(&root.path().join("muse")),
            )
            .unwrap();
        assert_eq!(usage["input"], 200);
        assert_eq!(usage["turns"], 2);
    }

    #[test]
    fn muse_usage_reconciliation_subtracts_only_the_current_vendor_session() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        retune_chat(&store, "original", "muse", "standard");
        store.set_resume("original", "muse", "session-a").unwrap();
        for (token, at_ms, input) in [
            ("session-a", 100, 100),
            ("session-b", 200, 200),
            ("session-a", 300, 50),
        ] {
            store
                .append(
                    "original",
                    &StoredEvent::Agent {
                        event: Event::Session { id: token.into() },
                        backend: "muse".into(),
                        at_ms: at_ms - 1,
                    },
                )
                .unwrap();
            store
                .append(
                    "original",
                    &StoredEvent::Agent {
                        event: Event::Usage {
                            input,
                            output: 20,
                            cache_read: 0,
                            cache_write: 0,
                            cost_usd: None,
                        },
                        backend: "muse".into(),
                        at_ms,
                    },
                )
                .unwrap();
        }
        let directory = root.path().join("muse/session-a");
        fs::create_dir_all(&directory).unwrap();
        let vendor = |id: &str, time: i64| {
            json!({"id":id,"recorded_at":time * 1000,
                "payload":{"event":{"kind":"model_completed","model":"test-model",
                    "usage":{"input_tokens":100,"output_tokens":20}}}})
        };
        fs::write(
            directory.join("session.jsonl"),
            format!("{}\n{}\n", vendor("old", 100), vendor("new", 300)),
        )
        .unwrap();
        let usage = store
            .conversation_usage_with_muse_root(
                &store.get("original").unwrap(),
                &store.events_path("original"),
                Some(&root.path().join("muse")),
            )
            .unwrap();
        assert_eq!(usage["input"], 400);
        assert_eq!(usage["turns"], 3);
    }

    #[test]
    fn retained_other_backend_usage_does_not_hide_a_new_muse_session() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        retune_chat(&store, "original", "muse", "standard");
        store.set_resume("original", "muse", "session-a").unwrap();
        let directory = root.path().join("muse/session-a");
        fs::create_dir_all(&directory).unwrap();
        let record = |id: &str| {
            json!({"id":id,"recorded_at":1788257973508549_u64,
            "payload_type":"runtime.session","payload":{"event":{
                "kind":"model_completed","model":"test-model","usage":{
                    "input_tokens":100,"output_tokens":20,"cache_read_tokens":0
                }}}})
        };
        fs::write(
            directory.join("session.jsonl"),
            format!("{}\n{}\n", record("first"), record("second")),
        )
        .unwrap();
        let path = store.events_path("original");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, concat!(
            "{\"kind\":\"retainedUsage\",\"usage\":{\"turns\":1,\"input\":100,\"output\":20,\"cacheRead\":0,\"cacheWrite\":0,\"cost\":0.0},\"seq\":1}\n",
            "{\"kind\":\"user\",\"text\":\"continue\",\"at_ms\":10,\"seq\":2}\n",
            "{\"kind\":\"agent\",\"backend\":\"claude\",\"event\":{\"kind\":\"usage\",\"input\":100,\"output\":20},\"at_ms\":20,\"seq\":3}\n"
        )).unwrap();
        assert_eq!(usage_totals(&path).unwrap()["input"], 200);
        assert_eq!(
            store
                .conversation_usage_with_muse_root(
                    &store.get("original").unwrap(),
                    &path,
                    Some(&root.path().join("muse")),
                )
                .unwrap(),
            json!({"turns":4,"input":400,"output":80,"cacheRead":0,"cacheWrite":0,"cost":0.0})
        );
    }

    #[test]
    fn muse_saved_usage_includes_subagents_without_recounting_records() {
        let root = tempfile::tempdir().unwrap();
        let child = root.path().join("children/agent-a");
        fs::create_dir_all(&child).unwrap();
        let record = |id: &str, input: u64, output: u64, cached: u64| {
            json!({
                "id":id,"recorded_at":1788257973508549_u64,"payload_type":"runtime.session",
                "payload":{"event":{"kind":"model_completed","model":"test-model",
                    "usage":{"input_tokens":input,"output_tokens":output,"cache_read_tokens":cached,"cache_write_tokens":0}}}
            })
        };
        let first = record("first", 100, 20, 60);
        let second = record("second", 200, 30, 100);
        fs::write(root.path().join("session.jsonl"), format!("{first}\n")).unwrap();
        fs::write(child.join("session.jsonl"), format!("{first}\n{second}\n")).unwrap();
        let usage = muse_log_usage(root.path(), 0).unwrap();
        assert_eq!(
            usage,
            json!({"turns":2,"input":140,"output":50,"cacheRead":160,"cacheWrite":0,"cost":0.0})
        );
        let previous =
            json!({"turns":1,"input":40,"output":20,"cacheRead":60,"cacheWrite":0,"cost":0.0});
        let extra = usage_difference(&usage, &previous).unwrap().unwrap();
        assert_eq!(extra["input"], 100);
        assert_eq!(extra["cacheRead"], 100);
        assert!(usage_difference(&previous, &usage).unwrap().is_none());
    }

    #[test]
    fn muse_usage_discovery_bounds_unrelated_directory_entries() {
        let root = tempfile::tempdir().unwrap();
        for index in 0..=VENDOR_USAGE_ENTRIES {
            fs::write(root.path().join(format!("unrelated-{index}")), b"").unwrap();
        }
        assert!(muse_session_directory(root.path(), "missing").is_err());
        assert!(muse_log_usage(root.path(), 0).is_err());
    }

    #[test]
    fn muse_usage_finds_the_session_in_date_directories() {
        let root = tempfile::tempdir().unwrap();
        let session = root.path().join("2026/09/30/session-a");
        fs::create_dir_all(&session).unwrap();
        fs::create_dir_all(root.path().join("unrelated/09/30/session-a")).unwrap();
        assert_eq!(
            muse_session_directory(root.path(), "session-a").unwrap(),
            Some(session)
        );
        assert!(
            muse_session_directory(root.path(), "missing")
                .unwrap()
                .is_none()
        );
        assert!(muse_session_directory(root.path(), "../session-a").is_err());
    }

    #[test]
    fn fork_preserves_history_usage_and_files_without_sharing_live_state() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        store
            .edit_conversation("original", |chat| {
                chat.title = "Design".into();
                chat.model = Some("model-a".into());
                chat.system_prompt = "Keep explanations concrete".into();
                chat.resume_token = Some("vendor-session".into());
                chat.resume_tokens
                    .insert("claude".into(), "vendor-session".into());
                chat.standing_sent
                    .insert("claude".into(), "standing-fingerprint".into());
                chat.allowed_tools.push("Read".into());
                chat.allowed_shell_prefixes.push("git status".into());
                chat.send_revision = 7;
                Ok(())
            })
            .unwrap();
        store
            .append(
                "original",
                &StoredEvent::User {
                    text: "Original prompt".into(),
                    at_ms: 1,
                },
            )
            .unwrap();
        store
            .append(
                "original",
                &StoredEvent::Agent {
                    event: Event::Session {
                        id: "vendor-session".into(),
                    },
                    at_ms: 2,
                    backend: "claude".into(),
                },
            )
            .unwrap();
        store
            .append(
                "original",
                &StoredEvent::Agent {
                    event: Event::Text {
                        delta: "Previous answer".into(),
                    },
                    at_ms: 3,
                    backend: "claude".into(),
                },
            )
            .unwrap();
        store
            .append(
                "original",
                &StoredEvent::Agent {
                    event: Event::Usage {
                        input: 100,
                        output: 20,
                        cache_read: 5,
                        cache_write: 2,
                        cost_usd: Some(0.01),
                    },
                    at_ms: 4,
                    backend: "claude".into(),
                },
            )
            .unwrap();
        store
            .append(
                "original",
                &StoredEvent::Approval {
                    approval: Approval {
                        id: "permission-a".into(),
                        conversation_id: "original".into(),
                        verb: "Shell".into(),
                        preview: "Read files".into(),
                        shell_prefix: None,
                        created_at_ms: 5,
                        expires_at_ms: i64::MAX,
                        decision: None,
                    },
                    at_ms: 5,
                },
            )
            .unwrap();
        let original_path = store.root.join("original");
        fs::create_dir_all(original_path.join("files/attachment-a")).unwrap();
        fs::write(
            original_path.join("files/attachment-a/diagram.txt"),
            "attached bytes",
        )
        .unwrap();
        fs::write(original_path.join("steer.txt"), "Pending note").unwrap();
        fs::create_dir(original_path.join("codex-home")).unwrap();
        let original_bytes = fs::read(store.events_path("original")).unwrap();
        let copied = store.fork("original").unwrap();
        assert_ne!(copied.id, "original");
        assert_eq!(copied.title, "Design (fork)");
        assert_eq!(copied.workspace_id, "workspace-a");
        assert_eq!(copied.model.as_deref(), Some("model-a"));
        assert_eq!(copied.system_prompt, "Keep explanations concrete");
        assert_eq!(copied.send_revision, 0);
        assert!(!copied.running);
        assert!(copied.resume_token.is_none());
        assert!(copied.resume_tokens.is_empty());
        assert!(copied.standing_sent.is_empty());
        assert!(copied.allowed_tools.is_empty());
        assert!(copied.allowed_shell_prefixes.is_empty());
        assert_eq!(store.get("original").unwrap().allowed_tools, ["Read"]);
        assert_eq!(
            store.get("original").unwrap().allowed_shell_prefixes,
            ["git status"]
        );
        let copied_path = store.root.join(&copied.id);
        assert_eq!(
            fs::read(copied_path.join("files/attachment-a/diagram.txt")).unwrap(),
            b"attached bytes"
        );
        assert!(!copied_path.join("steer.txt").exists());
        assert!(!copied_path.join("codex-home").exists());
        let page = store.event_page(&copied.id, None, 100).unwrap();
        assert!(
            !page
                .events
                .iter()
                .any(|row| row["event"]["kind"] == "session")
        );
        let approval = page
            .events
            .iter()
            .find(|row| row["kind"] == "approval")
            .unwrap();
        assert_eq!(approval["approval"]["conversationId"], copied.id);
        assert_ne!(approval["approval"]["id"], "permission-a");
        assert_eq!(approval["approval"]["decision"], "deny");
        assert_eq!(approval["approval"]["expiresAtMs"], 0);
        let usage = page.usage.unwrap();
        assert_eq!(usage["input"], 100);
        assert_eq!(usage["output"], 20);
        assert!(
            store
                .handover(&copied)
                .unwrap()
                .unwrap()
                .brief
                .contains("Previous answer")
        );
        let reloaded = Store::load_at(store.root.clone());
        assert_eq!(reloaded.get(&copied.id).unwrap().title, copied.title);
        reloaded
            .append(
                &copied.id,
                &StoredEvent::User {
                    text: "Fork prompt".into(),
                    at_ms: 6,
                },
            )
            .unwrap();
        assert_eq!(
            fs::read(store.events_path("original")).unwrap(),
            original_bytes
        );
        fs::write(
            copied_path.join("files/attachment-a/diagram.txt"),
            "changed copy",
        )
        .unwrap();
        assert_eq!(
            fs::read(original_path.join("files/attachment-a/diagram.txt")).unwrap(),
            b"attached bytes"
        );
    }

    #[test]
    fn fork_refuses_running_stale_and_incomplete_sources_without_publishing_a_copy() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        store
            .edit_conversation("original", |chat| {
                chat.running = true;
                Ok(())
            })
            .unwrap();
        assert!(
            store
                .fork("original")
                .unwrap_err()
                .contains("stop this turn")
        );
        store
            .edit_conversation("original", |chat| {
                chat.running = false;
                Ok(())
            })
            .unwrap();
        let runner = crate::chat_receipts::RunnerLease::try_acquire(&store.root, "original")
            .unwrap()
            .unwrap();
        assert!(
            store
                .fork("original")
                .unwrap_err()
                .contains("stop this turn")
        );
        drop(runner);
        fs::create_dir_all(store.root.join("original")).unwrap();
        fs::write(
            store.events_path("original"),
            b"{\"kind\":\"user\",\"text\":\"partial\",\"atMs\":1}",
        )
        .unwrap();
        assert!(store.fork("original").unwrap_err().contains("incomplete"));
        assert_eq!(store.list("workspace-a").len(), 1);
        let stale = Store::load_at(store.root.clone());
        store.remove("original").unwrap();
        assert!(stale.fork("original").is_err());
        assert!(
            Store::load_at(store.root.clone())
                .list("workspace-a")
                .is_empty()
        );
    }

    #[cfg(unix)]
    #[test]
    fn fork_refuses_symlinked_transcripts_and_attachments() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "original");
        let outside = root.path().join("outside");
        fs::write(&outside, "private bytes").unwrap();
        let path = store.root.join("original");
        fs::create_dir_all(&path).unwrap();
        symlink(&outside, path.join("events.ndjson")).unwrap();
        assert!(store.fork("original").is_err());
        fs::remove_file(path.join("events.ndjson")).unwrap();
        fs::create_dir_all(path.join("files/attachment-a")).unwrap();
        symlink(&outside, path.join("files/attachment-a/file.txt")).unwrap();
        assert!(store.fork("original").is_err());
        assert_eq!(
            Store::load_at(store.root.clone()).list("workspace-a").len(),
            1
        );
        assert_eq!(fs::read(outside).unwrap(), b"private bytes");
    }

    #[test]
    fn transcript_retention_preserves_legacy_and_new_anchors_across_pages() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "retention");
        store.save().unwrap();
        let path = store.events_path("retention");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut legacy = Vec::new();
        for at_ms in 0..10 {
            serde_json::to_writer(
                &mut legacy,
                &StoredEvent::User {
                    text: format!("Legacy {at_ms} {}", "x".repeat(32_000)),
                    at_ms,
                },
            )
            .unwrap();
            legacy.push(b'\n');
        }
        fs::write(&path, &legacy).unwrap();
        let mut identities: HashMap<u64, Value> = records(&legacy, 0)
            .into_iter()
            .map(|row| (row["seq"].as_u64().unwrap(), row["text"].clone()))
            .collect();
        let old = store.event_page("retention", None, 1).unwrap();
        let mut tail_offset = old.next_offset;
        let mut tail_cursor = old.tail_cursor.clone();
        let mut trims = 0;
        let mut previous_first = 0;
        for at_ms in 10..70 {
            store
                .append(
                    "retention",
                    &StoredEvent::User {
                        text: format!("New {at_ms} {}", "y".repeat(32_000)),
                        at_ms,
                    },
                )
                .unwrap();
            let (rows, end) = store.events("retention", 0).unwrap();
            let first = rows[0]["seq"].as_u64().unwrap();
            let changed = first != previous_first;
            if changed {
                trims += 1;
                previous_first = first;
            }
            let chunk = store
                .tail_events("retention", tail_offset, Some(&tail_cursor))
                .unwrap();
            assert_eq!(chunk.reset, changed);
            if changed {
                assert!(
                    chunk.events.is_empty(),
                    "never return a wrong physical slice"
                );
            } else {
                assert_eq!(chunk.events.len(), 1);
                assert_eq!(chunk.events[0]["atMs"], at_ms);
            }
            tail_offset = chunk.next_offset;
            tail_cursor = chunk.tail_cursor;
            let idle = store
                .tail_events("retention", tail_offset, Some(&tail_cursor))
                .unwrap();
            assert!(!idle.reset && idle.events.is_empty());
            let mut last = None;
            for row in &rows {
                let seq = row["seq"].as_u64().unwrap();
                assert!(last.is_none_or(|before| seq > before));
                last = Some(seq);
                if let Some(previous) = identities.insert(seq, row["text"].clone()) {
                    assert_eq!(
                        previous, row["text"],
                        "an anchor must never change its message"
                    );
                }
            }
            assert_eq!(rows.last().unwrap()["atMs"], at_ms);
            assert_eq!(
                end,
                fs::metadata(&path).unwrap().len(),
                "transport offsets stay physical"
            );
            assert!(end <= EVENTS_CAP);
        }
        assert!(trims >= 3, "exercise repeated compaction");
        assert!(
            fs::metadata(&path).unwrap().len() > old.next_offset,
            "regrew past the old length"
        );
        let stale_tail = store
            .tail_events("retention", old.next_offset, Some(&old.tail_cursor))
            .unwrap();
        assert!(stale_tail.reset && stale_tail.events.is_empty());
        let reset = store
            .event_page("retention", old.cursor.as_deref(), 1)
            .unwrap();
        assert!(
            reset.reset,
            "trim followed by growth invalidates a physical cursor"
        );
        let mut cursor = None;
        let mut seen = Vec::new();
        loop {
            let page = store.event_page("retention", cursor.as_deref(), 3).unwrap();
            assert!(!page.reset);
            for row in page.events {
                seen.push(row["seq"].as_u64().unwrap());
            }
            cursor = page.cursor;
            if cursor.is_none() {
                break;
            }
        }
        let (rows, _) = store.events("retention", 0).unwrap();
        seen.sort();
        assert_eq!(
            seen,
            rows.iter()
                .map(|r| r["seq"].as_u64().unwrap())
                .collect::<Vec<_>>()
        );
        let legacy_page = store
            .event_page_positions("retention", None, PAGE_EVENTS_MAX, false)
            .unwrap();
        assert_eq!(legacy_page.events[0]["seq"], legacy_page.start);
        let stable_page = store
            .event_page("retention", None, PAGE_EVENTS_MAX)
            .unwrap();
        assert!(stable_page.events[0]["seq"].as_u64().unwrap() > legacy_page.start);
        assert_eq!(legacy_page.events[0]["text"], stable_page.events[0]["text"]);
        let legacy_tail = store
            .tail_events_positions("retention", 0, None, false)
            .unwrap();
        assert_eq!(legacy_tail.events[0]["seq"], 0);
        assert_eq!(legacy_tail.next_offset, fs::metadata(&path).unwrap().len());
        let snapshot = store.search_snapshot("workspace-a", "retention").unwrap();
        assert!(
            snapshot
                .events
                .iter()
                .all(|row| identities[&row["seq"].as_u64().unwrap()] == row["text"])
        );
        assert!(!fs::read_dir(path.parent().unwrap()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn send_rechecks_revocation_after_waiting_for_acceptance() {
        crate::test_identity::isolated(|| {
            let root = tempfile::tempdir().unwrap();
            let store = Arc::new(Store::at(root.path().join("chat")));
            conversation_for_receipts(&store, "revoked-send");
            let phone = tokenstat_identity::MachineIdentity::from_secret([73; 32]);
            let peer = phone.public_key_hex();
            let policy = tokenstat_identity::identity_dir()
                .unwrap()
                .join("workspace-policy.json");
            for revoke_trust in [false, true] {
                let mut peers = tokenstat_identity::PeerStore::load().unwrap();
                peers.seen(
                    &phone.public_key(),
                    "Test device",
                    None,
                    "2026-09-10T00:00:00Z",
                );
                peers.approve(&phone.public_key());
                peers.save().unwrap();
                fs::write(
                    &policy,
                    serde_json::to_vec(&serde_json::json!({"allowed": [&peer]})).unwrap(),
                )
                .unwrap();
                let acceptance =
                    crate::chat_receipts::Operation::conversation(&store.root, "revoked-send")
                        .unwrap();
                std::thread::scope(|scope| {
                    let (ready, admitted) = std::sync::mpsc::channel();
                    let sending_store = Arc::clone(&store);
                    let sending_peer = peer.clone();
                    let pending = scope.spawn(move || {
                        crate::request_context::with_remote_peer(&sending_peer, || {
                            crate::workspace_policy::require_current_access().unwrap();
                            ready.send(()).unwrap();
                            sending_store.send(
                                "revoked-send",
                                "Keep these words",
                                &[],
                                Some("pending"),
                                Some(now_ms()),
                                Some(0),
                            )
                        })
                    });
                    admitted.recv_timeout(Duration::from_secs(5)).unwrap();
                    if revoke_trust {
                        peers.revoke(&phone.public_key());
                        peers.save().unwrap();
                    } else {
                        // Simulate another process changing the durable grant.
                        fs::write(&policy, br#"{"allowed":[]}"#).unwrap();
                    }
                    drop(acceptance);
                    let error = pending.join().unwrap().unwrap_err();
                    assert_eq!(
                        error.code,
                        if revoke_trust {
                            "not_approved"
                        } else {
                            "workspace_not_allowed"
                        }
                    );
                });
                assert!(!store.receipts_path("revoked-send").exists());
                assert!(!store.response_output_dir("revoked-send").exists());
                assert_eq!(store.get("revoked-send").unwrap().send_revision, 0);
            }
        });
    }

    #[test]
    fn send_revision_survives_reload_and_rejects_stale_setup_before_launch() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "revision");
        let mut legacy = serde_json::to_value(store.get("revision").unwrap()).unwrap();
        legacy.as_object_mut().unwrap().remove("sendRevision");
        assert_eq!(
            serde_json::from_value::<Conversation>(legacy)
                .unwrap()
                .send_revision,
            0
        );
        let stale = Arc::new(Store::load_at(store.root.clone()));
        let first = store
            .update(
                "revision",
                Update {
                    title: Some("Revised setup".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        let second = store
            .update(
                "revision",
                Update {
                    system_prompt: Some("New instructions".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(first.send_revision, 1);
        assert_eq!(second.send_revision, 2);
        store.mark_last_message("revision", 10, "agent").unwrap();
        store.set_running("revision", false).unwrap();
        assert_eq!(
            Store::load_at(store.root.clone())
                .get("revision")
                .unwrap()
                .send_revision,
            2
        );
        assert_eq!(
            stale
                .send(
                    "revision",
                    "Preserve these words",
                    &[],
                    Some("stale"),
                    Some(now_ms()),
                    Some(0)
                )
                .unwrap_err()
                .code,
            "conversation_changed"
        );
        assert!(!store.receipts_path("revision").exists());
        assert!(!store.response_output_dir("revision").exists());
    }

    #[test]
    fn turn_cleanup_precedes_idle_and_cannot_retire_another_owner() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "cleanup");
        store.set_running("cleanup", true).unwrap();
        store
            .active
            .lock()
            .unwrap()
            .insert("cleanup".into(), "current-pty".into());
        let output = store.response_output_dir("cleanup");
        fs::create_dir_all(&output).unwrap();
        fs::write(output.join("result.txt"), "turn output").unwrap();

        let retired = std::cell::Cell::new(false);
        store
            .finish_turn(
                "cleanup",
                "previous-pty",
                None,
                || retired.set(true),
                || panic!("stale owner cleaned current files"),
            )
            .unwrap();
        assert!(
            retired.get(),
            "a credential is retired even when a newer turn owns the conversation"
        );
        assert!(output.exists());
        assert!(store.get("cleanup").unwrap().running);
        let runner =
            crate::chat_receipts::RunnerLease::try_acquire(&store.root, "cleanup").unwrap();
        assert!(runner.is_some());
        store
            .finish_turn(
                "cleanup",
                "current-pty",
                runner,
                || {},
                || {
                    assert!(
                        crate::chat_receipts::RunnerLease::try_acquire(&store.root, "cleanup")
                            .unwrap()
                            .is_none()
                    );
                    assert!(store.get("cleanup").unwrap().running);
                    assert_eq!(
                        store.active.lock().unwrap().get("cleanup").unwrap(),
                        "current-pty"
                    );
                    fs::remove_dir_all(&output).unwrap();
                },
            )
            .unwrap();
        assert!(
            crate::chat_receipts::RunnerLease::try_acquire(&store.root, "cleanup")
                .unwrap()
                .is_some()
        );
        assert!(!output.exists());
        assert!(!store.get("cleanup").unwrap().running);
        assert!(!store.active.lock().unwrap().contains_key("cleanup"));
    }

    #[test]
    fn deleted_conversation_refuses_late_and_stale_process_appends() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "deleted");
        store.save().unwrap();
        let stale = Store::load_at(store.root.clone());
        let event = StoredEvent::User {
            text: "A late event".into(),
            at_ms: 1,
        };
        store.append("deleted", &event).unwrap();
        assert!(store.remove("deleted").unwrap());
        assert!(store.append("deleted", &event).is_err());
        assert!(stale.append("deleted", &event).is_err());
        assert!(!store.events_path("deleted").parent().unwrap().exists());
    }

    #[test]
    fn append_requires_verifiable_durable_ownership_before_creating_files() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        let event = StoredEvent::User {
            text: "Late event".into(),
            at_ms: 1,
        };
        assert!(store.append("missing", &event).is_err());
        assert!(!store.root.exists());
        conversation_for_receipts(&store, "owned");
        let stale = Store::load_at(store.root.clone());
        store.conversations.lock().unwrap()[0].workspace_id = "workspace-b".into();
        store.save().unwrap();
        assert!(stale.append("owned", &event).is_err());
        assert!(!store.root.join("owned").exists());
        fs::write(store.root.join("conversations.json"), b"broken index").unwrap();
        assert!(store.append("owned", &event).is_err());
        assert!(!store.root.join("owned").exists());
        fs::remove_file(store.root.join("conversations.json")).unwrap();
        assert!(store.append("owned", &event).is_err());
        assert!(!store.root.join("owned").exists());
    }

    #[test]
    fn stale_index_updates_preserve_deletion_and_other_process_changes() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "deleted-index");
        conversation_for_receipts(&store, "survivor");
        let stale = Store::load_at(store.root.clone());
        assert!(store.remove("deleted-index").unwrap());
        store
            .retitle_if_untitled("survivor", "A title from another process")
            .unwrap();
        stale.mark_last_message("survivor", 42, "agent").unwrap();
        let reloaded = Store::load_at(store.root.clone());
        assert!(reloaded.get("deleted-index").is_err());
        let survivor = reloaded.get("survivor").unwrap();
        assert_eq!(survivor.title, "A title from another process");
        assert_eq!(survivor.last_message_at_ms, Some(42));
        assert!(stale.set_running("deleted-index", false).is_err());
        assert!(
            Store::load_at(store.root.clone())
                .get("deleted-index")
                .is_err()
        );
    }

    #[test]
    fn index_edits_fail_without_publishing_partial_or_unverified_changes() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "unchanged");
        let original = fs::read(store.root.join("conversations.json")).unwrap();
        let result: Result<(), String> = store.edit_conversation("unchanged", |chat| {
            chat.title = "Should not be published".into();
            Err("operation failed".into())
        });
        assert!(result.is_err());
        assert_eq!(store.get("unchanged").unwrap().title, "New chat");
        assert_eq!(
            fs::read(store.root.join("conversations.json")).unwrap(),
            original
        );
        fs::write(store.root.join("conversations.json"), b"corrupt").unwrap();
        assert!(
            store
                .retitle_if_untitled("unchanged", "A new title")
                .is_err()
        );
        assert_eq!(store.get("unchanged").unwrap().title, "New chat");
        assert_eq!(
            fs::read(store.root.join("conversations.json")).unwrap(),
            b"corrupt"
        );
    }

    #[test]
    fn workspace_removal_uses_current_index_and_preserves_other_workspaces() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "first");
        let stale = Store::load_at(store.root.clone());
        conversation_for_receipts(&store, "newer");
        conversation_for_receipts(&store, "other");
        store
            .conversations
            .lock()
            .unwrap()
            .last_mut()
            .unwrap()
            .workspace_id = "workspace-b".into();
        store.save().unwrap();
        assert_eq!(stale.remove_all("workspace-a").unwrap(), 2);
        let reloaded = Store::load_at(store.root.clone());
        assert!(reloaded.list("workspace-a").is_empty());
        assert_eq!(reloaded.list("workspace-b").len(), 1);
        assert!(store.set_resume("newer", "codex", "late-token").is_err());
    }

    #[test]
    fn retention_keeps_usage_from_evicted_turns() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "usage-retention");
        store.save().unwrap();
        for at_ms in 0..80 {
            store
                .append(
                    "usage-retention",
                    &StoredEvent::Agent {
                        event: Event::Usage {
                            input: 100,
                            output: 10,
                            cache_read: 2,
                            cache_write: 1,
                            cost_usd: Some(0.01),
                        },
                        backend: "codex".into(),
                        at_ms,
                    },
                )
                .unwrap();
            store
                .append(
                    "usage-retention",
                    &StoredEvent::User {
                        text: "x".repeat(32_000),
                        at_ms,
                    },
                )
                .unwrap();
        }
        let page = store.event_page("usage-retention", None, 300).unwrap();
        let mut cursor = page.cursor.clone();
        let mut saw_trimmed_origin = page.history_trimmed;
        while let Some(raw) = cursor {
            let earlier = store
                .event_page("usage-retention", Some(&raw), 300)
                .unwrap();
            saw_trimmed_origin |= earlier.history_trimmed;
            cursor = earlier.cursor;
        }
        assert!(saw_trimmed_origin);
        let usage = page.usage.unwrap();
        assert_eq!(usage["input"], 8000);
        assert_eq!(usage["output"], 800);
        assert_eq!(usage["cacheRead"], 160);
        assert_eq!(usage["cacheWrite"], 80);
        assert_eq!(usage["turns"], 80);
        assert!((usage["cost"].as_f64().unwrap() - 0.8).abs() < 0.000001);
        let bytes = fs::read(store.events_path("usage-retention")).unwrap();
        assert!(bytes.len() as u64 <= EVENTS_CAP);
    }

    #[test]
    fn a_maximum_record_can_be_followed_by_another_after_usage_retention() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "maximum");
        store.save().unwrap();
        store
            .append(
                "maximum",
                &StoredEvent::Agent {
                    event: Event::Usage {
                        input: 100,
                        output: 10,
                        cache_read: 0,
                        cache_write: 0,
                        cost_usd: None,
                    },
                    backend: "codex".into(),
                    at_ms: 1,
                },
            )
            .unwrap();
        let bytes = fs::read(store.events_path("maximum")).unwrap();
        let seq = crate::work_transcript_identity::next_sequence(&bytes, 0).unwrap();
        let empty = serde_json::to_value(StoredEvent::User {
            text: String::new(),
            at_ms: 2,
        })
        .unwrap()
        .as_object()
        .unwrap()
        .clone();
        let overhead = crate::work_transcript_identity::encoded(empty, seq)
            .unwrap()
            .len();
        store
            .append(
                "maximum",
                &StoredEvent::User {
                    text: "x".repeat(PAGE_RECORD_BYTES as usize - overhead),
                    at_ms: 2,
                },
            )
            .unwrap();
        let page = store.event_page("maximum", None, 1).unwrap();
        assert_eq!(page.events.len(), 1);
        assert_eq!(page.events[0]["seq"], seq);
        store
            .append(
                "maximum",
                &StoredEvent::User {
                    text: "After the large record".into(),
                    at_ms: 3,
                },
            )
            .unwrap();
        let page = store.event_page("maximum", None, 300).unwrap();
        assert_eq!(page.usage.unwrap()["input"], 100);
        assert_eq!(
            page.events.last().unwrap()["text"],
            "After the large record"
        );
        assert!(page.history_trimmed);
    }

    #[test]
    fn transcript_writer_refuses_incomplete_tail_and_preserves_a_large_readable_record() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "bounded");
        let path = store.events_path("bounded");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let incomplete = b"{\"kind\":\"user\",\"text\":\"unfinished";
        fs::write(&path, incomplete).unwrap();
        let event = StoredEvent::User {
            text: "next".into(),
            at_ms: 2,
        };
        assert!(store.append("bounded", &event).is_err());
        assert_eq!(fs::read(&path).unwrap(), incomplete);
        fs::write(&path, b"").unwrap();
        let large = StoredEvent::User {
            text: "x".repeat(EVENTS_CAP as usize + 100),
            at_ms: 3,
        };
        store.append("bounded", &large).unwrap();
        let before = fs::read(&path).unwrap();
        assert_eq!(records(&before, 0).len(), 1);
        let oversized = StoredEvent::User {
            text: "x".repeat(PAGE_RECORD_BYTES as usize),
            at_ms: 4,
        };
        assert!(store.append("bounded", &oversized).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
        store.append("bounded", &event).unwrap();
        let rows = records(&fs::read(&path).unwrap(), 0);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["text"], "next");
        assert!(rows[0]["seq"].as_u64().unwrap() >= before.len() as u64);
    }

    #[test]
    fn transcript_process_writers_allocate_unique_complete_records() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().to_owned());
        conversation_for_receipts(&store, "shared");
        let children: Vec<_> = (0..3)
            .map(|writer| {
                std::process::Command::new(std::env::current_exe().unwrap())
                    .args([
                        "--exact",
                        "chat::tests::transcript_process_writer",
                        "--ignored",
                    ])
                    .env("TOKENSTAT_TRANSCRIPT_TEST_ROOT", root.path())
                    .env("TOKENSTAT_TRANSCRIPT_WRITER", writer.to_string())
                    .spawn()
                    .unwrap()
            })
            .collect();
        for mut child in children {
            assert!(child.wait().unwrap().success());
        }
        let saved = Store::load_at(root.path().to_owned())
            .get("shared")
            .unwrap();
        for writer in 0..3 {
            assert_eq!(saved.resume_tokens[&format!("writer-{writer}")], "59");
        }
        let rows = records(
            &fs::read(root.path().join("shared/events.ndjson")).unwrap(),
            0,
        );
        assert_eq!(rows.len(), 180);
        let positions: HashSet<_> = rows.iter().map(|r| r["seq"].as_u64().unwrap()).collect();
        let messages: HashSet<_> = rows.iter().map(|r| r["text"].as_str().unwrap()).collect();
        assert_eq!(positions.len(), rows.len());
        assert_eq!(messages.len(), rows.len());
        assert!(
            rows.windows(2)
                .all(|w| w[0]["seq"].as_u64().unwrap() < w[1]["seq"].as_u64().unwrap())
        );
    }

    #[test]
    #[ignore = "subprocess helper invoked by the transcript writer regression"]
    fn transcript_process_writer() {
        let root = PathBuf::from(std::env::var_os("TOKENSTAT_TRANSCRIPT_TEST_ROOT").unwrap());
        let writer = std::env::var("TOKENSTAT_TRANSCRIPT_WRITER").unwrap();
        let store = Store::load_at(root);
        for at_ms in 0..60 {
            store
                .set_resume("shared", &format!("writer-{writer}"), &at_ms.to_string())
                .unwrap();
            store
                .append(
                    "shared",
                    &StoredEvent::User {
                        text: format!("{writer}-{at_ms}"),
                        at_ms,
                    },
                )
                .unwrap();
        }
    }

    #[test]
    fn search_snapshot_verifies_ownership_bounds_content_and_tracks_revisions() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "chat-search");
        store.save().unwrap();
        assert!(store.search_snapshot("workspace-b", "chat-search").is_err());
        let empty = store.search_snapshot("workspace-a", "chat-search").unwrap();
        assert!(empty.events.is_empty() && !empty.partial);
        let path = store.events_path("chat-search");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let line = serde_json::to_string(&json!({"kind":"user", "text":"needle", "at_ms":1}))
            .unwrap()
            + "\n";
        fs::write(&path, line.repeat(PAGE_EVENTS_MAX + 10)).unwrap();
        let snapshot = store.search_snapshot("workspace-a", "chat-search").unwrap();
        assert!(snapshot.partial);
        assert!(snapshot.events.len() <= PAGE_EVENTS_MAX);
        assert_ne!(snapshot.revision, empty.revision);
        assert!(snapshot.events[0]["seq"].as_u64().unwrap() > 0);
        assert_eq!(
            snapshot.revision,
            store
                .search_snapshot("workspace-a", "chat-search")
                .unwrap()
                .revision
        );
        fs::write(&path, format!("{line}broken record\n")).unwrap();
        let damaged = store.search_snapshot("workspace-a", "chat-search").unwrap();
        assert!(
            damaged.partial,
            "skipped corrupt records must not imply complete coverage"
        );
        assert_eq!(damaged.events.len(), 1);
        let readable = crate::work_search_conversation::blocks(&damaged.events, &damaged.backend);
        assert_eq!(readable.len(), 1);
        assert_eq!(readable[0].anchor, "user-s0");
        assert_eq!(readable[0].text, "needle");
        let mut durable: Index =
            serde_json::from_slice(&fs::read(store.root.join("conversations.json")).unwrap())
                .unwrap();
        durable.conversations[0].title = "Renamed elsewhere".into();
        fs::write(
            store.root.join("conversations.json"),
            serde_json::to_vec(&durable).unwrap(),
        )
        .unwrap();
        let renamed = store.search_snapshot("workspace-a", "chat-search").unwrap();
        assert_eq!(renamed.title, "Renamed elsewhere");
        assert_ne!(renamed.revision, snapshot.revision);
        // Another store/process removes it while this store still holds the
        // original in-memory index. No old content may escape that stale view.
        fs::write(
            store.root.join("conversations.json"),
            br#"{"conversations":[]}"#,
        )
        .unwrap();
        assert!(store.search_snapshot("workspace-a", "chat-search").is_err());
        assert!(
            read_back_checked(&path, fs::metadata(&path).unwrap().len() + 1, 10, true).is_err()
        );
    }

    #[test]
    fn handoff_attachment_preview_is_bounded_metadata_with_verified_ownership() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "chat-handoff");
        store.save().unwrap();
        let path = store.attachment_path("chat-handoff", "att-one", "design.png");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        // A sparse file over the byte-transfer cap is still cheap to describe.
        fs::File::create(&path)
            .unwrap()
            .set_len(ATTACHMENT_CAP as u64 + 1)
            .unwrap();
        let ids = vec!["att-one".to_string()];
        let preview = store
            .handoff_attachments("workspace-a", "chat-handoff", &ids)
            .unwrap();
        assert_eq!(preview.len(), 1);
        assert_eq!(preview[0].id, "att-one");
        assert_eq!(preview[0].name, "design.png");
        assert_eq!(preview[0].size, Some(ATTACHMENT_CAP as u64 + 1));
        assert!(
            store
                .handoff_attachments("workspace-b", "chat-handoff", &ids)
                .is_err()
        );
        assert!(
            store
                .handoff_attachments("workspace-a", "chat-handoff", &vec!["att-one".into(); 21])
                .is_err()
        );
        assert!(
            store
                .handoff_attachments("workspace-a", "chat-handoff", &["../att-one".into()])
                .is_err()
        );
        #[cfg(unix)]
        {
            fs::remove_file(&path).unwrap();
            let outside = root.path().join("outside.png");
            fs::write(&outside, b"private").unwrap();
            std::os::unix::fs::symlink(&outside, &path).unwrap();
            assert!(
                store
                    .handoff_attachments("workspace-a", "chat-handoff", &ids)
                    .is_err()
            );
        }
        let stale = Store::load_at(store.root.clone());
        store.remove("chat-handoff").unwrap();
        assert!(
            stale
                .handoff_attachments("workspace-a", "chat-handoff", &ids)
                .is_err()
        );
        assert!(!store.root.join("chat-handoff").exists());
    }

    #[test]
    fn handoff_checks_persisted_conversation_ownership_and_attachments() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "chat-handoff");
        store.save().unwrap();
        let mut request = crate::work_handoff::PutHandoff {
            request_id: "share-one".into(),
            expected_revision: 0,
            device_name: "Phone".into(),
            draft: Some(crate::work_handoff::SharedDraft {
                text: "keep this draft".into(),
                attachment_ids: vec![],
            }),
            anchor: None,
        };
        assert!(store.handoff("workspace-b", "chat-handoff").is_err());
        assert_eq!(store.handoff("workspace-a", "chat-handoff").unwrap(), None);
        assert!(!store.root.join("chat-handoff").exists());
        request.draft.as_mut().unwrap().attachment_ids = vec!["missing-file".into()];
        assert!(
            store
                .put_handoff("workspace-a", "chat-handoff", &request, "device-a")
                .is_err()
        );
        assert!(!store.root.join("chat-handoff").exists());
        request.draft.as_mut().unwrap().attachment_ids.clear();
        assert!(matches!(
            store
                .put_handoff("workspace-a", "chat-handoff", &request, "device-a")
                .unwrap(),
            crate::work_handoff::PutResult::Saved { .. }
        ));
        let shared = store
            .handoff("workspace-a", "chat-handoff")
            .unwrap()
            .unwrap();
        assert_eq!(shared.device_id, "device-a");
        assert_eq!(shared.draft.unwrap().text, "keep this draft");
        let stale = Store::load_at(store.root.clone());
        assert!(store.remove("chat-handoff").unwrap());
        assert!(
            stale
                .put_handoff("workspace-a", "chat-handoff", &request, "device-a")
                .is_err()
        );
        assert!(!store.root.join("chat-handoff").exists());
    }

    #[test]
    fn a_message_the_host_already_took_is_not_run_again() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        conversation_for_receipts(&store, "chat-receipt");
        let key = crate::chat_receipts::key(None, "m-1");
        store
            .write_receipt(
                "chat-receipt",
                &key,
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Accepted,
                    digest: crate::chat_receipts::digest("hello", &[]),
                    at_ms: now_ms(),
                    event_at_ms: Some(now_ms()),
                },
            )
            .unwrap();
        // Returns the conversation without reaching the workspace lookup,
        // which is the first thing a real send needs and does not exist here.
        let chat = store
            .send("chat-receipt", "hello", &[], Some("m-1"), None, None)
            .unwrap();
        assert_eq!(chat.id, "chat-receipt");
        assert!(!store.events_path("chat-receipt").exists());

        // The same name for different words is a mistake, not a repeat.
        let conflict = store
            .send(
                "chat-receipt",
                "something else",
                &[],
                Some("m-1"),
                None,
                None,
            )
            .unwrap_err();
        assert!(conflict.message.contains("different message"), "{conflict}");

        // And a name that could shape a key in the ledger is refused.
        let bad = store
            .send("chat-receipt", "hello", &[], Some("../escape"), None, None)
            .unwrap_err();
        assert!(bad.message.contains("not usable"), "{bad}");
    }

    #[test]
    fn a_repeat_is_answered_while_the_turn_it_started_is_still_running() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        conversation_for_receipts(&store, "chat-running");
        store.set_running("chat-running", true).unwrap();
        // Without a receipt this is the ordinary refusal.
        let busy = store
            .send("chat-running", "hello", &[], None, None, None)
            .unwrap_err();
        assert!(busy.message.contains("already responding"), "{busy}");
        // With one it is the answer the client was waiting for. The case this
        // exists for is a send whose reply went missing while its turn ran.
        let key = crate::chat_receipts::key(None, "m-4");
        store
            .write_receipt(
                "chat-running",
                &key,
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Accepted,
                    digest: crate::chat_receipts::digest("hello", &[]),
                    at_ms: now_ms(),
                    event_at_ms: Some(now_ms()),
                },
            )
            .unwrap();
        let chat = store
            .send("chat-running", "hello", &[], Some("m-4"), None, None)
            .unwrap();
        assert!(chat.running);
    }

    #[test]
    fn a_pending_receipt_never_guesses_delivery_from_matching_words() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        conversation_for_receipts(&store, "chat-pending");
        let key = crate::chat_receipts::key(None, "m-2");
        let at_ms = now_ms();
        let pending = crate::chat_receipts::Receipt {
            state: crate::chat_receipts::ReceiptState::Pending,
            digest: crate::chat_receipts::digest("hello", &[]),
            at_ms,
            event_at_ms: None,
        };
        store.write_receipt("chat-pending", &key, pending).unwrap();
        for has_similar_row in [false, true] {
            if has_similar_row {
                store
                    .append(
                        "chat-pending",
                        &StoredEvent::User {
                            text: "hello again".into(),
                            at_ms,
                        },
                    )
                    .unwrap();
            }
            let error = store
                .send("chat-pending", "hello", &[], Some("m-2"), None, None)
                .unwrap_err();
            assert_eq!(error.code, crate::error::DELIVERY_UNKNOWN);
            let ledger =
                crate::chat_receipts::Ledger::load(store.receipts_path("chat-pending"), now_ms())
                    .unwrap();
            assert_eq!(
                ledger.get(&key).unwrap().state,
                crate::chat_receipts::ReceiptState::Pending
            );
            assert_eq!(
                store.receipt("chat-pending", "m-2").unwrap().unwrap().state,
                crate::chat_receipts::ReceiptState::NeedsRecovery
            );
        }
    }

    #[test]
    fn corrupt_receipts_refuse_sends_and_checks_without_replacing_evidence() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        conversation_for_receipts(&store, "corrupt");
        fs::create_dir_all(store.root.join("corrupt")).unwrap();
        let path = store.receipts_path("corrupt");
        fs::write(&path, b"{broken").unwrap();
        let error = store
            .send("corrupt", "hello", &[], Some("m-1"), None, None)
            .unwrap_err();
        assert_eq!(error.code, crate::error::DELIVERY_UNKNOWN);
        assert!(store.receipt("corrupt", "m-1").is_err());
        assert_eq!(fs::read(path).unwrap(), b"{broken");
    }

    #[test]
    #[ignore = "child process for the interrupted acceptance regression"]
    fn receipt_interrupted_process() {
        let root = PathBuf::from(std::env::var_os("TOKENSTAT_RECEIPT_TEST_ROOT").unwrap());
        let store = Arc::new(Store::at(root));
        conversation_for_receipts(&store, "interrupted-send");
        let _acceptance =
            crate::chat_receipts::Operation::conversation(&store.root, "interrupted-send").unwrap();
        store
            .write_receipt(
                "interrupted-send",
                &crate::chat_receipts::key(None, "crashed"),
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Pending,
                    digest: crate::chat_receipts::digest("original words", &[]),
                    at_ms: now_ms(),
                    event_at_ms: None,
                },
            )
            .unwrap();
        // Abruptly exit at the durable acceptance boundary. No destructors
        // run, and absence of a transcript must not grant a second launch.
        std::process::exit(23);
    }

    #[test]
    fn interrupted_acceptance_survives_process_exit_and_does_not_replay() {
        let root = tempfile::tempdir().unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "chat::tests::receipt_interrupted_process",
                "--ignored",
            ])
            .env("TOKENSTAT_RECEIPT_TEST_ROOT", root.path().join("chat"))
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(23));
        let store = Arc::new(Store::load_at(root.path().join("chat")));
        let error = store
            .send(
                "interrupted-send",
                "original words",
                &[],
                Some("crashed"),
                Some(now_ms()),
                None,
            )
            .unwrap_err();
        assert_eq!(error.code, crate::error::DELIVERY_UNKNOWN);
        assert_eq!(
            store
                .receipt("interrupted-send", "crashed")
                .unwrap()
                .unwrap()
                .state,
            crate::chat_receipts::ReceiptState::NeedsRecovery
        );
        assert!(!store.events_path("interrupted-send").exists());
    }

    #[test]
    fn stale_store_cannot_replay_a_deleted_conversation() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        conversation_for_receipts(&store, "removed-send");
        let stale = Arc::new(Store::load_at(store.root.clone()));
        store.remove("removed-send").unwrap();
        assert!(
            stale
                .send(
                    "removed-send",
                    "hello",
                    &[],
                    Some("new"),
                    Some(now_ms()),
                    None
                )
                .is_err()
        );
        assert!(!store.root.join("removed-send").exists());
    }

    #[test]
    fn a_receipt_can_be_read_back_without_sending_anything() {
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::at(root.path().join("chat")));
        conversation_for_receipts(&store, "chat-read");
        assert!(store.receipt("chat-read", "m-3").unwrap().is_none());
        let at_ms = now_ms();
        store
            .write_receipt(
                "chat-read",
                &crate::chat_receipts::key(None, "m-3"),
                crate::chat_receipts::Receipt {
                    state: crate::chat_receipts::ReceiptState::Accepted,
                    digest: crate::chat_receipts::digest("hello", &[]),
                    at_ms,
                    event_at_ms: Some(at_ms),
                },
            )
            .unwrap();
        let receipt = store.receipt("chat-read", "m-3").unwrap().unwrap();
        assert_eq!(receipt.state, crate::chat_receipts::ReceiptState::Accepted);
        assert_eq!(receipt.event_at_ms, Some(at_ms));
        assert!(store.receipt("chat-read", "../escape").is_err());
        assert!(store.receipt("no-such-chat", "m-3").is_err());
    }

    #[test]
    fn sent_attachments_become_timeline_rows() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("photo.png");
        fs::write(&file, b"fake-png").unwrap();
        let event = attachment_event("att-1", &file);
        match event {
            Event::Attachment {
                id,
                name,
                media_type,
                size,
            } => {
                assert_eq!(id, "att-1");
                assert_eq!(name, "photo.png");
                assert_eq!(media_type.as_deref(), Some("image/png"));
                assert_eq!(size, 8);
            }
            other => panic!("expected an attachment row, got {other:?}"),
        }
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
        assert!(open.contains("familiar human first name"));
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
    fn chat_backend_availability_comes_from_the_launcher() {
        let catalog = crate::launcher::catalog();
        for backend in backends(false) {
            let id = backend["id"].as_str().unwrap();
            let profile = catalog
                .as_array()
                .unwrap()
                .iter()
                .find(|profile| profile["id"] == launcher_profile_id(id))
                .unwrap();
            assert_eq!(backend["installed"], profile["installed"], "{id}");
            assert_eq!(backend["launcherId"], profile["id"], "{id}");
            if backend["installed"] == false {
                assert_eq!(
                    backend["models"],
                    json!([]),
                    "missing agent {id} advertises models"
                );
            }
            assert!(backend["modelListStatus"].is_string());
        }
    }

    #[test]
    fn chat_advertises_curated_models_where_enumeration_cannot_reach() {
        // Muse and Claude have no list command. An installed one must offer
        // its curated set (the Spark models, the haiku/sonnet aliases), not
        // just the agent default; a missing one advertises nothing.
        for backend in backends(false) {
            let id = backend["id"].as_str().unwrap();
            if !matches!(id, "claude" | "muse") {
                continue;
            }
            if backend["installed"] == false {
                assert_eq!(backend["models"], json!([]), "{id}");
            } else {
                assert_eq!(backend["modelListStatus"], json!("curated"), "{id}");
                assert!(
                    backend["models"]
                        .as_array()
                        .is_some_and(|models| !models.is_empty()),
                    "{id} offers no models past Default"
                );
            }
        }
    }

    #[test]
    fn backends_declare_a_gate_tier_and_keep_the_agent_label() {
        let rows = backends(false);
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        };
        store.conversations.lock().unwrap().push(chat.clone());
        store.save().unwrap();

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

        // Merely having a codex session does not make it current: Claude still
        // owns the latest event, so resuming this token needs the intervening
        // history.
        chat.resume_tokens.insert("codex".into(), "thread-1".into());
        assert!(store.handover(&chat).unwrap().is_some());

        // Once Codex has actually answered, its session is current.
        store
            .append(
                "chat-handoff",
                &StoredEvent::Agent {
                    event: Event::Text {
                        delta: "The retry is in place.".into(),
                    },
                    at_ms: 3,
                    backend: "codex".into(),
                },
            )
            .unwrap();
        assert!(store.handover(&chat).unwrap().is_none());

        // Switching back to Claude must carry Codex's intervening work even
        // though Claude also has an older resumable session.
        chat.backend = "claude".into();
        let returned = store
            .handover(&chat)
            .unwrap()
            .expect("a returning backend must be brought up to date");
        assert!(returned.brief.contains("The retry is in place"));
        assert!(returned.announce);
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        };
        store.conversations.lock().unwrap().push(chat.clone());
        store.save().unwrap();
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        };
        store.conversations.lock().unwrap().push(chat.clone());
        store.save().unwrap();
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        });
        store.save().unwrap();
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
    fn response_file_is_removed_when_its_timeline_record_cannot_be_written() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "broken-transcript");
        let path = store.events_path("broken-transcript");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"incomplete event").unwrap();
        let output = root.path().join("agent-output");
        fs::create_dir_all(&output).unwrap();
        let source = output.join("answer.txt");
        fs::write(&source, b"response").unwrap();
        store.record_response_attachments(
            "broken-transcript",
            "codex",
            &format!("[answer](<{}>)", source.display()),
            &output,
        );
        assert_eq!(fs::read(&path).unwrap(), b"incomplete event");
        let attachment = store.attachment_path("broken-transcript", "unused", "answer.txt");
        assert_eq!(
            fs::read_dir(attachment.parent().unwrap().parent().unwrap())
                .unwrap()
                .count(),
            0
        );
        assert_eq!(fs::read(&source).unwrap(), b"response");
    }

    #[test]
    fn late_response_files_do_not_recreate_a_deleted_conversation() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::at(root.path().join("chat"));
        conversation_for_receipts(&store, "deleted-files");
        let stale = Store::load_at(store.root.clone());
        let output = root.path().join("agent-output");
        fs::create_dir_all(&output).unwrap();
        let source = output.join("answer.txt");
        fs::write(&source, b"late response").unwrap();
        assert!(store.remove("deleted-files").unwrap());
        for writer in [&store, &stale] {
            writer.record_response_attachments(
                "deleted-files",
                "codex",
                &format!("[answer](<{}>)", source.display()),
                &output,
            );
            assert!(!store.root.join("deleted-files").exists());
        }
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        });
        store.save().unwrap();
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
    fn chat_record_ids_do_not_collide_inside_one_millisecond() {
        let first = mint_record_id("file");
        let second = mint_record_id("file");
        assert_ne!(first, second);
        assert!(first.starts_with("file-"));
        assert!(second.starts_with("file-"));
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        });
        {
            let mut chats = store.conversations.lock().unwrap();
            chats[0]
                .resume_tokens
                .insert("claude".into(), "claude-thread".into());
            chats[0].resume_token = Some("claude-thread".into());
        }
        store.save().unwrap();
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
        store.set_running("chat-test", true).unwrap();
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
        });
        store.save().unwrap();
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
        crate::chat_gate::write_codex_home(&codex_home, Some(helper)).unwrap();
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
        // A compound command has no prefix worth saving, so "always allow"
        // must not fall back to saving the bare shell tool verb.
        let compound = store
            .request_approval(
                "chat-test",
                "Bash",
                "Bash git status; curl example.invalid",
                None,
            )
            .unwrap();
        store.resolve_approval(&compound.id, "allowAlways").unwrap();
        assert!(
            !store
                .get("chat-test")
                .unwrap()
                .allowed_tools
                .iter()
                .any(|tool| tool == "Bash"),
            "a compound shell command must not become a standing tool allow"
        );
        let later = store
            .request_approval("chat-test", "Bash", "Bash git status", None)
            .unwrap();
        assert_eq!(later.decision, None, "a later shell call still asks");
    }

    #[test]
    fn untouched_starter_names_migrate_without_rewriting_custom_personas() {
        let root = tempfile::tempdir().unwrap();
        let starter = |id: &str, name: &str| Persona {
            id: id.into(),
            workspace_id: Some("workspace-a".into()),
            name: name.into(),
            system_prompt: STARTER_BRIEF.into(),
            seed: 73,
            created_at_ms: 10,
            updated_at_ms: 10,
        };
        let untouched = starter("starter", "Sage");
        let mut edited_name = starter("edited-name", "Sora");
        edited_name.updated_at_ms = 20;
        let mut edited_brief = starter("edited-brief", "Slate");
        edited_brief.system_prompt = "You review changes carefully.".into();
        let mut shared = starter("shared", "Sage");
        shared.workspace_id = None;
        let collision = starter("custom-human-name", "Ruby");
        let mut legacy_brief = starter("legacy-brief", "Mica");
        legacy_brief.system_prompt = LEGACY_STARTER_BRIEF.into();
        let original = PersonaIndex {
            personas: vec![
                untouched.clone(),
                edited_name.clone(),
                edited_brief.clone(),
                shared.clone(),
                collision.clone(),
                legacy_brief,
            ],
            default_by_workspace: HashMap::from([("workspace-a".into(), "starter".into())]),
        };
        fs::write(
            root.path().join("personas.json"),
            serde_json::to_vec(&original).unwrap(),
        )
        .unwrap();
        let migrated = load_persona_index(root.path());
        let first = &migrated.personas[0];
        assert!(STARTER_NAMES.contains(&first.name.as_str()));
        assert_ne!(first.name, collision.name);
        assert_eq!(first.id, untouched.id);
        assert_eq!(first.seed, untouched.seed);
        assert_eq!(first.system_prompt, untouched.system_prompt);
        assert_eq!(migrated.default_by_workspace, original.default_by_workspace);
        assert_eq!(migrated.personas[1], edited_name);
        assert_eq!(migrated.personas[2], edited_brief);
        assert_eq!(migrated.personas[3], shared);
        assert_eq!(migrated.personas[4], collision);
        assert!(STARTER_NAMES.contains(&migrated.personas[5].name.as_str()));
        assert_eq!(migrated.personas[5].system_prompt, STARTER_BRIEF);
        fs::write(
            root.path().join("personas.json"),
            serde_json::to_vec(&migrated).unwrap(),
        )
        .unwrap();
        assert_eq!(load_persona_index(root.path()).personas, migrated.personas);
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
            last_message_at_ms: None,
            send_revision: 0,
            last_message_author: None,
            running: false,
            branch: None,
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
