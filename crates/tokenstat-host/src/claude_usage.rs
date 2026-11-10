// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Where the Claude plan limits come from, in order of trust.
//!
//! 1. **The live feed.** Claude Code pipes `rate_limits` into its status line
//!    command after every reply. When the person turned the feed on, that
//!    command is ours and the latest reading sits on disk. It costs nothing
//!    and is as current as the last message.
//! 2. **Claude Code's own report.** The `get_usage` control request asks a
//!    short lived `claude` for the usage report. Claude Code fetches it with
//!    its own login, so nothing here reads, renews or writes that login, and
//!    no Keychain dialog can follow from it.
//! 3. **The usage endpoint, directly.** `tokenstat_sync::claude_limits`, for a
//!    machine where the `claude` command cannot be found.
//! 4. **The remembered reading**, marked as old, with the reason the others
//!    failed.
//!
//! Each step only runs when the one before it had nothing, so on a machine
//! where Claude Code works the direct endpoint is never asked and the stored
//! login is never touched.

use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokenstat_core::claude_feed::{self, SOURCE};
use tokenstat_core::limits::ProviderLimits;

/// Long enough for a cold start of `claude` plus one request on a slow
/// network, short enough that a hung child cannot hold the limits pass.
const GET_USAGE_TIMEOUT: Duration = Duration::from_secs(25);

/// An automatic pass reuses Claude Code's answer this long. The host asks
/// every five minutes, and the live feed covers the time in between.
const REUSE_AUTOMATIC: Duration = Duration::from_secs(120);

/// An explicit refresh still shares an answer this young, so several screens
/// refreshing together start one `claude`, not several.
const REUSE_FORCED: Duration = Duration::from_secs(15);

/// After a failure, automatic passes leave `claude` alone this long.
const FAILURE_PAUSE: Duration = Duration::from_secs(60);

fn now_ms() -> i64 {
    jiff::Timestamp::now().as_millisecond()
}

/// The Claude reading for one limits pass.
pub(crate) fn read(force: bool) -> ProviderLimits {
    let now = now_ms();
    let live = claude_feed::live::load();
    if !force
        && let Some(reading) = &live
        && age(reading, now) < claude_feed::LIVE_FOR_MS
    {
        return reading.clone();
    }

    let cli = read_through_claude(force);
    if let Some(reading) = cli.as_ref().filter(|r| r.has_reading()) {
        return newest(reading.clone(), live.as_ref());
    }

    let direct = tokenstat_sync::claude_limits::fetch_with_force(force);
    if direct.has_reading() {
        return newest(direct, live.as_ref());
    }

    // Claude Code's own words win when it was there to ask: they describe
    // the source that normally works. The direct read's reason is only
    // useful when no `claude` could be found.
    let failure = cli.unwrap_or(direct);
    let Some(mut reading) = live else {
        return failure;
    };
    let remembered = tokenstat_core::limits::cache::load()
        .get(SOURCE)
        .map_or(0, |r| r.observed_at_ms);
    if reading.observed_at_ms < remembered {
        // The general cache holds something newer, and fills it in.
        return failure;
    }
    if age(&reading, now) >= claude_feed::CURRENT_FOR_MS {
        reading.stale = true;
        reading.note = failure.note;
    }
    reading
}

fn age(reading: &ProviderLimits, now: i64) -> i64 {
    now.saturating_sub(reading.observed_at_ms)
}

/// A live reading newer than the one just fetched is the better answer: it
/// came from a reply that happened after the request was answered.
fn newest(fetched: ProviderLimits, live: Option<&ProviderLimits>) -> ProviderLimits {
    match live {
        Some(live) if live.observed_at_ms > fetched.observed_at_ms => ProviderLimits {
            plan: fetched.plan.clone().or_else(|| live.plan.clone()),
            ..live.clone()
        },
        _ => fetched,
    }
}

struct Pace {
    at: Instant,
    reading: ProviderLimits,
}

