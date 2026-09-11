// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! How a chat turn's agent is made to ask before it acts.
//!
//! Every supported CLI runs a lifecycle hook before a tool call, and every one
//! of them takes that hook as **a shell command line**, not as an argv. This
//! module owns building that line and the private configuration each backend
//! reads it from, because the gate failed silently for exactly as long as
//! those two jobs were spread across three files.
//!
//! ## What went wrong, so it cannot go wrong the same way again
//!
//! The hook command was built as `format!("{command} hook claude pre")` with no
//! quoting, and on macOS the helper lives at
//! `~/Library/Application Support/tokenstat/bin/tokenstat-hostd`. The shell
//! split that at "Application", the hook died with 127 before it could ask
//! anybody anything, and Claude Code treats a hook that fails to run as a
//! non-blocking error. The tool then ran. Standard mode had never once stopped
//! a tool call, on any backend, and nothing anywhere said so.
//!
//! Three defences now, because one is what was there before:
//!
//! 1. [`hook_command`] shell-quotes the path. That is the actual fix.
//! 2. [`stable_hook_path`] keeps a space-free symlink beside the helper and
//!    prefers it, so a future consumer that does its own naive splitting still
//!    works.
//! 3. `hook_command_survives_a_path_with_spaces` runs the built line through a
//!    real shell and checks the process started.
//!
//! ## Timeouts are part of the contract
//!
//! A hook is a process a CLI waits on, and each one caps that wait: 60 seconds
//! for Claude Code by default, 5 for grok, and 5 for whatever we wrote into
//! codex's and agy's hook files. A person cannot answer a permission card in
//! five seconds. Every hook entry this module writes therefore carries
//! [`GATE_TIMEOUT_SECONDS`], and the hook process is given a deadline slightly
//! inside it so an unanswered request becomes an explicit denial rather than a
//! killed process, which every one of these CLIs reads as "carry on".

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// How long a backend is asked to wait for a person, in seconds.
///
/// Measured, not guessed: a Claude Code `PreToolUse` hook with this timeout
/// held a tool call for 75 seconds and its denial was honoured. Five minutes
/// is long enough to walk back to the machine and short enough that a
/// forgotten card does not hold a turn open all afternoon.
pub const GATE_TIMEOUT_SECONDS: u64 = 300;

/// How long the hook process itself waits before it denies.
///
/// Inside [`GATE_TIMEOUT_SECONDS`] on purpose. A hook that is still running
/// when its CLI's timeout expires is *killed*, and a killed hook is a
/// non-blocking error that lets the tool run. Deciding first, with time to
/// spare, is what keeps an unanswered request fail-closed.
pub const GATE_DEADLINE_SECONDS: u64 = GATE_TIMEOUT_SECONDS - 20;

/// Name of the environment variable carrying [`GATE_DEADLINE_SECONDS`] to the
/// hook process, so the two halves cannot drift apart across a version skew.
pub const DEADLINE_ENV: &str = "TOKENSTAT_CHAT_GATE_DEADLINE_SECONDS";

/// A post hook only records what already happened, so it never waits on a
/// person and must not hold a turn open if the daemon is slow to answer.
pub const POST_TIMEOUT_SECONDS: u64 = 15;

/// Carries the helper's **path** to OpenCode's plugin, which spawns it as argv
/// rather than through a shell. Deliberately not the same variable as a
/// command line: handing a quoted line to `Bun.spawn` looks for a file whose
/// name contains the quotes, and the failure is a gate that never runs.
pub const HELPER_PATH_ENV: &str = "TOKENSTAT_CHAT_HOOK_PATH";

/// Quote one argument for `sh -c`.
///
/// Single quotes, with an embedded quote spelled the only way POSIX allows.
/// Nothing else is safe: a path is arbitrary user-chosen text, and this one
/// reliably contains a space on every Mac.
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// The shell command line that asks the daemon about one tool call.
pub fn hook_command(helper: &Path, flavor: &str, phase: &str) -> String {
    format!(
        "{} hook {flavor} {phase}",
        shell_quote(&stable_hook_path(helper).display().to_string())
    )
}

