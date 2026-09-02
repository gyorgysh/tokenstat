// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Qwen Code usage reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.qwen/usage/token-usage-<YYYY-MM>.jsonl
//! ~/.qwen/projects/<sanitized-cwd>/chats/<sessionId>.jsonl
//! ```
//!
//! `QWEN_HOME` moves the configuration directory and `QWEN_RUNTIME_DIR` moves
//! the runtime output on top of that, so the runtime directory is where both
//! the usage ledger and the transcripts live.
//!
//! # The ledger, not the transcript
//!
//! Qwen Code keeps its own append-only usage ledger, one file per calendar
//! month, one line per API response. That is what is read here, and the
//! transcripts are never opened. Two things follow from that, and both are
//! the reason for the choice:
//!
//! - **Nothing in the ledger is conversation.** Every field is a counter, an
//!   identifier, a timestamp, a model id or a fixed enum. This is the
//!   strongest form of dropping text at the parser boundary: the file that
//!   holds the text is not read at all.
//! - **It is complete.** A subagent or a background call, such as the memory
//!   extractor, writes a ledger line but never becomes an assistant message in
//!   a transcript. Measured on a real session, the transcript held 22 of the
//!   23 requests the ledger did.
//!
//! What the ledger does not carry is the folder. That is recovered from the
//! transcript directory *names* by [`session_index`], which lists file names
//! and opens nothing.
//!
//! # What the counters mean
//!
//! ```json
//! {"sessionId":"…","model":"…","source":"main","inputTokens":26627,
//!  "cachedTokens":26496,"outputTokens":328,"thoughtsTokens":253,
//!  "totalTokens":26955}
//! ```
//!
//! `cachedTokens` is **inside** `inputTokens`, so fresh input is the
//! difference. Across a real session the cached figure trails the input one by
//! a few hundred tokens on every line and never exceeds it, which is what says
//! it is a subset rather than a bucket beside it.
//!
//! Whether reasoning is inside the generated tokens is **read out of each
//! line** rather than assumed, because the two conventions both exist in the
//! wild and this CLI passes a provider's own numbers through. `totalTokens` is
//! the provider's `total_token_count`, so it is the arbiter: if it equals
//! input plus output then the thoughts are already inside output, and if it
//! equals input plus output plus thoughts then they are beside it and have to
//! be added. On the session this reader was built against every line took the
//! first branch exactly (26627 + 328 = 26955, with 253 thoughts inside the
//! 328). A line whose total matches neither is left alone: output stands as
//! reported and the thoughts are recorded as being within it, which is the
//! reading that cannot inflate a total.
//!
//! # Identity
//!
//! Each line carries a `id` uuid minted when it was appended and never
//! rewritten, so a re-read collapses onto the same event and the confidence is
//! exact.
//!
//! # When the ledger is not written
//!
//! Qwen Code gates the ledger on its own usage-statistics setting, which is on
//! unless someone turned it off. With it off there is no local record of spend
//! and this reader reports nothing, which is the honest answer rather than a
//! partial one recovered from transcripts that would then double count the day
//! the setting is turned back on.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the directory Qwen Code writes its runtime output to.
///
/// `QWEN_RUNTIME_DIR` wins, then `QWEN_HOME`, then `~/.qwen`, matching the
/// CLI's own resolution order.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let root = match std::env::var_os("QWEN_RUNTIME_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => match std::env::var_os("QWEN_HOME").filter(|v| !v.is_empty()) {
            Some(dir) => PathBuf::from(dir),
            None => home.join(".qwen"),
        },
    };
    root.is_dir().then_some(root)
}

/// Every monthly usage ledger under the runtime directory.
///
/// Append-only, so the caller reads each from its last offset rather than
/// re-reading a year of them on every scan.
pub fn ledgers(root: &Path) -> Vec<PathBuf> {
    let dir = root.join("usage");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("token-usage-") && n.ends_with(".jsonl"))
        })
        .collect();
    files.sort();
    files
}