/// `None` when there is no `claude` to ask, so the caller tries the next
/// source. A reading or a reason otherwise.
fn read_through_claude(force: bool) -> Option<ProviderLimits> {
    static LAST: Mutex<Option<Pace>> = Mutex::new(None);
    let mut last = LAST
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(pace) = last.as_ref() {
        let elapsed = pace.at.elapsed();
        let reuse = match (force, pace.reading.has_reading()) {
            (true, _) => REUSE_FORCED,
            (false, true) => REUSE_AUTOMATIC,
            (false, false) => FAILURE_PAUSE,
        };
        if elapsed < reuse {
            return Some(pace.reading.clone());
        }
    }
    let program = crate::launcher::resolve_command("claude")?;
    let reading = get_usage(&program);
    *last = Some(Pace {
        at: Instant::now(),
        reading: reading.clone(),
    });
    Some(reading)
}

/// Ask one `claude` for its usage report and stop it.
///
/// No prompt is sent, so no model turn runs and nothing is billed. The
/// person's own settings are left out (`--setting-sources ""`), so their
/// hooks and status line do not fire for a process they did not start, and
/// nothing is saved as a session.
fn get_usage(program: &str) -> ProviderLimits {
    let mut command = Command::new(program);
    command
        .args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--setting-sources",
            "",
        ])
        .env("PATH", crate::launcher::search_path_var())
        // A host started from inside a Claude Code session must not make
        // this child believe it is nested in one.
        .env_remove("CLAUDECODE")
        .env_remove("CLAUDE_CODE_ENTRYPOINT")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(home) = tokenstat_paths::home_dir() {
        command.current_dir(home);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            return ProviderLimits::unavailable(
                SOURCE,
                format!("Could not start Claude Code: {e}"),
            );
        }
    };

    let request_id = format!("tokenstat-usage-{}", std::process::id());
    let request = json!({
        "type": "control_request",
        "request_id": request_id,
        "request": {"subtype": "get_usage", "skip_behaviors": true},
    });
    // Stdin stays open until the answer is in: closing it ends the session
    // before the request has been read.
    let mut stdin = child.stdin.take();
    if let Some(input) = stdin.as_mut() {
        let _ = writeln!(input, "{request}");
        let _ = input.flush();
    }

    let (sender, receiver) = std::sync::mpsc::channel();
    if let Some(stdout) = child.stdout.take() {
        let wanted = request_id.clone();
        std::thread::spawn(move || {
            let reader = BufReader::new(stdout.take(16 * 1024 * 1024));
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if value.get("type").and_then(Value::as_str) == Some("control_response")
                    && value
                        .pointer("/response/request_id")
                        .and_then(Value::as_str)
                        == Some(wanted.as_str())
                {
                    let _ = sender.send(value);
                    return;
                }
            }
        });
    }
    let answer = receiver.recv_timeout(GET_USAGE_TIMEOUT);
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();

    match answer {
        Ok(value) => interpret(&value, now_ms()),
        Err(_) => ProviderLimits::unavailable(
            SOURCE,
            "Claude Code did not answer the usage request in time.",
        ),
    }
}

fn interpret(value: &Value, now: i64) -> ProviderLimits {
    let response = value.get("response").unwrap_or(&Value::Null);
    if response.get("subtype").and_then(Value::as_str) == Some("success") {
        return claude_feed::from_get_usage(response.get("response").unwrap_or(&Value::Null), now);
    }
    let error = response
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or("no reason given");
    ProviderLimits::unavailable(
        SOURCE,
        format!("Claude Code could not report its usage: {error}"),
    )
}

