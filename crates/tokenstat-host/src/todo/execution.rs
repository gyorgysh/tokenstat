// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Durable task launch claims. A run identity is attached to the reviewed task
//! before a process can start, so retries can only find or resume that run.

use super::{Board, Card, CardKind, Delegate, creation};
use crate::automations::{Automation, RunRecord, ScheduleSpec};
use serde::{Deserialize, Serialize};
use std::sync::PoisonError;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RunPlacement {
    Background,
    Foreground,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct LaunchReceipt {
    request_digest: String,
    card_id: String,
    run_id: String,
    created_at_ms: i64,
    placement: RunPlacement,
    job: Automation,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskRunOutcome {
    pub operation_id: String,
    pub card_id: String,
    pub run_id: String,
    pub created_at_ms: i64,
    pub placement: RunPlacement,
    pub card: Option<Card>,
    pub run: Option<RunRecord>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchRequest<'a> {
    card_id: &'a str,
    expected_revision: u64,
    placement: RunPlacement,
}

fn request_digest(id: &str, revision: u64, placement: RunPlacement) -> Result<String, String> {
    Ok(creation::hash(
        &serde_json::to_vec(&LaunchRequest {
            card_id: id,
            expected_revision: revision,
            placement,
        })
        .map_err(|error| error.to_string())?,
    ))
}

fn job(card: &Card) -> Automation {
    Automation {
        id: format!("todo-{}", card.id),
        name: card.title.clone(),
        backend: card.backend.clone(),
        model: card.model.clone(),
        effort: card.effort.clone(),
        workspace_id: card.workspace_id.clone(),
        prompt: super::prompt_for_run(card),
        schedule: ScheduleSpec::default(),
        budget_seconds: card.budget_seconds,
        enabled: false,
        last_run_at_ms: None,
        next_run_at_ms: None,
        last_run_id: None,
        revision: 0,
    }
}

impl Board {
    /// Compatibility for older clients. The atomic active-run check still
    /// prevents repeated legacy taps from launching concurrent work.
    pub fn delegate(self: &std::sync::Arc<Self>, id: &str) -> Result<Card, String> {
        let card = self
            .get(id)
            .ok_or_else(|| format!("no card with id {id}"))?;
        let operation_id = format!("legacy-run-{:032x}", rand::random::<u128>());
        self.run_task(id, card.revision, &operation_id, RunPlacement::Background)?
            .card
            .ok_or_else(|| format!("no card with id {id}"))
    }

    /// Compatibility for older clients. It snapshots the current linked run,
    /// then applies the same exact-run checks as the reviewed method.
    pub fn stop(&self, id: &str) -> Result<Card, String> {
        let card = self
            .get(id)
            .ok_or_else(|| format!("no card with id {id}"))?;
        let run_id = card
            .delegate
            .as_ref()
            .ok_or("This task has no run to stop.")?
            .run_id
            .clone();
        self.stop_task(id, card.revision, &run_id)
    }

    fn run_outcome(&self, operation_id: &str, receipt: &LaunchReceipt) -> TaskRunOutcome {
        let card = self
            .cards
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|card| card.id == receipt.card_id)
            .cloned();
        TaskRunOutcome {
            operation_id: operation_id.to_owned(),
            card_id: receipt.card_id.clone(),
            run_id: receipt.run_id.clone(),
            created_at_ms: receipt.created_at_ms,
            placement: receipt.placement,
            card,
            run: crate::automations::shared().get_run(&receipt.run_id),
        }
    }

    fn execute_claim(
        self: &std::sync::Arc<Self>,
        operation_id: &str,
        receipt: LaunchReceipt,
    ) -> Result<TaskRunOutcome, String> {
        let runs = crate::automations::shared();
        if runs.get_run(&receipt.run_id).is_none() {
            if !self.prepare_claim_retry(&receipt)? {
                return Ok(self.run_outcome(operation_id, &receipt));
            }
            let result = runs.run_task(
                receipt.job.clone(),
                receipt.run_id.clone(),
                receipt.placement == RunPlacement::Foreground,
            );
            // A simultaneous retry can lose the insertion race. The durable
            // row proves that the requested run exists, so that is success.
            if let Err(error) = result
                && runs.get_run(&receipt.run_id).is_none()
            {
                return Err(error);
            }
        }
        self.reconcile();
        Ok(self.run_outcome(operation_id, &receipt))
    }

    /// Re-arm only a claim whose process was never recorded. A deleted card
    /// or a card now linked to another run can never resurrect old work.
    fn prepare_claim_retry(&self, receipt: &LaunchReceipt) -> Result<bool, String> {
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(index) = cards.iter().position(|card| card.id == receipt.card_id) else {
            return Ok(false);
        };
        let delegate = cards[index]
            .delegate
            .as_ref()
            .ok_or("This task is no longer linked to the original run request.")?;
        if delegate.run_id != receipt.run_id {
            return Err("This task is now linked to a different run. The original request was not started again.".into());
        }
        if delegate.status == "starting" {
            return Ok(true);
        }
        let mut next = cards.clone();
        if let Some(delegate) = next[index].delegate.as_mut() {
            delegate.status = "starting".into();
            delegate.ended_at_ms = None;
            delegate.error = None;
        }
        next[index].updated_at_ms = Self::now_ms();
        next[index].revision = next[index].revision.saturating_add(1);
        self.save_cards(&next)?;
        *cards = next;
        Ok(true)
    }

    fn mark_launch_failed(&self, run_id: &str, message: &str) {
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(index) = cards.iter().position(|card| {
            card.delegate
                .as_ref()
                .is_some_and(|delegate| delegate.run_id == run_id)
        }) else {
            return;
        };
        let mut next = cards.clone();
        if let Some(delegate) = next[index].delegate.as_mut() {
            delegate.status = "error".into();
            delegate.ended_at_ms = Some(Self::now_ms());
            delegate.error = Some(message.to_owned());
        }
        next[index].updated_at_ms = Self::now_ms();
        next[index].revision = next[index].revision.saturating_add(1);
        if self.save_cards(&next).is_ok() {
            *cards = next;
        }
    }

    /// Claim a reviewed task and one immutable run identity before launching.
    pub fn run_task(
        self: &std::sync::Arc<Self>,
        id: &str,
        expected_revision: u64,
        operation_id: &str,
        placement: RunPlacement,
    ) -> Result<TaskRunOutcome, String> {
        self.ensure_available()?;
        creation::validate_id(operation_id)?;
        let digest = request_digest(id, expected_revision, placement)?;
        let runs = crate::automations::shared();
        runs.ensure_runs_available()?;

        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let creations = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let mut launches = self.launches.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(receipt) = launches.get(operation_id) {
            if receipt.request_digest != digest {
                return Err(
                    "This run id belongs to a different reviewed task. Check the original run."
                        .into(),
                );
            }
            let receipt = receipt.clone();
            drop(launches);
            drop(creations);
            drop(cards);
            // This is an explicit retry of the same immutable operation. The
            // run store claims its deterministic id before spawning, so two
            // callers can race here without creating two processes.
            return self.execute_claim(operation_id, receipt);
        }

        let index = cards
            .iter()
            .position(|card| card.id == id)
            .ok_or_else(|| format!("no card with id {id}"))?;
        if cards[index].revision != expected_revision {
            return Err("This task changed. Reload it before running it.".into());
        }
        if cards[index].revision == u64::MAX {
            return Err("This task's revision cannot be advanced.".into());
        }
        if cards[index].kind == CardKind::Note {
            return Err("notes cannot be run".into());
        }
        if cards[index].delegate.as_ref().is_some_and(|run| {
            matches!(
                run.status.as_str(),
                "starting" | "queued" | "running" | "stopping"
            )
        }) {
            return Err("This task already has an active run.".into());
        }
        let task = job(&cards[index]);
        crate::automations::validate_task_run(&task, placement == RunPlacement::Foreground)?;
        let run_id = format!("task-run-{}", creation::hash(operation_id.as_bytes()));
        let created_at_ms = Self::now_ms();
        let receipt = LaunchReceipt {
            request_digest: digest,
            card_id: id.to_owned(),
            run_id: run_id.clone(),
            created_at_ms,
            placement,
            job: task,
        };
        let mut next_cards = cards.clone();
        next_cards[index].delegate = Some(Delegate {
            run_id,
            status: "starting".into(),
            started_at_ms: created_at_ms,
            ended_at_ms: None,
            error: None,
        });
        next_cards[index].column = "doing".into();
        next_cards[index].order = next_cards
            .iter()
            .filter(|card| card.column == "doing" && card.id != id)
            .count() as i64;
        next_cards[index].updated_at_ms = created_at_ms;
        next_cards[index].revision += 1;
        let mut next_launches = launches.clone();
        next_launches.insert(operation_id.to_owned(), receipt.clone());
        self.save_state(&next_cards, &creations, &next_launches)?;
        *cards = next_cards;
        *launches = next_launches;
        drop(launches);
        drop(creations);
        drop(cards);
        match self.execute_claim(operation_id, receipt.clone()) {
            Ok(outcome) => Ok(outcome),
            Err(error) => {
                self.mark_launch_failed(&receipt.run_id, &error);
                Err(error)
            }
        }
    }

    /// Read a launch receipt without starting or resuming any process.
    pub fn run_receipt(&self, operation_id: &str) -> Result<Option<TaskRunOutcome>, String> {
        self.ensure_available()?;
        creation::validate_id(operation_id)?;
        self.reconcile();
        let launches = self.launches.lock().unwrap_or_else(PoisonError::into_inner);
        let receipt = launches.get(operation_id).cloned();
        drop(launches);
        Ok(receipt.map(|receipt| self.run_outcome(operation_id, &receipt)))
    }

    /// Stop the exact reviewed run. A stale card or another run is refused.
    pub fn stop_task(
        &self,
        id: &str,
        expected_revision: u64,
        run_id: &str,
    ) -> Result<Card, String> {
        self.ensure_available()?;
        let mut cards = self.cards.lock().unwrap_or_else(PoisonError::into_inner);
        let index = cards
            .iter()
            .position(|card| card.id == id)
            .ok_or_else(|| format!("no card with id {id}"))?;
        if cards[index].revision != expected_revision {
            return Err("This task changed. Reload it before stopping its run.".into());
        }
        let delegate = cards[index]
            .delegate
            .as_ref()
            .ok_or("This task has no run to stop.")?;
        if delegate.run_id != run_id {
            return Err(
                "This task is linked to a different run. Reload it before stopping.".into(),
            );
        }
        if !matches!(
            delegate.status.as_str(),
            "starting" | "queued" | "running" | "stopping"
        ) {
            return Ok(cards[index].clone());
        }
        let runs = crate::automations::shared();
        if let Err(error) = runs.kill_run(run_id) {
            let terminal = runs.get_run(run_id).is_some_and(|run| {
                !matches!(run.status.as_str(), "starting" | "queued" | "running")
            });
            if !terminal {
                return Err(error);
            }
        }
        let mut next = cards.clone();
        if let Some(delegate) = next[index].delegate.as_mut() {
            delegate.status = "stopping".into();
        }
        next[index].updated_at_ms = Self::now_ms();
        next[index].revision = next[index].revision.saturating_add(1);
        self.save_cards(&next)?;
        *cards = next;
        Ok(cards[index].clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_receipt_survives_delete_without_resuming_work() {
        let root = tempfile::tempdir().unwrap();
        let board = std::sync::Arc::new(Board::at(root.path().join("todo.json")));
        let mut task = super::super::tests::card("task");
        task.workspace_id = "missing-workspace".into();
        let task = board.create(task).unwrap();
        let operation_id = "fixture-deleted-task-run";
        let placement = RunPlacement::Background;
        board.launches.lock().unwrap().insert(
            operation_id.into(),
            LaunchReceipt {
                request_digest: request_digest(&task.id, task.revision, placement).unwrap(),
                card_id: task.id.clone(),
                run_id: "task-run-fixture-deleted".into(),
                created_at_ms: Board::now_ms(),
                placement,
                job: job(&task),
            },
        );
        board.save().unwrap();
        board.delete(&task.id, task.revision).unwrap();
        let outcome = board
            .run_task(&task.id, task.revision, operation_id, placement)
            .unwrap();
        assert!(outcome.card.is_none());
        assert!(outcome.run.is_none());
        assert!(board.run_receipt(operation_id).unwrap().is_some());
    }

    #[test]
    fn receipt_reads_do_not_launch_but_explicit_retries_resume_the_claim() {
        let root = tempfile::tempdir().unwrap();
        let board = std::sync::Arc::new(Board::at(root.path().join("todo.json")));
        let mut task = super::super::tests::card("task");
        task.workspace_id = "missing-workspace".into();
        let task = board.create(task).unwrap();
        let operation_id = "fixture-explicit-run-retry";
        let placement = RunPlacement::Background;
        let receipt = LaunchReceipt {
            request_digest: request_digest(&task.id, task.revision, placement).unwrap(),
            card_id: task.id.clone(),
            run_id: "task-run-fixture-explicit-retry".into(),
            created_at_ms: Board::now_ms(),
            placement,
            job: job(&task),
        };
        board
            .launches
            .lock()
            .unwrap()
            .insert(operation_id.into(), receipt.clone());
        board.cards.lock().unwrap()[0].delegate = Some(Delegate {
            run_id: receipt.run_id,
            status: "error".into(),
            started_at_ms: Board::now_ms(),
            ended_at_ms: Some(Board::now_ms()),
            error: Some("The first launch failed".into()),
        });

        let observed = board.run_receipt(operation_id).unwrap().unwrap();
        assert!(observed.run.is_none());
        let error = board
            .run_task(&task.id, task.revision, operation_id, placement)
            .unwrap_err();
        assert!(error.contains("workspace"), "{error}");
    }
}
