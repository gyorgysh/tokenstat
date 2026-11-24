// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The pull requests each conversation opened or talked about.
//!
//! Read from what the person and the agent wrote, and from the address
//! `gh pr create` prints. Other tool output is not read: one `gh pr list`
//! would put forty marks on a conversation that was about none of them.
//!
//! **Only repositories the person added here count.** A conversation is text
//! from anywhere, so a link in it must never decide which host is asked, or
//! which repository a credential is used for.
//!
//! Only references are kept here, in a file beside the conversations: no words
//! from them, and no states. What a pull request is, and whether it exists at
//! all, is [`crate::pull_states`]' answer, shared with the pull request pages.
//! A chat list reads both from memory and never waits for the forge.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokenstat_sync::forge::Repo;

const FILE: &str = "chat-pulls.json";
/// The most pull requests one conversation keeps, newest mention first.
const KEPT: usize = 20;
/// The most records read the first time a conversation is looked at.
const FIRST_SCAN: usize = 20_000;
/// The most conversations of a folder brought up to date in one pass.
const CHATS_PER_PASS: usize = 40;
/// How old an open pull request's answer may be before it is asked for again,
/// by who is looking. Settled ones age far more slowly wherever they show.
const AFTER_TURN_MS: i64 = 10 * 1000;
const OPEN_CHAT_MS: i64 = 60 * 1000;
const LIST_MS: i64 = 10 * 60 * 1000;

/// A pull request as a conversation names it.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Key {
    /// The repository, as [`crate::pull_states::key`] spells it.
    repo: String,
    number: u32,
}

impl Key {
    fn new(repo: &Repo, number: u32) -> Self {
        Self {
            repo: crate::pull_states::key(repo),
            number,
        }
    }
}

