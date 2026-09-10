// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Moving this host to a newer release, from here or from a device that
//! reaches it.
//!
//! # Why this is not `app.update*`
//!
//! Those methods are about the desktop application bundle, and they belong to
//! the person sitting in front of it: replacing an application needs Apple's
//! own tools and knowledge of where the running bundle lives. This is about
//! the two files that make a machine a host, the daemon and the command line
//! tool beside it. A server has no application and nobody sitting at it, so a
//! host that cannot be updated over the tunnel cannot be updated at all.
//!
//! # Why an approved device may ask
//!
//! An approved peer can already call `pty.spawn`, which is arbitrary code
//! execution on this machine. Refusing it an update method does not take that
//! away; it only removes the narrow path and leaves the general one, so
//! somebody types the commands into a terminal instead and nothing records
//! that they did. This method is therefore open to an approved device, and
//! every use of it is written to the access log, because a replaced binary
//! outlives the session that replaced it.
//!
//! # Why it answers without a session
//!
//! The host most in need of an update is the one whose archive will not open.
//! Same reason `host.stats` and `host.provisionStatus` answer without one.
//!
//! # What a restart costs, and when one happens
//!
//! Replacing the files is free. The running daemon keeps the image it started
//! with, so nothing it owns notices, and the new code is simply not in use
//! yet. Only a restart picks it up, and a restart ends every terminal and
//! every agent turn this daemon owns.
//!
//! So a restart happens when this daemon owns no live work, and otherwise the
//! files are left in place and the restart is reported as pending. A person
//! can insist with `restartNow`; a timer never can, because ending somebody
//! else's session is not a decision a clock gets to make.
//!
//! # One deliberate waste
//!
//! Somebody who runs `tokenstat update` at a console replaces both files and
//! is told to restart the host, which they may not do straight away. Until
//! this daemon restarts it is still the old release, so its own next check
//! sees a newer one and downloads it again to install what is already there.
//!
//! That is left alone on purpose. Asking the disk instead would mean running
//! the command line tool from this thread to read its version, and a hung
//! subprocess is a worse thing to own than one repeated download in a window
//! the following restart closes for good.

use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::access_audit::{self, Authority};

/// How long after start the first check runs.
///
/// Not at start. A fresh daemon is being asked for a first screen, and a
/// release check is network work nobody is waiting for.
///
/// The three cadences belong to the scheduler, which a test build does not
/// compile: nothing in a test runner should be replacing binaries on a timer.
#[cfg(not(test))]
const FIRST_CHECK_AFTER: Duration = Duration::from_secs(5 * 60);

/// How often the daemon looks for a release.
#[cfg(not(test))]
const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

/// How often a pending restart is retried while work is in flight.
#[cfg(not(test))]
const RESTART_RETRY_EVERY: Duration = Duration::from_secs(10 * 60);

/// Long enough for this request's answer to reach the caller before the
/// process goes away, short enough that nobody is left watching a spinner.
const RESTART_GRACE: Duration = Duration::from_millis(1500);

/// Set once an update has replaced the files this daemon is running from.
///
/// The running process is still the old one at that point. This is what lets
/// `host.updateCheck` say "installed, waiting to restart" rather than
/// reporting a version that is on disk but not in use.
fn restart_pending() -> &'static AtomicBool {
    static PENDING: AtomicBool = AtomicBool::new(false);
    &PENDING
}

/// One update at a time. Two downloads racing to replace the same two files
/// is the one way this could leave a machine with a mismatched pair.
fn gate() -> &'static Mutex<()> {
    static GATE: Mutex<()> = Mutex::new(());
    &GATE
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "host.updateCheck" => check(),
        "host.updateApply" => apply(params),
        _ => return None,
    })
}

/// The command line tool this daemon was installed beside.
///
/// An update replaces the pair, and the pair has to be in one directory. This
/// is also the check that catches a half install: a daemon copied somewhere on
/// its own cannot be updated, and saying so names the actual problem.
fn cli_path() -> Result<PathBuf, String> {
    let name = if cfg!(windows) {
        "tokenstat.exe"
    } else {
        "tokenstat"
    };
    let exe = std::env::current_exe().map_err(|error| error.to_string())?;
    let path = exe.with_file_name(name);
    if !path.is_file() {
        return Err(format!(
            "the tokenstat command line tool is not beside this daemon at {}. \
             An update replaces both, so both have to be installed in one place.",
            path.display()
        ));
    }
    Ok(path)
}

