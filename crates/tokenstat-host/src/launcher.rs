// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! What can be launched in a workspace on this machine.
//!
//! The app decides the launcher for a local folder from its own PATH. For a
//! remote folder the launcher has to mean *that machine's* PATH, so the host
//! answers the same question here and the app asks over the remote call when
//! the folder belongs to a peer.

use std::path::Path;

use serde_json::{Value, json};

struct Profile {
    id: &'static str,
    name: &'static str,
    command: &'static str,
    args: &'static [&'static str],
    bypass_args: &'static [&'static str],
    harness_id: Option<&'static str>,
    symbol: Option<&'static str>,
}

const PROFILES: &[Profile] = &[
    Profile {
        id: "shell",
        name: "Shell",
        command: "/bin/zsh",
        args: &["-il"],
        bypass_args: &[],
        harness_id: None,
        symbol: Some("terminal"),
    },
    Profile {
        id: "claude_code",
        name: "Claude Code",
        command: "claude",
        args: &[],
        bypass_args: &["--dangerously-skip-permissions"],
        harness_id: Some("claude_code"),
        symbol: None,
    },
    Profile {
        id: "codex",
        name: "Codex",
        command: "codex",
        args: &[],
        bypass_args: &["--dangerously-bypass-approvals-and-sandbox"],
        harness_id: Some("codex"),
        symbol: None,
    },
    Profile {
        id: "opencode",
        name: "OpenCode",
        command: "opencode",
        args: &[],
        bypass_args: &["--auto"],
        harness_id: Some("opencode"),
        symbol: None,
    },
    Profile {
        id: "grok",
        name: "Grok Build",
        command: "grok",
        args: &[],
        bypass_args: &["--permission-mode", "bypassPermissions"],
        harness_id: Some("grok"),
        symbol: None,
    },
    Profile {
        id: "copilot",
        name: "Copilot CLI",
        command: "copilot",
        args: &[],
        bypass_args: &["--allow-all"],
        harness_id: Some("copilot"),
        symbol: None,
    },
    Profile {
        id: "cline",
        name: "Cline",
        command: "cline",
        args: &[],
        bypass_args: &[],
        harness_id: Some("cline"),
        symbol: None,
    },
    Profile {
        id: "openclaw",
        name: "OpenClaw",
        command: "openclaw",
        args: &[],
        bypass_args: &[],
        harness_id: Some("openclaw"),
        symbol: None,
    },
    Profile {
        id: "muse",
        name: "Muse",
        command: "muse",
        args: &[],
        bypass_args: &[],
        harness_id: Some("muse"),
        symbol: None,
    },
    Profile {
        id: "pi",
        name: "Pi",
        command: "pi",
        args: &[],
        bypass_args: &[],
        harness_id: Some("pi"),
        symbol: None,
    },
    Profile {
        id: "zed",
        name: "Zed",
        command: "zed",
        args: &[],
        bypass_args: &[],
        harness_id: Some("zed"),
        symbol: None,
    },
    Profile {
        id: "antigravity",
        name: "Antigravity",
        command: "agy",
        args: &[],
        bypass_args: &["--dangerously-skip-permissions"],
        harness_id: Some("antigravity"),
        symbol: None,
    },
    Profile {
        id: "cursor_agent",
        name: "Cursor Agent",
        command: "agent",
        args: &[],
        bypass_args: &[],
        harness_id: Some("cursor"),
        symbol: None,
    },
    Profile {
        id: "cursor",
        name: "Cursor CLI",
        command: "cursor",
        args: &[],
        bypass_args: &[],
        harness_id: Some("cursor"),
        symbol: None,
    },
];

/// The harnesses whose command is on this machine's PATH. The shell profile is
/// always available: every Unix box has a shell.
pub(crate) fn catalog() -> Value {
    let path = search_path();
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let shell_args: &[&str] = if shell.ends_with("zsh") {
        &["-il"]
    } else {
        &[]
    };
    let available: Vec<Value> = PROFILES
        .iter()
        .filter(|profile| {
            profile.id == "shell"
                || profile.command.starts_with('/')
                || path
                    .iter()
                    .any(|dir| is_executable(&Path::new(dir).join(profile.command)))
        })
        .map(|profile| {
            let mut value = json!({
                "id": profile.id,
                "name": profile.name,
                "command": profile.command,
                "args": profile.args,
                "bypassArgs": profile.bypass_args,
                "harnessId": profile.harness_id,
                "symbol": profile.symbol,
            });
            if profile.id == "shell" {
                value["command"] = json!(shell);
                value["args"] = json!(shell_args);
            }
            value
        })
        .collect();
    Value::Array(available)
}

fn is_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// The daemon's PATH plus the usual install directories. The daemon runs under
/// launchd with a smaller PATH than a terminal, so the conventional locations
/// are added explicitly; this under-reports rather than guesses wrong, and the
/// shell entry keeps the launcher usable either way.
fn search_path() -> Vec<String> {
    let mut paths: Vec<String> = std::env::var("PATH")
        .unwrap_or_default()
        .split(':')
        .filter(|p| !p.is_empty())
        .map(str::to_string)
        .collect();
    // The login shell's PATH, resolved once per process and shared with the
    // sessions that will actually run. Same answer for "what can launch" and
    // "what the launched session can find", so a tile and its spawn agree.
    if let Some(env) = tokenstat_pty::login_env() {
        paths.extend(
            env.path
                .split(':')
                .filter(|p| !p.is_empty())
                .map(str::to_string),
        );
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let mut conventional = vec![
        format!("{home}/.local/bin"),
        format!("{home}/.npm-global/bin"),
        format!("{home}/.volta/bin"),
        "/opt/homebrew/bin".into(),
        "/usr/local/bin".into(),
        "/usr/bin".into(),
        "/bin".into(),
    ];
    paths.append(&mut conventional);
    let mut seen = std::collections::HashSet::new();
    paths.retain(|p| !p.is_empty() && seen.insert(p.clone()));
    paths
}

#[cfg(test)]
mod tests {
    use super::{PROFILES, catalog};

    #[test]
    fn the_catalog_always_includes_the_shell() {
        let list = catalog();
        let ids: Vec<&str> = list
            .as_array()
            .expect("an array")
            .iter()
            .filter_map(|v| v.get("id").and_then(|v| v.as_str()))
            .collect();
        assert!(ids.contains(&"shell"), "{ids:?}");
    }

    #[test]
    fn the_pi_harness_is_in_the_catalog() {
        // The launcher, the session-tab mark and the archive display name are
        // keyed by the same harness id. The profile's id must match so the
        // launched session renders with the Pi mark rather than a letter tile.
        let pi = PROFILES
            .iter()
            .find(|p| p.id == "pi")
            .expect("the Pi harness must be in the catalog");
        assert_eq!(pi.name, "Pi");
        assert_eq!(pi.command, "pi");
        assert_eq!(pi.harness_id, Some("pi"));
    }
}
