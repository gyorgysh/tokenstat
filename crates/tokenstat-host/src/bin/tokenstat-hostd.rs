// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The tokenstat host daemon.
//!
//! Serves the same dispatch the in-process bridge does, over a unix socket
//! (macOS, Linux) or a named pipe (Windows), so a client that is not in this
//! process can ask the same questions.
//!
//! Runs in the foreground and logs to stderr. Lifetime belongs to launchd or
//! the Windows scheduled task, not to this binary: a daemon that forks itself
//! is one the supervisor cannot see, restart, or stop.

#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::{
    io::{BufRead, BufReader, Read, Write},
    process::ExitCode,
};

use serde_json::{Value, json};

use tokenstat_host::{Session, ownership, server};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tokenstat-hostd: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    // The daemon holds a connection per peer, a stream per screen session and
    // a socket per SSH session at once. See `open_files`.
    tokenstat_host::open_files::raise_open_file_limit();

    let mut args = std::env::args().skip(1);
    let mut socket = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "hook" => {
                let flavor = args.next().ok_or("hook needs a backend flavor")?;
                let phase = args.next().ok_or("hook needs pre or post")?;
                return run_hook(&flavor, &phase);
            }
            "--socket" | "-s" | "--pipe" => {
                socket = Some(args.next().ok_or("--socket / --pipe needs a path")?);
            }
            "--help" | "-h" => {
                println!("{USAGE}");
                return Ok(());
            }
            "--version" | "-V" => {
                println!("tokenstat-hostd {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            other => return Err(format!("unexpected argument: {other}\n\n{USAGE}")),
        }
    }

    let path = match socket {
        Some(p) => std::path::PathBuf::from(p),
        None => server::default_socket_path()?,
    };

    // Before anything else, and before the archive is opened: one machine
    // identity, one daemon. Two hosts sharing a key expire each other's tunnel
    // credential on every renewal and knock each other off the relay, which
    // reads as an unreachable machine and names no cause anywhere. See
    // `ownership`.
    let role = ownership::ensure_may_serve(&path)?;
    if role == ownership::Role::Secondary {
        watch_for_the_installed_host();
    }

    // The login environment resolve is the one piece of a first spawn that can
    // take seconds (a loaded shell profile). Start it now, on a thread, so the
    // archive open and socket bind below overlap with it and the resolve is
    // finished by the time anybody can ask for a terminal.
    tokenstat_pty::warm_login_env();
    // The first Shell click should not pay a login-shell startup either, so a
    // fully-started shell is warmed beside the environment and handed over on
    // request.
    tokenstat_pty::warm_shell_pool();

    // Open the archive before binding. Failing after the socket exists would
    // leave clients connecting to something that answers every request with an
    // error, which is harder to diagnose than a daemon that refused to start.
    let session = Session::open_default()?;
    let listener = server::bind(&path)?;
    eprintln!("tokenstat-hostd listening on {}", path.display());

    server::serve(listener, session)
}

/// What one `PreToolUse` hook decided, and why.
///
/// A three-state answer rather than a `Result`, because "the host is
/// unreachable" and "the person pressed Deny" have to reach the model as the
/// same kind of thing: a refusal it must not retry. The old code returned
/// `Err` for both and let `main` exit non-zero, which every one of these CLIs
/// reads as a non-blocking error and carries on past. **Measured on Claude
/// Code 2.1.251: a hook exiting 1 does not block the tool.** So this type
/// exists to force a decision document on stdout, always, exit 0.
#[derive(Debug)]
enum Decision {
    Allow,
    Deny(String),
}