/// Session id → project label, built from transcript file *names*.
///
/// The ledger says which session spent the tokens and the transcript tree says
/// which folder that session ran in, so the join is the session id. Only the
/// directory listing is used: no transcript is opened, which is what keeps a
/// conversation out of this process even though its file name is read.
///
/// Archived chats sit in a subdirectory of `chats`, and a `.ledger.jsonl`
/// sidecar sits beside a transcript, so the walk is recursive and that suffix
/// is dropped.
pub fn session_index(root: &Path) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let projects = root.join("projects");
    let Ok(dirs) = std::fs::read_dir(&projects) else {
        return out;
    };
    for entry in dirs.filter_map(Result::ok) {
        let chats = entry.path().join("chats");
        if !chats.is_dir() {
            continue;
        }
        let label = project_label(entry.file_name().to_string_lossy().as_ref());
        for session in session_ids_in(&chats) {
            out.insert(session, label.clone());
        }
    }
    out
}

/// The sessions a given folder has run, for the live meter.
///
/// The directory name is a pure function of the folder, so this is an exact
/// answer rather than a label match: two checkouts with the same leaf name do
/// not share a directory here.
pub fn sessions_for_cwd(root: &Path, cwd: &str) -> Vec<String> {
    let chats = root.join("projects").join(sanitize_cwd(cwd)).join("chats");
    session_ids_in(&chats)
}

fn session_ids_in(chats: &Path) -> Vec<String> {
    walkdir::WalkDir::new(chats)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| {
            let name = e.file_name().to_str()?;
            let stem = name.strip_suffix(".jsonl")?;
            // `<id>.ledger.jsonl` is a sidecar of `<id>.jsonl`, so it names a
            // session that is already in the list rather than a new one.
            let stem = stem.strip_suffix(".ledger").unwrap_or(stem);
            (!stem.is_empty()).then(|| stem.to_string())
        })
        .collect()
}

