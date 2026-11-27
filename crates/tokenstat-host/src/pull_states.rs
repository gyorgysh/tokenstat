// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! What this computer last learned about each pull request, by repository.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};

use serde::{Deserialize, Serialize};
use tokenstat_sync::forge::{self, Repo};

const FILE: &str = "pull-states.json";
const KEPT: usize = 500;
const SETTLED_MS: i64 = 6 * 60 * 60 * 1000;

/// One pull request, as much of it as anything here has read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct State {
    pub number: u32,
    pub title: String,
    pub url: String,
    /// `open`, `merged` or `closed`.
    pub state: String,
    pub draft: bool,
    pub base_ref: String,
    /// Absent until something that reads the size has looked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub additions: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deletions: Option<u32>,
}

impl From<&forge::PullBrief> for State {
    fn from(pull: &forge::PullBrief) -> Self {
        Self {
            number: pull.number,
            title: pull.title.clone(),
            url: pull.url.clone(),
            state: pull.state.clone(),
            draft: pull.draft,
            base_ref: pull.base_ref.clone(),
            additions: Some(pull.additions),
            deletions: Some(pull.deletions),
        }
    }
}

impl From<&forge::BranchPull> for State {
    fn from(pull: &forge::BranchPull) -> Self {
        Self {
            number: pull.number,
            title: pull.title.clone(),
            url: pull.url.clone(),
            state: pull.state.clone(),
            draft: pull.draft,
            base_ref: pull.base_ref.clone(),
            additions: None,
            deletions: None,
        }
    }
}

impl From<&forge::PullDetail> for State {
    fn from(pull: &forge::PullDetail) -> Self {
        Self {
            number: pull.number,
            title: pull.title.clone(),
            url: pull.url.clone(),
            state: pull.state.to_ascii_lowercase(),
            draft: pull.draft,
            base_ref: pull.base_ref.clone(),
            additions: Some(pull.additions),
            deletions: Some(pull.deletions),
        }
    }
}

