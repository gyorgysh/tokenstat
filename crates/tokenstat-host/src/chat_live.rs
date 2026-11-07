// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One-turn CLI protocol runner. Live input and speed settings use a private,
//! turn-owned mailbox. Speed settings never become agent prompt text.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex, Once, OnceLock, PoisonError, mpsc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod emitter;
mod input;
mod mailbox;
mod opencode;
mod output;

const INTERRUPT_TIMEOUT: Duration = Duration::from_secs(3);
const EXIT_TIMEOUT: Duration = Duration::from_secs(3);
const STOP_TIMEOUT: Duration = Duration::from_secs(8);
const CAPABILITY_TTL: Duration = Duration::from_secs(60);

type CliVersion = Option<[u64; 3]>;
type VersionEntry = Arc<Mutex<Option<(Instant, CliVersion)>>>;

#[derive(Default)]
struct VersionCache {
    entries: Mutex<HashMap<String, VersionEntry>>,
}

impl VersionCache {
    fn version(&self, command: &str, probe: impl FnOnce() -> CliVersion) -> CliVersion {
        let entry = Arc::clone(
            self.entries
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .entry(command.to_owned())
                .or_default(),
        );
        // One probe per command, including overlapping startup/on-demand
        // reads. Other commands and unrelated RPCs do not share this lock.
        let mut cached = entry.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some((at, value)) = *cached
            && at.elapsed() < CAPABILITY_TTL
        {
            return value;
        }
        let value = probe();
        *cached = Some((Instant::now(), value));
        value
    }
}

fn cli_version(text: &str) -> CliVersion {
    let version = text
        .split_whitespace()
        .find(|part| part.as_bytes().first().is_some_and(u8::is_ascii_digit))?;
    let parts = version
        .split('.')
        .map(str::parse::<u64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    (parts.len() == 3).then(|| [parts[0], parts[1], parts[2]])
}

/// Prepare the existing, conservative capability checks while the client is
/// starting. A single background worker performs the same bounded probes as
/// on-demand reads; callers still validate through supported() and its TTL.
pub fn warm_capabilities() {
    static STARTED: Once = Once::new();
    STARTED.call_once(|| {
        let _ = std::thread::Builder::new()
            .name("tokenstat-chat-capabilities".into())
            .spawn(|| {
                for backend in ["claude", "codex"] {
                    let _ = supported(backend);
                }
            });
    });
}

#[cfg(unix)]
static STOPPED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn stopped(_: libc::c_int) {
    STOPPED.store(true, std::sync::atomic::Ordering::SeqCst);
}

fn stop_signalled() -> bool {
    #[cfg(unix)]
    {
        STOPPED.load(std::sync::atomic::Ordering::SeqCst)
    }
    #[cfg(not(unix))]
    {
        false
    }
}

fn stop_requested(directory: &Path) -> bool {
    stop_signalled() || directory.join("stop").is_file()
}

#[derive(Serialize, Deserialize)]
struct Config {
    backend: String,
    argv: Vec<String>,
    #[serde(default)]
    compact: bool,
}

pub(crate) struct Launch {
    directory: tempfile::TempDir,
    accepts_steer: bool,
    pub(crate) argv: Vec<String>,
}

pub(crate) enum SteerError {
    Refused(String),
    Unknown(String),
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
    static CACHE: OnceLock<VersionCache> = OnceLock::new();
    let version = CACHE
        .get_or_init(VersionCache::default)
        .version(&command, || {
            let text = crate::agent_models::run_list_with_timeout(
                &command,
                &["--version"],
                Duration::from_secs(2),
            )?;
            cli_version(&text)
        });
    version.is_some_and(|version| version >= floor)
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
    pub(crate) fn ready(&self) -> bool {
        self.directory.path().join("ready.json").is_file()
    }

    pub(crate) fn ready_for_steer(&self) -> bool {
        self.accepts_steer && self.ready()
    }

    /// Additional input goes to the existing CLI, never through interrupt or
    /// turn/start. A missing acknowledgement must never trigger a resend.
    pub(crate) fn steer(
        &self,
        pty: &str,
        text: &str,
        images: &[PathBuf],
    ) -> Result<(), SteerError> {
        if !self.ready_for_steer() {
            return Err(SteerError::Refused(
                "This agent is still starting. Try steering after its first step.".into(),
            ));
        }
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).map_err(|error| SteerError::Refused(error.to_string()))?;
        random[6] = (random[6] & 0x0f) | 0x40;
        random[8] = (random[8] & 0x3f) | 0x80;
        let id = random
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let request = self.directory.path().join(format!("request-{id}.json"));
        let response = self.directory.path().join(format!("response-{id}.json"));
        write_json(
            &request,
            &json!({"id":id,"steer":text,"images":images,"expires":now_ms()+10_000}),
        )
        .map_err(SteerError::Unknown)?;
        let until = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(bytes) = read_control_file(&response) {
                let _ = fs::remove_file(&response);
                let result: Value = serde_json::from_slice(&bytes)
                    .map_err(|error| SteerError::Unknown(error.to_string()))?;
                return if result["ok"] == true {
                    Ok(())
                } else if result["unknown"] == true {
                    Err(SteerError::Unknown("Steering delivery could not be confirmed. Check the conversation before sending these words again.".into()))
                } else {
                    Err(SteerError::Refused(
                        result["error"]
                            .as_str()
                            .unwrap_or("The agent refused this steering message.")
                            .into(),
                    ))
                };
            }
            if Instant::now() >= until
                || !tokenstat_pty::manager()
                    .info(pty)
                    .is_ok_and(|info| info.alive)
            {
                return Err(SteerError::Unknown("Steering delivery could not be confirmed. Check the conversation before sending these words again.".into()));
            }
            std::thread::sleep(Duration::from_millis(40));
        }
    }

    #[cfg(test)]
    pub(crate) fn test_mailbox(directory: tempfile::TempDir) -> Self {
        Self {
            directory,
            accepts_steer: true,
            argv: Vec::new(),
        }
    }

    pub(crate) fn prepare(
        backend: &str,
        argv: &[String],
        parent: &Path,
        compact: bool,
    ) -> Result<Option<Self>, String> {
        if argv.is_empty() {
            return Err("missing agent command".into());
        }
        let opencode = opencode::supported(backend, argv);
        if !supported(backend) && !opencode {
            return Ok(None);
        }
        if opencode && compact {
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
                compact,
            },
        )?;
        let helper = std::env::current_exe().map_err(|error| error.to_string())?;
        Ok(Some(Self {
            directory,
            accepts_steer: !compact,
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
            if let Ok(bytes) = read_control_file(&response) {
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
                let _ = self.stop(pty);
                return Err("The agent did not acknowledge its speed setting. The turn was stopped; try again.".into());
            }
            std::thread::sleep(Duration::from_millis(40));
        }
    }

    pub(crate) fn stop(&self, pty: &str) -> Result<(), tokenstat_pty::PtyError> {
        // PTY kill allows only a short signal grace period. Give the helper
        // its own cancellation request first, so Codex can persist aborted
        // tool outputs and flush its rollout before the process is retired.
        if fs::File::create(self.directory.path().join("stop")).is_ok() {
            let until = Instant::now() + STOP_TIMEOUT;
            loop {
                if !tokenstat_pty::manager().info(pty)?.alive {
                    return Ok(());
                }
                if Instant::now() >= until {
                    break;
                }
                std::thread::sleep(Duration::from_millis(40));
            }
        }
        tokenstat_pty::manager().kill(pty)
    }
}

