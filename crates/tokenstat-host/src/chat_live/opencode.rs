// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Observe the native v2 stream while the existing CLI owns the actual turn.
//! The leased server inherits this turn's hooks and credentials. No user
//! service is reused, and losing this observation never resends a prompt.

use super::{emitter::Emitter, mailbox::Stop, output};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

mod projection;
mod steering;
use projection::Projection;

const RECORD_CAP: usize = 16 * 1024 * 1024;
const PART_CAP: usize = 256;

fn envelope(source: &str, value: Value) -> Value {
    // The queue owns the parsed record. Move large completions through it
    // instead of cloning them just to label their source.
    Value::Object(serde_json::Map::from_iter([(source.into(), value)]))
}

pub(super) fn supported(backend: &str, argv: &[String]) -> bool {
    if !matches!(backend, "opencode" | "opencode2")
        || !argv
            .iter()
            .take_while(|arg| arg.as_str() != "--")
            .any(|arg| arg == "--standalone")
        || !std::env::current_exe().ok().is_some_and(|path| {
            path.file_stem()
                .is_some_and(|name| name == "tokenstat-hostd")
        })
    {
        return false;
    }
    supports_version(backend)
}

fn supports_version(backend: &str) -> bool {
    let Some((command, key, cacheable)) = crate::opencode_cli::version_probe_identity(backend)
    else {
        return false;
    };
    static CACHE: std::sync::OnceLock<super::VersionCache> = std::sync::OnceLock::new();
    let probe = || {
        let version = crate::agent_models::run_list_with_timeout(
            &command,
            &["--version"],
            Duration::from_secs(2),
        )?;
        super::cli_version(
            version
                .trim()
                .trim_start_matches("opencode ")
                .trim_start_matches('v'),
        )
    };
    let version = if cacheable {
        CACHE
            .get_or_init(super::VersionCache::default)
            .version(&key, probe)
    } else {
        probe()
    };
    version.is_some_and(|version| version[0] == 2 && version >= [2, 0, 32])
}

struct Owned {
    child: Child,
    reaped: bool,
}

impl Owned {
    fn spawn(command: &mut Command) -> Result<Self, String> {
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        Ok(Self {
            child: command.spawn().map_err(|error| error.to_string())?,
            reaped: false,
        })
    }

    fn finish(&mut self) -> Result<(), String> {
        // Keep the PID reserved until descendant cleanup, as in the other
        // native runners. Reaping first could signal a reused process group.
        super::kill_agent(&mut self.child);
        let status = self.child.wait().map_err(|error| error.to_string())?;
        self.reaped = true;
        if status.success() {
            Ok(())
        } else {
            Err("OpenCode did not complete this turn.".into())
        }
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        if !self.reaped {
            super::kill_agent(&mut self.child);
            let _ = self.child.wait();
        }
    }
}

struct Lease {
    _server: Owned,
    url: reqwest::Url,
    password: String,
}

