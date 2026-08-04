//! Daemon-owned recurring jobs.
//!
//! Automations are deliberately separate from `tokenstat_workspace::gitwrite`.
//! This module owns persistence, scheduling, and the PTY budget. A job may run
//! an agent that changes a repository, but no timer calls a gitwrite function.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::session::Session;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Automation {
    pub id: String,
    pub name: String,
    pub workspace_id: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub interval_seconds: u64,
    pub budget_seconds: u64,
    pub enabled: bool,
    pub last_run_at_ms: Option<i64>,
    pub next_run_at_ms: Option<i64>,
    pub last_run_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct File {
    #[serde(default)]
    jobs: Vec<Automation>,
}

pub struct Store {
    path: PathBuf,
    jobs: Mutex<Vec<Automation>>,
}

pub fn shared() -> Arc<Store> {
    static STORE: std::sync::OnceLock<Arc<Store>> = std::sync::OnceLock::new();
    Arc::clone(STORE.get_or_init(|| Arc::new(Store::load())))
}

impl Store {
    #[cfg(test)]
    fn from_path(path: PathBuf) -> Store {
        Store {
            jobs: Mutex::new(Vec::new()),
            path,
        }
    }

    pub fn load() -> Store {
        let path = Self::default_path().unwrap_or_else(|_| PathBuf::from("automations.json"));
        let jobs = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<File>(&text).ok())
            .map(|file| file.jobs)
            .unwrap_or_default();
        Store {
            path,
            jobs: Mutex::new(jobs),
        }
    }

    fn default_path() -> Result<PathBuf, String> {
        let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .ok_or("no data directory on this platform")?;
        Ok(dirs.data_dir().join("automations.json"))
    }

    fn save(&self, jobs: &[Automation]) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        let tmp = self.path.with_extension("json.tmp");
        let body = serde_json::to_string_pretty(&File {
            jobs: jobs.to_vec(),
        })
        .map_err(|e| e.to_string())?;
        std::fs::write(&tmp, body).map_err(|e| format!("{}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, &self.path).map_err(|e| format!("{}: {e}", self.path.display()))
    }

    pub fn list(&self) -> Vec<Automation> {
        self.jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn create(&self, mut job: Automation) -> Result<Automation, String> {
        validate(&job)?;
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        if jobs.iter().any(|existing| existing.id == job.id) {
            return Err(format!("an automation with id {} already exists", job.id));
        }
        if job.id.is_empty() {
            job.id = format!("automation-{}", now_ms());
        }
        if job.enabled {
            job.next_run_at_ms = Some(now_ms() + job.interval_seconds as i64 * 1000);
        }
        jobs.push(job.clone());
        self.save(&jobs)?;
        Ok(job)
    }

    pub fn update(&self, job: Automation) -> Result<Automation, String> {
        validate(&job)?;
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let current = jobs
            .iter_mut()
            .find(|existing| existing.id == job.id)
            .ok_or_else(|| format!("no automation with id {}", job.id))?;
        let last_run_at_ms = current.last_run_at_ms;
        let last_run_id = current.last_run_id.clone();
        *current = job;
        current.last_run_at_ms = last_run_at_ms;
        current.last_run_id = last_run_id;
        if !current.enabled {
            current.next_run_at_ms = None;
        } else if current.next_run_at_ms.is_none() {
            current.next_run_at_ms = Some(now_ms() + current.interval_seconds as i64 * 1000);
        }
        let result = current.clone();
        self.save(&jobs)?;
        Ok(result)
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<Automation, String> {
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let job = jobs
            .iter_mut()
            .find(|job| job.id == id)
            .ok_or_else(|| format!("no automation with id {id}"))?;
        job.enabled = enabled;
        job.next_run_at_ms = enabled.then_some(now_ms() + job.interval_seconds as i64 * 1000);
        let result = job.clone();
        self.save(&jobs)?;
        Ok(result)
    }

    pub fn remove(&self, id: &str) -> Result<bool, String> {
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let old = jobs.len();
        jobs.retain(|job| job.id != id);
        if old != jobs.len() {
            self.save(&jobs)?;
        }
        Ok(old != jobs.len())
    }

    /// Run one job immediately, or one due job from the scheduler.
    pub fn run(&self, id: &str, session: &Session) -> Result<Automation, String> {
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let job = jobs
            .iter_mut()
            .find(|job| job.id == id)
            .ok_or_else(|| format!("no automation with id {id}"))?;
        let workspace = session
            .workspaces
            .get(&job.workspace_id)
            .ok_or_else(|| format!("no workspace with id {}", job.workspace_id))?;
        if !workspace.exists() {
            return Err(format!(
                "the folder is missing: {}",
                workspace.path.display()
            ));
        }
        let info = tokenstat_pty::manager()
            .spawn(&tokenstat_pty::Spawn {
                command: job.command.clone(),
                args: job.args.clone(),
                cwd: workspace.path.clone(),
                workspace_id: Some(workspace.id.clone()),
                rows: 24,
                cols: 80,
            })
            .map_err(|e| e.to_string())?;
        let id_for_budget = info.id.clone();
        let budget = job.budget_seconds;
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(budget));
            let _ = tokenstat_pty::manager().kill(&id_for_budget);
        });
        job.last_run_at_ms = Some(now_ms());
        job.last_run_id = Some(info.id);
        job.next_run_at_ms = job
            .enabled
            .then_some(now_ms() + job.interval_seconds as i64 * 1000);
        let result = job.clone();
        self.save(&jobs)?;
        Ok(result)
    }

    pub fn run_due(&self, session: &Session) {
        let now = now_ms();
        let ids: Vec<String> = self
            .list()
            .into_iter()
            .filter(|job| job.enabled && job.next_run_at_ms.is_some_and(|at| at <= now))
            .map(|job| job.id)
            .collect();
        for id in ids {
            let _ = self.run(&id, session);
        }
    }
}

