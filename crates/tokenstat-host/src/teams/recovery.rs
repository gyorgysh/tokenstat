// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Release a shared chat whose Team run lost its guardian.
//!
//! Before the agent is born, the guardian writes down the process group it
//! is born into and this boot of the computer. A crash leaves the chat and
//! its checkout fenced. The publisher can release them on this computer
//! once tokenstat proves no process of that run is left: the computer has
//! restarted since, or the process group no longer exists. A process id that
//! was reused reads as alive and keeps the fence, never the other way round.
//! Nothing here signals a process.

use crate::{chat_receipts::team_runs::Fence, error::DispatchError, team_process};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    version: u32,
    fence: Fence,
    workspace: String,
    chat: String,
    boot: Option<String>,
    group: u32,
    /// The owner's start time where the platform needs one (Windows).
    #[serde(default)]
    born: u64,
}

fn directory() -> io::Result<PathBuf> {
    Ok(tokenstat_paths::data_dir()
        .ok_or_else(|| io::Error::other("No data directory."))?
        .join("team-run-recovery"))
}

fn file(directory: &Path, fence: &Fence) -> PathBuf {
    directory.join(format!("{}.json", fence.incarnation()))
}

/// Written before birth. If this fails, the agent is not started.
pub(super) fn remember(fence: &Fence, workspace: &str, chat: &str, anchor: u32) -> io::Result<()> {
    let (group, born) = if anchor == 0 {
        (0, 0)
    } else {
        team_process::run_owner(anchor)
    };
    use std::io::Write;
    let directory = directory()?;
    fs::create_dir_all(&directory)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    }
    let record = Record {
        version: 1,
        fence: fence.clone(),
        workspace: workspace.into(),
        chat: chat.into(),
        boot: team_process::boot_identity(),
        group,
        born,
    };
    let bytes = serde_json::to_vec(&record).map_err(io::Error::other)?;
    let path = file(&directory, fence);
    let staged = path.with_extension("tmp");
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut out = options.open(&staged)?;
    out.write_all(&bytes)?;
    out.sync_all()?;
    fs::rename(&staged, &path)
}

/// After a completion the guardian proved itself, the record has no use.
pub(super) fn forget(fence: &Fence) {
    if let Ok(directory) = directory() {
        let _ = fs::remove_file(file(&directory, fence));
    }
}

fn read(fence: &Fence) -> Option<Record> {
    let bytes = fs::read(file(&directory().ok()?, fence)).ok()?;
    if bytes.len() > 64 * 1024 {
        return None;
    }
    serde_json::from_slice::<Record>(&bytes)
        .ok()
        .filter(|record| record.version == 1 && &record.fence == fence)
}

fn proven_gone(record: &Record, current_boot: Option<&str>) -> bool {
    let restarted =
        matches!((record.boot.as_deref(), current_boot), (Some(then), Some(now)) if then != now);
    restarted || team_process::run_owner_gone(record.group, record.born)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    workspace_id: String,
    id: String,
    confirm_recovery: bool,
}

fn invalid() -> DispatchError {
    DispatchError::new(
        "invalid_request",
        "Refresh this chat's sharing details and try again.",
    )
}

pub(super) fn call(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    if method != "chat.sharing.recoverRun" {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("Team run recovery").map_err(|_| {
            DispatchError::new(
                "local_only",
                "Recover this agent run on its publishing computer.",
            )
        })?;
        if params.len() > 16 * 1024 {
            return Err(invalid());
        }
        let input: Input = serde_json::from_str(params).map_err(|_| invalid())?;
        if !input.confirm_recovery
            || !crate::chat_receipts::valid_id(&input.id)
            || input.workspace_id.is_empty()
            || input.workspace_id.len() > 4096
        {
            return Err(invalid());
        }
        let chats = crate::chat::shared();
        let Some(fence) = chats.team_run_fence(&input.workspace_id, &input.id)? else {
            return Ok(json!({"recovered":false,"reason":"none"}));
        };
        if super::runs::is_running(&fence) {
            return Err(DispatchError::new(
                "team_run_active",
                "This agent is still running. Stop it instead.",
            ));
        }
        let record = read(&fence)
            .filter(|record| record.workspace == input.workspace_id && record.chat == input.id);
        let gone = record
            .as_ref()
            .is_some_and(|record| proven_gone(record, team_process::boot_identity().as_deref()));
        // Without a record the agent was never born, which the journal
        // confirms: only a Reserved run can be closed without proof.
        let state = chats
            .recover_orphaned_run(&input.workspace_id, &input.id, &fence, gone)
            .map_err(|_| {
                DispatchError::new(
                    "team_run_unproven",
                    "tokenstat cannot prove this agent stopped. Restart the computer, then try again.",
                )
            })?;
        tokenstat_workspace::writer::clear_orphaned_run(fence.incarnation()).map_err(|_| {
            DispatchError::new(
                "team_run_recovery_required",
                "The chat is released, but its project could not be. Try again.",
            )
        })?;
        forget(&fence);
        Ok(json!({"recovered":true,"state":state}))
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(boot: Option<&str>, group: u32) -> Record {
        Record {
            version: 1,
            fence: Fence::new(format!("run_{}", "a".repeat(32)), "b".repeat(64)).unwrap(),
            workspace: "workspace".into(),
            chat: "chat".into(),
            boot: boot.map(str::to_string),
            group,
            born: 0,
        }
    }

    #[test]
    fn a_restart_proves_the_run_is_gone() {
        assert!(proven_gone(
            &record(Some("1.0"), std::process::id()),
            Some("2.0")
        ));
    }

    #[test]
    fn a_live_group_on_the_same_boot_keeps_the_fence() {
        // This test process is alive, so its id must never read as gone.
        assert!(!proven_gone(
            &record(Some("1.0"), std::process::id()),
            Some("1.0")
        ));
        assert!(!proven_gone(&record(None, std::process::id()), None));
    }

    #[test]
    fn invalid_groups_are_never_proof() {
        assert!(!proven_gone(&record(Some("1.0"), 0), Some("1.0")));
        assert!(!proven_gone(&record(Some("1.0"), 1), Some("1.0")));
    }

    #[cfg(unix)]
    #[test]
    fn a_finished_process_group_is_gone() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "exit 0"])
            .spawn()
            .unwrap();
        let pid = child.id();
        child.wait().unwrap();
        // Its id may be reused by now; then it reads as alive, which is safe.
        if team_process::run_owner_gone(pid, 0) {
            assert!(proven_gone(&record(Some("1.0"), pid), Some("1.0")));
        }
    }
}
