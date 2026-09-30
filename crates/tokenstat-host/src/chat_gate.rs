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
        helper.to_path_buf()
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

/// A private `CODEX_HOME` retaining this conversation's sessions, with the
/// person's credential linked in so they stay signed in. Only hooks are
/// temporary. Removing the home would destroy Codex's resume history.
///
/// Codex gates hooks on a sha256 trust record and *silently skips* an
/// untrusted one, so `--dangerously-bypass-hook-trust` is mandatory beside
/// this and is emitted by `chat_agent_command` under the same condition.
/// Passing the home without the flag is fail-open, which is the bug this whole
/// module exists to stop.
pub fn write_codex_home(home: &Path, helper: Option<&Path>) -> Result<(), String> {
    std::fs::create_dir_all(home).map_err(|error| error.to_string())?;
    if let Some(helper) = helper {
        std::fs::write(
            home.join("hooks.json"),
            hooks_document(helper, "codex").to_string(),
        )
        .map_err(|error| error.to_string())?;
    } else {
        clear_codex_hooks(home)?;
    }
    link_credential(home, ".codex", "auth.json")
}

/// Retire the hook configuration without touching Codex's session history.
pub fn clear_codex_hooks(home: &Path) -> Result<(), String> {
    match std::fs::remove_file(home.join("hooks.json")) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.to_string()),
    }
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

/// Muse could not be given a private home for this turn's note.
pub(crate) const MUSE_NOTE_PREPARE: &str = "muse could not prepare the next step.";

/// The person's muse sign-in is present, but this turn could not point at it.
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) const MUSE_SIGN_IN: &str =
    "muse is signed in, but this turn could not use that sign-in.";

/// One PostLLMCall command appended to a muse settings document.
///
/// An existing object is kept. A missing or non-object `hooks` map is replaced.
/// The new entry is appended, so a Stop hook and earlier PostLLMCall entries stay.
#[cfg_attr(not(unix), allow(dead_code))]
fn muse_settings_with_note(existing: Option<&Value>, command: &str) -> Value {
    let mut root = match existing {
        Some(Value::Object(map)) => map.clone(),
        _ => {
            let mut map = serde_json::Map::new();
            map.insert("schema_version".to_string(), json!(1));
            map
        }
    };
    if !root.contains_key("schema_version") {
        root.insert("schema_version".to_string(), json!(1));
    }
    let mut hooks = match root.get("hooks") {
        Some(Value::Object(map)) => map.clone(),
        _ => serde_json::Map::new(),
    };
    let mut post = match hooks.get("PostLLMCall") {
        Some(Value::Array(items)) => items.clone(),
        _ => Vec::new(),
    };
    post.push(json!({
        "matcher": "*",
        "hooks": [{
            "type": "command",
            "command": command,
            "timeout": POST_TIMEOUT_SECONDS,
        }]
    }));
    hooks.insert("PostLLMCall".to_string(), Value::Array(post));
    root.insert("hooks".to_string(), Value::Object(hooks));
    Value::Object(root)
}

/// A path a muse settings command can name without quoting.
///
/// The command is the script path alone. A space, quote, or backslash would
/// be split or swallowed before the script runs.
#[cfg(unix)]
fn path_is_bare(path: &Path) -> bool {
    let Some(text) = path.to_str() else {
        return false;
    };
    !text
        .chars()
        .any(|c| c.is_whitespace() || c == '\'' || c == '"' || c == '\\')
}

/// A fresh private directory whose `hook` path is safe to put in settings.
#[cfg(unix)]
fn muse_hook_directory() -> Result<PathBuf, String> {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).map_err(|_| MUSE_NOTE_PREPARE.to_string())?;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let base = std::env::temp_dir();
    let base = if path_is_bare(&base) {
        base
    } else {
        let fallback = PathBuf::from("/tmp");
        if path_is_bare(&fallback) {
            fallback
        } else {
            return Err(MUSE_NOTE_PREPARE.to_string());
        }
    };
    let root = base.join(format!("tokenstat-muse-{hex}"));
    if !path_is_bare(&root.join("hook")) {
        return Err(MUSE_NOTE_PREPARE.to_string());
    }
    Ok(root)
}

