// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! A kanban board of work, with cards that can be delegated to an agent.
//!
//! The board is a list of columns with cards in order. A card is work a person
//! is tracking; delegating it hands it to the same agent runner automations
//! use, as a one-shot job whose transcript lands in the runs history. Nothing
//! here writes to a repository. It moves cards.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};

use serde::{Deserialize, Serialize};

/// The columns, in order. Archive is hidden from the default list.
pub const COLUMNS: [&str; 4] = ["backlog", "doing", "done", "archive"];

/// Done cards older than this move to archive on the next list/create/update.
const ARCHIVE_AFTER_MS: i64 = 7 * 24 * 60 * 60 * 1000;
/// Extra Done cards above this count are archived, oldest first.
const DONE_CAP: usize = 20;

/// Separates cards created in the same millisecond so a fast client cannot
/// mint the same id twice and overwrite a card.
static CARD_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Whether a card is executable work or a private reminder.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum CardKind {
    #[default]
    Task,
    Note,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum Priority {
    #[default]
    Normal,
    Low,
    High,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Delegate {
    pub run_id: String,
    /// running, ok, error, or stopped. Mirrors the run status.
    pub status: String,
    pub started_at_ms: i64,
    pub ended_at_ms: Option<i64>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Card {
    pub id: String,
    /// Monotonic within this card, including moves and delegate changes.
    #[serde(default)]
    pub revision: u64,
    pub title: String,
    #[serde(default)]
    pub kind: CardKind,
    pub notes: String,
    pub column: String,
    pub order: i64,
    #[serde(default)]
    pub priority: Priority,
    /// Where a delegated run happens. Chosen once at create.
    pub backend: String,
    /// The backend's model alias, when the backend advertises one.
    #[serde(default)]
    pub model: Option<String>,
    /// The backend's reasoning effort, when the backend advertises levels.
    #[serde(default)]
    pub effort: Option<String>,
    pub workspace_id: String,
    pub budget_seconds: u64,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub delegate: Option<Delegate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct File {
    #[serde(default)]
    cards: Vec<Card>,
}

/// The fields a caller may change on a card.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CardUpdate {
    pub column: Option<String>,
    pub order: Option<i64>,
    pub title: Option<String>,
    pub kind: Option<CardKind>,
    pub notes: Option<String>,
    pub priority: Option<Priority>,
    pub backend: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub workspace_id: Option<String>,
    pub budget_seconds: Option<u64>,
}

pub struct Board {
    path: PathBuf,
    cards: Mutex<Vec<Card>>,
}

/// Same body the Mac In front path sends: notes, or the title if notes
/// are empty. The inspector Prompt field is the notes.
fn prompt_for_run(card: &Card) -> String {
    let body = card.notes.trim();
    if !body.is_empty() {
        body.to_string()
    } else {
        card.title.trim().to_string()
    }
}

fn run_error_note(run: &crate::automations::RunRecord) -> String {
    let raw = std::path::PathBuf::from(&run.transcript_path);
    let readable = crate::transcript::readable_path(&raw);
    let text = std::fs::read_to_string(&readable)
        .ok()
        .filter(|t| !t.trim().is_empty())
        .or_else(|| crate::transcript::rematerialize(&raw, &run.backend, true))
        .unwrap_or_default();
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    if line.is_empty() {
        return "the run failed".into();
    }
    let mut note = line.to_string();
    if note.len() > 240 {
        let mut end = 240;
        while end > 0 && !note.is_char_boundary(end) {
            end -= 1;
        }
        note.truncate(end);
    }
    note
}

pub fn shared() -> std::sync::Arc<Board> {
    static BOARD: std::sync::OnceLock<std::sync::Arc<Board>> = std::sync::OnceLock::new();
    std::sync::Arc::clone(BOARD.get_or_init(|| std::sync::Arc::new(Board::load())))
}

impl Board {
    #[cfg(test)]
    fn at(path: PathBuf) -> Board {
        Board {
            path,
            cards: Mutex::new(Vec::new()),
        }
    }

    pub fn load() -> Board {
        let path = tokenstat_paths::data_dir()
            .map(|d| d.join("todo.json"))
            .unwrap_or_else(|| PathBuf::from("todo.json"));
        let cards = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<File>(&text).ok())
            .map(|file| file.cards)
            .unwrap_or_default();
        Board {
            path,
            cards: Mutex::new(cards),
        }
    }

    fn save(&self) -> Result<(), String> {
        let cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        self.save_cards(&cards)
    }

    /// Keep the board lock through persistence so a slower old snapshot cannot
    /// overwrite a newer save. Checked edits publish in memory only afterward.
    fn save_cards(&self, cards: &[Card]) -> Result<(), String> {
        use std::io::Write;
        let body = serde_json::to_vec_pretty(&File {
            cards: cards.to_vec(),
        })
        .map_err(|e| e.to_string())?;
        if let Some(parent) = self.path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let parent = self
            .path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| std::path::Path::new("."));
        let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
        temp.write_all(&body).map_err(|e| e.to_string())?;
        temp.as_file().sync_all().map_err(|e| e.to_string())?;
        temp.persist(&self.path).map_err(|e| e.to_string())?;
        Ok(())
    }

    fn now_ms() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    /// Reconcile delegated cards against the runs history, so a card that
    /// finished while the app was closed stops saying it is running.
    pub fn reconcile(&self) {
        let runs = crate::automations::shared().runs();
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let mut changed = false;
        for card in cards.iter_mut() {
            if let Some(delegate) = card.delegate.as_mut() {
                if matches!(delegate.status.as_str(), "running" | "queued") {
                    if let Some(run) = runs.iter().find(|r| r.id == delegate.run_id) {
                        if run.status != delegate.status {
                            delegate.status = run.status.clone();
                            delegate.ended_at_ms = run.ended_at_ms;
                            if run.status == "error" {
                                delegate.error = Some(run_error_note(run));
                            }
                            card.updated_at_ms = Self::now_ms();
                            card.revision = card.revision.saturating_add(1);
                            changed = true;
                        }
                    }
                }
            }
        }
        drop(cards);
        if changed {
            let _ = self.save();
        }
    }

    /// Active cards, or the full board including archive.
    pub fn list_with(&self, include_archived: bool) -> Vec<Card> {
        self.reconcile();
        self.auto_archive();
        let mut cards = self
            .cards
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if !include_archived {
            cards.retain(|c| c.column != "archive");
        }
        cards.sort_by(|a, b| {
            let ac = COLUMNS
                .iter()
                .position(|c| *c == a.column)
                .unwrap_or(usize::MAX);
            let bc = COLUMNS
                .iter()
                .position(|c| *c == b.column)
                .unwrap_or(usize::MAX);
            (ac, a.order).cmp(&(bc, b.order))
        });
        cards
    }

    /// Hide finished work: week-old Done cards, then the oldest extras
    /// once Done is over the cap. Notes stay on the card.
    fn auto_archive(&self) {
        let now = Self::now_ms();
        let cutoff = now.saturating_sub(ARCHIVE_AFTER_MS);
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let mut changed = false;
        for card in cards.iter_mut() {
            if card.column == "done" && card.updated_at_ms > 0 && card.updated_at_ms < cutoff {
                card.column = "archive".into();
                card.updated_at_ms = now;
                card.revision = card.revision.saturating_add(1);
                changed = true;
            }
        }
        let mut done: Vec<usize> = cards
            .iter()
            .enumerate()
            .filter(|(_, c)| c.column == "done")
            .map(|(i, _)| i)
            .collect();
        if done.len() > DONE_CAP {
            done.sort_by_key(|&i| cards[i].updated_at_ms);
            let extra = done.len() - DONE_CAP;
            for &i in done.iter().take(extra) {
                cards[i].column = "archive".into();
                cards[i].updated_at_ms = now;
                cards[i].revision = cards[i].revision.saturating_add(1);
                changed = true;
            }
        }
        drop(cards);
        if changed {
            let _ = self.save();
        }
    }

    pub fn create(&self, mut card: Card) -> Result<Card, String> {
        if card.title.trim().is_empty() {
            return Err("a card needs a title".into());
        }
        self.auto_archive();
        if !COLUMNS.contains(&card.column.as_str()) {
            card.column = "backlog".into();
        }
        // Workspace and backend are chosen at delegate time. A card can be
        // saved as a reminder of the work before anyone picks an agent.
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        if card.id.is_empty() {
            card.id = format!(
                "todo-{}-{}",
                Self::now_ms(),
                CARD_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            );
        }
        if cards.iter().any(|c| c.id == card.id) {
            return Err(format!("a card with id {} already exists", card.id));
        }
        card.created_at_ms = Self::now_ms();
        card.revision = 1;
        card.updated_at_ms = card.created_at_ms;
        card.order = cards.iter().filter(|c| c.column == card.column).count() as i64;
        cards.push(card.clone());
        drop(cards);
        self.save()?;
        Ok(card)
    }

    pub fn update(&self, id: &str, changes: &CardUpdate) -> Result<Card, String> {
        self.update_checked(id, changes, None)
    }

    pub fn get(&self, id: &str) -> Option<Card> {
        self.reconcile();
        self.auto_archive();
        self.cards
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|card| card.id == id)
            .cloned()
    }

    pub fn edit(
        &self,
        id: &str,
        changes: &CardUpdate,
        expected_revision: u64,
    ) -> Result<Card, String> {
        self.update_checked(id, changes, Some(expected_revision))
    }

    fn update_checked(
        &self,
        id: &str,
        changes: &CardUpdate,
        expected_revision: Option<u64>,
    ) -> Result<Card, String> {
        self.auto_archive();
        let mut live = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let mut cards = live.clone();
        let idx = cards
            .iter()
            .position(|c| c.id == id)
            .ok_or_else(|| format!("no card with id {id}"))?;
        if expected_revision.is_some_and(|expected| expected != cards[idx].revision) {
            return Err("This task changed since you opened it. Compare the saved task before replacing it.".into());
        }
        if cards[idx].revision == u64::MAX {
            return Err("This task's revision cannot be advanced.".into());
        }
        if changes
            .column
            .as_deref()
            .is_some_and(|column| !COLUMNS.contains(&column))
        {
            return Err("Choose To Do, Doing, Done or Archive.".into());
        }
        if changes.title.as_ref().is_some_and(|s| s.len() > 4096)
            || changes
                .notes
                .as_ref()
                .is_some_and(|s| s.len() > 1024 * 1024)
        {
            return Err("Use a title of at most 4 KiB and a prompt of at most 1 MiB.".into());
        }
        if let Some(title) = changes.title.as_deref() {
            if title.trim().is_empty() {
                return Err("a card needs a title".into());
            }
            cards[idx].title = title.to_string();
        }
        if let Some(notes) = changes.notes.as_deref() {
            cards[idx].notes = notes.to_string();
        }
        if let Some(priority) = changes.priority {
            cards[idx].priority = priority;
        }
        if let Some(kind) = changes.kind {
            cards[idx].kind = kind;
        }
        if let Some(backend) = changes.backend.as_deref() {
            cards[idx].backend = backend.to_string();
        }
        if let Some(model) = changes.model.as_deref() {
            cards[idx].model = if model.trim().is_empty() {
                None
            } else {
                Some(model.to_string())
            };
        }
        if let Some(effort) = changes.effort.as_deref() {
            cards[idx].effort = if effort.trim().is_empty() {
                None
            } else {
                Some(effort.to_string())
            };
        }
        if let Some(workspace_id) = changes.workspace_id.as_deref() {
            cards[idx].workspace_id = workspace_id.to_string();
        }
        if let Some(budget_seconds) = changes.budget_seconds {
            cards[idx].budget_seconds = budget_seconds;
        }
        let mut column_changed = false;
        if let Some(column) = changes.column.as_deref() {
            if COLUMNS.contains(&column) && cards[idx].column != column {
                cards[idx].column = column.to_string();
                column_changed = true;
            }
        }
        let requested_order = changes.order.map(|o| o.max(0));
        cards[idx].updated_at_ms = Self::now_ms();
        cards[idx].revision += 1;
        let column = cards[idx].column.clone();
        if requested_order.is_some() || column_changed {
            let mut others: Vec<usize> = cards
                .iter()
                .enumerate()
                .filter(|(_, c)| c.column == column && c.id != id)
                .map(|(i, _)| i)
                .collect();
            others.sort_by_key(|&i| cards[i].order);
            let insert_at = requested_order
                .map(|o| (o as usize).min(others.len()))
                .unwrap_or(others.len());
            others.insert(insert_at, idx);
            for (order, i) in others.into_iter().enumerate() {
                if cards[i].order != order as i64 {
                    cards[i].order = order as i64;
                    if i != idx {
                        cards[i].revision = cards[i].revision.saturating_add(1);
                    }
                }
            }
        }
        let result = cards[idx].clone();
        self.save_cards(&cards)?;
        *live = cards;
        Ok(result)
    }

    pub fn remove(&self, id: &str) -> Result<bool, String> {
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let old = cards.len();
        cards.retain(|c| c.id != id);
        let changed = old != cards.len();
        drop(cards);
        if changed {
            self.save()?;
        }
        Ok(changed)
    }

    /// Delete the reviewed task, preserving newer edits and active runs.
    pub fn delete(&self, id: &str, expected_revision: u64) -> Result<bool, String> {
        self.reconcile();
        let mut live = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(card) = live.iter().find(|card| card.id == id) else {
            return Ok(false);
        };
        if card.revision != expected_revision {
            return Err("This task changed. Reload it before deleting it.".into());
        }
        if card
            .delegate
            .as_ref()
            .is_some_and(|run| matches!(run.status.as_str(), "running" | "queued" | "starting"))
        {
            return Err("Stop this task's run before deleting it.".into());
        }
        let mut next = live.clone();
        next.retain(|card| card.id != id);
        self.save_cards(&next)?;
        *live = next;
        Ok(true)
    }

    /// Hand a card to an agent. The run is a one-shot automation whose
    /// transcript lands in the runs history.
    pub fn delegate(self: &std::sync::Arc<Board>, id: &str) -> Result<Card, String> {
        let job = {
            let cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
            let card = cards
                .iter()
                .find(|c| c.id == id)
                .ok_or_else(|| format!("no card with id {id}"))?;
            if card
                .delegate
                .as_ref()
                .is_some_and(|d| matches!(d.status.as_str(), "running" | "queued"))
            {
                return Err(format!("{} is already running", card.title));
            }
            if card.kind == CardKind::Note {
                return Err("notes cannot be delegated to an agent".into());
            }
            if card.workspace_id.is_empty() {
                return Err("pick a workspace before delegating".into());
            }
            if card.backend.is_empty() {
                return Err("pick an agent before delegating".into());
            }
            crate::automations::Automation {
                id: format!("todo-{}", card.id),
                name: card.title.clone(),
                backend: card.backend.clone(),
                model: card.model.clone(),
                effort: card.effort.clone(),
                workspace_id: card.workspace_id.clone(),
                prompt: prompt_for_run(card),
                schedule: crate::automations::ScheduleSpec::default(),
                budget_seconds: card.budget_seconds,
                enabled: false,
                last_run_at_ms: None,
                next_run_at_ms: None,
                last_run_id: None,
            }
        };
        // The spawn happens with no board lock held: `run_adhoc` starts a
        // process and writes the runs store, and every other board operation
        // (list, move, update) must not queue behind a fork. The lock comes
        // back only to attach the result.
        let run = crate::automations::shared().run_adhoc(job)?;

        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(idx) = cards.iter().position(|c| c.id == id) else {
            // The card vanished while the process was spawning; the run has
            // nothing to attach to, so stop it rather than orphan it.
            drop(cards);
            let _ = crate::automations::shared().kill_run(&run.id);
            return Err(format!("no card with id {id}"));
        };
        if cards[idx]
            .delegate
            .as_ref()
            .is_some_and(|d| matches!(d.status.as_str(), "running" | "queued"))
        {
            // Another delegate claimed the card while the process spawned;
            // keep the original run, not this duplicate.
            let title = cards[idx].title.clone();
            drop(cards);
            let _ = crate::automations::shared().kill_run(&run.id);
            return Err(format!("{title} is already running"));
        }
        cards[idx].delegate = Some(Delegate {
            run_id: run.id.clone(),
            status: run.status.clone(),
            started_at_ms: run.started_at_ms,
            ended_at_ms: None,
            error: None,
        });
        cards[idx].column = "doing".into();
        cards[idx].order = cards
            .iter()
            .filter(|c| c.column == "doing" && c.id != id)
            .count() as i64;
        cards[idx].updated_at_ms = Self::now_ms();
        cards[idx].revision = cards[idx].revision.saturating_add(1);
        let result = cards[idx].clone();
        drop(cards);
        self.save()?;
        Ok(result)
    }

    /// Stop a delegated run by its card. Kills the pty behind the run.
    pub fn stop(&self, id: &str) -> Result<Card, String> {
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let card = cards
            .iter_mut()
            .find(|c| c.id == id)
            .ok_or_else(|| format!("no card with id {id}"))?;
        if let Some(delegate) = card.delegate.as_mut() {
            if matches!(delegate.status.as_str(), "running" | "queued") {
                let _ = crate::automations::shared().kill_run(&delegate.run_id);
            }
        }
        let result = card.clone();
        drop(cards);
        self.save()?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(id: &str) -> Card {
        Card {
            id: id.into(),
            revision: 0,
            title: "a card".into(),
            kind: CardKind::Task,
            notes: String::new(),
            column: "backlog".into(),
            order: 0,
            priority: Priority::Normal,
            backend: "claude".into(),
            model: None,
            effort: None,
            workspace_id: "w".into(),
            budget_seconds: 900,
            created_at_ms: 0,
            updated_at_ms: 0,
            delegate: None,
        }
    }

    #[test]
    fn checked_edits_reject_stale_writers_and_survive_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("todo.json");
        let board = Board::at(path.clone());
        let original = board.create(card("a")).unwrap();
        let edit = CardUpdate {
            title: Some("Updated task".into()),
            ..Default::default()
        };
        let updated = board.edit("a", &edit, original.revision).unwrap();
        assert_eq!(updated.revision, original.revision + 1);
        assert!(board.edit("a", &edit, original.revision).is_err());
        let persisted: File = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let reopened = Board {
            path,
            cards: Mutex::new(persisted.cards),
        };
        let saved = reopened.get("a").unwrap();
        assert_eq!(saved.title, "Updated task");
        assert_eq!(saved.revision, updated.revision);
    }

    #[test]
    fn checked_deletion_preserves_newer_edits_and_active_runs() {
        let dir = tempfile::tempdir().unwrap();
        let board = Board::at(dir.path().join("todo.json"));
        let original = board.create(card("delete-me")).unwrap();
        let updated = board
            .edit(
                &original.id,
                &CardUpdate {
                    notes: Some("New writing".into()),
                    ..Default::default()
                },
                original.revision,
            )
            .unwrap();
        assert!(board.delete(&original.id, original.revision).is_err());
        assert_eq!(board.get(&original.id).unwrap().notes, "New writing");
        assert!(board.delete(&original.id, updated.revision).unwrap());
        assert!(!board.delete(&original.id, updated.revision).unwrap());
        let mut running = card("running");
        running.delegate = Some(Delegate {
            run_id: "fixture-run".into(),
            status: "running".into(),
            started_at_ms: 0,
            ended_at_ms: None,
            error: None,
        });
        let created = board.create(running).unwrap();
        assert!(board.delete(&created.id, created.revision).is_err());
        assert!(board.get(&created.id).is_some());
    }

    #[test]
    fn failed_delete_persistence_keeps_the_task() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("todo.json");
        let board = Board::at(path.clone());
        let created = board.create(card("a")).unwrap();
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(board.delete(&created.id, created.revision).is_err());
        assert!(board.get(&created.id).is_some());
    }

    #[test]
    fn invalid_or_unpersistable_edit_does_not_publish_partial_fields() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("todo.json");
        let board = Board::at(path.clone());
        let original = board.create(card("a")).unwrap();
        let invalid = CardUpdate {
            title: Some("Must not change".into()),
            column: Some("unknown".into()),
            ..Default::default()
        };
        assert!(board.edit("a", &invalid, original.revision).is_err());
        assert_eq!(board.get("a").unwrap().title, original.title);
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        let update = CardUpdate {
            notes: Some("Must not publish".into()),
            ..Default::default()
        };
        assert!(board.edit("a", &update, original.revision).is_err());
        let unchanged = board.get("a").unwrap();
        assert_eq!(unchanged.notes, original.notes);
        assert_eq!(unchanged.revision, original.revision);
    }

    #[test]
    fn reorder_invalidates_revisions_of_cards_it_moves() {
        let dir = tempfile::tempdir().unwrap();
        let board = Board::at(dir.path().join("todo.json"));
        let first = board.create(card("a")).unwrap();
        let second = board.create(card("b")).unwrap();
        board
            .edit(
                "b",
                &CardUpdate {
                    order: Some(0),
                    ..Default::default()
                },
                second.revision,
            )
            .unwrap();
        assert!(
            board
                .edit(
                    "a",
                    &CardUpdate {
                        notes: Some("stale".into()),
                        ..Default::default()
                    },
                    first.revision
                )
                .is_err()
        );
        assert_eq!(board.get("a").unwrap().order, 1);
    }

    #[test]
    fn a_card_needs_a_title() {
        let dir = std::env::temp_dir().join("tokenstat-todo-test");
        let board = Board::at(dir.join("todo.json"));
        let mut c = card("a");
        c.title = "  ".into();
        assert!(board.create(c.clone()).is_err());
        c.title = "ok".into();
        c.workspace_id = String::new();
        assert!(board.create(c).is_ok());
    }

    #[test]
    fn reorder_honours_the_requested_index() {
        let dir = std::env::temp_dir().join("tokenstat-todo-reorder");
        let _ = std::fs::remove_file(dir.join("todo.json"));
        let board = Board::at(dir.join("todo.json"));
        board.create(card("a")).unwrap();
        board.create(card("b")).unwrap();
        board.create(card("c")).unwrap();
        board
            .update(
                "c",
                &CardUpdate {
                    order: Some(0),
                    ..CardUpdate::default()
                },
            )
            .unwrap();
        let ids: Vec<_> = board
            .list_with(false)
            .into_iter()
            .filter(|c| c.column == "backlog")
            .map(|c| c.id)
            .collect();
        assert_eq!(ids, vec!["c", "a", "b"]);
    }

    #[test]
    fn moving_the_first_card_down_one_slot_does_not_overshoot() {
        let dir = std::env::temp_dir().join("tokenstat-todo-reorder-down");
        let _ = std::fs::remove_file(dir.join("todo.json"));
        let board = Board::at(dir.join("todo.json"));
        board.create(card("a")).unwrap();
        board.create(card("b")).unwrap();
        board.create(card("c")).unwrap();
        // Visual [A, B, C]. Drop A before C after A is removed: insert at 1.
        board
            .update(
                "a",
                &CardUpdate {
                    order: Some(1),
                    ..CardUpdate::default()
                },
            )
            .unwrap();
        let ids: Vec<_> = board
            .list_with(false)
            .into_iter()
            .filter(|c| c.column == "backlog")
            .map(|c| c.id)
            .collect();
        assert_eq!(ids, vec!["b", "a", "c"]);
    }

    #[test]
    fn a_note_does_not_need_a_workspace() {
        let dir = std::env::temp_dir().join("tokenstat-todo-note-test");
        let board = Board::at(dir.join("todo.json"));
        let mut c = card("note");
        c.kind = CardKind::Note;
        c.workspace_id.clear();
        let created = board.create(c).unwrap();
        assert_eq!(created.kind, CardKind::Note);
    }

    #[test]
    fn unknown_columns_fall_back_to_backlog() {
        let dir = std::env::temp_dir().join("tokenstat-todo-test2");
        let board = Board::at(dir.join("todo.json"));
        let mut c = card("a");
        c.column = "somewhere-else".into();
        let created = board.create(c).unwrap();
        assert_eq!(created.column, "backlog");
    }

    #[test]
    fn moving_a_card_updates_its_order() {
        let dir = std::env::temp_dir().join("tokenstat-todo-test3");
        let board = Board::at(dir.join("todo.json"));
        board.create(card("a")).unwrap();
        board.create(card("b")).unwrap();
        let moved = board
            .update(
                "a",
                &CardUpdate {
                    column: Some("doing".into()),
                    ..CardUpdate::default()
                },
            )
            .unwrap();
        assert_eq!(moved.column, "doing");
        let all = board.list_with(false);
        // Columns sort backlog first, so the card moved to doing sits after the
        // one still in backlog.
        let pos_b = all.iter().position(|c| c.id == "b").unwrap();
        let pos_a = all.iter().position(|c| c.id == "a").unwrap();
        assert!(pos_b < pos_a);
    }

    #[test]
    fn empty_model_clears_the_stored_alias() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-todo-clear-model-{}", std::process::id()));
        let _ = std::fs::remove_file(dir.join("todo.json"));
        let board = Board::at(dir.join("todo.json"));
        let mut c = card("a");
        c.model = Some("gemini-flash".into());
        c.effort = Some("high".into());
        board.create(c).unwrap();
        let updated = board
            .update(
                "a",
                &CardUpdate {
                    model: Some(String::new()),
                    effort: Some("  ".into()),
                    ..CardUpdate::default()
                },
            )
            .unwrap();
        assert_eq!(updated.model, None);
        assert_eq!(updated.effort, None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn week_old_done_cards_move_to_archive() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-todo-archive-age-{}", std::process::id()));
        let _ = std::fs::remove_file(dir.join("todo.json"));
        let board = Board::at(dir.join("todo.json"));
        let mut c = card("old");
        c.column = "done".into();
        board.create(c).unwrap();
        {
            let mut cards = board.cards.lock().unwrap();
            cards[0].updated_at_ms = 1;
        }
        let active = board.list_with(false);
        assert!(active.is_empty(), "{active:?}");
        let archived = board.list_with(true);
        assert_eq!(archived.len(), 1);
        assert_eq!(archived[0].column, "archive");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn extra_done_cards_above_the_cap_are_archived() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-todo-archive-cap-{}", std::process::id()));
        let _ = std::fs::remove_file(dir.join("todo.json"));
        let board = Board::at(dir.join("todo.json"));
        for i in 0..(DONE_CAP + 3) {
            let mut c = card(&format!("d{i}"));
            c.column = "done".into();
            board.create(c).unwrap();
        }
        {
            // Recent stamps so the 7-day rule does not take them first.
            // Older first so the cap picks a stable extra of 3.
            let now = Board::now_ms();
            let mut cards = board.cards.lock().unwrap();
            for (i, card) in cards.iter_mut().enumerate() {
                card.updated_at_ms = now - i as i64;
                if card.column == "archive" {
                    card.column = "done".into();
                }
            }
        }
        let active = board.list_with(false);
        let done: Vec<_> = active.iter().filter(|c| c.column == "done").collect();
        assert_eq!(done.len(), DONE_CAP);
        let archived = board
            .list_with(true)
            .into_iter()
            .filter(|c| c.column == "archive")
            .count();
        assert_eq!(archived, 3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn archive_keeps_notes() {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-todo-archive-notes-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_file(dir.join("todo.json"));
        let board = Board::at(dir.join("todo.json"));
        let mut c = card("keep");
        c.column = "done".into();
        c.notes = "remember this".into();
        board.create(c).unwrap();
        {
            let mut cards = board.cards.lock().unwrap();
            cards[0].updated_at_ms = 1;
        }
        let archived = board.list_with(true);
        assert_eq!(archived[0].notes, "remember this");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prompt_for_run_prefers_notes() {
        let mut c = card("a");
        c.title = "Card title".into();
        c.notes = "do the work".into();
        assert_eq!(prompt_for_run(&c), "do the work");
        c.notes = "  ".into();
        assert_eq!(prompt_for_run(&c), "Card title");
    }

    #[test]
    fn delegate_requires_a_real_workspace() {
        let dir = std::env::temp_dir().join("tokenstat-todo-test4");
        let board = std::sync::Arc::new(Board::at(dir.join("todo.json")));
        board.create(card("a")).unwrap();
        // Workspace "w" does not exist, so delegation fails with words.
        let err = board.delegate("a").unwrap_err();
        assert!(err.contains("no workspace"), "{err}");
    }
}
