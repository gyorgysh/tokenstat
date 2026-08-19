// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Hermes Agent reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.hermes/state.db
//! ```
//!
//! Hermes has already done the rollup. `session_model_usage` is one row per
//! session, model, billing provider and task, holding input, output, cache read
//! and write, and reasoning, with `first_seen` and `last_seen` as epoch
//! seconds. `sessions` carries the `cwd` that names the project.
//!
//! **The rows grow.** They are running totals for a session that may still be
//! going, not per-call records, so a re-read of the same session sees larger
//! numbers. The event id is therefore derived from the row's own key and
//! carries no timestamp, and the archive's upsert keeps the maximum per
//! counter. That is the same treatment the OpenClaw session rollup gets, and it
//! is why re-scanning a live session updates a row rather than adding one.
//!
//! **`sessions` is not the sum of its usage rows.** On a real session the
//! session row held 29,557 input tokens while its usage rows held 29,557 plus
//! another 721 for a `title_generation` task. The auxiliary task is real spend
//! on a real model, so this reads `session_model_usage` and ignores the
//! session's own counters, which would quietly lose it.
//!
//! Day attribution uses `first_seen`: it is the moment the row started
//! accruing, it never moves, and the archive pins an event's day on first
//! write anyway. A session running across midnight lands wholly on the day it
//! started, which is a choice rather than a truth, and the honest one to make
//! given the vendor keeps no per-call breakdown.

use std::path::{Path, PathBuf};

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the Hermes state database.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let path = home.join(".hermes").join("state.db");
    path.is_file().then_some(path)
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Read every usage row.
pub fn parse_db(path: &Path) -> ParseOutput {
    parse_db_in(path, None, None)
}

/// Read the database, optionally narrowed to one folder and one span of time.
///
/// The narrowing is SQL rather than a filter on the results, for the same
/// reason it is in the OpenCode reader: this file holds every session the
/// machine has ever run, and the live meter asks on a poll.
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
    // An install too old for the rollup table is not a fault, it is an install
    // with nothing to say. Warning on every poll would make the normal case
    // noisy.
    if !has_table(&conn, "session_model_usage") {
        return out;
    }

    let mut sql = String::from(
        "SELECT u.session_id, u.model, u.task, u.billing_provider,
                u.input_tokens, u.output_tokens, u.cache_read_tokens,
                u.cache_write_tokens, u.reasoning_tokens,
                u.estimated_cost_usd, u.actual_cost_usd, u.cost_status,
                COALESCE(u.first_seen, u.last_seen, s.started_at, 0),
                COALESCE(s.cwd, '')
         FROM session_model_usage u
         LEFT JOIN sessions s ON s.id = u.session_id",
    );
    let mut clauses: Vec<&str> = Vec::new();
    if directory.is_some() {
        clauses.push("COALESCE(s.cwd, '') = :dir");
    }
    if since_ms.is_some() {
        // Seconds on this side of the boundary, milliseconds on ours.
        clauses.push("COALESCE(u.last_seen, u.first_seen, 0) >= :since");
    }
    if !clauses.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&clauses.join(" AND "));
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
    let floor = since_ms.map(|ms| ms as f64 / 1000.0).unwrap_or_default();
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
            model: r.get::<_, String>(1)?,
            task: r.get::<_, String>(2).unwrap_or_default(),
            provider: r.get::<_, String>(3).unwrap_or_default(),
            input: r.get::<_, i64>(4).unwrap_or(0),
            output: r.get::<_, i64>(5).unwrap_or(0),
            cache_read: r.get::<_, i64>(6).unwrap_or(0),
            cache_write: r.get::<_, i64>(7).unwrap_or(0),
            reasoning: r.get::<_, i64>(8).unwrap_or(0),
            estimated_cost: r.get::<_, f64>(9).unwrap_or(0.0),
            actual_cost: r.get::<_, f64>(10).unwrap_or(0.0),
            cost_status: r.get::<_, String>(11).unwrap_or_default(),
            seen: r.get::<_, f64>(12).unwrap_or(0.0),
            cwd: r.get::<_, String>(13).unwrap_or_default(),
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

    for row in rows {
        let Ok(row) = row else { continue };
        if row.input <= 0 && row.output <= 0 && row.cache_read <= 0 && row.cache_write <= 0 {
            continue;
        }
        out.rows_seen += 1;
        let project = row
            .cwd
            .rsplit(['/', '\\'])
            .find(|s| !s.is_empty())
            .unwrap_or("unknown")
            .to_string();
        out.events.push(UsageEvent {
            // Every part of the row's primary key that can differ within one
            // session, and no timestamp: the row is a running total and has to
            // land on the same event each time it is read.
            id: EventId::derive(&["hermes", &row.session, &row.model, &row.task, &row.provider]),
            source: SourceId::Hermes,
            ts: Timestamp::from_ms((row.seen * 1000.0) as i64),
            model: if row.model.is_empty() {
                "unknown".to_string()
            } else {
                row.model.clone()
            },
            session: row.session.clone(),
            project,
            counters: Counters {
                input_fresh: Some(row.input.max(0) as u64),
                cache_read: Some(row.cache_read.max(0) as u64),
                cache_write_5m: Some(row.cache_write.max(0) as u64),
                cache_write_1h: None,
                output: Some(row.output.max(0) as u64),
            },
            extras: Extras {
                // Hermes counts reasoning separately from output and its own
                // session totals do not add it in, so it is reported as the
                // part of output it is rather than added on top.
                reasoning_within_output: (row.reasoning > 0).then_some(row.reasoning as u64),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            billing: row.billing(),
            confidence: Confidence::Exact,
        });
    }
    out.events.sort_by_key(|e| e.ts.utc_ms);
    out
}

