// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Creation and launch receipts live in the same atomic file as the jobs.
//! Keeping a creation receipt after deletion prevents a delayed retry from
//! recreating deleted work. A launch receipt claims one run identity before
//! any process starts, so a lost reply can only find that run.

use super::{Automation, Store, is_auto_commit_name, now_ms, validate};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::{Arc, PoisonError};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CreationReceipt {
    request_digest: String,
    job_id: String,
    created_at_ms: i64,
}

/// A confirmed creation, including when the job has since been deleted.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomationCreationOutcome {
    pub operation_id: String,
    pub job_id: String,
    pub created_at_ms: i64,
    pub job: Option<Automation>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct LaunchReceipt {
    request_digest: String,
    job_id: String,
    run_id: String,
    created_at_ms: i64,
    job: Automation,
}

/// A confirmed run request. `run` is absent when the process was never recorded.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomationRunOutcome {
    pub operation_id: String,
    pub job_id: String,
    pub run_id: String,
    pub created_at_ms: i64,
    pub job: Option<Automation>,
    pub run: Option<super::RunRecord>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CreationRequest<'a> {
    name: &'a str,
    backend: &'a str,
    model: &'a Option<String>,
    effort: &'a Option<String>,
    workspace_id: &'a str,
    prompt: &'a str,
    schedule: &'a super::ScheduleSpec,
    budget_seconds: u64,
    enabled: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchRequest<'a> {
    job_id: &'a str,
}

pub(super) fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn validate_id(id: &str, kind: &str) -> Result<(), String> {
    if !(16..=128).contains(&id.len())
        || !id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(format!("A job {kind} needs a valid operation id."));
    }
    Ok(())
}

fn creation_digest(job: &Automation) -> Result<String, String> {
    Ok(hash(
        &serde_json::to_vec(&CreationRequest {
            name: job.name.trim(),
            backend: &job.backend,
            model: &job.model,
            effort: &job.effort,
            workspace_id: &job.workspace_id,
            prompt: job.prompt.trim(),
            schedule: &job.schedule,
            budget_seconds: job.budget_seconds,
            enabled: job.enabled,
        })
        .map_err(|error| error.to_string())?,
    ))
}

fn launch_digest(job_id: &str) -> Result<String, String> {
    Ok(hash(
        &serde_json::to_vec(&LaunchRequest { job_id }).map_err(|error| error.to_string())?,
    ))
}

fn creation_outcome(
    id: &str,
    receipt: &CreationReceipt,
    jobs: &[Automation],
) -> AutomationCreationOutcome {
    AutomationCreationOutcome {
        operation_id: id.to_owned(),
        job_id: receipt.job_id.clone(),
        created_at_ms: receipt.created_at_ms,
        job: jobs.iter().find(|job| job.id == receipt.job_id).cloned(),
    }
}

impl Store {
    /// Repeat one immutable creation safely across lost replies and restarts.
    pub fn create_once(
        &self,
        operation_id: &str,
        mut job: Automation,
    ) -> Result<AutomationCreationOutcome, String> {
        self.ensure_jobs_available()?;
        validate_id(operation_id, "creation")?;
        job.name = job.name.trim().to_owned();
        job.prompt = job.prompt.trim().to_owned();
        if is_auto_commit_name(&job.name) {
            return Err(
                "Auto commit is created from the folder, not as a new scheduled job.".into(),
            );
        }
        validate(&job)?;
        job.schedule.validate()?;
        // Server-owned fields are not part of the request.
        job.id.clear();
        job.revision = 0;
        job.last_run_at_ms = None;
        job.next_run_at_ms = None;
        job.last_run_id = None;
        let digest = creation_digest(&job)?;
        let mut live = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut receipts = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(receipt) = receipts.get(operation_id) {
            if receipt.request_digest != digest {
                return Err(
                    "This creation id belongs to a different job draft. Check the original creation."
                        .into(),
                );
            }
            return Ok(creation_outcome(operation_id, receipt, &live));
        }
        job.id = format!("automation-{}", hash(operation_id.as_bytes()));
        if live.iter().any(|saved| saved.id == job.id) {
            return Err("This job identity already exists without its creation receipt.".into());
        }
        job.revision = 1;
        if job.enabled {
            job.next_run_at_ms = job.schedule.next_run_ms(now_ms());
        }
        let created_at_ms = now_ms();
        let receipt = CreationReceipt {
            request_digest: digest,
            job_id: job.id.clone(),
            created_at_ms,
        };
        let mut next_jobs = live.clone();
        next_jobs.push(job);
        let mut next_receipts = receipts.clone();
        next_receipts.insert(operation_id.to_owned(), receipt.clone());
        let queue = *self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let launches = self.launches.lock().unwrap_or_else(PoisonError::into_inner);
        self.write_jobs(&next_jobs, queue, &next_receipts, &launches)?;
        *live = next_jobs;
        *receipts = next_receipts;
        Ok(creation_outcome(operation_id, &receipt, &live))
    }

