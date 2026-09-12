// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Creation receipts live in the same atomic file as the card. Keeping the
//! receipt after deletion prevents a delayed retry from recreating deleted work.

use super::{Board, COLUMNS, Card, CardKind};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::PoisonError;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CreationReceipt {
    request_digest: String,
    card_id: String,
    created_at_ms: i64,
}

/// A confirmed creation, including when the card has since been deleted.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreationOutcome {
    pub operation_id: String,
    pub card_id: String,
    pub created_at_ms: i64,
    pub card: Option<Card>,
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn validate_id(id: &str) -> Result<(), String> {
    if !(16..=128).contains(&id.len())
        || !id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err("A task creation needs a valid operation id.".into());
    }
    Ok(())
}

fn outcome(id: &str, receipt: &CreationReceipt, cards: &[Card]) -> CreationOutcome {
    CreationOutcome {
        operation_id: id.to_owned(),
        card_id: receipt.card_id.clone(),
        created_at_ms: receipt.created_at_ms,
        card: cards.iter().find(|c| c.id == receipt.card_id).cloned(),
    }
}

impl Board {
    /// Repeat one immutable creation safely across lost replies and restarts.
    pub fn create_once(
        &self,
        operation_id: &str,
        mut card: Card,
    ) -> Result<CreationOutcome, String> {
        self.ensure_available()?;
        validate_id(operation_id)?;
        if card.kind != CardKind::Task {
            return Err("This operation creates a task.".into());
        }
        card.title = card.title.trim().to_owned();
        if card.title.is_empty() || card.title.len() > 4096 || card.notes.len() > 1024 * 1024 {
            return Err(
                "Give the task a title of at most 4 KiB and a prompt of at most 1 MiB.".into(),
            );
        }
        if !COLUMNS.contains(&card.column.as_str()) {
            return Err("Choose To Do, Doing, Done or Archive.".into());
        }
        // Server-owned fields are not part of the request. A caller cannot
        // choose a card identity, inject a delegate, or change its revision.
        card.id.clear();
        card.revision = 0;
        card.order = 0;
        card.created_at_ms = 0;
        card.updated_at_ms = 0;
        card.delegate = None;
        let digest = hash(&serde_json::to_vec(&card).map_err(|e| e.to_string())?);
        let mut live = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let mut receipts = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(receipt) = receipts.get(operation_id) {
            if receipt.request_digest != digest {
                return Err("This creation id belongs to a different task draft. Check the original creation.".into());
            }
            return Ok(outcome(operation_id, receipt, &live));
        }
        // Separate from legacy timestamp IDs and stable for this operation.
        card.id = format!("task-{}", hash(operation_id.as_bytes()));
        if live.iter().any(|saved| saved.id == card.id) {
            return Err("This task identity already exists without its creation receipt.".into());
        }
        card.revision = 1;
        card.created_at_ms = Self::now_ms();
        card.updated_at_ms = card.created_at_ms;
        card.order = live.iter().filter(|c| c.column == card.column).count() as i64;
        let receipt = CreationReceipt {
            request_digest: digest,
            card_id: card.id.clone(),
            created_at_ms: card.created_at_ms,
        };
        let mut next_cards = live.clone();
        next_cards.push(card);
        let mut next_receipts = receipts.clone();
        next_receipts.insert(operation_id.to_owned(), receipt.clone());
        self.save_state(&next_cards, &next_receipts)?;
        *live = next_cards;
        *receipts = next_receipts;
        Ok(outcome(operation_id, &receipt, &live))
    }

    /// A read never submits or recreates work, even if the card is now absent.
    pub fn creation_receipt(&self, operation_id: &str) -> Result<Option<CreationOutcome>, String> {
        self.ensure_available()?;
        validate_id(operation_id)?;
        let cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let receipts = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        Ok(receipts
            .get(operation_id)
            .map(|receipt| outcome(operation_id, receipt, &cards)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "fixture-create-operation";

    #[test]
    fn concurrent_retries_create_one_card_and_deleted_receipt_survives_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("board.json");
        let board = std::sync::Arc::new(Board::at(path.clone()));
        let draft = super::super::tests::card("");
        let calls: Vec<_> = (0..8)
            .map(|_| {
                let board = board.clone();
                let draft = draft.clone();
                std::thread::spawn(move || board.create_once(ID, draft).unwrap().card_id)
            })
            .collect();
        let ids: Vec<_> = calls.into_iter().map(|call| call.join().unwrap()).collect();
        assert!(ids.iter().all(|id| id == &ids[0]));
        assert_eq!(board.cards.lock().unwrap().len(), 1);
        let reopened = Board::read_path(path.clone());
        let mut changed = draft.clone();
        changed.notes = "Different prompt".into();
        assert!(reopened.create_once(ID, changed).is_err());
        reopened.delete(&ids[0], 1).unwrap();
        let reopened = Board::read_path(path);
        assert!(
            reopened
                .creation_receipt(ID)
                .unwrap()
                .unwrap()
                .card
                .is_none()
        );
        assert!(reopened.create_once(ID, draft).unwrap().card.is_none());
        assert!(reopened.cards.lock().unwrap().is_empty());
    }

    #[test]
    fn failed_persistence_and_corrupt_stores_cannot_forget_receipts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("board.json");
        std::fs::write(&path, "invalid board").unwrap();
        let broken = Board::read_path(path.clone());
        assert!(broken.creation_receipt(ID).is_err());
        assert!(
            broken
                .create_once(ID, super::super::tests::card(""))
                .is_err()
        );
        assert!(broken.create(super::super::tests::card("legacy")).is_err());
        assert!(broken.delete("missing", 1).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "invalid board");
        let blocked = Board::at(dir.path().to_path_buf());
        assert!(
            blocked
                .create_once(ID, super::super::tests::card(""))
                .is_err()
        );
        assert!(blocked.cards.lock().unwrap().is_empty());
        assert!(blocked.creation_receipt(ID).unwrap().is_none());
    }

    #[test]
    fn legacy_notes_keep_their_existing_long_form_content() {
        let dir = tempfile::tempdir().unwrap();
        let board = Board::at(dir.path().join("board.json"));
        let mut note = super::super::tests::card("note");
        note.kind = CardKind::Note;
        note.title = "Note text".repeat(1024);
        let note = board.create(note).unwrap();
        let changes = super::super::CardUpdate {
            title: Some("Edited note".repeat(1024)),
            ..Default::default()
        };
        assert!(board.edit(&note.id, &changes, note.revision).is_ok());
        assert!(
            board
                .update(
                    &note.id,
                    &super::super::CardUpdate {
                        kind: Some(CardKind::Task),
                        ..Default::default()
                    }
                )
                .is_err()
        );
    }
}
