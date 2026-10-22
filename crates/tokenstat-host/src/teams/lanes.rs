// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Lanes for Team runs on this computer.
//!
//! The publisher turns lanes on per shared checkout and picks the branch work
//! lands on, the remote, and the check command. With lanes on, every Ask runs
//! in its own linked worktree, and when its agent finishes, tokenstat commits,
//! checks and lands the work. Settings stay on this computer.

use crate::error::DispatchError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
use tokenstat_workspace::gitwrite::lane::{self, Landing};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Settings {
    pub enabled: bool,
    pub target: String,
    #[serde(default)]
    pub remote: Option<String>,
    #[serde(default)]
    pub check: Vec<String>,
    /// A check runs code a teammate's agent changed, with the owner's
    /// account. It runs only after the owner said they understand that.
    #[serde(default)]
    pub check_runs_changed_code: bool,
    /// Lanes with review: work stops when it is ready, and a person lands it.
    #[serde(default)]
    pub review: bool,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    version: u32,
    checkouts: BTreeMap<String, Settings>,
}

fn root() -> Result<PathBuf, DispatchError> {
    Ok(tokenstat_paths::data_dir()
        .ok_or_else(unavailable)?
        .join("team-lanes"))
}
fn unavailable() -> DispatchError {
    DispatchError::new(
        "team_lanes_unavailable",
        "Lanes are not available on this computer.",
    )
}
fn invalid() -> DispatchError {
    DispatchError::new("invalid_request", "Check the lane settings and try again.")
}

fn load() -> File {
    root()
        .ok()
        .and_then(|root| fs::read(root.join("settings.json")).ok())
        .filter(|bytes| bytes.len() <= 256 * 1024)
        .and_then(|bytes| serde_json::from_slice::<File>(&bytes).ok())
        .filter(|file| file.version == 1)
        .unwrap_or(File {
            version: 1,
            ..File::default()
        })
}

fn save(file: &File) -> Result<(), DispatchError> {
    let root = root()?;
    fs::create_dir_all(&root).map_err(|_| unavailable())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).map_err(|_| unavailable())?;
    }
    let staged = root.join("settings.json.tmp");
    fs::write(
        &staged,
        serde_json::to_vec(file).map_err(|_| unavailable())?,
    )
    .map_err(|_| unavailable())?;
    fs::rename(staged, root.join("settings.json")).map_err(|_| unavailable())
}

fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 200
        && !value.starts_with('-')
        && !value.contains("..")
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'-' | b'.'))
}

fn validate(settings: &Settings) -> bool {
    valid_name(&settings.target)
        && settings.remote.as_deref().is_none_or(valid_name)
        && (settings.check.is_empty() || settings.check_runs_changed_code)
        && settings.check.len() <= 64
        && settings
            .check
            .iter()
            .all(|arg| !arg.is_empty() && arg.len() <= 4096 && !arg.contains('\0'))
}

/// Lane settings for a checkout, only when lanes are on.
pub(super) fn settings(checkout: &str) -> Option<Settings> {
    load()
        .checkouts
        .get(checkout)
        .filter(|s| s.enabled && validate(s))
        .cloned()
}

/// A lane for one run. Removed on drop unless kept, so a refused or failed
/// Ask never leaves a worktree behind.
pub(super) struct Lane {
    pub path: PathBuf,
    pub branch: String,
    repository: PathBuf,
    pointer: String,
    /// A rebase stopped at its conflicts and waits for the agent's fix.
    rebasing: bool,
    keep: bool,
}
impl Lane {
    pub fn keep(&mut self) {
        self.keep = true;
    }
}
impl Drop for Lane {
    fn drop(&mut self) {
        if !self.keep {
            let _ = lane::remove(&self.repository, &self.path, &self.branch);
            let _ = fs::remove_file(self.path.with_extension("json"));
        }
    }
}

/// What a lane is for, written beside it so members can see who is doing
/// what. Local to this computer; it travels only over the Team channel.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct About {
    branch: String,
    ask: String,
    asked_by: Value,
    started_at_ms: i64,
    /// The shared chat the Ask came from, so Land goes through its scope.
    #[serde(default)]
    share: Option<String>,
    repository: PathBuf,
    pointer: String,
    /// "ready" once checked and waiting for a person, "blocked" otherwise.
    #[serde(default)]
    status: Option<String>,
}