/// `tokenstat-hostd statusline`: what Claude Code runs as its status line once
/// the live feed is on.
///
/// Remembers the limits in the payload, then prints a line. When the person
/// had a status line of their own before, that command runs with the same
/// input and its output is passed through, so turning the feed on changes
/// nothing they can see.
pub fn run_status_line() -> u8 {
    let mut input = Vec::new();
    if std::io::stdin()
        .take(4 * 1024 * 1024)
        .read_to_end(&mut input)
        .is_err()
    {
        return 0;
    }
    let reading = serde_json::from_slice::<Value>(&input)
        .ok()
        .and_then(|payload| claude_feed::from_status_line(&payload, now_ms()));
    if let Some(reading) = &reading {
        let _ = claude_feed::live::store(reading);
    }

    let mut out = std::io::stdout();
    if let Some(previous) = status_line::chained_command() {
        if let Some(text) = status_line::run_chained(&previous, &input) {
            let _ = out.write_all(&text);
        }
    } else if let Some(reading) = &reading {
        let _ = writeln!(out, "{}", claude_feed::status_line_text(reading));
    }
    let _ = out.flush();
    0
}

/// Turning the live feed on and off.
///
/// This edits Claude Code's `settings.json`, which belongs to Claude Code, so
/// it only ever happens because a person pressed a button, and it is undone
/// exactly: their own status line command is kept aside and put back.
pub(crate) mod status_line {
    use super::*;
    use std::path::PathBuf;

    /// Marks the command as ours, so the state can be read back from the
    /// settings file alone.
    const ARGUMENT: &str = "statusline";

    fn settings_path() -> Option<PathBuf> {
        let base = std::env::var_os("CLAUDE_CONFIG_DIR")
            .filter(|dir| !dir.is_empty())
            .map(PathBuf::from)
            .or_else(|| tokenstat_paths::home_dir().map(|home| home.join(".claude")))?;
        Some(base.join("settings.json"))
    }

    fn chain_path() -> Option<PathBuf> {
        Some(tokenstat_paths::data_dir()?.join("claude-statusline-previous.json"))
    }

    fn our_command() -> Result<String, String> {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let exe = exe.to_str().ok_or("the helper's path is not valid text")?;
        if exe.contains('"') {
            return Err("the helper's path cannot be quoted for a shell".into());
        }
        Ok(format!("\"{exe}\" {ARGUMENT}"))
    }

    fn is_ours(status_line: &Value) -> bool {
        status_line
            .get("command")
            .and_then(Value::as_str)
            .is_some_and(|c| c.contains("tokenstat-hostd") && c.trim_end().ends_with(ARGUMENT))
    }

    /// The settings file as text, or `None` when there is none yet. Parsed
    /// once to make sure it is a JSON object: a file Claude Code itself would
    /// refuse is left alone rather than repaired.
    fn read_settings(path: &std::path::Path) -> Result<Option<String>, String> {
        match std::fs::read_to_string(path) {
            Ok(raw) if raw.trim().is_empty() => Ok(None),
            Ok(raw) => match serde_json::from_str::<Value>(&raw) {
                Ok(Value::Object(_)) => Ok(Some(raw)),
                _ => Err(format!(
                    "{} is not a JSON object, so it was left alone.",
                    path.display()
                )),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("Could not read {}: {e}", path.display())),
        }
    }

    fn current_status_line(text: Option<&str>) -> Option<Value> {
        serde_json::from_str::<Value>(text?)
            .ok()?
            .get("statusLine")
            .cloned()
    }

    fn write_settings(path: &std::path::Path, text: &str) -> Result<(), String> {
        // Never write something Claude Code would fail to read.
        if !matches!(serde_json::from_str::<Value>(text), Ok(Value::Object(_))) {
            return Err("The edited settings were not valid JSON, so nothing was written.".into());
        }
        let parent = path.parent().ok_or("settings path has no folder")?;
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let staging = parent.join(format!(".settings.json.tokenstat.{}", std::process::id()));
        std::fs::write(&staging, text).map_err(|e| e.to_string())?;
        std::fs::rename(&staging, path).map_err(|e| {
            let _ = std::fs::remove_file(&staging);
            e.to_string()
        })
    }