/// Called by an agent's lifecycle hook.
///
/// The host daemon is authoritative. A missing credential, malformed payload,
/// socket failure, malformed reply, or nobody answering in time all deny.
/// Never turn one of those into an allow, and never signal one by exiting
/// non-zero: an exit code is not a denial to any of these CLIs.
fn run_hook(flavor: &str, phase: &str) -> Result<(), String> {
    if phase != "pre" && phase != "post" {
        return Err("hook phase must be pre or post".into());
    }
    if phase == "post" {
        // A post hook records an outcome. It cannot block anything, so a
        // failure here is silence rather than a refusal of work already done.
        let _ = run_post_hook(flavor);
        if flavor == "agy" {
            println!("{{}}");
        }
        return Ok(());
    }
    let decision = match run_pre_hook(flavor) {
        Ok(decision) => decision,
        Err(reason) => Decision::Deny(reason),
    };
    println!("{}", decision_document(flavor, &decision));
    Ok(())
}

/// Spell one decision the way this backend understands it.
///
/// Each of these is the CLI's own documented contract, and each was checked
/// against that CLI rather than assumed. The shapes differ; the exit code does
/// not, and is always success, because a non-zero exit is what silently let
/// every denial through before.
fn decision_document(flavor: &str, decision: &Decision) -> String {
    match (flavor, decision) {
        // Claude Code: `permissionDecision` on stdout blocks and is reported
        // back in `permission_denials`. Verified: the tool did not run.
        ("claude", Decision::Allow) => "{}".into(),
        ("claude", Decision::Deny(reason)) => json!({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        })
        .to_string(),
        // Grok, agy and codex read the Claude-compatible top-level form.
        // `permissionDecision` rides along too: grok documents it as the
        // canonical spelling and prefers it when both are present.
        (_, Decision::Allow) => json!({"decision": "allow"}).to_string(),
        (flavor, Decision::Deny(reason)) => json!({
            "decision": deny_word(flavor),
            "reason": reason,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        })
        .to_string(),
    }
}

/// The word this backend actually acts on.
///
/// Codex accepts `deny` without complaint and **runs the tool anyway**;
/// only `block` stops it. Measured twice on the same binary, same payload,
/// one word apart: `block` produced "blocked by the PreToolUse hook", `deny`
/// produced "Yes, it ran successfully". A refusal that is silently spelled
/// wrong is worse than no gate, because the person was asked and told their
/// answer was taken. Grok documents `block` as a legacy alias and agy is
/// verified on `deny`, so only codex is moved.
fn deny_word(flavor: &str) -> &'static str {
    if flavor == "codex" { "block" } else { "deny" }
}

fn run_pre_hook(flavor: &str) -> Result<Decision, String> {
    let (token, socket, input) = hook_context()?;
    hook_request(flavor, &token, &socket, &input)
}

fn run_post_hook(flavor: &str) -> Result<(), String> {
    let (token, socket, input) = hook_context()?;
    hook_report(flavor, &token, &socket, &input)
}

/// The turn credential, the socket, and the tool payload.
///
/// The credential comes from a 0600 file rather than argv, because `ps` shows
/// argv to every process on this machine and this one authorises writing into
/// somebody's conversation.
fn hook_context() -> Result<(String, String, Value), String> {
    let token_file = std::env::var("TOKENSTAT_CHAT_TURN_FILE")
        .map_err(|_| "tokenstat cannot approve this: no turn credential")?;
    let token = std::fs::read_to_string(token_file)
        .map_err(|_| "tokenstat cannot approve this: unreadable turn credential")?;
    let token = token.trim().to_string();
    if token.is_empty() {
        return Err("tokenstat cannot approve this: empty turn credential".into());
    }
    let socket = std::env::var("TOKENSTAT_CHAT_SOCKET")
        .map_err(|_| "tokenstat cannot approve this: no host socket")?;
    let mut body = String::new();
    std::io::stdin()
        .read_to_string(&mut body)
        .map_err(|_| "tokenstat cannot approve this: unreadable tool request")?;
    let input: Value = serde_json::from_str(&body)
        .map_err(|_| "tokenstat cannot approve this: malformed tool request")?;
    Ok((token, socket, input))
}

