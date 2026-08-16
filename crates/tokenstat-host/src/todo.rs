//! A kanban board of work, with cards that can be delegated to an agent.
//!
//! The board is a list of columns with cards in order. A card is work a person
//! is tracking; delegating it hands it to the same agent runner automations
//! use, as a one-shot job whose transcript lands in the runs history. Nothing
//! here writes to a repository. It moves cards.

use std::path::PathBuf;
use std::sync::{Mutex, PoisonError};

use serde::{Deserialize, Serialize};

/// The columns, in order. Fixed, because a board with user-editable columns is
/// a settings screen, and this milestone is the cards.
pub const COLUMNS: [&str; 3] = ["backlog", "doing", "done"];

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
    pub title: String,
    #[serde(default)]
    pub kind: CardKind,
    pub notes: String,
    pub column: String,
    pub order: i64,
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
        let path = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .map(|d| d.data_dir().join("todo.json"))
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
        let cards = self
            .cards
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let body = serde_json::to_string_pretty(&File { cards }).map_err(|e| e.to_string())?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, &body).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
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
                                delegate.error = Some("the run failed".into());
                            }
                            card.updated_at_ms = Self::now_ms();
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

    pub fn list(&self) -> Vec<Card> {
        self.reconcile();
        let mut cards = self
            .cards
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
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

    pub fn create(&self, mut card: Card) -> Result<Card, String> {
        if card.title.trim().is_empty() {
            return Err("a card needs a title".into());
        }
        if !COLUMNS.contains(&card.column.as_str()) {
            card.column = "backlog".into();
        }
        // Workspace and backend are chosen at delegate time. A card can be
        // saved as a reminder of the work before anyone picks an agent.
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        if card.id.is_empty() {
            card.id = format!("todo-{}", Self::now_ms());
        }
        if cards.iter().any(|c| c.id == card.id) {
            return Err(format!("a card with id {} already exists", card.id));
        }
        card.created_at_ms = Self::now_ms();
        card.updated_at_ms = card.created_at_ms;
        card.order = cards.iter().filter(|c| c.column == card.column).count() as i64;
        cards.push(card.clone());
        drop(cards);
        self.save()?;
        Ok(card)
    }

    pub fn update(&self, id: &str, changes: &CardUpdate) -> Result<Card, String> {
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let idx = cards
            .iter()
            .position(|c| c.id == id)
            .ok_or_else(|| format!("no card with id {id}"))?;
        if let Some(title) = changes.title.as_deref() {
            if title.trim().is_empty() {
                return Err("a card needs a title".into());
            }
            cards[idx].title = title.to_string();
        }
        if let Some(notes) = changes.notes.as_deref() {
            cards[idx].notes = notes.to_string();
        }
        if let Some(kind) = changes.kind {
            cards[idx].kind = kind;
        }
        if let Some(backend) = changes.backend.as_deref() {
            cards[idx].backend = backend.to_string();
        }
        if let Some(model) = changes.model.as_deref() {
            cards[idx].model = Some(model.to_string());
        }
        if let Some(effort) = changes.effort.as_deref() {
            cards[idx].effort = Some(effort.to_string());
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
                cards[i].order = order as i64;
            }
        }
        let result = cards[idx].clone();
        drop(cards);
        self.save()?;
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
                prompt: format!("{}\n\n{}", card.title, card.notes),
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
            .list()
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
            .list()
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
        let all = board.list();
        // Columns sort backlog first, so the card moved to doing sits after the
        // one still in backlog.
        let pos_b = all.iter().position(|c| c.id == "b").unwrap();
        let pos_a = all.iter().position(|c| c.id == "a").unwrap();
        assert!(pos_b < pos_a);
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