pub(super) fn open(
    repository: &Path,
    checkout: &str,
    settings: &Settings,
    ask: &str,
    asked_by: Value,
    share: Option<String>,
) -> Result<Lane, DispatchError> {
    let failed = |_| {
        DispatchError::new(
            "team_lane_failed",
            "A lane for this work could not be created.",
        )
    };
    let parent = lane::root(
        &tokenstat_paths::data_dir().ok_or_else(unavailable)?,
        checkout,
    );
    fs::create_dir_all(&parent).map_err(|_| unavailable())?;
    let id = format!("{:016x}", rand::random::<u64>());
    let path = parent.join(&id);
    let branch = format!("tokenstat/lane-{id}");
    let base = match &settings.remote {
        Some(remote) => {
            tokenstat_workspace::gitwrite::lane::fetch(repository, remote, &settings.target)
                .map_err(failed)?;
            format!("{remote}/{}", settings.target)
        }
        None => settings.target.clone(),
    };
    lane::create(repository, &path, &branch, &base).map_err(failed)?;
    let mut opened = Lane {
        path,
        branch,
        repository: repository.into(),
        pointer: String::new(),
        rebasing: false,
        keep: false,
    };
    opened.pointer = lane::pointer(&opened.path).map_err(failed)?;
    if lane::escaping_link(&opened.path).map_err(failed)?.is_some() {
        return Err(DispatchError::new(
            "team_lane_link",
            "This project has a link that leads outside it, so an agent cannot work in it safely.",
        ));
    }
    let about = About {
        branch: opened.branch.clone(),
        ask: ask
            .lines()
            .next()
            .unwrap_or_default()
            .chars()
            .take(200)
            .collect(),
        asked_by,
        share,
        repository: opened.repository.clone(),
        pointer: opened.pointer.clone(),
        status: Some("running".into()),
        started_at_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or_default(),
    };
    fs::write(
        opened.path.with_extension("json"),
        serde_json::to_vec(&about).map_err(|_| unavailable())?,
    )
    .map_err(|_| unavailable())?;
    Ok(opened)
}

/// Lanes for one checkout on this computer: who asked for what, which files
/// each has changed so far, and which lanes touch the same files. A lane is
/// running while an agent holds it, and kept when its work could not land.
pub(super) fn list(checkout: &str, share: Option<&str>) -> Result<Value, DispatchError> {
    let parent = lane::root(
        &tokenstat_paths::data_dir().ok_or_else(unavailable)?,
        checkout,
    );
    let mut lanes = Vec::new();
    if let Ok(entries) = fs::read_dir(&parent) {
        for path in entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .take(64)
        {
            let Some(about) = fs::read(path.with_extension("json"))
                .ok()
                .filter(|bytes| bytes.len() <= 16 * 1024)
                .and_then(|bytes| serde_json::from_slice::<About>(&bytes).ok())
            else {
                continue;
            };
            // A connection scoped to one shared chat sees that chat's lanes only.
            if share.is_some() && about.share.as_deref() != share {
                continue;
            }
            // Read from the lane's own record: taking its lock here could make
            // a new Ask's own lock fail.
            let running = about.status.as_deref() == Some("running");
            let files = lane::changed_files(&path).unwrap_or_default();
            lanes.push((about, running, files));
        }
    }
    lanes.sort_by_key(|(about, _, _)| about.started_at_ms);
    let rows: Vec<Value> = lanes
        .iter()
        .map(|(about, running, files)| {
            let overlaps: Vec<&str> = lanes
                .iter()
                .filter(|(other, _, theirs)| {
                    other.branch != about.branch && theirs.iter().any(|file| files.contains(file))
                })
                .map(|(other, _, _)| other.branch.as_str())
                .collect();
            json!({"branch":about.branch,"ask":about.ask,"askedBy":about.asked_by,"startedAtMs":about.started_at_ms,
                "state": if *running { "running" } else if about.status.as_deref() == Some("ready") { "ready" } else { "kept" },
                "share":about.share,"files":files,"overlaps":overlaps})
        })
        .collect();
    Ok(json!({"lanes": rows}))
}

/// Commit, check and land one finished lane. One landing at a time per
/// checkout on this computer, so each lands onto the one before it.
pub(super) fn finish(lane: &mut Lane, settings: &Settings, message: &str) -> Landing {
    settle(lane, settings, message, false)
}

/// Land again after the agent worked on a conflict or a failed check.
pub(super) fn finish_fix(lane: &mut Lane, settings: &Settings, message: &str) -> Landing {
    settle(lane, settings, message, true)
}

/// One landing at a time per checkout on this computer, across processes.
fn landing_lock(lane: &Path) -> Option<fs::File> {
    let path = root()
        .ok()?
        .join(format!("{}.landing", lane.parent()?.file_name()?.to_str()?));
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
        .ok()?;
    file.lock().ok()?;
    Some(file)
}

