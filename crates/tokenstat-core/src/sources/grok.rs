//! Grok CLI unified log reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.grok/logs/unified.jsonl
//! ~/.grok/sessions/<pct-encoded-cwd>/<uuid>/summary.json
//! ```
//!
//! Usage lives on lines where `msg == "shell.turn.inference_done"`. Counters are
//! under `ctx`: `prompt_tokens`, `cached_prompt_tokens`, `completion_tokens`,
//! `reasoning_tokens`. Identity is `(sid, loop_index, ts)`.
//!
//! # Cache is a subset
//!
//! Like Codex, `cached_prompt_tokens` is already counted inside `prompt_tokens`.
//! Fresh input is the difference. Adding them would double-count.
//!
//! # Model attribution
//!
//! The inference event has no model field. The session's `summary.json`
//! `current_model_id` is joined by `sid`. The cumulative `updates.jsonl` stream
//! is deliberately not ingested: summing it would inflate without bound.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the Grok home directory.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = match std::env::var_os("GROK_HOME") {
        Some(dir) => PathBuf::from(dir),
        None => home.join(".grok"),
    };
    root.is_dir().then_some(root)
}

/// The primary append-only usage log, if present.
pub fn log_path(grok_home: &Path) -> Option<PathBuf> {
    let p = grok_home.join("logs").join("unified.jsonl");
    p.is_file().then_some(p)
}

/// Session id → model and project, read from each session's `summary.json`.
pub fn session_index(grok_home: &Path) -> HashMap<String, SessionMeta> {
    let mut out = HashMap::new();
    let sessions = grok_home.join("sessions");
    if !sessions.is_dir() {
        return out;
    }
    for entry in walkdir::WalkDir::new(&sessions)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .filter(|e| e.file_name() == "summary.json")
    {
        let path = entry.path();
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let Ok(summary) = serde_json::from_str::<SummaryFile>(&text) else {
            continue;
        };
        let sid = path
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();
        if sid.is_empty() {
            continue;
        }
        let project = path
            .parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .map(percent_decode_project)
            .unwrap_or_else(|| "unknown".to_string());
        out.insert(
            sid,
            SessionMeta {
                model: summary
                    .current_model_id
                    .unwrap_or_else(|| "unknown".to_string()),
                project,
            },
        );
    }
    out
}

#[derive(Debug, Clone)]
pub struct SessionMeta {
    pub model: String,
    pub project: String,
}

#[derive(Deserialize)]
struct SummaryFile {
    current_model_id: Option<String>,
}