/// A path to the helper with no space in it, when one can be had.
///
/// Maintains `<parent>/hostd-hook` as a symlink beside the running binary and
/// returns it only if the resulting path really is space-free. Belt to
/// [`shell_quote`]'s braces: quoting is correct and sufficient today, and this
/// costs one `symlink` call to also survive a consumer that splits on
/// whitespace before a shell ever sees the line.
fn stable_hook_path(helper: &Path) -> PathBuf {
    let Some(parent) = helper.parent() else {
        return helper.to_path_buf();
    };
    let link = parent.join("hostd-hook");
    if link.to_string_lossy().contains(' ') {
        return helper.to_path_buf();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        // Replace rather than reuse: the helper is updated in place by the
        // installer, and a link left pointing at a deleted inode is worse than
        // no link at all.
        let _ = std::fs::remove_file(&link);
        if symlink(helper, &link).is_err() {
            return helper.to_path_buf();
        }
    }
    #[cfg(not(unix))]
    {
        return helper.to_path_buf();
    }
    #[cfg(unix)]
    link
}

/// Claude Code takes its whole settings document as one argument, so the hook
/// needs no file anywhere on disk and nothing to clean up afterwards.
pub fn claude_settings(helper: &Path) -> String {
    hooks_document(helper, "claude").to_string()
}

/// The `hooks.json` body for a backend that reads Claude Code's shape.
///
/// Both spellings of the wait are written, always. Claude Code and grok take
/// `timeout` in **seconds**; codex reads `timeout_ms` in **milliseconds** and
/// ignores `timeout` entirely, which is not a difference any of them announce.
/// Codex therefore killed the hook at its own short default, the tool ran, and
/// the approval the person had been shown was answered into a process that no
/// longer existed. Writing both costs one line and cannot be got wrong later.
fn hooks_document(helper: &Path, flavor: &str) -> Value {
    let entry = |phase: &str, seconds: u64| {
        json!({
            "type": "command",
            "command": hook_command(helper, flavor, phase),
            "timeout": seconds,
            "timeout_ms": seconds * 1000,
            "timeoutMs": seconds * 1000,
        })
    };
    json!({
        "hooks": {
            "PreToolUse": [{
                "matcher": "*",
                "hooks": [entry("pre", GATE_TIMEOUT_SECONDS)]
            }],
            "PostToolUse": [{
                "matcher": "*",
                "hooks": [entry("post", POST_TIMEOUT_SECONDS)]
            }]
        }
    })
}

/// A private `CODEX_HOME` holding our hooks, with the person's own credential
/// linked in so they stay signed in.
///
/// Codex gates hooks on a sha256 trust record and *silently skips* an
/// untrusted one, so `--dangerously-bypass-hook-trust` is mandatory beside
/// this and is emitted by `chat_agent_command` under the same condition.
/// Passing the home without the flag is fail-open, which is the bug this whole
/// module exists to stop.
pub fn write_codex_home(home: &Path, helper: &Path) -> Result<(), String> {
    std::fs::create_dir_all(home).map_err(|error| error.to_string())?;
    std::fs::write(
        home.join("hooks.json"),
        hooks_document(helper, "codex").to_string(),
    )
    .map_err(|error| error.to_string())?;
    link_credential(home, ".codex", "auth.json")
}

/// Agy discovers customizations from every directory it is handed, so the gate
/// travels as an extra workspace root rather than as a relocated home.
pub fn write_agy_home(home: &Path, helper: &Path) -> Result<(), String> {
    let agents = home.join(".agents");
    std::fs::create_dir_all(&agents).map_err(|error| error.to_string())?;
    let document = json!({"tokenstat": {
        "PreToolUse": [{"matcher": "*", "hooks": [{
            "type": "command",
            "command": hook_command(helper, "agy", "pre"),
            "timeout": GATE_TIMEOUT_SECONDS,
        }]}],
        "PostToolUse": [{"matcher": "*", "hooks": [{
            "type": "command",
            "command": hook_command(helper, "agy", "post"),
            "timeout": 15,
        }]}]
    }});
    std::fs::write(agents.join("hooks.json"), document.to_string())
        .map_err(|error| error.to_string())
}

