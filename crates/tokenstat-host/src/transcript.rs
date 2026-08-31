// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Readable form of an automation transcript.
//!
//! Headless agent CLIs print NDJSON. The inspector must never see that stream:
//! it is large, it is not written for a person, and putting it in a text view
//! freezes the app. This module turns complete events into short display text
//! while a run drains.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// How much one `automation.transcript` reply may carry.
pub const REPLY_CAP: usize = 64 * 1024;

/// How much readable text to keep on disk for one run.
pub const READABLE_CAP: usize = 256 * 1024;

/// One meaningful thing that happened while an agent was working.
///
/// The automation inspector intentionally still renders these into its compact
/// prose timeline. Chat persists this shape instead, so it can show a tool,
/// an edit, or a cost at the point it actually happened without reparsing a
/// human-oriented transcript later.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    Session {
        id: String,
    },
    Text {
        delta: String,
    },
    Thinking {
        delta: String,
    },
    ToolStart {
        call_id: String,
        verb: String,
        target: String,
        input: Value,
    },
    ToolEnd {
        call_id: String,
        ok: bool,
        detail: Option<String>,
    },
    Edit {
        call_id: String,
        path: String,
        added: u32,
        removed: u32,
        patch: String,
    },
    /// A file the agent explicitly linked in its reply. Chat copies the file
    /// into its own store before emitting this event, so the descriptor works
    /// for remote workspaces and remains valid if the original is moved.
    Attachment {
        id: String,
        name: String,
        #[serde(rename = "mediaType")]
        media_type: Option<String>,
        size: u64,
    },
    Usage {
        input: u64,
        output: u64,
        cache_read: u64,
        cache_write: u64,
        cost_usd: Option<f64>,
    },
    Failed {
        text: String,
    },
    Done {
        status: String,
        exit_code: Option<i32>,
    },
}

enum Piece {
    /// A streamed text delta. Consecutive ones join without a blank line.
    Text(String),
    /// A tool line, an error, or any other standalone paragraph.
    Block(String),
}

/// Incremental NDJSON (or plain) renderer for one backend.
pub struct Parser {
    backend: String,
    leftover: String,
    last_block: String,
    last_was_text: bool,
    /// Tool starts that have not seen a matching end yet. Closed on Done,
    /// Failed, or [`Self::finish_events`], so a cancelled grok call cannot
    /// leave the row spinning after the turn is over.
    open_tools: Vec<String>,
    /// Claude repeats the final assistant text in its `result` record. Keep the
    /// last assistant payload so structured chat events can drop that summary
    /// copy while retaining result-only output from older CLI versions.
    last_claude_assistant: Option<String>,
    /// The session this stream has already reported.
    ///
    /// Some CLIs announce the session once, others stamp it on every line.
    /// Both are fine to parse from, as long as only the first reaches the
    /// caller: a `Session` event writes the conversation index to disk, and
    /// one per line would be one save per line.
    last_session: Option<String>,
}

impl Parser {
    pub fn new(backend: &str) -> Self {
        Self {
            backend: backend.to_string(),
            leftover: String::new(),
            last_block: String::new(),
            last_was_text: false,
            open_tools: Vec::new(),
            last_claude_assistant: None,
            last_session: None,
        }
    }

    /// Consume a drain chunk and return any newly completed display text.
    pub fn push(&mut self, bytes: &[u8]) -> String {
        let incoming = String::from_utf8_lossy(bytes);
        self.leftover.push_str(&incoming);
        let mut out = String::new();
        while let Some(idx) = self.leftover.find('\n') {
            let mut line = self.leftover[..idx].to_string();
            self.leftover = self.leftover[idx + 1..].to_string();
            if line.ends_with('\r') {
                line.pop();
            }
            if let Some(piece) = self.line(&line) {
                self.emit(&mut out, piece);
            }
        }
        out
    }

    /// Consume a drain chunk into structured events.
    ///
    /// This deliberately has its own incremental buffer. A caller chooses
    /// either this API or [`Self::push`] for a stream; chat uses this one while
    /// the existing automation inspector keeps its byte-identical renderer.
    pub fn push_events(&mut self, bytes: &[u8]) -> Vec<Event> {
        let incoming = String::from_utf8_lossy(bytes);
        self.leftover.push_str(&incoming);
        let mut events = Vec::new();
        while let Some(idx) = self.leftover.find('\n') {
            let mut line = self.leftover[..idx].to_string();
            self.leftover = self.leftover[idx + 1..].to_string();
            if line.ends_with('\r') {
                line.pop();
            }
            events.extend(self.line_events(&line));
        }
        events
    }

    /// Flush a final structured event from a line without a trailing newline.
    pub fn finish_events(&mut self) -> Vec<Event> {
        let mut events = if self.leftover.is_empty() {
            Vec::new()
        } else {
            let line = std::mem::take(&mut self.leftover);
            self.line_events(&line)
        };
        events.extend(self.close_open_tools(false, Some("ended".into())));
        events
    }

    /// Treat any leftover partial line as complete. Call when the process
    /// has gone, so a last `printf` without a newline still becomes text.
    pub fn finish(&mut self) -> String {
        if self.leftover.is_empty() {
            return String::new();
        }
        let leftover = std::mem::take(&mut self.leftover);
        let mut out = String::new();
        if let Some(piece) = self.line(&leftover) {
            self.emit(&mut out, piece);
        }
        out
    }

    /// Prefix a paragraph break when the new piece is not a text continuation,
    /// including across drain chunks where `out` starts empty.
    fn emit(&mut self, out: &mut String, piece: Piece) {
        match piece {
            Piece::Text(text) => {
                // Grok sends a lone space between tokens (" ship" + " " +
                // "0.4.0"). Dropping that space glued words. Keep it only
                // when it continues a paragraph already started.
                if text.trim().is_empty() {
                    if self.last_was_text {
                        out.push_str(&text);
                        self.last_block.push_str(&text);
                    }
                    return;
                }
                // Cursor (and some Claude streams) repeat the whole segment
                // after the deltas. Skip that exact copy.
                if text == self.last_block {
                    return;
                }
                if self.last_was_text {
                    out.push_str(&text);
                    self.last_block.push_str(&text);
                } else {
                    append_piece(out, &text, !self.last_block.is_empty());
                    self.last_block = text;
                    self.last_was_text = true;
                }
            }
            Piece::Block(text) => {
                if text == self.last_block {
                    return;
                }
                append_piece(out, &text, !self.last_block.is_empty());
                self.last_block = text;
                self.last_was_text = false;
            }
        }
    }

    fn line(&self, raw: &str) -> Option<Piece> {
        let cleaned = strip_ansi(raw)
            .trim()
            .trim_start_matches('\u{feff}')
            .to_string();
        if cleaned.is_empty() {
            return None;
        }
        if !cleaned.starts_with('{') {
            if self.is_json_backend() {
                // Truncated or escape-polluted JSON must not become the view.
                if cleaned.contains("\"type\":") {
                    return None;
                }
            }
            return Some(Piece::Block(cleaned));
        }
        let value: serde_json::Value = serde_json::from_str(&cleaned).ok()?;
        match self.backend.as_str() {
            "grok" => render_grok(&value),
            "claude" => render_claude_family(&value),
            "cursor" => render_cursor(&value),
            "codex" => render_codex(&value),
            "opencode" | "opencode2" => render_opencode(&value),
            "agy" => render_agy(&value),
            _ => None,
        }
    }

    fn line_events(&mut self, raw: &str) -> Vec<Event> {
        let cleaned = strip_ansi(raw)
            .trim()
            .trim_start_matches('\u{feff}')
            .to_string();
        if cleaned.is_empty() {
            return Vec::new();
        }
        if !cleaned.starts_with('{') {
            let events = if self.is_json_backend() && cleaned.contains("\"type\":") {
                Vec::new()
            } else if let Some(text) = cli_refusal_text(&cleaned) {
                vec![Event::Failed { text }]
            } else {
                vec![Event::Text { delta: cleaned }]
            };
            return self.take_events(events);
        }
        let Ok(value) = serde_json::from_str(&cleaned) else {
            return Vec::new();
        };
        let mut events = events_for_value(&self.backend, &value);
        if self.backend == "claude" {
            match value.get("type").and_then(Value::as_str) {
                Some("assistant") => {
                    if let Some(text) = claude_assistant_text(&value) {
                        self.last_claude_assistant = Some(text);
                    }
                }
                Some("result") => {
                    if let Some(repeated) = self.last_claude_assistant.as_deref() {
                        events.retain(
                            |event| !matches!(event, Event::Text { delta } if delta == repeated),
                        );
                    }
                }
                _ => {}
            }
        }
        self.take_events(events)
    }