fn settle(lane: &mut Lane, settings: &Settings, message: &str, after_fix: bool) -> Landing {
    let lock = landing_lock(&lane.path);
    if lock.is_none() {
        lane.keep();
        return Landing::Blocked {
            message: "Another landing could not be waited for.".into(),
        };
    }
    // The agent could edit files in the lane. Its git pointer must still be
    // the one tokenstat created, or git would follow the agent's choice.
    if lane::pointer(&lane.path).ok().as_deref() != Some(lane.pointer.as_str()) {
        lane.keep();
        return Landing::Blocked {
            message: "The lane's git link was changed.".into(),
        };
    }
    if lane.rebasing {
        lane.rebasing = false;
        if let Err(message) = lane::finish_rebase(&lane.path) {
            lane.keep();
            return Landing::Blocked { message };
        }
    }
    match lane::commit_all(&lane.path, message) {
        Ok(false) if !after_fix => return Landing::Nothing,
        Ok(_) => {}
        Err(message) => {
            lane.keep();
            return Landing::Blocked { message };
        }
    }
    let landing = if settings.review {
        lane::prepare(
            &lane.path,
            &settings.target,
            settings.remote.as_deref(),
            &settings.check,
        )
    } else {
        lane::land(
            &lane.path,
            &settings.target,
            settings.remote.as_deref(),
            &settings.check,
        )
    };
    // A lane kept by an earlier attempt is done once its work landed.
    lane.keep = !matches!(landing, Landing::Landed { .. });
    mark(&lane.path, matches!(landing, Landing::Ready { .. }));
    landing
}

/// What happens after a landing that did not go through.
pub(super) enum Next {
    /// Run the agent again in the same lane with this instruction.
    Agent(String),
    Done(Landing),
}

/// Turn a conflict or a failed check into the agent's next instruction.
/// A conflict starts the rebase and leaves its markers in the lane.
pub(super) fn next_step(
    lane: &mut Lane,
    settings: &Settings,
    landing: Landing,
    message: &str,
) -> Next {
    match landing {
        Landing::Conflict { .. } => {
            match lane::start_rebase(&lane.path, &settings.target, settings.remote.as_deref()) {
                Ok(files) if !files.is_empty() => {
                    // The rebase brought in teammates' files. An agent goes
                    // back in only if no link leads out of the lane now.
                    if !matches!(lane::escaping_link(&lane.path), Ok(None)) {
                        lane::abort_rebase(&lane.path);
                        lane.keep();
                        return Next::Done(Landing::Blocked {
                            message: "The project now has a link that leads outside it.".into(),
                        });
                    }
                    lane.rebasing = true;
                    Next::Agent(format!(
                        "Work that landed on {} while you worked conflicts with your change in: {}. Those files now contain conflict markers (<<<<<<<, =======, >>>>>>>). Edit them so both changes work together and remove every marker. Change nothing else. tokenstat finishes the merge and lands it after you finish.",
                        settings.target,
                        files.join(", ")
                    ))
                }
                // The target moved again and the conflict went with it.
                Ok(_) => Next::Done(finish_fix(lane, settings, message)),
                Err(message) => Next::Done(Landing::Blocked { message }),
            }
        }
        // The owner turned checks on knowing they run changed code, so the
        // agent may read what its own change made the check print.
        Landing::CheckFailed { .. } if !matches!(lane::escaping_link(&lane.path), Ok(None)) => {
            Next::Done(Landing::Blocked {
                message: "The project now has a link that leads outside it.".into(),
            })
        }
        Landing::CheckFailed { output } => Next::Agent(format!(
            "The project check failed after your change. Fix the cause by editing files in this folder. tokenstat runs the check again after you finish. The check printed:\n```\n{}\n```",
            output.trim()
        )),
        other => Next::Done(other),
    }
}

/// A teammate landed work on `repository`. Each automatic-lanes checkout of
/// it on this computer fast-forwards when it safely can, and lanes kept from
/// earlier runs rebase onto the new target while no agent is in them.
pub(crate) fn caught_up(repository: &str) {
    let Ok(store) = super::publications::Store::capture() else {
        return;
    };
    let Ok(rows) = store.active_for_repository(repository) else {
        return;
    };
    let Some(data) = tokenstat_paths::data_dir() else {
        return;
    };
    for row in rows {
        let Some(settings) = settings(&row.id) else {
            continue;
        };
        let Some(remote) = settings.remote.as_deref() else {
            continue;
        };
        let Ok(workspace) = crate::workspaces::get(&row.workspace_id) else {
            continue;
        };
        // The folder must still be the one that was published.
        if super::publications::Folder::capture(&workspace.path)
            .ok()
            .as_ref()
            != Some(&row.folder)
        {
            continue;
        }
        let _ = lane::catch_up(&row.folder.canonical, &settings.target, remote);
        let Ok(kept) = fs::read_dir(lane::root(&data, &row.id)) else {
            continue;
        };
        for entry in kept.flatten().take(64) {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let status = fs::read(path.with_extension("json"))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<About>(&bytes).ok())
                .and_then(|about| about.status);
            if status.as_deref() == Some("running") || lane::rebase_in_progress(&path) {
                continue;
            }
            // A lease held means an agent is working in that lane right now.
            if let Ok(_lease) = tokenstat_workspace::writer::Lease::acquire_lane(&path) {
                let _ = lane::refresh(&path, &settings.target, Some(remote));
            }
        }
    }
}

