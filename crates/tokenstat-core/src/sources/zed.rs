//! Zed agent thread reader.
//!
//! Layout on disk (macOS):
//!
//! ```text
//! ~/Library/Application Support/Zed/threads/threads.db
//! ```
//!
//! Each `threads` row stores a JSON blob, usually zstd-compressed
//! (`data_type = "zstd"`, legacy `"json"`). Usage lives in
//! `request_token_usage` (per user-message id) and `cumulative_token_usage`
//! (thread total). Fields match Anthropic-style disjoint cache counters.
//!
//! Prefer per-request rows when present. If their sum is below the cumulative
//! total, emit one remainder event so the archive matches Zed's own total.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the Zed threads database.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let candidates = [
        home.join("Library/Application Support/Zed/threads/threads.db"),
        home.join(".local/share/zed/threads/threads.db"),
        home.join(".config/zed/threads/threads.db"),
    ];
    candidates.into_iter().find(|p| p.is_file())
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

#[derive(Deserialize, Default)]
struct TokenUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
}

impl TokenUsage {
    fn is_empty(&self) -> bool {
        self.input_tokens == 0
            && self.output_tokens == 0
            && self.cache_creation_input_tokens == 0
            && self.cache_read_input_tokens == 0
    }

    fn total(&self) -> u64 {
        self.input_tokens
            .saturating_add(self.output_tokens)
            .saturating_add(self.cache_creation_input_tokens)
            .saturating_add(self.cache_read_input_tokens)
    }
}

#[derive(Deserialize)]
struct ThreadData {
    #[serde(default)]
    cumulative_token_usage: TokenUsage,
    #[serde(default)]
    request_token_usage: HashMap<String, TokenUsage>,
    model: Option<ModelInfo>,
    updated_at: Option<String>,
}

#[derive(Deserialize)]
struct ModelInfo {
    model: Option<String>,
    #[allow(dead_code)]
    provider: Option<String>,
}

/// Read every thread that carries token counters.
pub fn parse_db(path: &Path) -> ParseOutput {
    let mut out = ParseOutput::default();
    let conn = match rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    let mut stmt = match conn.prepare(
        "SELECT id, COALESCE(summary, ''), COALESCE(updated_at, ''), COALESCE(data_type, ''), data FROM threads",
    ) {
        Ok(s) => s,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    let rows = match stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<Vec<u8>>>(4)?,
        ))
    }) {
        Ok(rows) => rows,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    for row in rows {
        let Ok((id, _summary, updated_at, data_type, data)) = row else {
            continue;
        };
        let Some(data) = data else {
            continue;
        };
        let json_bytes = match decode_thread_blob(&data_type, &data) {
            Ok(b) => b,
            Err(reason) => {
                out.warnings.push(Warning::Unreadable {
                    path: path.to_path_buf(),
                    reason: format!("thread {id}: {reason}"),
                });
                continue;
            }
        };
        let thread: ThreadData = match serde_json::from_slice(&json_bytes) {
            Ok(t) => t,
            Err(_) => {
                out.warnings.push(Warning::MalformedLine {
                    path: path.to_path_buf(),
                    line: 0,
                });
                continue;
            }
        };

        let model = thread
            .model
            .as_ref()
            .and_then(|m| m.model.clone())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".to_string());
        // Thread id only. Summary/title are conversation text and must not
        // cross the parser boundary into the archive (or sync proj hashing).
        let project = id.clone();
        let ts_ms = parse_rfc3339(thread.updated_at.as_deref().or(Some(updated_at.as_str())));

        let mut request_sum = TokenUsage::default();
        for (req_id, usage) in &thread.request_token_usage {
            if usage.is_empty() {
                continue;
            }
            out.rows_seen += 1;
            request_sum.input_tokens = request_sum.input_tokens.saturating_add(usage.input_tokens);
            request_sum.output_tokens = request_sum
                .output_tokens
                .saturating_add(usage.output_tokens);
            request_sum.cache_creation_input_tokens = request_sum
                .cache_creation_input_tokens
                .saturating_add(usage.cache_creation_input_tokens);
            request_sum.cache_read_input_tokens = request_sum
                .cache_read_input_tokens
                .saturating_add(usage.cache_read_input_tokens);

            out.events.push(event_from_usage(
                &id,
                req_id,
                usage,
                &model,
                &project,
                ts_ms,
                Confidence::Exact,
            ));
        }

        let cum = &thread.cumulative_token_usage;
        if cum.is_empty() {
            continue;
        }

        // Remainder so totals match Zed's cumulative when request map undercounts.
        let rem = TokenUsage {
            input_tokens: cum.input_tokens.saturating_sub(request_sum.input_tokens),
            output_tokens: cum.output_tokens.saturating_sub(request_sum.output_tokens),
            cache_creation_input_tokens: cum
                .cache_creation_input_tokens
                .saturating_sub(request_sum.cache_creation_input_tokens),
            cache_read_input_tokens: cum
                .cache_read_input_tokens
                .saturating_sub(request_sum.cache_read_input_tokens),
        };

        if request_sum.is_empty() {
            out.rows_seen += 1;
            out.events.push(event_from_usage(
                &id,
                "cumulative",
                cum,
                &model,
                &project,
                ts_ms,
                Confidence::Strong,
            ));
        } else if !rem.is_empty() && rem.total() > 0 {
            out.rows_seen += 1;
            out.events.push(event_from_usage(
                &id,
                "cumulative-remainder",
                &rem,
                &model,
                &project,
                ts_ms,
                Confidence::Derived,
            ));
        }
    }

    out
}