pub fn start_scheduler(session: Arc<Mutex<Session>>) {
    let store = shared();
    std::thread::spawn(move || {
        loop {
            if let Ok(guard) = session.lock() {
                store.run_due(&guard);
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
}

fn validate(job: &Automation) -> Result<(), String> {
    if job.name.trim().is_empty() {
        return Err("an automation needs a name".into());
    }
    if job.workspace_id.is_empty() {
        return Err("an automation needs a workspace".into());
    }
    if job.command.trim().is_empty() {
        return Err("an automation needs a command".into());
    }
    if job.interval_seconds == 0 {
        return Err("interval must be at least one second".into());
    }
    if job.budget_seconds == 0 {
        return Err("budget must be at least one second".into());
    }
    Ok(())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_rejects_unbounded_jobs() {
        let job = Automation {
            id: "a".into(),
            name: "a".into(),
            workspace_id: "w".into(),
            command: "sh".into(),
            args: vec![],
            interval_seconds: 0,
            budget_seconds: 1,
            enabled: false,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
        };
        assert!(validate(&job).is_err());
    }

    #[test]
    fn budget_kills_the_host_owned_pty() {
        let dir = std::env::temp_dir().join(format!("tokenstat-automation-{}", now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut session = Session::open(&crate::session::OpenParams {
            db_path: Some(dir.join("archive.db").display().to_string()),
            timezone: Some("UTC".into()),
        })
        .unwrap();
        let workspace = session.workspaces.add(&dir, now_ms()).unwrap();
        let store = Store::from_path(dir.join("jobs.json"));
        let job = store
            .create(Automation {
                id: "budget-test".into(),
                name: "budget test".into(),
                workspace_id: workspace.id,
                command: "/bin/sh".into(),
                args: vec!["-c".into(), "sleep 30".into()],
                interval_seconds: 60,
                budget_seconds: 1,
                enabled: false,
                last_run_at_ms: None,
                next_run_at_ms: None,
                last_run_id: None,
            })
            .unwrap();
        let run = store.run(&job.id, &session).unwrap();
        std::thread::sleep(Duration::from_millis(1_200));
        let info = tokenstat_pty::manager()
            .info(run.last_run_id.as_deref().unwrap())
            .unwrap();
        assert!(!info.alive, "budget did not kill {}", info.id);
        let _ = tokenstat_pty::manager().close(&info.id);
        let _ = std::fs::remove_dir_all(dir);
    }
}