/// Land a lane that waits for review. Only the person who asked, a
/// maintainer or the publisher may, through a verified Run connection.
pub(super) fn land_ready(
    principal: &super::AuthorizedTeamPrincipal,
    params: &str,
) -> Result<Value, DispatchError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct LandInput {
        branch: String,
    }
    principal.run_ticket()?;
    if params.len() > 1024 {
        return Err(invalid());
    }
    let input: LandInput = serde_json::from_str(params).map_err(|_| invalid())?;
    let value = principal.value();
    super::publications::Store::current_for(principal)?;
    let settings = settings(&value.checkout_id)
        .filter(|settings| settings.review)
        .ok_or_else(unavailable)?;
    let parent = lane::root(
        &tokenstat_paths::data_dir().ok_or_else(unavailable)?,
        &value.checkout_id,
    );
    let found = fs::read_dir(&parent)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .find_map(|path| {
            let about =
                serde_json::from_slice::<About>(&fs::read(path.with_extension("json")).ok()?)
                    .ok()?;
            (about.branch == input.branch).then_some((path, about))
        });
    let Some((path, about)) = found.filter(|(_, about)| about.status.as_deref() == Some("ready"))
    else {
        return Ok(json!({"landed":false,"message":"This work is no longer waiting."}));
    };
    let asker = about
        .asked_by
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if about.share != value.share_id
        || !(value.person.id == asker
            || value.person.id == value.publisher_id
            || value.role == tokenstat_sync::teams::RepositoryRole::Maintainer)
    {
        return Err(DispatchError::new(
            "team_land_forbidden",
            "Only the person who asked, a maintainer or the publisher can land this work.",
        ));
    }
    let _lease = tokenstat_workspace::writer::Lease::acquire_lane(&path).map_err(|_| {
        DispatchError::new("team_lane_busy", "An agent is still working in this lane.")
    })?;
    if lane::pointer(&path).ok().as_deref() != Some(about.pointer.as_str())
        || lane::rebase_in_progress(&path)
        || !matches!(lane::escaping_link(&path), Ok(None))
    {
        return Err(DispatchError::new(
            "team_lane_changed",
            "This lane changed since it was ready. Ask the agent again.",
        ));
    }
    let _landing = landing_lock(&path)
        .ok_or_else(|| DispatchError::new("team_lane_busy", "Another landing is still running."))?;
    principal.ensure_live()?;
    let mut lane = Lane {
        path: path.clone(),
        branch: about.branch.clone(),
        repository: about.repository.clone(),
        pointer: about.pointer.clone(),
        rebasing: false,
        keep: true,
    };
    let landing = lane::land(
        &path,
        &settings.target,
        settings.remote.as_deref(),
        &settings.check,
    );
    let landed = matches!(landing, Landing::Landed { .. });
    let message = describe(&landing, &lane, &settings);
    if landed {
        lane.keep = false;
        if let Ok(client) = principal.account_client() {
            let _ = client.checkout_moved(&value.organization_id, &value.checkout_id);
        }
    } else {
        mark(&path, false);
    }
    drop(lane);
    Ok(json!({"landed":landed,"message":message}))
}

/// After a relay registration: catch up every repository that moved since
/// this computer last looked. Sequences seen are kept beside the settings.
pub(crate) fn caught_up_since_last_seen(client: &tokenstat_sync::teams::TeamClient) {
    let Ok(moves) = client.my_moves() else {
        return;
    };
    let Ok(root) = root() else {
        return;
    };
    let file = root.join("moves-seen.json");
    let mut seen: BTreeMap<String, u64> = fs::read(&file)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    let mut changed = false;
    for row in moves["moves"].as_array().into_iter().flatten().take(1000) {
        let (Some(repository), Some(sequence)) =
            (row["repositoryId"].as_str(), row["sequence"].as_u64())
        else {
            continue;
        };
        if seen.get(repository).is_some_and(|known| *known >= sequence) {
            continue;
        }
        caught_up(repository);
        seen.insert(repository.into(), sequence);
        changed = true;
    }
    if changed
        && fs::create_dir_all(&root).is_ok()
        && let Ok(bytes) = serde_json::to_vec(&seen)
    {
        let _ = fs::write(file, bytes);
    }
}

