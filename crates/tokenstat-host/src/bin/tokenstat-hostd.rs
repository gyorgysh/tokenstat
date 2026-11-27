// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.
//! The tokenstat host daemon.

#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::{
    io::{Read, Write},
    process::ExitCode,
};

#[cfg(unix)]
use std::io::{BufRead, BufReader};

use serde_json::{Value, json};

use tokenstat_host::{Session, ownership, server};

#[path = "../hook_preview.rs"]
mod hook_preview;

#[cfg(any(windows, test))]
#[path = "../windows_log.rs"]
mod windows_log;

fn main() -> ExitCode {
    #[cfg(target_os = "macos")]
    if let Some(code) = tokenstat_sync::quiet_keychain::serve_if_requested() {
        return ExitCode::from(code);
    }

    if std::env::args().nth(1).as_deref() == Some("statusline") {
        return ExitCode::from(tokenstat_host::claude_usage::run_status_line());
    }
    #[cfg(windows)]
    let daemon_mode = !matches!(
        std::env::args().nth(1).as_deref(),
        Some(
            "hook"
                | "statusline"
                | "team-hook"
                | "chat-live"
                | "team-run-anchor"
                | "team-run-guardian"
                | "team-run-sdk"
                | "--help"
                | "-h"
                | "--version"
                | "-V"
        )
    );
    #[cfg(windows)]
    if daemon_mode {
        windows_log::initialize();
    }
    adopt_home();
    match run() {
        Ok(()) => {
            #[cfg(windows)]
            if daemon_mode {
                eprintln!(
                    "{} hostd stopped normally pid={}",
                    jiff::Timestamp::now(),
                    std::process::id()
                );
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("tokenstat-hostd: {e}");
            ExitCode::FAILURE
        }
    }
}

fn adopt_home() {
    if cfg!(windows) {
        return;
    }
    if std::env::var_os("HOME").is_some_and(|home| !home.is_empty()) {
        return;
    }
    let Some(home) = tokenstat_paths::home_dir() else {
        return;
    };

    unsafe { std::env::set_var("HOME", home) };
}

fn run() -> Result<(), String> {
    tokenstat_host::open_files::raise_open_file_limit();

    let mut args = std::env::args().skip(1);
    let mut socket = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "team-run-sdk" => {
                if args.next().is_some() {
                    return Err("Unexpected Team SDK arguments.".into());
                }
                return tokenstat_host::team_sdk::main();
            }
            "team-run-guardian" => {
                if args.next().is_some() {
                    return Err("Unexpected guardian arguments.".into());
                }
                return tokenstat_host::team_process::guardian_main();
            }
            "team-run-anchor" => {
                if args.next().is_some() {
                    return Err("Unexpected process anchor arguments.".into());
                }
                return tokenstat_host::team_process::anchor_main()
                    .map_err(|_| "Team process anchor failed.".into());
            }
            "chat-live" => {
                let path = args.next().ok_or("chat-live needs a configuration path")?;
                return tokenstat_host::chat_live::run(std::path::Path::new(&path));
            }
            "hook" => {
                let flavor = args.next().ok_or("hook needs a backend flavor")?;
                let phase = args.next().ok_or("hook needs pre or post")?;
                return run_hook(&flavor, &phase);
            }
            "team-hook" => {
                let flavor = args.next().ok_or("Team hook needs a backend")?;
                let phase = args.next().ok_or("Team hook needs a phase")?;
                let decision = if phase == "pre" || (flavor == "cursor" && phase == "mcp") {
                    (|| -> Result<Decision, String> {
                        let mut body = String::new();
                        std::io::stdin().take(512 * 1024).read_to_string(&mut body).map_err(|_| "Invalid Team tool request")?;
                        let input:Value = serde_json::from_str(&body).map_err(|_| "Invalid Team tool request")?;
                        let name = team_tool_request(&flavor, &phase, &input).ok_or("Only this run's Team tools are available.")?;
                        if tokenstat_host::team_sdk::allows_tool(&name).map_err(|_| "Team authority is unavailable")? {
                            Ok(Decision::Allow)
                        } else { Ok(Decision::Deny("Only this run's Team tools are available. Use the team_file tools for lane work.".into())) }
                    })().unwrap_or_else(Decision::Deny)
                } else {
                    Decision::Deny("This Team hook cannot authorize that phase.".into())
                };
                println!("{}", decision_document(&flavor, &decision));
                return Ok(());
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

    let role = ownership::ensure_may_serve(&path)?;
    if role == ownership::Role::Secondary {
        watch_for_the_installed_host();
    }

    tokenstat_pty::warm_login_env();

    tokenstat_pty::warm_shell_pool();

    tokenstat_host::agent_models::refresh();

    let session = Session::open_default()?;
    let listener = server::bind(&path)?;
    eprintln!("tokenstat-hostd listening on {}", path.display());

    tokenstat_host::chat_live::warm_capabilities();

    tokenstat_host::install_team_sync();

    server::serve(listener, session)
}

fn team_tool_request(flavor: &str, phase: &str, input: &Value) -> Option<String> {
    let (name, _, _) = hook_tool(flavor, input);
    let tool = match (flavor, phase) {
        ("claude" | "codex", "pre") => name.strip_prefix("mcp__tokenstat_team__"),
        ("grok", "pre") => {
            let args = input.get("tool_input").or_else(|| input.get("toolInput"))?;

            if args["tool_name"] != name
                || !args["tool_input"].is_object()
                || !args
                    .as_object()?
                    .keys()
                    .all(|key| matches!(key.as_str(), "tool_name" | "tool_input"))
            {
                return None;
            }
            name.strip_prefix("tokenstat_team__")
        }
        ("agy", "pre") => name.strip_prefix("mcp_tokenstat_team_"),
        ("cursor", "pre") => name.strip_prefix("MCP:"),
        ("cursor", "mcp") if input["mcp_server_name"] == "tokenstat_team" => Some(name.as_str()),
        _ => None,
    }?;
    (!tool.is_empty()).then(|| format!("mcp__tokenstat_team__{tool}"))
}

#[derive(Debug)]
enum Decision {
    Allow,
    Deny(String),
}

fn run_hook(flavor: &str, phase: &str) -> Result<(), String> {
    if phase != "pre" && phase != "post" {
        return Err("hook phase must be pre or post".into());
    }
    if phase == "post" && flavor == "muse" {
        return run_muse_post_hook();
    }
    if phase == "post" {
        let note = run_post_hook(flavor).ok().flatten();
        if let Some(note) = note {
            let document = post_note_document(flavor, &note);
            if !document.is_empty() {
                println!("{document}");
            }
        }
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

fn decision_document(flavor: &str, decision: &Decision) -> String {
    match (flavor, decision) {
        ("claude", Decision::Allow) => "{}".into(),
        ("claude", Decision::Deny(reason)) => json!({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        })
        .to_string(),

        ("cursor", Decision::Allow) => json!({"permission": "allow"}).to_string(),
        ("cursor", Decision::Deny(reason)) => json!({
            "permission": "deny",
            "user_message": reason,
            "agent_message": reason,
        })
        .to_string(),

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

fn deny_word(flavor: &str) -> &'static str {
    if flavor == "codex" { "block" } else { "deny" }
}

fn post_note_document(flavor: &str, note: &str) -> String {
    let context = format!(
        "The person added a note while this step was running. Apply it now, then continue: {note}"
    );
    match flavor {
        "claude" | "codex" => json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": context,
            }
        })
        .to_string(),
        "muse" => json!({
            "hookSpecificOutput": {
                "hookEventName": "PostLLMCall",
                "additionalContext": context,
            }
        })
        .to_string(),

        "cursor" => json!({ "additional_context": context }).to_string(),
        _ => String::new(),
    }
}

fn run_muse_post_hook() -> Result<(), String> {
    let document = match hook_context() {
        Ok((token, socket, input)) if !muse_skips_note(&input) => {
            match muse_take_note(&socket, &token) {
                Ok(note) => muse_post_stdout(note.as_deref()),
                Err(_) => "{}".into(),
            }
        }
        _ => "{}".into(),
    };
    println!("{document}");
    Ok(())
}

fn muse_skips_note(input: &Value) -> bool {
    if let Some(name) = input.get("hook_event_name").and_then(Value::as_str)
        && name != "PostLLMCall"
    {
        return true;
    }
    muse_payload_is_observer(input)
}

fn muse_payload_is_observer(value: &Value) -> bool {
    match value {
        Value::String(text) => text.contains("reminder observer"),
        Value::Array(items) => items.iter().any(muse_payload_is_observer),
        Value::Object(map) => map.iter().any(|(key, child)| {
            ((key == "name" || key == "tool_name" || key == "tool")
                && child.as_str() == Some("submit_reminder_decision"))
                || muse_payload_is_observer(child)
        }),
        _ => false,
    }
}

fn muse_take_request(token: &str) -> Value {
    json!({
        "id": "muse-note",
        "method": "chat.toolResult",
        "params": { "turnToken": token, "noteOnly": true }
    })
}

fn muse_take_note(socket: &str, token: &str) -> Result<Option<String>, String> {
    let answer = hook_call(socket, &muse_take_request(token))?;
    if answer.get("error").is_some() || answer.get("ok") != Some(&Value::Bool(true)) {
        return Err("muse note was not taken".into());
    }
    Ok(answer
        .pointer("/result/note")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|note| !note.is_empty())
        .map(str::to_owned))
}

fn muse_post_stdout(note: Option<&str>) -> String {
    match note.map(str::trim).filter(|note| !note.is_empty()) {
        Some(note) => post_note_document("muse", note),
        None => "{}".into(),
    }
}

fn run_pre_hook(flavor: &str) -> Result<Decision, String> {
    let (token, socket, input) = hook_context()?;
    hook_request(flavor, &token, &socket, &input)
}

fn run_post_hook(flavor: &str) -> Result<Option<String>, String> {
    let (token, socket, input) = hook_context()?;
    hook_report(flavor, &token, &socket, &input)
}

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

fn hook_report(
    flavor: &str,
    token: &str,
    socket: &str,
    input: &Value,
) -> Result<Option<String>, String> {
    let (call_id, ok, detail) = hook_result(flavor, input);
    let request = json!({
        "id": "chat-hook",
        "method": "chat.toolResult",
        "params": {"turnToken": token, "callId": call_id, "ok": ok, "detail": detail}
    });
    let answer = hook_call(socket, &request)?;
    if answer.pointer("/result/recorded").and_then(Value::as_bool) != Some(true) {
        return Err("the host rejected the tool result".to_string());
    }
    Ok(answer
        .pointer("/result/note")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|note| !note.is_empty())
        .map(str::to_string))
}