    fn take_events(&mut self, events: Vec<Event>) -> Vec<Event> {
        let mut out = Vec::with_capacity(events.len() + self.open_tools.len());
        for event in events {
            match &event {
                Event::Session { id } => {
                    if self.last_session.as_deref() == Some(id.as_str()) {
                        continue;
                    }
                    self.last_session = Some(id.clone());
                    out.push(event);
                }
                Event::ToolStart { call_id, .. } => {
                    if !self.open_tools.iter().any(|id| id == call_id) {
                        self.open_tools.push(call_id.clone());
                    }
                    out.push(event);
                }
                Event::ToolEnd { call_id, .. } => {
                    self.open_tools.retain(|id| id != call_id);
                    out.push(event);
                }
                Event::Done { status, .. } => {
                    let cancelled = matches!(status.as_str(), "cancelled" | "canceled" | "error");
                    out.extend(
                        self.close_open_tools(!cancelled, cancelled.then(|| status.clone())),
                    );
                    // A backend's stream ending is not the process outcome.
                    // In particular, grok reports `cancelled` when one of its
                    // own tool calls is refused even though the process exits
                    // successfully. The chat drain observes the real exit and
                    // writes the conversation's single terminal Done event.
                }
                Event::Failed { text } => {
                    out.extend(self.close_open_tools(false, Some(text.clone())));
                    out.push(event);
                }
                _ => out.push(event),
            }
        }
        out
    }

    fn close_open_tools(&mut self, ok: bool, detail: Option<String>) -> Vec<Event> {
        std::mem::take(&mut self.open_tools)
            .into_iter()
            .map(|call_id| Event::ToolEnd {
                call_id,
                ok,
                detail: detail.clone(),
            })
            .collect()
    }

    fn is_json_backend(&self) -> bool {
        matches!(
            self.backend.as_str(),
            "grok" | "claude" | "cursor" | "codex" | "opencode" | "opencode2" | "agy"
        )
    }
}

/// Headless CLIs print a refusal as plain text, not NDJSON. That is a failed
/// turn, not the agent talking. Keep the original line unless it is one of
/// the two refusals we have copy for.
fn cli_refusal_text(line: &str) -> Option<String> {
    let lower = line.to_ascii_lowercase();
    if lower.contains("please run /login") {
        return Some(
            "Claude Code is not signed in on this Mac. Open a terminal, run claude, and use /login."
                .into(),
        );
    }
    if lower.contains("named models unavailable") || lower.contains("free plans can only use auto")
    {
        return Some("This Cursor plan can only use Auto.".into());
    }
    if lower.starts_with("error:") || lower.contains("actionrequirederror") {
        return Some(line.to_string());
    }
    None
}

/// Decode one complete backend record. Keep this vocabulary here: the
/// automation renderer and chat must agree on what a `Read` or `Edit` means.
fn events_for_value(backend: &str, value: &Value) -> Vec<Event> {
    let events = match backend {
        "grok" => events_grok(value),
        "claude" => events_claude(value),
        "cursor" => events_cursor(value),
        "codex" => events_codex(value),
        "opencode" | "opencode2" => events_opencode(value),
        "agy" => events_agy(value),
        _ => Vec::new(),
    };
    events
        .into_iter()
        .flat_map(|event| {
            let edit = match &event {
                Event::ToolStart {
                    call_id,
                    target,
                    input,
                    ..
                } => edit_event(call_id, target, input),
                _ => None,
            };
            std::iter::once(event).chain(edit).collect::<Vec<_>>()
        })
        .collect()
}

fn edit_event(call_id: &str, target: &str, input: &Value) -> Option<Event> {
    let old = lookup_str(input, &["old_string", "old_str", "OldString", "OldStr"])?;
    let new = lookup_str(input, &["new_string", "new_str", "NewString", "NewStr"])?;
    if old.is_empty() && new.is_empty() {
        return None;
    }
    Some(Event::Edit {
        call_id: call_id.to_string(),
        path: target.to_string(),
        added: new.lines().count() as u32,
        removed: old.lines().count() as u32,
        patch: render_edit_snippet(old, new),
    })
}

fn events_grok(value: &Value) -> Vec<Event> {
    match value.get("type").and_then(Value::as_str) {
        Some("text") => event_text(value.get("data").and_then(Value::as_str)),
        Some("thought") => event_thinking(value.get("data").and_then(Value::as_str)),
        Some("tool_call") => vec![tool_start(
            value,
            value
                .get("title")
                .and_then(Value::as_str)
                .or_else(|| value.get("toolName").and_then(Value::as_str))
                .unwrap_or("tool"),
            value.get("rawInput").cloned().unwrap_or(Value::Null),
        )],
        Some("tool_call_update") => events_grok_tool_update(value),
        Some("error") => event_failed(value.get("message").and_then(Value::as_str)),
        Some("usage") => event_usage(value),
        Some("end") => vec![done(
            value
                .get("stopReason")
                .and_then(Value::as_str)
                .unwrap_or("done"),
            None,
        )],
        _ => Vec::new(),
    }
}

fn events_grok_tool_update(value: &Value) -> Vec<Event> {
    let status = value.get("status").and_then(Value::as_str).unwrap_or("");
    if status.is_empty() {
        return Vec::new();
    }
    let ok = matches!(
        status,
        "completed" | "complete" | "success" | "succeeded" | "ok"
    );
    let failed = matches!(status, "failed" | "error" | "cancelled" | "canceled");
    if !ok && !failed {
        return Vec::new();
    }
    vec![Event::ToolEnd {
        call_id: item_id(value),
        ok,
        detail: grok_tool_detail(value),
    }]
}

fn grok_tool_detail(value: &Value) -> Option<String> {
    value
        .get("rawOutput")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| {
            value
                .pointer("/content/0/content/text")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        })
        .or_else(|| {
            value
                .pointer("/content/0/text")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        })
        .or_else(|| {
            value
                .get("error")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        })
}

fn events_claude(value: &Value) -> Vec<Event> {
    let kind = value.get("type").and_then(Value::as_str);
    if kind == Some("system") && value.get("subtype").and_then(Value::as_str) == Some("init") {
        return value
            .get("session_id")
            .and_then(Value::as_str)
            .map(|id| vec![Event::Session { id: id.into() }])
            .unwrap_or_default();
    }
    if kind == Some("assistant") {
        let content = value
            .pointer("/message/content")
            .or_else(|| value.get("content"));
        return content
            .and_then(Value::as_array)
            .map(|blocks| {
                blocks
                    .iter()
                    .flat_map(|block| match block.get("type").and_then(Value::as_str) {
                        Some("text") => event_text(block.get("text").and_then(Value::as_str)),
                        Some("thinking") => {
                            event_thinking(block.get("thinking").and_then(Value::as_str))
                        }
                        Some("tool_use") => vec![tool_start(
                            block,
                            block.get("name").and_then(Value::as_str).unwrap_or("tool"),
                            block.get("input").cloned().unwrap_or(Value::Null),
                        )],
                        _ => Vec::new(),
                    })
                    .collect()
            })
            .unwrap_or_default();
    }
    if kind == Some("result") {
        let mut events = event_text(value.get("result").and_then(Value::as_str));
        events.extend(event_usage(value));
        events.push(done(
            value
                .get("subtype")
                .and_then(Value::as_str)
                .unwrap_or("done"),
            value.get("exit_code").and_then(json_i32),
        ));
        return events;
    }
    Vec::new()
}

fn claude_assistant_text(value: &Value) -> Option<String> {
    let text = value
        .pointer("/message/content")
        .or_else(|| value.get("content"))?
        .as_array()?
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect::<String>();
    (!text.is_empty()).then_some(text)
}

fn events_cursor(value: &Value) -> Vec<Event> {
    match value.get("type").and_then(Value::as_str) {
        Some("assistant") => assistant_event_text(value),
        Some("result") => {
            let mut events = event_text(value.get("result").and_then(Value::as_str));
            events.push(done("done", value.get("exit_code").and_then(json_i32)));
            events
        }
        Some("tool_call") => {
            let subtype = value
                .get("subtype")
                .and_then(Value::as_str)
                .unwrap_or("started");
            let Some((name, call)) = value
                .get("tool_call")
                .and_then(Value::as_object)
                .and_then(|calls| calls.iter().next())
            else {
                return Vec::new();
            };
            let id = call
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or(name)
                .to_string();
            if subtype == "started" {
                vec![tool_start_with_id(
                    &id,
                    name,
                    call.get("args").cloned().unwrap_or(Value::Null),
                )]
            } else {
                vec![Event::ToolEnd {
                    call_id: id,
                    ok: subtype != "failed",
                    detail: call
                        .get("error")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                }]
            }
        }
        Some("error") => event_failed(value.get("message").and_then(Value::as_str)),
        _ => Vec::new(),
    }
}

