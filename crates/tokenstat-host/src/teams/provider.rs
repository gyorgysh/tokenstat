// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The agent command for one Team run.
//!
//! A teammate's Ask drives this process with the publisher's OS account, and
//! whatever it can read can end up in the shared chat. So the first version
//! gives it nothing to read but the Team tools: Claude starts with no
//! built-in tools, no settings sources and only the scoped MCP bridge. The
//! frozen conversation pages through `team_context`, never stdin.
//!
//! Claude gets a current access token in its environment and nothing that
//! could renew it. No file in the run home is a credential or a link to one.
//! The scoped SDK token is named by variable in the config, never written.
//!
//! Codex is refused: its login is a file holding a refresh token, and there
//! is no way yet to hand it only a short-lived token. Reading the checkout is
//! also not offered until reads can be confined to it.

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
const PROMPT: &str = "You are answering an Ask in a shared Team chat. Call the team_context tool first. When its result includes nextCursor, call it again with that cursor until you have read every page. The original Ask is on every page. Answer that Ask for the people in this chat from that conversation. You have no file or shell access in this run.";

const LANE_PROMPT: &str = "You are doing work asked for in a shared Team chat. Call the team_context tool first. When its result includes nextCursor, call it again with that cursor until you have read every page. The original Ask is on every page. Make the change it asks for by editing files in this folder, which is your own copy of the project on a fresh branch. You can read and edit files only inside this folder and cannot run commands. Do not commit: tokenstat commits your work, checks it and lands it after you finish. End with a short summary of what you changed.";

/// Only Claude Code can answer an Ask for now.
pub(super) fn supported(backend: &str) -> Result<(), DispatchError> {
    if backend == "claude" {
        return Ok(());
    }
    Err(DispatchError::new(
        "team_agent_backend_unsupported",
        "Shared chats can ask Claude Code for now. Fork this chat to use another agent.",
    ))
}

/// The access token alone, renewed first when it is close to expiry.
pub(super) fn access_token() -> Result<String, DispatchError> {
    tokenstat_sync::claude_limits::access_token().map_err(|_| {
        DispatchError::new(
            "team_agent_signed_out",
            "Claude Code is not signed in on the publishing computer.",
        )
    })
}