/// Ask the daemon about one tool call and wait, within a deadline.
///
/// Split from stdin and the environment so a missing host can be tested
/// without parking on stdin.
fn hook_request(
    flavor: &str,
    token: &str,
    socket: &str,
    input: &Value,
) -> Result<Decision, String> {
    let (verb, preview, shell_prefix) = hook_tool(flavor, input);
    let request = json!({
        "id": "chat-hook",
        "method": "chat.toolRequest",
        "params": {"turnToken": token, "verb": verb, "preview": preview, "shellPrefix": shell_prefix}
    });
    let answer = hook_call(socket, &request)?;
    let request_id = answer
        .pointer("/result/requestId")
        .and_then(Value::as_str)
        .ok_or("tokenstat cannot approve this: the host refused the request")?
        .to_string();
    if answer.pointer("/result/decision").and_then(Value::as_str) == Some("allow") {
        return Ok(Decision::Allow);
    }
    // Bounded, and shorter than the timeout the CLI was given. A hook still
    // running when that expires is killed, and a killed hook lets the tool
    // through. Deciding first is what keeps silence fail-closed.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(gate_deadline());
    while std::time::Instant::now() < deadline {
        let poll = json!({
            "id": "chat-hook",
            "method": "chat.toolAwait",
            "params": {"requestId": request_id, "waitMs": 2000}
        });
        match hook_call(socket, &poll)?
            .pointer("/result/decision")
            .and_then(Value::as_str)
        {
            Some("allow") => return Ok(Decision::Allow),
            Some("deny") => {
                return Ok(Decision::Deny(
                    "The person declined this in tokenstat. Do not retry it; \
                     say what you were going to do and ask what they want instead."
                        .into(),
                ));
            }
            _ => continue,
        }
    }
    Ok(Decision::Deny(
        "Nobody answered the tokenstat approval in time, so this was refused. \
         Do not retry it; tell the person the request is still waiting for them."
            .into(),
    ))
}

fn gate_deadline() -> u64 {
    std::env::var(tokenstat_host::chat_gate::DEADLINE_ENV)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(tokenstat_host::chat_gate::GATE_DEADLINE_SECONDS)
}

/// Record what a tool call actually did, once it has run.
fn hook_report(flavor: &str, token: &str, socket: &str, input: &Value) -> Result<(), String> {
    let (call_id, ok, detail) = hook_result(flavor, input);
    let request = json!({
        "id": "chat-hook",
        "method": "chat.toolResult",
        "params": {"turnToken": token, "callId": call_id, "ok": ok, "detail": detail}
    });
    let answer = hook_call(socket, &request)?;
    (answer.pointer("/result/recorded").and_then(Value::as_bool) == Some(true))
        .then_some(())
        .ok_or_else(|| "the host rejected the tool result".to_string())
}

fn hook_result(flavor: &str, input: &Value) -> (String, bool, Option<String>) {
    let call_id = input
        .get("tool_use_id")
        .or_else(|| input.get("toolUseId"))
        .or_else(|| input.get("call_id"))
        .or_else(|| input.get("callId"))
        .or_else(|| input.get("id"))
        .or_else(|| input.get("stepIdx"))
        .and_then(|id| match id {
            Value::String(id) if !id.is_empty() => Some(id.to_owned()),
            Value::Number(id) => Some(id.to_string()),
            _ => None,
        })
        .unwrap_or_else(|| format!("{flavor}-{}", std::process::id()));
    let ok = input
        .get("success")
        .or_else(|| input.get("ok"))
        .and_then(Value::as_bool)
        .unwrap_or_else(|| input.get("error").is_none());
    let detail = input
        .get("error")
        .or_else(|| input.get("result"))
        .or_else(|| input.get("output"))
        .and_then(|value| match value {
            Value::String(text) => Some(text.chars().take(360).collect()),
            Value::Null => None,
            other => serde_json::to_string(other)
                .ok()
                .map(|text| text.chars().take(360).collect()),
        });
    (call_id, ok, detail)
}

