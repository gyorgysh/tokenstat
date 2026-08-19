// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Pi session reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl
//! ```
//!
//! The directory name is the folder the session ran in with every separator
//! turned into a dash and a dash wrapped around it, so `/Users/x/git/demo`
//! becomes `--Users-x-git-demo--`. That is lossy: a real dash in a folder name
//! is now indistinguishable from a separator. The session's own header line
//! carries the exact `cwd`, so the header is what names the project and the
//! directory is only the fallback for a file whose header was never written.
//!
//! Each line is an event. `type: "session"` opens the file, `model_change`
//! records a switch, and `type: "message"` carries a turn. Only assistant
//! messages have `message.usage`, and each one holds **that turn's** counters
//! rather than a running total: across a three-turn session the input grows
//! with the context (6504, 6660, 6688) while the output stays flat.
//!
//! ```json
//! {"input":6504,"output":12,"cacheRead":512,"cacheWrite":0,
//!  "reasoning":11,"totalTokens":7028,"cost":{"total":0.014}}
//! ```
//!
//! `totalTokens` is `input + output + cacheRead + cacheWrite`, which is what
//! says the cache figures are **disjoint** from input, and that reasoning is
//! **inside** output rather than beside it: 6504 + 12 + 512 = 7028 exactly,
//! with the 11 reasoning tokens already counted in the 12 output ones.
//!
//! A turn that was interrupted or failed writes an all-zero usage block. Those
//! are skipped: a zero row is not a fact about spend, and keeping them would
//! put empty turns in the session count.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the sessions root.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = home.join(".pi").join("agent").join("sessions");
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
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"))
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
    id: Option<String>,
    timestamp: Option<String>,
    /// Only on the session header.
    cwd: Option<String>,
    message: Option<Message>,
}

#[derive(Deserialize)]
struct Message {
    role: Option<String>,
    model: Option<String>,
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Usage {
    input: Option<u64>,
    output: Option<u64>,
    #[serde(rename = "cacheRead")]
    cache_read: Option<u64>,
    #[serde(rename = "cacheWrite")]
    cache_write: Option<u64>,
    reasoning: Option<u64>,
    cost: Option<Cost>,
}

#[derive(Deserialize)]
struct Cost {
    total: Option<f64>,
}

/// Read one session file.
///
/// `contents` rather than a path read, so the caller can hand over only the
/// bytes appended since the last scan. A resumed read starts mid-file and so
/// may never see the header line, which is why the folder name stays as the
/// fallback for the project.
pub fn parse_file(path: &Path, sessions_root: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let session = session_id(path);
    let mut project = folder_label(path, sessions_root);

    for (i, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // The header is worth parsing for its `cwd`; everything else is worth
        // parsing only if it could carry counters. Most lines in a session are
        // user turns and tool results.
        let interesting = line.contains("\"usage\"") || line.contains("\"cwd\"");
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
            if let Some(cwd) = row.cwd.as_deref() {
                if let Some(label) = last_component(cwd) {
                    project = label;
                }
            }
            continue;
        }
        let Some(message) = row.message else { continue };
        if message.role.as_deref() == Some("user") {
            continue;
        }
        let Some(usage) = message.usage else { continue };

        let input = usage.input.unwrap_or(0);
        let output = usage.output.unwrap_or(0);
        let cache_read = usage.cache_read.unwrap_or(0);
        let cache_write = usage.cache_write.unwrap_or(0);
        if input == 0 && output == 0 && cache_read == 0 && cache_write == 0 {
            continue;
        }
        out.rows_seen += 1;

        let ts = row
            .timestamp
            .as_deref()
            .and_then(parse_iso8601_ms)
            .map(Timestamp::from_ms)
            .unwrap_or(Timestamp::from_ms(0));
        // The line's own id. Pi writes a uuid per event, so a re-read of the
        // same turn lands on the same row rather than adding a second one.
        // Without one, the file offset would be the only identity, and a file
        // rewritten from the start would count every turn again.
        let id = match row.id.as_deref() {
            Some(id) if !id.is_empty() => EventId::derive(&["pi", id]),
            _ => EventId::derive(&["pi", &session, &i.to_string()]),
        };

        out.events.push(UsageEvent {
            id,
            source: SourceId::Pi,
            ts,
            model: message
                .model
                .filter(|m| !m.is_empty())
                .unwrap_or_else(|| "unknown".to_string()),
            session: session.clone(),
            project: project.clone(),
            counters: Counters {
                input_fresh: Some(input),
                cache_read: usage.cache_read,
                cache_write_5m: usage.cache_write,
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras {
                // Already inside `output`. See the module comment for the
                // arithmetic that shows it.
                reasoning_within_output: usage.reasoning.filter(|&r| r > 0),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            // Pi prices the turn itself. A zero on a turn that spent tokens is
            // a model the plan covers, which is the same reading the OpenCode
            // shard makes of the same shape.
            billing: match usage.cost.and_then(|c| c.total) {
                Some(0.0) => BillingMode::Plan,
                Some(_) => BillingMode::Metered,
                None => BillingMode::Unknown,
            },
            confidence: Confidence::Exact,
        });
    }
    out
}

/// Parse an ISO-8601 UTC timestamp into epoch milliseconds.
fn parse_iso8601_ms(s: &str) -> Option<i64> {
    s.parse::<jiff::Timestamp>()
        .ok()
        .map(|t| t.as_millisecond())
}

/// The session id, which is the part of the filename after the timestamp.
fn session_id(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown");
    stem.split_once('_')
        .map(|(_, id)| id.to_string())
        .unwrap_or_else(|| stem.to_string())
}

/// Project from the encoded folder name, for a file whose header we did not
/// read. `--Users-x-git-demo--` is the folder `/Users/x/git/demo`, so the last
/// dash-separated part is the best guess at its name.
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

    const ROOT: &str = "/home/u/.pi/agent/sessions";

    fn path() -> PathBuf {
        PathBuf::from(ROOT)
            .join("--Users-x-git-demo--")
            .join("2026-08-19T21-49-58-054Z_01a01c00-9fa6-70a9-901b-34f46111a70e.jsonl")
    }

    #[test]
    fn reads_a_turn() {
        let text = r#"
{"type":"session","version":3,"id":"01a01c00","timestamp":"2026-08-19T21:49:58.054Z","cwd":"/Users/x/git/demo"}
{"type":"message","id":"m1","timestamp":"2026-08-19T21:50:01.000Z","message":{"role":"assistant","model":"grok-4.5","usage":{"input":6504,"output":12,"cacheRead":512,"cacheWrite":0,"reasoning":11,"totalTokens":7028,"cost":{"total":0.014}}}}
"#;
        let out = parse_file(&path(), Path::new(ROOT), text);
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.source, SourceId::Pi);
        assert_eq!(e.model, "grok-4.5");
        assert_eq!(e.project, "demo");
        assert_eq!(e.session, "01a01c00-9fa6-70a9-901b-34f46111a70e");
        assert_eq!(e.counters.input_fresh, Some(6504));
        assert_eq!(e.counters.output, Some(12));
        assert_eq!(e.counters.cache_read, Some(512));
        assert_eq!(e.extras.reasoning_within_output, Some(11));
        assert_eq!(e.billing, BillingMode::Metered);
    }