/// A private `GROK_HOME` holding our hooks.
///
/// **This one is persistent per conversation, unlike the others.** Grok keeps
/// its sessions under `$GROK_HOME/sessions`, so a home rebuilt per turn would
/// take `--resume` with it and every turn would start a new conversation. The
/// caller therefore creates it once per chat and never deletes it while the
/// chat exists.
///
/// The person's `auth.json` and their `config.toml` are linked in: relocating
/// the home must not sign them out or lose the model defaults they chose.
pub fn write_grok_home(home: &Path, helper: &Path) -> Result<(), String> {
    let hooks = home.join("hooks");
    std::fs::create_dir_all(&hooks).map_err(|error| error.to_string())?;
    std::fs::write(
        hooks.join("tokenstat.json"),
        hooks_document(helper, "grok").to_string(),
    )
    .map_err(|error| error.to_string())?;
    link_credential(home, ".grok", "auth.json")?;
    // Best effort: a missing config is a grok default, not a failure.
    let _ = link_credential(home, ".grok", "config.toml");
    Ok(())
}

/// Point `target` at `source`, replacing a stale file but never silently
/// reusing a credential that points elsewhere.
#[cfg(unix)]
fn ensure_symlink(source: &Path, target: &Path) -> Result<(), String> {
    use std::os::unix::fs::symlink;

    // Attempt the link without a prior existence check: check-then-act
    // races with a concurrent creator. An existing target is only
    // tolerated when it already points at this source; a stale file
    // (or a link elsewhere) is replaced so a previous credential is
    // never silently reused.
    match symlink(source, target) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            if std::fs::read_link(target).is_ok_and(|p| p.as_path() == source) {
                return Ok(());
            }
            // A regular file from a previous run: replace it. Anything
            // else (e.g. a directory in the way) surfaces as an error.
            std::fs::remove_file(target).map_err(|error| error.to_string())?;
            symlink(source, target).map_err(|error| error.to_string())
        }
        Err(error) => Err(error.to_string()),
    }
}

