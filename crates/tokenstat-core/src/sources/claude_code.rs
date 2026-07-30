//! Claude Code session log reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.claude/projects/<cwd-slug>/<sessionUuid>.jsonl
//! ~/.claude/projects/<cwd-slug>/<sessionUuid>/subagents/agent-<hex>.jsonl
//! ```
//!
//! The `<cwd-slug>` is the absolute working directory with `/` replaced by `-`,
//! so `/Users/me/git/tokenstat` becomes `-Users-me-git-tokenstat`.
//!
//! # Why the identity key is what it is
//!
//! Resuming a session rewrites earlier turns into a new file. Measured on a real
//! install, that makes roughly 55% of assistant rows duplicates of a row in some
//! other file. The per-line `uuid` is regenerated during that rewrite, so it
//! looks new every time and is the wrong key. `requestId` together with
//! `message.id` is assigned by the API and survives the rewrite, so it collapses
//! duplicates correctly.
//!
//! Subagent transcripts share their parent's `sessionId` but hold entirely
//! different requests, so they are counted rather than skipped.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Rows with this model carry no real usage.
const SYNTHETIC_MODEL: &str = "<synthetic>";

/// Locate the Claude Code project directory.
///
/// `CLAUDE_CONFIG_DIR` wins when set, matching the CLI's own behavior.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = match std::env::var_os("CLAUDE_CONFIG_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => home.join(".claude"),
    };
    let projects = root.join("projects");
    projects.is_dir().then_some(projects)
}

/// Every session transcript under `projects`, including subagent files.
pub fn shards(projects: &Path) -> Vec<PathBuf> {
    walkdir::WalkDir::new(projects)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect()
}

/// Recover the working directory from a `<cwd-slug>` directory name.
///
/// Ambiguous by nature, since the slug loses the difference between a `/` and a
/// literal `-`. Only the trailing component is used, as a display label, so the
/// ambiguity does not affect any number.
fn project_label(path: &Path, projects_root: &Path) -> String {
    path.strip_prefix(projects_root)
        .ok()
        .and_then(|rel| rel.components().next())
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .map(|slug| {
            slug.rsplit('-')
                .find(|s| !s.is_empty())
                .unwrap_or(&slug)
                .to_string()
        })
        .unwrap_or_else(|| "unknown".to_string())
}

#[derive(Deserialize)]
struct Row<'a> {
    #[serde(rename = "type")]
    kind: Option<&'a str>,
    #[serde(rename = "requestId")]
    request_id: Option<&'a str>,
    uuid: Option<&'a str>,
    #[serde(rename = "sessionId")]
    session_id: Option<&'a str>,
    timestamp: Option<&'a str>,
    message: Option<Message<'a>>,
}

#[derive(Deserialize)]
struct Message<'a> {
    id: Option<&'a str>,
    model: Option<&'a str>,
    usage: Option<Usage>,
}

/// Wire shape of `message.usage`.
///
/// `cache_creation` splits cache writes by time-to-live, which matters because
/// the two are billed at different multipliers. When it is absent we fall back
/// to the flat `cache_creation_input_tokens` and attribute it to the 5 minute
/// bucket, which is the default TTL.
#[derive(Deserialize)]
struct Usage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
    cache_creation: Option<CacheCreation>,
    server_tool_use: Option<ServerToolUse>,
    /// Present on some CLI versions. Each element restates the counters for one
    /// inference pass within the same request.
    iterations: Option<Vec<IterationUsage>>,
}

#[derive(Deserialize)]
struct CacheCreation {
    ephemeral_5m_input_tokens: Option<u64>,
    ephemeral_1h_input_tokens: Option<u64>,
}

#[derive(Deserialize)]
struct ServerToolUse {
    web_search_requests: Option<u32>,
    web_fetch_requests: Option<u32>,
}

#[derive(Deserialize)]
struct IterationUsage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
}

impl Usage {
    fn counters(&self) -> Counters {
        let (w5, w1) = match &self.cache_creation {
            Some(cc) => (cc.ephemeral_5m_input_tokens, cc.ephemeral_1h_input_tokens),
            // Flat field only: attribute to the default 5 minute TTL.
            None => (self.cache_creation_input_tokens, None),
        };
        Counters {
            // Anthropic reports cache reads separately from input_tokens, so
            // input_tokens is already the fresh portion. No subtraction needed,
            // unlike the OpenAI-shaped sources where cached is a subset.
            input_fresh: self.input_tokens,
            cache_read: self.cache_read_input_tokens,
            cache_write_5m: w5,
            cache_write_1h: w1,
            output: self.output_tokens,
        }
    }
}

