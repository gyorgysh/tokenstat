// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Asking an agent's own command line what is left of its plan.
//!
//! The preferred way to read a plan: the CLI holds the login, refreshes it,
//! and answers with the vendor's own figures. tokenstat never sees a token on
//! this path, so there is nothing to read from a keychain, nothing to rotate,
//! and nothing to leave signed out. Stored credentials stay as the fallback
//! for a CLI that is missing, too old, or silent.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use zeroize::Zeroizing;

/// More than any usage answer needs, so a CLI that prints something else
/// entirely is cut off rather than read into memory.
const MAX_BYTES: u64 = 256 * 1024;

/// Find `name` on the user's PATH, after the places installers put a CLI
/// that a GUI app's PATH leaves out. `extra` names more directories, relative
/// to the home directory.
pub(crate) fn program(name: &str, extra: &[&str]) -> Option<PathBuf> {
    let path = search_path(extra);
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
        #[cfg(windows)]
        for ext in ["cmd", "bat", "exe"] {
            let with_ext = candidate.with_extension(ext);
            if is_executable(&with_ext) {
                return Some(with_ext);
            }
        }
    }
    None
}

/// Run a CLI and hand back what it printed, or nothing when it failed, ran
/// past `timeout`, or said too much. Runs from the home directory, so a
/// project's own configuration cannot change the answer, with stdin closed so
/// nothing waits for a person.
pub(crate) fn run(
    program: &Path,
    args: &[&str],
    extra: &[&str],
    timeout: Duration,
) -> Option<Zeroizing<String>> {
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("PATH", search_path(extra));
    if let Some(home) = directories::BaseDirs::new() {
        command.current_dir(home.home_dir());
    }
    let mut child = command.spawn().ok()?;
    let stdout = child.stdout.take()?;
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut raw = Zeroizing::new(String::new());
        let _ = stdout.take(MAX_BYTES + 1).read_to_string(&mut raw);
        let _ = sender.send(raw);
    });
    let Ok(raw) = receiver.recv_timeout(timeout) else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    let status = child.wait().ok()?;
    (status.success() && raw.len() as u64 <= MAX_BYTES && !raw.trim().is_empty()).then_some(raw)
}

fn search_path(extra: &[&str]) -> String {
    let mut dirs = Vec::new();
    if let Some(home) = directories::BaseDirs::new() {
        dirs.push(home.home_dir().join(".local").join("bin"));
        for dir in extra {
            dirs.push(home.home_dir().join(dir));
        }
    }
    if let Ok(existing) = std::env::var("PATH") {
        for part in std::env::split_paths(&existing) {
            if !dirs.iter().any(|known| known == &part) {
                dirs.push(part);
            }
        }
    }
    std::env::join_paths(dirs)
        .ok()
        .and_then(|value| value.into_string().ok())
        .unwrap_or_else(|| std::env::var("PATH").unwrap_or_default())
}

fn is_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}