/// Link one file from the person's own agent directory into a private home.
///
/// A symlink, never a copy. This is somebody else's credential: tokenstat
/// reads it only by pointing the tool that owns it back at its own file, and a
/// copy would be a second place for a token to live and go stale.
fn link_credential(home: &Path, directory: &str, file: &str) -> Result<(), String> {
    #[cfg(unix)]
    {
        // Not `$HOME`: a headless daemon started by systemd has none, and the
        // credential to link sits under the real home whether or not the
        // unit's environment names it.
        let Some(user_home) = tokenstat_paths::home_dir() else {
            return Ok(());
        };
        let source = user_home.join(directory).join(file);
        let target = home.join(file);
        if !source.exists() {
            return Ok(());
        }
        ensure_symlink(&source, &target)
    }
    #[cfg(not(unix))]
    {
        let _ = (home, directory, file);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quoting_survives_the_paths_this_app_actually_uses() {
        assert_eq!(
            shell_quote("/Users/a/Library/Application Support/tokenstat/bin/tokenstat-hostd"),
            "'/Users/a/Library/Application Support/tokenstat/bin/tokenstat-hostd'"
        );
        assert_eq!(
            shell_quote("/tmp/o'brien/hostd"),
            r"'/tmp/o'\''brien/hostd'"
        );
    }

    /// The regression test for the defect this module was written around.
    ///
    /// Not a string comparison: the failure was that a real shell could not
    /// start the process, so a real shell has to be the thing that says it can.
    #[test]
    #[cfg(unix)]
    fn hook_command_survives_a_path_with_spaces() {
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;
        use std::process::Command;

        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("Application Support").join("bin");
        std::fs::create_dir_all(&directory).unwrap();
        let helper = directory.join("tokenstat-hostd");
        let marker = root.path().join("fired");
        let mut script = std::fs::File::create(&helper).unwrap();
        writeln!(script, "#!/bin/sh").unwrap();
        writeln!(script, "printf '%s' \"$1 $2 $3\" > {}", marker.display()).unwrap();
        drop(script);
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();

        let line = hook_command(&helper, "claude", "pre");
        let status = Command::new("/bin/sh")
            .arg("-c")
            .arg(&line)
            .status()
            .expect("the hook line must be runnable by a shell");
        assert!(status.success(), "hook line did not run: {line}");
        assert_eq!(std::fs::read_to_string(&marker).unwrap(), "hook claude pre");
    }

    #[test]
    fn every_written_hook_waits_long_enough_for_a_person() {
        let helper = PathBuf::from("/tmp/tokenstat/bin/tokenstat-hostd");
        let settings: Value = serde_json::from_str(&claude_settings(&helper)).unwrap();
        for flavor in ["claude", "grok", "codex", "agy"] {
            let document = if flavor == "claude" {
                settings.clone()
            } else {
                hooks_document(&helper, flavor)
            };
            let entry = &document["hooks"]["PreToolUse"][0]["hooks"][0];
            assert_eq!(entry["timeout"], GATE_TIMEOUT_SECONDS, "{flavor} seconds");
            // Codex reads only this one, in milliseconds. A hook entry that
            // carries the wait in one spelling is a hook some backend kills at
            // its own default while a person is still reading the card.
            assert_eq!(
                entry["timeout_ms"],
                GATE_TIMEOUT_SECONDS * 1000,
                "{flavor} milliseconds"
            );
        }
        // The hook has to answer before its CLI gives up, or it is killed and
        // the tool runs anyway. A compile-time check, because getting this
        // ordering wrong reopens the fail-open the whole module exists to
        // close and no test run should be what discovers it.
        const _: () = assert!(GATE_DEADLINE_SECONDS < GATE_TIMEOUT_SECONDS);
    }

    #[test]
    #[cfg(unix)]
    fn a_space_free_helper_directory_gets_a_link_and_a_spaced_one_is_quoted() {
        let root = tempfile::tempdir().unwrap();
        let plain = root.path().join("bin");
        std::fs::create_dir_all(&plain).unwrap();
        let helper = plain.join("tokenstat-hostd");
        std::fs::write(&helper, b"#!/bin/sh\n").unwrap();
        let line = hook_command(&helper, "codex", "post");
        assert!(line.contains("hostd-hook"), "{line}");

        let spaced = root.path().join("Application Support");
        std::fs::create_dir_all(&spaced).unwrap();
        let spaced_helper = spaced.join("tokenstat-hostd");
        std::fs::write(&spaced_helper, b"#!/bin/sh\n").unwrap();
        let spaced_line = hook_command(&spaced_helper, "codex", "post");
        assert!(spaced_line.starts_with('\''), "{spaced_line}");
    }

    #[test]
    #[cfg(unix)]
    fn a_credential_link_is_reused_when_correct_and_replaced_when_stale() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("auth.json");
        std::fs::write(&source, b"{}").unwrap();
        let target = root.path().join("home").join("auth.json");
        std::fs::create_dir_all(target.parent().unwrap()).unwrap();

        ensure_symlink(&source, &target).unwrap();
        assert_eq!(std::fs::read_link(&target).unwrap(), source);
        // Second run with the same source is a no-op, not an error.
        ensure_symlink(&source, &target).unwrap();

        // A stale regular file is replaced, never silently reused.
        std::fs::remove_file(&target).unwrap();
        std::fs::write(&target, b"stale").unwrap();
        ensure_symlink(&source, &target).unwrap();
        assert_eq!(std::fs::read_link(&target).unwrap(), source);

        // A link elsewhere is repointed too.
        let other = root.path().join("other.json");
        std::fs::write(&other, b"{}").unwrap();
        std::fs::remove_file(&target).unwrap();
        std::os::unix::fs::symlink(&other, &target).unwrap();
        ensure_symlink(&source, &target).unwrap();
        assert_eq!(std::fs::read_link(&target).unwrap(), source);
    }
}
