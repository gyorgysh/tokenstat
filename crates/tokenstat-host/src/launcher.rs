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

use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

#[cfg(unix)]
use std::os::unix::process::CommandExt;

use serde_json::{Value, json};

/// How long a profile installer may run before the host gives up on it.
///
/// Downloading a large CLI can take minutes on a slow link, so twenty minutes
/// is generous. The client's patience is a per-silence budget, so a live
/// download that keeps writing output is never cut off by the client; this
/// cap is the hard bound that keeps a silent hang from holding a connection
/// thread forever.
const INSTALL_TIMEOUT: Duration = Duration::from_secs(20 * 60);

struct Profile {
    id: &'static str,
    name: &'static str,
    command: &'static str,
    args: &'static [&'static str],
    bypass_args: &'static [&'static str],
    harness_id: Option<&'static str>,
    symbol: Option<&'static str>,
    /// The tool's official one-shot installer, when one exists. `None` for
    /// the shell, for a CLI that ships inside an editor, and for anything
    /// with no clean standalone installer. The front end offers the command
    /// to a user who has not installed the tool; the host runs it.
    install_command: Option<&'static str>,
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
        install_command: None,
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
        install_command: Some("curl -fsSL https://claude.ai/install.sh | bash"),
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
        install_command: Some("curl -fsSL https://chatgpt.com/codex/install.sh | sh"),
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
        install_command: Some("curl -fsSL https://opencode.ai/install | bash"),
        install_dirs: &[".opencode/bin"],
        open_url: None,
    },
    Profile {
        id: "opencode2",
        name: "OpenCode 2",
        command: "opencode2",
        args: &[],
        bypass_args: &["--auto"],
        harness_id: Some("opencode"),
        symbol: None,
        install_command: Some(
            "curl -fsSL https://raw.githubusercontent.com/anomalyco/opencode/v2/install | bash",
        ),
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
        install_command: Some("curl -fsSL https://x.ai/cli/install.sh | bash"),
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
        install_command: Some("npm install -g @github/copilot"),
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
        install_command: Some("npm install -g cline"),
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
        install_command: Some("curl -fsSL https://openclaw.ai/install.sh | bash"),
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
        install_command: Some("curl -fsSL https://dev.meta.ai/install.sh | bash"),
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
        install_command: Some("npm install -g --ignore-scripts @earendil-works/pi-coding-agent"),
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
        install_command: None,
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
        install_command: None,
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
        install_command: Some("curl -fsSL https://antigravity.google/cli/install.sh | bash"),
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
        install_command: Some("curl https://cursor.com/install -fsS | bash"),
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
        install_command: None,
        install_dirs: &[],
        open_url: None,
    },
    Profile {
        id: "hermes",
        name: "Hermes Agent",
        command: "hermes",
        args: &[],
        bypass_args: &[],
        harness_id: Some("hermes"),
        // No official vector in their repository. A letter or an invented
        // mark would claim an identity we do not have, so the tile uses the
        // same generic terminal glyph as the shell.
        symbol: Some("terminal"),
        install_command: Some("curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"),
        // The installer puts a symlink in ~/.local/bin, which search_path
        // already looks at. No extra directory to declare.
        install_dirs: &[],
        open_url: None,
    },
    Profile {
        id: "kilo",
        name: "Kilo Code",
        command: "kilocode",
        args: &[],
        bypass_args: &[],
        harness_id: Some("kilo"),
        symbol: Some("terminal"),
        install_command: Some("npm install -g @kilocode/cli"),
        install_dirs: &[],
        open_url: None,
    },
];

/// Tools taken off this machine's launcher. Display only: the binary stays.
///
/// Lives beside the machine key, not in the viewing app's defaults, so a
/// phone that asks this host sees the same grid the Mac does.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct LauncherPrefs {
    #[serde(default)]
    hidden: Vec<String>,
}

fn prefs_path_in(dir: &Path) -> PathBuf {
    dir.join("launcher.json")
}

fn load_prefs_in(dir: &Path) -> LauncherPrefs {
    std::fs::read_to_string(prefs_path_in(dir))
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save_prefs_in(dir: &Path, prefs: &LauncherPrefs) -> Result<(), String> {
    let _ = std::fs::create_dir_all(dir);
    let path = prefs_path_in(dir);
    let text = serde_json::to_string_pretty(prefs).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))
}