fn events_codex(value: &Value) -> Vec<Event> {
    let kind = value.get("type").and_then(Value::as_str).unwrap_or("");
    if matches!(kind, "thread.started" | "thread_id") {
        return value
            .get("thread_id")
            .or_else(|| value.get("id"))
            .and_then(Value::as_str)
            .map(|id| vec![Event::Session { id: id.into() }])
            .unwrap_or_default();
    }
    let item = value.get("item");
    if kind == "item.started" {
        let Some(item) = item else { return Vec::new() };
        return match item.get("type").and_then(Value::as_str) {
            Some("command_execution") => vec![tool_start(
                item,
                "shell",
                serde_json::json!({"command": item.get("command").and_then(Value::as_str).unwrap_or("")}),
            )],
            _ => Vec::new(),
        };
    }
    if kind == "item.completed" {
        let Some(item) = item else { return Vec::new() };
        return match item.get("type").and_then(Value::as_str) {
            Some("agent_message" | "message" | "text") => event_text(
                item.get("text")
                    .and_then(Value::as_str)
                    .or_else(|| item.get("content").and_then(Value::as_str)),
            ),
            Some("command_execution") => vec![Event::ToolEnd {
                call_id: item_id(item),
                ok: item.get("exit_code").and_then(json_i32).unwrap_or(0) == 0,
                detail: item
                    .get("aggregated_output")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            }],
            _ => Vec::new(),
        };
    }
    if kind == "turn.completed" {
        return vec![done("done", None)];
    }
    if kind == "error" {
        return event_failed(value.get("message").and_then(Value::as_str));
    }
    Vec::new()
}

fn events_opencode(value: &Value) -> Vec<Event> {
    // Every line carries `sessionID`, and there is no `session` line at all,
    // so waiting for one meant never learning the session and re-briefing a
    // fresh agent on every turn. Read it from wherever it appears; the parser
    // reports a session once and then stays quiet about it.
    let session = value
        .pointer("/session/id")
        .or_else(|| value.get("sessionID"))
        .and_then(Value::as_str)
        .map(|id| Event::Session { id: id.into() });
    let mut events: Vec<Event> = session.into_iter().collect();
    events.extend(match value.get("type").and_then(Value::as_str) {
        Some("session") | Some("session.created") => Vec::new(),
        Some("text") => event_text(
            value
                .pointer("/part/text")
                .and_then(Value::as_str)
                .or_else(|| value.get("text").and_then(Value::as_str)),
        ),
        Some("tool_use") => {
            let part = value.get("part").unwrap_or(value);
            let input = part
                .get("input")
                .or_else(|| part.get("args"))
                .or_else(|| part.pointer("/state/input"))
                .cloned()
                .unwrap_or(Value::Null);
            let id = item_id(part);
            let status = part
                .pointer("/state/status")
                .and_then(Value::as_str)
                .unwrap_or("running");
            if matches!(status, "completed" | "error" | "failed") {
                vec![Event::ToolEnd {
                    call_id: id,
                    ok: status == "completed",
                    detail: part
                        .pointer("/state/output")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                }]
            } else {
                vec![tool_start_with_id(
                    &id,
                    part.get("tool").and_then(Value::as_str).unwrap_or("tool"),
                    input,
                )]
            }
        }
        Some("error") => event_failed(
            value
                .pointer("/error/message")
                .and_then(Value::as_str)
                .or_else(|| value.get("error").and_then(Value::as_str)),
        ),
        Some("step_finish") => vec![done(
            value
                .pointer("/part/reason")
                .and_then(Value::as_str)
                .unwrap_or("done"),
            None,
        )],
        _ => Vec::new(),
    });
    events
}

fn events_agy(value: &Value) -> Vec<Event> {
    match value.get("event").and_then(Value::as_str) {
        // The id sits beside `init`, not inside it:
        // `{"event":"init","conversation_id":"…","init":{"cwd":…}}`. It was
        // read from inside only, so no conversation ever recorded a resume
        // token, `--conversation` was never passed, and every turn started an
        // agent with no memory that then had to be handed the whole summary
        // again. Both shapes are accepted, because one of them is what the
        // fixture and an older CLI say.
        Some("init") => value
            .get("conversation_id")
            .or_else(|| value.get("session_id"))
            .or_else(|| value.pointer("/init/conversation_id"))
            .or_else(|| value.pointer("/init/session_id"))
            .and_then(Value::as_str)
            .map(|id| vec![Event::Session { id: id.into() }])
            .unwrap_or_default(),
        Some("step_update") => {
            let Some(step) = value.get("step_update") else {
                return Vec::new();
            };
            match step.get("step_type").and_then(Value::as_str) {
                Some("agent_response") => {
                    event_text(step.get("text_delta").and_then(Value::as_str))
                }
                Some("tool") => {
                    let id = item_id(step);
                    let state = step
                        .get("state")
                        .and_then(Value::as_str)
                        .unwrap_or("ACTIVE");
                    if state == "ACTIVE" {
                        let name = step
                            .get("tool_name")
                            .and_then(Value::as_str)
                            .or_else(|| step.pointer("/tool_info/name").and_then(Value::as_str))
                            .unwrap_or("tool");
                        vec![tool_start_with_id(
                            &id,
                            name,
                            step.pointer("/tool_info/parameters")
                                .cloned()
                                .unwrap_or(Value::Null),
                        )]
                    } else {
                        vec![Event::ToolEnd {
                            call_id: id,
                            ok: state != "ERROR",
                            detail: step
                                .pointer("/tool_info/error")
                                .and_then(Value::as_str)
                                .map(str::to_string),
                        }]
                    }
                }
                _ => Vec::new(),
            }
        }
        Some("result") => {
            let result = value.get("result").unwrap_or(value);
            let status = result
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("done");
            if status.eq_ignore_ascii_case("error") {
                event_failed(
                    result
                        .get("error")
                        .and_then(Value::as_str)
                        .or_else(|| result.get("response").and_then(Value::as_str)),
                )
            } else {
                vec![done(status, None)]
            }
        }
        _ => Vec::new(),
    }
}

