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
        .transpose()?
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

/// Which service file is actually on disk, or none.
fn service_scope() -> Value {
    #[cfg(target_os = "linux")]
    {
        if std::path::Path::new("/etc/systemd/system/tokenstat-host.service").is_file() {
            return json!("system");
        }
        if home()
            .map(|home| home.join(".config/systemd/user/tokenstat-host.service"))
            .is_some_and(|path| path.is_file())
        {
            return json!("user");
        }
        json!(null)
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
    if scope.as_str() != Some("system") {
        command.arg("--user");
    }
    let output = command
        .args([
            "--unit",
            "tokenstat-host.service",
            "--no-pager",
            "--output",
            "cat",
            "--lines",
        ])
        .arg(lines.to_string())
        .output()
        .map_err(|error| format!("Could not read the journal: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "Could not read the journal: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
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
/// daemon for any allowed device. Read at most the final 512 KiB (plus one
/// line's slack for a split), then take lines from that window.
#[cfg(target_os = "macos")]
fn bounded_tail(path: &std::path::Path, lines: u32) -> Result<Vec<String>, String> {
    use std::io::{Read, Seek, SeekFrom};
    const MAX_BYTES: u64 = 512 * 1024;
    let mut file = std::fs::File::open(path).map_err(|error| error.to_string())?;
    let len = file.metadata().map_err(|error| error.to_string())?.len();
    let start = len.saturating_sub(MAX_BYTES);
    file.seek(SeekFrom::Start(start))
        .map_err(|error| error.to_string())?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)
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
