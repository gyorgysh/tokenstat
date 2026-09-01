// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Devin CLI reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.local/share/devin/cli/sessions.db
//! ~/.local/share/devin/cli/transcripts/<session>.json
//! ```
//!
//! The database is what is read. `sessions` names the folder and the model,
//! and `message_nodes` holds the conversation as a forest, one row per node,
//! with the counters on an assistant node's `chat_message.metadata`:
//!
//! ```json
//! {"metadata":{"request_id":"1265c42a-…","generation_model":"swe-1-6-slow",
//!   "started_generation_at":"2026-09-01T10:55:11.971849Z",
//!   "metrics":{"input_tokens":16810,"output_tokens":252,
//!              "cache_read_tokens":1344,"cache_creation_tokens":null,
//!              "ttft_ms":2130,"total_time_ms":3993}}}
//! ```
//!
//! **Only the counters are read out of the database.** The query pulls them
//! with `json_extract`, so the message itself never crosses into this process,
//! which is a stronger version of dropping conversation text at the parser
//! boundary: it is never picked up.
//!
//! ## Every request is stored twice
//!
//! `message_nodes` is a forest, and a completed turn is written to two nodes
//! with the same `request_id` and identical metrics. Identity is derived from
//! `request_id` alone, so the pair collapses to one event.
//!
//! ## Cache reads are beside the input, not inside it
//!
//! Established against the vendor's own arithmetic rather than assumed. The
//! transcript for a session carries a rollup it computed itself:
//!
//! ```json
//! {"total_prompt_tokens":751728,"total_completion_tokens":6434,
//!  "total_cached_tokens":676768,"total_steps":25}
//! ```
//!
//! Summing the fifteen distinct requests in the database gives input 74,960,
//! cache read 676,768 and output 6,434. Output and cached match exactly, and
//! 74,960 + 676,768 is 751,728, the prompt total. So `input_tokens` is the
//! fresh part, `cache_read_tokens` is the rest of the prompt, and the two are
//! disjoint. That the halved sums land on the vendor's own totals is also what
//! confirms the duplicate nodes above.
//!
//! ## Billing
//!
//! Nothing in the database says what a turn cost or which plan paid for it,
//! so this reports [`BillingMode::Unknown`] rather than guessing from the
//! product.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the session database.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let candidates = [
        home.join(".local/share/devin/cli/sessions.db"),
        home.join("Library/Application Support/devin/cli/sessions.db"),
    ];
    candidates.into_iter().find(|p| p.is_file())
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

struct Row {
    session: String,
    directory: String,
    session_model: String,
    request_id: Option<String>,
    model: Option<String>,
    started_at: Option<String>,
    created_at_text: Option<String>,
    created_at_secs: i64,
    input: Option<i64>,
    output: Option<i64>,
    cache_read: Option<i64>,
    cache_creation: Option<i64>,
}

/// Read every turn that carries counters.
pub fn parse_db(path: &Path) -> ParseOutput {
    parse_db_in(path, None, None)
}

