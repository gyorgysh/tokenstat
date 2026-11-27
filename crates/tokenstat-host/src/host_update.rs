// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.
//! Moving this host to a newer release, from here or from a device that
//! reaches it.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::access_audit::{self, Authority};

#[cfg(not(test))]
const FIRST_CHECK_AFTER: Duration = Duration::from_secs(5 * 60);

#[cfg(not(test))]
const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

#[cfg(not(test))]
const RESTART_RETRY_EVERY: Duration = Duration::from_secs(10 * 60);

const RESTART_GRACE: Duration = Duration::from_millis(1500);

fn restart_pending() -> &'static AtomicBool {
    static PENDING: AtomicBool = AtomicBool::new(false);
    &PENDING
}

fn gate() -> &'static Mutex<()> {
    static GATE: Mutex<()> = Mutex::new(());
    &GATE
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "host.updateCheck" => check(),
        "host.updateApply" => apply(params),

        "host.liveWork" => Ok(json!({ "liveWork": live_work() })),
        _ => return None,
    })
}

fn cli_path() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|error| error.to_string())?;
    cli_path_for(&exe)
}

fn cli_path_for(exe: &Path) -> Result<PathBuf, String> {
    let name = if cfg!(windows) {
        "tokenstat.exe"
    } else {
        "tokenstat"
    };
    let path = exe.with_file_name(name);

    if tokenstat_sync::update::is_desktop_app_dir(exe) {
        return Err(format!(
            "this daemon belongs to the tokenstat desktop application at {}, \
             which updates the whole folder itself",
            exe.parent().unwrap_or(exe).display()
        ));
    }
    if !path.is_file() {
        return Err(format!(
            "the tokenstat command line tool is not beside this daemon at {}. \
             An update replaces both, so both have to be installed in one place.",
            path.display()
        ));
    }
    Ok(path)
}

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

    match (dir.canonicalize(), managed.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

#[cfg(not(target_os = "macos"))]
fn app_managed_helper() -> bool {
    std::env::current_exe()
        .map(|exe| tokenstat_sync::update::is_desktop_app_dir(&exe))
        .unwrap_or(false)
}

fn live_work() -> usize {
    let listed = live_chats() + live_terminals();
    #[cfg(feature = "local-host")]
    {
        listed.max(crate::workspace_writer::pending_count())
    }
    #[cfg(not(feature = "local-host"))]
    listed
}

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


        "hostVersion": env!("CARGO_PKG_VERSION"),
        "protocolVersion": crate::PROTOCOL_VERSION,
        "latest": release.latest,
        "newer": release.newer,
        "htmlUrl": release.html_url,
        "autoApply": tokenstat_sync::auto_apply_enabled(),
        "restartPending": restart_pending().load(Ordering::Acquire),
        "liveWork": live,
        "canRestart": crate::host_policy::this_process_can_self_restart(),


        "appManaged": app_managed_helper(),


        "appImage": release.app_dmg_name,
    }))
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ApplyParams {
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
            if app_managed_helper() {
                let staged = stage_app_image();
                let detail = if staged.is_some() {
                    "The tokenstat application owns this helper and replaces it \
                     when it updates itself. Its download is on this machine and \
                     checked; open tokenstat there to finish."
                } else {
                    "The tokenstat application owns this helper and replaces it \
                     when it updates itself. Open tokenstat there to update."
                };
                return Ok(json!({
                    "hostVersion": env!("CARGO_PKG_VERSION"),
                    "appManaged": true,
                    "restarting": false,
                    "restartPending": false,
                    "appImage": staged,
                    "detail": detail,
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
    let restarting = (asked.restart_now || live == 0) && begin_restart(asked.restart_now);
    Ok(json!({
        "from": report.from,
        "to": report.to,
        "hostBinaryUpdated": report.host_binary_updated,


        "restarting": restarting,
        "restartPending": !restarting,
        "liveWork": live,
        "canRestart": crate::host_policy::this_process_can_self_restart(),
        "appImage": staged,
    }))
}

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

fn begin_restart(force: bool) -> bool {
    if !crate::host_policy::supervisor_would_restart_this_process() {
        return false;
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    if crate::host_policy::this_process_is_the_host_unit().is_none() {
        eprintln!(
            "tokenstat-hostd: update installed, keeping this process: not running as tokenstat-host.service"
        );
        return false;
    }
    std::thread::Builder::new()
        .name("tokenstat-host-restart".into())
        .spawn(move || {
            std::thread::sleep(RESTART_GRACE);


            if !force && live_work() != 0 {
                eprintln!(
                    "tokenstat-hostd: update installed, keeping this process: work started during restart wait"
                );
                return;
            }
            request_supervisor_restart();
        }).is_ok()
}

fn request_supervisor_restart() {
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let Some(unit) = crate::host_policy::this_process_is_the_host_unit() else {
            eprintln!(
                "tokenstat-hostd: update installed, keeping this process: not running as tokenstat-host.service"
            );
            return;
        };
        let mut command = std::process::Command::new("systemctl");
        if unit == crate::host_policy::LinuxHostUnit::User {
            command.arg("--user");
        }

        command
            .args([
                "restart",
                "--no-block",
                "--no-ask-password",
                "tokenstat-host.service",
            ])
            .stdin(std::process::Stdio::null());
        match command.status() {
            Ok(status) if status.success() => {
                eprintln!(
                    "tokenstat-hostd: updated on disk, asked systemd to restart tokenstat-host.service"
                );
            }
            Ok(status) => {
                eprintln!(
                    "tokenstat-hostd: systemctl restart failed ({status}), keeping this process"
                );
            }
            Err(error) => {
                eprintln!(
                    "tokenstat-hostd: could not ask systemd to restart ({error}), keeping this process"
                );
            }
        }
    }
    #[cfg(not(all(unix, not(target_os = "macos"))))]
    {
        eprintln!(
            "tokenstat-hostd: updated on disk, stopping so the supervisor starts the new version"
        );

        std::process::exit(if cfg!(windows) { 1 } else { 0 });
    }
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

#[cfg(not(test))]
fn tick() -> Duration {
    if restart_pending().load(Ordering::Acquire) {
        if live_work() == 0 {
            let _ = begin_restart(false);
        }

        return RESTART_RETRY_EVERY;
    }
    let Ok(cli) = cli_path() else {
        return CHECK_EVERY;
    };

    match tokenstat_sync::scheduled_update_to(&cli) {
        Ok(tokenstat_sync::ScheduledUpdate::Applied(report)) => {
            restart_pending().store(true, Ordering::Release);
            record_update(&report.from, &report.to);
            let _ = stage_app_image();
            if live_work() == 0 {
                let _ = begin_restart(false);
            }
            eprintln!(
                "tokenstat-hostd: updated to {} on disk, restarting when nothing is running",
                report.to
            );
            RESTART_RETRY_EVERY
        }
        Ok(_) => CHECK_EVERY,
        Err(error) => {
            eprintln!("tokenstat-hostd: update check failed: {error}");
            CHECK_EVERY
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_update_needs_the_command_line_tool_beside_the_daemon() {
        let cli = if cfg!(windows) {
            "tokenstat.exe"
        } else {
            "tokenstat"
        };
        let root = tempfile::tempdir().unwrap();
        let daemon = root.path().join("tokenstat-hostd");
        std::fs::write(&daemon, []).unwrap();
        let error = cli_path_for(&daemon).expect_err("a daemon alone is a half install");
        assert!(error.contains("not beside this daemon"), "{error}");
        assert!(error.contains("one place"), "{error}");
        std::fs::write(root.path().join(cli), []).unwrap();
        assert_eq!(cli_path_for(&daemon).unwrap(), root.path().join(cli));
    }

    #[test]
    fn the_desktop_application_folder_is_not_a_command_line_install() {
        let root = tempfile::tempdir().unwrap();
        let daemon = root.path().join("tokenstat-hostd.exe");
        std::fs::write(&daemon, []).unwrap();
        std::fs::write(root.path().join("tokenstat.exe"), []).unwrap();
        std::fs::write(root.path().join("tokenstat"), []).unwrap();
        std::fs::write(root.path().join("Tokenstat.dll"), []).unwrap();
        let error = cli_path_for(&daemon).expect_err("the app's launcher is not the CLI");
        assert!(error.contains("desktop application"), "{error}");
    }

    #[test]
    fn a_restart_is_refused_where_nothing_would_start_this_again() {
        assert!(!crate::host_policy::supervisor_would_restart_this_process());
        assert!(!crate::host_policy::this_process_can_self_restart());
        assert!(
            !begin_restart(false),
            "begin_restart must refuse without a supervisor rather than exit the test runner"
        );
    }

    #[test]
    fn only_one_update_runs_at_a_time() {
        let held = gate().try_lock().expect("the gate starts free");
        let refused = apply("{}").expect_err("a second update must be refused");
        assert!(refused.contains("already running"), "{refused}");
        drop(held);
    }
}