    /// Whether the feed is on, read from Claude Code's settings.
    pub(crate) fn state() -> Value {
        let enabled = settings_path()
            .and_then(|path| read_settings(&path).ok().flatten())
            .and_then(|text| current_status_line(Some(&text)))
            .is_some_and(|line| is_ours(&line));
        let live = claude_feed::live::load();
        json!({
            "enabled": enabled,
            "chained": chained_command().is_some(),
            "lastReadingAtMs": live.map(|r| r.observed_at_ms),
        })
    }

    /// Turn the feed on or off. Idempotent both ways.
    ///
    /// Only the `statusLine` value is touched, in place. Every other byte of
    /// the file, its key order, spacing and anything this version has never
    /// heard of, stays exactly as Claude Code or the person left it.
    pub(crate) fn set(enable: bool) -> Result<Value, String> {
        let path = settings_path().ok_or("Could not find Claude Code's settings folder.")?;
        let text = read_settings(&path)?;
        let ours = current_status_line(text.as_deref()).is_some_and(|line| is_ours(&line));
        let chain = chain_path().ok_or("Could not find the data folder.")?;
        let original = text.clone().unwrap_or_else(|| "{}\n".to_string());

        if enable && !ours {
            // Kept aside, as the exact text it was written in, before anything
            // is changed, so a failed write below can never lose it.
            let previous = json_text::member_value(&original, "statusLine")?;
            write_private(&chain, &json!({ "statusLineText": previous }))?;
            let command = serde_json::to_string(&our_command()?).map_err(|e| e.to_string())?;
            let value = format!(r#"{{"type": "command", "command": {command}, "padding": 0}}"#);
            let edited = json_text::set_member(&original, "statusLine", Some(&value))?;
            write_settings(&path, &edited)?;
        } else if !enable && ours {
            let previous = std::fs::read_to_string(&chain)
                .ok()
                .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
                .and_then(|saved| {
                    saved
                        .get("statusLineText")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                });
            let edited = json_text::set_member(&original, "statusLine", previous.as_deref())?;
            write_settings(&path, &edited)?;
            let _ = std::fs::remove_file(&chain);
        }
        Ok(state())
    }

    fn write_private(path: &std::path::Path, value: &Value) -> Result<(), String> {
        let text = serde_json::to_string(value).map_err(|e| e.to_string())?;
        tokenstat_sync::snapshot::write_private_atomically(path, &text).map_err(|e| e.to_string())
    }

    /// The person's own status line command, saved when the feed was turned
    /// on. Never one of ours, which would call itself forever.
    pub(crate) fn chained_command() -> Option<String> {
        let raw = std::fs::read_to_string(chain_path()?).ok()?;
        let saved: Value = serde_json::from_str(&raw).ok()?;
        let line: Value = serde_json::from_str(saved.get("statusLineText")?.as_str()?).ok()?;
        if is_ours(&line) {
            return None;
        }
        line.get("command")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|c| !c.is_empty())
            .map(str::to_string)
    }

    /// Run the saved command the way Claude Code would have, with the same
    /// input, and hand back what it printed. Bounded, because Claude Code
    /// waits for the line.
    pub(crate) fn run_chained(command: &str, input: &[u8]) -> Option<Vec<u8>> {
        #[cfg(windows)]
        let mut shell = {
            let mut c = Command::new("cmd");
            c.args(["/C", command]);
            c
        };
        #[cfg(not(windows))]
        let mut shell = {
            let mut c = Command::new("/bin/sh");
            c.args(["-c", command]);
            c
        };
        let mut child = shell
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .ok()?;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(input);
        }
        let stdout = child.stdout.take()?;
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut text = Vec::new();
            let _ = stdout.take(1024 * 1024).read_to_end(&mut text);
            let _ = sender.send(text);
        });
        let text = receiver.recv_timeout(Duration::from_secs(10)).ok();
        let _ = child.kill();
        let _ = child.wait();
        text
    }
}

/// Editing one top-level member of a JSON object as text.
///
/// Rewriting a settings file through a parser would sort its keys and
/// respace it, which is a change to somebody else's file that nobody asked
/// for. This finds the member's exact span and replaces only that.
mod json_text {
    struct Member {
        key: String,
        key_start: usize,
        value_start: usize,
        value_end: usize,
    }