impl Drop for Lease {
    fn drop(&mut self) {
        // Match the CLI's standalone lease: EOF lets the engine persist its
        // final session state before the process group is forcibly retired.
        self._server.child.stdin.take();
        let deadline = Instant::now() + super::EXIT_TIMEOUT;
        while Instant::now() < deadline
            && !super::agent_exited(&mut self._server.child).unwrap_or(true)
        {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn receive<T>(rx: &mpsc::Receiver<T>, stop: &mut Stop, timeout: Duration) -> Result<T, String> {
    let deadline = Instant::now() + timeout;
    loop {
        if stop.requested() {
            return Err("The turn was stopped.".into());
        }
        match rx.recv_timeout(Duration::from_millis(20)) {
            Ok(value) => return Ok(value),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("OpenCode closed its stream during startup.".into());
            }
            Err(mpsc::RecvTimeoutError::Timeout) if Instant::now() >= deadline => {
                return Err("OpenCode did not initialize its stream.".into());
            }
            Err(_) => {}
        }
    }
}

impl Lease {
    fn interrupt(&self, session: &str) {
        let Ok(url) = self.url.join(&format!("api/session/{session}/interrupt")) else {
            return;
        };
        let password = self.password.clone();
        let directory = std::env::current_dir().ok().map(|path| {
            crate::opencode_cli::directory_header(&path)
                .trim_start_matches("x-opencode-directory:")
                .to_string()
        });
        std::thread::spawn(move || {
            if let Ok(client) = tokenstat_sync::http::client_builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(1))
                .build()
            {
                let mut request = client.post(url).basic_auth("opencode", Some(password));
                if let Some(directory) = directory {
                    request = request.header("x-opencode-directory", directory);
                }
                let _ = request.send();
            }
        });
    }

    fn start(binary: &str, stop: &mut Stop) -> Result<Self, String> {
        let mut random = [0u8; 24];
        getrandom::fill(&mut random).map_err(|error| error.to_string())?;
        let password: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let args =
            ["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"].map(str::to_string);
        let mut command = tokenstat_pty::headless_command(binary, &args);
        command
            .env("OPENCODE_PASSWORD", &password)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut server = Owned::spawn(&mut command)?;
        let stdout = server
            .child
            .stdout
            .take()
            .ok_or("missing OpenCode readiness output")?;
        let (tx, rx) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let result = super::read_message(&mut reader, 64 * 1024);
            let _ = tx.send(result);
            let _ = std::io::copy(&mut reader, &mut std::io::sink());
        });
        let (ready, _) = receive(&rx, stop, Duration::from_secs(10))??
            .ok_or("OpenCode did not report readiness")?;
        let url = reqwest::Url::parse(ready["url"].as_str().ok_or("missing OpenCode endpoint")?)
            .map_err(|_| "invalid OpenCode endpoint")?;
        if url.scheme() != "http"
            || url.host_str() != Some("127.0.0.1")
            || url.port().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.path() != "/"
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err("OpenCode did not report a private loopback endpoint.".into());
        }
        Ok(Self {
            _server: server,
            url,
            password,
        })
    }

    fn subscribe(&self) -> Result<(output::Sender, output::Messages, mpsc::Receiver<()>), String> {
        let client = tokenstat_sync::http::client_builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(3))
            .build()
            .map_err(|error| error.to_string())?;
        let request = client
            .get(
                self.url
                    .join("api/event")
                    .map_err(|error| error.to_string())?,
            )
            .basic_auth("opencode", Some(&self.password));
        let (tx, rx) = output::channel();
        let native = tx.clone();
        let (connected, ready) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let result = (|| {
                let response = request
                    .send()
                    .map_err(|_| "OpenCode stream could not connect")?
                    .error_for_status()
                    .map_err(|_| "OpenCode stream was refused")?;
                read_sse(BufReader::new(response), |value, bytes| {
                    let kind = value["type"].as_str().unwrap_or("");
                    if kind == "server.connected" {
                        let _ = connected.try_send(());
                    }
                    // Catalog changes, tool-input fragments and other
                    // unused updates need not wake the turn's output loop.
                    if !Projection::observes(kind) && kind != "session.inbox.delivered" {
                        return true;
                    }
                    native.send(Ok(envelope("native", value)), bytes)
                })
            })();
            let _ = result;
            let _ = native.send(Ok(json!({"nativeEof":true})), 0);
        });
        Ok((tx, rx, ready))
    }
}

fn read_sse(
    reader: impl BufRead,
    mut emit: impl FnMut(Value, usize) -> bool,
) -> Result<(), String> {
    let mut reader = reader;
    let mut data = Vec::new();
    loop {
        let mut line = Vec::new();
        let n = reader
            .by_ref()
            .take(RECORD_CAP as u64 + 1)
            .read_until(b'\n', &mut line)
            .map_err(|_| "OpenCode stream disconnected")?;
        if n == 0 {
            return Ok(());
        }
        if line.len() > RECORD_CAP {
            return Err("OpenCode stream record exceeded its limit.".into());
        }
        while matches!(line.last(), Some(b'\r' | b'\n')) {
            line.pop();
        }
        if line.is_empty() && !data.is_empty() {
            let value = serde_json::from_slice(&data)
                .map_err(|_| "OpenCode stream record was unreadable")?;
            if !emit(value, data.len()) {
                return Ok(());
            }
            data.clear();
        } else if let Some(field) = line.strip_prefix(b"data:") {
            let field = field.strip_prefix(b" ").unwrap_or(field);
            if data.len().saturating_add(field.len()).saturating_add(1) > RECORD_CAP {
                return Err("OpenCode stream record exceeded its limit.".into());
            }
            if !data.is_empty() {
                data.push(b'\n');
            }
            data.extend_from_slice(field);
        }
    }
}

