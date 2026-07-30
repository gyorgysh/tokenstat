//! Antigravity IDE usage cache reader.
//!
//! The IDE does not leave plain token counters on disk. `tokenstat-sync` talks
//! to a running language server, then writes normalized JSONL under the
//! tokenstat data directory. This module only reads that cache:
//!
//! ```text
//! <data>/cache/antigravity/sessions/<sessionId>.jsonl
//! ```
//!
//! Each line is either `session_meta` (model fallback) or `usage` (counters).

use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Directory where sync writes IDE session JSONL files.
pub fn cache_dir() -> Option<PathBuf> {
    directories::ProjectDirs::from("ai", "tokenstat", "tokenstat").map(|d| {
        d.data_dir()
            .join("cache")
            .join("antigravity")
            .join("sessions")
    })
}

/// Locate the IDE cache when present.
pub fn discover() -> Option<PathBuf> {
    let root = cache_dir()?;
    root.is_dir().then_some(root)
}

pub fn shards(root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("jsonl"))
        .collect();
    out.sort();
    out
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
    row_type: Option<String>,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    #[serde(rename = "modelId")]
    model_id: Option<String>,
    timestamp: Option<Value>,
    input: Option<Value>,
    output: Option<Value>,
    #[serde(rename = "cacheRead")]
    cache_read: Option<Value>,
    #[serde(rename = "cacheWrite")]
    cache_write: Option<Value>,
    reasoning: Option<Value>,
    #[serde(rename = "responseId")]
    response_id: Option<String>,
}

/// Parse one session JSONL cache file written by sync.
pub fn parse_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let fallback_session = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string();

    let mut session_model: Option<String> = None;
    let mut session_ts: Option<i64> = None;
    let mut ordinal: u64 = 0;
    let file_mtime_ms = std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    for (line_no, line) in contents.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let row: Row = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(_) => {
                out.warnings.push(Warning::MalformedLine {
                    path: path.to_path_buf(),
                    line: line_no + 1,
                });
                continue;
            }
        };

        match row.row_type.as_deref() {
            Some("session_meta") => {
                if let Some(model) = row.model_id.filter(|m| !m.trim().is_empty()) {
                    session_model = Some(model);
                }
                let ts = to_i64(row.timestamp.as_ref());
                if ts > 0 {
                    session_ts = Some(ts);
                }
            }
            Some("usage") => {
                let fallback_ts = session_ts.filter(|&t| t > 0).unwrap_or(file_mtime_ms);
                if let Some(event) = parse_usage(
                    &row,
                    session_model.as_deref(),
                    &fallback_session,
                    ordinal,
                    fallback_ts,
                ) {
                    out.rows_seen += 1;
                    out.events.push(event);
                    ordinal += 1;
                }
            }
            _ => {}
        }
    }

    out
}

fn parse_usage(
    row: &Row,
    fallback_model: Option<&str>,
    fallback_session: &str,
    ordinal: u64,
    fallback_ts_ms: i64,
) -> Option<UsageEvent> {
    let session = row
        .session_id
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(fallback_session)
        .to_string();

    let mut ts_ms = to_i64(row.timestamp.as_ref());
    if ts_ms <= 0 {
        ts_ms = fallback_ts_ms;
    }
    if ts_ms <= 0 {
        return None;
    }

    let model = row
        .model_id
        .as_deref()
        .filter(|m| !m.trim().is_empty())
        .map(str::to_string)
        .or_else(|| fallback_model.map(str::to_string))
        .unwrap_or_else(|| "unknown".to_string());

    let input = to_u64(row.input.as_ref());
    let output_text = to_u64(row.output.as_ref());
    let cache_read = to_u64(row.cache_read.as_ref());
    let cache_write = to_u64(row.cache_write.as_ref());
    let reasoning = to_u64(row.reasoning.as_ref());
    let output = output_text.saturating_add(reasoning);
    if input == 0 && output == 0 && cache_read == 0 && cache_write == 0 {
        return None;
    }

    let response_id = row
        .response_id
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(str::to_string);

    let (id, confidence) = match &response_id {
        Some(rid) => (
            EventId::derive(&["antigravity", &session, rid]),
            Confidence::Exact,
        ),
        None => (
            EventId::derive(&[
                "antigravity",
                "ide",
                &session,
                &ordinal.to_string(),
                &ts_ms.to_string(),
            ]),
            Confidence::Derived,
        ),
    };

    Some(UsageEvent {
        id,
        source: SourceId::Antigravity,
        ts: Timestamp::from_ms(ts_ms),
        model,
        session: session.clone(),
        project: session,
        counters: Counters {
            input_fresh: Some(input),
            cache_read: Some(cache_read),
            cache_write_5m: Some(cache_write),
            cache_write_1h: None,
            output: Some(output),
        },
        extras: Extras {
            reasoning_within_output: (reasoning > 0).then_some(reasoning),
            ..Extras::default()
        },
        billing: BillingMode::Plan,
        confidence,
    })
}

fn to_i64(value: Option<&Value>) -> i64 {
    value
        .and_then(|inner| {
            inner
                .as_i64()
                .or_else(|| inner.as_u64().and_then(|n| i64::try_from(n).ok()))
                .or_else(|| inner.as_str().and_then(|t| t.parse().ok()))
        })
        .unwrap_or(0)
        .max(0)
}

fn to_u64(value: Option<&Value>) -> u64 {
    value
        .and_then(|inner| {
            inner
                .as_u64()
                .or_else(|| inner.as_i64().and_then(|n| u64::try_from(n).ok()))
                .or_else(|| inner.as_str().and_then(|t| t.parse().ok()))
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_row_with_meta_fallback() {
        let input = r#"{"type":"session_meta","sessionId":"abc","modelId":"claude-sonnet-4-6"}
{"type":"usage","sessionId":"abc","timestamp":1711200000000,"input":12,"output":4,"cacheRead":2,"cacheWrite":0,"reasoning":1,"responseId":"resp-1"}
"#;
        let path = PathBuf::from("/tmp/abc.jsonl");
        let out = parse_file(&path, input);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].model, "claude-sonnet-4-6");
        assert_eq!(out.events[0].counters.input_fresh, Some(12));
        assert_eq!(out.events[0].counters.output, Some(5));
        assert_eq!(out.events[0].extras.reasoning_within_output, Some(1));
        assert_eq!(out.events[0].confidence, Confidence::Exact);
    }

    #[test]
    fn null_timestamp_falls_back_to_meta_or_mtime() {
        let dir = std::env::temp_dir().join(format!("tokenstat-ag-cache-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("abc.jsonl");
        let input = r#"{"type":"session_meta","sessionId":"abc","modelId":"m","timestamp":1711200000000}
{"type":"usage","sessionId":"abc","timestamp":null,"input":12,"output":4,"cacheRead":0,"cacheWrite":0,"reasoning":0,"responseId":"r1"}
"#;
        std::fs::write(&path, input).unwrap();
        let out = parse_file(&path, input);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].ts.utc_ms, 1711200000000);
    }

    #[test]
    fn empty_usage_is_skipped() {
        let input = r#"{"type":"usage","sessionId":"abc","timestamp":1,"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}
"#;
        assert!(
            parse_file(&PathBuf::from("x.jsonl"), input)
                .events
                .is_empty()
        );
    }

    #[test]
    fn malformed_line_warns() {
        let out = parse_file(&PathBuf::from("x.jsonl"), "{bad\n");
        assert!(out.events.is_empty());
        assert_eq!(out.warnings.len(), 1);
    }
}
