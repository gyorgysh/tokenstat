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
    io::{Read, Seek, SeekFrom},
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
    /// Rebased and checked, waiting for a person to land it.
    Ready {
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

/// The host revalidates permission at each effect, and owns the process tree
/// for checks. Keeping that control here also covers a retried push.
pub enum Control<'a> {
    Guard,
    Check(&'a Path, &'a [String]),
}

/// Every lane git command runs with hooks and fsmonitor off. A lane holds
/// files an agent wrote, and neither may make git run them.
fn lane_git(dir: &Path) -> Command {
    let mut command = git_command(dir);
    command.env("GIT_CONFIG_NOSYSTEM", "1").args([
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
    ]);
    command
}

fn run(dir: &Path, args: &[&str]) -> Result<String, String> {
    let output = lane_git(dir)
        .args(args)
        .output()
        .map_err(|error| error.to_string())?;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if output.status.success() {
        Ok(text)
    } else {
        // These errors can appear in a shared chat. Git's stderr may contain
        // an owner's credential-bearing remote URL or local configuration.
        Err(format!(
            "Git could not complete {}.",
            args.first().copied().unwrap_or("the operation")
        ))
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

/// Start a rebase onto the latest target and stop at its conflicts, leaving
/// the conflict markers in the lane for its agent to resolve. Returns the
/// conflicted files, empty when the rebase went through on its own.
pub fn start_rebase(
    lane: &Path,
    target: &str,
    remote: Option<&str>,
) -> Result<Vec<String>, String> {
    let base = base_ref(lane, target, remote)?;
    if run(lane, &["rebase", "-q", &base]).is_ok() {
        return Ok(Vec::new());
    }
    let files = conflicted(lane);
    if files.is_empty() {
        let _ = run(lane, &["rebase", "--abort"]);
        return Err("The rebase stopped without a conflict.".into());
    }
    Ok(files)
}

/// Whether a rebase stopped part way in this lane.
pub fn rebase_in_progress(lane: &Path) -> bool {
    ["rebase-merge", "rebase-apply"].iter().any(|name| {
        run(lane, &["rev-parse", "--git-path", name])
            .map(|path| {
                let path = Path::new(&path);
                if path.is_absolute() {
                    path.to_path_buf()
                } else {
                    lane.join(path)
                }
            })
            .is_ok_and(|path| path.exists())
    })
}

/// Give up a rebase started by `start_rebase`; the lane keeps its own work.
pub fn abort_rebase(lane: &Path) {
    let _ = run(lane, &["rebase", "--abort"]);
}

/// Finish a rebase started by `start_rebase` once the agent resolved it.
/// Any conflict marker left behind aborts the rebase instead.
pub fn finish_rebase(lane: &Path) -> Result<(), String> {
    run(lane, &["add", "-A"])?;
    if run(lane, &["diff", "--cached", "--check"]).is_err() {
        let _ = run(lane, &["rebase", "--abort"]);
        return Err("Conflict markers are still in the files.".into());
    }
    let output = lane_git(lane)
        .env("GIT_EDITOR", "true")
        .args(["rebase", "--continue"])
        .output()
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        let _ = run(lane, &["rebase", "--abort"]);
        return Err("The rebase could not finish.".into());
    }
    Ok(())
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
    let _ = std::fs::File::open(&log).and_then(|mut file| {
        let length = file.metadata()?.len();
        file.seek(SeekFrom::Start(length.saturating_sub(OUTPUT_TAIL as u64)))?;
        file.take(OUTPUT_TAIL as u64).read_to_end(&mut output)
    });
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
    land_with(lane, target, remote, check_command, true)
}

/// Rebase and check like `land`, but stop before the target moves. A person
/// lands it later with `land`, which rebases and checks again.
pub fn prepare(
    lane: &Path,
    target: &str,
    remote: Option<&str>,
    check_command: &[String],
) -> Landing {
    land_with(lane, target, remote, check_command, false)
}

fn land_with(
    lane: &Path,
    target: &str,
    remote: Option<&str>,
    check_command: &[String],
    push: bool,
) -> Landing {
    land_controlled(
        lane,
        target,
        remote,
        check_command,
        push,
        &mut |step| match step {
            Control::Guard => Ok(()),
            Control::Check(lane, command) => check(lane, command),
        },
    )
}

pub fn land_controlled(
    lane: &Path,
    target: &str,
    remote: Option<&str>,
    check_command: &[String],
    push: bool,
    control: &mut impl FnMut(Control<'_>) -> Result<(), String>,
) -> Landing {
    for _ in 0..PUSH_ATTEMPTS {
        if let Err(message) = control(Control::Guard) {
            return Landing::Blocked { message };
        }
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
        if let Err(output) = control(Control::Check(lane, check_command)) {
            return Landing::CheckFailed { output };
        }
        if let Err(message) = control(Control::Guard) {
            return Landing::Blocked { message };
        }
        let commit = match run(lane, &["rev-parse", "HEAD"]) {
            Ok(commit) => commit,
            Err(message) => return Landing::Blocked { message },
        };
        if !push {
            return Landing::Ready { commit };
        }
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

/// What the lane's `.git` file says. Recorded at creation and compared
/// before every later git step, so an edited pointer is never followed.
pub fn pointer(lane: &Path) -> Result<String, String> {
    let meta = std::fs::symlink_metadata(lane.join(".git")).map_err(|error| error.to_string())?;
    if !meta.is_file() || meta.len() > 4096 {
        return Err("The lane's git pointer is not a plain file.".into());
    }
    std::fs::read_to_string(lane.join(".git")).map_err(|error| error.to_string())
}

/// The first link inside the lane that leads outside it, if any. A lane like
/// that is refused: an agent confined to the lane could read through it.
pub fn escaping_link(lane: &Path) -> Result<Option<PathBuf>, String> {
    let root = lane.canonicalize().map_err(|error| error.to_string())?;
    let mut stack = vec![root.clone()];
    let mut seen = 0usize;
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            seen += 1;
            if seen > 500_000 {
                return Err("The project is too large to check for links.".into());
            }
            let path = entry.path();
            if path.file_name().is_some_and(|name| name == ".git") && dir == root {
                continue;
            }
            let kind = entry.file_type().map_err(|error| error.to_string())?;
            if kind.is_symlink() {
                match path.canonicalize() {
                    Ok(target) if target.starts_with(&root) => {}
                    // A dangling link is refused too: what it names may appear later.
                    _ => return Ok(Some(path)),
                }
            } else if kind.is_dir() {
                stack.push(path);
            }
        }
    }
    Ok(None)
}

/// Files the lane changed since it was cut, committed or not. Read only.
pub fn changed_files(lane: &Path, target: Option<&str>) -> Result<Vec<String>, String> {
    let base = run(
        lane,
        &["merge-base", "HEAD", target.unwrap_or("@{upstream}")],
    )
    .or_else(|_| run(lane, &["rev-parse", "HEAD"]))?;
    let mut files: Vec<String> = run(lane, &["diff", "--name-only", &base])?
        .lines()
        .chain(run(lane, &["ls-files", "--others", "--exclude-standard"])?.lines())
        .take(500)
        .map(str::to_string)
        .collect();
    files.sort();
    files.dedup();
    Ok(files)
}

/// What happened when a person's own checkout tried to catch up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatchUp {
    Updated,
    Current,
    /// The folder is on another branch, so it is left alone.
    OtherBranch,
    /// Uncommitted changes. Nobody's unsaved work is ever touched.
    Dirty,
    /// The local branch has its own commits. The person merges, not tokenstat.
    Diverged,
    /// Another writer holds the folder right now.
    Busy,
    Failed(String),
}

/// Bring a person's own checkout up to the target after a teammate landed:
/// a fast-forward only, only on the target branch, only with nothing
/// uncommitted. Hooks stay off, so a landed hook script never runs from a sync.
pub fn catch_up(dir: &Path, target: &str, remote: &str) -> CatchUp {
    let Ok(writer) = crate::writer::Lease::acquire(dir) else {
        return CatchUp::Busy;
    };
    if let Err(message) = run(dir, &["fetch", "-q", remote, target]) {
        return CatchUp::Failed(message);
    }
    if run(dir, &["symbolic-ref", "--quiet", "--short", "HEAD"]).unwrap_or_default() != target {
        return CatchUp::OtherBranch;
    }
    if !run(dir, &["status", "--porcelain", "--untracked-files=normal"])
        .is_ok_and(|status| status.is_empty())
    {
        return CatchUp::Dirty;
    }
    let theirs = format!("{remote}/{target}");
    if run(dir, &["rev-list", "--count", &format!("HEAD..{theirs}")]).as_deref() == Ok("0") {
        return CatchUp::Current;
    }
    if run(dir, &["merge-base", "--is-ancestor", "HEAD", &theirs]).is_err() {
        return CatchUp::Diverged;
    }
    // Fetch can wait on another computer. Do not apply its result to a
    // replacement folder or Git directory that appeared at this path meanwhile.
    if let Err(error) = writer.ensure_current() {
        return CatchUp::Failed(error.to_string());
    }
    match run(
        dir,
        &["merge", "--ff-only", "--no-overwrite-ignore", "-q", &theirs],
    ) {
        Ok(_) => CatchUp::Updated,
        Err(message) => CatchUp::Failed(message),
    }
}

/// Push the lane's branch to the remote under its own name, for a pull
/// request. The target branch is not touched.
pub fn publish_branch(lane: &Path, remote: &str, branch: &str) -> Result<(), String> {
    run(
        lane,
        &["push", "-q", remote, &format!("HEAD:refs/heads/{branch}")],
    )
    .map(|_| ())
}

/// Where lanes for one checkout live.
pub fn root(data: &Path, checkout: &str) -> PathBuf {
    data.join("team-lanes").join(checkout)
}

#[cfg(test)]
#[path = "lane/tests.rs"]
mod tests;
