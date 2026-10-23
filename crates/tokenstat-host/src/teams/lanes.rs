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
    io::{Read, Write},
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
    /// With review on: open a pull request for ready work instead of waiting
    /// for Land, for repositories where changes go through review.
    #[serde(default)]
    pub pull_request: bool,
    /// The owner also permits clean target-checkout updates in Manual or
    /// Review mode. Omitting false preserves the older settings format.
    #[serde(default, skip_serializing_if = "is_false")]
    pub update_checkout: bool,
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl Settings {
    fn updates_checkout(&self) -> bool {
        (self.enabled && !self.review) || self.update_checkout
    }
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

const SETTINGS_MAX_BYTES: u64 = 256 * 1024;

fn settings_storage() -> DispatchError {
    DispatchError::new(
        "team_lanes_storage",
        "Lane settings could not be read or saved. Check their storage and try again.",
    )
}

fn load() -> Result<File, DispatchError> {
    load_at(&root()?)
}

fn load_at(root: &Path) -> Result<File, DispatchError> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = match options.open(root.join("settings.json")) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(File {
                version: 1,
                ..File::default()
            });
        }
        Err(_) => return Err(settings_storage()),
    };
    let metadata = file.metadata().map_err(|_| settings_storage())?;
    if !metadata.is_file() || metadata.len() > SETTINGS_MAX_BYTES {
        return Err(settings_storage());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(settings_storage());
        }
    }
    let mut bytes = Vec::new();
    file.take(SETTINGS_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| settings_storage())?;
    if bytes.len() as u64 > SETTINGS_MAX_BYTES {
        return Err(settings_storage());
    }
    let file: File = serde_json::from_slice(&bytes).map_err(|_| settings_storage())?;
    if file.version != 1
        || file
            .checkouts
            .iter()
            .any(|(checkout, settings)| !valid_checkout(checkout) || !validate(settings))
    {
        return Err(settings_storage());
    }
    Ok(file)
}

