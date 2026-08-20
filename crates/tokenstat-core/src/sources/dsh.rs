// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! DeepSeek Harness session reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.dsh/sessions/<encoded-cwd>/session-<uuid>/session.jsonl.zstd
//! ```
//!
//! The directory name encodes the folder the way Pi's does, and the session's
//! own header line carries the exact `cwd`, so the header names the project and
//! the directory is only the fallback.
//!
//! **The file is compressed and appended to one frame at a time.** A 94 line
//! session held 36 zstd frames, so it grows rather than being rewritten, and
//! `zstd::decode_all` follows concatenated frames (there is a test for that
//! below, because the whole reader rests on it).
//!
//! Usage rides on `assistant/message`:
//!
//! ```json
//! {"type":"assistant/message","time":1787182700415,
//!  "data":{"usage":{"inputTokens":13050,"outputTokens":69,
//!                   "cacheReadTokens":0,"reasoningTokens":47},
//!          "message":{"id":"31279b3c-…",
//!                     "source":{"provider":"deepseek-official",
//!                               "model":"deepseek-v4-flash"}}}}
//! ```
//!
//! **`inputTokens` is fresh only**, disjoint from `cacheReadTokens`. One
//! session settles it: turn 1 spent 7,777 input with no cache, and turn 2 spent
//! **32** input while reading 7,808 from cache, which is turn 1's prompt come
//! back. An inclusive count could never be smaller than its own cache figure.
//!
//! Reasoning is **inside** output in every row seen (69/47, 123/54, 311/64).
//!
//! There is no cache-write counter at all, which is right for this vendor's
//! pricing, so that field is reported as absent rather than as a zero.
//!
//! # Two things this must not do
//!
//! `assistant/chunk` carries a `chunk.type: "usage"` that repeats the same
//! numbers as the message it belongs to. Reading both doubles every session, so
//! only `assistant/message` is counted.
//!
//! The harness also makes a `session/title-llm-request` call and records no
//! usage for it, so its title generation is invisible here. That is a small
//! under-report this reader cannot fix, and inventing a figure for it would be
//! worse than missing it.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the sessions root.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = home.join(".dsh").join("sessions");
    root.is_dir().then_some(root)
}

/// Every session transcript under the sessions root.
pub fn shards(root: &Path) -> Vec<PathBuf> {
    walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with(".jsonl.zstd"))
        })
        .collect()
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

#[derive(Deserialize)]
struct Row {
    #[serde(rename = "type")]
    kind: Option<String>,
    time: Option<i64>,
    /// Only on the session header.
    cwd: Option<String>,
    #[serde(rename = "createdAt")]
    created_at: Option<i64>,
    data: Option<Data>,
}

#[derive(Deserialize)]
struct Data {
    usage: Option<Usage>,
    message: Option<Message>,
}

#[derive(Deserialize)]
struct Message {
    id: Option<String>,
    source: Option<Source>,
}

#[derive(Deserialize)]
struct Source {
    model: Option<String>,
}

#[derive(Deserialize)]
struct Usage {
    #[serde(rename = "inputTokens")]
    input: Option<u64>,
    #[serde(rename = "outputTokens")]
    output: Option<u64>,
    #[serde(rename = "cacheReadTokens")]
    cache_read: Option<u64>,
    #[serde(rename = "reasoningTokens")]
    reasoning: Option<u64>,
}

/// Read one session file, decompressing it first.
///
/// The file is opened here rather than handed over as text, because it is zstd
/// and the scan's text path would deliver the compressed bytes as mojibake.
pub fn parse_file(path: &Path, sessions_root: &Path) -> ParseOutput {
    let mut out = ParseOutput::default();
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };
    let text = match zstd::decode_all(&bytes[..]) {
        Ok(t) => t,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: format!("zstd: {e}"),
            });
            return out;
        }
    };
    parse_text(path, sessions_root, &String::from_utf8_lossy(&text))
}

