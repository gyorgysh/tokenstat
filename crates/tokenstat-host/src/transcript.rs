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

/// Incremental NDJSON (or plain) renderer for one backend.
pub struct Parser {
    backend: String,
    leftover: String,
    last_block: String,
}

impl Parser {
    pub fn new(backend: &str) -> Self {
        Self {
            backend: backend.to_string(),
            leftover: String::new(),
            last_block: String::new(),
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
                append_block(&mut out, &piece);
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
        self.line(&leftover).unwrap_or_default()
    }

    fn line(&mut self, raw: &str) -> Option<String> {
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
            return Some(cleaned);
        }
        let value: serde_json::Value = serde_json::from_str(&cleaned).ok()?;
        let rendered = match self.backend.as_str() {
            "grok" => render_grok(&value),
            "claude" | "cursor" => render_claude_family(&value),
            "codex" => render_codex(&value),
            _ => None,
        };
        match rendered {
            Some(text) if text == self.last_block => None,
            Some(text) => {
                self.last_block = text.clone();
                Some(text)
            }
            None => None,
        }
    }

    fn is_json_backend(&self) -> bool {
        matches!(
            self.backend.as_str(),
            "grok" | "claude" | "cursor" | "codex"
        )
    }
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
    let start = text.len() - READABLE_CAP;
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

fn append_block(out: &mut String, piece: &str) {
    if piece.is_empty() {
        return;
    }
    if !out.is_empty() {
        out.push_str("\n\n");
    }
    out.push_str(piece);
}

fn render_grok(value: &serde_json::Value) -> Option<String> {
    let kind = value.get("type")?.as_str()?;
    match kind {
        "text" => nonempty(value.get("data").and_then(|v| v.as_str())),
        "error" => nonempty(value.get("message").and_then(|v| v.as_str())),
        "tool_call" => {
            let title = value
                .get("title")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .or_else(|| value.get("toolName").and_then(|v| v.as_str()))
                .unwrap_or("tool");
            let path = value
                .get("rawInput")
                .and_then(|v| v.get("path").or_else(|| v.get("file")))
                .and_then(|v| v.as_str());
            Some(match path {
                Some(p) => format!("{title} {p}"),
                None => title.to_string(),
            })
        }
        _ => None,
    }
}

fn render_claude_family(value: &serde_json::Value) -> Option<String> {
    let kind = value.get("type")?.as_str()?;
    match kind {
        "assistant" => assistant_texts(value),
        "result" => nonempty(value.get("result").and_then(|v| v.as_str())),
        _ => None,
    }
}

fn render_codex(value: &serde_json::Value) -> Option<String> {
    let kind = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if kind == "item.completed" {
        let item = value.get("item")?;
        let item_type = item.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if matches!(item_type, "agent_message" | "message" | "text") {
            return nonempty(
                item.get("text")
                    .and_then(|v| v.as_str())
                    .or_else(|| item.get("content").and_then(|v| v.as_str())),
            );
        }
        return None;
    }
    if kind == "message" && value.get("role").and_then(|v| v.as_str()) == Some("assistant") {
        if let Some(text) = value.get("text").and_then(|v| v.as_str()) {
            return nonempty(Some(text));
        }
        return assistant_texts(value);
    }
    if kind == "agent_message" {
        return nonempty(value.get("text").and_then(|v| v.as_str()));
    }
    None
}

fn assistant_texts(value: &serde_json::Value) -> Option<String> {
    let content = value
        .get("message")
        .and_then(|m| m.get("content"))
        .or_else(|| value.get("content"));
    let texts: Vec<&str> = match content {
        Some(serde_json::Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| block.get("text").and_then(|v| v.as_str()))
            .filter(|s| !s.is_empty())
            .collect(),
        Some(serde_json::Value::String(s)) if !s.is_empty() => vec![s.as_str()],
        _ => Vec::new(),
    };
    if texts.is_empty() {
        None
    } else {
        Some(texts.join("\n"))
    }
}

fn nonempty(s: Option<&str>) -> Option<String> {
    s.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
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
}
