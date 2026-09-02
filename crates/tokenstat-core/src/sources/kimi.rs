// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Kimi Code usage reader.
//!
//! Current Kimi Code keeps runtime data below `~/.kimi-code` (or
//! `KIMI_CODE_HOME`). Every main agent and subagent has an append-only
//! `wire.jsonl`. One durable `usage.record` is written for every provider
//! response and carries the model plus four disjoint counters:
//! `inputOther`, `inputCacheRead`, `inputCacheCreation`, and `output`.
//!
//! The wire also holds the conversation. [`parse_file`] therefore decodes
//! only the flat allowlisted shape of `usage.record`; serde ignores every
//! field in every other record. Nothing from a prompt or response reaches a
//! [`UsageEvent`].

use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate Kimi Code's runtime root.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = std::env::var_os("KIMI_CODE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".kimi-code"));
    root.is_dir().then_some(root)
}

/// Every main-agent and subagent wire below the session store.
pub fn wires(root: &Path) -> Vec<PathBuf> {
    let sessions = root.join("sessions");
    if !sessions.is_dir() {
        return Vec::new();
    }
    let mut files: Vec<_> = walkdir::WalkDir::new(sessions)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file() && e.file_name() == "wire.jsonl")
        .map(|e| e.into_path())
        .collect();
    files.sort();
    files
}

/// Kimi Code's exact workspace bucket key for a working directory.
///
/// This mirrors upstream's `encodeWorkDirKey`: normalized path, a slug of the
/// leaf (at most 40 characters), and the first 12 hex characters of SHA-256.
pub fn workspace_key(cwd: &str) -> String {
    let normalized = cwd.replace('\\', "/").trim_end_matches('/').to_string();
    let base = normalized.rsplit('/').next().unwrap_or(&normalized);
    let mut slug: String = base
        .to_ascii_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect();
    while slug.contains("--") {
        slug = slug.replace("--", "-");
    }
    slug = slug.trim_matches('-').chars().take(40).collect();
    slug = slug.trim_matches('-').to_string();
    if slug.is_empty() || slug == "." || slug == ".." {
        slug = "workspace".to_string();
    }
    let hash: String = Sha256::digest(normalized.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("wd_{slug}_{}", &hash[..12])
}

/// Wires belonging to one exact working directory, used by the live meter.
pub fn wires_for_cwd(root: &Path, cwd: &str) -> Vec<PathBuf> {
    let dir = root.join("sessions").join(workspace_key(cwd));
    if !dir.is_dir() {
        return Vec::new();
    }
    let mut files: Vec<_> = walkdir::WalkDir::new(dir)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file() && e.file_name() == "wire.jsonl")
        .map(|e| e.into_path())
        .collect();
    files.sort();
    files
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
    #[serde(rename = "agentId")]
    agent_id: Option<String>,
    model: Option<String>,
    usage: Option<TokenUsage>,
}

#[derive(Deserialize)]
struct TokenUsage {
    #[serde(rename = "inputOther")]
    input_other: Option<u64>,
    output: Option<u64>,
    #[serde(rename = "inputCacheRead")]
    input_cache_read: Option<u64>,
    #[serde(rename = "inputCacheCreation")]
    input_cache_creation: Option<u64>,
}

/// Decode only Kimi Code's durable usage rows from one agent wire.
pub fn parse_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let (workspace, session, path_agent) = identity_from_path(path);

    for (line_no, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let row: Row = match serde_json::from_str(line) {
            Ok(row) => row,
            Err(_) => {
                out.warnings.push(Warning::MalformedLine {
                    path: path.to_path_buf(),
                    line: line_no + 1,
                });
                continue;
            }
        };
        if row.kind.as_deref() != Some("usage.record") {
            continue;
        }
        let Some(usage) = row.usage else {
            continue;
        };
        let fresh = usage.input_other.unwrap_or(0);
        let cache_read = usage.input_cache_read.unwrap_or(0);
        let cache_write = usage.input_cache_creation.unwrap_or(0);
        let output = usage.output.unwrap_or(0);
        if fresh == 0 && cache_read == 0 && cache_write == 0 && output == 0 {
            continue;
        }
        out.rows_seen += 1;

        let ts = row.time.unwrap_or(0);
        let model = row
            .model
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| "unknown".to_string());
        let agent = row
            .agent_id
            .filter(|a| !a.is_empty())
            .unwrap_or_else(|| path_agent.clone());
        // The wire protocol has no provider request id. All stable fields are
        // used so re-reading the same append lands on the same derived event.
        let id = EventId::derive(&[
            "kimi",
            &session,
            &agent,
            &ts.to_string(),
            &model,
            &fresh.to_string(),
            &cache_read.to_string(),
            &cache_write.to_string(),
            &output.to_string(),
        ]);

        out.events.push(UsageEvent {
            id,
            source: SourceId::Kimi,
            ts: Timestamp::from_ms(ts),
            model,
            project: workspace.clone(),
            session: session.clone(),
            counters: Counters {
                input_fresh: Some(fresh),
                cache_read: Some(cache_read),
                // Kimi exposes one cache-creation bucket without a TTL. Keep
                // it in the generic short-lived bucket rather than dropping
                // real usage; pricing can still mark a missing rate incomplete.
                cache_write_5m: Some(cache_write),
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras::default(),
            // The wire does not persist whether this historical request used
            // OAuth quota or an API key. Current config cannot answer history.
            billing: BillingMode::Unknown,
            confidence: Confidence::Derived,
        });
    }
    out
}