fn hook_tool(flavor: &str, input: &Value) -> (String, String, Option<String>) {
    let tool = input.get("toolCall").unwrap_or(input);
    let verb = tool
        .get("tool_name")
        .or_else(|| input.get("tool"))
        .or_else(|| tool.get("name"))
        .and_then(Value::as_str)
        .unwrap_or(flavor)
        .to_string();
    let detail = tool
        .get("tool_input")
        .or_else(|| tool.get("input"))
        .or_else(|| tool.get("arguments"))
        .or_else(|| tool.get("args"))
        .cloned()
        .unwrap_or(Value::Null);
    let preview = tool_preview(&detail);
    let shell_prefix = detail
        .get("command")
        .or_else(|| detail.get("command_line"))
        .or_else(|| detail.get("commandLine"))
        .and_then(Value::as_str)
        .and_then(safe_shell_prefix);
    (verb, preview, shell_prefix)
}

/// One line a person can judge without reading JSON.
///
/// A permission card is a decision, and a decision needs the thing being
/// decided, not the payload it arrived in. `Bash {"command":"rm -rf
/// build","description":"Clean"}` is a wall; `rm -rf build` is a question.
/// Falls back to compact JSON only when no field is recognisably the subject.
fn tool_preview(input: &Value) -> String {
    // Compared without case or separators, because the same field is
    // `command` to Claude Code, `CommandLine` to agy and `command_line`
    // elsewhere, and a card that falls back to raw JSON because of a capital
    // letter is a card nobody can act on.
    const SUBJECTS: &[&str] = &[
        "command",
        "commandline",
        "filepath",
        "path",
        "url",
        "pattern",
        "query",
        "prompt",
    ];
    let normalise = |key: &str| {
        key.chars()
            .filter(|character| character.is_ascii_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect::<String>()
    };
    let subject = input.as_object().and_then(|fields| {
        SUBJECTS.iter().find_map(|wanted| {
            fields.iter().find_map(|(key, value)| {
                (normalise(key) == *wanted)
                    .then(|| value.as_str())
                    .flatten()
                    .map(str::to_owned)
            })
        })
    });
    let subject = subject.unwrap_or_else(|| serde_json::to_string(input).unwrap_or_default());
    subject.chars().take(360).collect()
}

/// Remember only simple argv-shaped commands. Shell operators, substitutions
/// and redirections can hide another action after an innocuous prefix, so such
/// requests must always come back through the approval queue.
fn safe_shell_prefix(command: &str) -> Option<String> {
    const SHELL_SYNTAX: &[char] = &[';', '&', '|', '\n', '\r', '`', '>', '<'];
    if command.contains(SHELL_SYNTAX) || command.contains("$(") {
        return None;
    }
    let prefix = command
        .split_whitespace()
        .take(2)
        .collect::<Vec<_>>()
        .join(" ");
    (!prefix.is_empty()).then_some(prefix)
}

#[cfg(unix)]
fn hook_call(socket: &str, request: &Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket)
        .map_err(|_| "tokenstat cannot approve this: the host is not reachable")?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(3)))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(request.to_string().as_bytes())
        .and_then(|_| stream.write_all(b"\n"))
        .map_err(|_| "tokenstat cannot approve this: the host stopped listening")?;
    let mut line = String::new();
    BufReader::new(&mut stream)
        .read_line(&mut line)
        .map_err(|_| "tokenstat cannot approve this: the host did not reply")?;
    serde_json::from_str(&line)
        .map_err(|_| "tokenstat cannot approve this: the host replied with nonsense".into())
}

#[cfg(windows)]
fn hook_call(socket: &str, request: &Value) -> Result<Value, String> {
    let mut stream = tokenstat_host::server::connect(std::path::Path::new(socket), 3_000)
        .map_err(|_| "tokenstat cannot approve this: the host is not reachable")?;
    stream
        .write_all(request.to_string().as_bytes())
        .and_then(|_| stream.write_all(b"\n"))
        .and_then(|_| stream.flush())
        .map_err(|_| "tokenstat cannot approve this: the host stopped listening")?;
    let mut line = String::new();
    BufReader::new(&mut stream)
        .read_line(&mut line)
        .map_err(|_| "tokenstat cannot approve this: the host did not reply")?;
    serde_json::from_str(&line)
        .map_err(|_| "tokenstat cannot approve this: the host replied with nonsense".into())
}

