// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Muse session reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.local/share/muse/sessions/<yyyy>/<mm>/<dd>/<session-id>/session.jsonl
//! ~/.local/share/muse/sessions/<yyyy>/<mm>/<dd>/<session-id>/subagent/<id>/session.jsonl
//! ```
//!
//! Every line is one record in an event log: `{schema_version, stream, id,
//! sequence, recorded_at, record_type, payload_type, payload}`. Most of them
//! are `runtime.session`, whose `payload.event.kind` says what actually
//! happened. **`model_completed` is the one that carries counters**, and it
//! carries exactly the four things a reader needs:
//!
//! ```json
//! {"kind":"model_completed","model":"muse-spark-1.2","duration_ms":7202,
//!  "finish_reason":"tool_calls",
//!  "usage":{"input_tokens":37538,"output_tokens":97,"cached_tokens":35313,
//!           "cache_write_tokens":0,"cache_read_tokens":35313,
//!           "reasoning_tokens":0}}
//! ```
//!
//! `recorded_at` is **microseconds** since the epoch, not milliseconds.
//!
//! ## What the numbers mean, and how that was established
//!
//! Checked against 239 real `model_completed` records:
//!
//! - `cached_tokens == cache_read_tokens` in every one of them. It is the same
//!   figure under two names, so counting both would double the cache read.
//! - `cache_read_tokens + cache_write_tokens <= input_tokens` in every one.
//!   `input_tokens` is therefore the **whole** prompt and the cache figures are
//!   the part of it that came from cache, so fresh input is the difference. The
//!   alternative reading has a session whose first call spent 35,336 prompt
//!   tokens spending 72,851 on its second, which is not what a cached prefix
//!   plus one tool result costs.
//! - `output_tokens >= reasoning_tokens` in all 39 records that reasoned.
//!   Together with the field sitting beside `output_tokens` in an
//!   OpenAI-shaped usage block, that reads as reasoning **inside** output, so
//!   it is folded there and the split kept in `extras`.
//!
//! ## Subagents
//!
//! A subagent gets its own directory and its own `session.jsonl` with its own
//! `model_completed` records, so walking every `session.jsonl` counts them once
//! each. The parent session separately writes `subagent.control.runtime_observed`
//! carrying the child's **cumulative** usage, and `goal_usage_attribution`
//! records that attribute the same spend to goals. Both would double count, and
//! keying on `model_completed` alone is what avoids them.
//!
//! ## Project
//!
//! `runtime.session.metadata` carries `record.workspace_root`, and
//! `session.workspace_branch.observed` carries it again. Both sit at the head
//! of the file, which a resumed tail read never sees, so the header is read
//! from disk separately and bounded. A subagent's metadata has no workspace of
//! its own, but its `workspace_branch` record does.
//!
//! ## Billing
//!
//! Muse writes no cost, and its model catalogue lists `cost: null` for every
//! `muse-spark` model. That is not the same as knowing the usage is covered by
//! a plan, so this reports [`BillingMode::Unknown`] rather than inventing
//! either answer.

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the sessions root.
pub fn discover(home: &Path) -> Option<PathBuf> {
    // XDG data home, which is where it puts everything on macOS too rather
    // than Application Support. Application Support holds only the session
    // name authority, which has no counters in it.
    let candidates = [
        home.join(".local/share/muse/sessions"),
        home.join("Library/Application Support/muse/sessions"),
    ];
    candidates.into_iter().find(|p| p.is_dir())
}

/// Every session transcript under the root, subagents included.
pub fn shards(root: &Path) -> Vec<PathBuf> {
    walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| p.file_name().and_then(|n| n.to_str()) == Some("session.jsonl"))
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
    /// Unique per record, so a re-read lands on the same event.
    id: Option<String>,
    /// Microseconds since the epoch.
    recorded_at: Option<i64>,
    payload: Option<Payload>,
}

#[derive(Deserialize)]
struct Payload {
    event: Option<Event>,
}

#[derive(Deserialize)]
struct Event {
    kind: Option<String>,
    model: Option<String>,
    usage: Option<Usage>,
}

/// Only the token fields. `resource_usage_sampled` also has a `usage`, holding
/// resident memory and CPU milliseconds, and it is skipped by kind rather than
/// by shape, but nothing here would read a byte count as a token either.
#[derive(Deserialize)]
struct Usage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_write_tokens: Option<u64>,
    cache_read_tokens: Option<u64>,
    reasoning_tokens: Option<u64>,
}

