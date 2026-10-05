// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One-turn CLI protocol runner. Speed controls use a private, turn-owned
//! mailbox, never agent prompt text or the provider's persistent preferences.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Mutex, OnceLock, PoisonError, mpsc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(unix)]
static STOPPED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn stopped(_: libc::c_int) {
    STOPPED.store(true, std::sync::atomic::Ordering::SeqCst);
}

#[derive(Serialize, Deserialize)]
struct Config {
    backend: String,
    argv: Vec<String>,
}

pub(crate) struct Launch {
    directory: tempfile::TempDir,
    pub(crate) argv: Vec<String>,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Conservative version floors for the exact runtime APIs used below. Older
/// installations keep their existing exec/print behavior and next-turn toggle.
pub(crate) fn supported(backend: &str) -> bool {
    // Embedded readers and CLI tools do not implement the helper subcommand.
    // They retain ordinary exec/print turns until a daemon owns their work.
    if !std::env::current_exe().ok().is_some_and(|path| {
        path.file_stem()
            .is_some_and(|name| name == "tokenstat-hostd")
    }) {
        return false;
    }
    let floor = match backend {
        "codex" => [0, 160, 0],
        "claude" => [2, 1, 289],
        _ => return false,
    };
    let command = crate::launcher::spawn_command(backend);
    static CACHE: OnceLock<Mutex<HashMap<String, (Instant, bool)>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Mutex::default);
    if let Some((at, value)) = cache
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&command)
        && at.elapsed() < Duration::from_secs(60)
    {
        return *value;
    }
    let value = (|| {
        let mut child = tokenstat_pty::headless_command(&command, &["--version".into()])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let until = Instant::now() + Duration::from_secs(2);
        loop {
            if child.try_wait().ok()?.is_some() {
                break;
            }
            if Instant::now() >= until {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let output = child.wait_with_output().ok()?;
        if !output.status.success() {
            return None;
        }
        let text = String::from_utf8(output.stdout).ok()?;
        let version = text
            .split_whitespace()
            .find(|part| part.as_bytes().first().is_some_and(u8::is_ascii_digit))?;
        let parts = version
            .split('.')
            .map(str::parse::<u64>)
            .collect::<Result<Vec<_>, _>>()
            .ok()?;
        (parts.len() == 3).then(|| [parts[0], parts[1], parts[2]] >= floor)
    })()
    .unwrap_or(false);
    cache
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(command, (Instant::now(), value));
    value
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let temporary = path.with_extension("tmp");
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .map_err(|error| error.to_string())?;
    serde_json::to_writer(&mut file, value).map_err(|error| error.to_string())?;
    file.flush().map_err(|error| error.to_string())?;
    fs::rename(temporary, path).map_err(|error| error.to_string())
}

impl Launch {
    pub(crate) fn prepare(
        backend: &str,
        argv: &[String],
        parent: &Path,
    ) -> Result<Option<Self>, String> {
        if !supported(backend) {
            return Ok(None);
        }
        let directory = tempfile::Builder::new()
            .prefix("live-speed-")
            .tempdir_in(parent)
            .map_err(|error| error.to_string())?;
        let path = directory.path().join("config.json");
        let mut original = argv.to_vec();
        original[0] = crate::launcher::spawn_command(&original[0]);
        write_json(
            &path,
            &Config {
                backend: backend.into(),
                argv: original,
            },
        )?;
        let helper = std::env::current_exe().map_err(|error| error.to_string())?;
        Ok(Some(Self {
            directory,
            argv: vec![
                helper.to_string_lossy().into_owned(),
                "chat-live".into(),
                path.to_string_lossy().into_owned(),
            ],
        }))
    }

    pub(crate) fn apply(&self, pty: &str, fast: bool) -> Result<(), String> {
        if !self.directory.path().join("ready.json").is_file() {
            return Err(
                "This agent is still starting. Try changing speed after its first step.".into(),
            );
        }
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).map_err(|error| error.to_string())?;
        let id = random
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let request = self.directory.path().join(format!("request-{id}.json"));
        let response = self.directory.path().join(format!("response-{id}.json"));
        write_json(
            &request,
            &json!({"id":id,"fast":fast,"expires":now_ms()+10_000}),
        )?;
        let until = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(bytes) = fs::read(&response) {
                let _ = fs::remove_file(&response);
                let result: Value =
                    serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
                return if result["ok"] == true {
                    Ok(())
                } else {
                    Err(result["error"]
                        .as_str()
                        .unwrap_or("The agent could not change speed.")
                        .into())
                };
            }
            if !tokenstat_pty::manager()
                .info(pty)
                .is_ok_and(|info| info.alive)
            {
                return Err("This turn has finished. Change speed for the next turn.".into());
            }
            if Instant::now() >= until {
                // An unacknowledged paid setting must not continue invisibly.
                let _ = tokenstat_pty::manager().kill(pty);
                return Err("The agent did not acknowledge its speed setting. The turn was stopped; try again.".into());
            }
            std::thread::sleep(Duration::from_millis(40));
        }
    }
}

