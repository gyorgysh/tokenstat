// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Codex plan limits, asked of Codex itself.
//!
//! Codex writes its limits into a session log only while it runs a turn, so
//! somebody who has not used Codex since a window reset sees a stale reading.
//! Codex's app server answers `account/rateLimits/read` from the account
//! instead: current numbers, no turn, nothing billed, and through Codex's own
//! sign-in. The logs stay as the fallback for a Codex without that request
//! and for an API-key login, which has no plan windows to report.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokenstat_core::limits::ProviderLimits;

/// A cold Codex start plus one request on a slow network.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(20);
/// Same pacing as the Claude read: an automatic pass reuses an answer this
/// long, an explicit refresh shares a very young one, and a failure leaves
/// Codex alone for a minute.
const REUSE_AUTOMATIC: Duration = Duration::from_secs(120);
const REUSE_FORCED: Duration = Duration::from_secs(15);
const FAILURE_PAUSE: Duration = Duration::from_secs(60);

fn now_ms() -> i64 {
    jiff::Timestamp::now().as_millisecond()
}

/// The Codex reading for one limits pass: Codex's own answer when it gives
/// one, else its session logs, including the private homes chats run in.
pub(crate) fn read(force: bool) -> ProviderLimits {
    if let Some(reading) = read_through_codex(force) {
        return reading;
    }
    tokenstat_core::limits::codex_limits_with_homes(&chat_codex_homes())
}

/// The per-chat Codex homes the host created. Codex writes those chats'
/// logs there rather than under `~/.codex`.
fn chat_codex_homes() -> Vec<std::path::PathBuf> {
    let Some(root) = tokenstat_paths::data_dir().map(|dir| dir.join("chat")) else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|entry| entry.path().join("codex-hook"))
        .filter(|home| home.join("sessions").is_dir())
        .collect()
}

struct Pace {
    at: Instant,
    reading: Option<ProviderLimits>,
}

/// `None` when Codex is not installed or gave no reading, so the caller
/// falls back to the logs.
fn read_through_codex(force: bool) -> Option<ProviderLimits> {
    static LAST: Mutex<Option<Pace>> = Mutex::new(None);
    let mut last = LAST
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(pace) = last.as_ref() {
        let reuse = match (force, pace.reading.is_some()) {
            (true, _) => REUSE_FORCED,
            (false, true) => REUSE_AUTOMATIC,
            (false, false) => FAILURE_PAUSE,
        };
        if pace.at.elapsed() < reuse {
            return pace.reading.clone();
        }
    }
    let program = crate::launcher::resolve_command("codex")?;
    let reading = ask(&program)
        .and_then(|answer| tokenstat_core::limits::codex_limits_from_answer(&answer, now_ms()));
    *last = Some(Pace {
        at: Instant::now(),
        reading: reading.clone(),
    });
    reading
}

/// Start `codex app-server`, ask for the account's rate limits, and stop it.
/// It runs from the home folder with the person's own Codex home, because
/// the question is about their account and Codex's sign-in lives there.
fn ask(program: &str) -> Option<Value> {
    let mut command = Command::new(program);
    command
        .arg("app-server")
        .env("PATH", crate::launcher::search_path_var())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(home) = tokenstat_paths::home_dir() {
        command.current_dir(home);
    }
    let mut child = command.spawn().ok()?;
    let mut stdin = child.stdin.take();
    if let Some(input) = stdin.as_mut() {
        for message in [
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"clientInfo": {"name": "tokenstat", "version": env!("CARGO_PKG_VERSION")}}}),
            json!({"jsonrpc": "2.0", "method": "initialized"}),
            json!({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"}),
        ] {
            let _ = writeln!(input, "{message}");
        }
        let _ = input.flush();
    }
    let (sender, receiver) = std::sync::mpsc::channel();
    if let Some(stdout) = child.stdout.take() {
        std::thread::spawn(move || {
            let reader = BufReader::new(stdout.take(4 * 1024 * 1024));
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if value["id"] == 2 {
                    let _ = sender.send(value);
                    return;
                }
            }
        });
    }
    let answer = receiver.recv_timeout(ANSWER_TIMEOUT).ok();
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    // An older Codex answers with an error for an unknown method.
    answer.and_then(|value| value.get("result").cloned())
}