/// Read only. A catalog draw must not create the identity directory.
fn load_prefs() -> LauncherPrefs {
    tokenstat_identity::identity_dir_path()
        .ok()
        .map(|dir| load_prefs_in(&dir))
        .unwrap_or_default()
}

/// Hide an installed profile on this machine's launcher.
///
/// The shell stays: a machine without a shell tile cannot start a session
/// at all. Unknown ids are refused the same way install is, so a remote
/// caller cannot write an arbitrary string into the set.
pub(crate) fn hide(id: &str) -> Result<Value, String> {
    let dir = tokenstat_identity::identity_dir().map_err(|e| e.to_string())?;
    hide_in(&dir, id)
}

fn hide_in(dir: &Path, id: &str) -> Result<Value, String> {
    if id == "shell" {
        return Err("the shell cannot be hidden".into());
    }
    if !PROFILES.iter().any(|p| p.id == id) {
        return Err(format!("no launcher profile {id}"));
    }
    let mut prefs = load_prefs_in(dir);
    if !prefs.hidden.iter().any(|hidden| hidden == id) {
        prefs.hidden.push(id.to_string());
        prefs.hidden.sort();
        save_prefs_in(dir, &prefs)?;
    }
    Ok(json!({ "id": id, "hidden": true }))
}

/// Put a hidden profile back on this machine's launcher.
pub(crate) fn show(id: &str) -> Result<Value, String> {
    let dir = tokenstat_identity::identity_dir().map_err(|e| e.to_string())?;
    show_in(&dir, id)
}

fn show_in(dir: &Path, id: &str) -> Result<Value, String> {
    if !PROFILES.iter().any(|p| p.id == id) && id != "shell" {
        return Err(format!("no launcher profile {id}"));
    }
    let mut prefs = load_prefs_in(dir);
    let before = prefs.hidden.len();
    prefs.hidden.retain(|hidden| hidden != id);
    if prefs.hidden.len() != before {
        save_prefs_in(dir, &prefs)?;
    }
    Ok(json!({ "id": id, "hidden": false }))
}

/// Everything a launcher can run in a workspace, with whether it is on this
/// machine, as its daemon reports it. The shell profile is always available:
/// every Unix box has a shell.
///
/// The answer is the whole supported catalog, not only what is installed: a
/// front end shows what is here as something to start, and everything else
/// as something that can be installed from here. `installed` is the verdict
/// the UI draws on, and the front end never launches a profile that reports
/// false. `hidden` is the user's own take-off-the-grid set, stored on this
/// machine so every client that asks sees the same list.
pub(crate) fn catalog() -> Value {
    let path = search_path();
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let shell_args: &[&str] = if shell.ends_with("zsh") {
        &["-il"]
    } else {
        &[]
    };
    let home = std::env::var("HOME").unwrap_or_default();
    let hidden = load_prefs().hidden.into_iter().collect::<HashSet<_>>();
    let available: Vec<Value> = PROFILES
        .iter()
        .map(|profile| {
            let installed = profile.id == "shell"
                || profile.command.starts_with('/')
                || resolve_profile(profile, &path, Path::new(&home)).is_some();
            let mut value = json!({
                "id": profile.id,
                "name": profile.name,
                "command": profile.command,
                "args": profile.args,
                "bypassArgs": profile.bypass_args,
                "harnessId": profile.harness_id,
                "symbol": profile.symbol,
                "openUrl": profile.open_url,
                "installed": installed,
                "hidden": hidden.contains(profile.id),
                "installCommand": profile.install_command,
            });
            if profile.id == "shell" {
                value["command"] = json!(shell);
                value["args"] = json!(shell_args);
            } else if installed {
                // Absolute path so a click does not need the login PATH to
                // find the binary. Spawn used to block on `$SHELL -ilc env`
                // just to resolve `claude` → `/Users/…/bin/claude`.
                if let Some(full) = resolve_profile(profile, &path, Path::new(&home)) {
                    value["command"] = json!(full);
                }
            }
            value
        })
        .collect();
    Value::Array(available)
}