/// One reference found in a piece of text, before it is known to be real.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Found {
    Address {
        host: String,
        owner: String,
        repo: String,
        number: u32,
    },
    Named {
        owner: String,
        repo: String,
        number: u32,
    },
    Here {
        number: u32,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Mention {
    pull: Key,
    /// The agent opened it here, rather than only naming it.
    #[serde(default)]
    opened: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Chat {
    /// The last record read. Sequence numbers outlive history compaction.
    #[serde(default)]
    seq: u64,
    /// Newest mention first.
    #[serde(default)]
    pulls: Vec<Mention>,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Marks {
    /// The folders holding each repository, as of the last look, so a list
    /// can say where a pull request opens without running git.
    #[serde(default)]
    folders: HashMap<String, Vec<String>>,
    #[serde(default)]
    chats: HashMap<String, Chat>,
}

impl Marks {
    fn load(path: &Path) -> Self {
        // A derived file. One that cannot be read is found again from the
        // conversations, so it starts empty rather than failing a list.
        std::fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save(&self, path: &Path) {
        if let Ok(body) = serde_json::to_string(self) {
            let _ = tokenstat_sync::snapshot::write_private_atomically(path, &body);
        }
    }

    fn note(&mut self, chat: &str, seq: u64, found: Vec<Mention>) {
        let entry = self.chats.entry(chat.to_string()).or_default();
        for mention in found {
            let opened = entry
                .pulls
                .iter()
                .any(|known| known.pull == mention.pull && known.opened);
            entry.pulls.retain(|known| known.pull != mention.pull);
            entry.pulls.insert(
                0,
                Mention {
                    opened: opened || mention.opened,
                    ..mention
                },
            );
        }
        entry.pulls.truncate(KEPT);
        entry.seq = entry.seq.max(seq);
    }

    fn keys(&self, chats: &[String]) -> HashSet<Key> {
        chats
            .iter()
            .filter_map(|id| self.chats.get(id))
            .flat_map(|chat| chat.pulls.iter().map(|mention| mention.pull.clone()))
            .collect()
    }

    fn wanted(&self, chat: &str) -> Vec<(Key, bool)> {
        self.chats.get(chat).map_or_else(Vec::new, |chat| {
            chat.pulls
                .iter()
                .map(|mention| (mention.pull.clone(), mention.opened))
                .collect()
        })
    }
}

/// What a chat list shows. Only pull requests the forge has confirmed: a
/// number in a sentence is not one until it has been looked up.
fn shown(wanted: &[(Key, bool)], folders: &HashMap<String, Vec<String>>, own: &str) -> Vec<Value> {
    let keys: Vec<(String, u32)> = wanted
        .iter()
        .map(|(key, _)| (key.repo.clone(), key.number))
        .collect();
    crate::pull_states::known(&keys)
        .into_iter()
        .zip(wanted)
        .filter_map(|(known, (key, opened))| {
            let (repo, pull) = known?;
            let mut row = serde_json::to_value(pull).ok()?;
            row["repo"] = json!(repo);
            row["opened"] = json!(opened);
            // Its own folder when that is the repository, or another of them.
            let folder = folders
                .get(&key.repo)
                .and_then(|ids| ids.iter().find(|id| *id == own).or_else(|| ids.first()));
            if let Some(folder) = folder {
                row["workspaceId"] = json!(folder);
            }
            Some(row)
        })
        .collect()
}

struct Shared {
    path: PathBuf,
    marks: Mutex<Marks>,
}

fn shared() -> Option<&'static Shared> {
    static SHARED: OnceLock<Option<Shared>> = OnceLock::new();
    SHARED
        .get_or_init(|| {
            let path = crate::chat::shared().root_path().join(FILE);
            Some(Shared {
                marks: Mutex::new(Marks::load(&path)),
                path,
            })
        })
        .as_ref()
}

fn lock(shared: &'static Shared) -> MutexGuard<'static, Marks> {
    shared.marks.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Put every confirmed pull request beside its conversation.
pub(crate) fn attach(rows: &mut Value) {
    let (Some(rows), Some(shared)) = (rows.as_array_mut(), shared()) else {
        return;
    };
    let marks = lock(shared);
    for row in rows {
        let Some(id) = row["id"].as_str() else {
            continue;
        };
        let own = row["workspaceId"].as_str().unwrap_or_default();
        let mut pulls = shown(&marks.wanted(id), &marks.folders, own);
        // The branch's own pull request is one of them, whether or not
        // anybody wrote its number down.
        if row["pull"].is_object() && !pulls.iter().any(|pull| pull["url"] == row["pull"]["url"]) {
            let mut pull = row["pull"].clone();
            pull["workspaceId"] = row["workspaceId"].clone();
            pulls.push(pull);
        }
        if !pulls.is_empty() {
            row["pulls"] = Value::Array(pulls);
        }
    }
}

/// Forget deleted conversations.
pub(crate) fn forget(chats: &[String]) {
    let Some(shared) = shared() else { return };
    let mut marks = lock(shared);
    let before = marks.chats.len();
    marks.chats.retain(|id, _| !chats.contains(id));
    if marks.chats.len() != before {
        marks.save(&shared.path);
    }
}

/// A turn just ended here: read what it said, and look at what it touched.
pub(crate) fn turn_ended(workspace: &str, chat: &str) {
    start(Look::Chat {
        workspace: workspace.into(),
        chat: chat.into(),
        open_ms: AFTER_TURN_MS,
    });
}

/// This conversation is being opened, so its answers should be recent.
pub(crate) fn opened(workspace: &str, chat: &str) {
    start(Look::Chat {
        workspace: workspace.into(),
        chat: chat.into(),
        open_ms: OPEN_CHAT_MS,
    });
}

/// A folder's list is on screen. It shows what is known, and what has aged is
/// looked at behind it.
pub(crate) fn listed(workspace: &str) {
    start(Look::Folder {
        workspace: workspace.into(),
    });
}

#[derive(Clone)]
enum Look {
    Chat {
        workspace: String,
        chat: String,
        open_ms: i64,
    },
    Folder {
        workspace: String,
    },
}

impl Look {
    fn name(&self) -> String {
        match self {
            Self::Chat { chat, .. } => format!("chat:{chat}"),
            Self::Folder { workspace } => format!("folder:{workspace}"),
        }
    }
}

/// When a look last ran, and whether one is running now or wanted again.
#[derive(Default)]
struct Looks {
    folders: HashMap<String, Instant>,
    running: HashMap<String, Option<Look>>,
}

/// Run one look off the calling thread. Never two of the same at once: a turn
/// that ends during a look is looked at when that one finishes.
fn start(look: Look) {
    // Unit tests read lists all the time and must not start work behind them.
    if cfg!(test) {
        return;
    }
    static LOOKS: OnceLock<Mutex<Looks>> = OnceLock::new();
    let looks = LOOKS.get_or_init(Default::default);
    let name = look.name();
    {
        let mut looks = looks.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(again) = looks.running.get_mut(&name) {
            *again = Some(look);
            return;
        }
        if let Look::Folder { workspace } = &look {
            let recent = Duration::from_millis(LIST_MS as u64);
            if looks
                .folders
                .get(workspace)
                .is_some_and(|at| at.elapsed() < recent)
            {
                return;
            }
            looks.folders.insert(workspace.clone(), Instant::now());
        }
        looks.running.insert(name.clone(), None);
    }
    let thread_name = name.clone();
    let spawned = std::thread::Builder::new()
        .name("chat-pulls".into())
        .spawn(move || {
            let mut next = Some(look);
            while let Some(look) = next {
                run(&look);
                let mut looks = looks.lock().unwrap_or_else(PoisonError::into_inner);
                next = looks.running.get_mut(&thread_name).and_then(Option::take);
                if next.is_none() {
                    looks.running.remove(&thread_name);
                }
            }
        });
    if spawned.is_err() {
        looks
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .running
            .remove(&name);
    }
}

fn run(look: &Look) {
    let Some(shared) = shared() else { return };
    let repos = known_repositories();
    let (workspace, chats, open_ms) = match look {
        Look::Chat {
            workspace,
            chat,
            open_ms,
        } => (workspace, vec![chat.clone()], *open_ms),
        Look::Folder { workspace } => {
            let mut chats = crate::chat::shared().list(workspace);
            chats.sort_by_key(|chat| std::cmp::Reverse(chat.updated_at_ms));
            let chats = chats.into_iter().take(CHATS_PER_PASS).map(|chat| chat.id);
            (workspace, chats.collect(), LIST_MS)
        }
    };
    let here = repos.get(workspace);
    let added: Vec<Repo> = repos.values().cloned().collect();
    let store = crate::chat::shared();
    let mut read = {
        let mut folders: HashMap<String, Vec<String>> = HashMap::new();
        for (id, repo) in &repos {
            let ids = folders.entry(crate::pull_states::key(repo)).or_default();
            ids.push(id.clone());
            ids.sort();
        }
        let mut marks = lock(shared);
        let moved = marks.folders != folders;
        marks.folders = folders;
        moved
    };
    for id in &chats {
        let after = lock(shared).chats.get(id).map_or(0, |known| known.seq);
        let Ok(records) = store.records_after(id, after, FIRST_SCAN) else {
            continue;
        };
        let Some(last) = records.iter().filter_map(|row| row["seq"].as_u64()).max() else {
            continue;
        };
        let found = mentions(&records, here, &added);
        lock(shared).note(id, last, found);
        read = true;
    }
    if read {
        lock(shared).save(&shared.path);
    }
    let mut by_repo: HashMap<String, Vec<u32>> = HashMap::new();
    for key in lock(shared).keys(&chats) {
        by_repo.entry(key.repo).or_default().push(key.number);
    }
    for (name, numbers) in by_repo {
        // Only while it is still one of the folders here.
        if let Some(repo) = added
            .iter()
            .find(|repo| crate::pull_states::key(repo) == name)
        {
            crate::pull_states::ensure(repo, &numbers, open_ms);
        }
    }
}

/// The repository behind every folder added here, by folder.
fn known_repositories() -> HashMap<String, Repo> {
    let folders: Vec<(String, PathBuf)> = crate::workspaces::read()
        .workspaces
        .iter()
        .map(|folder| (folder.id.clone(), folder.path.clone()))
        .collect();
    folders
        .into_iter()
        .filter_map(|(id, path)| {
            let remote = tokenstat_workspace::git::remote(&path)?;
            Some((
                id,
                Repo {
                    host: remote.host,
                    owner: remote.owner,
                    repo: remote.repo,
                },
            ))
        })
        .collect()
}

/// Every pull request of an added repository named in these records, oldest
/// first. Streamed text arrives in pieces, so one run of it is read whole.
fn mentions(records: &[Value], here: Option<&Repo>, added: &[Repo]) -> Vec<Mention> {
    let mut out = Vec::new();
    let mut run = String::new();
    let mut commands: HashMap<String, bool> = HashMap::new();
    let mut take = |text: &str, opened: bool| {
        for found in references(text) {
            if let Some(pull) = resolve(found, here, added) {
                out.push(Mention { pull, opened });
            }
        }
    };
    for record in records {
        let event = &record["event"];
        let kind = event["kind"].as_str().unwrap_or_default();
        if record["kind"] == "agent" && kind == "text" {
            run.push_str(event["delta"].as_str().unwrap_or_default());
            continue;
        }
        if !run.is_empty() {
            take(&std::mem::take(&mut run), false);
        }
        match (record["kind"].as_str().unwrap_or_default(), kind) {
            ("user", _) => take(record["text"].as_str().unwrap_or_default(), false),
            ("agent", "toolStart") => {
                let call = event["callId"].as_str().unwrap_or_default().to_string();
                commands.insert(call, opens_a_pull_request(event));
            }
            ("agent", "toolEnd") => {
                let call = event["callId"].as_str().unwrap_or_default();
                if commands.remove(call) == Some(true) && event["ok"] != json!(false) {
                    // Only the address it printed. Anything else in there is
                    // the body of what was written, not what was opened.
                    let detail = event["detail"].as_str().unwrap_or_default();
                    if let Some(line) = detail.lines().rev().find(|line| line.contains("/pull/")) {
                        take(line, true);
                    }
                }
            }
            _ => {}
        }
    }
    if !run.is_empty() {
        take(&run, false);
    }
    out
}

fn opens_a_pull_request(event: &Value) -> bool {
    let command = event["input"]["command"]
        .as_str()
        .or_else(|| event["input"]["cmd"].as_str())
        .or_else(|| event["target"].as_str())
        .unwrap_or_default();
    command.contains("gh pr create")
}

fn resolve(found: Found, here: Option<&Repo>, added: &[Repo]) -> Option<Key> {
    match found {
        // A bare number only means something in a repository's own folder.
        Found::Here { number } => here.map(|here| Key::new(here, number)),
        Found::Address {
            host,
            owner,
            repo,
            number,
        } => added
            .iter()
            .find(|known| {
                known.host.eq_ignore_ascii_case(&host)
                    && known.owner.eq_ignore_ascii_case(&owner)
                    && known.repo.eq_ignore_ascii_case(&repo)
            })
            .map(|known| Key::new(known, number)),
        Found::Named {
            owner,
            repo,
            number,
        } => added
            .iter()
            .find(|known| {
                known.owner.eq_ignore_ascii_case(&owner) && known.repo.eq_ignore_ascii_case(&repo)
            })
            .map(|known| Key::new(known, number)),
    }
}

/// The pull requests a piece of text names, in order.
///
/// Three spellings, each unmistakable on its own: an address, `owner/repo#12`,
/// and a number the words call a pull request ("PR #12", "PRs #12, #13 and
/// 14", "pull request 12"). A bare `#12` is not one. It is as often an issue,
/// a colour or a step.
fn references(text: &str) -> Vec<Found> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        if text.is_char_boundary(at) {
            let rest = &text[at..];
            if let Some((found, used)) = address(rest) {
                out.push(found);
                at += used;
                continue;
            }
            if at == 0 || !word(bytes[at - 1]) {
                if let Some((found, used)) =
                    named(rest, at > 0 && matches!(bytes[at - 1], b'/' | b'.' | b'-'))
                {
                    out.push(found);
                    at += used;
                    continue;
                }
                if let Some((numbers, used)) = spoken(rest) {
                    out.extend(numbers.into_iter().map(|number| Found::Here { number }));
                    at += used;
                    continue;
                }
            }
        }
        at += 1;
    }
    out
}

fn word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn name_part(text: &str) -> usize {
    text.bytes()
        .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        .count()
}

fn number_at(text: &str) -> Option<(u32, usize)> {
    let digits = text.bytes().take_while(u8::is_ascii_digit).count();
    let number = text[..digits].parse::<u32>().ok()?;
    (number > 0 && !text[digits..].bytes().next().is_some_and(word)).then_some((number, digits))
}

fn address(text: &str) -> Option<(Found, usize)> {
    let rest = text.strip_prefix("https://")?;
    let host = name_part(rest);
    let after = rest[host..].strip_prefix('/')?;
    let owner = name_part(after);
    let tail = after[owner..].strip_prefix('/')?;
    let repo = name_part(tail);
    let path = tail[repo..].strip_prefix("/pull/")?;
    let (number, digits) = number_at(path)?;
    if host == 0 || owner == 0 || repo == 0 {
        return None;
    }
    let used = text.len() - path.len() + digits;
    Some((
        Found::Address {
            host: rest[..host].into(),
            owner: after[..owner].into(),
            repo: tail[..repo].into(),
            number,
        },
        used,
    ))
}

fn named(text: &str, inside_a_path: bool) -> Option<(Found, usize)> {
    if inside_a_path {
        return None;
    }
    let owner = name_part(text);
    let after = text[owner..].strip_prefix('/')?;
    let repo = name_part(after);
    let tail = after[repo..].strip_prefix('#')?;
    let (number, digits) = number_at(tail)?;
    if owner == 0 || repo == 0 {
        return None;
    }
    Some((
        Found::Named {
            owner: text[..owner].into(),
            repo: after[..repo].into(),
            number,
        },
        text.len() - tail.len() + digits,
    ))
}

/// "PR #12", "PRs 12, #13 and #14", "pull request #12", "pull requests 1 & 2".
fn spoken(text: &str) -> Option<(Vec<u32>, usize)> {
    const WORDS: [&str; 4] = ["pull requests", "pull request", "prs", "pr"];
    let used = WORDS.iter().find_map(|name| {
        let head = text.get(..name.len())?;
        (head.eq_ignore_ascii_case(name) && !text[name.len()..].bytes().next().is_some_and(word))
            .then_some(name.len())
    })?;
    let mut at = used;
    let mut numbers = Vec::new();
    loop {
        let before = &text[at..];
        let gap = before.len()
            - before
                .trim_start_matches([' ', '\u{a0}', ':', '*', '`', '[', '('])
                .len();
        let rest = &before[gap..];
        let rest_at = at + gap;
        let mark = usize::from(rest.starts_with('#'));
        let Some((number, digits)) = number_at(&rest[mark..]) else {
            break;
        };
        // A second number has to carry its own mark. "PR 12, 3 files" is one.
        if !numbers.is_empty() && mark == 0 {
            break;
        }
        numbers.push(number);
        at = rest_at + mark + digits;
        let tail = &text[at..];
        let joined = [", and ", " and ", ", ", ",", " & ", "/", " "]
            .iter()
            .find(|join| {
                tail.starts_with(**join)
                    && tail[join.len()..]
                        .trim_start_matches(['*', '`', '['])
                        .starts_with('#')
            });
        match joined {
            Some(join) => at += join.len(),
            None => break,
        }
    }
    (!numbers.is_empty()).then_some((numbers, at))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo(owner: &str, name: &str) -> Repo {
        Repo {
            host: "github.com".into(),
            owner: owner.into(),
            repo: name.into(),
        }
    }

    fn here(numbers: &[u32]) -> Vec<Found> {
        numbers
            .iter()
            .map(|number| Found::Here { number: *number })
            .collect()
    }

    fn text(seq: u64, delta: &str) -> Value {
        json!({"kind": "agent", "seq": seq, "event": {"kind": "text", "delta": delta}})
    }

    #[test]
    fn spoken_numbers_need_the_words() {
        assert_eq!(references("see PR #12."), here(&[12]));
        assert_eq!(
            references("PRs #12, #13 and #14 are ready"),
            here(&[12, 13, 14])
        );
        assert_eq!(references("**PR #7** and pull request 8"), here(&[7, 8]));
        assert_eq!(references("merged PR 12, 3 files changed"), here(&[12]));
        assert_eq!(
            references("PR [#9](https://github.com/o/r/pull/9)").len(),
            2
        );
        for other in [
            "#12",
            "issue #12",
            "color #123456",
            "step #1",
            "approx #3",
            "PRD #4",
            "spr 5",
            "PR #0",
            "PR #12a",
            "the PR is 2 days old",
        ] {
            assert_eq!(references(other), vec![], "{other}");
        }
    }

    #[test]
    fn addresses_and_names_are_whole() {
        assert_eq!(
            references("https://github.com/o/r.js/pull/53/files"),
            vec![Found::Address {
                host: "github.com".into(),
                owner: "o".into(),
                repo: "r.js".into(),
                number: 53
            }]
        );
        assert_eq!(
            references("(o/r#5)"),
            vec![Found::Named {
                owner: "o".into(),
                repo: "r".into(),
                number: 5
            }]
        );
        for other in [
            "https://github.com/o/r/issues/5",
            "https://github.com/o/r/pull/",
            "a/b/c#5",
            "src/main.rs#L5",
            "http://github.com/o/r/pull/5",
        ] {
            assert_eq!(references(other), vec![], "{other}");
        }
        assert_eq!(
            references("árvíztűrő PR #3 – é").len(),
            1,
            "never splits a character"
        );
    }

    #[test]
    fn only_repositories_added_here_count() {
        let here = repo("o", "r");
        let added = [here.clone(), repo("o", "other")];
        let records = vec![
            json!({"kind": "user", "seq": 1, "text": "compare https://github.com/o/other/pull/4 with https://evil.example/o/r/pull/5 and x/y#6"}),
            text(2, "Looking at P"),
            text(3, "R #7 now"),
        ];
        let found: Vec<String> = mentions(&records, Some(&here), &added)
            .iter()
            .map(|m| format!("{}#{}", m.pull.repo, m.pull.number))
            .collect();
        assert_eq!(found, ["github.com/o/other#4", "github.com/o/r#7"]);
    }

    #[test]
    fn opened_comes_from_the_create_command_alone() {
        let here = repo("o", "r");
        let call = |seq: u64, command: &str, detail: &str| {
            vec![
                json!({"kind": "agent", "seq": seq, "event": {"kind": "toolStart", "callId": "t", "input": {"command": command}}}),
                json!({"kind": "agent", "seq": seq + 1, "event": {"kind": "toolEnd", "callId": "t", "ok": true, "detail": detail}}),
            ]
        };
        let mut records = call(1, "gh pr list", "PR #1\nhttps://github.com/o/r/pull/2");
        records.extend(call(
            3,
            "gh pr create --fill",
            "Creating pull request for x into main in o/r\n\nhttps://github.com/o/r/pull/9",
        ));
        let found = mentions(&records, Some(&here), std::slice::from_ref(&here));
        assert_eq!(found.len(), 1);
        assert!(found[0].opened && found[0].pull.number == 9);
    }

    #[test]
    fn a_later_mention_keeps_opened_and_moves_to_the_front() {
        let here = repo("o", "r");
        let mention = |number, opened| Mention {
            pull: Key::new(&here, number),
            opened,
        };
        let mut marks = Marks::default();
        marks.note("c", 5, vec![mention(1, true), mention(2, false)]);
        marks.note("c", 9, vec![mention(1, false)]);
        let chat = &marks.chats["c"];
        assert_eq!(chat.seq, 9);
        assert_eq!(
            chat.pulls
                .iter()
                .map(|m| (m.pull.number, m.opened))
                .collect::<Vec<_>>(),
            [(1, true), (2, false)]
        );
        marks.note("c", 10, (1..60).map(|n| mention(n, false)).collect());
        assert_eq!(marks.chats["c"].pulls.len(), KEPT);
    }
}
