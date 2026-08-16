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

/// How much one `automation.transcript` reply may carry.
pub const REPLY_CAP: usize = 64 * 1024;

/// How much readable text to keep on disk for one run.
pub const READABLE_CAP: usize = 256 * 1024;

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
}

impl Parser {
    pub fn new(backend: &str) -> Self {
        Self {
            backend: backend.to_string(),
            leftover: String::new(),
            last_block: String::new(),
            last_was_text: false,
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
            "opencode" => render_opencode(&value),
            "agy" => render_agy(&value),
            _ => None,
        }
    }

    fn is_json_backend(&self) -> bool {
        matches!(
            self.backend.as_str(),
            "grok" | "claude" | "cursor" | "codex" | "opencode" | "agy"
        )
    }
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
/// `agent_response`. The final `result` repeats that text, so it is dropped.
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
                    Some(Piece::Block(format_tool(&display_verb(name), params)))
                }
                "agent_response" => {
                    text_delta(step.get("text_delta").and_then(|v| v.as_str())).map(Piece::Text)
                }
                _ => None,
            }
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
                .or_else(|| part.get("state"));
            Some(Piece::Block(format_tool(&display_verb(tool), input)))
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
    const KEYS: [&str; 12] = [
        "path",
        "file_path",
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
    let wanted: Vec<String> = keys.iter().map(|k| k.to_ascii_lowercase()).collect();
    for (key, val) in obj {
        if wanted.iter().any(|want| want == &key.to_ascii_lowercase()) {
            if let Some(s) = val.as_str().filter(|s| !s.is_empty()) {
                return Some(s);
            }
        }
    }
    None
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
        "read_file" | "Read" | "view_file" | "view_file_outline" | "view_code_item" => {
            "Read".into()
        }
        "write" | "Write" | "write_file" | "write_to_file" | "create_file" => "Write".into(),
        "search_replace"
        | "Edit"
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