/// A second daemon that started while nothing else was running still has to
/// give the machine back when the installed host arrives.
///
/// The startup check only covers one order of events. Reboot, a `launchctl
/// kickstart`, a scheduled-task start, or simply opening the app is enough
/// to bring the installed host up behind a development one, and from that
/// moment the two are fighting over the same tunnel credential again.
///
/// Exiting rather than standing down in place. This process is by definition
/// the one nobody installed: nothing restarts it, the terminals it owns are a
/// test session's, and leaving it half alive would mean two daemons answering
/// two sockets with one archive between them. A loud exit is easier to
/// understand than a daemon that quietly stopped doing half its job.
fn watch_for_the_installed_host() {
    let Ok(identity) = tokenstat_identity::MachineIdentity::load_or_create() else {
        return;
    };
    let key = identity.public_key_hex();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(std::time::Duration::from_secs(20));
            if ownership::owned_by_primary(&key) {
                eprintln!(
                    "tokenstat-hostd: the installed host has taken this machine's identity \
                     back, so this second daemon is stopping. Two hosts on one identity \
                     expire each other's tunnel credential."
                );
                std::process::exit(0);
            }
        }
    });
}

#[cfg(windows)]
const USAGE: &str = "\
tokenstat host daemon. Serves the local archive over a named pipe.

Usage: tokenstat-hostd [--pipe <name>]

Options:
  -s, --socket <name>  Same as --pipe
      --pipe <name>    Listen here instead of \\\\.\\pipe\\ai.tokenstat.hostd.<user>
  -h, --help           Print this
  -V, --version        Print the version

Runs in the foreground. Use a per-user scheduled task to keep it alive.
See scripts/install-host-task.ps1.
";

#[cfg(not(windows))]
const USAGE: &str = "\
tokenstat host daemon. Serves the local archive over a unix socket.

Usage: tokenstat-hostd [--socket <path>]

Options:
  -s, --socket <path>  Listen here instead of the default under the data dir
      --pipe <path>    Same as --socket
  -h, --help           Print this
  -V, --version        Print the version