/// Read the database, optionally narrowed to one folder and one span of time.
///
/// The narrowing is SQL rather than a filter on the results, for the same
/// reason it is in the OpenCode and Hermes readers: this file holds every
/// session the machine has run, and the live meter asks on a poll.
pub fn parse_db_in(path: &Path, directory: Option<&str>, since_ms: Option<i64>) -> ParseOutput {
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
    // A CLI too old for the message forest is not a fault, it is an install
    // with nothing to say yet. Warning on every poll would make that noisy.
    if !has_table(&conn, "message_nodes") || !has_table(&conn, "sessions") {
        return out;
    }

    // Counters and identifiers only. `m.chat_message` is the conversation and
    // is never selected: SQLite reads it, this process does not.
    let mut sql = String::from(
        "SELECT s.id, COALESCE(s.working_directory, ''), COALESCE(s.model, ''),
                json_extract(m.chat_message, '$.metadata.request_id'),
                json_extract(m.chat_message, '$.metadata.generation_model'),
                json_extract(m.chat_message, '$.metadata.started_generation_at'),
                json_extract(m.chat_message, '$.metadata.created_at'),
                COALESCE(m.created_at, 0),
                json_extract(m.chat_message, '$.metadata.metrics.input_tokens'),
                json_extract(m.chat_message, '$.metadata.metrics.output_tokens'),
                json_extract(m.chat_message, '$.metadata.metrics.cache_read_tokens'),
                json_extract(m.chat_message, '$.metadata.metrics.cache_creation_tokens')
         FROM message_nodes m
         JOIN sessions s ON s.id = m.session_id
         WHERE json_extract(m.chat_message, '$.metadata.metrics.output_tokens') IS NOT NULL",
    );
    if directory.is_some() {
        sql.push_str(" AND COALESCE(s.working_directory, '') = :dir");
    }
    if since_ms.is_some() {
        // Seconds on this side of the boundary, milliseconds on ours.
        sql.push_str(" AND COALESCE(m.created_at, 0) >= :since");
    }
    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    let filter = directory.unwrap_or_default().to_string();
    let floor = since_ms.map(|ms| ms / 1000).unwrap_or_default();
    let mut params: Vec<(&str, &dyn rusqlite::ToSql)> = Vec::new();
    if directory.is_some() {
        params.push((":dir", &filter));
    }
    if since_ms.is_some() {
        params.push((":since", &floor));
    }
    let rows = match stmt.query_map(params.as_slice(), |r| {
        Ok(Row {
            session: r.get::<_, String>(0)?,
            directory: r.get::<_, String>(1)?,
            session_model: r.get::<_, String>(2)?,
            request_id: r.get::<_, Option<String>>(3)?,
            model: r.get::<_, Option<String>>(4)?,
            started_at: r.get::<_, Option<String>>(5)?,
            created_at_text: r.get::<_, Option<String>>(6)?,
            created_at_secs: r.get::<_, i64>(7)?,
            input: r.get::<_, Option<i64>>(8)?,
            output: r.get::<_, Option<i64>>(9)?,
            cache_read: r.get::<_, Option<i64>>(10)?,
            cache_creation: r.get::<_, Option<i64>>(11)?,
        })
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

    // Every request is stored twice, on two nodes with the same request_id.
    // Collapse them here so the archive and the meter do not pay for both.
    // Keep the strongest counters when a duplicate diverges, mirroring the
    // archive's max-on-conflict and the meter's collapse.
    let mut by_id: HashMap<EventId, usize> = HashMap::with_capacity(64);

    for row in rows.flatten() {
        let input = row.input.unwrap_or(0).max(0) as u64;
        let output = row.output.unwrap_or(0).max(0) as u64;
        let cache_read = row.cache_read.unwrap_or(0).max(0) as u64;
        let cache_creation = row.cache_creation.unwrap_or(0).max(0) as u64;
        // A turn that was interrupted before the model answered writes zeroes.
        if input == 0 && output == 0 && cache_read == 0 {
            continue;
        }
        out.rows_seen += 1;

        let ts = row
            .started_at
            .as_deref()
            .or(row.created_at_text.as_deref())
            .and_then(parse_iso8601_ms)
            .unwrap_or(row.created_at_secs.saturating_mul(1000));

        // The request id, and nothing else, so the two nodes a turn is written
        // to collapse into one event.
        let id = match row.request_id.as_deref() {
            Some(rid) if !rid.is_empty() => EventId::derive(&["devin", rid]),
            _ => EventId::derive(&["devin", &row.session, &ts.to_string(), &output.to_string()]),
        };

        if let Some(&idx) = by_id.get(&id) {
            // Duplicate node: keep the larger counters rather than a
            // second copy.
            let kept = &mut out.events[idx].counters;
            kept.input_fresh = kept.input_fresh.max(Some(input));
            kept.cache_read = kept.cache_read.max(Some(cache_read));
            kept.cache_write_5m = kept.cache_write_5m.max(Some(cache_creation));
            kept.output = kept.output.max(Some(output));
            // Timestamp and model are stable across the pair; keep first.
            continue;
        }

        let pos = out.events.len();
        by_id.insert(id, pos);
        out.events.push(UsageEvent {
            id,
            source: SourceId::Devin,
            ts: Timestamp::from_ms(ts),
            model: row.model.filter(|m| !m.is_empty()).unwrap_or_else(|| {
                match row.session_model.as_str() {
                    "" => "unknown".to_string(),
                    m => m.to_string(),
                }
            }),
            session: row.session.clone(),
            project: last_component(&row.directory).unwrap_or_else(|| "unknown".to_string()),
            counters: Counters {
                // Disjoint from the cache read: see the module comment for the
                // vendor's own arithmetic that says so.
                input_fresh: Some(input),
                cache_read: Some(cache_read),
                cache_write_5m: Some(cache_creation),
                // One cache tier, so the hour bucket is genuinely zero rather
                // than unreported.
                cache_write_1h: Some(0),
                output: Some(output),
            },
            extras: Extras {
                // No reasoning split is reported.
                reasoning_within_output: None,
                web_search_requests: None,
                web_fetch_requests: None,
            },
            billing: BillingMode::Unknown,
            confidence: Confidence::Exact,
        });
    }
    out
}

fn has_table(conn: &rusqlite::Connection, name: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [name],
        |_| Ok(()),
    )
    .is_ok()
}

/// Parse an ISO-8601 timestamp into epoch milliseconds.
fn parse_iso8601_ms(s: &str) -> Option<i64> {
    s.parse::<jiff::Timestamp>()
        .ok()
        .map(|t| t.as_millisecond())
}

fn last_component(path: &str) -> Option<String> {
    path.rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A database shaped like the real one, with the first two turns of the
    /// session quoted in the module comment and the duplicate node each one is
    /// written to.
    fn temp_db() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("tokenstat-devin-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("sessions.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, working_directory TEXT NOT NULL,
                 backend_type TEXT, model TEXT, agent_mode TEXT, created_at INTEGER,
                 last_activity_at INTEGER);
             CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                 session_id TEXT NOT NULL, node_id INTEGER NOT NULL,
                 parent_node_id INTEGER, chat_message TEXT NOT NULL,
                 created_at INTEGER NOT NULL, metadata TEXT);",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, working_directory, backend_type, model, agent_mode,
                 created_at, last_activity_at)
             VALUES ('cheddar-windscreen', '/Users/x/git/demo', 'windsurf', 'swe-1-6-slow',
                 'normal', 1788260109, 1788260363)",
            [],
        )
        .unwrap();
        let turn = |rid: &str, input: u64, output: u64, read: u64, at: &str| {
            format!(
                r#"{{"message_id":"m","role":"assistant","content":"the answer, which is never selected",
                    "metadata":{{"request_id":"{rid}","generation_model":"swe-1-6-slow",
                    "started_generation_at":"{at}","created_at":"{at}","num_tokens":{output},
                    "finish_reason":"tool_calls",
                    "metrics":{{"ttft_ms":2130,"total_time_ms":3993,"input_tokens":{input},
                    "output_tokens":{output},"cache_read_tokens":{read},
                    "cache_creation_tokens":null}}}}}}"#
            )
        };
        let first = turn(
            "1265c42a-1a20-42ca-b9e7-c1e8f2c0949d",
            16810,
            252,
            1344,
            "2026-09-01T10:55:11.971849Z",
        );
        let second = turn(
            "41b5cea7-7a12-4db5-a60f-1421445423ac",
            13660,
            473,
            18144,
            "2026-09-01T10:55:15.926098Z",
        );
        // Each turn on two nodes, the way the forest stores it.
        for (node, message) in [(26, &first), (27, &first), (31, &second), (32, &second)] {
            conn.execute(
                "INSERT INTO message_nodes (session_id, node_id, parent_node_id, chat_message, created_at)
                 VALUES ('cheddar-windscreen', ?1, NULL, ?2, 1788260363)",
                rusqlite::params![node, message],
            )
            .unwrap();
        }
        // A user turn, which has no metrics and must not become an event.
        conn.execute(
            "INSERT INTO message_nodes (session_id, node_id, parent_node_id, chat_message, created_at)
             VALUES ('cheddar-windscreen', 25, NULL,
                 '{\"role\":\"user\",\"content\":\"a question\",\"metadata\":{\"metrics\":{}}}',
                 1788260360)",
            [],
        )
        .unwrap();
        path
    }

    #[test]
    fn reads_a_turn() {
        let out = parse_db(&temp_db());
        let first = out
            .events
            .iter()
            .find(|e| e.counters.output == Some(252))
            .expect("the first turn");
        assert_eq!(first.source, SourceId::Devin);
        assert_eq!(first.model, "swe-1-6-slow");
        assert_eq!(first.project, "demo");
        assert_eq!(first.session, "cheddar-windscreen");
        assert_eq!(first.counters.input_fresh, Some(16810));
        assert_eq!(first.counters.cache_read, Some(1344));
        // Beside the input, so the prompt is the sum of the two.
        assert_eq!(first.counters.input_total(), 16810 + 1344);
        assert!(!first.counters.has_unknown());
    }

    /// The forest stores each turn twice. Two rows, one event.
    #[test]
    fn the_duplicate_node_collapses() {
        let out = parse_db(&temp_db());
        // Both rows are read, because the archive is what deduplicates.
        assert_eq!(out.rows_seen, 4);
        let ids: std::collections::HashSet<_> = out.events.iter().map(|e| e.id).collect();
        assert_eq!(ids.len(), 2, "two requests, whatever the node count");
    }

    #[test]
    fn a_user_turn_is_not_an_event() {
        let out = parse_db(&temp_db());
        assert_eq!(out.rows_seen, 4);
    }

    #[test]
    fn the_timestamp_comes_from_the_generation_not_the_row() {
        let out = parse_db(&temp_db());
        let first = out
            .events
            .iter()
            .find(|e| e.counters.output == Some(252))
            .unwrap();
        // 2026-09-01T10:55:11.971849Z, not the row's 1788260363 seconds.
        assert_eq!(first.ts.utc_ms, 1_788_260_111_971);
    }

    /// The live meter asks for one folder, and asks often.
    #[test]
    fn narrows_to_a_folder() {
        let path = temp_db();
        assert_eq!(
            parse_db_in(&path, Some("/Users/x/git/demo"), None).rows_seen,
            4
        );
        assert_eq!(
            parse_db_in(&path, Some("/Users/x/git/other"), None).rows_seen,
            0
        );
    }

    /// A database from a CLI that predates the forest says nothing rather than
    /// warning on every poll.
    #[test]
    fn an_install_with_no_forest_is_quiet() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-devin-empty-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("sessions.db");
        rusqlite::Connection::open(&path).unwrap();
        let out = parse_db(&path);
        assert!(out.events.is_empty());
        assert!(out.warnings.is_empty());
    }
}
