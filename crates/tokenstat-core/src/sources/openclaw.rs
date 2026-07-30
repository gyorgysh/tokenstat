//! OpenClaw session reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.openclaw/agents/<agent>/sessions/sessions.json
//! ~/.openclaw/agents/<agent>/sessions/<uuid>.trajectory.jsonl
//! ```
//!
//! `sessions.json` holds per-session rollups (`inputTokens`, `outputTokens`,
//! `cacheRead`, `cacheWrite`). Those grow as the session continues, so identity
//! is the session id and re-reads keep the max via the archive upsert.
//!
//! When a trajectory `model.completed` row carries non-zero `lastCallUsage`,
//! that turn is ingested as a per-call event. Scan prefers turns: a session
//! rollup is dropped when any turn for the same session id was seen, so the
//! two sources never double-count.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the OpenClaw agents root.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = home.join(".openclaw").join("agents");
    root.is_dir().then_some(root)
}

/// Every `sessions.json` under the agents tree.
pub fn session_shards(agents: &Path) -> Vec<PathBuf> {
    walkdir::WalkDir::new(agents)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n == "sessions.json")
        })
        .collect()
}

/// Trajectory JSONL files (per-turn usage when the provider fills it).
pub fn trajectory_shards(agents: &Path) -> Vec<PathBuf> {
    walkdir::WalkDir::new(agents)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with(".trajectory.jsonl"))
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
#[serde(rename_all = "camelCase")]
struct SessionRow {
    session_id: Option<String>,
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read: Option<u64>,
    cache_write: Option<u64>,
    model: Option<String>,
    model_provider: Option<String>,
    started_at: Option<i64>,
    updated_at: Option<i64>,
    #[serde(default)]
    estimated_cost_usd: Option<f64>,
}

/// Parse one `sessions.json` object map.
pub fn parse_sessions_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let root: HashMap<String, SessionRow> = match serde_json::from_str(contents) {
        Ok(r) => r,
        Err(_) => {
            out.warnings.push(Warning::MalformedLine {
                path: path.to_path_buf(),
                line: 0,
            });
            return out;
        }
    };

    let agent = path
        .parent()
        .and_then(|sessions| sessions.parent())
        .and_then(|agent| agent.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("main")
        .to_string();

    for (key, row) in root {
        let input = row.input_tokens.unwrap_or(0);
        let output = row.output_tokens.unwrap_or(0);
        let cache_read = row.cache_read.unwrap_or(0);
        let cache_write = row.cache_write.unwrap_or(0);
        if input == 0 && output == 0 && cache_read == 0 && cache_write == 0 {
            continue;
        }

        out.rows_seen += 1;
        let session = row
            .session_id
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| key.clone());
        let model = row
            .model
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".to_string());
        let ts_ms = row
            .updated_at
            .or(row.started_at)
            .filter(|&ms| ms > 0)
            .unwrap_or(0);
        let billing = billing_for_provider(row.model_provider.as_deref());

        out.events.push(UsageEvent {
            id: EventId::derive(&["openclaw", "session", &session]),
            source: SourceId::OpenClaw,
            ts: Timestamp::from_ms(ts_ms),
            model,
            session: session.clone(),
            project: agent.clone(),
            counters: Counters {
                input_fresh: Some(input),
                cache_read: Some(cache_read),
                cache_write_5m: Some(cache_write),
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras::default(),
            billing,
            confidence: Confidence::Strong,
        });
        let _ = row.estimated_cost_usd;
    }

    out
}

/// Parse one trajectory JSONL file for per-turn usage.
pub fn parse_trajectory_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let fallback_session = path
        .file_stem()
        .and_then(|s| s.to_str())
        .map(|s| s.trim_end_matches(".trajectory").to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let agent = path
        .parent()
        .and_then(|sessions| sessions.parent())
        .and_then(|agent| agent.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("main")
        .to_string();

    for (line_no, line) in contents.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let row: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => {
                out.warnings.push(Warning::MalformedLine {
                    path: path.to_path_buf(),
                    line: line_no + 1,
                });
                continue;
            }
        };
        if row.get("type").and_then(Value::as_str) != Some("model.completed") {
            continue;
        }
        let Some(event) = parse_model_completed(&row, &fallback_session, &agent) else {
            continue;
        };
        out.rows_seen += 1;
        out.events.push(event);
    }

    out
}

