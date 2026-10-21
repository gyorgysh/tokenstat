// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The agent command for one Team run.
//!
//! The first version answers an Ask and changes nothing: Claude gets only its
//! read tools, Codex runs in its read-only sandbox. The frozen conversation
//! reaches the agent through the scoped `team_context` tool, never through
//! stdin, so a long shared chat pages instead of filling the prompt.
//!
//! The run home stays empty of personal state. Claude gets a current access
//! token in its environment and nothing that could renew it. Codex gets its
//! login file linked in, the way a private chat does. The scoped SDK token is
//! never written to disk: both config files name the variable, not its value.

use super::run_home::RunHome;
use crate::{error::DispatchError, team_process::Program};
use serde_json::json;
use std::{
    collections::BTreeMap,
    fs, io,
    path::{Path, PathBuf},
};

/// The MCP server name the agent sees. Tool names derive from it.
const SERVER: &str = "tokenstat_team";
const SDK_VARS: [&str; 2] = ["TOKENSTAT_TEAM_SDK_ADDRESS", "TOKENSTAT_TEAM_SDK_TOKEN"];
const PROMPT: &str = "You are answering an Ask in a shared Team chat. Call the team_context tool first. When its result includes nextCursor, call it again with that cursor until you have read every page. The original Ask is on every page. Answer that Ask for the people in this chat. You may read files in this checkout. This run is read-only: do not try to modify files or run commands that change state.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Backend {
    Claude,
    Codex,
}

impl Backend {
    pub fn parse(name: &str) -> Result<Self, DispatchError> {
        match name {
            "claude" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            _ => Err(DispatchError::new(
                "team_agent_backend_unsupported",
                "Shared chats can ask Claude Code or Codex. Fork this chat to use another agent.",
            )),
        }
    }
    fn command(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

/// How the agent signs in. Claude's token is the access token alone.
pub(super) enum Credential {
    ClaudeToken(String),
    CodexLogin,
}

impl Credential {
    pub fn current(backend: Backend) -> Result<Self, DispatchError> {
        match backend {
            Backend::Claude => tokenstat_sync::claude_limits::access_token()
                .map(Self::ClaudeToken)
                .map_err(|_| signed_out()),
            Backend::Codex => Ok(Self::CodexLogin),
        }
    }
}

fn signed_out() -> DispatchError {
    DispatchError::new(
        "team_agent_signed_out",
        "The agent is not signed in on the publishing computer.",
    )
}

/// The program before its home exists. `run_home::prepare` checks the folder
/// and keeps only `PATH` from this environment.
pub(super) fn program(backend: Backend, checkout: &Path) -> Result<Program, DispatchError> {
    let path = search_path().ok_or_else(missing)?;
    let executable = resolve(backend.command(), &path).ok_or_else(missing)?;
    Ok(Program {
        executable,
        args: Vec::new(),
        env: BTreeMap::from([("PATH".into(), path)]),
        folder: checkout.into(),
        input: PathBuf::new(),
        output: PathBuf::new(),
        errors: PathBuf::new(),
    })
}

fn missing() -> DispatchError {
    DispatchError::new(
        "team_agent_missing",
        "The agent is not installed on the publishing computer.",
    )
}

fn search_path() -> Option<String> {
    #[cfg(unix)]
    let login = tokenstat_pty::login_env_ready();
    #[cfg(not(unix))]
    let login = tokenstat_pty::login_env();
    login
        .map(|env| env.path.clone())
        .filter(|path| !path.is_empty())
        .or_else(|| std::env::var("PATH").ok())
}

/// The first executable file named `name` on `path`. Only absolute entries
/// count: a relative one would resolve against the checkout.
fn resolve(name: &str, path: &str) -> Option<PathBuf> {
    let file = if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.into()
    };
    std::env::split_paths(path)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join(&file))
        .find(|candidate| executable(candidate))
}

fn executable(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        metadata.is_file()
    }
}