/// Whether this daemon is the copy the desktop application installs and puts
/// back, rather than one installed beside the command line tool.
///
/// The application copies its bundled helper into its own support directory
/// and replaces it whenever the two differ, so writing a newer helper there
/// from here would be undone at the next launch. For that machine the useful
/// thing is not replacing this file, it is having the application's own
/// download already on disk and already checked.
#[cfg(target_os = "macos")]
fn app_managed_helper() -> bool {
    let Some(home) = std::env::var_os("HOME") else {
        return false;
    };
    let managed = PathBuf::from(home).join("Library/Application Support/tokenstat/bin");
    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    let Some(dir) = exe.parent() else {
        return false;
    };
    if dir == managed {
        return true;
    }
    // Resolved as well as compared: the support directory is reached through a
    // symlink on some accounts, and one spelling of a path is not two places.
    match (dir.canonicalize(), managed.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

#[cfg(not(target_os = "macos"))]
fn app_managed_helper() -> bool {
    false
}

/// Terminals and agent turns this daemon owns right now.
///
/// The number a restart would end. Reported rather than only tested, because
/// "not yet, two things are running" is an answer somebody can act on and
/// "not yet" is not.
fn live_work() -> usize {
    live_chats() + live_terminals()
}

/// Agent turns this daemon owns right now.
///
/// Without the local half there is no chat store to count: receipts and
/// runner leases live behind `local-host`, and the count is zero rather
/// than a read of a directory this build never writes.
#[cfg(feature = "local-host")]
fn live_chats() -> usize {
    tokenstat_paths::data_dir()
        .map(|dir| crate::chat_receipts::running_count(&dir.join("chat")))
        .unwrap_or(0)
}

#[cfg(not(feature = "local-host"))]
fn live_chats() -> usize {
    0
}

#[cfg(feature = "local-host")]
fn live_terminals() -> usize {
    tokenstat_pty::manager().list().len()
}

#[cfg(not(feature = "local-host"))]
fn live_terminals() -> usize {
    0
}

fn check() -> Result<Value, String> {
    let release = tokenstat_sync::check_latest().map_err(|error| error.to_string())?;
    let live = live_work();
    Ok(json!({
        // What this process is running, which after an applied update is not
        // the same as what is on disk.
        "hostVersion": env!("CARGO_PKG_VERSION"),
        "protocolVersion": crate::PROTOCOL_VERSION,
        "latest": release.latest,
        "newer": release.newer,
        "htmlUrl": release.html_url,
        "autoApply": tokenstat_sync::auto_apply_enabled(),
        "restartPending": restart_pending().load(Ordering::Acquire),
        "liveWork": live,
        "canRestart": crate::host_policy::supervisor_would_restart_this_process(),
        // True where the desktop application owns this helper, so an update
        // here means staging the application's download rather than replacing
        // a pair of binaries.
        "appManaged": app_managed_helper(),
        // Present only where this machine has an application to update as
        // well. The host cannot install it; see `stage_app_image`.
        "appImage": release.app_dmg_name,
    }))
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ApplyParams {
    /// Restart even though this daemon owns live work.
    ///
    /// A person can decide to end their own sessions. The scheduler never
    /// sets this.
    restart_now: bool,
}

fn apply(params: &str) -> Result<Value, String> {
    let trimmed = params.trim();
    let asked: ApplyParams = if trimmed.is_empty() {
        ApplyParams::default()
    } else {
        serde_json::from_str(trimmed)
            .map_err(|error| format!("invalid update parameters: {error}"))?
    };
    let _guard = gate()
        .try_lock()
        .map_err(|_| "an update is already running on this machine".to_string())?;
    let cli = match cli_path() {
        Ok(path) => path,
        Err(reason) => {
            // Not a broken install: on a Mac with the app, this is the normal
            // arrangement. Do what actually helps and say what happens next.
            if app_managed_helper() {
                let staged = stage_app_image();
                return Ok(json!({
                    "hostVersion": env!("CARGO_PKG_VERSION"),
                    "appManaged": true,
                    "restarting": false,
                    "restartPending": false,
                    "appImage": staged,
                    "detail": "The tokenstat application owns this helper and replaces it \
                               when it updates itself. Its download is on this machine and \
                               checked; open tokenstat there to finish.",
                }));
            }
            return Err(reason);
        }
    };
    let report = tokenstat_sync::apply_update_to(&cli).map_err(|error| error.to_string())?;
    restart_pending().store(true, Ordering::Release);
    record_update(&report.from, &report.to);
    let staged = stage_app_image();
    let live = live_work();
    let restarting = (asked.restart_now || live == 0) && begin_restart();
    Ok(json!({
        "from": report.from,
        "to": report.to,
        "hostBinaryUpdated": report.host_binary_updated,
        // True means this daemon is about to stop and be started again. The
        // caller gets this answer first, then loses the connection, which is
        // the update working rather than failing.
        "restarting": restarting,
        "restartPending": !restarting,
        "liveWork": live,
        "canRestart": crate::host_policy::supervisor_would_restart_this_process(),
        "appImage": staged,
    }))
}

/// Write who moved this machine to a new release.
///
/// A terminal session leaves nothing behind and this leaves a different binary,
/// so it is the kind of thing the log exists for.
fn record_update(from: &str, to: &str) {
    let peer = crate::request_context::remote_peer();
    let authority = if peer.is_some() {
        Authority::Device
    } else {
        Authority::Console
    };
    access_audit::record(
        "host updated",
        peer.as_deref(),
        Some(&format!("{from} to {to}")),
        authority,
    );
}

/// Fetch and verify the desktop application's disk image, where there is one.
///
/// The host stops at a verified file on disk, exactly as `app.updateDownload`
/// does, because mounting it, checking who signed it and replacing the running
/// bundle need Apple's tools and the app's own knowledge of where it lives.
/// What this buys is the waiting: when somebody next opens the app the
/// download has already happened and been checked.
///
/// Never a reason to fail an update. The host's own binaries are the point of
/// this method, and they are already replaced by the time this runs.
#[cfg(target_os = "macos")]
fn stage_app_image() -> Option<String> {
    match tokenstat_sync::download_app_image() {
        Ok(path) => Some(path.display().to_string()),
        Err(error) => {
            eprintln!("host update: the application image was not staged: {error}");
            None
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn stage_app_image() -> Option<String> {
    None
}

/// Stop, so whatever started this daemon starts the replacement.
///
/// A process cannot exchange its own running image, and nothing else on the
/// machine is watching this one, so stopping and being started again is the
/// only way a new binary comes into use. Only where something will actually
/// start it: exiting under a supervisor that will not is how a machine goes
/// quiet for good, which is the opposite of what was asked for.
///
/// On a thread with a delay, because the answer to this request has not been
/// written yet and the caller is owed it.
fn begin_restart() -> bool {
    if !crate::host_policy::supervisor_would_restart_this_process() {
        return false;
    }
    let _ = std::thread::Builder::new()
        .name("tokenstat-host-restart".into())
        .spawn(|| {
            std::thread::sleep(RESTART_GRACE);
            // Work may have started during the grace wait. Exiting then would
            // end a session that began after the decision to restart.
            if live_work() != 0 {
                eprintln!(
                    "tokenstat-hostd: update installed, keeping this process: work started during restart wait"
                );
                return;
            }
            eprintln!(
                "tokenstat-hostd: updated on disk, stopping so the supervisor starts the new version"
            );
            std::process::exit(0);
        });
    true
}

/// Look for a release once a day, and finish what a busy machine deferred.
///
/// In this process rather than an operating system timer, because the daemon
/// already carries its own schedulers and because one loop behaves the same on
/// macOS, Linux and Windows. An always-on host is running whenever this would
/// have fired, which is the case a timer would have bought.
#[cfg(not(test))]
pub fn start_scheduler() {
    let _ = std::thread::Builder::new()
        .name("tokenstat-host-update".into())
        .spawn(|| {
            std::thread::sleep(FIRST_CHECK_AFTER);
            loop {
                std::thread::sleep(tick());
            }
        });
}

#[cfg(test)]
pub fn start_scheduler() {}

/// One pass. Returns how long to wait before the next one.
#[cfg(not(test))]
fn tick() -> Duration {
    // Already installed and waiting for a quiet moment. Do not go looking for
    // another release: the answer is on disk, the restart is what is left.
    if restart_pending().load(Ordering::Acquire) {
        if live_work() == 0 && begin_restart() {
            // The process is going away. Sleep long rather than loop.
            return CHECK_EVERY;
        }
        return RESTART_RETRY_EVERY;
    }
    let Ok(cli) = cli_path() else {
        return CHECK_EVERY;
    };
    // `scheduled_update_to` owns the policy: the auto-apply setting, the
    // asleep check, the jitter that keeps a fleet from arriving at once, and
    // refusing to replace an install a package manager owns.
    match tokenstat_sync::scheduled_update_to(&cli) {
        Ok(tokenstat_sync::ScheduledUpdate::Applied(report)) => {
            restart_pending().store(true, Ordering::Release);
            record_update(&report.from, &report.to);
            let _ = stage_app_image();
            if live_work() == 0 && begin_restart() {
                return CHECK_EVERY;
            }
            eprintln!(
                "tokenstat-hostd: updated to {} on disk, restarting when nothing is running",
                report.to
            );
            RESTART_RETRY_EVERY
        }
        Ok(_) => CHECK_EVERY,
        Err(error) => {
            // Not news. The binary in place still works, and a machine that
            // could not reach GitHub today will try tomorrow.
            eprintln!("tokenstat-hostd: update check failed: {error}");
            CHECK_EVERY
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pair has to live in one directory, and the message has to say so:
    /// a daemon copied somewhere on its own is a half install, not a network
    /// problem or a permission problem.
    #[test]
    fn an_update_needs_the_command_line_tool_beside_the_daemon() {
        // The test binary's own directory has no `tokenstat` beside it.
        let error = cli_path().expect_err("a test binary has no CLI sibling");
        assert!(error.contains("not beside this daemon"), "{error}");
        assert!(error.contains("one place"), "{error}");
    }

    /// A test binary has no supervisor, so nothing in here may ever decide to
    /// exit the process it is running in.
    #[test]
    fn a_restart_is_refused_where_nothing_would_start_this_again() {
        assert!(!crate::host_policy::supervisor_would_restart_this_process());
        assert!(
            !begin_restart(),
            "begin_restart must refuse without a supervisor rather than exit the test runner"
        );
    }

    /// Two callers must not both be replacing the same two files.
    #[test]
    fn only_one_update_runs_at_a_time() {
        let held = gate().try_lock().expect("the gate starts free");
        let refused = apply("{}").expect_err("a second update must be refused");
        assert!(refused.contains("already running"), "{refused}");
        drop(held);
    }
}