/// The script muse runs after a model step. The turn credential stays in the file.
#[cfg(unix)]
fn muse_hook_script(hostd: &Path, socket: &Path, turn_file: &Path) -> Result<String, String> {
    let hostd = hostd.to_str().ok_or(MUSE_NOTE_PREPARE)?;
    let socket = socket.to_str().ok_or(MUSE_NOTE_PREPARE)?;
    let turn_file = turn_file.to_str().ok_or(MUSE_NOTE_PREPARE)?;
    Ok(format!(
        "#!/bin/sh\nexport TOKENSTAT_CHAT_SOCKET={socket}\nexport TOKENSTAT_CHAT_TURN_FILE={turn}\nexec {hostd} hook muse post\n",
        socket = shell_quote(socket),
        turn = shell_quote(turn_file),
        hostd = shell_quote(hostd),
    ))
}

/// The person's settings object, or nothing when it cannot be used as one.
#[cfg(unix)]
fn read_muse_settings_object(user_config: Option<&Path>) -> Option<Value> {
    let dir = user_config?;
    let bytes = std::fs::read(dir.join("settings.json")).ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    value.is_object().then_some(value)
}

#[cfg(unix)]
fn create_private_dir(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(path)
        .map_err(|_| MUSE_NOTE_PREPARE.to_string())
}

#[cfg(unix)]
fn write_private_file(path: &Path, bytes: &[u8], mode: u32) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)
        .map_err(|_| MUSE_NOTE_PREPARE.to_string())?;
    file.write_all(bytes)
        .map_err(|_| MUSE_NOTE_PREPARE.to_string())
}

/// Point the private muse directory at the person's config, except settings.
///
/// Settings are rewritten for this turn. Everything else is a symlink, so a
/// credential is never copied. `auth.json` failing to link is its own error:
/// the turn would otherwise run signed out.
#[cfg(unix)]
fn mirror_muse_config(user_config: Option<&Path>, private_muse_dir: &Path) -> Result<(), String> {
    let Some(user_config) = user_config else {
        return Ok(());
    };
    if !user_config.is_dir() {
        return Ok(());
    }
    let entries = std::fs::read_dir(user_config).map_err(|_| MUSE_NOTE_PREPARE.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|_| MUSE_NOTE_PREPARE.to_string())?;
        let name_owned = entry.file_name();
        let Some(name) = name_owned.to_str() else {
            return Err(MUSE_NOTE_PREPARE.to_string());
        };
        if name == "settings.json" {
            continue;
        }
        if ensure_symlink(&entry.path(), &private_muse_dir.join(name)).is_err() {
            if name == "auth.json" {
                return Err(MUSE_SIGN_IN.to_string());
            }
            return Err(MUSE_NOTE_PREPARE.to_string());
        }
    }
    Ok(())
}

/// Build `root/muse/settings.json` and `root/hook` for one turn.
///
/// `root` is what muse sees as `XDG_CONFIG_HOME`. A second call on a root that
/// already exists fails before it touches the first files.
#[cfg(unix)]
fn install_muse_note_home_at(
    root: &Path,
    user_config: Option<&Path>,
    hostd: &Path,
    socket: &Path,
    turn_file: &Path,
) -> Result<(), String> {
    let hook = root.join("hook");
    if !path_is_bare(&hook) {
        return Err(MUSE_NOTE_PREPARE.to_string());
    }
    let script = muse_hook_script(hostd, socket, turn_file)?;
    let command = hook.to_str().ok_or(MUSE_NOTE_PREPARE)?;
    let existing = read_muse_settings_object(user_config);
    let settings = muse_settings_with_note(existing.as_ref(), command);
    let settings_bytes =
        serde_json::to_vec(&settings).map_err(|_| MUSE_NOTE_PREPARE.to_string())?;
    create_private_dir(root)?;
    let installed = (|| -> Result<(), String> {
        let muse = root.join("muse");
        create_private_dir(&muse)?;
        mirror_muse_config(user_config, &muse)?;
        write_private_file(&hook, script.as_bytes(), 0o700)?;
        write_private_file(&muse.join("settings.json"), &settings_bytes, 0o600)?;
        Ok(())
    })();
    if let Err(error) = installed {
        remove_muse_home(root);
        return Err(error);
    }
    Ok(())
}

/// A private config home for one muse turn, or `None` where that home is not used.
pub(crate) fn install_muse_note_home(
    user_config: Option<&Path>,
    hostd: &Path,
    socket: &Path,
    turn_file: &Path,
) -> Result<Option<PathBuf>, String> {
    #[cfg(unix)]
    {
        let root = muse_hook_directory()?;
        install_muse_note_home_at(&root, user_config, hostd, socket, turn_file)?;
        Ok(Some(root))
    }
    #[cfg(not(unix))]
    {
        let _ = (user_config, hostd, socket, turn_file, MUSE_NOTE_PREPARE);
        Ok(None)
    }
}