/// Finish the program inside its prepared home: IO files, arguments, the MCP
/// bridge and the credential. Call after `sdk.configure`, which adds the
/// bridge's address and token to the environment.
pub(super) fn configure(
    backend: Backend,
    home: &RunHome,
    program: &mut Program,
    helper: &Path,
    credential: Credential,
) -> io::Result<()> {
    program.input = home.file("input");
    program.output = home.file("output");
    program.errors = home.file("errors");
    write_new(&program.input, PROMPT.as_bytes())?;
    match (backend, credential) {
        (Backend::Claude, Credential::ClaudeToken(token)) => {
            let config = home.file("mcp.json");
            write_new(&config, claude_mcp(helper).to_string().as_bytes())?;
            program.args = claude_args(&config);
            program.env.insert("CLAUDE_CODE_OAUTH_TOKEN".into(), token);
        }
        (Backend::Codex, Credential::CodexLogin) => {
            let codex = home
                .env
                .get("CODEX_HOME")
                .map(PathBuf::from)
                .ok_or_else(|| io::Error::other("The Team run home has no Codex home."))?;
            write_new(&codex.join("config.toml"), codex_config(helper).as_bytes())?;
            crate::chat_gate::link_credential(&codex, ".codex", "auth.json")
                .map_err(io::Error::other)?;
            program.args = codex_args();
        }
        _ => return Err(io::Error::other("The Team run credential does not match.")),
    }
    Ok(())
}