/// Run a catalog profile's official installer on this machine.
///
/// The command comes from the hardcoded [`PROFILES`] table, never from the
/// caller: a client may pick a profile by id, and nothing else, so a remote
/// caller cannot make the host run a command of its own. The installer runs
/// with the login environment so `npm`, `brew` and friends resolve, and its
/// output is captured so the calling app can say what happened.
pub(crate) fn install(id: &str) -> Result<Value, String> {
    let profile = PROFILES
        .iter()
        .find(|p| p.id == id)
        .ok_or_else(|| format!("no launcher profile {id}"))?;
    let command = profile
        .install_command
        .ok_or_else(|| format!("{id} has no bundled installer"))?;

    // Refuse when the tool is already where the catalog looks for it. The
    // front end never offers this, so the guard is for a stale tile or a
    // remote caller asking twice: reinstalling something that is present is
    // at best pointless and at worst a way to burn a peer's CPU.
    let home = std::env::var("HOME").unwrap_or_default();
    if !profile.command.starts_with('/')
        && resolve_profile(profile, &search_path(), Path::new(&home)).is_some()
    {
        return Err(format!("{id} is already installed"));
    }

    let mut cmd = std::process::Command::new("/bin/sh");
    cmd.arg("-c").arg(command);
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    // Own process group, so a timeout can kill the installer's whole tree
    // rather than only the shell that launched it: `curl | bash` and npm
    // postinstall scripts outlive the shell they hang under otherwise.
    #[cfg(unix)]
    cmd.process_group(0);
    if let Some(env) = tokenstat_pty::login_env_ready() {
        cmd.env("PATH", &env.path);
        for (key, value) in &env.vars {
            cmd.env(key, value);
        }
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("failed to start the installer: {e}"))?;
    let mut stdout = child.stdout.take().ok_or("installer produced no stdout")?;
    let mut stderr = child.stderr.take().ok_or("installer produced no stderr")?;
    let (out_tx, out_rx) = std::sync::mpsc::channel();
    let (err_tx, err_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        let _ = out_tx.send(buf);
    });
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr.read_to_end(&mut buf);
        let _ = err_tx.send(buf);
    });

    // The pipes are drained on the reader threads, so waiting on the child
    // cannot deadlock on a full buffer. The deadline bounds a hung installer
    // so the connection thread it runs on does not stay busy forever.
    let deadline = Instant::now() + INSTALL_TIMEOUT;
    let status = loop {
        match child
            .try_wait()
            .map_err(|e| format!("installer wait failed: {e}"))?
        {
            Some(status) => break status,
            None => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    // Kill the rest of the process group too: the shell's own
                    // children (curl, npm postinstall, a download) would keep
                    // running and keep the captured pipes open otherwise.
                    #[cfg(unix)]
                    {
                        let pid = child.id();
                        let _ = std::process::Command::new("kill")
                            .args(["-9", &format!("-{pid}")])
                            .status();
                    }
                    return Err(format!("the {id} installer timed out"));
                }
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    };

    let mut combined = out_rx
        .recv_timeout(Duration::from_secs(5))
        .unwrap_or_default();
    combined.extend_from_slice(
        &err_rx
            .recv_timeout(Duration::from_secs(5))
            .unwrap_or_default(),
    );
    let truncated = combined.len() > 4096;
    combined.truncate(4096);
    // Installer output is display text. Some installers paint a TTY when they
    // can, and their ANSI cursor codes would be noise in the error a failed
    // install shows, so the escapes are stripped before the text is returned.
    let mut output = strip_ansi(&String::from_utf8_lossy(&combined));
    if truncated {
        output.push_str("\n… (output truncated)");
    }

    Ok(json!({
        "ok": status.success(),
        "exitCode": status.code(),
        "output": output,
    }))
}