struct Protocol {
    backend: String,
    thread: String,
    turn: String,
    pending: HashMap<String, Pending>,
    usage: Value,
    deferred_result: Option<Value>,
    finished: bool,
}

struct Pending {
    path: PathBuf,
    steer: bool,
    // The positive mailbox response has been posted.
    accepted: bool,
    // All input bytes and the flush completed, even if the echo is pending.
    written: bool,
}

/// App-server totals are cumulative across resumed turns. Emit only the
/// increments observed during this launch, never the restored thread total.
#[derive(Default)]
struct CodexUsage {
    previous: Option<Value>,
    totals: [u64; 5],
    invalid: bool,
}
impl CodexUsage {
    fn observe(&mut self, usage: &Value, active: bool) -> Option<Value> {
        let total = usage.get("total")?;
        const FIELDS: [&str; 5] = [
            "inputTokens",
            "cachedInputTokens",
            "cacheWriteInputTokens",
            "outputTokens",
            "reasoningOutputTokens",
        ];
        if active && !self.invalid {
            let monotonic = self.previous.as_ref().is_some_and(|old| {
                FIELDS
                    .iter()
                    .all(|key| total[*key].as_u64().unwrap_or(0) >= old[*key].as_u64().unwrap_or(0))
            });
            for (index, key) in FIELDS.iter().enumerate() {
                let delta = if monotonic {
                    total[*key].as_u64().unwrap_or(0)
                        - self.previous.as_ref().unwrap()[*key].as_u64().unwrap_or(0)
                } else {
                    usage["last"][*key].as_u64().unwrap_or(0)
                };
                if let Some(next) = self.totals[index].checked_add(delta) {
                    self.totals[index] = next;
                } else {
                    self.invalid = true;
                }
            }
        }
        self.previous = Some(total.clone());
        (!self.invalid && active).then(|| json!({"input_tokens":self.totals[0], "cached_input_tokens":self.totals[1], "cache_write_input_tokens":self.totals[2], "output_tokens":self.totals[3], "reasoning_output_tokens":self.totals[4]}))
    }
}

fn emit(output: &mut emitter::Emitter, value: &Value) -> Result<(), String> {
    output.emit(value)
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
    let compact = input.len() == 1 && input[0]["type"] == "text" && input[0]["text"] == "/compact";
    let mut turn = json!({"input":input});
    if compact {
        turn["tokenstatCompact"] = json!(true);
    }
    if let Some(effort) = effort {
        turn["effort"] = json!(effort);
    }
    Ok((args, setup, turn))
}

fn claude_launch(argv: &[String]) -> Result<(Vec<String>, String), String> {
    let mut args = argv.get(1..).ok_or("missing Claude command")?.to_vec();
    let at = args
        .iter()
        .position(|arg| arg == "-p")
        .ok_or("missing Claude print flag")?;
    let prompt = args.get(at + 1).ok_or("missing Claude prompt")?.clone();
    args.remove(at + 1);
    args.extend([
        "--input-format".into(),
        "stream-json".into(),
        "--replay-user-messages".into(),
    ]);
    Ok((args, prompt))
}

fn read_control_file(path: &Path) -> Result<Vec<u8>, String> {
    const CAP: u64 = 16 * 1024 * 1024;
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW);
    }
    let file = options.open(path).map_err(|error| error.to_string())?;
    if !file
        .metadata()
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err("live control message is not a regular file".into());
    }
    let mut bytes = Vec::new();
    file.take(CAP + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() as u64 > CAP {
        return Err("live control message is too large".into());
    }
    Ok(bytes)
}

fn codex_mcp_inventory(servers: &[Value]) -> Value {
    let inventory_partial = servers.len() > 100
        || servers.iter().take(100).any(|server| {
            server["tools"]
                .as_object()
                .is_some_and(|tools| tools.len() > 256)
        });
    let servers: Vec<_> = servers
        .iter()
        .take(100)
        .map(|server| {
            let tools: Option<Vec<_>> = server["tools"]
                .as_object()
                .map(|tools| tools.keys().take(256).cloned().collect());
            let status = server["runtimeStatus"].as_str().or_else(|| {
                (server["authStatus"] == "notLoggedIn").then_some("authenticationRequired")
            });
            json!({"name":server["name"], "runtimeStatus":status, "tools":tools})
        })
        .collect();
    json!({"type":"tokenstat.mcp", "servers":servers, "inventoryPartial":inventory_partial})
}

fn read_message(reader: &mut impl BufRead, cap: u64) -> Result<Option<(Value, usize)>, String> {
    let mut line = String::new();
    let length = reader
        .take(cap + 1)
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    if length == 0 {
        return Ok(None);
    }
    if length as u64 > cap {
        return Err("agent protocol message is too large".into());
    }
    serde_json::from_str(&line)
        .map(|value| Some((value, length)))
        .map_err(|error| error.to_string())
}

fn read_messages(child: &mut Child) -> Result<output::Messages, String> {
    let output = child.stdout.take().ok_or("missing agent output")?;
    Ok(read_messages_from(output))
}