/// Read one session file.
///
/// `contents` is the text appended since the last scan, which for a resumed
/// read starts mid-file. The project comes from the head of the file on disk
/// for that reason.
pub fn parse_file(path: &Path, contents: &str) -> ParseOutput {
    let mut out = ParseOutput::default();
    let session = session_id(path);
    let project = workspace_project(path).unwrap_or_else(|| "unknown".to_string());

    for (i, line) in contents.lines().enumerate() {
        let line = line.trim();
        // Most of a session log is tool output and streamed deltas. One
        // substring test is what keeps this from deserializing megabytes of
        // records that cannot carry counters.
        if line.is_empty() || !line.contains("model_completed") {
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
        let Some(event) = row.payload.and_then(|p| p.event) else {
            continue;
        };
        if event.kind.as_deref() != Some("model_completed") {
            continue;
        }
        let Some(usage) = event.usage else { continue };

        let input = usage.input_tokens.unwrap_or(0);
        let cache_read = usage.cache_read_tokens.unwrap_or(0);
        let cache_write = usage.cache_write_tokens.unwrap_or(0);
        let output = usage.output_tokens.unwrap_or(0);
        // A refusal or a cancelled call writes zeroes. A zero row is not a
        // fact about spend, and keeping it would put empty turns in the count.
        if input == 0 && output == 0 {
            continue;
        }
        out.rows_seen += 1;

        let ts = row
            .recorded_at
            .map(|us| Timestamp::from_ms(us / 1_000))
            .unwrap_or_else(|| Timestamp::from_ms(0));
        let id = match row.id.as_deref() {
            Some(id) if !id.is_empty() => EventId::derive(&["muse", id]),
            _ => EventId::derive(&["muse", &session, &i.to_string()]),
        };

        out.events.push(UsageEvent {
            id,
            source: SourceId::Muse,
            ts,
            model: event
                .model
                .filter(|m| !m.is_empty())
                .unwrap_or_else(|| "unknown".to_string()),
            session: session.clone(),
            project: project.clone(),
            counters: Counters {
                // The cache figures are part of `input_tokens`, so fresh input
                // is what is left of it. Saturating because a vendor that ever
                // reports them the other way round must not underflow into a
                // number the size of the universe.
                input_fresh: Some(input.saturating_sub(cache_read).saturating_sub(cache_write)),
                cache_read: Some(cache_read),
                cache_write_5m: Some(cache_write),
                // Muse has one cache tier, so the hour bucket is not
                // unreported, it is genuinely zero.
                cache_write_1h: Some(0),
                output: Some(output),
            },
            extras: Extras {
                reasoning_within_output: usage.reasoning_tokens.filter(|&r| r > 0),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            billing: BillingMode::Unknown,
            confidence: Confidence::Exact,
        });
    }
    out
}

/// The session id, which is the directory the log sits in. True for a subagent
/// as well, whose directory is its own id.
fn session_id(path: &Path) -> String {
    path.parent()
        .and_then(|d| d.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string()
}

/// The folder this session ran in, read from the head of the file.
///
/// Bounded on purpose: a session log reaches tens of megabytes, the records
/// that name the workspace are written in its first moments, and this runs
/// once per changed file per scan.
fn workspace_project(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut reader = BufReader::new(file.take(HEAD_BYTES));
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) | Err(_) => return None,
            Ok(_) => {}
        }
        if !line.contains("workspace_root") {
            continue;
        }
        if let Some(root) = workspace_root(&line) {
            return last_component(&root);
        }
    }
}

/// How much of a session log may be read looking for its workspace.
const HEAD_BYTES: u64 = 256 * 1024;

/// `payload.record.workspace_root`, from either the metadata record or the
/// workspace-branch one. Both spell it the same way and both are near the top.
fn workspace_root(line: &str) -> Option<String> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    #[derive(Deserialize)]
    struct Row {
        payload: Option<Payload>,
    }
    #[derive(Deserialize)]
    struct Payload {
        record: Option<Record>,
    }
    #[derive(Deserialize)]
    struct Record {
        workspace_root: Option<String>,
    }
    let row: Row = serde_json::from_str(line).ok()?;
    row.payload?
        .record?
        .workspace_root
        .filter(|s| !s.is_empty())
}