fn parse_model_completed(row: &Value, fallback_session: &str, agent: &str) -> Option<UsageEvent> {
    let data = row.get("data")?;
    let usage = data
        .pointer("/promptCache/lastCallUsage")
        .or_else(|| data.get("usage"))
        .or_else(|| data.get("lastCallUsage"))?;

    let input = json_u64(usage.get("input").or_else(|| usage.get("inputTokens")));
    let output = json_u64(usage.get("output").or_else(|| usage.get("outputTokens")));
    let cache_read = json_u64(
        usage
            .get("cacheRead")
            .or_else(|| usage.get("cacheReadTokens")),
    );
    let cache_write = json_u64(
        usage
            .get("cacheWrite")
            .or_else(|| usage.get("cacheWriteTokens")),
    );
    if input == 0 && output == 0 && cache_read == 0 && cache_write == 0 {
        return None;
    }

    let session = row
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or(fallback_session)
        .to_string();
    let run_id = row.get("runId").and_then(Value::as_str).unwrap_or("");
    let seq = row
        .get("seq")
        .and_then(Value::as_u64)
        .map(|n| n.to_string())
        .unwrap_or_else(|| "0".into());
    let model = row
        .get("modelId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_string();
    let provider = row.get("provider").and_then(Value::as_str);
    let ts_ms = parse_ts(row.get("ts"));

    Some(UsageEvent {
        id: EventId::derive(&["openclaw", "turn", &session, run_id, &seq]),
        source: SourceId::OpenClaw,
        ts: Timestamp::from_ms(ts_ms),
        model,
        session,
        project: agent.to_string(),
        counters: Counters {
            input_fresh: Some(input),
            cache_read: Some(cache_read),
            cache_write_5m: Some(cache_write),
            cache_write_1h: None,
            output: Some(output),
        },
        extras: Extras::default(),
        billing: billing_for_provider(provider),
        confidence: Confidence::Exact,
    })
}

fn billing_for_provider(provider: Option<&str>) -> BillingMode {
    match provider.map(str::to_ascii_lowercase).as_deref() {
        Some("lmstudio" | "ollama" | "local") => BillingMode::Unknown,
        Some(_) => BillingMode::Metered,
        None => BillingMode::Unknown,
    }
}

fn json_u64(v: Option<&Value>) -> u64 {
    v.and_then(|inner| {
        inner
            .as_u64()
            .or_else(|| inner.as_i64().and_then(|n| u64::try_from(n).ok()))
            .or_else(|| inner.as_str().and_then(|t| t.parse().ok()))
    })
    .unwrap_or(0)
}

fn parse_ts(v: Option<&Value>) -> i64 {
    v.and_then(|inner| {
        inner
            .as_i64()
            .or_else(|| inner.as_u64().and_then(|n| i64::try_from(n).ok()))
            .or_else(|| {
                inner.as_str().and_then(|text| {
                    text.parse::<i64>().ok().or_else(|| {
                        text.parse::<jiff::Timestamp>()
                            .ok()
                            .map(|ts| ts.as_millisecond())
                    })
                })
            })
    })
    .unwrap_or(0)
    .max(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_json_maps_disjoint_counters() {
        let input = r#"{
          "agent:main:main": {
            "sessionId": "sess-1",
            "inputTokens": 100,
            "outputTokens": 20,
            "cacheRead": 50,
            "cacheWrite": 10,
            "model": "openai/gpt-oss-20b",
            "modelProvider": "lmstudio",
            "updatedAt": 1781719897412
          }
        }"#;
        let out = parse_sessions_file(
            Path::new("/h/.openclaw/agents/main/sessions/sessions.json"),
            input,
        );
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.source, SourceId::OpenClaw);
        assert_eq!(e.counters.input_fresh, Some(100));
        assert_eq!(e.counters.cache_read, Some(50));
        assert_eq!(e.counters.cache_write_5m, Some(10));
        assert_eq!(e.counters.output, Some(20));
        assert_eq!(e.project, "main");
        assert_eq!(e.billing, BillingMode::Unknown);
        assert_eq!(e.confidence, Confidence::Strong);
    }

    #[test]
    fn trajectory_skips_zero_usage() {
        let input = r#"{"type":"model.completed","sessionId":"s","runId":"r","seq":1,"ts":"2026-06-17T18:56:37.649Z","modelId":"m","provider":"lmstudio","data":{"promptCache":{"lastCallUsage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}}}
"#;
        assert!(
            parse_trajectory_file(Path::new("s.trajectory.jsonl"), input)
                .events
                .is_empty()
        );
    }

    #[test]
    fn trajectory_keeps_nonzero_turn() {
        let input = r#"{"type":"model.completed","sessionId":"s","runId":"r","seq":5,"ts":"2026-06-17T18:56:37.649Z","modelId":"openai/gpt-oss-20b","provider":"openai","data":{"promptCache":{"lastCallUsage":{"input":12,"output":4,"cacheRead":2,"cacheWrite":0}}}}
"#;
        let out = parse_trajectory_file(
            Path::new("/h/.openclaw/agents/main/sessions/s.trajectory.jsonl"),
            input,
        );
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].counters.input_fresh, Some(12));
        assert_eq!(out.events[0].billing, BillingMode::Metered);
        assert_eq!(out.events[0].confidence, Confidence::Exact);
    }
}
