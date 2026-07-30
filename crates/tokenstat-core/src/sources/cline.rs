//! Cline session reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.cline/data/sessions/<id>/<id>.messages.json
//! ```
//!
//! Each file is a JSON object with a `messages` array. Usage lives on
//! `messages[].metrics` with Anthropic-style disjoint cache fields. Identity is
//! `(sessionId, message id)` when present, otherwise `(session, ordinal)`.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the Cline sessions directory.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = home.join(".cline").join("data").join("sessions");
    root.is_dir().then_some(root)
}

pub fn shards(sessions: &Path) -> Vec<PathBuf> {
    walkdir::WalkDir::new(sessions)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with(".messages.json"))
        })
        .collect()
}

#[derive(Deserialize)]
struct FileRoot {
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    messages: Option<Vec<Message>>,
}

#[derive(Deserialize)]
struct Message {
    id: Option<String>,
    role: Option<String>,
    ts: Option<i64>,
    metrics: Option<Metrics>,
    #[serde(rename = "modelInfo")]
    model_info: Option<ModelInfo>,
}

#[derive(Deserialize)]
struct ModelInfo {
    id: Option<String>,
    #[allow(dead_code)]
    provider: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Metrics {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_tokens: Option<u64>,
    cache_write_tokens: Option<u64>,
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Parse one session messages file.
pub fn parse_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let root: FileRoot = match serde_json::from_str(contents) {
        Ok(r) => r,
        Err(_) => {
            out.warnings.push(Warning::MalformedLine {
                path: path.to_path_buf(),
                line: 0,
            });
            return out;
        }
    };

    let session = root
        .session_id
        .or_else(|| {
            path.file_stem()
                .and_then(|s| s.to_str())
                .map(|s| s.trim_end_matches(".messages").to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    // Project is not recorded; keep the session id's basename as a stand-in so
    // reports still group somehow without inventing a path.
    let project = session.clone();

    let Some(messages) = root.messages else {
        return out;
    };

    for (ordinal, msg) in messages.into_iter().enumerate() {
        if msg.role.as_deref() == Some("user") {
            continue;
        }
        let Some(metrics) = msg.metrics else { continue };
        let input = metrics.input_tokens.unwrap_or(0);
        let output = metrics.output_tokens.unwrap_or(0);
        let cache_read = metrics.cache_read_tokens.unwrap_or(0);
        let cache_write = metrics.cache_write_tokens.unwrap_or(0);
        if input == 0 && output == 0 && cache_read == 0 && cache_write == 0 {
            continue;
        }

        out.rows_seen += 1;
        let identity = msg.id.clone().unwrap_or_else(|| ordinal.to_string());
        let confidence = if msg.id.is_some() {
            Confidence::Exact
        } else {
            Confidence::Derived
        };
        let model = msg
            .model_info
            .as_ref()
            .and_then(|m| m.id.clone())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".to_string());

        out.events.push(UsageEvent {
            id: EventId::derive(&["cline", &session, &identity]),
            source: SourceId::Cline,
            ts: Timestamp::from_ms(msg.ts.unwrap_or(0)),
            model,
            session: session.clone(),
            project: project.clone(),
            counters: Counters {
                // Anthropic-style: cache fields are separate from input.
                input_fresh: metrics.input_tokens,
                cache_read: metrics.cache_read_tokens,
                cache_write_5m: metrics.cache_write_tokens,
                cache_write_1h: None,
                output: metrics.output_tokens,
            },
            extras: Extras::default(),
            billing: BillingMode::Unknown,
            confidence,
        });
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> PathBuf {
        PathBuf::from("/h/.cline/data/sessions/s1/s1.messages.json")
    }

    #[test]
    fn metrics_map_onto_disjoint_buckets() {
        let input = r#"{
          "sessionId":"s1",
          "messages":[
            {"id":"m1","role":"assistant","ts":1781700000000,
             "modelInfo":{"id":"claude-sonnet-4-6","provider":"anthropic"},
             "metrics":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":50,"cacheWriteTokens":10}}
          ]
        }"#;
        let out = parse_file(&p(), input);
        assert_eq!(out.events.len(), 1);
        let c = out.events[0].counters;
        assert_eq!(c.input_fresh, Some(100));
        assert_eq!(c.cache_read, Some(50));
        assert_eq!(c.cache_write_5m, Some(10));
        assert_eq!(c.output, Some(20));
        assert_eq!(out.events[0].model, "claude-sonnet-4-6");
        assert_eq!(out.events[0].confidence, Confidence::Exact);
    }

    #[test]
    fn user_messages_are_skipped() {
        let input = r#"{
          "sessionId":"s1",
          "messages":[
            {"id":"u1","role":"user","ts":1,"metrics":{"inputTokens":1,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}}
          ]
        }"#;
        assert!(parse_file(&p(), input).events.is_empty());
    }

    #[test]
    fn missing_message_id_falls_back_to_ordinal() {
        let input = r#"{
          "sessionId":"s1",
          "messages":[
            {"role":"assistant","ts":1,"metrics":{"inputTokens":1,"outputTokens":1,"cacheReadTokens":0,"cacheWriteTokens":0}},
            {"role":"assistant","ts":2,"metrics":{"inputTokens":2,"outputTokens":2,"cacheReadTokens":0,"cacheWriteTokens":0}}
          ]
        }"#;
        let out = parse_file(&p(), input);
        assert_eq!(out.events.len(), 2);
        assert_ne!(out.events[0].id, out.events[1].id);
        assert_eq!(out.events[0].confidence, Confidence::Derived);
    }

    #[test]
    fn malformed_json_warns_without_aborting() {
        let out = parse_file(&p(), "{bad");
        assert!(out.events.is_empty());
        assert_eq!(out.warnings.len(), 1);
    }
}