/// What the shared chat reads after a run, in plain words.
/// The run ended without its work landing. A rebase stopped for the agent
/// is given up, so the lane keeps its own commits and nothing half done.
pub(super) fn abandon(lane: &mut Lane) {
    if lane.rebasing {
        lane.rebasing = false;
        lane::abort_rebase(&lane.path);
    }
    mark(&lane.path, false);
}

/// Record whether a kept lane is ready to land or blocked.
fn mark(path: &Path, ready: bool) {
    let file = path.with_extension("json");
    if let Some(mut about) = fs::read(&file)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<About>(&bytes).ok())
    {
        about.status = Some(if ready { "ready" } else { "blocked" }.into());
        if let Ok(bytes) = serde_json::to_vec(&about) {
            let _ = fs::write(file, bytes);
        }
    }
}

pub(super) fn describe(landing: &Landing, lane: &Lane, settings: &Settings) -> String {
    match landing {
        Landing::Ready { .. } => format!(
            "Ready to land on {}: committed, rebased and checked. The person who asked, a maintainer or the publisher can land it from Work in progress.",
            settings.target
        ),
        Landing::Nothing => "The agent made no changes, so nothing was landed.".into(),
        Landing::Landed { commit } => format!(
            "Landed on {} as {}.",
            settings.target,
            &commit[..commit.len().min(12)]
        ),
        Landing::Conflict { files } => format!(
            "Not landed: this work conflicts with {} in {}. It is kept on branch {}.",
            settings.target,
            files.join(", "),
            lane.branch
        ),
        // The output can hold anything the changed code printed. It stays on
        // this computer and never goes into the shared chat.
        Landing::CheckFailed { .. } => format!(
            "Not landed: the check failed. It is kept on branch {}.",
            lane.branch
        ),
        Landing::Blocked { message } => format!(
            "Not landed: {message} It is kept on branch {}.",
            lane.branch
        ),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    checkout: String,
    #[serde(default)]
    settings: Option<Settings>,
}

/// `teams.lanes.get` and `teams.lanes.set`, for the publisher on this computer.
pub(super) fn call(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    if !matches!(method, "teams.lanes.get" | "teams.lanes.set") {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("Team lane settings").map_err(|_| {
            DispatchError::new(
                "local_only",
                "Change lane settings on the publishing computer.",
            )
        })?;
        if params.len() > 64 * 1024 {
            return Err(invalid());
        }
        // The app's Team client adds its account receipt to every call.
        let mut body: Value = serde_json::from_str(params).map_err(|_| invalid())?;
        if let Some(object) = body.as_object_mut() {
            object.remove("_accountScope");
            object.remove("_accountSession");
        }
        let input: Input = serde_json::from_value(body).map_err(|_| invalid())?;
        if input.checkout.is_empty()
            || input.checkout.len() > 128
            || !input
                .checkout
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err(invalid());
        }
        let mut file = load();
        if method == "teams.lanes.set" {
            let settings = input.settings.ok_or_else(invalid)?;
            if !validate(&settings) {
                return Err(invalid());
            }
            file.checkouts.insert(input.checkout.clone(), settings);
            save(&file)?;
        }
        Ok(json!({"settings": file.checkouts.get(&input.checkout)}))
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(target: &str, remote: Option<&str>, check: &[&str]) -> Settings {
        Settings {
            enabled: true,
            target: target.into(),
            remote: remote.map(str::to_string),
            check: check.iter().map(|s| s.to_string()).collect(),
            check_runs_changed_code: true,
            review: false,
        }
    }

    #[test]
    fn names_that_git_could_read_as_options_are_refused() {
        assert!(validate(&settings(
            "main",
            Some("origin"),
            &["cargo", "test"]
        )));
        assert!(validate(&settings("release/1.8", None, &[])));
        for target in ["", "-x", "a..b", "main branch", "main;rm"] {
            assert!(!validate(&settings(target, None, &[])), "{target}");
        }
        assert!(!validate(&settings("main", Some("--upload-pack=x"), &[])));
        assert!(!validate(&settings("main", None, &["bad\0arg"])));
        let mut unacknowledged = settings("main", None, &["make", "check"]);
        unacknowledged.check_runs_changed_code = false;
        assert!(!validate(&unacknowledged));
    }
}