/// The reading half, over decompressed text. Split out so a fixture can be a
/// plain file that a person can read in a diff.
pub fn parse_text(path: &Path, sessions_root: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let session = session_id(path);
    let mut project = folder_label(path, sessions_root);
    let mut started_at: Option<i64> = None;

    for (i, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // A session is mostly streaming chunks and tool traffic. Only the
        // header and the finished assistant messages are worth a parse, and
        // `assistant/chunk` repeats the counters so it must not be one of them.
        let interesting = line.contains("\"assistant/message\"") || line.contains("\"cwd\"");
        if !interesting {
            continue;
        }
        let row: Row = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(_) => {
                out.warnings.push(Warning::MalformedLine {
                    path: path.to_path_buf(),
                    line: i + 1,
                });
                continue;
            }
        };
        if row.kind.as_deref() == Some("session") {
            if let Some(cwd) = row.cwd.as_deref()
                && let Some(label) = last_component(cwd)
            {
                project = label;
            }
            started_at = row.created_at;
            continue;
        }
        if row.kind.as_deref() != Some("assistant/message") {
            continue;
        }
        let Some(data) = row.data else { continue };
        let Some(usage) = data.usage else { continue };

        let input = usage.input.unwrap_or(0);
        let output = usage.output.unwrap_or(0);
        let cache_read = usage.cache_read.unwrap_or(0);
        if input == 0 && output == 0 && cache_read == 0 {
            continue;
        }
        out.rows_seen += 1;

        let message = data.message;
        let model = message
            .as_ref()
            .and_then(|m| m.source.as_ref())
            .and_then(|s| s.model.clone())
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| "unknown".to_string());
        // The harness's own id for the message. A re-read lands on the same
        // row rather than adding a second one.
        let id = match message.as_ref().and_then(|m| m.id.as_deref()) {
            Some(id) if !id.is_empty() => EventId::derive(&["dsh", id]),
            _ => EventId::derive(&["dsh", &session, &i.to_string()]),
        };

        out.events.push(UsageEvent {
            id,
            source: SourceId::Dsh,
            ts: Timestamp::from_ms(row.time.or(started_at).unwrap_or(0)),
            model,
            session: session.clone(),
            project: project.clone(),
            counters: Counters {
                input_fresh: Some(input),
                cache_read: usage.cache_read,
                // No such counter in this vendor's accounting. `None` says the
                // source does not report it, where a zero would claim it does.
                cache_write_5m: None,
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras {
                reasoning_within_output: usage.reasoning.filter(|&r| r > 0),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            // The log carries no cost and no plan marker, so this stays
            // unknown rather than being guessed from the provider's name.
            billing: BillingMode::Unknown,
            confidence: Confidence::Exact,
        });
    }
    out
}