    fn skip_ws(b: &[u8], mut i: usize) -> usize {
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        i
    }

    /// Index just past the string that opens at `i`.
    fn skip_string(b: &[u8], mut i: usize) -> Result<usize, String> {
        i += 1;
        while i < b.len() {
            match b[i] {
                b'\\' => i += 2,
                b'"' => return Ok(i + 1),
                _ => i += 1,
            }
        }
        Err("unterminated string".into())
    }

    fn skip_value(b: &[u8], i: usize) -> Result<usize, String> {
        match b.get(i) {
            Some(b'"') => skip_string(b, i),
            Some(b'{' | b'[') => {
                let mut depth = 0usize;
                let mut j = i;
                while j < b.len() {
                    match b[j] {
                        b'"' => {
                            j = skip_string(b, j)?;
                            continue;
                        }
                        b'{' | b'[' => depth += 1,
                        b'}' | b']' => {
                            depth -= 1;
                            if depth == 0 {
                                return Ok(j + 1);
                            }
                        }
                        _ => {}
                    }
                    j += 1;
                }
                Err("unbalanced brackets".into())
            }
            Some(_) => {
                let mut j = i;
                while j < b.len()
                    && !matches!(b[j], b',' | b'}' | b']')
                    && !b[j].is_ascii_whitespace()
                {
                    j += 1;
                }
                Ok(j)
            }
            None => Err("missing value".into()),
        }
    }

    /// The members of the top-level object, plus where it opens and closes.
    fn members(text: &str) -> Result<(usize, usize, Vec<Member>), String> {
        let b = text.as_bytes();
        let open = skip_ws(b, 0);
        if b.get(open) != Some(&b'{') {
            return Err("not a JSON object".into());
        }
        let mut list = Vec::new();
        let mut i = skip_ws(b, open + 1);
        if b.get(i) == Some(&b'}') {
            return Ok((open, i, list));
        }
        loop {
            if b.get(i) != Some(&b'"') {
                return Err("expected a key".into());
            }
            let key_start = i;
            let key_end = skip_string(b, i)?;
            let key: String =
                serde_json::from_str(&text[key_start..key_end]).map_err(|e| e.to_string())?;
            i = skip_ws(b, key_end);
            if b.get(i) != Some(&b':') {
                return Err("expected a colon".into());
            }
            let value_start = skip_ws(b, i + 1);
            let value_end = skip_value(b, value_start)?;
            list.push(Member {
                key,
                key_start,
                value_start,
                value_end,
            });
            i = skip_ws(b, value_end);
            match b.get(i) {
                Some(b',') => i = skip_ws(b, i + 1),
                Some(b'}') => return Ok((open, i, list)),
                _ => return Err("expected a comma or the end of the object".into()),
            }
        }
    }

    /// The exact text of one member's value, if it is there.
    pub(super) fn member_value(text: &str, key: &str) -> Result<Option<String>, String> {
        let (_, _, list) = members(text)?;
        Ok(list
            .iter()
            .rfind(|m| m.key == key)
            .map(|m| text[m.value_start..m.value_end].to_string()))
    }