struct Row {
    session: String,
    model: String,
    task: String,
    provider: String,
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    reasoning: i64,
    estimated_cost: f64,
    actual_cost: f64,
    cost_status: String,
    seen: f64,
    cwd: String,
}

impl Row {
    /// Whether this row is money or plan.
    ///
    /// A provider reached over OAuth is a signed-in subscription, which is what
    /// `xai-oauth` on a real row means, and a subscription is plan usage. An
    /// API key is metered. Where the vendor priced it, a non-zero cost settles
    /// it outright; `cost_status` of `unknown` with a zero cost is the vendor
    /// saying it could not price the call, which is not the same as free.
    fn billing(&self) -> BillingMode {
        if self.actual_cost > 0.0 || self.estimated_cost > 0.0 {
            return BillingMode::Metered;
        }
        if self.provider.contains("oauth") {
            return BillingMode::Plan;
        }
        if self.cost_status.eq_ignore_ascii_case("unknown") || self.cost_status.is_empty() {
            return BillingMode::Unknown;
        }
        BillingMode::Plan
    }
}

/// Whether this database has that table, so an older install is quiet.
fn has_table(conn: &rusqlite::Connection, name: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [name],
        |_| Ok(()),
    )
    .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The real schema, narrowed to the columns this reads, holding the two
    /// rows a real session produced.
    fn temp_db() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("tokenstat-hermes-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, started_at REAL);
             CREATE TABLE session_model_usage (
                session_id TEXT, model TEXT, billing_provider TEXT, billing_base_url TEXT,
                billing_mode TEXT, task TEXT, api_call_count INTEGER,
                input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
                cache_write_tokens INTEGER, reasoning_tokens INTEGER,
                estimated_cost_usd REAL, actual_cost_usd REAL, cost_status TEXT,
                cost_source TEXT, first_seen REAL, last_seen REAL);",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, cwd, started_at)
             VALUES ('20260819_232554_02d29e', '/Users/x/git/demo', 1787174808.0)",
            [],
        )
        .unwrap();
        let insert = "INSERT INTO session_model_usage (session_id, model, billing_provider,
             billing_base_url, billing_mode, task, api_call_count, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd,
             actual_cost_usd, cost_status, cost_source, first_seen, last_seen)
             VALUES (?1,?2,?3,'','',?4,1,?5,?6,?7,0,?8,0,0,?9,'none',1787174812.0,1787174812.0)";
        conn.execute(
            insert,
            rusqlite::params![
                "20260819_232554_02d29e",
                "grok-composer-2.5-fast",
                "xai-oauth",
                "",
                29557,
                78,
                384,
                53,
                "unknown"
            ],
        )
        .unwrap();
        // The auxiliary task the session's own counters leave out.
        conn.execute(
            insert,
            rusqlite::params![
                "20260819_232554_02d29e",
                "grok-composer-2.5-fast",
                "xai-oauth",
                "title_generation",
                721,
                128,
                0,
                0,
                ""
            ],
        )
        .unwrap();
        path
    }

    #[test]
    fn reads_every_task_not_just_the_main_one() {
        let out = parse_db(&temp_db());
        assert_eq!(out.events.len(), 2, "title generation is spend too");
        let total: u64 = out
            .events
            .iter()
            .filter_map(|e| e.counters.input_fresh)
            .sum();
        assert_eq!(total, 29557 + 721);
    }

    #[test]
    fn a_task_is_its_own_event() {
        let out = parse_db(&temp_db());
        let ids: std::collections::HashSet<_> = out.events.iter().map(|e| &e.id).collect();
        assert_eq!(ids.len(), 2, "one session, two rows, two ids");
    }

    #[test]
    fn the_project_comes_from_the_session_cwd() {
        let out = parse_db(&temp_db());
        assert!(out.events.iter().all(|e| e.project == "demo"));
    }

    #[test]
    fn a_running_total_keeps_its_identity_when_it_grows() {
        let path = temp_db();
        let before = parse_db(&path);
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute(
            "UPDATE session_model_usage SET input_tokens = input_tokens + 1000,
             last_seen = last_seen + 60 WHERE task = ''",
            [],
        )
        .unwrap();
        let after = parse_db(&path);
        let grown = after
            .events
            .iter()
            .find(|e| e.session.starts_with("2026"))
            .unwrap();
        let same = before.events.iter().find(|e| e.id == grown.id).unwrap();
        assert_eq!(same.id, grown.id, "the archive must update, not add");
        assert!(grown.counters.input_fresh > same.counters.input_fresh);
    }

    #[test]
    fn an_oauth_provider_is_plan_usage() {
        let out = parse_db(&temp_db());
        assert!(out.events.iter().all(|e| e.billing == BillingMode::Plan));
    }

    #[test]
    fn a_database_without_the_rollup_says_nothing() {
        let dir = std::env::temp_dir().join(format!("tokenstat-hermes-old-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.db");
        rusqlite::Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE sessions (id TEXT PRIMARY KEY)")
            .unwrap();
        let out = parse_db(&path);
        assert!(out.events.is_empty());
        assert!(out.warnings.is_empty(), "an old install is not a fault");
    }
}