fn tool_start(source: &Value, name: &str, input: Value) -> Event {
    tool_start_with_id(&item_id(source), name, input)
}
fn tool_start_with_id(id: &str, name: &str, input: Value) -> Event {
    let target = tool_arg(Some(&input)).unwrap_or("").to_string();
    Event::ToolStart {
        call_id: id.to_string(),
        verb: display_verb(name),
        target,
        input,
    }
}
fn item_id(value: &Value) -> String {
    value
        .get("id")
        .or_else(|| value.get("call_id"))
        .or_else(|| value.get("tool_call_id"))
        .or_else(|| value.get("toolCallId"))
        .and_then(Value::as_str)
        .unwrap_or("tool")
        .to_string()
}
fn event_text(text: Option<&str>) -> Vec<Event> {
    nonempty(text)
        .map(|delta| vec![Event::Text { delta }])
        .unwrap_or_default()
}
fn event_thinking(text: Option<&str>) -> Vec<Event> {
    nonempty(text)
        .map(|delta| vec![Event::Thinking { delta }])
        .unwrap_or_default()
}
fn event_failed(text: Option<&str>) -> Vec<Event> {
    nonempty(text)
        .map(|text| vec![Event::Failed { text }])
        .unwrap_or_default()
}
fn done(status: &str, exit_code: Option<i32>) -> Event {
    Event::Done {
        status: status.to_string(),
        exit_code,
    }
}
fn assistant_event_text(value: &Value) -> Vec<Event> {
    value
        .pointer("/message/content")
        .or_else(|| value.get("content"))
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .flat_map(|block| event_text(block.get("text").and_then(Value::as_str)))
                .collect()
        })
        .unwrap_or_default()
}
fn event_usage(value: &Value) -> Vec<Event> {
    let usage = value.get("usage").unwrap_or(value);
    let input = usage
        .get("input_tokens")
        .or_else(|| usage.get("inputTokens"))
        .and_then(Value::as_u64);
    let output = usage
        .get("output_tokens")
        .or_else(|| usage.get("outputTokens"))
        .and_then(Value::as_u64);
    if input.is_none() && output.is_none() {
        return Vec::new();
    }
    vec![Event::Usage {
        input: input.unwrap_or(0),
        output: output.unwrap_or(0),
        cache_read: usage
            .get("cache_read_input_tokens")
            .or_else(|| usage.get("cacheReadTokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        cache_write: usage
            .get("cache_creation_input_tokens")
            .or_else(|| usage.get("cacheWriteTokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        cost_usd: usage
            .get("cost_usd")
            .or_else(|| usage.get("cost"))
            .and_then(Value::as_f64),
    }]
}
fn json_i32(value: &Value) -> Option<i32> {
    value
        .as_i64()
        .and_then(|n| i32::try_from(n).ok())
        .or_else(|| value.as_u64().and_then(|n| i32::try_from(n).ok()))
}

/// Walk a whole raw transcript into readable text, then cap it.
pub fn render_raw(backend: &str, raw: &[u8]) -> String {
    let mut parser = Parser::new(backend);
    let mut out = parser.push(raw);
    out.push_str(&parser.finish());
    cap_readable(&mut out);
    out
}

/// True when `bytes` look like an agent NDJSON stream, not prose.
pub fn looks_like_ndjson(bytes: &[u8]) -> bool {
    let start = bytes.iter().position(|b| !b.is_ascii_whitespace());
    let Some(i) = start else {
        return false;
    };
    if bytes[i] != b'{' {
        return false;
    }
    let sample = &bytes[i..bytes.len().min(i + 512)];
    sample.windows(7).any(|w| w == b"\"type\":") || sample.windows(8).any(|w| w == b"\"event\":")
}

/// Rebuild `{run}.readable.txt` from the raw file.
///
/// Old runs predate drain-time parsing. Serving that raw file to a text view
/// freezes the app. Never call this on a live drain that is still writing
/// incrementally unless the readable sibling is absent. `force` overwrites
/// a file that already exists, used when that file is the raw NDJSON stream
/// under the wrong name.
///
/// Returns the rendered prose when the raw file was read, even if writing
/// the sibling failed. `None` when there was nothing to rebuild.
pub fn rematerialize(raw: &Path, backend: &str, force: bool) -> Option<String> {
    let readable = readable_path(raw);
    if !raw.is_file() {
        return None;
    }
    let stale = !readable.is_file()
        || std::fs::metadata(&readable)
            .map(|m| m.len() == 0)
            .unwrap_or(true);
    if !force && !stale {
        return None;
    }
    let Ok(bytes) = std::fs::read(raw) else {
        return None;
    };
    let text = render_raw(backend, &bytes);
    let _ = std::fs::write(&readable, text.as_bytes());
    Some(text)
}

/// Sibling of the raw transcript that the inspector tails.
pub fn readable_path(raw: &Path) -> PathBuf {
    raw.with_extension("readable.txt")
}

/// Drop the oldest paragraphs so `text` stays within [`READABLE_CAP`].
pub fn cap_readable(text: &mut String) {
    if text.len() <= READABLE_CAP {
        return;
    }
    let mut start = text.len() - READABLE_CAP;
    while start < text.len() && !text.is_char_boundary(start) {
        start += 1;
    }
    let cut = text[start..]
        .find('\n')
        .map(|i| start + i + 1)
        .unwrap_or(start);
    text.replace_range(..cut, "");
}

/// Slice a transcript file for one RPC reply.
pub fn slice_reply(bytes: &[u8], offset: u64) -> (String, u64) {
    let start = (offset as usize).min(bytes.len());
    let mut end = (start + REPLY_CAP).min(bytes.len());
    while end > start && !is_char_boundary(bytes, end) {
        end -= 1;
    }
    let text = String::from_utf8_lossy(&bytes[start..end]).into_owned();
    (text, end as u64)
}

fn is_char_boundary(bytes: &[u8], index: usize) -> bool {
    index == bytes.len() || (bytes[index] as i8) >= -0x40
}

/// Join a new paragraph. `had_prior` is true when a previous `push` already
/// emitted something, so a drain chunk that starts a block still gets a break.
fn append_piece(out: &mut String, piece: &str, had_prior: bool) {
    if piece.is_empty() {
        return;
    }
    if !out.is_empty() || had_prior {
        out.push_str("\n\n");
    }
    out.push_str(piece);
}

fn render_grok(value: &serde_json::Value) -> Option<Piece> {
    let kind = value.get("type")?.as_str()?;
    match kind {
        "text" => text_delta(value.get("data").and_then(|v| v.as_str())).map(Piece::Text),
        "error" => nonempty(value.get("message").and_then(|v| v.as_str())).map(Piece::Block),
        "tool_call" => {
            let title = value
                .get("title")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .or_else(|| value.get("toolName").and_then(|v| v.as_str()))
                .unwrap_or("tool");
            Some(Piece::Block(format_tool(
                &display_verb(title),
                value.get("rawInput"),
            )))
        }
        "tool_call_update" => {
            let status = value.get("status").and_then(|v| v.as_str()).unwrap_or("");
            if !matches!(status, "failed" | "error" | "cancelled" | "canceled") {
                return None;
            }
            grok_tool_detail(value).map(Piece::Block)
        }
        _ => None,
    }
}

fn render_claude_family(value: &serde_json::Value) -> Option<Piece> {
    let kind = value.get("type")?.as_str()?;
    match kind {
        "assistant" => {
            let (tools, texts) = assistant_split(value);
            match (tools.is_empty(), texts.is_empty()) {
                (true, true) => None,
                (false, true) => Some(Piece::Block(tools.join("\n\n"))),
                (true, false) => Some(Piece::Text(texts.join("\n"))),
                (false, false) => Some(Piece::Block(format!(
                    "{}\n\n{}",
                    tools.join("\n\n"),
                    texts.join("\n")
                ))),
            }
        }
        "result" => nonempty(value.get("result").and_then(|v| v.as_str())).map(Piece::Text),
        _ => None,
    }
}

fn render_cursor(value: &serde_json::Value) -> Option<Piece> {
    let kind = value.get("type")?.as_str()?;
    match kind {
        "assistant" => assistant_texts(value).map(Piece::Text),
        "result" => nonempty(value.get("result").and_then(|v| v.as_str())).map(Piece::Text),
        "tool_call" => {
            // Only the start of a call. The completed event is the same name
            // again and would double every tool in the inspector.
            let subtype = value.get("subtype").and_then(|v| v.as_str()).unwrap_or("");
            if !subtype.is_empty() && subtype != "started" {
                return None;
            }
            let map = value.get("tool_call")?.as_object()?;
            let (key, call) = map.iter().next()?;
            let title = display_verb(&tool_label(key));
            Some(Piece::Block(format_tool(&title, call.get("args"))))
        }
        _ => None,
    }
}

fn render_codex(value: &serde_json::Value) -> Option<Piece> {
    let kind = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if kind == "item.completed" {
        let item = value.get("item")?;
        let item_type = item.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if matches!(item_type, "agent_message" | "message" | "text") {
            return nonempty(
                item.get("text")
                    .and_then(|v| v.as_str())
                    .or_else(|| item.get("content").and_then(|v| v.as_str())),
            )
            .map(Piece::Text);
        }
        if item_type == "command_execution" {
            let command = item
                .get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("shell");
            let one_line = command.lines().next().unwrap_or(command);
            return Some(Piece::Block(format!("Shell {one_line}")));
        }
        return None;
    }
    if kind == "message" && value.get("role").and_then(|v| v.as_str()) == Some("assistant") {
        if let Some(text) = value.get("text").and_then(|v| v.as_str()) {
            return nonempty(Some(text)).map(Piece::Text);
        }
        return assistant_texts(value).map(Piece::Text);
    }
    if kind == "agent_message" {
        return nonempty(value.get("text").and_then(|v| v.as_str())).map(Piece::Text);
    }
    None
}

/// Antigravity `--output-format stream-json`. Tools are `step_update`
/// with `step_type: tool`. Text arrives as `text_delta` on
/// `agent_response`. A successful `result` repeats that text, so it is
/// dropped. An ERROR result is the only place a failed launch is explained.
fn render_agy(value: &serde_json::Value) -> Option<Piece> {
    let event = value.get("event")?.as_str()?;
    match event {
        "step_update" => {
            let step = value.get("step_update")?;
            let kind = step.get("step_type").and_then(|v| v.as_str()).unwrap_or("");
            match kind {
                "tool" => {
                    // ACTIVE and DONE are the same call. Emit once, when it
                    // starts, so the inspector does not double every row.
                    let state = step.get("state").and_then(|v| v.as_str()).unwrap_or("");
                    if state != "ACTIVE" {
                        return None;
                    }
                    let name = step
                        .get("tool_name")
                        .and_then(|v| v.as_str())
                        .or_else(|| {
                            step.get("tool_info")
                                .and_then(|info| info.get("name"))
                                .and_then(|v| v.as_str())
                        })
                        .unwrap_or("tool");
                    let params = step
                        .get("tool_info")
                        .and_then(|info| info.get("parameters"));
                    Some(Piece::Block(stamp(
                        event_timestamp(value).or_else(|| event_timestamp(step)),
                        format_tool(&display_verb(name), params),
                    )))
                }
                "agent_response" => {
                    text_delta(step.get("text_delta").and_then(|v| v.as_str())).map(Piece::Text)
                }
                _ => None,
            }
        }
        "result" => {
            let result = value.get("result")?;
            let status = result.get("status").and_then(|v| v.as_str()).unwrap_or("");
            if !status.eq_ignore_ascii_case("ERROR") && !status.eq_ignore_ascii_case("error") {
                return None;
            }
            let err = result
                .get("error")
                .and_then(|v| v.as_str())
                .or_else(|| result.get("response").and_then(|v| v.as_str()))
                .unwrap_or("the run failed");
            nonempty(Some(err)).map(|text| {
                Piece::Block(stamp(
                    event_timestamp(value).or_else(|| event_timestamp(result)),
                    text,
                ))
            })
        }
        _ => None,
    }
}

fn render_opencode(value: &serde_json::Value) -> Option<Piece> {
    let kind = value.get("type")?.as_str()?;
    match kind {
        "text" => nonempty(
            value
                .get("part")
                .and_then(|p| p.get("text"))
                .and_then(|v| v.as_str())
                .or_else(|| value.get("text").and_then(|v| v.as_str())),
        )
        .map(Piece::Text),
        "tool_use" => {
            let part = value.get("part").unwrap_or(value);
            let tool = part.get("tool").and_then(|v| v.as_str()).unwrap_or("tool");
            let input = part
                .get("input")
                .or_else(|| part.get("args"))
                .or_else(|| part.pointer("/state/input"))
                .or_else(|| part.get("state"));
            let mut body = format_tool(&display_verb(tool), input);
            if body
                .split_once(' ')
                .map(|(_, a)| a.trim().is_empty())
                .unwrap_or(true)
            {
                if let Some(title) = part
                    .pointer("/state/title")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                {
                    body = format!("{} {title}", display_verb(tool));
                }
            }
            if let Some(out) = part.pointer("/state/output").and_then(|v| v.as_str()) {
                let snippet = output_snippet(out);
                if !snippet.is_empty() {
                    body.push('\n');
                    body.push_str(&snippet);
                }
            }
            Some(Piece::Block(stamp(event_timestamp(value), body)))
        }
        "error" => {
            let msg = match value.get("error") {
                Some(serde_json::Value::String(s)) => s.clone(),
                Some(obj) => obj
                    .get("message")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                None => String::new(),
            };
            nonempty(Some(&msg)).map(Piece::Block)
        }
        _ => None,
    }
}

/// One display paragraph for a tool: `Verb path`, plus an optional short
/// `+/-` snippet when the call carried old and new text.
fn format_tool(verb: &str, input: Option<&serde_json::Value>) -> String {
    let arg = tool_arg(input);
    let mut out = match arg {
        Some(a) => format!("{verb} {a}"),
        None => verb.to_string(),
    };
    if let Some(snip) = edit_snippet(input) {
        out.push('\n');
        out.push_str(&snip);
    }
    out
}

fn tool_arg(input: Option<&serde_json::Value>) -> Option<&str> {
    let value = input?;
    const KEYS: [&str; 14] = [
        "path",
        "file_path",
        "filePath",
        "file",
        "target_file",
        "target_directory",
        "command",
        "pattern",
        "query",
        // Antigravity stream-json uses PascalCase.
        "TargetFile",
        "AbsolutePath",
        "CommandLine",
        "FilePath",
        "Command",
    ];
    lookup_str(value, &KEYS)
}

fn lookup_str<'a>(value: &'a serde_json::Value, keys: &[&str]) -> Option<&'a str> {
    for key in keys {
        if let Some(s) = value
            .get(*key)
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            return Some(s);
        }
    }
    let obj = value.as_object()?;
    let wanted: Vec<String> = keys.iter().map(|k| fold_key(k)).collect();
    for (key, val) in obj {
        if wanted.iter().any(|want| want == &fold_key(key)) {
            if let Some(s) = val.as_str().filter(|s| !s.is_empty()) {
                return Some(s);
            }
        }
    }
    None
}

/// `filePath`, `file_path`, and `FilePath` are the same key.
fn fold_key(key: &str) -> String {
    key.chars()
        .filter(|c| *c != '_')
        .flat_map(|c| c.to_lowercase())
        .collect()
}

fn event_timestamp(value: &serde_json::Value) -> Option<i64> {
    value
        .get("timestamp")
        .and_then(json_i64)
        .or_else(|| value.get("time").and_then(json_i64))
}

fn json_i64(value: &serde_json::Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().map(|n| n as i64))
        .or_else(|| value.as_f64().map(|n| n as i64))
}