/// Delete a private muse home. Symlinks are removed. Their targets are not.
pub(crate) fn remove_muse_home(root: &Path) {
    if let Ok(entries) = std::fs::read_dir(root.join("muse")) {
        for entry in entries.flatten() {
            let _ = std::fs::remove_file(entry.path());
        }
    }
    let _ = std::fs::remove_dir_all(root);
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
    fn codex_session_history_survives_hook_cleanup_and_autonomy_changes() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("codex-home");
        let rollout = home.join("sessions").join("rollout.jsonl");
        std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
        std::fs::write(&rollout, b"session history").unwrap();
        let helper = Path::new("/tmp/tokenstat-hostd");
        write_codex_home(&home, Some(helper)).unwrap();
        assert!(home.join("hooks.json").is_file());
        clear_codex_hooks(&home).unwrap();
        assert!(!home.join("hooks.json").exists());
        assert_eq!(std::fs::read(&rollout).unwrap(), b"session history");
        write_codex_home(&home, Some(helper)).unwrap();
        write_codex_home(&home, None).unwrap();
        assert!(!home.join("hooks.json").exists());
        assert_eq!(std::fs::read(&rollout).unwrap(), b"session history");
        clear_codex_hooks(&home).unwrap();
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

    #[test]
    fn muse_settings_keep_an_existing_document_and_append_one_post_hook() {
        let existing = json!({
            "schema_version": 2,
            "provider": "meta",
            "hooks": {
                "Stop": [{"matcher": "stop"}],
                "PostLLMCall": [{"matcher": "old", "hooks": []}]
            }
        });
        let merged = muse_settings_with_note(Some(&existing), "/tmp/tokenstat-muse-hook");
        assert_eq!(merged["schema_version"], 2_u64);
        assert_eq!(merged["provider"], "meta");
        assert_eq!(merged["hooks"]["Stop"][0]["matcher"], "stop");
        assert_eq!(merged["hooks"]["PostLLMCall"][0]["matcher"], "old");
        assert_eq!(merged["hooks"]["PostLLMCall"].as_array().unwrap().len(), 2);
        let added = &merged["hooks"]["PostLLMCall"][1];
        assert_eq!(added["matcher"], "*");
        assert_eq!(added["hooks"][0]["type"], "command");
        assert_eq!(added["hooks"][0]["command"], "/tmp/tokenstat-muse-hook");
        assert_eq!(added["hooks"][0]["timeout"], POST_TIMEOUT_SECONDS);
        assert!(added["hooks"][0].get("timeoutMs").is_none());
        assert!(added["hooks"][0].get("timeout_ms").is_none());

        let hooks_replaced =
            muse_settings_with_note(Some(&json!({"hooks": "nope"})), "/tmp/tokenstat-muse-hook");
        assert_eq!(hooks_replaced["schema_version"], 1_u64);
        assert_eq!(
            hooks_replaced["hooks"]["PostLLMCall"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(hooks_replaced["hooks"].get("Stop").is_none());

        let post_replaced = muse_settings_with_note(
            Some(&json!({
                "schema_version": 2,
                "hooks": {
                    "Stop": [{"matcher": "stop"}],
                    "PostLLMCall": "nope"
                }
            })),
            "/tmp/tokenstat-muse-hook",
        );
        assert_eq!(post_replaced["schema_version"], 2_u64);
        assert_eq!(post_replaced["hooks"]["Stop"][0]["matcher"], "stop");
        assert_eq!(
            post_replaced["hooks"]["PostLLMCall"]
                .as_array()
                .unwrap()
                .len(),
            1
        );

        let fresh = muse_settings_with_note(None, "/tmp/tokenstat-muse-hook");
        assert_eq!(fresh["schema_version"], 1_u64);
        assert_eq!(fresh["hooks"]["PostLLMCall"].as_array().unwrap().len(), 1);

        let nope = json!("nope");
        let from_string = muse_settings_with_note(Some(&nope), "/tmp/tokenstat-muse-hook");
        assert_eq!(from_string["schema_version"], 1_u64);
        assert_eq!(
            from_string["hooks"]["PostLLMCall"]
                .as_array()
                .unwrap()
                .len(),
            1
        );

        let preserved = muse_settings_with_note(
            Some(&json!({"provider": "meta"})),
            "/tmp/tokenstat-muse-hook",
        );
        assert_eq!(preserved["schema_version"], 1_u64);
        assert_eq!(preserved["provider"], "meta");
    }

    #[cfg(unix)]
    fn muse_scratch_dir() -> Option<tempfile::TempDir> {
        if path_is_bare(&std::env::temp_dir()) {
            Some(tempfile::tempdir().unwrap())
        } else if path_is_bare(Path::new("/tmp")) {
            Some(tempfile::tempdir_in("/tmp").unwrap())
        } else {
            None
        }
    }

    #[cfg(unix)]
    struct MuseHomeGuard(Option<PathBuf>);

    #[cfg(unix)]
    impl Drop for MuseHomeGuard {
        fn drop(&mut self) {
            if let Some(root) = self.0.take() {
                remove_muse_home(&root);
            }
        }
    }

    #[test]
    #[cfg(unix)]
    fn muse_note_home_installs_a_private_hook_and_leaves_the_user_config() {
        use std::os::unix::fs::PermissionsExt;

        let Some(parent) = muse_scratch_dir() else {
            return;
        };
        let user = parent.path().join("user-muse");
        let root = parent.path().join("private");
        std::fs::create_dir_all(user.join("skills")).unwrap();
        let user_settings = br#"{"provider":"meta","extra":true}"#;
        std::fs::write(user.join("settings.json"), user_settings).unwrap();
        std::fs::write(user.join("auth.json"), b"signed-in").unwrap();
        std::fs::write(user.join("skills").join("keep.txt"), b"keep").unwrap();
        std::fs::write(user.join("mcp.json"), b"{}").unwrap();

        install_muse_note_home_at(
            &root,
            Some(&user),
            Path::new("/tmp/tokenstat-hostd"),
            Path::new("/tmp/tokenstat.sock"),
            Path::new("/tmp/tokenstat.turn"),
        )
        .unwrap();

        let mode = |path: &Path| {
            std::fs::symlink_metadata(path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777
        };
        assert_eq!(mode(&root), 0o700);
        assert_eq!(mode(&root.join("muse")), 0o700);
        let settings_path = root.join("muse").join("settings.json");
        let settings_meta = std::fs::symlink_metadata(&settings_path).unwrap();
        assert!(settings_meta.file_type().is_file());
        assert!(!settings_meta.file_type().is_symlink());
        assert_eq!(settings_meta.permissions().mode() & 0o777, 0o600);

        let parsed: Value =
            serde_json::from_slice(&std::fs::read(&settings_path).unwrap()).unwrap();
        let command = parsed["hooks"]["PostLLMCall"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        assert_eq!(command, root.join("hook").to_str().unwrap());
        assert!(!command.contains(' ') && !command.contains('\'') && !command.contains('"'));
        assert_eq!(
            parsed["hooks"]["PostLLMCall"][0]["hooks"][0]["timeout"],
            POST_TIMEOUT_SECONDS
        );
        assert_eq!(parsed["provider"], "meta");
        assert_eq!(parsed["extra"], true);
        assert_eq!(parsed["schema_version"], 1_u64);
        assert_eq!(parsed["hooks"]["PostLLMCall"].as_array().unwrap().len(), 1);

        assert_eq!(mode(&root.join("hook")), 0o700);
        let hook_text = std::fs::read_to_string(root.join("hook")).unwrap();
        assert!(hook_text.contains(&shell_quote("/tmp/tokenstat.sock")));
        assert!(hook_text.contains(&shell_quote("/tmp/tokenstat.turn")));
        let exec_line = format!(
            "exec {} hook muse post",
            shell_quote("/tmp/tokenstat-hostd")
        );
        assert!(hook_text.contains(&exec_line), "{hook_text}");

        assert_eq!(
            std::fs::read_link(root.join("muse").join("auth.json")).unwrap(),
            user.join("auth.json")
        );
        assert_eq!(
            std::fs::read_link(root.join("muse").join("skills")).unwrap(),
            user.join("skills")
        );
        assert_eq!(
            std::fs::read_link(root.join("muse").join("mcp.json")).unwrap(),
            user.join("mcp.json")
        );
        assert_eq!(
            std::fs::read(user.join("settings.json")).unwrap(),
            user_settings
        );
        assert_eq!(std::fs::read(user.join("auth.json")).unwrap(), b"signed-in");

        let first_settings = std::fs::read(&settings_path).unwrap();
        let again = install_muse_note_home_at(
            &root,
            Some(&user),
            Path::new("/tmp/tokenstat-hostd"),
            Path::new("/tmp/tokenstat.sock"),
            Path::new("/tmp/tokenstat.turn"),
        );
        assert_eq!(again.unwrap_err(), MUSE_NOTE_PREPARE);
        assert_eq!(std::fs::read(&settings_path).unwrap(), first_settings);

        remove_muse_home(&root);
        assert!(!root.exists());
        assert_eq!(std::fs::read(user.join("auth.json")).unwrap(), b"signed-in");
        assert_eq!(
            std::fs::read(user.join("skills").join("keep.txt")).unwrap(),
            b"keep"
        );
    }

    #[test]
    #[cfg(unix)]
    fn muse_note_home_refuses_a_path_with_a_space() {
        let Some(parent) = muse_scratch_dir() else {
            return;
        };
        let spaced = parent.path().join("a b");
        let result = install_muse_note_home_at(
            &spaced,
            None,
            Path::new("/tmp/tokenstat-hostd"),
            Path::new("/tmp/tokenstat.sock"),
            Path::new("/tmp/tokenstat.turn"),
        );
        assert_eq!(result.unwrap_err(), MUSE_NOTE_PREPARE);
        assert!(!spaced.exists());
    }

    #[test]
    #[cfg(unix)]
    fn muse_note_home_replaces_a_non_object_user_settings_file() {
        let Some(parent) = muse_scratch_dir() else {
            return;
        };
        let user = parent.path().join("user-muse");
        let root = parent.path().join("private");
        std::fs::create_dir_all(&user).unwrap();
        std::fs::write(user.join("settings.json"), b"\"nope\"").unwrap();
        install_muse_note_home_at(
            &root,
            Some(&user),
            Path::new("/tmp/tokenstat-hostd"),
            Path::new("/tmp/tokenstat.sock"),
            Path::new("/tmp/tokenstat.turn"),
        )
        .unwrap();
        let parsed: Value = serde_json::from_slice(
            &std::fs::read(root.join("muse").join("settings.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(parsed["schema_version"], 1_u64);
        assert_eq!(parsed["hooks"]["PostLLMCall"].as_array().unwrap().len(), 1);
        assert_eq!(
            std::fs::read(user.join("settings.json")).unwrap(),
            b"\"nope\""
        );
        remove_muse_home(&root);
    }

    #[test]
    #[cfg(unix)]
    fn muse_mirror_reports_sign_in_when_auth_cannot_be_linked() {
        let Some(parent) = muse_scratch_dir() else {
            return;
        };
        let user = parent.path().join("user-muse");
        let dest = parent.path().join("private");
        std::fs::create_dir_all(&user).unwrap();
        std::fs::write(user.join("auth.json"), b"signed-in").unwrap();
        std::fs::create_dir_all(dest.join("muse").join("auth.json")).unwrap();
        let result = mirror_muse_config(Some(&user), &dest.join("muse"));
        assert_eq!(result.unwrap_err(), MUSE_SIGN_IN);
        assert_eq!(std::fs::read(user.join("auth.json")).unwrap(), b"signed-in");
        remove_muse_home(&dest);
        assert_eq!(std::fs::read(user.join("auth.json")).unwrap(), b"signed-in");
    }

    #[test]
    #[cfg(unix)]
    fn muse_mirror_reports_prepare_when_another_entry_cannot_be_linked() {
        let Some(parent) = muse_scratch_dir() else {
            return;
        };
        let user = parent.path().join("user-muse");
        let dest = parent.path().join("private");
        std::fs::create_dir_all(user.join("skills")).unwrap();
        std::fs::write(user.join("skills").join("keep.txt"), b"keep").unwrap();
        std::fs::create_dir_all(dest.join("muse").join("skills")).unwrap();
        let result = mirror_muse_config(Some(&user), &dest.join("muse"));
        assert_eq!(result.unwrap_err(), MUSE_NOTE_PREPARE);
        assert_eq!(
            std::fs::read(user.join("skills").join("keep.txt")).unwrap(),
            b"keep"
        );
    }

    #[test]
    #[cfg(unix)]
    fn muse_note_home_picks_a_bare_private_directory() {
        if !path_is_bare(&std::env::temp_dir()) && !path_is_bare(Path::new("/tmp")) {
            let result = install_muse_note_home(
                None,
                Path::new("/tmp/tokenstat-hostd"),
                Path::new("/tmp/tokenstat.sock"),
                Path::new("/tmp/tokenstat.turn"),
            );
            assert_eq!(result.unwrap_err(), MUSE_NOTE_PREPARE);
            return;
        }
        let root = install_muse_note_home(
            None,
            Path::new("/tmp/tokenstat-hostd"),
            Path::new("/tmp/tokenstat.sock"),
            Path::new("/tmp/tokenstat.turn"),
        )
        .unwrap()
        .expect("a unix install must find a home");
        let _guard = MuseHomeGuard(Some(root.clone()));
        assert!(path_is_bare(&root.join("hook")));
        assert!(root.join("hook").is_file());
    }
}