struct Protocol {
    backend: String,
    thread: String,
    turn: String,
    pending: HashMap<String, PathBuf>,
    usage: Value,
}

fn send(input: &mut impl Write, message: &Value) -> Result<(), String> {
    serde_json::to_writer(&mut *input, message).map_err(|error| error.to_string())?;
    input
        .write_all(b"\n")
        .and_then(|()| input.flush())
        .map_err(|error| error.to_string())
}

fn emit(value: &Value) -> Result<(), String> {
    send(&mut std::io::stdout().lock(), value)
}

/// Convert only CLI launch flags we own. Unknown flags abort before a prompt
/// is sent, rather than silently losing an approval, sandbox or attachment.
fn codex_launch(argv: &[String]) -> Result<(Vec<String>, Value, Value), String> {
    let mut args = Vec::new();
    let mut setup = json!({"approvalPolicy":"never"});
    let mut input = Vec::new();
    let mut effort = None;
    let mut at = 1;
    while at < argv.len() {
        match argv[at].as_str() {
            "-c" => {
                let config = argv.get(at + 1).ok_or("missing Codex config")?;
                if let Some(value) = config.strip_prefix("model_reasoning_effort=") {
                    effort = Some(value.to_string());
                }
                if let Some(value) = config.strip_prefix("service_tier=") {
                    setup["serviceTier"] =
                        serde_json::from_str(value).map_err(|error| error.to_string())?;
                }
                args.extend_from_slice(argv.get(at..at + 2).ok_or("missing Codex config")?);
                at += 2;
            }
            "--model" => {
                setup["model"] = json!(argv.get(at + 1).ok_or("missing Codex model")?);
                at += 2;
            }
            "exec" | "--json" | "--skip-git-repo-check" => at += 1,
            "resume" => {
                setup["threadId"] = json!(argv.get(at + 1).ok_or("missing Codex session")?);
                at += 2;
            }
            "--dangerously-bypass-hook-trust" => {
                setup["config"] = json!({"bypass_hook_trust":true});
                at += 1;
            }
            "--dangerously-bypass-approvals-and-sandbox" => {
                setup["sandbox"] = json!("danger-full-access");
                at += 1;
            }
            "--sandbox" => {
                setup["sandbox"] = json!(argv.get(at + 1).ok_or("missing Codex sandbox")?);
                at += 2;
            }
            "-i" => {
                input.push(json!({"type":"localImage","path":argv.get(at+1).ok_or("missing Codex image")?}));
                at += 2;
            }
            "--" => {
                let prompt = argv.get(at + 1).ok_or("missing Codex prompt")?;
                if at + 2 != argv.len() {
                    return Err("unexpected Codex prompt arguments".into());
                }
                input.push(json!({"type":"text","text":prompt}));
                break;
            }
            flag => return Err(format!("unsupported live Codex launch flag: {flag}")),
        }
    }
    if input.is_empty() {
        return Err("missing Codex input".into());
    }
    args.push("app-server".into());
    args.push("--stdio".into());
    let mut turn = json!({"input":input});
    if let Some(effort) = effort {
        turn["effort"] = json!(effort);
    }
    Ok((args, setup, turn))
}

