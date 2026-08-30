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

use std::{io::Read, process::ExitCode};
#[cfg(unix)]
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
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

/// Called by an agent's lifecycle hook. The host daemon is authoritative: a
/// missing credential, malformed hook payload, socket failure, or malformed
/// daemon reply all deny. Never turn one of those failures into an allow.
fn run_hook(flavor: &str, phase: &str) -> Result<(), String> {
    if flavor == "agy" {
        return run_agy_hook(phase);
    }
    run_hook_inner(flavor, phase)
}

/// Agy command hooks communicate exclusively with JSON. A malformed request or
/// unreachable daemon must become an explicit denial, never an unstructured
/// command failure that the CLI could interpret as permission to continue.
fn run_agy_hook(phase: &str) -> Result<(), String> {
    if phase != "pre" && phase != "post" {
        return Err("hook phase must be pre or post".into());
    }
    match run_hook_inner("agy", phase) {
        Ok(()) if phase == "pre" => println!(r#"{{"decision":"allow"}}"#),
        Ok(()) => println!("{{}}"),
        Err(reason) if phase == "pre" => println!(
            "{}",
            json!({"decision": "deny", "reason": format!("Tokenstat approval unavailable: {reason}")})
        ),
        Err(_) => println!("{{}}"),
    }
    Ok(())
}

fn run_hook_inner(flavor: &str, phase: &str) -> Result<(), String> {
    if phase != "pre" && phase != "post" {
        return Err("hook phase must be pre or post".into());
    }
    let token_file = std::env::var("TOKENSTAT_CHAT_TURN_FILE")
        .map_err(|_| "chat approval is unavailable: no turn credential")?;
    let token = std::fs::read_to_string(token_file)
        .map_err(|_| "chat approval is unavailable: cannot read turn credential")?;
    let token = token.trim();
    if token.is_empty() {
        return Err("chat approval is unavailable: empty turn credential".into());
    }
    let mut body = String::new();
    std::io::stdin()
        .read_to_string(&mut body)
        .map_err(|_| "chat approval is unavailable: cannot read tool request")?;
    let input: Value = serde_json::from_str(&body)
        .map_err(|_| "chat approval is unavailable: invalid tool request")?;
    let socket = std::env::var("TOKENSTAT_CHAT_SOCKET")
        .map_err(|_| "chat approval is unavailable: no host socket")?;
    if phase == "post" {
        let (call_id, ok, detail) = hook_result(flavor, &input);
        let request = json!({
            "id": "chat-hook",
            "method": "chat.toolResult",
            "params": {"turnToken": token, "callId": call_id, "ok": ok, "detail": detail}
        });
        let answer = hook_call(&socket, &request)?;
        return (answer.pointer("/result/recorded").and_then(Value::as_bool) == Some(true))
            .then_some(())
            .ok_or_else(|| "chat approval is unavailable: host rejected tool result".to_string());
    }
    let (verb, preview, shell_prefix) = hook_tool(flavor, &input);
    let request = json!({
        "id": "chat-hook",
        "method": "chat.toolRequest",
        "params": {"turnToken": token, "verb": verb, "preview": preview, "shellPrefix": shell_prefix}
    });
    let answer = hook_call(&socket, &request)?;
    let request_id = answer
        .pointer("/result/requestId")
        .and_then(Value::as_str)
        .ok_or("chat approval is unavailable: host rejected tool request")?;
    if answer.pointer("/result/decision").and_then(Value::as_str) == Some("allow") {
        return Ok(());
    }
    loop {
        let poll = json!({"id":"chat-hook", "method":"chat.toolAwait", "params":{"requestId": request_id, "waitMs": 2000}});
        let answer = hook_call(&socket, &poll)?;
        match answer.pointer("/result/decision").and_then(Value::as_str) {
            Some("allow") => return Ok(()),
            Some("deny") => return Err("tokenstat denied this tool request".into()),
            _ => continue,
        }
    }
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
    let rendered = serde_json::to_string(&detail).unwrap_or_default();
    let preview = format!("{verb} {}", rendered.chars().take(360).collect::<String>());
    let shell_prefix = detail
        .get("command")
        .or_else(|| detail.get("command_line"))
        .or_else(|| detail.get("commandLine"))
        .and_then(Value::as_str)
        .map(|command| {
            command
                .split_whitespace()
                .take(2)
                .collect::<Vec<_>>()
                .join(" ")
        });
    (verb, preview, shell_prefix)
}

#[cfg(unix)]
fn hook_call(socket: &str, request: &Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket)
        .map_err(|_| "chat approval is unavailable: host is not reachable")?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(3)))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(request.to_string().as_bytes())
        .and_then(|_| stream.write_all(b"\n"))
        .map_err(|_| "chat approval is unavailable: cannot reach host")?;
    let mut line = String::new();
    BufReader::new(&mut stream)
        .read_line(&mut line)
        .map_err(|_| "chat approval is unavailable: host did not reply")?;
    serde_json::from_str(&line)
        .map_err(|_| "chat approval is unavailable: invalid host reply".into())
}

#[cfg(windows)]
fn hook_call(_: &str, _: &Value) -> Result<Value, String> {
    Err("chat approval is unavailable on this host".into())
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
        assert!(preview.starts_with("Bash"));
        assert_eq!(prefix.as_deref(), Some("git status"));
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
}