/// Outcome of reading one transcript.
#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    /// Assistant rows seen, before deduplication. Useful for reporting how much
    /// duplication the log actually contained.
    pub rows_seen: u64,
}

/// Parse one transcript into normalized events.
///
/// Deduplication happens later, at insert time, because a duplicate row is
/// usually in a *different* file than the original.
pub fn parse_file(path: &Path, projects_root: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let project = project_label(path, projects_root);

    for (i, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // Cheap reject before paying for a JSON parse. Most lines in a
        // transcript are user turns and tool results with no usage at all.
        if !line.contains("\"usage\"") {
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

        if row.kind != Some("assistant") {
            continue;
        }
        let Some(message) = row.message else { continue };
        let Some(usage) = message.usage else { continue };
        let model = message.model.unwrap_or("unknown");
        if model == SYNTHETIC_MODEL {
            continue;
        }

        out.rows_seen += 1;

        // Identity ladder. requestId plus message.id is provider-assigned and
        // survives a session-resume rewrite; the rest is a fallback for the
        // small number of rows that lack a requestId.
        let (id, confidence) = match (row.request_id, message.id) {
            (Some(req), Some(mid)) => (
                EventId::derive(&["claude_code", req, mid]),
                Confidence::Exact,
            ),
            (None, Some(mid)) => (
                EventId::derive(&["claude_code", "msg", mid]),
                Confidence::Strong,
            ),
            (Some(req), None) => (
                EventId::derive(&["claude_code", "req", req]),
                Confidence::Strong,
            ),
            (None, None) => match row.uuid {
                // Last resort. The uuid is regenerated on rewrite, so this can
                // over-count, which is why it is reported as derived.
                Some(u) => (
                    EventId::derive(&["claude_code", "uuid", u]),
                    Confidence::Derived,
                ),
                None => {
                    out.warnings.push(Warning::MissingIdentity {
                        path: path.to_path_buf(),
                        line: i + 1,
                    });
                    continue;
                }
            },
        };

        let counters = usage.counters();

        // Where `iterations` is present it should restate the top-level
        // counters. Verify rather than assume: if a future version makes the
        // top level a partial figure, silently trusting it would undercount.
        if let Some(iters) = &usage.iterations {
            if let Some(last) = iters.last() {
                let mismatch = last.output_tokens != usage.output_tokens
                    || last.input_tokens != usage.input_tokens
                    || last.cache_read_input_tokens != usage.cache_read_input_tokens
                    || last.cache_creation_input_tokens != usage.cache_creation_input_tokens;
                if mismatch {
                    out.warnings.push(Warning::IterationMismatch {
                        path: path.to_path_buf(),
                        line: i + 1,
                    });
                }
            }
        }

        let ts = row
            .timestamp
            .and_then(parse_iso8601_ms)
            .map(Timestamp::from_ms)
            .unwrap_or(Timestamp::from_ms(0));

        out.events.push(UsageEvent {
            id,
            source: SourceId::ClaudeCode,
            ts,
            model: model.to_string(),
            session: row.session_id.unwrap_or("unknown").to_string(),
            project: project.clone(),
            counters,
            extras: Extras {
                reasoning_within_output: None,
                web_search_requests: usage
                    .server_tool_use
                    .as_ref()
                    .and_then(|s| s.web_search_requests),
                web_fetch_requests: usage
                    .server_tool_use
                    .as_ref()
                    .and_then(|s| s.web_fetch_requests),
            },
            // Claude Code is normally used on a subscription. Reporting this as
            // metered would present plan usage as money charged, which the
            // product rules forbid.
            billing: BillingMode::Plan,
            confidence,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        PathBuf::from("/home/u/.claude/projects")
    }
    fn file() -> PathBuf {
        PathBuf::from("/home/u/.claude/projects/-Users-me-git-tokenstat/s1.jsonl")
    }

    #[test]
    fn parses_usage_and_maps_cache_buckets() {
        let line = r#"{"type":"assistant","requestId":"req_1","sessionId":"s1","timestamp":"2026-07-28T10:00:00.000Z","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":5000,"cache_creation_input_tokens":700,"cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":500}}}}"#;
        let out = parse_file(&file(), &root(), line);
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.model, "claude-opus-4-8");
        assert_eq!(e.project, "tokenstat");
        assert_eq!(e.counters.input_fresh, Some(10));
        assert_eq!(e.counters.cache_read, Some(5000));
        assert_eq!(e.counters.cache_write_5m, Some(200));
        assert_eq!(e.counters.cache_write_1h, Some(500));
        assert_eq!(e.counters.output, Some(100));
        assert_eq!(e.counters.total(), 5810);
        assert_eq!(e.confidence, Confidence::Exact);
        assert_eq!(e.billing, BillingMode::Plan);
    }

    #[test]
    fn flat_cache_creation_falls_back_to_the_5m_bucket() {
        let line = r#"{"type":"assistant","requestId":"r","sessionId":"s","timestamp":"2026-07-28T10:00:00Z","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":900}}}"#;
        let out = parse_file(&file(), &root(), line);
        let c = out.events[0].counters;
        assert_eq!(c.cache_write_5m, Some(900));
        assert_eq!(c.cache_write_1h, None);
    }

    #[test]
    fn identical_requests_in_different_files_share_an_id() {
        // The same request, rewritten into a resumed session with a new uuid.
        let a = r#"{"type":"assistant","requestId":"req_9","uuid":"u-aaa","sessionId":"s1","timestamp":"2026-07-28T10:00:00Z","message":{"id":"msg_9","model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#;
        let b = r#"{"type":"assistant","requestId":"req_9","uuid":"u-bbb","sessionId":"s2","timestamp":"2026-07-28T10:00:00Z","message":{"id":"msg_9","model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#;
        let ea = parse_file(&file(), &root(), a);
        let eb = parse_file(&file(), &root(), b);
        assert_eq!(ea.events[0].id, eb.events[0].id);
    }

    #[test]
    fn synthetic_rows_are_excluded() {
        let line = r#"{"type":"assistant","requestId":"r","sessionId":"s","timestamp":"2026-07-28T10:00:00Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}"#;
        let out = parse_file(&file(), &root(), line);
        assert!(out.events.is_empty());
        assert_eq!(out.rows_seen, 0);
    }

    #[test]
    fn non_assistant_rows_are_ignored() {
        let line = r#"{"type":"user","message":{"usage":{"input_tokens":5}}}"#;
        assert!(parse_file(&file(), &root(), line).events.is_empty());
    }

    #[test]
    fn missing_request_id_falls_back_to_message_id() {
        let line = r#"{"type":"assistant","sessionId":"s","timestamp":"2026-07-28T10:00:00Z","message":{"id":"msg_x","model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#;
        let out = parse_file(&file(), &root(), line);
        assert_eq!(out.events[0].confidence, Confidence::Strong);
    }

    #[test]
    fn malformed_lines_warn_and_do_not_abort() {
        let input = format!(
            "{}\n{}\n",
            r#"{"type":"assistant","usage":"#,
            r#"{"type":"assistant","requestId":"r","sessionId":"s","timestamp":"2026-07-28T10:00:00Z","message":{"id":"m","model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#
        );
        let out = parse_file(&file(), &root(), &input);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.warnings.len(), 1);
    }

    #[test]
    fn iteration_mismatch_is_reported() {
        let line = r#"{"type":"assistant","requestId":"r","sessionId":"s","timestamp":"2026-07-28T10:00:00Z","message":{"id":"m","model":"m","usage":{"input_tokens":1,"output_tokens":10,"iterations":[{"input_tokens":1,"output_tokens":4},{"input_tokens":1,"output_tokens":99}]}}}"#;
        let out = parse_file(&file(), &root(), line);
        assert_eq!(out.events.len(), 1);
        assert!(matches!(
            out.warnings.as_slice(),
            [Warning::IterationMismatch { .. }]
        ));
    }

    #[test]
    fn iterations_matching_the_top_level_produce_no_warning() {
        let line = r#"{"type":"assistant","requestId":"r","sessionId":"s","timestamp":"2026-07-28T10:00:00Z","message":{"id":"m","model":"m","usage":{"input_tokens":1,"output_tokens":10,"iterations":[{"input_tokens":1,"output_tokens":10}]}}}"#;
        let out = parse_file(&file(), &root(), line);
        assert!(out.warnings.is_empty());
    }
}