/// Prefix a tool/error line with `HH:MM:SS` when the event carried a time.
fn stamp(ts_ms: Option<i64>, body: String) -> String {
    match ts_ms.and_then(format_clock) {
        Some(clock) => format!("{clock} {body}"),
        None => body,
    }
}

fn format_clock(ms: i64) -> Option<String> {
    let ts = jiff::Timestamp::from_millisecond(ms).ok()?;
    let zoned = ts.to_zoned(jiff::tz::TimeZone::system());
    Some(format!(
        "{:02}:{:02}:{:02}",
        zoned.hour(),
        zoned.minute(),
        zoned.second()
    ))
}

/// First lines of a tool's stdout, marked so the inspector can fold them.
fn output_snippet(out: &str) -> String {
    const MAX_LINES: usize = 8;
    const MAX_CHARS: usize = 2000;
    let lines: Vec<&str> = out.lines().collect();
    if lines.is_empty() || out.trim().is_empty() {
        return String::new();
    }
    let mut out_lines: Vec<String> = lines
        .iter()
        .take(MAX_LINES)
        .map(|line| format!("| {line}"))
        .collect();
    if lines.len() > MAX_LINES {
        out_lines.push("| …".into());
    }
    let mut text = out_lines.join("\n");
    if text.len() > MAX_CHARS {
        let mut end = MAX_CHARS;
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

fn edit_snippet(input: Option<&serde_json::Value>) -> Option<String> {
    let value = input?;
    let old = lookup_str(value, &["old_string", "old_str", "OldString", "OldStr"])?;
    let new = lookup_str(value, &["new_string", "new_str", "NewString", "NewStr"])?;
    if old.is_empty() && new.is_empty() {
        return None;
    }
    Some(render_edit_snippet(old, new))
}

/// Cap a preview so the inspector stays a timeline, not a dump of the file.
fn render_edit_snippet(old: &str, new: &str) -> String {
    const MAX_EACH: usize = 6;
    const MAX_CHARS: usize = 2000;
    let mut lines: Vec<String> = Vec::new();
    let old_lines: Vec<&str> = old.lines().collect();
    let new_lines: Vec<&str> = new.lines().collect();
    for line in old_lines.iter().take(MAX_EACH) {
        lines.push(format!("- {line}"));
    }
    if old_lines.len() > MAX_EACH {
        lines.push("- …".into());
    }
    for line in new_lines.iter().take(MAX_EACH) {
        lines.push(format!("+ {line}"));
    }
    if new_lines.len() > MAX_EACH {
        lines.push("+ …".into());
    }
    let mut out = lines.join("\n");
    if out.len() > MAX_CHARS {
        let mut end = MAX_CHARS;
        while end > 0 && !out.is_char_boundary(end) {
            end -= 1;
        }
        out.truncate(end);
    }
    out
}

/// Canonical inspector verb. Grok titles are snake_case (`read_file`);
/// Claude already sends `Read`. The Swift timeline matches these words.
fn display_verb(name: &str) -> String {
    let leaf = name
        .rsplit("__")
        .next()
        .unwrap_or(name)
        .trim_end_matches("ToolCall");
    match leaf {
        "read_file" | "Read" | "read" | "view_file" | "view_file_outline" | "view_code_item" => {
            "Read".into()
        }
        "write" | "Write" | "write_file" | "write_to_file" | "create_file" => "Write".into(),
        "search_replace"
        | "Edit"
        | "edit"
        | "str_replace"
        | "edit_file"
        | "replace_file_content"
        | "NotebookEdit" => "Edit".into(),
        "run_terminal_command" | "run_command" | "shell_exec" => "Shell".into(),
        "Bash" | "bash" => "Bash".into(),
        "Shell" | "shell" => "Shell".into(),
        "grep" | "Grep" | "grep_search" | "code_search" => "Grep".into(),
        "list_dir" | "list_directory" | "Glob" | "glob" | "find_by_name" => "Glob".into(),
        "WebFetch" | "web_fetch" | "read_url_content" => "WebFetch".into(),
        "WebSearch" | "web_search" | "search_web" => "WebSearch".into(),
        "TodoWrite" | "todo_write" => "TodoWrite".into(),
        "get_command_or_subagent_output" | "Task" | "task" => "Subagent".into(),
        other if other.contains('_') => other
            .split('_')
            .filter(|part| !part.is_empty())
            .map(|part| {
                let mut chars = part.chars();
                match chars.next() {
                    Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
        other => tool_label(other),
    }
}

fn text_delta(s: Option<&str>) -> Option<String> {
    s.filter(|s| !s.is_empty()).map(str::to_string)
}

fn tool_label(name: &str) -> String {
    let base = name.trim_end_matches("ToolCall");
    if base.is_empty() {
        return "Tool".into();
    }
    let mut chars = base.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => "Tool".into(),
    }
}

fn assistant_texts(value: &serde_json::Value) -> Option<String> {
    let (tools, texts) = assistant_split(value);
    let mut parts = tools;
    parts.extend(texts);
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n"))
    }
}

fn assistant_split(value: &serde_json::Value) -> (Vec<String>, Vec<String>) {
    let content = value
        .get("message")
        .and_then(|m| m.get("content"))
        .or_else(|| value.get("content"));
    let mut tools: Vec<String> = Vec::new();
    let mut texts: Vec<String> = Vec::new();
    match content {
        Some(serde_json::Value::Array(blocks)) => {
            for block in blocks {
                let kind = block.get("type").and_then(|v| v.as_str()).unwrap_or("");
                if kind == "tool_use" {
                    if let Some(name) = block.get("name").and_then(|v| v.as_str()) {
                        tools.push(format_tool(&display_verb(name), block.get("input")));
                    }
                    continue;
                }
                if let Some(text) = block.get("text").and_then(|v| v.as_str()) {
                    if !text.is_empty() {
                        texts.push(text.to_string());
                    }
                }
            }
        }
        Some(serde_json::Value::String(s)) if !s.is_empty() => texts.push(s.clone()),
        _ => {}
    }
    (tools, texts)
}

fn nonempty(s: Option<&str>) -> Option<String> {
    // Keep leading and trailing spaces. Grok (and others) send text as
    // word-sized deltas ("I'll", " start") and trim would glue them.
    s.filter(|s| !s.trim().is_empty()).map(str::to_string)
}

/// Strip CSI and similar cursor sequences the pty can interleave.
pub fn strip_ansi(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
            i += 2;
            while i < bytes.len() {
                let b = bytes[i];
                i += 1;
                if b.is_ascii_alphabetic() {
                    break;
                }
            }
            continue;
        }
        let rest = &text[i..];
        let ch = rest.chars().next().unwrap_or('\u{fffd}');
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(backend: &str, raw: &str) -> String {
        let mut p = Parser::new(backend);
        p.push(raw.as_bytes())
    }

    #[test]
    fn recorded_backend_streams_keep_the_events_chat_needs() {
        let fixtures = [
            (
                "claude",
                include_str!("../../../fixtures/chat/claude.ndjson"),
            ),
            ("codex", include_str!("../../../fixtures/chat/codex.ndjson")),
            ("grok", include_str!("../../../fixtures/chat/grok.ndjson")),
            (
                "cursor",
                include_str!("../../../fixtures/chat/cursor.ndjson"),
            ),
            ("agy", include_str!("../../../fixtures/chat/agy.ndjson")),
            (
                "opencode",
                include_str!("../../../fixtures/chat/opencode.ndjson"),
            ),
            (
                "opencode2",
                include_str!("../../../fixtures/chat/opencode2.ndjson"),
            ),
        ];
        for (backend, raw) in fixtures {
            let mut parser = Parser::new(backend);
            let events = parser.push_events(raw.as_bytes());
            assert!(
                events
                    .iter()
                    .any(|event| matches!(event, Event::Text { .. })),
                "{backend} lost its response: {events:?}"
            );
            assert!(
                events
                    .iter()
                    .any(|event| matches!(event, Event::ToolStart { .. })),
                "{backend} lost its tool call: {events:?}"
            );
            assert!(
                !events
                    .iter()
                    .any(|event| matches!(event, Event::Done { .. })),
                "{backend} leaked its stream marker as a process outcome: {events:?}"
            );
        }
    }

    #[test]
    fn cli_refusals_are_failed_turns_not_assistant_prose() {
        let mut grok = Parser::new("grok");
        let grok_events = grok.push_events(
            b"error: a value is required for '--output-format <OUTPUT_FORMAT>' but none was supplied\n",
        );
        assert!(
            matches!(grok_events.first(), Some(Event::Failed { text }) if text.starts_with("error:")),
            "{grok_events:?}"
        );

        let mut claude = Parser::new("claude");
        let claude_events = claude.push_events("Not logged in · Please run /login\n".as_bytes());
        assert!(
            matches!(
                claude_events.first(),
                Some(Event::Failed { text }) if text.contains("not signed in")
            ),
            "{claude_events:?}"
        );

        let mut cursor = Parser::new("cursor");
        let cursor_events = cursor.push_events(
            b"ActionRequiredError: Named models unavailable Free plans can only use Auto.\n",
        );
        assert!(
            matches!(
                cursor_events.first(),
                Some(Event::Failed { text }) if text.contains("can only use Auto")
            ),
            "{cursor_events:?}"
        );
    }

    /// Both CLIs announce their session somewhere other than where this
    /// parser used to look, so neither ever produced a `Session` event. With
    /// no session recorded, no resume flag was passed, every turn started an
    /// agent with no memory of the conversation, and the transcript filled
    /// with handovers to the agent that was already there.
    #[test]
    fn a_session_is_found_where_each_cli_actually_puts_it() {
        // Antigravity puts the id beside `init`, not inside it.
        let mut agy = Parser::new("agy");
        let events = agy.push_events(
            br#"{"event":"init","conversation_id":"agy-1","init":{"permission_mode":"ask"}}
"#,
        );
        assert!(
            matches!(events.first(), Some(Event::Session { id }) if id == "agy-1"),
            "{events:?}"
        );

        // opencode has no session line at all. Every line is stamped with it.
        let mut opencode = Parser::new("opencode2");
        let events = opencode.push_events(
            br#"{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}
"#,
        );
        assert!(
            matches!(events.first(), Some(Event::Session { id }) if id == "ses_1"),
            "{events:?}"
        );

        // And it is reported once, not once per line: each one writes the
        // conversation index to disk.
        let more = opencode.push_events(
            br#"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"hi"}}
"#,
        );
        assert!(
            !more
                .iter()
                .any(|event| matches!(event, Event::Session { .. })),
            "{more:?}"
        );
        assert!(
            more.iter()
                .any(|event| matches!(event, Event::Text { delta } if delta == "hi")),
            "{more:?}"
        );
    }

    #[test]
    fn tool_start_serializes_input_as_an_object_beside_usage_counts() {
        let start = Event::ToolStart {
            call_id: "item_3".into(),
            verb: "Shell".into(),
            target: "/bin/zsh -lc pwd".into(),
            input: serde_json::json!({"command": "/bin/zsh -lc pwd"}),
        };
        let usage = Event::Usage {
            input: 12,
            output: 4,
            cache_read: 0,
            cache_write: 0,
            cost_usd: None,
        };
        let start_v = serde_json::to_value(&start).unwrap();
        assert_eq!(start_v["kind"], "toolStart");
        assert!(start_v["input"].is_object(), "{start_v}");
        let usage_v = serde_json::to_value(&usage).unwrap();
        assert_eq!(usage_v["kind"], "usage");
        assert_eq!(usage_v["input"], 12);
    }

    #[test]
    fn events_preserve_session_usage_and_edits() {
        let raw = include_str!("../../../fixtures/chat/claude.ndjson");
        let mut parser = Parser::new("claude");
        let events = parser.push_events(raw.as_bytes());
        assert!(matches!(events.first(), Some(Event::Session { id }) if id == "claude-session"));
        assert!(events.iter().any(
            |event| matches!(event, Event::Thinking { delta } if delta == "Inspecting the project")
        ));
        assert!(events.iter().any(|event| matches!(
            event,
            Event::Usage {
                input: 12,
                output: 4,
                ..
            }
        )));
        assert_eq!(
            events
                .iter()
                .filter(|event| matches!(event, Event::Text { delta } if delta == "I found it."))
                .count(),
            1,
            "Claude's result record must not repeat the assistant event: {events:?}"
        );

        let mut agy = Parser::new("agy");
        let edits = agy.push_events(include_str!("../../../fixtures/chat/agy.ndjson").as_bytes());
        assert!(edits.iter().any(|event| matches!(event, Event::Edit { path, added: 1, removed: 1, .. } if path == "a.rs")));
    }

    #[test]
    fn grok_tool_call_update_ends_the_call() {
        let raw = concat!(
            r#"{"type":"tool_call","toolCallId":"call-abc","toolName":"run_terminal_command","status":"pending","rawInput":{"command":"mkdir tmp"}}"#,
            "\n",
            r#"{"type":"tool_call_update","toolCallId":"call-abc","status":null}"#,
            "\n",
            r#"{"type":"tool_call_update","toolCallId":"call-abc","status":"failed","rawOutput":"User cancelled the execution for tool `run_terminal_command`","content":[{"content":{"text":"User cancelled the execution for tool `run_terminal_command`"}}]}"#,
            "\n",
            r#"{"type":"end","stopReason":"cancelled"}"#,
            "\n",
        );
        let mut parser = Parser::new("grok");
        let events = parser.push_events(raw.as_bytes());
        assert!(
            events.iter().any(|event| matches!(
                event,
                Event::ToolStart { call_id, verb, .. } if call_id == "call-abc" && verb == "Shell"
            )),
            "{events:?}"
        );
        assert!(
            events.iter().any(|event| matches!(
                event,
                Event::ToolEnd { call_id, ok: false, detail: Some(detail) }
                    if call_id == "call-abc" && detail.contains("cancelled")
            )),
            "{events:?}"
        );
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, Event::Done { .. })),
            "the backend's cancelled stream marker is not a turn outcome: {events:?}"
        );
    }

    #[test]
    fn leftover_tools_close_when_the_stream_ends() {
        let raw = concat!(
            r#"{"type":"tool_call","id":"read-1","title":"read_file","rawInput":{"path":"src/lib.rs"}}"#,
            "\n",
            r#"{"type":"end","stopReason":"end_turn"}"#,
            "\n",
        );
        let mut parser = Parser::new("grok");
        let events = parser.push_events(raw.as_bytes());
        assert!(
            events.iter().any(|event| matches!(
                event,
                Event::ToolEnd { call_id, ok: true, .. } if call_id == "read-1"
            )),
            "{events:?}"
        );
    }

    #[test]
    fn grok_keeps_text_and_tools_and_drops_machinery() {
        let raw = concat!(
            "{\"type\":\"thought\",\"data\":\"thinking\"}\n",
            "{\"type\":\"tool_call\",\"title\":\"Read\",\"toolName\":\"read_file\",\"rawInput\":{\"path\":\"src/main.rs\"}}\n",
            "{\"type\":\"text\",\"data\":\"Here is the summary\"}\n",
            "{\"type\":\"usage\",\"stopReason\":\"end_turn\"}\n",
            "{\"type\":\"end\",\"stopReason\":\"end_turn\"}\n",
            "{\"type\":\"error\",\"message\":\"quota\"}\n",
        );
        let out = feed("grok", raw);
        assert!(out.contains("Read src/main.rs"));
        assert!(out.contains("Here is the summary"));
        assert!(out.contains("quota"));
        assert!(!out.contains("thinking"));
        assert!(!out.contains("end_turn"));
    }

    #[test]
    fn claude_assistant_and_result_dedupe() {
        let raw = concat!(
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Done.\"}]}}\n",
            "{\"type\":\"result\",\"result\":\"Done.\"}\n",
            "{\"type\":\"system\",\"subtype\":\"init\"}\n",
        );
        let out = feed("claude", raw);
        assert_eq!(out, "Done.");
    }

    #[test]
    fn finish_emits_a_last_line_without_newline() {
        let mut p = Parser::new("sh");
        assert!(p.push(b"hello").is_empty());
        assert_eq!(p.finish(), "hello");
    }

    #[test]
    fn a_truncated_json_line_is_held() {
        let mut p = Parser::new("grok");
        let first = p.push(b"{\"type\":\"text\",\"data\":\"Hel");
        assert!(first.is_empty(), "partial line must wait");
        let second = p.push(b"lo\"}\n");
        assert_eq!(second, "Hello");
    }

    #[test]
    fn grok_text_deltas_join() {
        let raw = concat!(
            "{\"type\":\"text\",\"data\":\"Hel\"}\n",
            "{\"type\":\"text\",\"data\":\"lo\"}\n",
        );
        assert_eq!(feed("grok", raw), "Hello");
    }

    #[test]
    fn grok_text_deltas_join_across_drain_chunks() {
        let mut p = Parser::new("grok");
        let a = p.push(b"{\"type\":\"text\",\"data\":\"Hel\"}\n");
        let b = p.push(b"{\"type\":\"text\",\"data\":\"lo\"}\n");
        assert_eq!(format!("{a}{b}"), "Hello");
    }

    #[test]
    fn a_tool_after_text_stays_its_own_paragraph() {
        let mut p = Parser::new("grok");
        let a = p.push(b"{\"type\":\"text\",\"data\":\"Hi\"}\n");
        let b = p.push(
            b"{\"type\":\"tool_call\",\"title\":\"Read\",\"rawInput\":{\"path\":\"a.rs\"}}\n",
        );
        assert_eq!(format!("{a}{b}"), "Hi\n\nRead a.rs");
    }

    #[test]
    fn codex_keeps_agent_text_and_shell() {
        let raw = concat!(
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Done.\"}}\n",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"command\":\"ls -la\"}}\n",
            "{\"type\":\"item.started\",\"item\":{\"type\":\"agent_message\"}}\n",
        );
        let out = feed("codex", raw);
        assert!(out.contains("Done."));
        assert!(out.contains("Shell ls -la"));
        assert!(!out.contains("item.started"));
    }

    #[test]
    fn cursor_tool_call_and_repeat_are_readable() {
        let raw = concat!(
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"H\"}]}}\n",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"i\"}]}}\n",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hi\"}]}}\n",
            "{\"type\":\"tool_call\",\"subtype\":\"started\",\"tool_call\":{\"shellToolCall\":{\"args\":{\"command\":\"ls\"}}}}\n",
            "{\"type\":\"tool_call\",\"subtype\":\"completed\",\"tool_call\":{\"shellToolCall\":{}}}\n",
        );
        let out = feed("cursor", raw);
        assert!(out.contains("Hi"));
        assert!(out.contains("Shell"));
        assert_eq!(out.matches("Shell").count(), 1);
        assert_eq!(out.matches("Hi").count(), 1);
    }

    #[test]
    fn opencode_keeps_text_and_tools() {
        let raw = concat!(
            "{\"type\":\"text\",\"part\":{\"text\":\"Done.\"}}\n",
            "{\"type\":\"tool_use\",\"part\":{\"tool\":\"bash\",\"state\":{\"status\":\"completed\"}}}\n",
            "{\"type\":\"step_finish\",\"part\":{\"reason\":\"stop\"}}\n",
        );
        let out = feed("opencode", raw);
        assert!(out.contains("Done."));
        assert!(out.contains("Bash"));
    }

    #[test]
    fn opencode_reads_state_input_and_stamps_time() {
        let raw = concat!(
            "{\"type\":\"tool_use\",\"timestamp\":1786894155793,\"part\":{\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"ls -ld /tmp\"},\"output\":\"ok\\n\"}}}\n",
            "{\"type\":\"tool_use\",\"timestamp\":1786894158457,\"part\":{\"tool\":\"read\",\"state\":{\"status\":\"completed\",\"input\":{\"filePath\":\"/tmp/a.txt\"}}}}\n",
        );
        let out = feed("opencode", raw);
        assert!(out.contains("Bash ls -ld /tmp"), "{out}");
        assert!(out.contains("Read /tmp/a.txt"), "{out}");
        assert!(out.contains("| ok"), "{out}");
        assert!(out.contains(':'), "{out}");
    }

    #[test]
    fn agy_error_result_becomes_readable() {
        let raw = "{\"event\":\"result\",\"result\":{\"status\":\"ERROR\",\"error\":\"invalid model selection\"}}\n";
        let out = feed("agy", raw);
        assert!(out.contains("invalid model selection"), "{out}");
    }

    #[test]
    fn reply_is_capped() {
        let bytes = vec![b'x'; REPLY_CAP + 50];
        let (text, next) = slice_reply(&bytes, 0);
        assert_eq!(text.len(), REPLY_CAP);
        assert_eq!(next, REPLY_CAP as u64);
        let (rest, end) = slice_reply(&bytes, next);
        assert_eq!(rest.len(), 50);
        assert_eq!(end, bytes.len() as u64);
    }

    #[test]
    fn readable_cap_keeps_the_tail() {
        let mut text = "head\n".to_string();
        text.push_str(&"y".repeat(READABLE_CAP));
        text.push_str("\ntail");
        cap_readable(&mut text);
        assert!(text.len() <= READABLE_CAP);
        assert!(text.ends_with("tail"));
        assert!(!text.starts_with("head"));
    }

    #[test]
    fn readable_cap_does_not_split_a_multibyte_character() {
        // `é` is two bytes. Place it so `len - READABLE_CAP` lands on its
        // second byte, which is not a char boundary.
        let mut text = String::from("head\n");
        text.push('é');
        text.push_str(&"z".repeat(READABLE_CAP - 1));
        cap_readable(&mut text);
        assert!(text.len() <= READABLE_CAP);
        assert!(text.is_char_boundary(0));
        assert!(text.ends_with('z'));
        assert!(!text.contains('é') || text.starts_with('é'));
    }

    #[test]
    fn grok_drops_available_commands_and_keeps_text() {
        let raw = concat!(
            "{\"type\":\"available_commands\",\"tools\":[\"read_file\"]}\n",
            "{\"type\":\"thought\",\"data\":\"planning\"}\n",
            "{\"type\":\"text\",\"data\":\"I'll start\"}\n",
            "{\"type\":\"text\",\"data\":\" by reading\"}\n",
            "{\"type\":\"tool_call\",\"title\":\"Read\",\"toolName\":\"read_file\",\"rawInput\":{\"path\":\"Cargo.toml\"}}\n",
        );
        let out = feed("grok", raw);
        assert_eq!(out, "I'll start by reading\n\nRead Cargo.toml");
        assert!(!out.contains("available_commands"));
        assert!(!out.contains("planning"));
    }

    #[test]
    fn claude_keeps_tool_path() {
        let raw = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"src/lib.rs\"}}]}}\n";
        assert_eq!(feed("claude", raw), "Read src/lib.rs");
    }

    #[test]
    fn grok_edit_carries_a_short_snippet() {
        let raw = "{\"type\":\"tool_call\",\"title\":\"Edit\",\"rawInput\":{\"path\":\"a.rs\",\"old_string\":\"foo\",\"new_string\":\"bar\"}}\n";
        let out = feed("grok", raw);
        assert!(out.starts_with("Edit a.rs\n"), "{out}");
        assert!(out.contains("- foo"), "{out}");
        assert!(out.contains("+ bar"), "{out}");
    }

    #[test]
    fn grok_snake_case_tools_become_verbs() {
        let raw = concat!(
            "{\"type\":\"tool_call\",\"title\":\"read_file\",\"toolName\":\"read_file\",\"rawInput\":{\"target_file\":\"Cargo.toml\"}}\n",
            "{\"type\":\"tool_call\",\"title\":\"run_terminal_command\",\"rawInput\":{\"command\":\"git status\"}}\n",
            "{\"type\":\"tool_call\",\"title\":\"list_dir\",\"rawInput\":{\"target_directory\":\"/tmp\"}}\n",
            "{\"type\":\"tool_call\",\"title\":\"search_replace\",\"rawInput\":{\"file_path\":\"a.rs\",\"old_string\":\"foo\",\"new_string\":\"bar\"}}\n",
        );
        let out = feed("grok", raw);
        assert!(out.contains("Read Cargo.toml"), "{out}");
        assert!(out.contains("Shell git status"), "{out}");
        assert!(out.contains("Glob /tmp"), "{out}");
        assert!(out.contains("Edit a.rs"), "{out}");
        assert!(out.contains("- foo") && out.contains("+ bar"), "{out}");
        assert!(!out.contains("read_file"), "{out}");
        assert!(!out.contains("run_terminal_command"), "{out}");
    }

    #[test]
    fn grok_keeps_a_space_only_text_delta() {
        let raw = concat!(
            "{\"type\":\"text\",\"data\":\"ship\"}\n",
            "{\"type\":\"text\",\"data\":\" \"}\n",
            "{\"type\":\"text\",\"data\":\"0.4.0\"}\n",
        );
        assert_eq!(feed("grok", raw), "ship 0.4.0");
    }

    #[test]
    fn claude_keeps_tool_names_and_drops_hooks() {
        let raw = concat!(
            "{\"type\":\"system\",\"subtype\":\"init\",\"tools\":[\"Read\"]}\n",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},{\"type\":\"tool_use\",\"name\":\"Read\"}]}}\n",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Version is 0.4.0.\"}]}}\n",
        );
        let out = feed("claude", raw);
        assert!(out.contains("Read"));
        assert!(out.contains("Version is 0.4.0."));
        assert!(!out.contains("ReadVersion"), "{out}");
        assert!(!out.contains("hmm"));
        assert!(!out.contains("subtype"));
    }

    #[test]
    fn agy_keeps_prose_and_drops_json() {
        let raw = concat!(
            "Checking the workspace.\n",
            "{\"type\":\"unknown\",\"data\":\"nope\"}\n",
            "Done.\n",
        );
        let out = feed("agy", raw);
        assert!(out.contains("Checking the workspace."));
        assert!(out.contains("Done."));
        assert!(!out.contains("unknown"));
    }

    #[test]
    fn agy_stream_json_tools_become_verbs() {
        let raw = "\
{\"event\":\"init\",\"init\":{\"tools\":[]}}\n\
{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"tool\",\"state\":\"ACTIVE\",\"tool_name\":\"view_file\",\"tool_info\":{\"name\":\"view_file\",\"parameters\":{\"AbsolutePath\":\"/tmp/a.txt\"}}}}\n\
{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"tool\",\"state\":\"DONE\",\"tool_name\":\"view_file\",\"tool_info\":{\"name\":\"view_file\",\"parameters\":{\"AbsolutePath\":\"/tmp/a.txt\"}}}}\n\
{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"tool\",\"state\":\"ACTIVE\",\"tool_name\":\"write_to_file\",\"tool_info\":{\"parameters\":{\"TargetFile\":\"/tmp/a.txt\"}}}}\n\
{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"tool\",\"state\":\"ACTIVE\",\"tool_name\":\"replace_file_content\",\"tool_info\":{\"parameters\":{\"TargetFile\":\"/tmp/a.txt\"}}}}\n\
{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"tool\",\"state\":\"ACTIVE\",\"tool_name\":\"run_command\",\"tool_info\":{\"parameters\":{\"CommandLine\":\"echo ok\"}}}}\n\
{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"agent_response\",\"text_delta\":\"done\"}}\n\
{\"event\":\"result\",\"result\":{\"response\":\"done\"}}\n";
        let out = feed("agy", raw);
        assert!(out.contains("Read /tmp/a.txt"), "{out}");
        assert!(out.contains("Write /tmp/a.txt"), "{out}");
        assert!(out.contains("Edit /tmp/a.txt"), "{out}");
        assert!(out.contains("Shell echo ok"), "{out}");
        assert!(out.contains("done"), "{out}");
        assert_eq!(out.matches("Read /tmp/a.txt").count(), 1, "{out}");
        assert!(!out.contains("write_to_file"), "{out}");
        assert!(!out.contains("view_file"), "{out}");
        assert!(!out.contains("CommandLine"), "{out}");
    }

    #[test]
    fn rematerialize_writes_readable_from_raw() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-transcript-mat-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let raw = dir.join("run.txt");
        std::fs::write(
            &raw,
            "{\"type\":\"thought\",\"data\":\"x\"}\n{\"type\":\"text\",\"data\":\"hello\"}\n",
        )
        .unwrap();
        let text = rematerialize(&raw, "grok", false).expect("raw still renders");
        assert_eq!(text, "hello");
        let on_disk = std::fs::read_to_string(readable_path(&raw)).unwrap();
        assert_eq!(on_disk, "hello");
        assert!(!looks_like_ndjson(text.as_bytes()));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn looks_like_ndjson_detects_grok_streams() {
        assert!(looks_like_ndjson(b"{\"type\":\"text\",\"data\":\"hi\"}\n"));
        assert!(looks_like_ndjson(
            b"{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"tool\"}}\n"
        ));
        assert!(!looks_like_ndjson(b"I'll start by reading Cargo.toml"));
        assert!(!looks_like_ndjson(b""));
    }

    #[test]
    fn rematerialize_overwrites_a_raw_readable() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-transcript-re-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let raw = dir.join("run.txt");
        let body = "{\"type\":\"text\",\"data\":\"hello\"}\n";
        std::fs::write(&raw, body).unwrap();
        let readable = readable_path(&raw);
        std::fs::write(&readable, body).unwrap();
        assert!(looks_like_ndjson(&std::fs::read(&readable).unwrap()));
        rematerialize(&raw, "grok", true);
        let text = std::fs::read_to_string(&readable).unwrap();
        assert_eq!(text, "hello");
        assert!(!looks_like_ndjson(text.as_bytes()));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn rematerialize_returns_text_when_the_sibling_cannot_be_written() {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-transcript-nowrite-{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let raw = dir.join("run.txt");
        std::fs::write(&raw, "{\"type\":\"text\",\"data\":\"hello\"}\n").unwrap();
        let readable = readable_path(&raw);
        std::fs::create_dir_all(&readable).unwrap();
        let text = rematerialize(&raw, "grok", true).expect("raw still renders");
        assert_eq!(text, "hello");
        assert!(readable.is_dir());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn local_grok_run_becomes_prose() {
        let path = local_run("run-1786840440894.txt");
        let Some(bytes) = path.and_then(|p| std::fs::read(p).ok()) else {
            return;
        };
        let text = render_raw("grok", &bytes);
        assert!(!looks_like_ndjson(text.as_bytes()), "must not serve NDJSON");
        assert!(text.contains("I'll start"), "{text}");
        assert!(text.contains("Read "), "{text}");
        assert!(
            text.contains("ship 0.4.0") || text.contains(" 0.4.0"),
            "{text}"
        );
        assert!(!text.contains("read_file"), "{text}");
        assert!(!text.contains("run_terminal_command"), "{text}");
        assert!(!text.contains("available_commands"));
        assert!(!text.contains("\"type\":\"thought\""));
    }

    #[test]
    fn local_claude_run_becomes_prose() {
        let path = local_run("run-1786029156900.txt");
        let Some(bytes) = path.and_then(|p| std::fs::read(p).ok()) else {
            return;
        };
        let text = render_raw("claude", &bytes);
        assert!(!looks_like_ndjson(text.as_bytes()), "must not serve NDJSON");
        assert!(!text.contains("\"type\":\"system\""));
        assert!(!text.contains("\"thinking\""));
        assert!(
            text.contains("Read") || text.contains("Version") || !text.is_empty(),
            "{text}"
        );
    }

    fn local_run(name: &str) -> Option<std::path::PathBuf> {
        let home = std::env::var_os("HOME")?;
        let path = std::path::PathBuf::from(home)
            .join("Library/Application Support/ai.tokenstat.tokenstat/runs")
            .join(name);
        path.is_file().then_some(path)
    }
}