pub(super) fn run(argv: &[String], directory: &Path) -> Result<(), String> {
    let mut stop = Stop::new(directory);
    let lease = Lease::start(&argv[0], &mut stop)?;
    let (tx, records, connected) = lease.subscribe()?;
    receive(&connected, &mut stop, Duration::from_secs(8))?;
    let separator = argv
        .iter()
        .position(|arg| arg == "--")
        .unwrap_or(argv.len());
    let mut args = Vec::new();
    for (index, arg) in argv.iter().enumerate().skip(1) {
        if index < separator && arg == "--standalone" {
            args.extend([
                "--server".into(),
                lease.url.as_str().trim_end_matches('/').into(),
            ]);
        } else {
            args.push(arg.clone());
        }
    }
    let mut command = tokenstat_pty::headless_command(&argv[0], &args);
    command
        .env("OPENCODE_PASSWORD", &lease.password)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut cli = Owned::spawn(&mut command)?;
    let (_diagnostics, _finished) = super::read_diagnostics(&mut cli.child);
    let stdout = cli.child.stdout.take().ok_or("missing OpenCode output")?;
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            match super::read_message(&mut reader, RECORD_CAP as u64) {
                Ok(Some((value, bytes))) => {
                    if !tx.send(Ok(envelope("cli", value)), bytes) {
                        return;
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    let _ = tx.send(Err(error), 0);
                    return;
                }
            }
        }
        let _ = tx.send(Ok(json!({"cliEof":true})), 0);
    });
    let mut projection = Projection::default();
    let mut steering: Option<steering::Steering> = None;
    let mut output = Emitter::new(|| std::io::stdout().lock(), directory);
    let mut cli_eof = false;
    let mut native_eof = false;
    let mut exited = None;
    let mut stopped_at = None;
    let mut interrupted = false;
    let result = (|| {
        loop {
            if stop.requested() && stopped_at.is_none() {
                stopped_at = Some(Instant::now());
                if let Some(steering) = &steering {
                    steering.close();
                }
            }
            if stopped_at.is_some()
                && !interrupted
                && let Some(session) = &projection.session
            {
                lease.interrupt(session);
                interrupted = true;
            }
            if stopped_at.is_some_and(|at: Instant| at.elapsed() >= super::INTERRUPT_TIMEOUT) {
                return Err("The turn was stopped.".into());
            }
            match records.recv_timeout(Duration::from_millis(40)) {
                Ok(Ok(mut value)) => {
                    let projected = if value["nativeEof"] == true {
                        native_eof = true;
                        if let Some(steering) = &steering {
                            steering.close();
                        }
                        Vec::new()
                    } else if value["cliEof"] == true {
                        cli_eof = true;
                        Vec::new()
                    } else if let Some(native) = value.get_mut("native") {
                        if let (Some(steering), Some(session)) = (&steering, &projection.session) {
                            steering.delivered(native, session);
                        }
                        projection.native(native.take())
                    } else {
                        projection.cli(value["cli"].take())
                    };
                    if steering.is_none()
                        && stopped_at.is_none()
                        && !projection.ended
                        && let Some(session) = &projection.session
                    {
                        steering = Some(steering::Steering::start(&lease, session, directory)?);
                    }
                    if projection.ended
                        && let Some(steering) = &steering
                    {
                        steering.close();
                    }
                    for value in projected {
                        output.emit(&value)?;
                    }
                }
                Ok(Err(error)) => return Err(error),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    cli_eof = true;
                    native_eof = true;
                    // A CLI may close stdout before its final cleanup ends.
                    // A disconnected receiver otherwise spins without wait.
                    std::thread::sleep(Duration::from_millis(40));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            if super::agent_exited(&mut cli.child).map_err(|error| error.to_string())? {
                if let Some(steering) = &steering {
                    steering.close();
                }
                let at = *exited.get_or_insert_with(Instant::now);
                if cli_eof
                    && (projection.ended || native_eof || at.elapsed() >= Duration::from_secs(1))
                {
                    break;
                }
                if at.elapsed() >= Duration::from_secs(3) {
                    return Err("OpenCode did not close its output.".into());
                }
            }
        }
        output.finish()?;
        if stopped_at.is_some() {
            return Err("The turn was stopped.".into());
        }
        cli.finish()
    })();
    if result.is_err()
        && let Some(steering) = &steering
    {
        steering.close();
    }
    if result.is_err()
        && !cli.reaped
        && let Some(session) = &projection.session
    {
        // Emitter backpressure can return Stop from inside emit(), before
        // the outer loop sees it. Persist the native interruption in that
        // path too, then drain bounded queues while the CLI winds down.
        if !interrupted {
            lease.interrupt(session);
        }
        let deadline = stopped_at.unwrap_or_else(Instant::now) + super::INTERRUPT_TIMEOUT;
        while Instant::now() < deadline && !super::agent_exited(&mut cli.child).unwrap_or(true) {
            let _ = records.recv_timeout(Duration::from_millis(20));
        }
    }
    result
}

#[cfg(test)]
mod tests;