    /// Set, replace or (with `None`) remove one member, leaving the rest of
    /// the text as it was.
    pub(super) fn set_member(text: &str, key: &str, value: Option<&str>) -> Result<String, String> {
        let (open, close, list) = members(text)?;
        let found = list.iter().rposition(|m| m.key == key);
        let quoted = serde_json::to_string(key).map_err(|e| e.to_string())?;
        Ok(match (found, value) {
            (Some(at), Some(value)) => {
                let m = &list[at];
                format!("{}{value}{}", &text[..m.value_start], &text[m.value_end..])
            }
            (Some(at), None) => {
                let m = &list[at];
                if let Some(next) = list.get(at + 1) {
                    format!("{}{}", &text[..m.key_start], &text[next.key_start..])
                } else if at > 0 {
                    format!(
                        "{}{}",
                        &text[..list[at - 1].value_end],
                        &text[m.value_end..]
                    )
                } else {
                    format!("{}{}", &text[..=open], &text[close..])
                }
            }
            (None, Some(value)) => match list.last() {
                Some(last) => {
                    let line_start = text[..last.key_start].rfind('\n').map_or(0, |n| n + 1);
                    let indent = &text[line_start..last.key_start];
                    let indent = if indent.trim().is_empty() {
                        indent
                    } else {
                        "  "
                    };
                    format!(
                        "{},\n{indent}{quoted}: {value}{}",
                        &text[..last.value_end],
                        &text[last.value_end..]
                    )
                }
                None => format!(
                    "{}\n  {quoted}: {value}\n{}",
                    &text[..=open],
                    &text[close..]
                ),
            },
            (None, None) => text.to_string(),
        })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn edits_one_member_and_keeps_every_other_byte() {
            let text = "{\n    \"zeta\": [1, {\"a\": \"}\"}],\n    \"statusLine\": {\"command\": \"x\"},\n    \"alpha\": true\n}\n";
            let replaced = set_member(text, "statusLine", Some("{\"command\": \"y\"}")).unwrap();
            assert_eq!(replaced, text.replace("\"x\"", "\"y\""));
            assert_eq!(
                member_value(text, "statusLine").unwrap().as_deref(),
                Some("{\"command\": \"x\"}")
            );
            let removed = set_member(text, "statusLine", None).unwrap();
            assert_eq!(
                removed,
                "{\n    \"zeta\": [1, {\"a\": \"}\"}],\n    \"alpha\": true\n}\n"
            );
            let added = set_member(&removed, "statusLine", Some("1")).unwrap();
            assert_eq!(
                added,
                "{\n    \"zeta\": [1, {\"a\": \"}\"}],\n    \"alpha\": true,\n    \"statusLine\": 1\n}\n"
            );
            let last_removed = set_member(&added, "statusLine", None).unwrap();
            assert_eq!(last_removed, removed);
        }

        #[test]
        fn handles_empty_and_single_member_objects() {
            assert_eq!(
                set_member("{}\n", "k", Some("1")).unwrap(),
                "{\n  \"k\": 1\n}\n"
            );
            let one = "{\"k\": 1}";
            assert_eq!(set_member(one, "k", None).unwrap(), "{}");
            assert!(member_value("[1]", "k").is_err());
            assert_eq!(member_value("{\"a\": \"q\\\"\"}", "k").unwrap(), None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(at: i64, percent: f64) -> ProviderLimits {
        claude_feed::from_status_line(
            &json!({"rate_limits": {"five_hour": {"used_percentage": percent}}}),
            at,
        )
        .unwrap()
    }

    #[test]
    fn a_later_live_reading_beats_a_fetched_one() {
        let mut fetched = reading(100, 10.0);
        fetched.plan = Some("Pro".into());
        let live = reading(200, 20.0);
        let chosen = newest(fetched.clone(), Some(&live));
        assert_eq!(chosen.windows[0].percent, 20.0);
        assert_eq!(chosen.plan.as_deref(), Some("Pro"));
        let older = reading(50, 5.0);
        assert_eq!(newest(fetched, Some(&older)).windows[0].percent, 10.0);
    }

    #[test]
    fn a_control_error_is_a_reason_not_a_reading() {
        let value = json!({"type": "control_response",
            "response": {"subtype": "error", "request_id": "x", "error": "not signed in"}});
        let limits = interpret(&value, 1);
        assert!(!limits.has_reading());
        assert!(limits.note.unwrap().contains("not signed in"));
        let ok = json!({"type": "control_response", "response": {"subtype": "success",
            "request_id": "x", "response": {"rate_limits": {
                "five_hour": {"utilization": 3, "resets_at": null}}}}});
        assert_eq!(interpret(&ok, 1).windows[0].percent, 3.0);
    }
}
