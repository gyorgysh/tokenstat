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
    /// Where this tool's own installer puts it, relative to `$HOME`.
    ///
    /// A CLI that ships its own directory is only on the PATH because its
    /// installer edited a startup file, and that edit is exactly what does not
    /// survive a fresh machine, a shell the user changed afterwards, or a
    /// profile that guards it behind a condition. The daemon then cannot see a
    /// harness the user has plainly installed, and the launcher offers a
    /// shorter list on one Mac than on another with no way to tell why.
    ///
    /// Searched after the PATH, so a version manager or a deliberate override
    /// still wins. Only directories a known installer actually writes belong
    /// here: the policy is to under-report rather than to guess, and a wrong
    /// absolute path is worse than a missing tile.
    install_dirs: &'static [&'static str],
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
        install_dirs: &[],
    },
    Profile {
        id: "claude_code",
        name: "Claude Code",
        command: "claude",
        args: &[],
        bypass_args: &["--dangerously-skip-permissions"],
        harness_id: Some("claude_code"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "codex",
        name: "Codex",
        command: "codex",
        args: &[],
        bypass_args: &["--dangerously-bypass-approvals-and-sandbox"],
        harness_id: Some("codex"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "opencode",
        name: "OpenCode",
        command: "opencode",
        args: &[],
        bypass_args: &["--auto"],
        harness_id: Some("opencode"),
        symbol: None,
        install_dirs: &[".opencode/bin"],
    },
    Profile {
        id: "grok",
        name: "Grok Build",
        command: "grok",
        args: &[],
        bypass_args: &["--permission-mode", "bypassPermissions"],
        harness_id: Some("grok"),
        symbol: None,
        install_dirs: &[".grok/bin"],
    },
    Profile {
        id: "copilot",
        name: "Copilot CLI",
        command: "copilot",
        args: &[],
        bypass_args: &["--allow-all"],
        harness_id: Some("copilot"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "cline",
        name: "Cline",
        command: "cline",
        args: &[],
        bypass_args: &[],
        harness_id: Some("cline"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "openclaw",
        name: "OpenClaw",
        command: "openclaw",
        args: &[],
        bypass_args: &[],
        harness_id: Some("openclaw"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "muse",
        name: "Muse",
        command: "muse",
        args: &[],
        bypass_args: &[],
        harness_id: Some("muse"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "pi",
        name: "Pi",
        command: "pi",
        args: &[],
        bypass_args: &[],
        harness_id: Some("pi"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "zed",
        name: "Zed",
        command: "zed",
        args: &[],
        bypass_args: &[],
        harness_id: Some("zed"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "antigravity",
        name: "Antigravity",
        command: "agy",
        args: &[],
        bypass_args: &["--dangerously-skip-permissions"],
        harness_id: Some("antigravity"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "cursor_agent",
        name: "Cursor Agent",
        command: "agent",
        args: &[],
        bypass_args: &[],
        harness_id: Some("cursor"),
        symbol: None,
        install_dirs: &[],
    },
    Profile {
        id: "cursor",
        name: "Cursor CLI",
        command: "cursor",
        args: &[],
        bypass_args: &[],
        harness_id: Some("cursor"),
        symbol: None,
        install_dirs: &[],
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
    let home = std::env::var("HOME").unwrap_or_default();
    let available: Vec<Value> = PROFILES
        .iter()
        .filter(|profile| {
            profile.id == "shell"
                || profile.command.starts_with('/')
                || resolve_profile(profile, &path, Path::new(&home)).is_some()
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
            } else if let Some(full) = resolve_profile(profile, &path, Path::new(&home)) {
                // Absolute path so a click does not need the login PATH to
                // find the binary. Spawn used to block on `$SHELL -ilc env`
                // just to resolve `claude` → `/Users/…/bin/claude`.
                value["command"] = json!(full);
            }
            value
        })
        .collect();
    Value::Array(available)
}

/// Build the environment for a local model selection.
///
/// Only harnesses with a known provider contract are accepted here. Passing a
/// model choice through as arbitrary environment variables would make a remote
/// client able to alter the whole process environment and would make failures
/// look like unsupported harness configuration.
pub(crate) fn model_environment(
    command: &str,
    provider: Option<&str>,
    model: Option<&str>,
) -> Result<Vec<(String, String)>, String> {
    match (provider, model) {
        (None, None) => return Ok(Vec::new()),
        (Some(_), Some(model)) if valid_model_id(model) => {}
        (Some(_), Some(_)) => {
            return Err("local model id contains invalid control characters".into());
        }
        _ => return Err("local model selection needs both a provider and a model".into()),
    }

    let executable = Path::new(command)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(command);
    match (executable, provider) {
        ("claude", Some("lmstudio")) => Ok(vec![
            ("ANTHROPIC_BASE_URL".into(), "http://127.0.0.1:1234".into()),
            ("ANTHROPIC_AUTH_TOKEN".into(), "lmstudio".into()),
        ]),
        ("claude", Some("ollama")) => {
            Err("Ollama does not provide the Anthropic-compatible endpoint Claude needs".into())
        }
        ("codex" | "opencode", Some("lmstudio")) => Ok(vec![
            ("OPENAI_BASE_URL".into(), "http://127.0.0.1:1234/v1".into()),
            ("OPENAI_API_KEY".into(), "lmstudio".into()),
        ]),
        ("codex" | "opencode", Some("ollama")) => Ok(vec![
            ("OPENAI_BASE_URL".into(), "http://127.0.0.1:11434/v1".into()),
            ("OPENAI_API_KEY".into(), "ollama".into()),
            ("OLLAMA_HOST".into(), "http://127.0.0.1:11434".into()),
        ]),
        (_, Some(provider)) => Err(format!(
            "local model selection is not configured for {executable} with {provider}"
        )),
        (_, None) => unreachable!("provider was checked with the model above"),
    }
}

fn valid_model_id(model: &str) -> bool {
    !model.is_empty() && model.len() <= 512 && !model.chars().any(char::is_control)
}

/// Where this profile's command actually is: the search path first, then the
/// directory its own installer uses.
///
/// The order is the point. A tool on the PATH is the one the user's shell
/// would run, so it wins even when a copy sits in the install directory as
/// well. The install directory is the answer to "it is plainly installed and
/// tokenstat cannot see it", which happens on any machine whose startup file
/// does not export it.
fn resolve_profile(profile: &Profile, path: &[String], home: &Path) -> Option<String> {
    if let Some(found) = resolve_on_path(profile.command, path) {
        return Some(found);
    }
    if home.as_os_str().is_empty() {
        return None;
    }
    profile
        .install_dirs
        .iter()
        .map(|dir| home.join(dir).join(profile.command))
        .find(|candidate| is_executable(candidate))
        .map(|candidate| candidate.display().to_string())
}

/// First executable match for a bare command name on the search path.
fn resolve_on_path(command: &str, path: &[String]) -> Option<String> {
    if command.starts_with('/') {
        return is_executable(Path::new(command)).then(|| command.to_string());
    }
    path.iter()
        .map(|dir| Path::new(dir).join(command))
        .find(|p| is_executable(p))
        .map(|p| p.display().to_string())
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
    // Blocking here on purpose: a catalog that answered before the resolve
    // finished would hide harnesses that only exist in the login PATH, and
    // this runs on the launch surface, not on a terminal click.
    if let Some(env) = tokenstat_pty::login_env_ready() {
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
    use super::{PROFILES, Profile, catalog, model_environment, resolve_profile};
    use std::path::Path;
    #[cfg(unix)]
    use std::path::PathBuf;

    /// A `$HOME` with `<dir>/<command>` in it, executable.
    #[cfg(unix)]
    fn home_with(dir: &str, command: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!("tokenstat-launcher-{dir}-{command}"));
        let bin = home.join(dir);
        std::fs::create_dir_all(&bin).expect("a temp home");
        let path = bin.join(command);
        std::fs::write(&path, b"#!/bin/sh\n").expect("a fake binary");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
                .expect("an executable bit");
        }
        home
    }

    fn profile(command: &'static str, install_dirs: &'static [&'static str]) -> Profile {
        Profile {
            id: "test",
            name: "Test",
            command,
            args: &[],
            bypass_args: &[],
            harness_id: None,
            symbol: None,
            install_dirs,
        }
    }

    /// The reported bug: `~/.opencode/bin/opencode` exists, the machine's
    /// startup file never exported that directory, and the launcher offered no
    /// OpenCode tile with nothing to say about why.
    #[cfg(unix)]
    #[test]
    fn a_tool_in_its_own_install_directory_is_found_off_the_path() {
        let home = home_with(".opencode/bin", "opencode");
        let found = resolve_profile(&profile("opencode", &[".opencode/bin"]), &[], &home)
            .expect("an installed tool must be found without the PATH");
        assert!(found.ends_with(".opencode/bin/opencode"), "{found}");
        let _ = std::fs::remove_dir_all(&home);
    }

    /// The PATH still decides. A version manager or a deliberate override is
    /// what the user's own shell would run, and the install directory must not
    /// quietly take precedence over it.
    #[cfg(unix)]
    #[test]
    fn the_path_wins_over_the_install_directory() {
        let home = home_with(".grok/bin", "grok");
        let elsewhere = home_with("preferred", "grok");
        let path = vec![elsewhere.join("preferred").display().to_string()];
        let found = resolve_profile(&profile("grok", &[".grok/bin"]), &path, &home)
            .expect("the PATH copy must be found");
        assert!(found.ends_with("preferred/grok"), "{found}");
        let _ = std::fs::remove_dir_all(&home);
        let _ = std::fs::remove_dir_all(&elsewhere);
    }

    /// A profile with no install directory of its own is unchanged: absent
    /// from the PATH means absent.
    #[test]
    fn a_profile_without_an_install_directory_still_needs_the_path() {
        let home = std::env::temp_dir();
        assert!(resolve_profile(&profile("definitely-not-installed", &[]), &[], &home).is_none());
        assert!(resolve_profile(&profile("opencode", &[]), &[], Path::new("")).is_none());
    }

    /// The two tools that ship their own directory are the two this exists
    /// for. A rename here silently reintroduces the bug.
    #[test]
    fn the_tools_that_ship_a_directory_declare_it() {
        for (id, dir) in [("opencode", ".opencode/bin"), ("grok", ".grok/bin")] {
            let found = PROFILES
                .iter()
                .find(|p| p.id == id)
                .unwrap_or_else(|| panic!("{id} must be in the catalog"));
            assert!(
                found.install_dirs.contains(&dir),
                "{id} must look in {dir}, has {:?}",
                found.install_dirs
            );
        }
    }

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

    #[test]
    fn claude_gets_lm_studio_anthropic_environment() {
        let env =
            model_environment("claude", Some("lmstudio"), Some("qwen/model")).expect("environment");
        assert!(env.contains(&("ANTHROPIC_BASE_URL".into(), "http://127.0.0.1:1234".into())));
        assert!(env.contains(&("ANTHROPIC_AUTH_TOKEN".into(), "lmstudio".into())));
    }

    #[test]
    fn ollama_is_rejected_for_claude() {
        let error = model_environment("claude", Some("ollama"), Some("llama3.2"))
            .expect_err("unsupported provider");
        assert!(error.contains("Anthropic-compatible"));
    }

    #[test]
    fn model_selection_rejects_control_characters() {
        let error = model_environment("codex", Some("ollama"), Some("llama\n3.2"))
            .expect_err("invalid model");
        assert!(error.contains("control characters"));
    }
}