/// The folder a session ran in, from the head of its log.
///
/// The full path, not a label: the live meter matches it against the folder a
/// terminal is actually in. Muse files sessions by date and uuid rather than
/// by folder, so this is the only way to ask which one a log belongs to.
pub fn session_workspace(head: &str) -> Option<String> {
    head.lines()
        .filter(|line| line.contains("workspace_root"))
        .find_map(workspace_root)
}

fn last_component(path: &str) -> Option<String> {
    path.rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session_dir(name: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir()
            .join(format!("tokenstat-muse-{}-{n}", std::process::id()))
            .join("sessions/2026/09/01")
            .join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The two header shapes and two turns, in the field order the real log
    /// uses.
    const METADATA: &str = r#"{"schema_version":1,"stream":{"kind":"session","id":"s1"},"id":"r0","recorded_at":1788257844312475,"record_type":"event","payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"/Users/x/git/demo","provider_id":"meta","build":{"semver":"1.0.1"}}}}"#;
    const FIRST_CALL: &str = r#"{"schema_version":1,"stream":{"kind":"session","id":"s1"},"id":"r1","recorded_at":1788257973508549,"record_type":"event","payload_type":"runtime.session","payload":{"event":{"kind":"model_completed","usage":{"input_tokens":35336,"output_tokens":236,"cached_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"reasoning_tokens":60},"duration_ms":7202,"finish_reason":"tool_calls","model":"muse-spark-1.2"}}}"#;
    const CACHED_CALL: &str = r#"{"schema_version":1,"stream":{"kind":"session","id":"s1"},"id":"r2","recorded_at":1788257977748102,"record_type":"event","payload_type":"runtime.session","payload":{"event":{"kind":"model_completed","usage":{"input_tokens":37538,"output_tokens":97,"cached_tokens":35313,"cache_write_tokens":0,"cache_read_tokens":35313,"reasoning_tokens":0},"duration_ms":3937,"finish_reason":"tool_calls","model":"muse-spark-1.2"}}}"#;

    fn write(dir: &Path, lines: &[&str]) -> PathBuf {
        let path = dir.join("session.jsonl");
        std::fs::write(&path, format!("{}\n", lines.join("\n"))).unwrap();
        path
    }

    #[test]
    fn reads_a_completed_call() {
        let dir = session_dir("01a05c79");
        let path = write(&dir, &[METADATA, FIRST_CALL]);
        let text = std::fs::read_to_string(&path).unwrap();
        let out = parse_file(&path, &text);
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.source, SourceId::Muse);
        assert_eq!(e.model, "muse-spark-1.2");
        assert_eq!(e.project, "demo");
        assert_eq!(e.session, "01a05c79");
        assert_eq!(e.counters.input_fresh, Some(35336));
        assert_eq!(e.counters.output, Some(236));
        // Reasoning is inside output, so it does not add to the total.
        assert_eq!(e.extras.reasoning_within_output, Some(60));
        assert_eq!(e.counters.total(), 35336 + 236);
    }

    #[test]
    fn cache_read_comes_out_of_input() {
        let dir = session_dir("01a05c80");
        let path = write(&dir, &[METADATA, CACHED_CALL]);
        let text = std::fs::read_to_string(&path).unwrap();
        let out = parse_file(&path, &text);
        let e = &out.events[0];
        assert_eq!(e.counters.cache_read, Some(35313));
        assert_eq!(e.counters.input_fresh, Some(37538 - 35313));
        // Which is what keeps the disjoint buckets summing to the prompt Muse
        // reported, plus the output.
        assert_eq!(e.counters.input_total(), 37538);
        assert_eq!(e.counters.total(), 37538 + 97);
    }

    /// Microseconds, not milliseconds. A thousandfold error here puts every
    /// session in 1970 and every report at zero.
    #[test]
    fn recorded_at_is_microseconds() {
        let dir = session_dir("01a05c81");
        let path = write(&dir, &[METADATA, FIRST_CALL]);
        let text = std::fs::read_to_string(&path).unwrap();
        let out = parse_file(&path, &text);
        assert_eq!(out.events[0].ts.utc_ms, 1_788_257_973_508);
    }

    /// The attribution ledger and the subagent observation both restate spend
    /// that `model_completed` already carries.
    #[test]
    fn ignores_the_records_that_would_double_count() {
        let attribution = r#"{"id":"r3","recorded_at":1788257973600000,"payload_type":"runtime.session","payload":{"event":{"kind":"goal_usage_attribution","record":{"usage_id":"usage-1","usage_family":"provider","quantity":{"input_tokens":35336,"output_tokens":236,"cached_tokens":0,"reasoning_tokens":60}}}}}"#;
        let observed = r#"{"id":"r4","recorded_at":1788257973700000,"payload_type":"subagent.control.runtime_observed","payload":{"record":{"usage":{"input_tokens":752392,"output_tokens":6516,"cached_tokens":683935,"cache_write_tokens":0,"cache_read_tokens":683935,"reasoning_tokens":2142}}}}"#;
        let dir = session_dir("01a05c82");
        let path = write(&dir, &[METADATA, FIRST_CALL, attribution, observed]);
        let text = std::fs::read_to_string(&path).unwrap();
        let out = parse_file(&path, &text);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].counters.output, Some(236));
    }

    /// A resumed scan hands over only what was appended, so the header is not
    /// in the text. The project still has to come out right.
    #[test]
    fn a_tail_read_still_names_the_project() {
        let dir = session_dir("01a05c83");
        let path = write(&dir, &[METADATA, FIRST_CALL, CACHED_CALL]);
        let tail = format!("{CACHED_CALL}\n");
        let out = parse_file(&path, &tail);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].project, "demo");
    }

    /// A subagent has no workspace in its metadata, only in its branch record.
    #[test]
    fn a_subagent_takes_the_workspace_from_its_branch_record() {
        let branch = r#"{"id":"b0","recorded_at":1788257844410562,"payload_type":"session.workspace_branch.observed","payload":{"kind":"workspace_branch","record":{"workspace_root":"/Users/x/git/demo","reference":{"kind":"branch","name":"main"},"vcs":"git"}}}"#;
        let sub_metadata = r#"{"id":"m0","recorded_at":1788257844312475,"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"provider_id":"meta","model_id":"muse-spark-1.2"}}}"#;
        let parent = session_dir("01a05c84");
        let dir = parent.join("subagent").join("0e4e845f");
        std::fs::create_dir_all(&dir).unwrap();
        let path = write(&dir, &[sub_metadata, branch, FIRST_CALL]);
        let text = std::fs::read_to_string(&path).unwrap();
        let out = parse_file(&path, &text);
        assert_eq!(out.events[0].project, "demo");
        assert_eq!(out.events[0].session, "0e4e845f");
    }

    /// A cancelled call writes zeroes, and a zero row is not a fact about
    /// spend.
    #[test]
    fn skips_a_call_that_spent_nothing() {
        let empty = r#"{"id":"r5","recorded_at":1788257973800000,"payload_type":"runtime.session","payload":{"event":{"kind":"model_completed","usage":{"input_tokens":0,"output_tokens":0,"cached_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"reasoning_tokens":0},"model":"muse-spark-1.2"}}}"#;
        let dir = session_dir("01a05c85");
        let path = write(&dir, &[METADATA, empty]);
        let text = std::fs::read_to_string(&path).unwrap();
        let out = parse_file(&path, &text);
        assert!(out.events.is_empty());
        assert_eq!(out.rows_seen, 0);
    }

    /// What the live meter asks: which folder is this log's session in.
    #[test]
    fn the_head_says_which_folder_the_session_is_in() {
        let head = format!("{METADATA}\n{FIRST_CALL}\n");
        assert_eq!(
            session_workspace(&head).as_deref(),
            Some("/Users/x/git/demo")
        );
        assert_eq!(session_workspace(FIRST_CALL), None);
    }

    #[test]
    fn shards_find_parents_and_subagents() {
        let parent = session_dir("01a05c86");
        write(&parent, &[METADATA, FIRST_CALL]);
        let sub = parent.join("subagent").join("0e4e865f");
        std::fs::create_dir_all(&sub).unwrap();
        write(&sub, &[FIRST_CALL]);
        // The sessions root is three levels above the session directory.
        let root = parent.parent().unwrap().parent().unwrap().parent().unwrap();
        let found = shards(root);
        assert_eq!(found.len(), 2);
    }
}