fn kill_agent(child: &mut Child) {
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

fn agent_exited(child: &mut Child) -> std::io::Result<bool> {
    #[cfg(unix)]
    {
        // Keep the PID reserved until output and descendant cleanup finish.
        // waitid(WNOWAIT) observes exit without reaping the provider.
        // SAFETY: siginfo_t is a C POD; zeroing also handles WNOHANG with no event.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: the child PID and writable siginfo_t belong to this caller.
        // WNOWAIT leaves an exited child available for the final Child::wait.
        let status = unsafe {
            libc::waitid(
                libc::P_PID,
                child.id() as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if status != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: waitid supplies SIGCHLD fields, or leaves our zeroed PID.
        Ok(unsafe { info.si_pid() } != 0)
    }
    #[cfg(not(unix))]
    {
        // Child retains the Windows process handle and therefore its identity.
        child.try_wait().map(|status| status.is_some())
    }
}

fn read_messages_from(output: impl Read + Send + 'static) -> output::Messages {
    let (tx, rx) = output::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(output);
        loop {
            let (value, bytes) = match read_message(&mut reader, 16 * 1024 * 1024) {
                Ok(Some((value, bytes))) => (Ok(value), bytes),
                Ok(None) => break,
                Err(error) => {
                    let _ = tx.send(Err(error), 0);
                    break;
                }
            };
            if !tx.send(value, bytes) {
                break;
            }
        }
    });
    rx
}

/// Provider diagnostics are not assistant text. Keep a bounded tail for a
/// failed turn rather than mixing stderr (including echoed tool scripts)
/// into the structured transcript through the wrapper's PTY.
fn read_diagnostics(child: &mut Child) -> (Arc<Mutex<Vec<u8>>>, mpsc::Receiver<()>) {
    let tail = Arc::new(Mutex::new(Vec::new()));
    let output = Arc::clone(&tail);
    let stderr = child.stderr.take();
    let (done, finished) = mpsc::channel();
    std::thread::spawn(move || {
        const CAP: usize = 8192;
        if let Some(mut stderr) = stderr {
            let mut bytes = [0u8; CAP];
            loop {
                match stderr.read(&mut bytes) {
                    Ok(0) => break,
                    Ok(count) => {
                        let mut tail = output.lock().unwrap_or_else(PoisonError::into_inner);
                        let drop = (tail.len() + count).saturating_sub(CAP);
                        tail.drain(..drop);
                        tail.extend_from_slice(&bytes[..count]);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
        }
        let _ = done.send(());
    });
    (tail, finished)
}

impl Protocol {
    fn interrupt(
        &self,
        input: &mut input::Input,
        messages: &output::Messages,
        output: &mut emitter::Emitter,
    ) {
        if self.backend != "codex"
            || self.thread.is_empty()
            || self.turn.is_empty()
            || self.finished
        {
            return;
        }
        if input.send(
            &json!({"id":"interrupt","method":"turn/interrupt","params":{"threadId":self.thread,"turnId":self.turn}}),
        )
        .is_err()
        {
            return;
        }
        let until = Instant::now() + INTERRUPT_TIMEOUT;
        while Instant::now() < until {
            match messages.recv_timeout(Duration::from_millis(40)) {
                Ok(Ok(message))
                    if message["method"] == "turn/completed"
                        && message["params"]["threadId"] == self.thread
                        && message["params"]["turn"]["id"] == self.turn =>
                {
                    // Closing stdin next performs the server's thread shutdown
                    // and flush. Unsubscribe alone only removes a subscriber.
                    return;
                }
                Ok(Ok(message))
                    if matches!(
                        message["method"].as_str(),
                        Some("item/started" | "item/completed")
                    ) =>
                {
                    if let Some(item) = codex_owned_item(&message, &self.thread, &self.turn) {
                        let _ = emit(output, &item);
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
                _ => {}
            }
        }
    }

    fn controls(&mut self, directory: &Path, input: &mut input::Input) -> Result<(), String> {
        if !input.ready_for_control() {
            return Ok(());
        }
        let mut attempts = 0;
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
            if attempts == 8 || stop_requested(directory) || !input.ready_for_control() {
                break;
            }
            attempts += 1;
            let request: Value = serde_json::from_slice(&read_control_file(&entry.path())?)
                .map_err(|error| error.to_string())?;
            let response = directory.join(format!("response-{id}.json"));
            if request["id"] != id
                || request["expires"]
                    .as_u64()
                    .is_none_or(|expires| expires <= now_ms())
            {
                write_json(
                    &response,
                    &json!({"ok":false,"error":"The agent input request expired. Try again."}),
                )?;
            } else {
                let steer = request["steer"].as_str();
                let message = if let Some(text) = steer {
                    let uuid = format!(
                        "{}-{}-{}-{}-{}",
                        &id[..8],
                        &id[8..12],
                        &id[12..16],
                        &id[16..20],
                        &id[20..]
                    );
                    if self.backend == "claude" {
                        json!({"type":"user","uuid":uuid,"session_id":"","message":{"role":"user","content":[{"type":"text","text":text}]},"parent_tool_use_id":null})
                    } else {
                        let mut input = vec![json!({"type":"text","text":text})];
                        if let Some(images) = request["images"].as_array() {
                            for path in images {
                                let path = path.as_str().ok_or("invalid steering image path")?;
                                input.push(json!({"type":"localImage","path":path}));
                            }
                        }
                        json!({"id":id,"method":"turn/steer","params":{"threadId":self.thread,"expectedTurnId":self.turn,"clientUserMessageId":uuid,"input":input}})
                    }
                } else {
                    let fast = request["fast"].as_bool().ok_or("invalid speed request")?;
                    if self.backend == "claude" {
                        json!({"type":"control_request","request_id":id,"request":{"subtype":"apply_flag_settings","settings":{"fastMode":fast}}})
                    } else {
                        json!({"id":id,"method":"turn/settings/update","params":{"threadId":self.thread,"turnId":self.turn,"serviceTier":if fast {"priority"} else {"default"}}})
                    }
                };
                let queued = input.control(
                    &message,
                    id.into(),
                    request["expires"].as_u64().unwrap_or(0),
                );
                if matches!(queued, Ok(false)) {
                    break;
                }
                if let Err(error) = queued {
                    if steer.is_some() {
                        let _ = write_json(
                            &response,
                            &json!({"ok":false,"unknown":true,"error":error}),
                        );
                        let _ = fs::remove_file(entry.path());
                        continue;
                    }
                    return Err(error);
                }
                self.pending.insert(
                    id.into(),
                    Pending {
                        path: response,
                        steer: steer.is_some(),
                        accepted: false,
                        written: false,
                    },
                );
            }
            fs::remove_file(entry.path()).map_err(|error| error.to_string())?;
        }
        Ok(())
    }

    fn written(&mut self, input: &mut input::Input) -> Result<(), String> {
        while let Some(completed) = input.take_completed() {
            let pending = completed
                .control
                .as_deref()
                .and_then(|id| self.pending.get_mut(id));
            match completed.result {
                Ok(()) => {
                    if let Some(pending) = pending {
                        pending.written = true;
                        if !pending.steer || self.backend != "claude" {
                            continue;
                        }
                        self.deferred_result = None;
                        // Claude may echo input only after a long tool call.
                        // Accept after the full write, then retain the echo
                        // fence so an earlier result cannot close this turn.
                        if !pending.accepted {
                            pending.accepted =
                                write_json(&pending.path, &json!({"ok":true})).is_ok();
                        }
                    }
                }
                Err(input::Failure::Expired) => {
                    if let Some(id) = completed.control
                        && let Some(pending) = self.pending.remove(&id)
                    {
                        let _ = write_json(
                            &pending.path,
                            &json!({"ok":false,"error":"The agent input request expired. Try again."}),
                        );
                    }
                }
                Err(input::Failure::Write(error)) => {
                    if completed.control.is_some() {
                        match pending.map(|pending| pending.steer) {
                            Some(true) => {
                                self.retire_unwritten(&error);
                                continue;
                            }
                            None => continue,
                            Some(false) => {}
                        }
                    }
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    fn retire_unwritten(&mut self, error: &str) {
        let ids: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, pending)| pending.steer && !pending.written)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            if let Some(pending) = self.pending.remove(&id) {
                let _ = write_json(
                    &pending.path,
                    &json!({"ok":false,"unknown":true,"error":error}),
                );
            }
        }
    }

    fn acknowledge(&mut self, value: &Value) -> Result<bool, String> {
        let replay = self.backend == "claude" && value["type"] == "user";
        if self.backend == "claude" && !replay && value["type"] != "control_response" {
            return Ok(false);
        }
        if self.backend == "codex"
            && (value["method"].is_string()
                || (value.get("result").is_none() && value.get("error").is_none()))
        {
            return Ok(false);
        }
        let response = if self.backend == "claude" && !replay {
            &value["response"]
        } else {
            value
        };
        let id = if replay {
            value["uuid"].as_str()
        } else if self.backend == "claude" {
            response["request_id"].as_str()
        } else {
            response["id"].as_str()
        };
        let Some(id) = id else {
            return Ok(false);
        };
        let id = if replay {
            id.replace('-', "")
        } else {
            id.to_string()
        };
        if self.backend == "claude"
            && self
                .pending
                .get(&id)
                .is_some_and(|pending| pending.steer != replay)
        {
            return Ok(false);
        }
        let Some(pending) = self.pending.remove(&id) else {
            return Ok(false);
        };
        let Pending {
            path,
            steer,
            accepted,
            ..
        } = pending;
        let ok = if replay {
            steer
        } else if self.backend == "claude" {
            response["subtype"] == "success"
        } else if steer {
            response["result"]["turnId"] == self.turn && response["error"].is_null()
        } else {
            response["result"]["status"] == "applied"
        };
        let error = response["error"]
            .as_str()
            .or_else(|| response["error"]["message"].as_str())
            .unwrap_or(if steer {
                "The active turn refused this steering message."
            } else {
                "The active turn could not apply this speed setting."
            });
        if self.backend == "claude" && steer {
            self.deferred_result = None;
            if !accepted {
                let _ = write_json(&path, &json!({"ok":true}));
            }
            return Ok(true);
        }
        if steer {
            let _ = write_json(&path, &json!({"ok":ok,"error":error}));
        } else {
            write_json(&path, &json!({"ok":ok,"error":error}))?;
        }
        Ok(true)
    }
}

/// Entry point called only by the bundled host helper's `chat-live` command.
pub fn run(path: &Path) -> Result<(), String> {
    let config: Config =
        serde_json::from_slice(&read_control_file(path)?).map_err(|error| error.to_string())?;
    if config.argv.is_empty() {
        return Err("missing agent command".into());
    }
    let directory = path.parent().ok_or("missing live control directory")?;
    install_stop_signals();
    if matches!(config.backend.as_str(), "opencode" | "opencode2") {
        return opencode::run(&config.argv, directory);
    }
    let (args, mut setup, mut initial) = match config.backend.as_str() {
        "codex" => codex_launch(&config.argv)?,
        "claude" => {
            let (args, prompt) = claude_launch(&config.argv)?;
            (args, Value::Null, json!(prompt))
        }
        _ => return Err("unsupported live agent".into()),
    };
    // A launch's standing rules and plan-mode instructions can wrap its
    // prompt. Maintenance is an explicit operation, so it must not depend on
    // recognizing the decorated prompt or start an ordinary model turn.
    if config.compact {
        if config.backend == "codex" {
            initial["tokenstatCompact"] = json!(true);
        } else {
            initial = json!("/compact");
        }
    }
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
        // The CLI's own group contains only this turn's children.
        // Stop retires that group before the wrapper.
        command.process_group(0);
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    let (diagnostics, diagnostics_finished) = read_diagnostics(&mut child);
    let prepared = (|| {
        let rx = read_messages(&mut child)?;
        let input = input::start(child.stdin.take().ok_or("missing agent input")?);
        Ok::<_, String>((rx, input))
    })();
    let (rx, mut input) = match prepared {
        Ok(prepared) => prepared,
        Err(error) => {
            kill_agent(&mut child);
            let _ = child.wait();
            return Err(error);
        }
    };
    let mut output = emitter::Emitter::new(|| std::io::stdout().lock(), directory);
    let mut stop = mailbox::Stop::new(directory);
    let mut controls = mailbox::Poll::new();
    let mut protocol = Protocol {
        backend: config.backend.clone(),
        thread: String::new(),
        turn: String::new(),
        pending: HashMap::new(),
        usage: Value::Null,
        deferred_result: None,
        finished: false,
    };
    let result = (|| {
        let initialize = if config.backend == "codex" {
            json!({"id":"initialize","method":"initialize","params":{"clientInfo":{"name":"tokenstat","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}})
        } else {
            json!({"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}})
        };
        input.send(&initialize)?;
        let startup_deadline = Instant::now() + Duration::from_secs(30);
        let mut initialized = false;
        let mut mcp_pages = 0;
        let mut goal_notified = false;
        let mut codex_usage = CodexUsage::default();
        let mut started = false;
        loop {
            if stop.requested() {
                return Err("The turn was stopped.".into());
            }
            protocol.written(&mut input)?;
            if !started && Instant::now() >= startup_deadline {
                return Err("The agent did not initialize its live protocol.".into());
            }
            let deferred = if protocol.pending.values().any(|pending| pending.steer) {
                None
            } else {
                protocol.deferred_result.take()
            };
            let timeout = Duration::from_millis(if input.busy() { 5 } else { 40 });
            let received = if let Some(message) = deferred {
                Ok(Ok(message))
            } else {
                rx.recv_timeout(timeout)
            };
            let message = match received {
                Ok(value) => value?,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if started && input.ready_for_control() && controls.due() {
                        protocol.controls(directory, &mut input)?;
                    }
                    continue;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    protocol.written(&mut input)?;
                    if protocol.deferred_result.is_some() {
                        input.cancel();
                        protocol.retire_unwritten(
                            "The agent closed its protocol before confirming steering delivery.",
                        );
                    }
                    if !protocol.pending.values().any(|pending| pending.steer)
                        && let Some(message) = protocol.deferred_result.take()
                    {
                        message
                    } else {
                        return Err(
                            "The agent closed its protocol before completing the turn.".into()
                        );
                    }
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
                    input.send(&json!({"type":"user","session_id":"","message":{"role":"user","content":[{"type":"text","text":initial.as_str().ok_or("invalid Claude prompt")?}]},"parent_tool_use_id":null}),
                    )?;
                    initialized = true;
                } else if message["type"] == "result" {
                    // A resumed session can finish an old background task
                    // before consuming the new prompt. Its result does not
                    // complete or fail the person's active request. A steer
                    // that is still waiting for its echo is the same case:
                    // emitting this result closes the turn, and an error
                    // result exits before the CLI has taken the new words.
                    if message["origin"]["kind"] == "task-notification" {
                        continue;
                    }
                    if protocol.pending.values().any(|pending| pending.steer) {
                        if !protocol
                            .pending
                            .values()
                            .any(|pending| pending.steer && pending.written)
                            && protocol.deferred_result.is_none()
                        {
                            // Restore this result if the write is refused or fails.
                            protocol.deferred_result = Some(message);
                        }
                        continue;
                    }
                    protocol.finished = true;
                    emit(&mut output, &message)?;
                    if message["is_error"] == true {
                        return Err("Claude reported a failed turn.".into());
                    }
                    if initial == "/compact" {
                        emit(
                            &mut output,
                            &json!({"type":"assistant","message":{"content":[{"type":"text","text":"Context compaction completed."}]}}),
                        )?;
                    }
                    return Ok(());
                } else {
                    emit(&mut output, &message)?;
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
                input.send(&json!({"method":"initialized"}))?;
                input.send(&json!({"id":"thread","method":if setup["threadId"].is_string() {"thread/resume"} else {"thread/start"},"params":setup}),
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
                emit(
                    &mut output,
                    &json!({"type":"thread.started","thread_id":protocol.thread}),
                )?;
                emit(
                    &mut output,
                    &json!({"type":"tokenstat.context","model":message["result"]["model"]}),
                )?;
                let mut params = initial.clone();
                let compact = params["tokenstatCompact"] == true;
                params.as_object_mut().unwrap().remove("tokenstatCompact");
                params["threadId"] = json!(protocol.thread);
                input.send(&json!({"id":if compact {"compact"} else {"turn"},
                        "method":if compact {"thread/compact/start"} else {"turn/start"},
                        "params":if compact {json!({"threadId":protocol.thread})} else {params}}))?;
                // Reuse this thread's connections. Inventory must never
                // delay turn/start or start an unrelated agent session.
                let _ = input.send(
                    &json!({"id":"inspection-mcp","method":"mcpServerStatus/list",
                    "params":{"threadId":protocol.thread,"limit":100}}),
                );
                // Read the existing session goal; this never creates or
                // resumes a goal and must not delay the user's turn.
                let _ = input.send(&json!({"id":"inspection-goal","method":"thread/goal/get",
                    "params":{"threadId":protocol.thread}}));
            } else if message["id"] == "compact" {
                if let Some(error) = message.get("error") {
                    return Err(error["message"]
                        .as_str()
                        .unwrap_or("Native compaction is unavailable in this Codex version.")
                        .into());
                }
            } else if message["id"] == "inspection-mcp" {
                if let Some(servers) = message["result"]["data"].as_array() {
                    emit(&mut output, &codex_mcp_inventory(servers))?;
                    mcp_pages += 1;
                    if mcp_pages >= 3 && message["result"]["nextCursor"].is_string() {
                        emit(
                            &mut output,
                            &json!({"type":"tokenstat.mcp", "servers":[], "inventoryPartial":true}),
                        )?;
                    }
                    if mcp_pages < 3 && message["result"]["nextCursor"].is_string() {
                        let _ = input.send(&json!({"id":"inspection-mcp","method":"mcpServerStatus/list",
                            "params":{"threadId":protocol.thread,"limit":100,"cursor":message["result"]["nextCursor"]}}),
                        );
                    }
                }
            } else if message["id"] == "inspection-goal" {
                if let Some(activity) = codex_goal_reply(&message, &protocol.thread, goal_notified)
                {
                    emit(&mut output, &activity)?;
                }
            } else if let Some(activity) =
                crate::chat_activity::codex_notification(&message, &protocol.thread, &protocol.turn)
            {
                goal_notified |= activity["kind"] == "goal";
                emit(&mut output, &activity)?;
            } else if message["method"] == "mcpServer/startupStatus/updated" {
                let params = &message["params"];
                if params["threadId"].is_null() || params["threadId"] == protocol.thread {
                    let status = match params["status"].as_str() {
                        Some("ready") => "connected",
                        Some("failed") if params["failureReason"] == "reauthenticationRequired" => {
                            "authenticationRequired"
                        }
                        Some("failed") => "failed",
                        Some("cancelled") => "cancelled",
                        _ => "starting",
                    };
                    emit(
                        &mut output,
                        &json!({"type":"tokenstat.mcp", "servers":[{"name":params["name"], "runtimeStatus":status}]}),
                    )?;
                }
            } else if initial["tokenstatCompact"] == true
                && message["method"] == "item/started"
                && message["params"]["threadId"].as_str() == Some(protocol.thread.as_str())
                && message["params"]["item"]["type"] == "contextCompaction"
            {
                // thread/compact/start returns before any turn exists. The
                // compaction run is the turn that owns this item, not the
                // first turn/started on a resumed thread (often a goal).
                if let Some(id) = message["params"]["turnId"].as_str() {
                    protocol.turn = id.to_string();
                }
                if !started {
                    write_json(&directory.join("ready.json"), &json!(true))?;
                    started = true;
                }
            } else if message["id"] == "turn" || message["method"] == "turn/started" {
                if message["method"] == "turn/started"
                    && (message["params"]["threadId"].as_str() != Some(protocol.thread.as_str())
                        || (!protocol.turn.is_empty()
                            && message["params"]["turn"]["id"].as_str()
                                != Some(protocol.turn.as_str())))
                {
                    continue;
                }
                if message["method"] == "turn/started"
                    && initial["tokenstatCompact"] == true
                    && protocol.turn.is_empty()
                {
                    if !started {
                        write_json(&directory.join("ready.json"), &json!(true))?;
                        started = true;
                    }
                    continue;
                }
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
                if message["params"]["threadId"].as_str() != Some(protocol.thread.as_str())
                    || turn["id"].as_str() != Some(protocol.turn.as_str())
                {
                    continue;
                }
                protocol.finished = true;
                let completed = turn["status"] == "completed";
                if !completed {
                    emit(
                        &mut output,
                        &json!({"type":"error","message":turn["error"]["message"].as_str().unwrap_or("Codex turn failed or was interrupted")}),
                    )?;
                }
                if completed && initial["tokenstatCompact"] == true {
                    emit(
                        &mut output,
                        &json!({"type":"item.completed","item":{"id":"tokenstat-compact-result","type":"agent_message","text":"Context compaction completed."}}),
                    )?;
                }
                if completed {
                    emit(
                        &mut output,
                        &json!({"type":"turn.completed","usage":protocol.usage}),
                    )?;
                }
                // Match exec's subscription cleanup. Closing protocol stdin
                // afterward shuts down the thread and flushes its rollout.
                input.send(&json!({"id":"shutdown","method":"thread/unsubscribe","params":{"threadId":protocol.thread}}),
                )?;
                let until = Instant::now() + Duration::from_secs(3);
                while Instant::now() < until {
                    if stop.requested() {
                        return Err("The turn was stopped.".into());
                    }
                    match rx.recv_timeout(Duration::from_millis(40)) {
                        Ok(Ok(reply)) if reply["id"] == "shutdown" => break,
                        Ok(Ok(reply)) => {
                            // Goal accounting can settle after turn/completed.
                            // Preserve owned activity while the existing,
                            // bounded subscription shutdown flushes history.
                            if let Some(activity) = crate::chat_activity::codex_notification(
                                &reply,
                                &protocol.thread,
                                &protocol.turn,
                            ) {
                                goal_notified |= activity["kind"] == "goal";
                                emit(&mut output, &activity)?;
                            } else if let Some(activity) =
                                codex_goal_reply(&reply, &protocol.thread, goal_notified)
                            {
                                emit(&mut output, &activity)?;
                            } else if let Some(item) =
                                codex_owned_item(&reply, &protocol.thread, &protocol.turn)
                            {
                                emit(&mut output, &item)?;
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        _ => {}
                    }
                }
                return if completed {
                    Ok(())
                } else {
                    Err("Codex did not complete the turn.".into())
                };
            } else if message["method"] == "thread/tokenUsage/updated" {
                let params = &message["params"];
                if params["threadId"].as_str() != Some(protocol.thread.as_str())
                    || (!protocol.turn.is_empty()
                        && params["turnId"].as_str() != Some(protocol.turn.as_str()))
                {
                    continue;
                }
                let usage = &params["tokenUsage"];
                emit(
                    &mut output,
                    &json!({"type":"tokenstat.context", "contextUsed":usage["last"]["inputTokens"],
                    "contextWindow":usage["modelContextWindow"],
                    "contextBreakdown":{
                        "input":usage["last"]["inputTokens"].as_u64().and_then(|input| input.checked_sub(usage["last"]["cachedInputTokens"].as_u64().unwrap_or(0))).and_then(|input| input.checked_sub(usage["last"]["cacheWriteInputTokens"].as_u64().unwrap_or(0))),
                        "cacheRead":usage["last"]["cachedInputTokens"].as_u64().unwrap_or(0),
                        "cacheWrite":usage["last"]["cacheWriteInputTokens"].as_u64().unwrap_or(0)
                    }}),
                )?;
                let turn = message["params"]["turnId"].as_str();
                if protocol.turn.is_empty() || turn.is_none_or(|turn| turn == protocol.turn) {
                    protocol.usage = codex_usage
                        .observe(usage, !protocol.turn.is_empty())
                        .unwrap_or(Value::Null);
                }
            } else if let Some(item) = codex_owned_item(&message, &protocol.thread, &protocol.turn)
            {
                emit(&mut output, &item)?;
            } else if message.get("id").is_some() && message["method"].is_string() {
                // Match exec's noninteractive contract. Never silently grant a
                // provider permission request or leave it parked indefinitely.
                input.send(&json!({"id":message["id"],"error":{"code":-32601,"message":"This headless turn uses tokenstat tool hooks; interactive requests are unavailable."}}),
                )?;
            }
            if started && input.ready_for_control() && controls.due() {
                protocol.controls(directory, &mut input)?;
            }
        }
    })();
    if stop_requested(directory) {
        protocol.interrupt(&mut input, &rx, &mut output);
    }
    drop(input);
    drop(rx);
    // Closing protocol stdin starts the app-server's thread shutdown. Even a
    // stopped/failed turn needs this bounded grace period to flush its history.
    // On a protocol failure the server also cancels any still-running work.
    let mut exited = false;
    let mut owned = true;
    if result.is_ok() || config.backend == "codex" {
        let until = Instant::now() + EXIT_TIMEOUT;
        while Instant::now() < until {
            match agent_exited(&mut child) {
                Ok(true) => {
                    exited = true;
                    break;
                }
                Ok(false) => {}
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => {
                    // Only ECHILD means the PID may already have been reaped.
                    // Other observation failures must still retire a live child
                    // before the final, potentially blocking wait.
                    owned = {
                        #[cfg(unix)]
                        {
                            error.raw_os_error() != Some(libc::ECHILD)
                        }
                        #[cfg(not(unix))]
                        {
                            let _ = error;
                            true
                        }
                    };
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    let retired = owned && (!exited || result.is_err());
    if retired {
        kill_agent(&mut child);
    }
    let flushed = output.finish();
    if flushed.is_err() && owned && !retired {
        kill_agent(&mut child);
    }
    let result = result.and(flushed);
    let _ = child.wait();
    result.map_err(|error| {
        let _ = diagnostics_finished.recv_timeout(Duration::from_millis(100));
        let tail = diagnostics.lock().unwrap_or_else(PoisonError::into_inner);
        let detail = String::from_utf8_lossy(&tail);
        let detail = detail.trim();
        if detail.is_empty() {
            error
        } else {
            format!("{error}\n{detail}")
        }
    })
}

fn install_stop_signals() {
    #[cfg(unix)]
    // SAFETY: the handler only stores an atomic flag and performs no I/O.
    unsafe {
        libc::signal(libc::SIGHUP, stopped as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stopped as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, stopped as *const () as libc::sighandler_t);
    }
}

fn codex_goal_reply(message: &Value, thread: &str, goal_notified: bool) -> Option<Value> {
    let result = &message["result"];
    (message["id"] == "inspection-goal"
        && !goal_notified
        && message["error"].is_null()
        && result.get("goal").is_some()
        && (result["goal"].is_null() || result["goal"]["threadId"].as_str() == Some(thread)))
    .then(|| json!({"type":"tokenstat.activity","kind":"goal","goal":result["goal"]}))
}

fn codex_owned_item(message: &Value, thread: &str, turn: &str) -> Option<Value> {
    let method = message["method"].as_str()?;
    if !matches!(
        method,
        "item/started" | "item/completed" | "item/agentMessage/delta"
    ) || turn.is_empty()
        || message["params"]["threadId"].as_str() != Some(thread)
        || (!turn.is_empty() && message["params"]["turnId"].as_str() != Some(turn))
    {
        return None;
    }
    if method == "item/agentMessage/delta" {
        let params = &message["params"];
        return Some(json!({"type":"item.delta","item":{
            "type":"agent_message", "id":params["itemId"].as_str()?,
            "text":params["delta"].as_str()?
        }}));
    }
    let item = codex_item(&message["params"]["item"])?;
    Some(
        json!({"type":if method == "item/started" {"item.started"} else {"item.completed"},"item":item}),
    )
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
        "imageView" => "image_view",
        "imageGeneration" => "image_generation",
        "dynamicToolCall" => "dynamic_tool_call",
        "collabAgentToolCall" => "collab_agent_tool_call",
        "collabToolCall" => "collab_tool_call",
        "subAgentActivity" => "sub_agent_activity",
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

    fn protocol(backend: &str) -> Protocol {
        Protocol {
            backend: backend.into(),
            thread: "thread".into(),
            turn: "turn".into(),
            pending: HashMap::new(),
            usage: Value::Null,
            deferred_result: None,
            finished: false,
        }
    }

    #[cfg(unix)]
    #[test]
    fn observing_provider_exit_keeps_it_waitable_until_cleanup() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "read value; exit 0"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        assert!(!agent_exited(&mut child).unwrap());
        drop(child.stdin.take());
        let until = Instant::now() + Duration::from_secs(2);
        while !agent_exited(&mut child).unwrap() {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(
            agent_exited(&mut child).unwrap(),
            "Observing exit must not release PID ownership"
        );
        assert!(child.wait().unwrap().success());
    }

    #[test]
    fn steering_acceptance_waits_for_write_or_echo_and_failed_writes_stay_unknown() {
        struct HeldFlush {
            entered: mpsc::Sender<()>,
            release: mpsc::Receiver<()>,
            fail: bool,
        }
        impl Write for HeldFlush {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                self.entered.send(()).unwrap();
                self.release.recv().unwrap();
                if self.fail {
                    Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe))
                } else {
                    Ok(())
                }
            }
        }
        for mode in ["written", "echo", "failure", "echo-failure"] {
            let root = tempfile::tempdir().unwrap();
            let id = "00000000000040008000000000000001";
            fs::write(
                root.path().join(format!("request-{id}.json")),
                json!({"id":id,"steer":"extra context","expires":u64::MAX}).to_string(),
            )
            .unwrap();
            let response = root.path().join(format!("response-{id}.json"));
            let (entered, was_entered) = mpsc::channel();
            let (release, released) = mpsc::channel();
            let mut input = input::start(HeldFlush {
                entered,
                release: released,
                fail: mode.ends_with("failure"),
            });
            let mut protocol = protocol("claude");
            protocol.controls(root.path(), &mut input).unwrap();
            was_entered.recv_timeout(Duration::from_secs(2)).unwrap();
            protocol.written(&mut input).unwrap();
            assert!(
                !response.exists(),
                "Enqueueing input must not acknowledge delivery"
            );
            let echo = json!({"type":"user","uuid":"00000000-0000-4000-8000-000000000001"});
            if mode.starts_with("echo") {
                assert!(protocol.acknowledge(&echo).unwrap());
                assert_eq!(
                    serde_json::from_slice::<Value>(&fs::read(&response).unwrap()).unwrap()["ok"],
                    true
                );
                fs::remove_file(&response).unwrap();
            }
            protocol.deferred_result = Some(json!({"type":"result","is_error":false}));
            release.send(()).unwrap();
            let until = Instant::now() + Duration::from_secs(2);
            while input.busy() {
                protocol.written(&mut input).unwrap();
                assert!(Instant::now() < until);
                std::thread::sleep(Duration::from_millis(1));
            }
            if mode.starts_with("echo") {
                assert!(
                    !response.exists(),
                    "A late write completion must not recreate an accepted response"
                );
                assert!(protocol.deferred_result.is_some());
            } else {
                let answer: Value = serde_json::from_slice(&fs::read(&response).unwrap()).unwrap();
                assert_eq!(answer["ok"], mode != "failure");
                if mode == "failure" {
                    assert_eq!(answer["unknown"], true);
                    assert!(protocol.pending.is_empty());
                    assert!(
                        protocol.deferred_result.is_some(),
                        "A failed steer must retain the current turn's result"
                    );
                } else {
                    assert!(protocol.deferred_result.is_none());
                    fs::remove_file(&response).unwrap();
                    assert!(protocol.acknowledge(&echo).unwrap());
                    assert!(
                        !response.exists(),
                        "An echo must not recreate the consumed acceptance"
                    );
                }
            }
        }
    }

    #[test]
    fn an_expired_unwritten_steer_keeps_the_current_result() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("response.json");
        let mut protocol = protocol("claude");
        protocol.pending.insert(
            "request".into(),
            Pending {
                path: path.clone(),
                steer: true,
                accepted: false,
                written: false,
            },
        );
        protocol.deferred_result = Some(json!({"type":"result","is_error":false}));
        let mut input = input::start(std::io::sink());
        assert!(
            input
                .control(&json!({"text":"expired"}), "request".into(), 0)
                .unwrap()
        );
        let until = Instant::now() + Duration::from_secs(2);
        while !path.exists() {
            protocol.written(&mut input).unwrap();
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        let answer: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert_eq!(answer["ok"], false);
        assert!(answer["unknown"].is_null());
        assert!(protocol.pending.is_empty());
        assert!(protocol.deferred_result.is_some());
    }

    #[test]
    fn busy_input_leaves_later_mailbox_requests_for_the_next_poll() {
        struct Held(mpsc::Sender<()>, mpsc::Receiver<()>);
        impl Write for Held {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                self.0.send(()).unwrap();
                self.1.recv().unwrap();
                Ok(())
            }
        }
        let root = tempfile::tempdir().unwrap();
        let id = "00000000000040008000000000000001";
        let request = root.path().join(format!("request-{id}.json"));
        let response = root.path().join(format!("response-{id}.json"));
        fs::write(
            &request,
            json!({"id":id,"steer":"x".repeat(1024*1024),"expires":0}).to_string(),
        )
        .unwrap();
        let (entered, was_entered) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let mut input = input::start(Held(entered, released));
        input.send(&json!({"first":true})).unwrap();
        was_entered.recv_timeout(Duration::from_secs(2)).unwrap();
        let mut protocol = protocol("claude");
        protocol.controls(root.path(), &mut input).unwrap();
        assert!(
            request.exists() && !response.exists(),
            "Busy input must defer mailbox reads"
        );
        release.send(()).unwrap();
        let until = Instant::now() + Duration::from_secs(2);
        while input.busy() {
            protocol.written(&mut input).unwrap();
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        protocol.controls(root.path(), &mut input).unwrap();
        assert!(!request.exists());
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(response).unwrap()).unwrap()["ok"],
            false
        );
    }

    #[test]
    fn acknowledgements_must_match_the_control_kind() {
        let id = "00000000000040008000000000000001";
        let uuid = "00000000-0000-4000-8000-000000000001";
        for (backend, steer, wrong) in [
            (
                "claude",
                true,
                json!({"type":"control_response","response":{"request_id":id,"subtype":"error"}}),
            ),
            ("claude", false, json!({"type":"user","uuid":uuid})),
            (
                "codex",
                true,
                json!({"id":id,"method":"approval/request","params":{}}),
            ),
            ("codex", false, json!({"id":id})),
        ] {
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("response.json");
            let mut protocol = protocol(backend);
            protocol.pending.insert(
                id.into(),
                Pending {
                    path: path.clone(),
                    steer,
                    accepted: false,
                    written: false,
                },
            );
            assert!(
                !protocol.acknowledge(&wrong).unwrap(),
                "An unrelated message must not acknowledge queued input: {backend}/{steer}"
            );
            assert!(!path.exists() && protocol.pending.contains_key(id));
            let right = if backend == "claude" {
                if steer {
                    json!({"type":"user","uuid":uuid})
                } else {
                    json!({"type":"control_response","response":{"request_id":id,"subtype":"success"}})
                }
            } else if steer {
                json!({"id":id,"result":{"turnId":"turn"}})
            } else {
                json!({"id":id,"result":{"status":"applied"}})
            };
            assert!(protocol.acknowledge(&right).unwrap());
            assert!(protocol.pending.is_empty());
            assert_eq!(
                serde_json::from_slice::<Value>(&fs::read(path).unwrap()).unwrap()["ok"],
                true
            );
        }
    }

    #[cfg(unix)]
    #[test]
    #[ignore = "manual provider queue memory and throughput measurement"]
    fn protocol_output_backpressure_measurement() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        struct Records {
            bytes: Vec<u8>,
            left: usize,
            offset: usize,
            completed: Arc<AtomicUsize>,
            finished: mpsc::Sender<()>,
        }
        impl Read for Records {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                if self.left == 0 {
                    return Ok(0);
                }
                let count = buffer.len().min(self.bytes.len() - self.offset);
                buffer[..count].copy_from_slice(&self.bytes[self.offset..self.offset + count]);
                self.offset += count;
                if self.offset == self.bytes.len() {
                    self.offset = 0;
                    self.left -= 1;
                    self.completed.fetch_add(1, Ordering::SeqCst);
                }
                Ok(count)
            }
        }
        impl Drop for Records {
            fn drop(&mut self) {
                let _ = self.finished.send(());
            }
        }
        fn peak_kib() -> u64 {
            let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
            // SAFETY: getrusage initializes the provided rusage on success.
            assert_eq!(
                unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) },
                0
            );
            let peak = unsafe { usage.assume_init() }.ru_maxrss as u64;
            if cfg!(target_os = "macos") {
                peak / 1024
            } else {
                peak
            }
        }
        let completed = Arc::new(AtomicUsize::new(0));
        let (finished, was_finished) = mpsc::channel();
        let bytes = format!("{{\"data\":\"{}\"}}\n", "x".repeat(4 * 1024 * 1024)).into_bytes();
        let before = peak_kib();
        let receiver = read_messages_from(Records {
            bytes,
            left: 40,
            offset: 0,
            completed: Arc::clone(&completed),
            finished,
        });
        let start = Instant::now();
        let mut last = 0;
        let mut changed = start;
        while start.elapsed() < Duration::from_secs(10) {
            let count = completed.load(Ordering::SeqCst);
            if count != last {
                last = count;
                changed = Instant::now();
            }
            if count >= 2 && changed.elapsed() >= Duration::from_millis(300) {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        println!(
            "Provider queue: {last} complete 4 MiB frames read without consumption; peak {before} -> {} KiB",
            peak_kib()
        );
        drop(receiver);
        was_finished
            .recv_timeout(Duration::from_secs(2))
            .expect("Dropping the receiver must release the blocked drainer");

        let mut timings = Vec::new();
        for _ in 0..7 {
            let (finished, _) = mpsc::channel();
            let receiver = read_messages_from(Records {
                bytes: b"{\"type\":\"delta\",\"text\":\"small streaming message\"}\n".to_vec(),
                left: 30_000,
                offset: 0,
                completed: Arc::new(AtomicUsize::new(0)),
                finished,
            });
            let start = Instant::now();
            for _ in 0..30_000 {
                assert_eq!(
                    receiver
                        .recv_timeout(Duration::from_secs(2))
                        .unwrap()
                        .unwrap()["type"],
                    "delta"
                );
            }
            timings.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        timings.sort_by(f64::total_cmp);
        println!(
            "Provider queue: 30,000 small streamed messages, median of 7 = {} ms",
            timings[3]
        );
    }

    #[test]
    fn codex_text_deltas_belong_to_the_active_thread_and_turn() {
        let message = json!({"method":"item/agentMessage/delta","params":{
            "threadId":"thread", "turnId":"turn", "itemId":"reply", "delta":" 🌍"
        }});
        assert_eq!(
            codex_owned_item(&message, "thread", "turn").unwrap(),
            json!({"type":"item.delta","item":{"type":"agent_message","id":"reply","text":" 🌍"}})
        );
        assert!(codex_owned_item(&message, "other", "turn").is_none());
        assert!(codex_owned_item(&message, "thread", "other").is_none());
        assert!(codex_owned_item(&message, "thread", "").is_none());
    }

    #[test]
    fn capability_prewarming_and_first_use_share_one_probe() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let cache = Arc::new(VersionCache::default());
        let calls = Arc::new(AtomicUsize::new(0));
        let (entered, was_entered) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let background = {
            let cache = Arc::clone(&cache);
            let calls = Arc::clone(&calls);
            std::thread::spawn(move || {
                cache.version("fixture", || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    entered.send(()).unwrap();
                    released.recv_timeout(Duration::from_secs(5)).unwrap();
                    Some([2, 1, 289])
                })
            })
        };
        was_entered.recv_timeout(Duration::from_secs(5)).unwrap();
        let (starting, started) = mpsc::channel();
        let foreground = {
            let cache = Arc::clone(&cache);
            let calls = Arc::clone(&calls);
            std::thread::spawn(move || {
                starting.send(()).unwrap();
                cache.version("fixture", || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    None
                })
            })
        };
        started.recv_timeout(Duration::from_secs(5)).unwrap();
        // A different command remains usable while this probe is in flight.
        assert_eq!(
            cache.version("another", || Some([0, 160, 0])),
            Some([0, 160, 0])
        );
        release.send(()).unwrap();
        assert_eq!(background.join().unwrap(), Some([2, 1, 289]));
        assert_eq!(foreground.join().unwrap(), Some([2, 1, 289]));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn capability_cache_preserves_negative_expiry_and_version_changes() {
        let cache = VersionCache::default();
        assert_eq!(cache.version("fixture", || None), None);
        assert_eq!(
            cache.version("fixture", || panic!("negative results stay cached")),
            None
        );
        let entry = Arc::clone(cache.entries.lock().unwrap().get("fixture").unwrap());
        *entry.lock().unwrap() = Some((Instant::now() - CAPABILITY_TTL, None));
        assert_eq!(
            cache.version("fixture", || Some([0, 160, 0])),
            Some([0, 160, 0])
        );
        assert_eq!(
            cache.version("fixture", || panic!("fresh version stays cached")),
            Some([0, 160, 0])
        );
        *entry.lock().unwrap() = Some((Instant::now() - CAPABILITY_TTL, Some([0, 160, 0])));
        assert_eq!(
            cache.version("fixture", || Some([0, 159, 0])),
            Some([0, 159, 0])
        );
        assert_eq!(cli_version("codex-cli 0.160.0"), Some([0, 160, 0]));
        assert_eq!(cli_version("Claude 2.1.289"), Some([2, 1, 289]));
        for invalid in ["", "version unknown", "2.1", "2.1.289-extra", "2.1.289.1"] {
            assert_eq!(cli_version(invalid), None);
        }
    }

    #[test]
    fn native_image_items_keep_tool_identity_and_structured_image_evidence() {
        let data = crate::base64::encode(b"\x89PNG\r\n\x1a\nfixture");
        for item in [
            json!({"type":"imageView","id":"view","path":"screen.png"}),
            json!({"type":"mcpToolCall","id":"mcp","tool":"capture","arguments":{},"status":"completed","result":{"content":[{"type":"image","data":data}]}}),
            json!({"type":"imageGeneration","id":"generate","status":"completed","result":data}),
            json!({"type":"dynamicToolCall","id":"dynamic","tool":"capture","arguments":{},"status":"completed","contentItems":[{"type":"inputImage","imageUrl":format!("data:image/png;base64,{data}")}]}),
        ] {
            let normalized = codex_item(&item).expect("native image items must reach the parser");
            let mut parser = crate::transcript::Parser::new("codex");
            let stream = format!(
                "{}\n{}\n",
                json!({"type":"item.started","item":normalized}),
                json!({"type":"item.completed","item":normalized})
            );
            let events = parser.push_events(stream.as_bytes());
            assert!(events.iter().any(|event| matches!(event, crate::transcript::Event::ToolStart { call_id, .. } if call_id == item["id"].as_str().unwrap())));
            assert!(events.iter().any(|event| matches!(event, crate::transcript::Event::ToolEnd { call_id, ok:true, .. } if call_id == item["id"].as_str().unwrap())));
            let images = parser.take_images();
            assert_eq!(images.len(), 1, "{item}");
            assert_eq!(images[0].call_id, item["id"].as_str().unwrap());
        }
    }

    #[test]
    fn resumed_usage_counts_new_work_once_and_handles_compaction_resets() {
        let mut usage = CodexUsage::default();
        assert!(usage.observe(&json!({"total":{"inputTokens":1000,"cachedInputTokens":800,"outputTokens":100},"last":{"inputTokens":500}}), false).is_none());
        let first = json!({"total":{"inputTokens":1100,"cachedInputTokens":850,"outputTokens":110},"last":{"inputTokens":100,"cachedInputTokens":50,"outputTokens":10}});
        assert_eq!(usage.observe(&first, true).unwrap()["input_tokens"], 100);
        assert_eq!(
            usage.observe(&first, true).unwrap()["input_tokens"],
            100,
            "repeated notifications are snapshots"
        );
        let next = usage.observe(&json!({"total":{"inputTokens":20,"cachedInputTokens":10,"outputTokens":2},"last":{"inputTokens":20,"cachedInputTokens":10,"outputTokens":2}}), true).unwrap();
        assert_eq!(next["input_tokens"], 120);
        assert_eq!(next["cached_input_tokens"], 60);
        assert_eq!(next["output_tokens"], 12);
        let mut cold = CodexUsage::default();
        assert_eq!(
            cold.observe(&first, true).unwrap()["input_tokens"],
            100,
            "cold resume without a replay only counts the latest increment"
        );
    }

    #[test]
    fn codex_inventory_reports_truncated_tool_lists() {
        let tools: serde_json::Map<_, _> = (0..257)
            .map(|i| (format!("tool-{i}"), json!({"description":"private"})))
            .collect();
        let inventory = codex_mcp_inventory(&[json!({"name":"many-tools", "tools":tools})]);
        assert_eq!(inventory["inventoryPartial"], true);
        assert_eq!(
            inventory["servers"][0]["tools"].as_array().unwrap().len(),
            256
        );
        assert!(!inventory.to_string().contains("private"));
    }

    #[test]
    fn malformed_launch_and_oversized_protocol_messages_are_refused() {
        assert!(claude_launch(&[]).is_err());
        assert!(codex_launch(&[]).is_err());
        let mut reader = std::io::Cursor::new(format!("{{\"text\":\"{}\"}}\n", "x".repeat(100)));
        assert!(
            read_message(&mut reader, 32)
                .unwrap_err()
                .contains("too large")
        );
        let mut reader = std::io::Cursor::new(b"{}\n{}\n");
        assert!(read_message(&mut reader, 32).unwrap().is_some());
        assert!(read_message(&mut reader, 32).unwrap().is_some());
        assert!(read_message(&mut reader, 32).unwrap().is_none());
    }

    #[test]
    fn protocol_queue_weights_use_utf8_frame_bytes() {
        let line = "{\"text\":\"🌍 café\"}\n";
        let mut reader = std::io::Cursor::new(line.as_bytes());
        let (value, bytes) = read_message(&mut reader, line.len() as u64)
            .unwrap()
            .unwrap();
        assert_eq!(value["text"], "🌍 café");
        assert_eq!(bytes, line.len());
        assert!(
            read_message(&mut reader, line.len() as u64)
                .unwrap()
                .is_none()
        );
    }

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
                "stream-json",
                "--replay-user-messages"
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
                pending: HashMap::from([(
                    "request".into(),
                    Pending {
                        path: path.clone(),
                        steer: false,
                        accepted: false,
                        written: false,
                    },
                )]),
                usage: Value::Null,
                deferred_result: None,
                finished: false,
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
