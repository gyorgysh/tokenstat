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
    /// A loopback page this command starts. The front end opens it after
    /// spawn. None for a TTY session.
    open_url: Option<&'static str>,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
    },
    Profile {
        id: "dsh",
        name: "DeepSeek Harness",
        command: "npx",
        args: &["--yes", "@deepseek-ai/dsh", "web"],
        bypass_args: &[],
        harness_id: Some("dsh"),
        symbol: None,
        install_dirs: &[],
        // `npx @deepseek-ai/dsh web` serves the UI here. The session is the
        // server process. The front end opens this URL once it answers.
        open_url: Some("http://127.0.0.1:3080/"),
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
        open_url: None,
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
                "openUrl": profile.open_url,
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

    let executable = executable_name(command);
    match (executable, provider) {
        ("claude", Some("lmstudio")) => {
            let base = crate::local_models::origin("lmstudio")
                .ok_or("LM Studio is not a known local provider")?;
            Ok(vec![
                ("ANTHROPIC_BASE_URL".into(), base),
                ("ANTHROPIC_AUTH_TOKEN".into(), "lmstudio".into()),
            ])
        }
        ("claude", Some("ollama")) => {
            Err("Ollama does not provide the Anthropic-compatible endpoint Claude needs".into())
        }
        // Copilot takes the endpoint through its own variables rather than the
        // generic OPENAI_* pair, and needs no key for a loopback server that
        // asks for none.
        ("copilot", Some(provider)) => {
            let base = crate::local_models::api_base_url(provider)
                .ok_or_else(|| format!("{provider} is not a known local provider"))?;
            Ok(vec![("COPILOT_PROVIDER_BASE_URL".into(), base.into())])
        }
        // These CLIs receive their local provider through explicit launch
        // arguments. Their private config/auth handling must not be overridden
        // by guessed OPENAI_* variables.
        ("codex" | "opencode", Some("lmstudio" | "ollama")) => Ok(Vec::new()),
        (_, Some(provider)) => Err(format!(
            "local model selection is not configured for {executable} with {provider}"
        )),
        (_, None) => unreachable!("provider was checked with the model above"),
    }
}

/// The launch arguments that name a local model to a harness.
///
/// Here rather than in a front end, beside the environment half of the same
/// contract. A client that knew one and not the other would launch a session
/// pointed at a local server while still asking it for a cloud model.
///
/// Returns nothing for a harness that carries the whole selection in its
/// environment, and for one that has no selection at all. A harness that
/// supports neither has already failed in [`model_environment`], which is the
/// only place that decides what is supported.
pub(crate) fn model_arguments(
    command: &str,
    provider: Option<&str>,
    model: Option<&str>,
) -> Vec<String> {
    let (Some(provider), Some(model)) = (provider, model) else {
        return Vec::new();
    };
    match executable_name(command) {
        // Codex names the provider itself, and refuses a local model without
        // being told to leave its cloud account out of it.
        "codex" => vec![
            "--oss".into(),
            "--local-provider".into(),
            provider.into(),
            "--model".into(),
            model.into(),
        ],
        // OpenCode addresses every model as `provider/model`, local included.
        "opencode" => vec!["--model".into(), format!("{provider}/{model}")],
        "claude" | "copilot" => vec!["--model".into(), model.into()],
        _ => Vec::new(),
    }
}

/// The file name a command runs as, for matching a harness contract.
fn executable_name(command: &str) -> &str {
    Path::new(command)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(command)
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
    use super::{PROFILES, Profile, catalog, model_arguments, model_environment, resolve_profile};
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
            open_url: None,
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
    fn the_deepseek_harness_starts_its_web_ui() {
        // Official start is `npx @deepseek-ai/dsh web`. `--yes` skips the
        // first-run install prompt so a tile click does not hang the session.
        // The UI is the page on :3080, not the TTY.
        let dsh = PROFILES
            .iter()
            .find(|p| p.id == "dsh")
            .expect("DeepSeek Harness must be in the catalog");
        assert_eq!(dsh.name, "DeepSeek Harness");
        assert_eq!(dsh.command, "npx");
        assert_eq!(dsh.args, &["--yes", "@deepseek-ai/dsh", "web"]);
        assert_eq!(dsh.harness_id, Some("dsh"));
        assert_eq!(dsh.open_url, Some("http://127.0.0.1:3080/"));
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

    #[test]
    fn codex_local_providers_do_not_get_guessed_environment() {
        let env =
            model_environment("codex", Some("ollama"), Some("llama3.2")).expect("environment");
        assert!(env.is_empty());
    }

    #[test]
    fn copilot_gets_the_providers_openai_endpoint() {
        let env =
            model_environment("copilot", Some("ollama"), Some("llama3.2")).expect("environment");
        assert_eq!(
            env,
            vec![(
                "COPILOT_PROVIDER_BASE_URL".to_string(),
                "http://127.0.0.1:11434".to_string()
            )]
        );
    }

    #[test]
    fn codex_is_told_to_use_its_local_provider() {
        assert_eq!(
            model_arguments("/opt/homebrew/bin/codex", Some("lmstudio"), Some("qwen/a")),
            vec!["--oss", "--local-provider", "lmstudio", "--model", "qwen/a"]
        );
    }

    #[test]
    fn opencode_addresses_a_model_by_provider() {
        assert_eq!(
            model_arguments("opencode", Some("lmstudio"), Some("qwen/a")),
            vec!["--model", "lmstudio/qwen/a"]
        );
    }

    #[test]
    fn no_selection_means_no_arguments() {
        assert!(model_arguments("claude", None, None).is_empty());
        assert!(model_arguments("claude", Some("lmstudio"), None).is_empty());
    }
}