/// The directory name Qwen Code gives a folder: every character that is not a
/// letter or a digit becomes a dash.
///
/// Lossy in the same way Claude Code's slug is, since a real dash and a
/// separator end up identical. Only the trailing component is used, as a
/// display label, so the ambiguity does not affect any number.
fn sanitize_cwd(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

fn project_label(slug: &str) -> String {
    slug.rsplit('-')
        .find(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_string()
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Wire shape of one ledger line.
///
/// `source` is the subagent that made the call, or `main` for the session
/// itself. It is read so a background call can be recognised, not to split the
/// event off: the spend belongs to the session either way.
#[derive(Deserialize)]
struct Row {
    id: Option<String>,
    timestamp: Option<String>,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    model: Option<String>,
    #[serde(rename = "authType")]
    auth_type: Option<String>,
    #[serde(rename = "inputTokens")]
    input_tokens: Option<u64>,
    #[serde(rename = "outputTokens")]
    output_tokens: Option<u64>,
    #[serde(rename = "cachedTokens")]
    cached_tokens: Option<u64>,
    #[serde(rename = "thoughtsTokens")]
    thoughts_tokens: Option<u64>,
    #[serde(rename = "totalTokens")]
    total_tokens: Option<u64>,
}

/// Read one monthly ledger.
///
/// `contents` rather than a path read, so the caller can hand over only the
/// bytes appended since the last scan. Every line stands alone, so a tail read
/// loses nothing.
pub fn parse_file(path: &Path, contents: &str, sessions: &HashMap<String, String>) -> ParseOutput {
    let mut out = ParseOutput::default();

    for (i, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
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

        let input = row.input_tokens.unwrap_or(0);
        let output = row.output_tokens.unwrap_or(0);
        let cached = row.cached_tokens.unwrap_or(0).min(input);
        let thoughts = row.thoughts_tokens.unwrap_or(0);
        if input == 0 && output == 0 && thoughts == 0 {
            // A failed or interrupted call writes zeroes. A zero row is not a
            // fact about spend, and keeping it would put empty turns in the
            // session count.
            continue;
        }
        out.rows_seen += 1;

        // See the module comment: the provider's own total says which
        // convention this line follows, and neither branch is assumed.
        let separate = row.total_tokens == Some(input + output + thoughts) && thoughts > 0;
        let generated = if separate { output + thoughts } else { output };

        let session = row.session_id.unwrap_or_default();
        let ts = row
            .timestamp
            .as_deref()
            .and_then(parse_iso8601_ms)
            .map(Timestamp::from_ms)
            .unwrap_or(Timestamp::from_ms(0));

        // The uuid the ledger minted when the line was appended. It is never
        // rewritten, so a re-read lands on the same event. Without one the
        // file offset would be the only identity, and a ledger rotated or
        // rewritten from the start would count the month again.
        let (id, confidence) = match row.id.as_deref() {
            Some(id) if !id.is_empty() => (EventId::derive(&["qwen", id]), Confidence::Exact),
            _ => (
                EventId::derive(&["qwen", &session, &i.to_string()]),
                Confidence::Derived,
            ),
        };

        out.events.push(UsageEvent {
            id,
            source: SourceId::Qwen,
            ts,
            model: row
                .model
                .filter(|m| !m.is_empty())
                .unwrap_or_else(|| "unknown".to_string()),
            project: sessions
                .get(&session)
                .cloned()
                .unwrap_or_else(|| "unknown".to_string()),
            session,
            counters: Counters {
                input_fresh: Some(input - cached),
                cache_read: Some(cached),
                // Qwen Code reports no cache write, so it must not claim a
                // zero: an unreported field is what lets a report say a total
                // is a lower bound.
                cache_write_5m: None,
                cache_write_1h: None,
                output: Some(generated),
            },
            extras: Extras {
                reasoning_within_output: (thoughts > 0).then_some(thoughts),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            billing: billing_for(row.auth_type.as_deref()),
            confidence,
        });
    }
    out
}

/// How the call was paid for, from the login it was made under.
///
/// The CLI writes one of five: `qwen-oauth` is the quota that comes with a
/// Qwen account, which is a plan rather than an invoice, and `openai`,
/// `gemini`, `anthropic` and `vertex-ai` are all a key the person pasted,
/// which bills. A name this list does not know is left unknown rather than
/// guessed in either direction, since a wrong `Plan` would silently drop real
/// money out of a total and a wrong `Metered` would invent a bill.
fn billing_for(auth_type: Option<&str>) -> BillingMode {
    match auth_type {
        Some("qwen-oauth") => BillingMode::Plan,
        Some("openai" | "gemini" | "anthropic" | "vertex-ai") => BillingMode::Metered,
        _ => BillingMode::Unknown,
    }
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

    const LEDGER: &str = "/home/u/.qwen/usage/token-usage-2026-09.jsonl";

    fn index() -> HashMap<String, String> {
        HashMap::from([("s1".to_string(), "demo".to_string())])
    }

    fn line(extra: &str) -> String {
        format!(
            r#"{{"schemaVersion":1,"id":"e1","timestamp":"2026-09-02T05:13:13.827Z","localDate":"2026-09-02","localMonth":"2026-09","sessionId":"s1","model":"qwen3-coder-plus","authType":"openai","source":"main",{extra},"apiDurationMs":5319}}"#
        )
    }

    #[test]
    fn cache_is_inside_the_input_it_is_reported_with() {
        let text = line(
            r#""inputTokens":26627,"outputTokens":328,"cachedTokens":26496,"thoughtsTokens":253,"totalTokens":26955"#,
        );
        let out = parse_file(Path::new(LEDGER), &text, &index());
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.source, SourceId::Qwen);
        assert_eq!(e.model, "qwen3-coder-plus");
        assert_eq!(e.session, "s1");
        assert_eq!(e.project, "demo");
        // 26627 prompt tokens of which 26496 came from cache.
        assert_eq!(e.counters.input_fresh, Some(131));
        assert_eq!(e.counters.cache_read, Some(26496));
        // The provider's total is input + output, so the thoughts are already
        // inside the output and must not be added to it.
        assert_eq!(e.counters.output, Some(328));
        assert_eq!(e.extras.reasoning_within_output, Some(253));
        assert_eq!(e.counters.total(), 26955);
        assert_eq!(e.confidence, Confidence::Exact);
        assert_eq!(e.billing, BillingMode::Metered);
    }

    #[test]
    fn thoughts_beside_the_output_are_added_to_it() {
        // The other convention: the provider's total only balances once the
        // thoughts are counted as generated tokens.
        let text = line(
            r#""inputTokens":1000,"outputTokens":40,"cachedTokens":0,"thoughtsTokens":30,"totalTokens":1070"#,
        );
        let out = parse_file(Path::new(LEDGER), &text, &index());
        let e = &out.events[0];
        assert_eq!(e.counters.output, Some(70));
        assert_eq!(e.extras.reasoning_within_output, Some(30));
        assert_eq!(e.counters.total(), 1070);
    }

    #[test]
    fn a_total_that_balances_neither_way_leaves_output_alone() {
        let text = line(
            r#""inputTokens":1000,"outputTokens":40,"cachedTokens":0,"thoughtsTokens":30,"totalTokens":9999"#,
        );
        let out = parse_file(Path::new(LEDGER), &text, &index());
        let e = &out.events[0];
        assert_eq!(e.counters.output, Some(40));
        assert_eq!(e.extras.reasoning_within_output, Some(30));
    }

    #[test]
    fn no_cache_write_is_reported_rather_than_claimed_as_zero() {
        let text = line(
            r#""inputTokens":1000,"outputTokens":40,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":1040"#,
        );
        let out = parse_file(Path::new(LEDGER), &text, &index());
        let e = &out.events[0];
        assert_eq!(e.counters.cache_write_5m, None);
        assert_eq!(e.counters.cache_write_1h, None);
        assert_eq!(e.extras.reasoning_within_output, None);
    }

    #[test]
    fn a_failed_call_is_not_spend() {
        let text = line(
            r#""inputTokens":0,"outputTokens":0,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":0"#,
        );
        let out = parse_file(Path::new(LEDGER), &text, &index());
        assert!(out.events.is_empty());
        assert_eq!(out.rows_seen, 0);
    }

    #[test]
    fn a_subagent_call_belongs_to_the_session_that_made_it() {
        // The memory extractor writes a ledger line and never appears in a
        // transcript, which is the reason the ledger is what gets read.
        let text = format!(
            "{}\n{}",
            line(
                r#""inputTokens":100,"outputTokens":10,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":110"#
            ),
            r#"{"schemaVersion":1,"id":"e2","timestamp":"2026-09-02T05:12:38.891Z","sessionId":"s1","model":"qwen3-coder-plus","authType":"openai","source":"managed-auto-memory-extractor","inputTokens":9680,"outputTokens":75,"cachedTokens":0,"thoughtsTokens":42,"totalTokens":9755,"apiDurationMs":3796}"#
        );
        let out = parse_file(Path::new(LEDGER), &text, &index());
        assert_eq!(out.events.len(), 2);
        assert!(out.events.iter().all(|e| e.session == "s1"));
        assert!(out.events.iter().all(|e| e.project == "demo"));
    }

    #[test]
    fn the_same_line_read_twice_is_one_event() {
        let text = line(
            r#""inputTokens":100,"outputTokens":10,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":110"#,
        );
        let first = parse_file(Path::new(LEDGER), &text, &index());
        let again = parse_file(Path::new(LEDGER), &text, &index());
        assert_eq!(first.events[0].id, again.events[0].id);
    }

    #[test]
    fn a_session_with_no_transcript_left_is_still_counted() {
        let text = line(
            r#""inputTokens":100,"outputTokens":10,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":110"#,
        );
        let out = parse_file(Path::new(LEDGER), &text, &HashMap::new());
        assert_eq!(out.events[0].project, "unknown");
        assert_eq!(out.events[0].counters.total(), 110);
    }

    #[test]
    fn the_free_tier_is_a_plan_and_a_pasted_key_is_not() {
        assert_eq!(billing_for(Some("qwen-oauth")), BillingMode::Plan);
        assert_eq!(billing_for(Some("openai")), BillingMode::Metered);
        assert_eq!(billing_for(Some("vertex-ai")), BillingMode::Metered);
        assert_eq!(billing_for(Some("something-new")), BillingMode::Unknown);
        assert_eq!(billing_for(None), BillingMode::Unknown);
    }

    #[test]
    fn a_malformed_line_is_a_warning_rather_than_a_stop() {
        let text = format!(
            "not json\n{}",
            line(
                r#""inputTokens":100,"outputTokens":10,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":110"#
            )
        );
        let out = parse_file(Path::new(LEDGER), &text, &index());
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.warnings.len(), 1);
    }

    #[test]
    fn the_folder_slug_is_the_one_the_cli_writes() {
        assert_eq!(
            sanitize_cwd("/Users/x/git/demo-app"),
            "-Users-x-git-demo-app"
        );
        assert_eq!(project_label("-Users-x-git-demo-app"), "app");
        assert_eq!(project_label(""), "unknown");
    }
}