fn update_settings_at(
    root: &Path,
    checkout: String,
    settings: Settings,
) -> Result<File, DispatchError> {
    let mut directory = fs::DirBuilder::new();
    directory.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directory.mode(0o700);
    }
    directory.create(root).map_err(|_| settings_storage())?;
    let metadata = fs::symlink_metadata(root).map_err(|_| settings_storage())?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(settings_storage());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700))
            .map_err(|_| settings_storage())?;
    }
    let started = std::time::Instant::now();
    let _lease = loop {
        if let Some(lease) =
            crate::chat_receipts::OwnerLease::try_acquire(&root.join("settings.lock"))
                .map_err(|_| settings_storage())?
        {
            break lease;
        }
        if started.elapsed() >= std::time::Duration::from_secs(2) {
            return Err(DispatchError::new(
                "team_lanes_busy",
                "Another lane settings change is being saved. Try again shortly.",
            ));
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    };
    // Reload after acquiring the cross-process lease: independent checkout
    // saves must preserve one another's entries and any unreadable old state.
    let mut file = load_at(root)?;
    file.checkouts.insert(checkout, settings);
    let bytes = serde_json::to_vec(&file).map_err(|_| settings_storage())?;
    if bytes.len() as u64 > SETTINGS_MAX_BYTES {
        return Err(settings_storage());
    }
    let mut staged = tempfile::Builder::new()
        .prefix(".settings-")
        .tempfile_in(root)
        .map_err(|_| settings_storage())?;
    staged
        .write_all(&bytes)
        .and_then(|()| staged.as_file().sync_all())
        .map_err(|_| settings_storage())?;
    for attempt in 0..=50 {
        match staged.persist(root.join("settings.json")) {
            Ok(_) => {
                #[cfg(unix)]
                fs::File::open(root)
                    .and_then(|directory| directory.sync_all())
                    .map_err(|_| settings_storage())?;
                return Ok(file);
            }
            Err(error)
                if cfg!(windows)
                    && error.error.kind() == std::io::ErrorKind::PermissionDenied
                    && attempt < 50 =>
            {
                staged = error.file;
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(_) => return Err(settings_storage()),
        }
    }
    Err(settings_storage())
}

fn valid_checkout(checkout: &str) -> bool {
    !checkout.is_empty()
        && checkout.len() <= 128
        && checkout
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
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
        && (!settings.update_checkout || settings.remote.is_some())
        && (settings.check.is_empty() || settings.check_runs_changed_code)
        && settings.check.len() <= 64
        && settings
            .check
            .iter()
            .all(|arg| !arg.is_empty() && arg.len() <= 4096 && !arg.contains('\0'))
}

/// Lane settings for a checkout, only when lanes are on.
pub(super) fn settings(checkout: &str) -> Option<Settings> {
    checkout_settings(checkout).filter(|s| s.enabled)
}

fn checkout_settings(checkout: &str) -> Option<Settings> {
    load()
        .ok()?
        .checkouts
        .get(checkout)
        .filter(|s| validate(s))
        .cloned()
}

/// A lane for one run. Removed on drop unless kept, so a preflight refusal
/// never leaves a worktree behind. Started work is kept when it cannot land.
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
    /// The target ref stays useful after committing, including in repositories
    /// that disable Git's automatic upstream setup for new branches.
    #[serde(default)]
    base: Option<String>,
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
        base: Some(base),
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
            let files = lane::changed_files(&path, about.base.as_deref()).unwrap_or_default();
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
pub(super) fn finish(
    lane: &mut Lane,
    settings: &Settings,
    message: &str,
    control: &mut impl FnMut(lane::Control<'_>) -> Result<(), String>,
) -> Landing {
    settle(lane, settings, message, false, control)
}

/// Land again after the agent worked on a conflict or a failed check.
pub(super) fn finish_fix(
    lane: &mut Lane,
    settings: &Settings,
    message: &str,
    control: &mut impl FnMut(lane::Control<'_>) -> Result<(), String>,
) -> Landing {
    settle(lane, settings, message, true, control)
}

/// One landing at a time per checkout on this computer, across processes.
struct LandingLock(fs::File);
impl Drop for LandingLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}
fn landing_lock(lane: &Path) -> Option<LandingLock> {
    landing_lock_at(&root().ok()?, lane).ok().flatten()
}
fn landing_lock_at(root: &Path, lane: &Path) -> std::io::Result<Option<LandingLock>> {
    let checkout = lane
        .parent()
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        .ok_or_else(|| std::io::Error::other("The landing directory is invalid."))?;
    let path = root.join(format!("{checkout}.landing"));
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)?;
    // Never wait behind another landing's potentially twenty-minute check:
    // this guardian must keep observing Stop and authority expiry.
    match file.try_lock() {
        Ok(()) => Ok(Some(LandingLock(file))),
        Err(fs::TryLockError::WouldBlock) => Ok(None),
        Err(fs::TryLockError::Error(error)) => Err(error),
    }
}

fn landing_lock_controlled(
    root: &Path,
    path: &Path,
    control: &mut impl FnMut(lane::Control<'_>) -> Result<(), String>,
) -> Result<LandingLock, String> {
    // Preserve automatic landing order while other lanes run their checks.
    // The waiting guardian still renews its lease and observes Stop or expiry.
    loop {
        control(lane::Control::Guard)?;
        match landing_lock_at(root, path) {
            Ok(Some(lock)) => return Ok(lock),
            Ok(None) => {}
            Err(_) => return Err("The landing lock is unavailable.".into()),
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

fn settle(
    lane: &mut Lane,
    settings: &Settings,
    message: &str,
    after_fix: bool,
    control: &mut impl FnMut(lane::Control<'_>) -> Result<(), String>,
) -> Landing {
    let lock = root()
        .map_err(|_| "The landing directory is unavailable.".to_string())
        .and_then(|root| landing_lock_controlled(&root, &lane.path, control));
    let _lock = match lock {
        Ok(lock) => lock,
        Err(message) => {
            lane.keep();
            return Landing::Blocked { message };
        }
    };
    // The agent could edit files in the lane. Its git pointer must still be
    // the one tokenstat created, or git would follow the agent's choice.
    if lane::pointer(&lane.path).ok().as_deref() != Some(lane.pointer.as_str()) {
        lane.keep();
        return Landing::Blocked {
            message: "The lane's git link was changed.".into(),
        };
    }
    if let Err(message) = control(lane::Control::Guard) {
        lane.keep();
        return Landing::Blocked { message };
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
    let landing = lane::land_controlled(
        &lane.path,
        &settings.target,
        settings.remote.as_deref(),
        &settings.check,
        !settings.review,
        control,
    );
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
    control: &mut impl FnMut(lane::Control<'_>) -> Result<(), String>,
) -> Next {
    if let Err(message) = control(lane::Control::Guard) {
        lane.keep();
        return Next::Done(Landing::Blocked { message });
    }
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
                Ok(_) => Next::Done(finish_fix(lane, settings, message, control)),
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
        let Some(settings) = checkout_settings(&row.id) else {
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
        if settings.updates_checkout() {
            record_catch_up(
                &row.id,
                &lane::catch_up(&row.folder.canonical, &settings.target, remote),
            );
        } else {
            record_catch_up_note(
                &row.id,
                Some("New work landed in this project. Update this checkout when you are ready."),
            );
        }
        // Manual mode's opt-in covers the target checkout only. It must not
        // resume automatic changes to lanes left from an earlier workflow.
        if !settings.enabled {
            continue;
        }
        let Ok(kept) = fs::read_dir(lane::root(&data, &row.id)) else {
            continue;
        };
        for entry in kept.flatten().take(64) {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let Some(about) = fs::read(path.with_extension("json"))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<About>(&bytes).ok())
            else {
                continue;
            };
            if about.status.as_deref() == Some("running")
                || lane::pointer(&path).ok().as_deref() != Some(about.pointer.as_str())
                || lane::rebase_in_progress(&path)
            {
                continue;
            }
            // A lease held means an agent is working in that lane right now.
            if let Ok(_lease) = tokenstat_workspace::writer::Lease::acquire_lane(&path)
                && !matches!(
                    lane::refresh(&path, &settings.target, Some(remote)),
                    Landing::Nothing
                )
            {
                mark(&path, false);
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
    super::lane_check::recover_manual(&path).map_err(|_| DispatchError::new("team_lane_busy", "This lane's previous check needs recovery. Restart the publishing computer before trying again."))?;
    let mut lease = tokenstat_workspace::writer::Lease::acquire_lane(&path).map_err(|_| {
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
    let source = super::scoped_source::Source::capture(principal)?;
    let client = principal.account_client()?.clone();
    // A long check outlives the viewer's short connection ticket. The host
    // renews its own authority, just as it does during an agent's landing.
    let mut authority = client
        .admit_host_run_authority(
            &format!("runlease_{:032x}", rand::random::<u128>()),
            principal.run_ticket()?,
        )
        .map_err(super::api_error)?;
    let mut renew = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let mut guard = || {
        if std::time::Instant::now() >= renew {
            authority
                .renew()
                .map_err(|_| "Permission to land this work ended.".to_string())?;
            renew = std::time::Instant::now() + std::time::Duration::from_secs(10);
        }
        if !authority
            .remaining()
            .is_ok_and(|left| left >= crate::team_process::BIRTH)
        {
            return Err("Permission to land this work ended.".to_string());
        }
        source.ensure_current().map_err(|_| {
            "This project or chat is no longer shared from this folder.".to_string()
        })?;
        Ok(())
    };
    let helper = std::env::current_exe().map_err(|_| unavailable())?;
    let landing = lane::land_controlled(
        &path,
        &settings.target,
        settings.remote.as_deref(),
        &settings.check,
        true,
        &mut |step| match step {
            lane::Control::Guard => guard(),
            lane::Control::Check(folder, command) => {
                if command.is_empty() {
                    return guard();
                }
                let mut record = super::lane_check::Manual::begin(folder, &mut lease)
                    .map_err(|_| "The check's writer claim could not be saved.".to_string())?;
                let outcome = super::lane_check::run(&helper, folder, command, &mut guard, |anchor| record.birth(folder, anchor))
                    .map_err(|_| "The check process could not be verified. Restart this computer before trying again.".to_string())?;
                record.complete(folder, &mut lease).map_err(|_| {
                    "The check's writer claim could not be released. Try again.".to_string()
                })?;
                outcome
            }
        },
    );
    let _ = authority.retire();
    let landed = matches!(landing, Landing::Landed { .. });
    let message = describe(&landing, &lane, &settings);
    if landed {
        lane.keep = false;
        let _ = client.checkout_moved(&value.organization_id, &value.checkout_id);
    } else {
        mark(&path, false);
    }
    drop(lane);
    Ok(json!({"landed":landed,"message":message}))
}

/// Words for the last catch-up of a checkout, kept for the owner to see.
fn record_catch_up(checkout: &str, outcome: &lane::CatchUp) {
    let note = match outcome {
        lane::CatchUp::Updated | lane::CatchUp::Current => None,
        lane::CatchUp::OtherBranch => {
            Some("This folder is on another branch, so it was not updated.")
        }
        lane::CatchUp::Dirty => Some("This folder has uncommitted changes, so it was not updated."),
        lane::CatchUp::Diverged => Some(
            "This folder has its own commits on the target, so it was not updated. Pull or rebase it yourself.",
        ),
        lane::CatchUp::Busy => {
            Some("Another change was being written in this folder, so it was not updated.")
        }
        lane::CatchUp::Failed(_) => Some(
            "This folder was not updated. Check the remote and any local or ignored files before trying again.",
        ),
    };
    record_catch_up_note(checkout, note);
}

fn record_catch_up_note(checkout: &str, note: Option<&str>) {
    let Ok(root) = root() else {
        return;
    };
    let file = root.join("caught-up.json");
    let mut notes: BTreeMap<String, String> = fs::read(&file)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    match note {
        Some(note) => notes.insert(checkout.into(), note.into()),
        None => notes.remove(checkout),
    };
    if fs::create_dir_all(&root).is_ok()
        && let Ok(bytes) = serde_json::to_vec(&notes)
    {
        let _ = fs::write(file, bytes);
    }
}

fn catch_up_note(checkout: &str) -> Option<String> {
    let bytes = fs::read(root().ok()?.join("caught-up.json")).ok()?;
    serde_json::from_slice::<BTreeMap<String, String>>(&bytes)
        .ok()?
        .remove(checkout)
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

/// Drop a lane that is not running: its worktree and branch go, nothing
/// lands. Same people as Land, through the same verified Run connection.
pub(super) fn discard(
    principal: &super::AuthorizedTeamPrincipal,
    params: &str,
) -> Result<Value, DispatchError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct DiscardInput {
        branch: String,
    }
    principal.run_ticket()?;
    if params.len() > 1024 {
        return Err(invalid());
    }
    let input: DiscardInput = serde_json::from_str(params).map_err(|_| invalid())?;
    let value = principal.value();
    super::publications::Store::current_for(principal)?;
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
    let Some((path, about)) = found else {
        return Ok(json!({"discarded":false}));
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
            "Only the person who asked, a maintainer or the publisher can discard this work.",
        ));
    }
    if about.status.as_deref() == Some("running") {
        return Err(DispatchError::new(
            "team_lane_busy",
            "An agent is still working in this lane. Stop it first.",
        ));
    }
    super::lane_check::recover_manual(&path).map_err(|_| DispatchError::new("team_lane_busy", "This lane's previous check needs recovery. Restart the publishing computer before trying again."))?;
    let _lease = tokenstat_workspace::writer::Lease::acquire_lane(&path)
        .map_err(|_| DispatchError::new("team_lane_busy", "This lane is in use right now."))?;
    // Git runs inside the lane only while its pointer is still tokenstat's.
    // Otherwise the lane goes through the main repository alone.
    if lane::pointer(&path).ok().as_deref() == Some(about.pointer.as_str()) {
        lane::abort_rebase(&path);
    }
    drop(_lease);
    let removed = Lane {
        path,
        branch: about.branch,
        repository: about.repository,
        pointer: about.pointer,
        rebasing: false,
        keep: false,
    };
    drop(removed);
    Ok(json!({"discarded":true}))
}

/// Push a ready lane's branch and open a pull request for it. The lane goes
/// once the request exists; the branch on the remote carries the work.
pub(super) fn open_pull(
    lane: &mut Lane,
    settings: &Settings,
    title: &str,
    workspace: &str,
    control: &mut impl FnMut(lane::Control<'_>) -> Result<(), String>,
) -> String {
    if let Err(message) = control(lane::Control::Guard) {
        return message;
    }
    let Some(remote) = settings.remote.as_deref() else {
        return format!(
            "Ready, but a pull request needs a remote. It is kept on branch {}.",
            lane.branch
        );
    };
    if let Err(message) = lane::publish_branch(&lane.path, remote, &lane.branch) {
        return format!(
            "Ready, but the branch could not be pushed: {message} It is kept on branch {}.",
            lane.branch
        );
    }
    let body = "Opened by tokenstat from a shared Team chat. The work was committed, rebased and checked in its own lane.";
    if let Err(message) = control(lane::Control::Guard) {
        return message;
    }
    match crate::pulls::open_for_lane(workspace, &lane.branch, &settings.target, title, body) {
        Ok(url) => {
            lane.keep = false;
            format!("Opened a pull request for review: {url}")
        }
        Err(message) => format!(
            "Ready, and branch {} is on {remote}, but the pull request could not be opened: {message}",
            lane.branch
        ),
    }
}

/// What the shared chat reads after a run, in plain words.
/// The run ended without its work landing. A rebase stopped for the agent
/// is given up, so the lane keeps its own commits and nothing half done.
pub(super) fn abandon(lane: &mut Lane) {
    lane.keep();
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
    if !matches!(
        method,
        "teams.lanes.get" | "teams.lanes.set" | "teams.lanes.catchUp"
    ) {
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
        if !valid_checkout(&input.checkout) {
            return Err(invalid());
        }
        let file = if method == "teams.lanes.set" {
            let settings = input.settings.ok_or_else(invalid)?;
            if !validate(&settings) {
                return Err(invalid());
            }
            update_settings_at(&root()?, input.checkout.clone(), settings)?
        } else {
            load()?
        };
        if method == "teams.lanes.catchUp" {
            // The owner asked to try again now, on this computer only.
            let settings = file
                .checkouts
                .get(&input.checkout)
                .ok_or_else(unavailable)?;
            let remote = settings.remote.as_deref().ok_or_else(invalid)?;
            let row = super::publications::Store::capture()?
                .active_checkout(&input.checkout)?
                .ok_or_else(unavailable)?;
            let workspace = crate::workspaces::get(&row.workspace_id)?;
            if super::publications::Folder::capture(&workspace.path)? != row.folder {
                return Err(unavailable());
            }
            record_catch_up(
                &input.checkout,
                &lane::catch_up(&row.folder.canonical, &settings.target, remote),
            );
        }
        Ok(
            json!({"settings": file.checkouts.get(&input.checkout), "catchUp": catch_up_note(&input.checkout), "supportsCheckoutUpdates": true}),
        )
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
            pull_request: false,
            update_checkout: false,
        }
    }

    #[test]
    fn unreadable_existing_settings_are_reported_and_preserved() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.json");
        assert!(load_at(root.path()).unwrap().checkouts.is_empty());
        let cases = [
            b"{broken settings".to_vec(),
            br#"{"version":2,"checkouts":{}}"#.to_vec(),
            br#"{"version":1,"checkouts":{"existing":{"enabled":true,"target":"-unsafe"}}}"#
                .to_vec(),
            vec![b' '; SETTINGS_MAX_BYTES as usize + 1],
        ];
        for bytes in cases {
            fs::write(&path, &bytes).unwrap();
            assert_eq!(
                load_at(root.path()).err().unwrap().code,
                "team_lanes_storage"
            );
            assert_eq!(
                update_settings_at(root.path(), "new".into(), settings("main", None, &[]))
                    .err()
                    .unwrap()
                    .code,
                "team_lanes_storage"
            );
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(load_at(root.path()).is_err());
        assert!(
            update_settings_at(root.path(), "new".into(), settings("main", None, &[])).is_err()
        );
        assert!(path.is_dir());
    }

    // A separate process uses the same transaction as a native host or daemon.
    #[test]
    fn settings_update_child() {
        let Some(root) = std::env::var_os("TOKENSTAT_TEST_LANE_SETTINGS_ROOT") else {
            return;
        };
        let root = PathBuf::from(root);
        let checkout = std::env::var("TOKENSTAT_TEST_LANE_SETTINGS_CHECKOUT").unwrap();
        fs::write(root.join(format!("{checkout}.ready")), []).unwrap();
        let started = std::time::Instant::now();
        while !root.join("settings.start").exists() {
            assert!(started.elapsed() < std::time::Duration::from_secs(15));
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        for index in 0..10 {
            update_settings_at(
                &root,
                format!("{checkout}-{index}"),
                settings("main", None, &[]),
            )
            .unwrap();
        }
    }

    #[test]
    fn concurrent_checkout_updates_preserve_each_other_across_processes() {
        use std::process::{Command, Stdio};
        let root = tempfile::tempdir().unwrap();
        let lease =
            crate::chat_receipts::OwnerLease::try_acquire(&root.path().join("settings.lock"))
                .unwrap()
                .unwrap();
        let children = ["first", "second"].map(|checkout| {
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "teams::lanes::tests::settings_update_child"])
                .env("TOKENSTAT_TEST_LANE_SETTINGS_ROOT", root.path())
                .env("TOKENSTAT_TEST_LANE_SETTINGS_CHECKOUT", checkout)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let ready = || {
            ["first", "second"]
                .iter()
                .all(|checkout| root.path().join(format!("{checkout}.ready")).exists())
        };
        while !ready() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let both_ready = ready();
        // The children must reload this entry after they acquire the lease,
        // even though their requests began before it was saved.
        let existing = File {
            version: 1,
            checkouts: BTreeMap::from([("existing".into(), settings("main", None, &[]))]),
        };
        fs::write(
            root.path().join("settings.json"),
            serde_json::to_vec(&existing).unwrap(),
        )
        .unwrap();
        fs::write(root.path().join("settings.start"), []).unwrap();
        drop(lease);
        // Always release the parent lock and reap children before assertions.
        let outputs = children.map(|child| child.wait_with_output().unwrap());
        for output in outputs {
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        assert!(both_ready);
        let file = load_at(root.path()).unwrap();
        assert_eq!(file.checkouts.len(), 21);
        assert!(file.checkouts.contains_key("existing"));
        for checkout in ["first", "second"] {
            for index in 0..10 {
                assert!(file.checkouts.contains_key(&format!("{checkout}-{index}")));
            }
        }
    }

    #[test]
    fn another_landing_is_refused_without_waiting_for_its_check() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("checkout/lane");
        let first = landing_lock_at(root.path(), &path).unwrap().unwrap();
        let (sender, result) = std::sync::mpsc::channel();
        let directory = root.path().to_path_buf();
        let worker_path = path.clone();
        let worker = std::thread::spawn(move || {
            let acquired = landing_lock_at(&directory, &worker_path).unwrap().is_some();
            let _ = sender.send(acquired);
        });
        let contended = result.recv_timeout(std::time::Duration::from_secs(2));
        // Release and join before asserting: a regressed blocking acquire
        // must fail the test instead of hanging the whole test runner.
        drop(first);
        worker.join().unwrap();
        assert!(matches!(contended, Ok(false)));
        assert!(landing_lock_at(root.path(), &path).unwrap().is_some());
    }

    #[test]
    fn automatic_landing_waits_for_another_check_with_live_guards() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("checkout/lane");
        let first = landing_lock_at(root.path(), &path).unwrap().unwrap();
        let holder = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(80));
            drop(first);
        });
        let mut guards = 0;
        let acquired = landing_lock_controlled(root.path(), &path, &mut |_| {
            guards += 1;
            Ok(())
        });
        holder.join().unwrap();
        assert!(acquired.is_ok());
        assert!(guards > 1, "waiting must keep checking the run's authority");
    }

    #[test]
    fn automatic_landing_observes_stop_before_the_other_lock_is_released() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("checkout/lane");
        let first = landing_lock_at(root.path(), &path).unwrap().unwrap();
        let (sender, result) = std::sync::mpsc::channel();
        let directory = root.path().to_path_buf();
        let worker = std::thread::spawn(move || {
            let mut checks = 0;
            let error = landing_lock_controlled(&directory, &path, &mut |_| {
                checks += 1;
                if checks > 1 {
                    Err("Stopped or access expired".into())
                } else {
                    Ok(())
                }
            })
            .err();
            let _ = sender.send(error);
        });
        let stopped = result.recv_timeout(std::time::Duration::from_secs(1));
        drop(first);
        worker.join().unwrap();
        assert_eq!(
            stopped.unwrap().as_deref(),
            Some("Stopped or access expired")
        );
    }

    #[test]
    fn abandoning_started_work_retains_its_changes_and_branch() {
        let root = tempfile::tempdir().unwrap();
        let repository = root.path().join("repository");
        fs::create_dir(&repository).unwrap();
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&repository)
                .args([
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "-c",
                    "commit.gpgSign=false",
                ])
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["commit", "--allow-empty", "-qm", "Initial"]);
        let path = root.path().join("lane");
        let branch = "team/retained";
        lane::create(&repository, &path, branch, "main").unwrap();
        let mut opened = Lane {
            pointer: lane::pointer(&path).unwrap(),
            path: path.clone(),
            branch: branch.into(),
            repository: repository.clone(),
            rebasing: false,
            keep: false,
        };
        fs::write(path.join("unfinished.txt"), "unfinished agent work").unwrap();
        abandon(&mut opened);
        drop(opened);
        assert_eq!(
            fs::read_to_string(path.join("unfinished.txt")).unwrap(),
            "unfinished agent work"
        );
        assert_eq!(git(&["branch", "--list", branch]), format!("+ {branch}"));
    }

    #[test]
    fn checkout_updates_preserve_old_defaults_and_need_explicit_opt_in() {
        let legacy = r#"{"enabled":true,"target":"main","remote":"origin","review":true}"#;
        let mut value: Settings = serde_json::from_str(legacy).unwrap();
        assert!(!value.updates_checkout());
        assert!(
            serde_json::to_value(&value)
                .unwrap()
                .get("updateCheckout")
                .is_none()
        );
        value.update_checkout = true;
        assert!(value.updates_checkout());
        assert!(validate(&value));
        value.enabled = false;
        assert!(value.updates_checkout());
        value.remote = None;
        assert!(!validate(&value));
        value.update_checkout = false;
        assert!(!value.updates_checkout());
        value.enabled = true;
        value.review = false;
        assert!(value.updates_checkout());
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
