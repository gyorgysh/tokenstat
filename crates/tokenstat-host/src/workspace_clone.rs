// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Getting a repository onto a machine that has none.
//!
//! A folder has to exist before it can be registered, and on a fresh server
//! nothing does. This is the one step that fills that gap, and it runs in a
//! **terminal** rather than as a captured command. Three reasons, all of them
//! about what a person sees:
//!
//! - the existing terminal stream already carries progress, so there is no new
//!   kind of stream to invent,
//! - a clone that wants a passphrase or an unknown host key can be answered,
//! - a clone that hangs looks like a terminal that has stopped moving, rather
//!   than a spinner that never ends.
//!
//! It mutates, so the rules of `gitwrite` apply: it runs because a person
//! pressed a button, and never from a watcher or a timer. The one background
//! thread here waits for that command to finish and registers what it made. It
//! starts nothing of its own.
//!
//! Nothing is ever deleted, including a clone that failed halfway. It is
//! somebody's disk.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Clone)]
struct Job {
    path: PathBuf,
    /// `None` while it runs, then the folder it registered or why it did not.
    outcome: Option<Result<String, String>>,
}

fn jobs() -> &'static Mutex<HashMap<String, Job>> {
    static JOBS: OnceLock<Mutex<HashMap<String, Job>>> = OnceLock::new();
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CloneParams {
    url: String,
    parent: String,
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatusParams {
    session_id: String,
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "workspace.clone" => start(params),
        "workspace.cloneStatus" => status(params),
        _ => return None,
    })
}

fn start(params: &str) -> Result<Value, String> {
    let p: CloneParams = serde_json::from_str(params.trim()).map_err(|error| error.to_string())?;
    // The same roots as the folder picker, so a clone cannot land somewhere
    // browsing would not have shown.
    let parent = crate::fs_browse::resolve_root(std::path::Path::new(&p.parent))?;
    let name = match p.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        Some(name) => name.to_string(),
        None => tokenstat_workspace::gitwrite::name_from_url(&p.url)
            .ok_or("That address does not say what to call the folder. Give it a name.")?,
    };
    let args = tokenstat_workspace::gitwrite::clone_command(&p.url, &name)?;
    let target = parent.join(&name);
    if target.exists() {
        return Err(format!(
            "{name} is already there. Pick another name, or add that folder instead."
        ));
    }
    let info = tokenstat_pty::manager()
        .spawn(&tokenstat_pty::Spawn {
            command: "git".into(),
            args,
            cwd: parent,
            workspace_id: None,
            hidden: false,
            rows: 24,
            cols: 100,
            no_color: false,
            dark: None,
            environment: Vec::new(),
        })
        .map_err(|error| error.to_string())?;
    if let Ok(mut jobs) = jobs().lock() {
        jobs.insert(
            info.id.clone(),
            Job {
                path: target.clone(),
                outcome: None,
            },
        );
    }
    watch(info.id.clone());
    let mut value = serde_json::to_value(&info).map_err(|error| error.to_string())?;
    value["sessionId"] = json!(info.id);
    value["path"] = json!(target);
    value["name"] = json!(name);
    Ok(value)
}

/// Wait for the command a person started, and register what it made.
///
/// A thread rather than registering on the next poll, so the answer does not
/// depend on somebody still watching: an app closed mid-clone must not leave a
/// folder on disk that the machine does not know about.
fn watch(session: String) {
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_millis(400));
            let info = match tokenstat_pty::manager().info(&session) {
                Ok(info) => info,
                // The session is gone before it exited: nothing was seen, so
                // nothing is claimed.
                Err(_) => return finish(&session, Err("The clone stopped before it finished.")),
            };
            if info.alive {
                continue;
            }
            let path = match jobs()
                .lock()
                .ok()
                .and_then(|jobs| jobs.get(&session).map(|job| job.path.clone()))
            {
                Some(path) => path,
                None => return,
            };
            if info.exit_code != Some(0) || !path.join(".git").exists() {
                return finish(
                    &session,
                    Err(
                        "The clone did not finish. The terminal above says why, and nothing was removed.",
                    ),
                );
            }
            let registered = {
                let mut registry = crate::workspaces::write();
                let folder = registry.add(&path, jiff::Timestamp::now().as_millisecond());
                match folder {
                    Ok(folder) => crate::workspaces::save(&registry).map(|()| folder.id),
                    Err(error) => Err(error.to_string()),
                }
            };
            return match registered {
                Ok(id) => finish_ok(&session, id),
                Err(error) => finish(&session, Err(&error)),
            };
        }
    });
}

fn finish(session: &str, outcome: Result<String, &str>) {
    if let Ok(mut jobs) = jobs().lock()
        && let Some(job) = jobs.get_mut(session)
    {
        job.outcome = Some(outcome.map_err(str::to_owned));
    }
}

fn finish_ok(session: &str, id: String) {
    finish(session, Ok(id));
}

fn status(params: &str) -> Result<Value, String> {
    let p: StatusParams = serde_json::from_str(params.trim()).map_err(|error| error.to_string())?;
    let job = jobs()
        .lock()
        .ok()
        .and_then(|jobs| jobs.get(&p.session_id).cloned())
        .ok_or("That clone is not one this machine started.")?;
    Ok(match job.outcome {
        None => json!({"state": "running", "path": job.path}),
        Some(Ok(id)) => json!({"state": "done", "path": job.path, "workspaceId": id}),
        Some(Err(error)) => json!({"state": "failed", "path": job.path, "error": error}),
    })
}