/// Remove ANSI escape sequences from installer output.
///
/// Handles CSI (`ESC [ … final`) and OSC (`ESC ] … BEL`) and the one-shot
/// sequences (`ESC X`). Everything else passes through untouched; a trailing
/// half-eaten sequence from the 4 KiB cap simply has nothing left to strip.
fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            Some('[') => {
                chars.next();
                for n in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&n) {
                        break;
                    }
                }
            }
            Some(']') => {
                chars.next();
                // A BEL ends an OSC; so does the ST escape (`ESC \`), which
                // this branch swallows whole since the ESC was already taken
                // by the iteration.
                loop {
                    match chars.next() {
                        None | Some('\u{07}') => break,
                        Some('\u{1b}') => {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                        Some(_) => continue,
                    }
                }
            }
            _ => {
                // `ESC` followed by a single char, e.g. `ESC 7`.
                chars.next();
            }
        }
    }
    out
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
        // Codex names the provider on the command line. Do not guess OPENAI_*.
        ("codex", Some("lmstudio" | "ollama")) => Ok(Vec::new()),
        // OpenCode only accepts a `provider/id` that is in its catalog. A
        // freshly loaded LM Studio model is often missing from that cache.
        // `OPENCODE_CONFIG_CONTENT` is per-process and registers the one
        // selected id without writing `~/.config/opencode/`. The same blob
        // names the default model, which is how OpenCode 2 picks one: its
        // TUI has no `--model` flag.
        ("opencode" | "opencode2", Some(provider @ ("lmstudio" | "ollama"))) => {
            let model = model.ok_or("local model selection needs both a provider and a model")?;
            Ok(vec![(
                "OPENCODE_CONFIG_CONTENT".into(),
                opencode_model_config(provider, model)?,
            )])
        }
        (_, Some(provider)) => Err(format!(
            "local model selection is not configured for {executable} with {provider}"
        )),
        (_, None) => unreachable!("provider was checked with the model above"),
    }
}

/// Per-process OpenCode config that names one local model.
///
/// OpenCode splits `provider/model` on the first slash and then looks the
/// rest up in that provider's catalog. A model id that itself contains a
/// slash (`meta/muse-glimmer`) is valid once it is in that catalog.
///
/// `model` is the default the TUI starts on. OpenCode 1 also accepts
/// `--model` on the root command. OpenCode 2 does not, so this field is
/// the only way to point that CLI at the selection.
fn opencode_model_config(provider: &str, model: &str) -> Result<String, String> {
    let name = model.rsplit('/').next().unwrap_or(model);
    serde_json::to_string(&json!({
        "model": format!("{provider}/{model}"),
        "provider": {
            provider: {
                "models": {
                    model: { "name": name }
                }
            }
        }
    }))
    .map_err(|error| error.to_string())
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
        // OpenCode 1 takes `--model` on the TUI. OpenCode 2 rejects that flag
        // on the root command (`Unrecognized flag: --model`). Its default
        // lives in `OPENCODE_CONFIG_CONTENT` instead, and `--standalone`
        // keeps that config on this process rather than on a background
        // service that never saw it.
        "opencode" => vec!["--model".into(), format!("{provider}/{model}")],
        "opencode2" => vec!["--standalone".into()],
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
    for name in command_names(profile) {
        if let Some(found) = resolve_on_path(name, path) {
            return Some(found);
        }
    }
    if home.as_os_str().is_empty() {
        return None;
    }
    for name in command_names(profile) {
        let found = profile
            .install_dirs
            .iter()
            .map(|dir| home.join(dir).join(name))
            .find(|candidate| is_executable(candidate));
        if let Some(candidate) = found {
            return Some(candidate.display().to_string());
        }
    }
    None
}

/// Executable names this profile answers to.
///
/// Most tools have one. Kilo's npm page calls the command `kilocode` and the
/// docs call it `kilo`, so both are probed rather than guessing which install
/// a machine has.
fn command_names(profile: &Profile) -> impl Iterator<Item = &'static str> {
    let extra: &[&str] = match profile.id {
        "kilo" => &["kilo"],
        _ => &[],
    };
    std::iter::once(profile.command).chain(extra.iter().copied())
}

/// Where a bare command name is on this machine: PATH, the login PATH,
/// conventional install dirs, then a catalog profile's own directory.
///
/// Automations use this so `grok models` and friends resolve the same way
/// a launcher tile does. The daemon's launchd PATH is too small on its own.
pub(crate) fn resolve_command(command: &str) -> Option<String> {
    let path = search_path();
    if let Some(found) = resolve_on_path(command, &path) {
        return Some(found);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        return None;
    }
    let home = Path::new(&home);
    for profile in PROFILES {
        if profile.command == command {
            return resolve_profile(profile, &path, home);
        }
    }
    None
}

