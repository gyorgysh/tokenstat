// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Lanes: one linked worktree per piece of Team work, and landing it.
//!
//! A lane lives outside every project folder, on its own branch. Landing is
//! the owner's opt-in and runs because a person asked an agent for work:
//! commit the lane, rebase it onto the latest target, run the check command,
//! then fast-forward the target on the remote. Nobody's own working folder is
//! touched, and nothing here runs on a timer.

use super::git_command;
use std::{
    fs::OpenOptions,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

const CHECK_TIME: Duration = Duration::from_secs(20 * 60);
const OUTPUT_TAIL: usize = 4 * 1024;
const PUSH_ATTEMPTS: usize = 3;

/// What a landing attempt ended with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Landing {
    /// The lane has no change against its base.
    Nothing,
    Landed {
        commit: String,
    },
    /// Rebasing onto the target conflicts in these files. The lane is left
    /// as it was before the rebase.
    Conflict {
        files: Vec<String>,
    },
    /// The check command failed on the rebased lane.
    CheckFailed {
        output: String,
    },
    /// Landing cannot happen as configured; the message says why.
    Blocked {
        message: String,
    },
}

fn run(dir: &Path, args: &[&str]) -> Result<String, String> {
    let output = git_command(dir)
        .args(args)
        .output()
        .map_err(|error| error.to_string())?;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if output.status.success() {
        Ok(text)
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// Create a lane on a new branch from `base`. The destination must not exist
/// and its parent must, so a failure cannot leave a stray branch behind.
pub fn create(
    repository: &Path,
    destination: &Path,
    branch: &str,
    base: &str,
) -> Result<(), String> {
    if !destination.is_absolute() || destination.symlink_metadata().is_ok() {
        return Err("The lane folder must be a new absolute path.".into());
    }
    if destination.parent().is_none_or(|parent| !parent.is_dir()) {
        return Err("The lane folder's parent must exist.".into());
    }
    run(repository, &["check-ref-format", "--branch", branch])?;
    let destination = destination
        .to_str()
        .ok_or("The lane path is not valid text.")?;
    run(
        repository,
        &["worktree", "add", "-q", "-b", branch, destination, base],
    )
    .map(|_| ())
}

/// Bring the remote target up to date before cutting a lane from it.
pub fn fetch(repository: &Path, remote: &str, target: &str) -> Result<(), String> {
    run(repository, &["fetch", "-q", remote, target]).map(|_| ())
}

/// Remove a lane and its branch. The branch may already be landed.
pub fn remove(repository: &Path, lane: &Path, branch: &str) -> Result<(), String> {
    let path = lane.to_str().ok_or("The lane path is not valid text.")?;
    if lane.exists() {
        run(repository, &["worktree", "remove", "--force", path])?;
    }
    let _ = run(repository, &["worktree", "prune"]);
    let _ = run(repository, &["branch", "-D", branch]);
    Ok(())
}

/// Commit everything in the lane. Returns false when there was nothing to commit.
pub fn commit_all(lane: &Path, message: &str) -> Result<bool, String> {
    run(lane, &["add", "-A"])?;
    if run(lane, &["diff", "--cached", "--quiet"]).is_ok() {
        return Ok(false);
    }
    let message = if message.trim().is_empty() {
        "Team agent work"
    } else {
        message
    };
    run(lane, &["commit", "-q", "-m", message]).map(|_| true)
}

fn base_ref(lane: &Path, target: &str, remote: Option<&str>) -> Result<String, String> {
    match remote {
        Some(remote) => {
            run(lane, &["fetch", "-q", remote, target])?;
            Ok(format!("{remote}/{target}"))
        }
        None => Ok(target.to_string()),
    }
}

fn conflicted(lane: &Path) -> Vec<String> {
    run(lane, &["diff", "--name-only", "--diff-filter=U"])
        .unwrap_or_default()
        .lines()
        .take(200)
        .map(str::to_string)
        .collect()
}

/// Rebase the lane onto the latest target. On a conflict the rebase is
/// aborted, so the lane keeps its own work unchanged.
pub fn refresh(lane: &Path, target: &str, remote: Option<&str>) -> Landing {
    let base = match base_ref(lane, target, remote) {
        Ok(base) => base,
        Err(message) => return Landing::Blocked { message },
    };
    if run(lane, &["rebase", "-q", &base]).is_err() {
        let files = conflicted(lane);
        let _ = run(lane, &["rebase", "--abort"]);
        return Landing::Conflict { files };
    }
    Landing::Nothing
}

fn tail(bytes: &[u8]) -> String {
    let start = bytes.len().saturating_sub(OUTPUT_TAIL);
    String::from_utf8_lossy(&bytes[start..]).into_owned()
}

/// Run the owner's check command in the lane, bounded in time and output.
fn check(lane: &Path, command: &[String]) -> Result<(), String> {
    let Some((program, args)) = command.split_first() else {
        return Ok(());
    };
    // Outside the working tree, so the log can never be committed.
    let private = run(lane, &["rev-parse", "--absolute-git-dir"])?;
    let log = Path::new(&private).join("tokenstat-check.log");
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&log)
        .map_err(|error| error.to_string())?;
    let errors = file.try_clone().map_err(|error| error.to_string())?;
    let mut child = Command::new(program)
        .args(args)
        .current_dir(lane)
        .stdin(Stdio::null())
        .stdout(file)
        .stderr(errors)
        .spawn()
        .map_err(|error| format!("The check command could not start: {error}"))?;
    let deadline = Instant::now() + CHECK_TIME;
    let status = loop {
        match child.try_wait().map_err(|error| error.to_string())? {
            Some(status) => break Some(status),
            None if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            None => std::thread::sleep(Duration::from_millis(200)),
        }
    };
    let mut output = Vec::new();
    let _ = std::fs::File::open(&log).and_then(|mut file| file.read_to_end(&mut output));
    let _ = std::fs::remove_file(&log);
    match status {
        Some(status) if status.success() => Ok(()),
        Some(_) => Err(tail(&output)),
        None => Err(format!(
            "The check command ran longer than {} minutes.\n{}",
            CHECK_TIME.as_secs() / 60,
            tail(&output)
        )),
    }
}

/// Land a committed lane: rebase onto the latest target, check, and
/// fast-forward the target. With a remote, the target moves on the remote
/// only, and a push that lost a race is retried from a fresh fetch. Without
/// one, the local branch moves only if no worktree has it checked out.
pub fn land(lane: &Path, target: &str, remote: Option<&str>, check_command: &[String]) -> Landing {
    for _ in 0..PUSH_ATTEMPTS {
        match refresh(lane, target, remote) {
            Landing::Nothing => {}
            other => return other,
        }
        let base = remote.map_or_else(|| target.to_string(), |remote| format!("{remote}/{target}"));
        let ahead =
            run(lane, &["rev-list", "--count", &format!("{base}..HEAD")]).unwrap_or_default();
        if ahead == "0" {
            return Landing::Nothing;
        }
        if let Err(output) = check(lane, check_command) {
            return Landing::CheckFailed { output };
        }
        let commit = match run(lane, &["rev-parse", "HEAD"]) {
            Ok(commit) => commit,
            Err(message) => return Landing::Blocked { message },
        };
        match remote {
            Some(remote) => {
                let refspec = format!("HEAD:refs/heads/{target}");
                if run(lane, &["push", "-q", remote, &refspec]).is_ok() {
                    return Landing::Landed { commit };
                }
                // Somebody landed first. Start again from their result.
            }
            None => {
                if checked_out(lane, target) {
                    return Landing::Blocked {
                        message: format!(
                            "{target} is checked out in a folder on this computer. Add a remote to land automatically."
                        ),
                    };
                }
                let old =
                    run(lane, &["rev-parse", &format!("refs/heads/{target}")]).unwrap_or_default();
                return match run(
                    lane,
                    &["update-ref", &format!("refs/heads/{target}"), &commit, &old],
                ) {
                    Ok(_) => Landing::Landed { commit },
                    Err(message) => Landing::Blocked { message },
                };
            }
        }
    }
    Landing::Blocked {
        message: "Other landings kept moving the target. Try again shortly.".into(),
    }
}

fn checked_out(lane: &Path, target: &str) -> bool {
    let wanted = format!("branch refs/heads/{target}");
    run(lane, &["worktree", "list", "--porcelain"])
        .is_ok_and(|list| list.lines().any(|line| line == wanted))
}

/// Where lanes for one checkout live.
pub fn root(data: &Path, checkout: &str) -> PathBuf {
    data.join("team-lanes").join(checkout)
}

#[cfg(test)]
#[path = "lane/tests.rs"]
mod tests;