fn percent_decode_project(encoded: &str) -> String {
    // Session parent dirs are percent-encoded absolute paths. Take the last
    // segment as the project name, matching how Codex reports cwd basenames.
    let decoded = percent_decode(encoded);
    decoded
        .rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_string()
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(a), Some(b)) = (from_hex(bytes[i + 1]), from_hex(bytes[i + 2])) {
                out.push((a << 4) | b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn from_hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[derive(Deserialize)]
struct Row<'a> {
    msg: Option<&'a str>,
    sid: Option<&'a str>,
    ts: Option<&'a str>,
    ctx: Option<Ctx>,
}

#[derive(Deserialize)]
struct Ctx {
    loop_index: Option<u64>,
    prompt_tokens: Option<u64>,
    cached_prompt_tokens: Option<u64>,
    completion_tokens: Option<u64>,
    reasoning_tokens: Option<u64>,
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Parse the unified log, joining models from `sessions`.
pub fn parse_file(
    path: &Path,
    contents: &str,
    sessions: &HashMap<String, SessionMeta>,
) -> ParseOutput {
    let mut out = ParseOutput::default();

    for (i, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(row) = serde_json::from_str::<Row>(line) else {
            out.warnings.push(Warning::MalformedLine {
                path: path.to_path_buf(),
                line: i + 1,
            });
            continue;
        };
        if row.msg != Some("shell.turn.inference_done") {
            continue;
        }
        let Some(ctx) = row.ctx else { continue };
        let Some(sid) = row.sid.filter(|s| !s.is_empty()) else {
            out.warnings.push(Warning::MissingIdentity {
                path: path.to_path_buf(),
                line: i + 1,
            });
            continue;
        };
        let Some(loop_index) = ctx.loop_index else {
            out.warnings.push(Warning::MissingIdentity {
                path: path.to_path_buf(),
                line: i + 1,
            });
            continue;
        };
        let Some(ts_raw) = row.ts else {
            out.warnings.push(Warning::MissingIdentity {
                path: path.to_path_buf(),
                line: i + 1,
            });
            continue;
        };

        let prompt = ctx.prompt_tokens.unwrap_or(0);
        let cached = ctx.cached_prompt_tokens.unwrap_or(0);
        let completion = ctx.completion_tokens.unwrap_or(0);
        let reasoning = ctx.reasoning_tokens.unwrap_or(0);
        if prompt == 0 && completion == 0 && cached == 0 {
            continue;
        }

        out.rows_seen += 1;
        let meta = sessions.get(sid);
        let model = meta
            .map(|m| m.model.clone())
            .unwrap_or_else(|| "unknown".to_string());
        let project = meta
            .map(|m| m.project.clone())
            .unwrap_or_else(|| "unknown".to_string());

        let ts = ts_raw
            .parse::<jiff::Timestamp>()
            .map(|t| Timestamp::from_ms(t.as_millisecond()))
            .unwrap_or(Timestamp::from_ms(0));

        out.events.push(UsageEvent {
            id: EventId::derive(&["grok", sid, &loop_index.to_string(), ts_raw]),
            source: SourceId::Grok,
            ts,
            model,
            session: sid.to_string(),
            project,
            counters: Counters {
                input_fresh: Some(prompt.saturating_sub(cached)),
                cache_read: ctx.cached_prompt_tokens,
                cache_write_5m: None,
                cache_write_1h: None,
                output: Some(completion),
            },
            extras: Extras {
                reasoning_within_output: ctx.reasoning_tokens.filter(|_| reasoning > 0),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            billing: BillingMode::Unknown,
            confidence: Confidence::Strong,
        });
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> PathBuf {
        PathBuf::from("/h/.grok/logs/unified.jsonl")
    }

    fn sessions() -> HashMap<String, SessionMeta> {
        HashMap::from([(
            "sess-1".into(),
            SessionMeta {
                model: "grok-4.5".into(),
                project: "tokenstat".into(),
            },
        )])
    }

    fn row(
        sid: &str,
        loop_index: u64,
        ts: &str,
        prompt: u64,
        cached: u64,
        completion: u64,
        reasoning: u64,
    ) -> String {
        format!(
            r#"{{"msg":"shell.turn.inference_done","sid":"{sid}","ts":"{ts}","ctx":{{"loop_index":{loop_index},"prompt_tokens":{prompt},"cached_prompt_tokens":{cached},"completion_tokens":{completion},"reasoning_tokens":{reasoning}}}}}"#
        )
    }

    #[test]
    fn cached_tokens_are_subtracted_from_prompt() {
        let input = format!(
            "{}\n",
            row(
                "sess-1",
                0,
                "2026-07-01T18:15:59.894Z",
                11296,
                10432,
                536,
                529
            )
        );
        let out = parse_file(&p(), &input, &sessions());
        assert_eq!(out.events.len(), 1);
        let c = out.events[0].counters;
        assert_eq!(c.input_fresh, Some(11296 - 10432));
        assert_eq!(c.cache_read, Some(10432));
        assert_eq!(c.input_fresh.unwrap() + c.cache_read.unwrap(), 11296);
        assert_eq!(c.output, Some(536));
        assert_eq!(out.events[0].extras.reasoning_within_output, Some(529));
    }

    #[test]
    fn model_and_project_come_from_the_session_index() {
        let input = format!(
            "{}\n",
            row("sess-1", 1, "2026-07-01T18:16:00.000Z", 10, 0, 5, 0)
        );
        let e = &parse_file(&p(), &input, &sessions()).events[0];
        assert_eq!(e.model, "grok-4.5");
        assert_eq!(e.project, "tokenstat");
        assert_eq!(e.session, "sess-1");
    }

    #[test]
    fn unknown_sessions_still_ingest_with_placeholders() {
        let input = format!(
            "{}\n",
            row("orphan", 0, "2026-07-01T18:16:00.000Z", 10, 0, 5, 0)
        );
        let e = &parse_file(&p(), &input, &sessions()).events[0];
        assert_eq!(e.model, "unknown");
        assert_eq!(e.project, "unknown");
    }

    #[test]
    fn identities_are_stable_and_distinct() {
        let input = format!(
            "{}\n{}\n",
            row("sess-1", 0, "2026-07-01T18:15:59.894Z", 10, 0, 5, 0),
            row("sess-1", 1, "2026-07-01T18:16:00.000Z", 10, 0, 5, 0)
        );
        let a = parse_file(&p(), &input, &sessions());
        let b = parse_file(&p(), &input, &sessions());
        assert_eq!(a.events[0].id, b.events[0].id);
        assert_ne!(a.events[0].id, a.events[1].id);
    }

    #[test]
    fn non_inference_lines_are_ignored() {
        let input = r#"{"msg":"shell.tool.exec_done","sid":"sess-1","ts":"2026-07-01T18:15:59.894Z","ctx":{}}
"#;
        assert!(parse_file(&p(), input, &sessions()).events.is_empty());
    }

    #[test]
    fn malformed_lines_warn_without_aborting() {
        let input = format!(
            "{{bad\n{}\n",
            row("sess-1", 0, "2026-07-01T18:15:59.894Z", 10, 0, 5, 0)
        );
        let out = parse_file(&p(), &input, &sessions());
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.warnings.len(), 1);
    }

    #[test]
    fn percent_decode_extracts_the_project_basename() {
        assert_eq!(
            percent_decode_project("%2FUsers%2Fme%2Fgit%2Ftokenstat"),
            "tokenstat"
        );
    }

    #[test]
    fn missing_loop_index_is_a_warning_not_an_event() {
        let input = r#"{"msg":"shell.turn.inference_done","sid":"sess-1","ts":"2026-07-01T18:15:59.894Z","ctx":{"prompt_tokens":10,"completion_tokens":5}}
"#;
        let out = parse_file(&p(), input, &sessions());
        assert!(out.events.is_empty());
        assert!(matches!(
            out.warnings.as_slice(),
            [Warning::MissingIdentity { .. }]
        ));
    }
}