/// The search path as one `PATH` value, for a child that must see the same
/// tools the catalog does (helpers a CLI may re-exec).
pub(crate) fn search_path_var() -> String {
    search_path().join(":")
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
    let mut seen = HashSet::new();
    paths.retain(|p| !p.is_empty() && seen.insert(p.clone()));
    paths
}

#[cfg(test)]
mod tests {
    use super::{
        PROFILES, Profile, catalog, command_names, hide_in, install, load_prefs_in,
        model_arguments, model_environment, resolve_profile, show_in, strip_ansi,
    };
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
            install_command: None,
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
        for (id, dir) in [
            ("opencode", ".opencode/bin"),
            ("opencode2", ".opencode/bin"),
            ("grok", ".grok/bin"),
        ] {
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

    /// The v2 next build is its own binary in the same install directory as
    /// v1, so a machine that runs the beta gets its own tile while v1 keeps
    /// the classic one. It bills as the same product, so the harness id and
    /// its installer command must not drift from the OpenCode family.
    #[test]
    fn the_next_opencode_build_is_its_own_profile() {
        let next = PROFILES
            .iter()
            .find(|p| p.id == "opencode2")
            .expect("OpenCode 2 must be in the catalog");
        assert_eq!(next.name, "OpenCode 2");
        assert_eq!(next.command, "opencode2");
        assert_eq!(next.harness_id, Some("opencode"));
        let command = next.install_command.expect("a bundled installer");
        assert!(
            command.starts_with("curl -fsSL https://raw.githubusercontent.com/anomalyco/opencode/"),
            "{command}"
        );
    }

    /// The catalog answers for the whole supported list, not only what is on
    /// the machine. Every profile carries the verdict a front end draws on and
    /// the command that would install it.
    #[test]
    fn the_catalog_carries_an_install_verdict_and_command() {
        let list = catalog();
        let entries = list.as_array().expect("an array");
        assert!(
            entries.len() >= PROFILES.len(),
            "every profile must be listed, even when not installed"
        );
        for entry in entries {
            assert!(
                entry.get("installed").and_then(|v| v.as_bool()).is_some(),
                "{entry} must carry an installed verdict"
            );
            assert!(
                entry.get("hidden").and_then(|v| v.as_bool()).is_some(),
                "{entry} must carry a hidden verdict"
            );
        }
        let claude = entries
            .iter()
            .find(|v| v.get("id").and_then(|v| v.as_str()) == Some("claude_code"))
            .expect("claude_code must be listed");
        assert_eq!(
            claude.get("installCommand").and_then(|v| v.as_str()),
            Some("curl -fsSL https://claude.ai/install.sh | bash")
        );
    }

    /// The id is the only thing a client may choose. Anything else is refused
    /// before a command is built, so a remote caller cannot make the host run
    /// a command of its own.
    #[test]
    fn install_refuses_unknown_profiles() {
        let error = install("definitely-not-a-launcher-profile").expect_err("unknown id");
        assert!(error.contains("no launcher profile"), "{error}");
    }

    /// A profile without a bundled installer is refused too, rather than
    /// launching nothing or running a guessed command.
    #[test]
    fn install_refuses_a_profile_without_an_installer() {
        let error = install("cursor").expect_err("no installer");
        assert!(error.contains("no bundled installer"), "{error}");
    }

    /// Installer output is shown to people as an error message, so the ANSI
    /// cursor codes an installer aimed at a TTY must not survive into it.
    #[test]
    fn installer_output_has_ansi_escapes_stripped() {
        assert_eq!(
            strip_ansi("Installing \u{1b}[0;2mopencode\u{1b}[0m ✓\u{1b}[K\n"),
            "Installing opencode ✓\n"
        );
        assert_eq!(
            strip_ansi("progress \u{1b}[2A\u{1b}[J done"),
            "progress  done"
        );
        assert_eq!(strip_ansi("plain text"), "plain text");
        assert_eq!(strip_ansi("OSC \u{1b}]0;title\u{07} end"), "OSC  end");
        assert_eq!(strip_ansi("OSC \u{1b}]0;title\u{1b}\\ end"), "OSC  end");
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
    fn hermes_and_kilo_are_in_the_catalog() {
        let hermes = PROFILES
            .iter()
            .find(|p| p.id == "hermes")
            .expect("Hermes Agent must be in the catalog");
        assert_eq!(hermes.name, "Hermes Agent");
        assert_eq!(hermes.command, "hermes");
        assert_eq!(hermes.harness_id, Some("hermes"));
        assert_eq!(hermes.symbol, Some("terminal"));
        let command = hermes.install_command.expect("a bundled installer");
        assert!(
            command.contains("hermes-agent.nousresearch.com/install.sh"),
            "{command}"
        );

        let kilo = PROFILES
            .iter()
            .find(|p| p.id == "kilo")
            .expect("Kilo Code must be in the catalog");
        assert_eq!(kilo.name, "Kilo Code");
        assert_eq!(kilo.command, "kilocode");
        assert_eq!(kilo.harness_id, Some("kilo"));
        assert_eq!(kilo.symbol, Some("terminal"));
        let command = kilo.install_command.expect("a bundled installer");
        assert!(command.contains("@kilocode/cli"), "{command}");
        let names: Vec<_> = command_names(kilo).collect();
        assert_eq!(names, ["kilocode", "kilo"]);
    }

    #[cfg(unix)]
    #[test]
    fn kilo_is_found_under_the_docs_command_name() {
        let home = home_with("preferred", "kilo");
        let path = vec![home.join("preferred").display().to_string()];
        let kilo = PROFILES
            .iter()
            .find(|p| p.id == "kilo")
            .expect("Kilo Code must be in the catalog");
        let found = resolve_profile(kilo, &path, &home).expect("kilo must resolve");
        assert!(found.ends_with("preferred/kilo"), "{found}");
        let _ = std::fs::remove_dir_all(&home);
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
        assert_eq!(
            model_arguments(
                "/Users/me/.opencode/bin/opencode2",
                Some("lmstudio"),
                Some("meta/muse-glimmer")
            ),
            vec!["--standalone"]
        );
        assert!(model_arguments("opencode2", None, None).is_empty());
    }

    #[test]
    fn opencode_registers_a_slashed_local_model_for_this_process() {
        let env = model_environment("opencode2", Some("lmstudio"), Some("meta/muse-glimmer"))
            .expect("environment");
        let content = env
            .iter()
            .find(|(key, _)| key == "OPENCODE_CONFIG_CONTENT")
            .map(|(_, value)| value.as_str())
            .expect("OPENCODE_CONFIG_CONTENT");
        let parsed: serde_json::Value = serde_json::from_str(content).expect("json");
        assert_eq!(parsed["model"], "lmstudio/meta/muse-glimmer");
        assert_eq!(
            parsed["provider"]["lmstudio"]["models"]["meta/muse-glimmer"]["name"],
            "muse-glimmer"
        );
        assert_eq!(env.len(), 1);
    }

    #[test]
    fn no_selection_means_no_arguments() {
        assert!(model_arguments("claude", None, None).is_empty());
        assert!(model_arguments("claude", Some("lmstudio"), None).is_empty());
    }

    fn temp_prefs_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-launcher-prefs-{}-{}-{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).expect("a temp prefs dir");
        dir
    }

    #[test]
    fn hide_persists_and_show_removes() {
        let dir = temp_prefs_dir("hide");
        hide_in(&dir, "opencode").expect("hide");
        hide_in(&dir, "codex").expect("hide");
        let prefs = load_prefs_in(&dir);
        assert_eq!(prefs.hidden, vec!["codex", "opencode"]);
        show_in(&dir, "opencode").expect("show");
        let prefs = load_prefs_in(&dir);
        assert_eq!(prefs.hidden, vec!["codex"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hide_refuses_the_shell_and_unknown_ids() {
        let dir = temp_prefs_dir("refuse");
        let shell = hide_in(&dir, "shell").expect_err("shell");
        assert!(shell.contains("cannot be hidden"), "{shell}");
        let unknown = hide_in(&dir, "definitely-not-a-launcher-profile").expect_err("unknown");
        assert!(unknown.contains("no launcher profile"), "{unknown}");
        assert!(load_prefs_in(&dir).hidden.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hide_is_idempotent() {
        let dir = temp_prefs_dir("twice");
        hide_in(&dir, "grok").expect("first");
        hide_in(&dir, "grok").expect("second");
        assert_eq!(load_prefs_in(&dir).hidden, vec!["grok"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
