// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Is this machine finished being set up, and why is it unhappy.
//!
//! One call rather than eight, because the setup wizard, the machine's page in
//! the app and `tokenstat host status` all ask the same question and must not
//! answer it differently. And one call for the log, so a person can see why a
//! machine is refusing to work without opening an SSH session to read it.

use serde::Deserialize;
use serde_json::{Value, json};

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "host.provisionStatus" => status(),
        "host.logs" => logs(params),
        _ => return None,
    })
}

fn status() -> Result<Value, String> {
    let identity =
        tokenstat_identity::MachineIdentity::load_or_create().map_err(|error| error.to_string())?;
    let policy = crate::host_policy::call("host.policy", "{}")
        .transpose()?
        .unwrap_or(Value::Null);
    let remote = crate::remote::call("remote.status", "{}")
        .transpose()
        .map_err(|e| e.to_string())?
        .unwrap_or(Value::Null);
    let account = match tokenstat_sync::sync_status(None) {
        Ok(status) => json!({
            "signedIn": true,
            "handle": status.handle,
            "tier": status.tier,
        }),
        // Signed out is an answer. Anything else is the account server having
        // a minute, and reporting that as signed out would send somebody to
        // sign in again for no reason.
        Err(error) if error.is_unauthenticated() => json!({"signedIn": false}),
        Err(error) => json!({"signedIn": null, "error": error.to_string()}),
    };
    let (allowed, pending) = crate::workspace_policy::counts()?;
    Ok(json!({
        // No desktop app exists for this platform, so the console is the only
        // thing at this machine. It is what the wizard branches on, and it is
        // not a guess about whether a screen is plugged in.
        "headless": cfg!(not(any(target_os = "macos", windows))),
        "serviceScope": service_scope(),
        "runsAs": runs_as(),
        "alwaysOn": policy.get("alwaysOn").cloned().unwrap_or(Value::Null),
        "account": account,
        "machineName": tokenstat_identity::machine_label(),
        "machineKey": identity.public_key_hex(),
        "keyFingerprint": identity.fingerprint(),
        "protocolVersion": crate::PROTOCOL_VERSION,
        "hostVersion": env!("CARGO_PKG_VERSION"),
        "allowedDevices": allowed,
        "pendingRequests": pending,
        "agents": agents(),
        "folders": folders(),
        "tunnel": {
            "enabled": remote.get("tunnel").cloned().unwrap_or(Value::Null),
            "online": remote.get("tunnelOnline").cloned().unwrap_or(Value::Null),
            "error": remote.get("tunnelError").cloned().unwrap_or(Value::Null),
        },
    }))
}

#[cfg(feature = "local-host")]
fn folders() -> usize {
    crate::workspaces::read().workspaces.len()
}

#[cfg(not(feature = "local-host"))]
fn folders() -> usize {
    0
}

/// What this machine can run, and whether it is signed in to it.
///
/// `signedIn` stays three-valued: a tool whose login this machine has no way
/// to inspect answers null, and always did. What changed is that some of them
/// can now be inspected, by looking for the credential store the tool itself
/// wrote, so a fresh server no longer claims nothing is knowable when the
/// plain fact is that nobody has signed in yet. `readiness` carries the states
/// a screen needs; see `agent_readiness`. Guessing is still forbidden.
#[cfg(feature = "local-host")]
fn agents() -> Value {
    let catalog = crate::launcher::catalog();
    Value::Array(
        catalog
            .as_array()
            .map(|profiles| {
                profiles
                    .iter()
                    .filter(|profile| profile["id"].as_str() != Some("shell"))
                    .map(|profile| {
                        let id = profile["id"].as_str().unwrap_or_default();
                        let installed = profile["installed"].as_bool().unwrap_or(false);
                        let mut entry = json!({
                            "id": profile["id"],
                            "name": profile["name"],
                            "installed": installed,
                        });
                        if let Some(state) =
                            crate::agent_readiness::describe(id, installed).as_object()
                        {
                            for (key, value) in state {
                                entry[key] = value.clone();
                            }
                        }
                        entry
                    })
                    .collect()
            })
            .unwrap_or_default(),
    )
}

#[cfg(not(feature = "local-host"))]
fn agents() -> Value {
    Value::Array(Vec::new())
}

/// The service scope of this host, when it can be identified.
fn service_scope() -> Value {
    #[cfg(target_os = "linux")]
    {
        // A system unit belonging to another account may exist alongside
        // this user's host. Inspect this process, not global unit-file presence.
        std::fs::read_to_string("/proc/self/cgroup")
            .ok()
            .and_then(|groups| linux_service_scope(&groups))
            .map(|scope| json!(scope))
            .unwrap_or(Value::Null)
    }
    #[cfg(target_os = "macos")]
    {
        match home().map(|home| home.join("Library/LaunchAgents/ai.tokenstat.hostd.plist")) {
            Some(path) if path.is_file() => json!("user"),
            _ => json!(null),
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        json!(null)
    }
}

#[cfg(any(target_os = "linux", test))]
fn linux_service_scope(groups: &str) -> Option<&'static str> {
    groups.lines().find_map(|line| {
        let path = line.splitn(3, ':').nth(2)?;
        let parts: Vec<_> = path.split('/').collect();
        if !parts.contains(&"tokenstat-host.service") {
            return None;
        }
        match parts.get(1).copied() {
            Some("system.slice") => Some("system"),
            Some("user.slice") => Some("user"),
            _ => None,
        }
    })
}