fn event_from_usage(
    thread_id: &str,
    req_id: &str,
    usage: &TokenUsage,
    model: &str,
    project: &str,
    ts_ms: i64,
    confidence: Confidence,
) -> UsageEvent {
    UsageEvent {
        id: EventId::derive(&["zed", thread_id, req_id]),
        source: SourceId::Zed,
        ts: Timestamp::from_ms(ts_ms),
        model: model.to_string(),
        session: thread_id.to_string(),
        project: project.to_string(),
        counters: Counters {
            input_fresh: Some(usage.input_tokens),
            cache_read: Some(usage.cache_read_input_tokens),
            cache_write_5m: Some(usage.cache_creation_input_tokens),
            cache_write_1h: None,
            output: Some(usage.output_tokens),
        },
        extras: Extras::default(),
        billing: BillingMode::Plan,
        confidence,
    }
}

fn decode_thread_blob(data_type: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    match data_type {
        "zstd" | "" => zstd::decode_all(data).map_err(|e| e.to_string()),
        "json" => Ok(data.to_vec()),
        other => {
            // Try zstd first (common), then raw JSON.
            zstd::decode_all(data).or_else(|_| {
                if data.starts_with(b"{") {
                    Ok(data.to_vec())
                } else {
                    Err(format!("unsupported data_type {other:?}"))
                }
            })
        }
    }
}

fn parse_rfc3339(s: Option<&str>) -> i64 {
    s.and_then(|text| {
        text.parse::<jiff::Timestamp>()
            .ok()
            .map(|ts| ts.as_millisecond())
    })
    .unwrap_or(0)
    .max(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn tempfile_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-zed-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_thread_db(path: &Path, thread_json: &str) {
        let conn = Connection::open(path).unwrap();
        conn.execute_batch(
            "CREATE TABLE threads (
               id TEXT PRIMARY KEY,
               summary TEXT,
               updated_at TEXT,
               data_type TEXT,
               data BLOB
             );",
        )
        .unwrap();
        let compressed = zstd::encode_all(thread_json.as_bytes(), 0).unwrap();
        conn.execute(
            "INSERT INTO threads (id, summary, updated_at, data_type, data) VALUES (?1, ?2, ?3, 'zstd', ?4)",
            rusqlite::params![
                "thread-1",
                "demo",
                "2026-06-17T12:32:28.507586Z",
                compressed
            ],
        )
        .unwrap();
    }

    #[test]
    fn parses_request_map_and_remainder() {
        let dir = tempfile_dir();
        let path = dir.join("threads.db");
        let json = r#"{
          "title": "demo",
          "updated_at": "2026-06-17T12:32:28.507586Z",
          "model": {"provider": "anthropic", "model": "claude-sonnet-4-6"},
          "request_token_usage": {
            "msg-1": {"input_tokens": 10, "output_tokens": 2, "cache_read_input_tokens": 1}
          },
          "cumulative_token_usage": {
            "input_tokens": 30,
            "output_tokens": 5,
            "cache_creation_input_tokens": 4,
            "cache_read_input_tokens": 1
          }
        }"#;
        write_thread_db(&path, json);
        let out = parse_db(&path);
        assert_eq!(out.events.len(), 2);
        assert_eq!(out.events[0].counters.input_fresh, Some(10));
        assert_eq!(out.events[0].confidence, Confidence::Exact);
        let rem = out
            .events
            .iter()
            .find(|e| e.confidence == Confidence::Derived)
            .unwrap();
        assert_eq!(rem.counters.input_fresh, Some(20));
        assert_eq!(rem.counters.output, Some(3));
        assert_eq!(rem.counters.cache_write_5m, Some(4));
    }

    #[test]
    fn empty_usage_yields_no_events() {
        let dir = tempfile_dir();
        let path = dir.join("threads.db");
        write_thread_db(
            &path,
            r#"{"title":"x","cumulative_token_usage":{},"request_token_usage":{},"model":{"model":"m"}}"#,
        );
        assert!(parse_db(&path).events.is_empty());
    }

    #[test]
    fn cumulative_only_when_no_requests() {
        let dir = tempfile_dir();
        let path = dir.join("threads.db");
        write_thread_db(
            &path,
            r#"{
              "model": {"model": "claude-opus-4-8"},
              "updated_at": "2026-06-17T12:32:28Z",
              "request_token_usage": {},
              "cumulative_token_usage": {"input_tokens": 7, "output_tokens": 3}
            }"#,
        );
        let out = parse_db(&path);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].confidence, Confidence::Strong);
        assert_eq!(out.events[0].counters.input_fresh, Some(7));
    }
}