/// The session id, which is the directory the transcript sits in.
fn session_id(path: &Path) -> String {
    path.parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .map(|n| n.trim_start_matches("session-").to_string())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

/// Project from the encoded folder name, for a file whose header we did not
/// read. `--Users-x-git-demo--` is the folder `/Users/x/git/demo`.
fn folder_label(path: &Path, sessions_root: &Path) -> String {
    let dir = path
        .strip_prefix(sessions_root)
        .ok()
        .and_then(|rel| rel.components().next())
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .unwrap_or_default();
    dir.trim_matches('-')
        .rsplit('-')
        .find(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_string()
}

fn last_component(cwd: &str) -> Option<String> {
    cwd.rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: &str = "/home/u/.dsh/sessions";

    fn path() -> PathBuf {
        PathBuf::from(ROOT)
            .join("--Users-x-git-demo--")
            .join("session-4a549fa4-108e-4361-b86f-4c69cc3ac53a")
            .join("session.jsonl.zstd")
    }

    /// The two turns quoted in the module comment, plus the chunk that repeats
    /// the second one's counters.
    const SESSION: &str = r#"
{"type":"session","version":0,"id":"session-4a549fa4","createdAt":1787182615856,"cwd":"/Users/x/git/demo"}
{"type":"user/message","seq":3,"time":1787182616000,"data":{"text":"hello"}}
{"type":"assistant/message","seq":89,"time":1787182617000,"data":{"turn":1,"step":1,"message":{"role":"assistant","id":"4e2815ad","source":{"kind":"model","provider":"deepseek-official","model":"deepseek-v4-flash"}},"usage":{"inputTokens":7777,"outputTokens":57,"cacheReadTokens":0,"reasoningTokens":35}}}
{"type":"assistant/chunk","seq":87,"time":1787182618000,"data":{"turn":2,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":32,"outputTokens":123,"cacheReadTokens":7808,"reasoningTokens":54}}}}
{"type":"assistant/message","seq":90,"time":1787182619000,"data":{"turn":2,"step":1,"message":{"role":"assistant","id":"dc10d80a","source":{"kind":"model","provider":"deepseek-official","model":"deepseek-v4-flash"}},"usage":{"inputTokens":32,"outputTokens":123,"cacheReadTokens":7808,"reasoningTokens":54}}}
"#;

    #[test]
    fn reads_a_turn() {
        let out = parse_text(&path(), Path::new(ROOT), SESSION);
        assert_eq!(out.events.len(), 2);
        let first = &out.events[0];
        assert_eq!(first.source, SourceId::Dsh);
        assert_eq!(first.model, "deepseek-v4-flash");
        assert_eq!(first.project, "demo");
        assert_eq!(first.session, "4a549fa4-108e-4361-b86f-4c69cc3ac53a");
        assert_eq!(first.counters.input_fresh, Some(7777));
        assert_eq!(first.counters.output, Some(57));
        assert_eq!(first.extras.reasoning_within_output, Some(35));
    }

    /// The bug this reader is most likely to grow: `assistant/chunk` repeats
    /// the message's counters, so counting both doubles every session.
    #[test]
    fn the_streaming_chunk_is_not_counted_twice() {
        let out = parse_text(&path(), Path::new(ROOT), SESSION);
        let input: u64 = out
            .events
            .iter()
            .filter_map(|e| e.counters.input_fresh)
            .sum();
        assert_eq!(
            input,
            7777 + 32,
            "the chunk repeats the message, not adds to it"
        );
        assert_eq!(out.rows_seen, 2);
    }

    /// Fresh input, not a total. A turn that read 7,808 from cache spent 32.
    #[test]
    fn cache_read_is_disjoint_from_input() {
        let out = parse_text(&path(), Path::new(ROOT), SESSION);
        let second = &out.events[1];
        assert_eq!(second.counters.input_fresh, Some(32));
        assert_eq!(second.counters.cache_read, Some(7808));
        assert!(
            second.counters.input_fresh < second.counters.cache_read,
            "an inclusive input could never be smaller than its own cache figure"
        );
    }

    /// A vendor with no cache-write counter must not be given a zero, which
    /// would read as "it wrote nothing" rather than "it does not say".
    #[test]
    fn a_missing_counter_is_absent_not_zero() {
        let out = parse_text(&path(), Path::new(ROOT), SESSION);
        assert_eq!(out.events[0].counters.cache_write_5m, None);
        assert_eq!(out.events[0].counters.cache_write_1h, None);
    }

    #[test]
    fn the_same_turn_read_twice_is_one_event() {
        let first = parse_text(&path(), Path::new(ROOT), SESSION);
        let again = parse_text(&path(), Path::new(ROOT), SESSION);
        assert_eq!(first.events[0].id, again.events[0].id);
    }

    /// The whole reader rests on this: the harness appends a frame per record,
    /// so a session is many frames and reading only the first would stop at
    /// the header.
    #[test]
    fn every_appended_frame_is_read() {
        let dir = std::env::temp_dir().join(format!("tokenstat-dsh-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let session_dir = dir.join("--Users-x-git-demo--").join("session-abc");
        std::fs::create_dir_all(&session_dir).unwrap();
        let file = session_dir.join("session.jsonl.zstd");

        // One frame per line, the way the harness writes them.
        let mut bytes = Vec::new();
        for line in SESSION.lines().filter(|l| !l.trim().is_empty()) {
            let framed = format!("{line}\n");
            bytes.extend(zstd::encode_all(framed.as_bytes(), 0).unwrap());
        }
        std::fs::write(&file, &bytes).unwrap();

        let out = parse_file(&file, &dir);
        assert!(out.warnings.is_empty(), "{:?}", out.warnings);
        assert_eq!(out.events.len(), 2, "a later frame's turn was lost");
        assert_eq!(out.events[1].counters.cache_read, Some(7808));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_is_not_zstd_warns_rather_than_panics() {
        let dir = std::env::temp_dir().join(format!("tokenstat-dsh-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("session.jsonl.zstd");
        std::fs::write(&file, b"not compressed at all").unwrap();
        let out = parse_file(&file, &dir);
        assert!(out.events.is_empty());
        assert_eq!(out.warnings.len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