    #[test]
    fn an_interrupted_turn_is_not_spend() {
        let text = r#"{"type":"message","id":"m2","timestamp":"2026-08-19T21:50:01.000Z","message":{"role":"assistant","model":"grok-4.5","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"total":0}}}}"#;
        let out = parse_file(&path(), Path::new(ROOT), text);
        assert!(out.events.is_empty());
        assert_eq!(out.rows_seen, 0);
    }

    #[test]
    fn user_turns_carry_nothing() {
        let text = r#"{"type":"message","id":"m3","timestamp":"2026-08-19T21:50:00.000Z","message":{"role":"user","content":"hello"}}"#;
        let out = parse_file(&path(), Path::new(ROOT), text);
        assert!(out.events.is_empty());
    }

    #[test]
    fn a_zero_cost_turn_reads_as_plan() {
        let text = r#"{"type":"message","id":"m4","timestamp":"2026-08-19T21:50:01.000Z","message":{"role":"assistant","model":"free-model","usage":{"input":10,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":12,"cost":{"total":0}}}}"#;
        let out = parse_file(&path(), Path::new(ROOT), text);
        assert_eq!(out.events[0].billing, BillingMode::Plan);
    }

    #[test]
    fn the_folder_name_stands_in_when_the_header_was_not_read() {
        // A resumed read starts after the header line, which is the case this
        // fallback exists for.
        let text = r#"{"type":"message","id":"m5","timestamp":"2026-08-19T21:50:01.000Z","message":{"role":"assistant","model":"m","usage":{"input":5,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":6,"cost":{"total":0.1}}}}"#;
        let out = parse_file(&path(), Path::new(ROOT), text);
        assert_eq!(out.events[0].project, "demo");
    }

    #[test]
    fn the_same_turn_read_twice_is_one_event() {
        let text = r#"{"type":"message","id":"m6","timestamp":"2026-08-19T21:50:01.000Z","message":{"role":"assistant","model":"m","usage":{"input":5,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":6,"cost":{"total":0.1}}}}"#;
        let first = parse_file(&path(), Path::new(ROOT), text);
        let again = parse_file(&path(), Path::new(ROOT), text);
        assert_eq!(first.events[0].id, again.events[0].id);
    }
}