fn write_new(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn claude_mcp(helper: &Path) -> serde_json::Value {
    let env: serde_json::Map<String, serde_json::Value> = SDK_VARS
        .iter()
        .map(|var| ((*var).into(), format!("${{{var}}}").into()))
        .collect();
    json!({"mcpServers": {SERVER: {
        "command": helper,
        "args": ["team-run-sdk"],
        "env": env,
    }}})
}

fn claude_args(config: &Path) -> Vec<String> {
    let mut args: Vec<String> = [
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        // No user, project or local settings: a teammate's Ask must not run
        // hooks or pick up permissions written for the publisher.
        "--setting-sources",
        "",
        "--disable-slash-commands",
        "--tools",
        "Read,Grep,Glob",
        "--allowedTools",
        "mcp__tokenstat_team",
        "--strict-mcp-config",
        "--mcp-config",
    ]
    .map(str::to_string)
    .into();
    args.push(config.to_string_lossy().into_owned());
    args
}

fn codex_config(helper: &Path) -> String {
    // TOML basic strings take the same escapes as JSON for a path.
    let command = serde_json::to_string(&helper.to_string_lossy()).unwrap_or_default();
    let vars = serde_json::to_string(&SDK_VARS).unwrap_or_default();
    format!(
        "[mcp_servers.{SERVER}]\ncommand = {command}\nargs = [\"team-run-sdk\"]\nenv_vars = {vars}\n"
    )
}

fn codex_args() -> Vec<String> {
    [
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--ephemeral",
        "--ignore-rules",
        "--sandbox",
        "read-only",
        "-",
    ]
    .map(str::to_string)
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SDK_TOKEN: &str = "5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d";
    const ACCESS: &str = "sk-ant-oat01-fixture-access";

    fn prepared(backend: Backend) -> (tempfile::TempDir, tempfile::TempDir, RunHome, Program) {
        let scratch = tempfile::tempdir().unwrap();
        let checkout = tempfile::tempdir().unwrap();
        let program = Program {
            executable: checkout.path().join(backend.command()),
            args: Vec::new(),
            env: BTreeMap::from([("PATH".into(), "/usr/bin:/bin".into())]),
            folder: checkout.path().into(),
            input: PathBuf::new(),
            output: PathBuf::new(),
            errors: PathBuf::new(),
        };
        let home =
            super::super::run_home::prepare(scratch.path(), checkout.path(), &program).unwrap();
        let mut program = program;
        program.env.clone_from(&home.env);
        program.env.insert(SDK_VARS[0].into(), "127.0.0.1:9".into());
        program.env.insert(SDK_VARS[1].into(), SDK_TOKEN.into());
        (scratch, checkout, home, program)
    }

    fn home_files(root: &Path) -> Vec<(PathBuf, String)> {
        let mut found = Vec::new();
        let mut stack = vec![root.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(dir).unwrap() {
                let path = entry.unwrap().path();
                let kind = fs::symlink_metadata(&path).unwrap().file_type();
                if kind.is_dir() {
                    stack.push(path);
                } else if kind.is_file() {
                    let text = fs::read_to_string(&path).unwrap_or_default();
                    found.push((path, text));
                }
            }
        }
        found
    }

    #[test]
    fn only_claude_and_codex_can_answer() {
        assert_eq!(Backend::parse("claude").unwrap(), Backend::Claude);
        assert_eq!(Backend::parse("codex").unwrap(), Backend::Codex);
        assert_eq!(
            Backend::parse("grok").unwrap_err().code,
            "team_agent_backend_unsupported"
        );
    }

    #[test]
    fn claude_reads_only_and_keeps_its_token_off_disk() {
        let (_scratch, _checkout, home, mut program) = prepared(Backend::Claude);
        let helper = Path::new("/opt/tokenstat/tokenstat-hostd");
        configure(
            Backend::Claude,
            &home,
            &mut program,
            helper,
            Credential::ClaudeToken(ACCESS.into()),
        )
        .unwrap();
        assert_eq!(program.env["CLAUDE_CODE_OAUTH_TOKEN"], ACCESS);
        assert!(!program.args.iter().any(|a| a.contains("skip-permissions")));
        let at = |flag: &str| program.args.iter().position(|a| a == flag).unwrap() + 1;
        assert_eq!(program.args[at("--tools")], "Read,Grep,Glob");
        assert_eq!(program.args[at("--setting-sources")], "");
        assert_eq!(program.args[at("--allowedTools")], "mcp__tokenstat_team");
        let config = PathBuf::from(&program.args[at("--mcp-config")]);
        assert!(config.starts_with(home.file("")));
        let mcp: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
        let server = &mcp["mcpServers"]["tokenstat_team"];
        assert_eq!(server["command"], helper.to_str().unwrap());
        assert_eq!(server["args"], json!(["team-run-sdk"]));
        assert_eq!(
            server["env"]["TOKENSTAT_TEAM_SDK_TOKEN"],
            "${TOKENSTAT_TEAM_SDK_TOKEN}"
        );
        assert_eq!(fs::read_to_string(&program.input).unwrap(), PROMPT);
        for (path, text) in home_files(&home.file("")) {
            assert!(!text.contains(SDK_TOKEN), "{path:?}");
            assert!(!text.contains(ACCESS), "{path:?}");
            assert!(!text.contains("refresh"), "{path:?}");
        }
    }

    #[test]
    fn codex_runs_read_only_with_the_bridge_named_by_variable() {
        let (_scratch, _checkout, home, mut program) = prepared(Backend::Codex);
        let helper = Path::new("/opt/tokenstat/tokenstat-hostd");
        configure(
            Backend::Codex,
            &home,
            &mut program,
            helper,
            Credential::CodexLogin,
        )
        .unwrap();
        assert_eq!(program.args, codex_args());
        assert!(!program.args.iter().any(|a| a.contains("bypass")));
        assert!(!program.env.contains_key("CLAUDE_CODE_OAUTH_TOKEN"));
        let codex = PathBuf::from(&home.env["CODEX_HOME"]);
        let config = fs::read_to_string(codex.join("config.toml")).unwrap();
        assert!(config.contains("command = \"/opt/tokenstat/tokenstat-hostd\""));
        assert!(
            config.contains(
                "env_vars = [\"TOKENSTAT_TEAM_SDK_ADDRESS\",\"TOKENSTAT_TEAM_SDK_TOKEN\"]"
            )
        );
        for (path, text) in home_files(&home.file("")) {
            assert!(!text.contains(SDK_TOKEN), "{path:?}");
        }
    }

    #[test]
    fn a_mismatched_credential_is_refused() {
        let (_scratch, _checkout, home, mut program) = prepared(Backend::Codex);
        assert!(
            configure(
                Backend::Codex,
                &home,
                &mut program,
                Path::new("/opt/hostd"),
                Credential::ClaudeToken(ACCESS.into()),
            )
            .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn resolution_takes_the_first_absolute_executable() {
        use std::os::unix::fs::PermissionsExt;
        let first = tempfile::tempdir().unwrap();
        let second = tempfile::tempdir().unwrap();
        fs::write(first.path().join("claude"), "not executable").unwrap();
        let found = second.path().join("claude");
        fs::write(&found, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&found, fs::Permissions::from_mode(0o755)).unwrap();
        let path = std::env::join_paths([
            "relative",
            first.path().to_str().unwrap(),
            second.path().to_str().unwrap(),
        ])
        .unwrap();
        assert_eq!(resolve("claude", path.to_str().unwrap()), Some(found));
        assert_eq!(resolve("codex", path.to_str().unwrap()), None);
    }
}