fn hook_result(flavor: &str, input: &Value) -> (String, bool, Option<String>) {
    let present = |key: &str| input.get(key).filter(|value| !value.is_null());
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
    let call_id = if flavor == "cursor" {
        tokenstat_host::chat_gate::cursor_call_id(&call_id)
            .unwrap_or(&call_id)
            .to_string()
    } else {
        call_id
    };
    let ok = input
        .get("success")
        .or_else(|| input.get("ok"))
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            present("error").is_none()
                && present("error_message").is_none()
                && !input
                    .get("hook_event_name")
                    .and_then(Value::as_str)
                    .is_some_and(|event| event.eq_ignore_ascii_case("PostToolUseFailure"))
        });
    let detail = present("error")
        .or_else(|| present("error_message"))
        .or_else(|| present("result"))
        .or_else(|| present("output"))
        .or_else(|| present("tool_output"))
        .or_else(|| present("tool_response"))
        .map(|value| match value {
            Value::String(text) => text.chars().take(360).collect(),
            other => hook_preview::json_prefix(other),
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
        .unwrap_or(&Value::Null);
    let preview = tool_preview(detail);
    let shell_prefix = detail
        .get("command")
        .or_else(|| detail.get("command_line"))
        .or_else(|| detail.get("commandLine"))
        .and_then(Value::as_str)
        .and_then(safe_shell_prefix);
    (verb, preview, shell_prefix)
}

fn tool_preview(input: &Value) -> String {
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
    let subject = input.as_object().and_then(|fields| {
        SUBJECTS.iter().find_map(|wanted| {
            fields.iter().find_map(|(key, value)| {
                value.as_str().filter(|_| {
                    key.bytes()
                        .filter(u8::is_ascii_alphanumeric)
                        .map(|byte| byte.to_ascii_lowercase())
                        .eq(wanted.bytes())
                })
            })
        })
    });
    match subject {
        Some(text) => text.chars().take(360).collect(),
        None => hook_preview::json_prefix(input),
    }
}

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
        .set_write_timeout(Some(std::time::Duration::from_secs(3)))
        .map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(3)))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(request.to_string().as_bytes())
        .and_then(|_| stream.write_all(b"\n"))
        .map_err(|_| "tokenstat cannot approve this: the host stopped listening")?;
    let mut line = String::new();
    BufReader::new(&mut stream)
        .take(64 * 1024)
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
    let line =
        tokenstat_host::server::read_response(&mut stream, std::time::Duration::from_secs(3))
            .ok_or("tokenstat cannot approve this: the host did not reply")?;
    serde_json::from_str(&line)
        .map_err(|_| "tokenstat cannot approve this: the host replied with nonsense".into())
}

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
    fn team_hooks_bind_native_mcp_names_to_the_guardians_server() {
        for (backend, name) in [
            ("claude", "mcp__tokenstat_team__team_file_read"),
            ("codex", "mcp__tokenstat_team__team_file_read"),
            ("agy", "mcp_tokenstat_team_team_file_read"),
        ] {
            assert_eq!(
                team_tool_request(backend, "pre", &json!({"tool_name":name})).as_deref(),
                Some("mcp__tokenstat_team__team_file_read")
            );
            for denied in [
                "team_file_read",
                "Shell",
                "mcp__other__team_file_read",
                "other__team_file_read",
                "mcp_other_team_file_read",
            ] {
                assert!(team_tool_request(backend, "pre", &json!({"tool_name":denied})).is_none());
            }
        }
        let grok = json!({"tool_name":"tokenstat_team__team_file_read","tool_input":{"tool_name":"tokenstat_team__team_file_read","tool_input":{"path":"source.rs"}}});
        assert_eq!(
            team_tool_request("grok", "pre", &grok).as_deref(),
            Some("mcp__tokenstat_team__team_file_read")
        );
        for args in [
            json!({"tool_name":"tokenstat_team__team_file_read","tool_input_file":"/private/file"}),
            json!({"file":"/private/wrapper"}),
            json!({"tool_name":"other__team_file_read","tool_input":{}}),
        ] {
            assert!(
                team_tool_request(
                    "grok",
                    "pre",
                    &json!({"tool_name":"tokenstat_team__team_file_read","tool_input":args})
                )
                .is_none()
            );
        }
        assert_eq!(
            team_tool_request(
                "agy",
                "pre",
                &json!({"toolCall":{"name":"mcp_tokenstat_team_team_context","args":{}}})
            )
            .as_deref(),
            Some("mcp__tokenstat_team__team_context")
        );
        assert!(team_tool_request("cursor", "pre", &json!({"tool_name":"Read"})).is_none());

        assert!(
            team_tool_request("cursor", "pre", &json!({"tool_name":"MCP:team_file_read"}))
                .is_some()
        );
        assert_eq!(
            team_tool_request(
                "cursor",
                "mcp",
                &json!({"tool_name":"team_file_read","mcp_server_name":"tokenstat_team"})
            )
            .as_deref(),
            Some("mcp__tokenstat_team__team_file_read")
        );
        for server in [json!("other"), json!(null)] {
            assert!(
                team_tool_request(
                    "cursor",
                    "mcp",
                    &json!({"tool_name":"team_file_read","mcp_server_name":server})
                )
                .is_none()
            );
        }
    }

    #[test]
    fn hook_input_keeps_the_tool_and_short_shell_prefix() {
        let (verb, preview, prefix) = hook_tool(
            "claude",
            &json!({"tool_name":"Bash", "tool_input":{"command":"git status --short"}}),
        );
        assert_eq!(verb, "Bash");
        assert_eq!(preview, "git status --short");
        assert_eq!(prefix.as_deref(), Some("git status"));
    }

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
    fn hook_previews_keep_the_exact_json_prefix_for_unicode_and_escapes() {
        for text in ["plain", "é", "🦀", "\"\\\n\r\t\0"].map(|text| text.repeat(600)) {
            for value in [
                json!({"unrecognised": text}),
                json!([text, {"nested": [null, true, 42, 3.5]}]),
                json!({text.clone(): "long key"}),
            ] {
                let expected: String = serde_json::to_string(&value)
                    .unwrap()
                    .chars()
                    .take(360)
                    .collect();
                assert_eq!(tool_preview(&value), expected);
                assert_eq!(
                    hook_result("claude", &json!({"id": "call", "result": value}))
                        .2
                        .as_deref(),
                    Some(expected.as_str())
                );
            }
        }

        let command = format!("git status {} && rm -rf build", "x".repeat(1000));
        assert_eq!(
            hook_tool("claude", &json!({"tool_input": {"command": command}})).2,
            None
        );
    }

    #[test]
    #[ignore = "manual hook preview timing"]
    fn benchmark_large_hook_previews() {
        let text = "image-data".repeat(350_000);
        let known = json!({"tool_name": "Image", "tool_input": {"prompt": text}});
        let fallback = json!({"tool_name": "Image", "tool_input": {"payload": text}});
        let result = json!({"id": "call", "result": {"payload": text}});
        for (label, input, post) in [
            ("subject", &known, false),
            ("fallback", &fallback, false),
            ("result", &result, true),
        ] {
            let mut samples = Vec::new();
            for _ in 0..15 {
                let start = std::time::Instant::now();
                if post {
                    std::hint::black_box(hook_result("claude", input));
                } else {
                    std::hint::black_box(hook_tool("claude", input));
                }
                samples.push(start.elapsed().as_secs_f64() * 1000.0);
            }
            samples.sort_by(f64::total_cmp);
            eprintln!("hook {label} 3.5 MB: median_ms={:.6}", samples[7]);
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
    fn claude_post_hooks_keep_documented_responses_and_failure_events() {
        let response = json!({"filePath": "/repo/file.txt", "type": "create"});
        let (id, ok, detail) = hook_result(
            "claude",
            &json!({
                "hook_event_name": "PostToolUse", "tool_use_id": "toolu_fixture",
                "tool_name": "Write", "tool_response": response,
            }),
        );
        assert_eq!(id, "toolu_fixture");
        assert!(ok);
        assert_eq!(detail.as_deref(), Some(response.to_string().as_str()));
        assert_eq!(
            hook_result("claude", &json!({"tool_response": "raw output"}))
                .2
                .as_deref(),
            Some("raw output")
        );
        assert_eq!(
            hook_result(
                "claude",
                &json!({"result": "old alias", "tool_response": response})
            )
            .2
            .as_deref(),
            Some("old alias")
        );
        assert_eq!(
            hook_result(
                "claude",
                &json!({"error": "failed", "tool_response": response})
            )
            .2
            .as_deref(),
            Some("failed")
        );
        for event in ["PostToolUseFailure", "postToolUseFailure"] {
            assert!(
                !hook_result("claude", &json!({"hook_event_name": event, "error": null})).1,
                "{event} stays failed even without error text"
            );
        }
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

        assert_eq!(deny_word("codex"), "block");
        assert_eq!(deny_word("grok"), "deny");

        let allowed = decision_document("claude", &Decision::Allow);
        assert_eq!(allowed, "{}");

        let cursor: Value =
            serde_json::from_str(&decision_document("cursor", &Decision::Deny("no".into())))
                .unwrap();
        assert_eq!(
            cursor,
            json!({"permission": "deny", "user_message": "no", "agent_message": "no"})
        );
        let cursor: Value =
            serde_json::from_str(&decision_document("cursor", &Decision::Allow)).unwrap();
        assert_eq!(cursor, json!({"permission": "allow"}));
    }

    #[test]
    fn cursor_reports_a_refused_call_as_a_failure() {
        let failed = json!({
            "hook_event_name": "postToolUseFailure",
            "tool_use_id": "call-1",
            "tool_name": "Shell",
            "error_message": "blocked",
            "failure_type": "permission_denied",
        });
        let (call_id, ok, detail) = hook_result("cursor", &failed);
        assert_eq!(call_id, "call-1");
        assert!(!ok);
        assert_eq!(detail.as_deref(), Some("blocked"));

        let ran = json!({
            "hook_event_name": "postToolUse",
            "tool_use_id": "call-2",
            "error_message": null,
            "tool_output": "{\"output\":\"a.txt\\n\",\"exitCode\":0}",
        });
        let (call_id, ok, detail) = hook_result("cursor", &ran);
        assert_eq!(call_id, "call-2");
        assert!(ok);
        assert!(detail.unwrap().contains("a.txt"));
    }

    #[test]
    fn cursor_hook_result_matches_the_streams_multiline_call_identity() {
        let (id, ok, _) = hook_result(
            "cursor",
            &json!({
                "tool_use_id":"call-fixture-0\nfc_provider_0",
                "hook_event_name":"postToolUse", "tool_output":"done"
            }),
        );
        assert_eq!(id, "call-fixture-0");
        assert!(ok);
    }

    #[test]
    fn steer_post_note_is_context_not_a_block() {
        let note = "say \"hi\"";
        let claude: Value = serde_json::from_str(&post_note_document("claude", note)).unwrap();
        assert!(claude.get("decision").is_none());
        assert!(claude.get("continue").is_none());
        assert_eq!(claude["hookSpecificOutput"]["hookEventName"], "PostToolUse");
        let claude_context = claude["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .unwrap();
        assert!(claude_context.contains("say \"hi\""));
        assert!(claude_context.contains("Apply it now, then continue"));

        let codex: Value = serde_json::from_str(&post_note_document("codex", note)).unwrap();
        assert!(codex.get("decision").is_none());

        assert!(codex.get("additionalContext").is_none());
        assert_eq!(codex["hookSpecificOutput"]["hookEventName"], "PostToolUse");
        assert_eq!(
            codex["hookSpecificOutput"]["additionalContext"],
            claude["hookSpecificOutput"]["additionalContext"]
        );

        let muse: Value = serde_json::from_str(&post_note_document("muse", note)).unwrap();
        assert!(muse.get("additionalContext").is_none());
        assert!(muse.get("decision").is_none());
        assert!(muse.get("continue").is_none());
        assert_eq!(muse["hookSpecificOutput"]["hookEventName"], "PostLLMCall");
        let muse_context = muse["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .unwrap();
        assert!(muse_context.contains(note));
        assert!(muse_context.contains("Apply it now, then continue"));

        let cursor: Value = serde_json::from_str(&post_note_document("cursor", note)).unwrap();
        assert!(cursor.get("permission").is_none());
        assert_eq!(
            cursor["additional_context"],
            claude["hookSpecificOutput"]["additionalContext"]
        );

        assert!(post_note_document("grok", note).is_empty());
        assert!(post_note_document("agy", note).is_empty());
        assert!(post_note_document("opencode", note).is_empty());
        assert_eq!(muse_post_stdout(None), "{}");
        assert_eq!(muse_post_stdout(Some("  ")), "{}");
        assert_eq!(
            muse_post_stdout(Some(note)),
            post_note_document("muse", note)
        );
    }

    #[test]
    fn muse_take_request_carries_note_only_and_no_call_id() {
        let token = "turn-token";
        let request = muse_take_request(token);
        assert_eq!(request["method"], "chat.toolResult");
        assert_eq!(request["params"]["noteOnly"], true);
        assert_eq!(request["params"]["turnToken"], token);
        assert!(request["params"].get("callId").is_none());
    }

    #[test]
    fn muse_skips_an_observer_and_a_foreign_event() {
        let observer = json!({
            "hook_event_name": "PostLLMCall",
            "messages": [{ "text": "this is a reminder observer call" }]
        });
        assert!(muse_skips_note(&observer));

        let named = json!({
            "hook_event_name": "PostLLMCall",
            "tools": [{ "name": "submit_reminder_decision" }]
        });
        assert!(muse_skips_note(&named));

        let tool_name = json!({ "tool_name": "submit_reminder_decision" });
        assert!(muse_skips_note(&tool_name));

        assert!(muse_skips_note(&json!({ "hook_event_name": "PreLLMCall" })));

        assert!(!muse_skips_note(&json!({
            "tools": [{ "name": "read_file" }]
        })));
        assert!(!muse_skips_note(&json!({})));
        assert!(!muse_skips_note(&json!({
            "hook_event_name": "PostLLMCall",
            "tools": [{ "name": "read_file" }],
            "messages": [{ "text": "read the file" }]
        })));
    }

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