/// The program before its home exists. `run_home::prepare` checks the folder
/// and keeps only `PATH` from this environment.
pub(super) fn program(checkout: &Path) -> Result<Program, DispatchError> {
    let path = search_path().ok_or_else(missing)?;
    let executable = resolve("claude", &path).ok_or_else(missing)?;
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
        "Claude Code is not installed on the publishing computer.",
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
/// bridge and the token. Call after `sdk.configure`, which adds the bridge's
/// address and token to the environment.
pub(super) fn configure(
    home: &RunHome,
    program: &mut Program,
    helper: &Path,
    token: String,
    lane: bool,
) -> io::Result<()> {
    program.input = home.file("input");
    program.output = home.file("output");
    program.errors = home.file("errors");
    write_new(
        &program.input,
        if lane { LANE_PROMPT } else { PROMPT }.as_bytes(),
    )?;
    let config = home.file("mcp.json");
    write_new(&config, claude_mcp(helper).to_string().as_bytes())?;
    program.args = claude_args(&config, lane);
    program.env.insert("CLAUDE_CODE_OAUTH_TOKEN".into(), token);
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

/// A lane agent edits files inside its own lane and nothing else: path rules
/// confine every file tool to the working folder, and it has no shell.
/// tokenstat commits, checks and lands the work afterwards.
const LANE_TOOLS: [&str; 5] = [
    "Read(./**)",
    "Edit(./**)",
    "Glob(./**)",
    "Grep(./**)",
    "mcp__tokenstat_team",
];

const LANE_DENIED: [&str; 3] = ["Edit(./.git)", "Edit(./.git/**)", "Read(./.git/**)"];

fn claude_args(config: &Path, lane: bool) -> Vec<String> {
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
        "--strict-mcp-config",
        "--mcp-config",
    ]
    .map(str::to_string)
    .into();
    args.push(config.to_string_lossy().into_owned());
    if lane {
        args.extend([
            "--tools".into(),
            "Read,Edit,Write,Glob,Grep".into(),
            "--allowedTools".into(),
        ]);
        args.extend(LANE_TOOLS.map(str::to_string));
        // The git pointer and directory are tokenstat's, never the agent's.
        args.push("--disallowedTools".into());
        args.extend(LANE_DENIED.map(str::to_string));
    } else {
        // No built-in tools. Read, Grep and Glob accept paths outside the
        // checkout, and Bash reads anything.
        args.extend(["--tools", "", "--allowedTools", "mcp__tokenstat_team"].map(str::to_string));
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    const SDK_TOKEN: &str = "5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d";
    const ACCESS: &str = "sk-ant-oat01-fixture-access";

    fn prepared() -> (tempfile::TempDir, tempfile::TempDir, RunHome, Program) {
        let scratch = tempfile::tempdir().unwrap();
        let checkout = tempfile::tempdir().unwrap();
        let program = Program {
            executable: checkout.path().join("claude"),
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

    /// Every entry under the run root. A link of any kind fails the test:
    /// nothing in a Team run may point back into a personal home.
    fn home_files(root: &Path) -> Vec<(PathBuf, String)> {
        let mut found = Vec::new();
        let mut stack = vec![root.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(dir).unwrap() {
                let path = entry.unwrap().path();
                let kind = fs::symlink_metadata(&path).unwrap().file_type();
                assert!(!kind.is_symlink(), "{path:?} is a link");
                if kind.is_dir() {
                    stack.push(path);
                } else {
                    let text = fs::read_to_string(&path).unwrap_or_default();
                    found.push((path, text));
                }
            }
        }
        found
    }

    #[test]
    fn only_claude_can_answer_for_now() {
        assert!(supported("claude").is_ok());
        for backend in ["codex", "grok", "cursor", ""] {
            assert_eq!(
                supported(backend).unwrap_err().code,
                "team_agent_backend_unsupported"
            );
        }
    }

    #[test]
    fn claude_has_only_team_tools_and_no_credential_on_disk() {
        let (_scratch, _checkout, home, mut program) = prepared();
        let helper = Path::new("/opt/tokenstat/tokenstat-hostd");
        configure(&home, &mut program, helper, ACCESS.into(), false).unwrap();
        assert_eq!(program.env["CLAUDE_CODE_OAUTH_TOKEN"], ACCESS);
        assert!(!program.args.iter().any(|a| a.contains("skip-permissions")));
        let at = |flag: &str| program.args.iter().position(|a| a == flag).unwrap() + 1;
        assert_eq!(program.args[at("--tools")], "");
        assert_eq!(program.args[at("--setting-sources")], "");
        assert_eq!(program.args[at("--allowedTools")], "mcp__tokenstat_team");
        assert!(program.args.iter().any(|a| a == "--strict-mcp-config"));
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
        let files = home_files(&home.file(""));
        for (path, text) in &files {
            assert!(!text.contains(SDK_TOKEN), "{path:?}");
            assert!(!text.contains(ACCESS), "{path:?}");
            assert!(!text.contains("refresh"), "{path:?}");
            let name = path.file_name().unwrap().to_string_lossy();
            assert!(
                ![".credentials.json", "auth.json"].contains(&name.as_ref()),
                "{path:?}"
            );
        }
        let mut names: Vec<_> = files
            .iter()
            .map(|(p, _)| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["input", "mcp.json"]);
    }

    #[test]
    fn a_lane_agent_edits_only_inside_its_lane_and_has_no_shell() {
        let (_scratch, _checkout, home, mut program) = prepared();
        configure(
            &home,
            &mut program,
            Path::new("/opt/hostd"),
            ACCESS.into(),
            true,
        )
        .unwrap();
        let at = |flag: &str| program.args.iter().position(|a| a == flag).unwrap() + 1;
        assert_eq!(program.args[at("--tools")], "Read,Edit,Write,Glob,Grep");
        assert!(
            !program
                .args
                .iter()
                .any(|a| a.contains("Bash") || a.contains("skip-permissions"))
        );
        let allowed = &program.args[at("--allowedTools")..at("--disallowedTools") - 1];
        assert_eq!(allowed, LANE_TOOLS.map(str::to_string));
        assert_eq!(
            &program.args[at("--disallowedTools")..],
            LANE_DENIED.map(str::to_string)
        );
        assert!(
            allowed
                .iter()
                .all(|rule| rule.ends_with("(./**)") || rule == "mcp__tokenstat_team")
        );
        assert_eq!(fs::read_to_string(&program.input).unwrap(), LANE_PROMPT);
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