fn claude_launch(argv: &[String]) -> Result<(Vec<String>, String), String> {
    let mut args = argv[1..].to_vec();
    let at = args
        .iter()
        .position(|arg| arg == "-p")
        .ok_or("missing Claude print flag")?;
    let prompt = args.get(at + 1).ok_or("missing Claude prompt")?.clone();
    args.remove(at + 1);
    args.extend(["--input-format".into(), "stream-json".into()]);
    Ok((args, prompt))
}

fn read_messages(child: &mut Child) -> Result<mpsc::Receiver<Result<Value, String>>, String> {
    let output = child.stdout.take().ok_or("missing agent output")?;
    let (tx, rx) = mpsc::sync_channel(32);
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            let value = line
                .map_err(|error| error.to_string())
                .and_then(|line| serde_json::from_str(&line).map_err(|error| error.to_string()));
            if tx.send(value).is_err() {
                break;
            }
        }
    });
    Ok(rx)
}

impl Protocol {
    fn controls(&mut self, directory: &Path, input: &mut impl Write) -> Result<(), String> {
        for entry in fs::read_dir(directory).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(id) = name
                .strip_prefix("request-")
                .and_then(|name| name.strip_suffix(".json"))
            else {
                continue;
            };
            if id.len() != 32 || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                continue;
            }
            let request: Value =
                serde_json::from_slice(&fs::read(entry.path()).map_err(|error| error.to_string())?)
                    .map_err(|error| error.to_string())?;
            let response = directory.join(format!("response-{id}.json"));
            if request["id"] != id
                || request["expires"]
                    .as_u64()
                    .is_none_or(|expires| expires <= now_ms())
            {
                write_json(
                    &response,
                    &json!({"ok":false,"error":"The speed request expired. Try again."}),
                )?;
            } else {
                let fast = request["fast"].as_bool().ok_or("invalid speed request")?;
                let message = if self.backend == "claude" {
                    json!({"type":"control_request","request_id":id,"request":{"subtype":"apply_flag_settings","settings":{"fastMode":fast}}})
                } else {
                    json!({"id":id,"method":"turn/settings/update","params":{"threadId":self.thread,"turnId":self.turn,"serviceTier":if fast {"priority"} else {"default"}}})
                };
                send(input, &message)?;
                self.pending.insert(id.into(), response);
            }
            fs::remove_file(entry.path()).map_err(|error| error.to_string())?;
        }
        Ok(())
    }

    fn acknowledge(&mut self, value: &Value) -> Result<bool, String> {
        let response = if self.backend == "claude" {
            &value["response"]
        } else {
            value
        };
        let id = if self.backend == "claude" {
            response["request_id"].as_str()
        } else {
            response["id"].as_str()
        };
        let Some(path) = id.and_then(|id| self.pending.remove(id)) else {
            return Ok(false);
        };
        let ok = if self.backend == "claude" {
            response["subtype"] == "success"
        } else {
            response["result"]["status"] == "applied"
        };
        let error = response["error"]
            .as_str()
            .or_else(|| response["error"]["message"].as_str())
            .unwrap_or("The active turn could not apply this speed setting.");
        write_json(&path, &json!({"ok":ok,"error":error}))?;
        Ok(true)
    }
}