Runs in the foreground. Use launchd to keep it alive; see docs/desktop-app.md.
";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_input_keeps_the_tool_and_short_shell_prefix() {
        let (verb, preview, prefix) = hook_tool(
            "claude",
            &json!({"tool_name":"Bash", "tool_input":{"command":"git status --short"}}),
        );
        assert_eq!(verb, "Bash");
        // The card shows the thing being decided, not the envelope it came
        // in. The verb has its own chip beside it.
        assert_eq!(preview, "git status --short");
        assert_eq!(prefix.as_deref(), Some("git status"));
    }

    /// A person judges a permission card in a second or two. Whatever names
    /// the subject of the call has to be what they read.
    #[test]
    fn a_preview_names_the_subject_of_the_call() {
        assert_eq!(
            tool_preview(&json!({"command": "rm -rf build", "description": "Clean"})),
            "rm -rf build"
        );
        assert_eq!(
            tool_preview(&json!({"file_path": "/repo/src/main.rs", "old_string": "a"})),
            "/repo/src/main.rs"
        );
        assert_eq!(
            tool_preview(&json!({"url": "https://example.com"})),
            "https://example.com"
        );
        // Nothing recognisable is still better shown than hidden.
        // agy spells the same field `CommandLine`.
        assert_eq!(
            tool_preview(&json!({"CommandLine": "echo hi", "Cwd": "/tmp"})),
            "echo hi"
        );
        assert_eq!(tool_preview(&json!({"weird": 3})), r#"{"weird":3}"#);
    }

    #[test]
    fn compound_shell_commands_are_never_remembered() {
        for command in [
            "git status && rm -rf build",
            "git status; curl example.invalid",
            "git status | tee leaked.txt",
            "git status $(touch leaked)",
            "git status > report.txt",
        ] {
            let (_, _, prefix) = hook_tool(
                "claude",
                &json!({"tool_name":"Bash", "tool_input":{"command":command}}),
            );
            assert_eq!(prefix, None, "{command}");
        }
    }

    #[test]
    fn hook_result_uses_backend_call_id_and_bounds_detail() {
        let (call_id, ok, detail) = hook_result(
            "claude",
            &json!({"tool_use_id":"tool-7", "success":false, "error":"permission denied"}),
        );
        assert_eq!(call_id, "tool-7");
        assert!(!ok);
        assert_eq!(detail.as_deref(), Some("permission denied"));
    }

    #[test]
    fn agy_hook_input_uses_its_nested_tool_and_step() {
        let input = json!({
            "stepIdx": 19,
            "toolCall": {"name": "run_command", "args": {"CommandLine": "git status --short"}},
            "error": "exit status 1"
        });
        let (verb, preview, _) = hook_tool("agy", &input);
        assert_eq!(verb, "run_command");
        assert!(preview.contains("git status --short"));
        let (call_id, ok, detail) = hook_result("agy", &input);
        assert_eq!(call_id, "19");
        assert!(!ok);
        assert_eq!(detail.as_deref(), Some("exit status 1"));
    }

    #[cfg(unix)]
    #[test]
    fn a_missing_host_socket_is_a_deny_not_an_allow() {
        let err = hook_call(
            "/tmp/tokenstat-chat-host-missing.sock",
            &json!({"id": "chat-hook", "method": "chat.toolRequest"}),
        )
        .unwrap_err();
        assert!(
            err.contains("not reachable"),
            "an unreachable host must fail closed: {err}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn standard_mode_denies_when_the_host_disappears() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("gone.sock");
        let input = json!({"tool_name": "Edit", "tool_input": {"file_path": "src/main.rs"}});
        let reason =
            hook_request("claude", "turn-token", socket.to_str().unwrap(), &input).unwrap_err();
        assert!(
            reason.contains("tokenstat cannot approve this"),
            "a disappeared host must deny the tool: {reason}"
        );
    }

    /// The defect that made every denial useless.
    ///
    /// A hook that exits non-zero does not block Claude Code: measured, the
    /// tool ran anyway. So a refusal has to be a document on stdout, and this
    /// asserts the shape each CLI actually reads.
    #[test]
    fn a_refusal_is_a_document_each_backend_understands() {
        let claude: Value =
            serde_json::from_str(&decision_document("claude", &Decision::Deny("no".into())))
                .unwrap();
        assert_eq!(
            claude["hookSpecificOutput"]["permissionDecision"], "deny",
            "claude reads permissionDecision, not an exit code"
        );
        assert_eq!(claude["hookSpecificOutput"]["hookEventName"], "PreToolUse");

        for flavor in ["grok", "agy", "codex"] {
            let denied: Value =
                serde_json::from_str(&decision_document(flavor, &Decision::Deny("no".into())))
                    .unwrap();
            assert_eq!(denied["decision"], deny_word(flavor), "{flavor}");
            assert_eq!(denied["reason"], "no", "{flavor}");
            assert_eq!(denied["hookSpecificOutput"]["permissionDecision"], "deny");
            let allowed: Value =
                serde_json::from_str(&decision_document(flavor, &Decision::Allow)).unwrap();
            assert_eq!(allowed["decision"], "allow", "{flavor}");
        }

        // Codex is the one that needs the other word, and getting it wrong
        // does not error, it just runs the tool.
        assert_eq!(deny_word("codex"), "block");
        assert_eq!(deny_word("grok"), "deny");

        // Claude wants silence for an allow: any decision key it did not ask
        // for is a chance to be misread.
        let allowed = decision_document("claude", &Decision::Allow);
        assert_eq!(allowed, "{}");
    }

    /// A refusal has to tell the model to stop, or it burns the turn retrying.
    #[test]
    fn a_refusal_tells_the_model_not_to_retry() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("gone.sock");
        let reason = hook_request(
            "claude",
            "turn-token",
            socket.to_str().unwrap(),
            &json!({"tool_name": "Bash"}),
        )
        .unwrap_err();
        let document = decision_document("claude", &Decision::Deny(reason));
        assert!(document.contains("tokenstat cannot approve this"));
    }
}