fn identity_from_path(path: &Path) -> (String, String, String) {
    let parts: Vec<_> = path
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .collect();
    let sessions = parts.iter().rposition(|p| *p == "sessions");
    let workspace_key = sessions
        .and_then(|i| parts.get(i + 1))
        .copied()
        .unwrap_or("unknown");
    let session = sessions
        .and_then(|i| parts.get(i + 2))
        .copied()
        .unwrap_or("unknown")
        .to_string();
    let agent = parts
        .iter()
        .rposition(|p| *p == "agents")
        .and_then(|i| parts.get(i + 1))
        .copied()
        .unwrap_or("main")
        .to_string();
    (project_from_key(workspace_key), session, agent)
}

fn project_from_key(key: &str) -> String {
    key.strip_prefix("wd_")
        .and_then(|s| s.rsplit_once('_').map(|(slug, _)| slug))
        .filter(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PATH: &str =
        "/home/u/.kimi-code/sessions/wd_demo-app_0123456789ab/s1/agents/main/wire.jsonl";

    #[test]
    fn reads_model_and_all_four_disjoint_counters() {
        let text = r#"{"type":"usage.record","agentId":"main","model":"kimi-k2.5","usage":{"inputOther":120,"output":30,"inputCacheRead":400,"inputCacheCreation":50},"usageScope":"turn","time":1788321000123}"#;
        let out = parse_file(Path::new(PATH), text);
        let event = &out.events[0];
        assert_eq!(event.source, SourceId::Kimi);
        assert_eq!(event.model, "kimi-k2.5");
        assert_eq!(event.project, "demo-app");
        assert_eq!(event.session, "s1");
        assert_eq!(event.counters.input_fresh, Some(120));
        assert_eq!(event.counters.cache_read, Some(400));
        assert_eq!(event.counters.cache_write_5m, Some(50));
        assert_eq!(event.counters.output, Some(30));
        assert_eq!(event.counters.total(), 600);
        assert_eq!(event.ts, Timestamp::from_ms(1788321000123));
    }

    #[test]
    fn conversation_rows_are_ignored() {
        let text = r#"{"type":"context.append_message","message":{"role":"user","content":"private"},"time":1}
{"type":"usage.record","agentId":"main","model":"m","usage":{"inputOther":1,"output":2,"inputCacheRead":0,"inputCacheCreation":0},"time":2}"#;
        let out = parse_file(Path::new(PATH), text);
        assert_eq!(out.events.len(), 1);
        assert!(out.warnings.is_empty());
    }

    #[test]
    fn subagent_identity_comes_from_its_wire() {
        let path = Path::new("/x/sessions/wd_repo_0123456789ab/s2/agents/agent-3/wire.jsonl");
        let text = r#"{"type":"usage.record","agentId":"agent-3","model":"m","usage":{"inputOther":1,"output":2,"inputCacheRead":0,"inputCacheCreation":0},"time":2}"#;
        let first = parse_file(path, text);
        let again = parse_file(path, text);
        assert_eq!(first.events[0].id, again.events[0].id);
        assert_eq!(first.events[0].session, "s2");
    }

    #[test]
    fn workspace_key_matches_upstream_shape() {
        let key = workspace_key("/Users/x/git/Demo App/");
        assert!(key.starts_with("wd_demo-app_"));
        assert_eq!(key.len(), "wd_demo-app_".len() + 12);
        assert_eq!(key, workspace_key("/Users/x/git/Demo App"));
    }
}