/// Entry point called only by the bundled host helper's `chat-live` command.
pub fn run(path: &Path) -> Result<(), String> {
    let config: Config =
        serde_json::from_slice(&fs::read(path).map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())?;
    let directory = path.parent().ok_or("missing live control directory")?;
    let (args, mut setup, initial) = match config.backend.as_str() {
        "codex" => codex_launch(&config.argv)?,
        "claude" => {
            let (args, prompt) = claude_launch(&config.argv)?;
            (args, Value::Null, json!(prompt))
        }
        _ => return Err("unsupported live agent".into()),
    };
    if config.backend == "codex" {
        // Like exec, each turn uses the workspace it was launched in. A
        // resumed thread may remember a directory that has since moved.
        setup["cwd"] = json!(std::env::current_dir().map_err(|error| error.to_string())?);
        if setup["threadId"].is_string() {
            // Only the thread identity is needed; its old messages remain in
            // the provider's session and must not be hydrated into this turn.
            setup["excludeTurns"] = json!(true);
        }
    }
    let mut command = tokenstat_pty::headless_command(&config.argv[0], &args);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // The wrapper stays in its PTY; the CLI's own group contains only
        // this turn's children. Stop retires that group before the wrapper.
        command.process_group(0);
        // SAFETY: the standalone runner is single-threaded here. The handler
        // only stores an atomic flag and does not touch allocation or I/O.
        unsafe {
            libc::signal(libc::SIGHUP, stopped as *const () as libc::sighandler_t);
            libc::signal(libc::SIGTERM, stopped as *const () as libc::sighandler_t);
            libc::signal(libc::SIGINT, stopped as *const () as libc::sighandler_t);
        }
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| error.to_string())?;
    let result = (|| {
        let rx = read_messages(&mut child)?;
        let mut input = child.stdin.take().ok_or("missing agent input")?;
        let mut protocol = Protocol {
            backend: config.backend.clone(),
            thread: String::new(),
            turn: String::new(),
            pending: HashMap::new(),
            usage: Value::Null,
        };
        let initialize = if config.backend == "codex" {
            json!({"id":"initialize","method":"initialize","params":{"clientInfo":{"name":"tokenstat","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}})
        } else {
            json!({"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}})
        };
        send(&mut input, &initialize)?;
        let startup_deadline = Instant::now() + Duration::from_secs(30);
        let mut initialized = false;
        let mut started = false;
        loop {
            #[cfg(unix)]
            if STOPPED.load(std::sync::atomic::Ordering::SeqCst) {
                return Err("The turn was stopped.".into());
            }
            if !started && Instant::now() >= startup_deadline {
                return Err("The agent did not initialize its live protocol.".into());
            }
            let message = match rx.recv_timeout(Duration::from_millis(40)) {
                Ok(value) => value?,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if started {
                        protocol.controls(directory, &mut input)?;
                    }
                    continue;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err("The agent closed its protocol before completing the turn.".into());
                }
            };
            if protocol.acknowledge(&message)? {
                continue;
            }
            if config.backend == "claude" {
                if message["type"] == "control_response"
                    && message["response"]["request_id"] == "initialize"
                {
                    if message["response"]["subtype"] != "success" {
                        return Err("Claude could not initialize its live protocol.".into());
                    }
                    send(
                        &mut input,
                        &json!({"type":"user","session_id":"","message":{"role":"user","content":[{"type":"text","text":initial.as_str().ok_or("invalid Claude prompt")?}]},"parent_tool_use_id":null}),
                    )?;
                    initialized = true;
                } else if message["type"] == "result" {
                    emit(&message)?;
                    if message["is_error"] == true {
                        return Err("Claude reported a failed turn.".into());
                    }
                    return Ok(());
                } else {
                    emit(&message)?;
                    if initialized && message["type"] == "system" && message["subtype"] == "init" {
                        write_json(&directory.join("ready.json"), &json!(true))?;
                        started = true;
                    }
                }
            } else if message["id"] == "initialize" {
                if message.get("error").is_some() {
                    return Err(message["error"]["message"]
                        .as_str()
                        .unwrap_or("Codex initialization failed")
                        .into());
                }
                send(&mut input, &json!({"method":"initialized"}))?;
                send(
                    &mut input,
                    &json!({"id":"thread","method":if setup["threadId"].is_string() {"thread/resume"} else {"thread/start"},"params":setup}),
                )?;
            } else if message["id"] == "thread" {
                protocol.thread = message["result"]["thread"]["id"]
                    .as_str()
                    .ok_or_else(|| {
                        message["error"]["message"]
                            .as_str()
                            .unwrap_or("Codex could not open its thread")
                            .to_string()
                    })?
                    .into();
                emit(&json!({"type":"thread.started","thread_id":protocol.thread}))?;
                let mut params = initial.clone();
                params["threadId"] = json!(protocol.thread);
                send(
                    &mut input,
                    &json!({"id":"turn","method":"turn/start","params":params}),
                )?;
            } else if message["id"] == "turn" || message["method"] == "turn/started" {
                let turn = if message["id"] == "turn" {
                    &message["result"]["turn"]
                } else {
                    &message["params"]["turn"]
                };
                protocol.turn = turn["id"]
                    .as_str()
                    .ok_or_else(|| {
                        message["error"]["message"]
                            .as_str()
                            .unwrap_or("Codex could not start its turn")
                            .to_string()
                    })?
                    .into();
                if !started {
                    write_json(&directory.join("ready.json"), &json!(true))?;
                    started = true;
                }
            } else if message["method"] == "turn/completed" {
                let turn = &message["params"]["turn"];
                if turn["status"] != "completed" {
                    emit(
                        &json!({"type":"error","message":turn["error"]["message"].as_str().unwrap_or("Codex turn failed or was interrupted")}),
                    )?;
                    return Err("Codex did not complete the turn.".into());
                }
                emit(&json!({"type":"turn.completed","usage":protocol.usage}))?;
                // Match exec's shutdown: retiring the thread lets its rollout
                // writer flush before the stdio server itself is closed.
                send(
                    &mut input,
                    &json!({"id":"shutdown","method":"thread/unsubscribe","params":{"threadId":protocol.thread}}),
                )?;
                let until = Instant::now() + Duration::from_secs(3);
                while Instant::now() < until {
                    #[cfg(unix)]
                    if STOPPED.load(std::sync::atomic::Ordering::SeqCst) {
                        return Err("The turn was stopped.".into());
                    }
                    match rx.recv_timeout(Duration::from_millis(40)) {
                        Ok(Ok(reply)) if reply["id"] == "shutdown" => break,
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        _ => {}
                    }
                }
                return Ok(());
            } else if message["method"] == "thread/tokenUsage/updated" {
                let total = &message["params"]["tokenUsage"]["total"];
                protocol.usage = json!({"input_tokens":total["inputTokens"],"cached_input_tokens":total["cachedInputTokens"],"cache_write_input_tokens":total["cacheWriteInputTokens"],"output_tokens":total["outputTokens"],"reasoning_output_tokens":total["reasoningOutputTokens"]});
            } else if matches!(
                message["method"].as_str(),
                Some("item/started" | "item/completed")
            ) {
                if let Some(item) = codex_item(&message["params"]["item"]) {
                    emit(
                        &json!({"type":if message["method"] == "item/started" {"item.started"} else {"item.completed"},"item":item}),
                    )?;
                }
            } else if message.get("id").is_some() && message["method"].is_string() {
                // Match exec's noninteractive contract. Never silently grant a
                // provider permission request or leave it parked indefinitely.
                send(
                    &mut input,
                    &json!({"id":message["id"],"error":{"code":-32601,"message":"This headless turn uses Tokenstat tool hooks; interactive requests are unavailable."}}),
                )?;
            }
            if started {
                protocol.controls(directory, &mut input)?;
            }
        }
    })();
    // Closing protocol stdin lets the CLI flush its resume history. A Stop
    // or failure terminates immediately; a successful turn gets a brief,
    // bounded graceful shutdown before its process is retired.
    let mut exited = false;
    if result.is_ok() {
        let until = Instant::now() + Duration::from_secs(3);
        while Instant::now() < until {
            #[cfg(unix)]
            if STOPPED.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            if child.try_wait().is_ok_and(|status| status.is_some()) {
                exited = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    if !exited {
        #[cfg(windows)]
        tokenstat_pty::kill_windows_process_tree(child.id());
        #[cfg(unix)]
        // SAFETY: this unreaped child owns a fresh process group, so its PID
        // cannot be reused while we terminate only this turn's descendants.
        unsafe {
            libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL);
        }
        let _ = child.kill();
    }
    let _ = child.wait();
    result
}

fn codex_item(item: &Value) -> Option<Value> {
    let mut item = item.clone();
    let object = item.as_object_mut()?;
    let kind = match object.get("type")?.as_str()? {
        "agentMessage" => "agent_message",
        "commandExecution" => "command_execution",
        "fileChange" => "file_change",
        "reasoning" => "reasoning",
        "mcpToolCall" => "mcp_tool_call",
        "webSearch" => "web_search",
        _ => return None,
    };
    object.insert("type".into(), json!(kind));
    if kind == "file_change"
        && object
            .get("status")
            .is_some_and(|status| status == "declined")
    {
        object.insert("status".into(), json!("failed"));
    }
    for (source, target) in [
        ("aggregatedOutput", "aggregated_output"),
        ("exitCode", "exit_code"),
    ] {
        if let Some(value) = object.remove(source) {
            object.insert(target.into(), value);
        }
    }
    if let Some(changes) = object.get_mut("changes").and_then(Value::as_array_mut) {
        for change in changes {
            if change["kind"].is_object() {
                change["kind"] = change["kind"]["type"].clone();
            }
        }
    }
    Some(item)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_translation_keeps_hooks_resume_sandbox_images_and_literal_prompts() {
        let original = [
            "codex",
            "-c",
            "service_tier=\"priority\"",
            "--model",
            "gpt-5.6-sol",
            "exec",
            "--dangerously-bypass-hook-trust",
            "--sandbox",
            "read-only",
            "resume",
            "session",
            "--json",
            "--skip-git-repo-check",
            "-i",
            "/tmp/image with spaces.png",
            "--",
            "literal `text` $HOME\nnew line",
        ]
        .map(String::from);
        let (args, setup, input) = codex_launch(&original).unwrap();
        assert_eq!(
            args,
            ["-c", "service_tier=\"priority\"", "app-server", "--stdio"]
        );
        assert_eq!(setup["config"]["bypass_hook_trust"], true);
        assert_eq!(setup["sandbox"], "read-only");
        assert_eq!(setup["threadId"], "session");
        assert_eq!(setup["model"], "gpt-5.6-sol");
        assert_eq!(setup["approvalPolicy"], "never");
        assert_eq!(setup["serviceTier"], "priority");
        assert_eq!(input["input"][0]["path"], "/tmp/image with spaces.png");
        assert_eq!(input["input"][1]["text"], "literal `text` $HOME\nnew line");
        let mut unknown = original.to_vec();
        unknown.insert(1, "--new-permission-mode".into());
        assert!(codex_launch(&unknown).is_err());
        let (args, prompt) = claude_launch(
            &[
                "claude",
                "--settings",
                "{\"hooks\":{},\"fastMode\":true}",
                "-p",
                "literal prompt",
                "--resume",
                "session",
            ]
            .map(String::from),
        )
        .unwrap();
        assert_eq!(prompt, "literal prompt");
        assert_eq!(
            args,
            [
                "--settings",
                "{\"hooks\":{},\"fastMode\":true}",
                "-p",
                "--resume",
                "session",
                "--input-format",
                "stream-json"
            ]
        );
    }

    #[test]
    fn acknowledgements_belong_to_the_request_and_refused_controls_stay_failed() {
        for backend in ["codex", "claude"] {
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("response.json");
            let mut protocol = Protocol {
                backend: backend.into(),
                thread: "thread".into(),
                turn: "turn".into(),
                pending: HashMap::from([("request".into(), path.clone())]),
                usage: Value::Null,
            };
            assert!(
                !protocol
                    .acknowledge(&json!({"id":"someone-else","result":{"status":"applied"}}))
                    .unwrap()
            );
            assert!(!path.exists());
            let message = if backend == "claude" {
                json!({"type":"control_response","response":{"request_id":"request","subtype":"error","error":"unavailable"}})
            } else {
                json!({"id":"request","result":{"status":"targetUnavailable"}})
            };
            assert!(protocol.acknowledge(&message).unwrap());
            let response: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
            assert_eq!(response["ok"], false);
            assert!(protocol.pending.is_empty());
        }
    }
}