/// The account this host, and therefore every agent it launches, runs as.
///
/// Said out loud because a root install gives every agent root, and that is a
/// fact to put next to the operating system version rather than to discover.
fn runs_as() -> Value {
    #[cfg(unix)]
    {
        let uid = unsafe { libc::getuid() };
        let name = std::env::var("USER")
            .or_else(|_| std::env::var("LOGNAME"))
            .ok()
            .filter(|name| !name.is_empty());
        json!({
            "uid": uid,
            "name": name,
            "root": uid == 0,
        })
    }
    #[cfg(not(unix))]
    {
        json!(null)
    }
}

/// macOS stores the launch agent and host logs under the current home.
#[cfg(target_os = "macos")]
fn home() -> Option<std::path::PathBuf> {
    directories::BaseDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

#[derive(Deserialize)]
struct LogParams {
    #[serde(default)]
    lines: Option<u32>,
}

/// The tail of this host's own log, so somebody can see why it is unhappy
/// without opening a shell on the machine.
fn logs(params: &str) -> Result<Value, String> {
    let p: LogParams = serde_json::from_str(params.trim()).unwrap_or(LogParams { lines: None });
    let lines = p.lines.unwrap_or(200).clamp(1, 5000);
    let text = read_logs(lines)?;
    Ok(json!({"lines": lines, "text": text}))
}

#[cfg(target_os = "linux")]
fn read_logs(lines: u32) -> Result<String, String> {
    let scope = service_scope();
    let mut command = std::process::Command::new("journalctl");
    match scope.as_str() {
        Some("system") => {}
        Some("user") => { command.arg("--user"); }
        _ => return Err("This host is not running in a recognized systemd service. Check the console that started it for logs.".into()),
    }
    command
        .args([
            "--unit",
            "tokenstat-host.service",
            "--no-pager",
            "--output",
            "cat",
            "--lines",
        ])
        .arg(lines.to_string());
    journal_output(&mut command)
}

#[cfg(any(target_os = "linux", test))]
fn journal_output(command: &mut std::process::Command) -> Result<String, String> {
    use std::process::Stdio;
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null())
        .spawn()
        .map_err(|error| format!("Could not read the journal: {error}"))?;
    let stdout = child.stdout.take().ok_or("Journal output is unavailable")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Journal errors are unavailable")?;
    // Drain both streams so a full stderr pipe cannot block stdout. Retain
    // only their tails: line counts do not bound an individual journal entry.
    std::thread::scope(|scope| {
        let errors = scope.spawn(move || output_tail(stderr));
        let output = output_tail(stdout);
        if output.is_err() {
            let _ = child.kill();
        }
        let status = wait_bounded(&mut child).map_err(|error| error.to_string())?;
        let errors = errors
            .join()
            .map_err(|_| "Journal error reader stopped")??;
        let output = output?;
        if !status.success() {
            return Err(format!("Could not read the journal: {}", errors.trim()));
        }
        Ok(output)
    })
}

/// Wait for a helper with a bound, so a hung reader cannot hang dispatch.
///
/// `journalctl` with a line count normally exits at once. If it does not,
/// kill it and report that rather than blocking the caller forever.
#[cfg(any(target_os = "linux", test))]
fn wait_bounded(child: &mut std::process::Child) -> std::io::Result<std::process::ExitStatus> {
    use std::time::{Duration, Instant};
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        match child.try_wait()? {
            Some(status) => return Ok(status),
            None if Instant::now() >= deadline => {
                let _ = child.kill();
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "Could not read the journal: timed out",
                ));
            }
            None => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

#[cfg(any(target_os = "linux", test))]
fn output_tail(mut reader: impl std::io::Read) -> Result<String, String> {
    use std::collections::VecDeque;
    const MAX_BYTES: usize = 512 * 1024;
    let mut tail = VecDeque::with_capacity(MAX_BYTES);
    let mut chunk = [0; 8192];
    let mut truncated = false;
    loop {
        let count = match reader.read(&mut chunk) {
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.to_string()),
        };
        if count == 0 {
            break;
        }
        let excess = (tail.len() + count).saturating_sub(MAX_BYTES);
        if excess > 0 {
            tail.drain(..excess);
            truncated = true;
        }
        tail.extend(&chunk[..count]);
    }
    let bytes: Vec<u8> = tail.into_iter().collect();
    let text = String::from_utf8_lossy(&bytes);
    if truncated {
        Ok(format!("[Earlier log output omitted]\n{text}"))
    } else {
        Ok(text.into_owned())
    }
}