impl State {
    /// A row of the pull request list, which carries no address of its own.
    pub(crate) fn listed(repo: &Repo, pull: &forge::PullSummary) -> Self {
        Self {
            number: pull.number,
            title: pull.title.clone(),
            url: format!(
                "https://{}/{}/{}/pull/{}",
                repo.host, repo.owner, repo.repo, pull.number
            ),
            state: pull.state.to_ascii_lowercase(),
            draft: pull.draft,
            base_ref: pull.base_ref.clone(),
            additions: Some(pull.additions),
            deletions: Some(pull.deletions),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    pull: Option<State>,
    checked_at_ms: i64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Repository {
    name: String,
    pulls: BTreeMap<u32, Entry>,
}

#[derive(Default, Serialize, Deserialize)]
struct States {
    #[serde(default)]
    repositories: BTreeMap<String, Repository>,
}

pub(crate) fn key(repo: &Repo) -> String {
    format!("{}/{}/{}", repo.host, repo.owner, repo.repo).to_ascii_lowercase()
}

impl States {
    fn load(path: &Path) -> Self {
        std::fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn set(&mut self, repo: &Repo, number: u32, pull: Option<State>, now: i64) {
        let known = self.repositories.entry(key(repo)).or_default();
        known.name = format!("{}/{}", repo.owner, repo.repo);
        let before = known.pulls.remove(&number).and_then(|entry| entry.pull);
        let pull = pull.map(|mut pull| {
            if let Some(before) = before {
                pull.additions = pull.additions.or(before.additions);
                pull.deletions = pull.deletions.or(before.deletions);
            }
            pull
        });
        known.pulls.insert(
            number,
            Entry {
                pull,
                checked_at_ms: now,
            },
        );
        if known.pulls.len() > KEPT {
            let oldest = known
                .pulls
                .iter()
                .min_by_key(|(_, entry)| entry.checked_at_ms)
                .map(|(number, _)| *number);
            if let Some(oldest) = oldest {
                known.pulls.remove(&oldest);
            }
        }
    }

    fn stale(&self, repo: &Repo, numbers: &[u32], open_ms: i64, now: i64) -> Vec<u32> {
        let known = self.repositories.get(&key(repo));
        let mut out: Vec<u32> = numbers
            .iter()
            .copied()
            .filter(
                |number| match known.and_then(|known| known.pulls.get(number)) {
                    None => true,
                    Some(entry) => {
                        let open = entry.pull.as_ref().is_some_and(|pull| pull.state == "open");
                        let age = if open { open_ms } else { SETTLED_MS };
                        now.saturating_sub(entry.checked_at_ms) >= age
                    }
                },
            )
            .collect();
        out.sort_unstable();
        out.dedup();
        out
    }
}

struct Shared {
    path: PathBuf,
    states: Mutex<States>,
}

fn shared() -> &'static Shared {
    static SHARED: OnceLock<Shared> = OnceLock::new();
    SHARED.get_or_init(|| {
        let path = crate::chat::shared().root_path().join(FILE);
        Shared {
            states: Mutex::new(States::load(&path)),
            path,
        }
    })
}

fn lock() -> MutexGuard<'static, States> {
    shared()
        .states
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

fn save(states: &States) {
    if let Ok(body) = serde_json::to_string(states) {
        let _ = tokenstat_sync::snapshot::write_private_atomically(&shared().path, &body);
    }
}

/// Keep what a pull request screen just read. `epoch` is the read cache's
/// from before the request: a sign-out or a write since then makes the
/// answer one that must not be kept.
pub(crate) fn learn(repo: &Repo, pulls: impl IntoIterator<Item = State>, epoch: u64) {
    if cfg!(test) {
        return;
    }
    let now = now_ms();
    let mut states = lock();
    if crate::pulls::cache_epoch() != epoch {
        return;
    }
    let mut any = false;
    for pull in pulls {
        states.set(repo, pull.number, Some(pull), now);
        any = true;
    }
    if any {
        save(&states);
    }
}

/// Something here just changed this pull request: ask again next time.
pub(crate) fn changed(repo: &Repo, number: u32) {
    if cfg!(test) {
        return;
    }
    let mut states = lock();
    if let Some(entry) = states
        .repositories
        .get_mut(&key(repo))
        .and_then(|known| known.pulls.get_mut(&number))
    {
        entry.checked_at_ms = 0;
        save(&states);
    }
}

/// The account changed, so nothing read with the old one is kept.
pub(crate) fn clear() {
    if cfg!(test) {
        return;
    }
    let mut states = lock();
    states.repositories.clear();
    save(&states);
}

/// The last known answers, with the repository's own spelling. Never asks.
pub(crate) fn known(wanted: &[(String, u32)]) -> Vec<Option<(String, State)>> {
    let states = lock();
    wanted
        .iter()
        .map(|(repo, number)| {
            let known = states.repositories.get(repo)?;
            let pull = known.pulls.get(number)?.pull.clone()?;
            Some((known.name.clone(), pull))
        })
        .collect()
}

/// Ask for the numbers whose answers are older than this, in one request per
/// forty. Callers queue here, and each looks again once it is its turn, so
/// two chats naming the same pull request ask once.
pub(crate) fn ensure(repo: &Repo, numbers: &[u32], open_ms: i64) {
    static ASKING: Mutex<()> = Mutex::new(());
    let _turn = ASKING.lock().unwrap_or_else(PoisonError::into_inner);
    let epoch = crate::pulls::cache_epoch();
    let stale = lock().stale(repo, numbers, open_ms, now_ms());
    for numbers in stale.chunks(forge::BRIEFS_LIMIT) {
        let Ok(briefs) = forge::briefs(repo, numbers) else {
            return;
        };
        let now = now_ms();
        let mut states = lock();
        if crate::pulls::cache_epoch() != epoch {
            return;
        }
        for number in numbers {
            let pull = briefs
                .iter()
                .find(|pull| pull.number == *number)
                .map(State::from);
            states.set(repo, *number, pull, now);
        }
        save(&states);
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo() -> Repo {
        Repo {
            host: "github.com".into(),
            owner: "O".into(),
            repo: "R".into(),
        }
    }

    fn state(number: u32, state: &str, additions: Option<u32>) -> State {
        State {
            number,
            title: "t".into(),
            url: format!("https://github.com/O/R/pull/{number}"),
            state: state.into(),
            draft: false,
            base_ref: "main".into(),
            additions,
            deletions: additions,
        }
    }

    #[test]
    fn only_aged_answers_are_asked_for_again() {
        let mut states = States::default();
        states.set(&repo(), 1, Some(state(1, "open", Some(1))), 0);
        states.set(&repo(), 2, Some(state(2, "merged", Some(1))), 0);
        states.set(&repo(), 3, None, 0);
        assert_eq!(
            states.stale(&repo(), &[4, 1, 2, 3, 1], 60_000, 60_000),
            [1, 4]
        );
        assert_eq!(
            states.stale(&repo(), &[1], 600_000, 60_000),
            [] as [u32; 0],
            "a list waits longer than the open chat"
        );
        assert_eq!(
            states.stale(&repo(), &[2, 3], 60_000, SETTLED_MS),
            [2, 3],
            "settled and absent ones are looked at again in time"
        );
    }

    #[test]
    fn a_reader_without_sizes_updates_the_state_and_keeps_them() {
        let mut states = States::default();
        states.set(&repo(), 1, Some(state(1, "open", Some(9))), 0);
        states.set(&repo(), 1, Some(state(1, "merged", None)), 5);
        let known = &states.repositories["github.com/o/r"];
        let pull = known.pulls[&1].pull.as_ref().expect("kept");
        assert_eq!((pull.state.as_str(), pull.additions), ("merged", Some(9)));
        assert_eq!(known.name, "O/R");
    }

    #[test]
    fn one_repository_keeps_its_newest_answers() {
        let mut states = States::default();
        for number in 1..=(KEPT as u32 + 5) {
            states.set(&repo(), number, None, i64::from(number));
        }
        let pulls = &states.repositories["github.com/o/r"].pulls;
        assert_eq!(pulls.len(), KEPT);
        assert!(!pulls.contains_key(&5) && pulls.contains_key(&6));
    }
}