    /// A read never submits or recreates work, even if the job is now absent.
    pub fn creation_receipt(
        &self,
        operation_id: &str,
    ) -> Result<Option<AutomationCreationOutcome>, String> {
        self.ensure_jobs_available()?;
        validate_id(operation_id, "creation")?;
        let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let receipts = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        Ok(receipts
            .get(operation_id)
            .map(|receipt| creation_outcome(operation_id, receipt, &jobs)))
    }

    fn run_outcome(&self, operation_id: &str, receipt: &LaunchReceipt) -> AutomationRunOutcome {
        let job = self
            .jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|job| job.id == receipt.job_id)
            .cloned();
        AutomationRunOutcome {
            operation_id: operation_id.to_owned(),
            job_id: receipt.job_id.clone(),
            run_id: receipt.run_id.clone(),
            created_at_ms: receipt.created_at_ms,
            job,
            run: self.get_run(&receipt.run_id),
        }
    }

    fn execute_run_claim(
        self: &Arc<Self>,
        operation_id: &str,
        receipt: LaunchReceipt,
    ) -> Result<AutomationRunOutcome, String> {
        if self.get_run(&receipt.run_id).is_none() {
            if self
                .jobs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .iter()
                .all(|job| job.id != receipt.job_id)
            {
                return Ok(self.run_outcome(operation_id, &receipt));
            }
            let result = self.run_task(receipt.job.clone(), receipt.run_id.clone(), false);
            if let Err(error) = result
                && self.get_run(&receipt.run_id).is_none()
            {
                return Err(error);
            }
            if let Some(run) = self.get_run(&receipt.run_id) {
                let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(job) = jobs.iter_mut().find(|job| job.id == receipt.job_id) {
                    job.last_run_at_ms = Some(run.started_at_ms);
                    job.last_run_id = Some(run.id.clone());
                    job.next_run_at_ms = if job.enabled {
                        job.schedule.next_run_ms(now_ms())
                    } else {
                        None
                    };
                }
                drop(jobs);
                let _ = self.save();
            }
        }
        Ok(self.run_outcome(operation_id, &receipt))
    }

    /// Claim one immutable run identity before launching. Later edits of the
    /// job apply to future runs, not this one.
    pub fn run_once(
        self: &Arc<Self>,
        id: &str,
        operation_id: &str,
    ) -> Result<AutomationRunOutcome, String> {
        self.ensure_jobs_available()?;
        self.ensure_runs_available()?;
        validate_id(operation_id, "run")?;
        let digest = launch_digest(id)?;

        let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let creations = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let mut launches = self.launches.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(receipt) = launches.get(operation_id) {
            if receipt.request_digest != digest {
                return Err(
                    "This run id belongs to a different job. Check the original run.".into(),
                );
            }
            let receipt = receipt.clone();
            drop(launches);
            drop(creations);
            drop(jobs);
            return self.execute_run_claim(operation_id, receipt);
        }

        let snapshot = jobs
            .iter()
            .find(|job| job.id == id)
            .cloned()
            .ok_or_else(|| format!("no automation with id {id}"))?;
        let run_id = format!("automation-run-{}", hash(operation_id.as_bytes()));
        let created_at_ms = now_ms();
        let receipt = LaunchReceipt {
            request_digest: digest,
            job_id: id.to_owned(),
            run_id,
            created_at_ms,
            job: snapshot,
        };
        let mut next_launches = launches.clone();
        next_launches.insert(operation_id.to_owned(), receipt.clone());
        let queue = *self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        self.write_jobs(&jobs, queue, &creations, &next_launches)?;
        *launches = next_launches;
        drop(launches);
        drop(creations);
        drop(jobs);
        self.execute_run_claim(operation_id, receipt)
    }

    /// Read a launch receipt without starting or resuming any process.
    pub fn run_receipt(&self, operation_id: &str) -> Result<Option<AutomationRunOutcome>, String> {
        self.ensure_jobs_available()?;
        validate_id(operation_id, "run")?;
        let launches = self.launches.lock().unwrap_or_else(PoisonError::into_inner);
        let receipt = launches.get(operation_id).cloned();
        drop(launches);
        Ok(receipt.map(|receipt| self.run_outcome(operation_id, &receipt)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::automations::{ScheduleSpec, Store};
    use std::sync::Arc;

    const ID: &str = "fixture-create-operation";

    fn draft(name: &str) -> Automation {
        Automation {
            id: String::new(),
            name: name.into(),
            backend: "claude".into(),
            model: None,
            effort: None,
            workspace_id: "w".into(),
            prompt: "do the thing".into(),
            schedule: ScheduleSpec::default(),
            budget_seconds: 60,
            enabled: true,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
            revision: 0,
        }
    }

    #[test]
    fn concurrent_retries_create_one_job_and_deleted_receipt_survives_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        let store = Arc::new(Store::at(path.clone()));
        let first = draft("Nightly");
        let calls: Vec<_> = (0..8)
            .map(|_| {
                let store = store.clone();
                let first = first.clone();
                std::thread::spawn(move || store.create_once(ID, first).unwrap().job_id)
            })
            .collect();
        let ids: Vec<_> = calls.into_iter().map(|call| call.join().unwrap()).collect();
        assert!(ids.iter().all(|id| id == &ids[0]));
        assert_eq!(store.list().len(), 1);
        assert_eq!(store.list()[0].revision, 1);
        let reopened = Store::load_at(path.clone());
        let mut changed = first.clone();
        changed.prompt = "Different prompt".into();
        assert!(reopened.create_once(ID, changed).is_err());
        reopened.remove(&ids[0]).unwrap();
        let reopened = Store::load_at(path);
        assert!(
            reopened
                .creation_receipt(ID)
                .unwrap()
                .unwrap()
                .job
                .is_none()
        );
        assert!(reopened.create_once(ID, first).unwrap().job.is_none());
        assert!(reopened.list().is_empty());
    }

    #[test]
    fn failed_persistence_and_corrupt_stores_cannot_forget_receipts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automations.json");
        std::fs::write(&path, "invalid jobs").unwrap();
        let broken = Store::load_at(path.clone());
        assert!(broken.creation_receipt(ID).is_err());
        assert!(broken.create_once(ID, draft("Nightly")).is_err());
        assert!(broken.create(draft("legacy")).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "invalid jobs");
        let blocked = Store::at(dir.path().to_path_buf());
        assert!(blocked.create_once(ID, draft("Nightly")).is_err());
        assert!(blocked.list().is_empty());
        assert!(blocked.creation_receipt(ID).unwrap().is_none());
    }

    #[test]
    fn auto_commit_stays_off_create_once() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::at(dir.path().join("automations.json"));
        assert!(store.create_once(ID, draft("Auto commit")).is_err());
        assert!(store.list().is_empty());
    }
}