#[cfg(target_os = "macos")]
fn read_logs(lines: u32) -> Result<String, String> {
    let dir = home()
        .map(|home| home.join("Library/Logs/tokenstat"))
        .ok_or("No home directory")?;
    let mut collected = String::new();
    for name in ["hostd.out.log", "hostd.err.log"] {
        let path = dir.join(name);
        if !path.is_file() {
            continue;
        }
        let tail = bounded_tail(&path, lines)?;
        if tail.is_empty() {
            continue;
        }
        collected.push_str(&format!("--- {name}\n{}\n", tail.join("\n")));
    }
    if collected.is_empty() {
        return Err("This host has not written a log yet.".into());
    }
    Ok(collected)
}

/// Last `lines` of a file without reading it whole.
///
/// Log files are unbounded; `read_to_string` on a multi-GB file OOMs the
/// daemon for any allowed device. Read at most the final 512 KiB from the
/// measured snapshot, then take lines from that window.
#[cfg(target_os = "macos")]
fn bounded_tail(path: &std::path::Path, lines: u32) -> Result<Vec<String>, String> {
    let mut file = std::fs::File::open(path).map_err(|error| error.to_string())?;
    let len = file.metadata().map_err(|error| error.to_string())?.len();
    tail_snapshot(&mut file, len, lines)
}

#[cfg(any(target_os = "macos", test))]
fn tail_snapshot(
    file: &mut (impl std::io::Read + std::io::Seek),
    len: u64,
    lines: u32,
) -> Result<Vec<String>, String> {
    use std::io::{Read, SeekFrom};
    const MAX_BYTES: u64 = 512 * 1024;
    let start = len.saturating_sub(MAX_BYTES);
    file.seek(SeekFrom::Start(start))
        .map_err(|error| error.to_string())?;
    let mut buf = Vec::new();
    file.take(len - start)
        .read_to_end(&mut buf)
        .map_err(|error| error.to_string())?;
    let text = String::from_utf8_lossy(&buf);
    let mut all: Vec<&str> = text.lines().collect();
    // If we started mid-file, the first line is a fragment; drop it unless we
    // read the whole file.
    if start > 0 && !all.is_empty() {
        all.remove(0);
    }
    Ok(all
        .into_iter()
        .rev()
        .take(lines as usize)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .map(str::to_owned)
        .collect())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read_logs(_: u32) -> Result<String, String> {
    Err("This platform keeps the host's log somewhere this cannot read.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn journal_scope_belongs_to_the_running_process() {
        assert_eq!(
            linux_service_scope("0::/system.slice/tokenstat-host.service"),
            Some("system")
        );
        assert_eq!(
            linux_service_scope(
                "0::/user.slice/user-1000.slice/user@1000.service/app.slice/tokenstat-host.service"
            ),
            Some("user")
        );
        assert_eq!(linux_service_scope("0::/user.slice/session-3.scope"), None);
        assert_eq!(
            linux_service_scope("0::/system.slice/tokenstat-host.service.other"),
            None
        );
        assert_eq!(linux_service_scope("malformed"), None);
    }

    #[test]
    fn file_growth_after_measurement_cannot_expand_the_snapshot() {
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(b"before\n").unwrap();
        let measured = file.metadata().unwrap().len();
        file.write_all(&vec![b'x'; 1024 * 1024]).unwrap();
        assert_eq!(tail_snapshot(&mut file, measured, 20).unwrap(), ["before"]);
        let len = file.metadata().unwrap().len();
        assert!(tail_snapshot(&mut file, len, 20).unwrap().is_empty());
    }

    #[test]
    fn journal_retains_recent_output_with_a_fixed_byte_budget() {
        let mut data = vec![b'x'; 2 * 1024 * 1024];
        data.extend_from_slice(b"\nlatest entry\n");
        let text = output_tail(data.as_slice()).unwrap();
        assert!(text.starts_with("[Earlier log output omitted]\n"));
        assert!(text.ends_with("latest entry\n"));
        assert!(text.len() < 512 * 1024 + 64);
        assert_eq!(output_tail(b"small\n".as_slice()).unwrap(), "small\n");
    }

    #[test]
    #[cfg(unix)]
    fn journal_capture_drains_both_pipes_and_preserves_errors() {
        let mut command = std::process::Command::new("sh");
        command.args(["-c", "i=0; while [ $i -lt 40000 ]; do printf 'stderr detail for fixture\n' >&2; i=$((i+1)); done; printf 'last error\n' >&2; exit 23"]);
        let error = journal_output(&mut command).unwrap_err();
        assert!(error.contains("last error"));
        assert!(error.len() < 512 * 1024 + 128);
    }
}
