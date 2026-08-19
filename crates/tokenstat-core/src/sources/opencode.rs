//! OpenCode SQLite reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.local/share/opencode/opencode.db
//! ```
//!
//! Usage lives in the message `data` column as JSON with `tokens.{input,
//! output,reasoning,cache.{read,write}}`. Identity is the message primary key.
//!
//! **Two schemas share that file.** OpenCode 1 writes `message` joined to
//! `session`, with the model in `modelID`. OpenCode 2 writes `session_message`
//! joined to `session_v2`, with the model in `model.id` and the role in a
//! `type` column rather than in the JSON. Both are read: a machine that has
//! run both has history in both, and reading only the first is why an
//! OpenCode 2 session reported zero for everything.
//!
//! Cache read/write are **disjoint** from input here (unlike Codex/Grok): the
//! vendor's own `tokens.total` equals the sum of those fields.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the OpenCode database.
pub fn discover(home: &Path) -> Option<PathBuf> {
    // XDG data home on Linux; Application Support layout is not used here.
    let candidates = [
        home.join(".local/share/opencode/opencode.db"),
        home.join("Library/Application Support/opencode/opencode.db"),
    ];
    candidates.into_iter().find(|p| p.is_file())
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

#[derive(Deserialize)]
struct MessageData {
    #[serde(rename = "modelID")]
    model_id: Option<String>,
    /// OpenCode 2 nests what version 1 kept at the top level.
    model: Option<ModelRef>,
    role: Option<String>,
    tokens: Option<Tokens>,
    cost: Option<f64>,
    time: Option<MessageTime>,
}

#[derive(Deserialize)]
struct ModelRef {
    id: Option<String>,
}

#[derive(Deserialize)]
struct Tokens {
    input: Option<u64>,
    output: Option<u64>,
    reasoning: Option<u64>,
    cache: Option<Cache>,
}

#[derive(Deserialize)]
struct Cache {
    read: Option<u64>,
    write: Option<u64>,
}

#[derive(Deserialize)]
struct MessageTime {
    created: Option<i64>,
}

/// Read every message that carries token counters.
pub fn parse_db(path: &Path) -> ParseOutput {
    parse_db_in(path, None, None)
}

/// Read the database, optionally narrowed to one folder and one span of time.
///
/// The live meter asks about one folder since one spawn; the archive asks about
/// everything. Both narrowings are SQL rather than a filter on the results,
/// because this database is not small: on a working machine it reaches
/// gigabytes and holds every folder ever opened, and the live meter runs on a
/// poll. Parsing three thousand messages to keep four is not a filter, it is
/// the work done twice.
///
/// The directory is matched whole: a label is a basename and two checkouts can
/// share one.
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

    for layout in [Layout::V1, Layout::V2] {
        read_layout(&conn, path, layout, directory, since_ms, &mut out);
    }
    out.events.sort_by_key(|e| e.ts.utc_ms);
    out
}

/// Which pair of tables a query reads.
#[derive(Clone, Copy)]
enum Layout {
    V1,
    V2,
}

impl Layout {
    fn messages(self) -> &'static str {
        match self {
            Layout::V1 => "message",
            Layout::V2 => "session_message",
        }
    }

    fn sessions(self) -> &'static str {
        match self {
            Layout::V1 => "session",
            Layout::V2 => "session_v2",
        }
    }
}

/// Read one schema's messages into `out`.
///
/// A missing table is not a warning. An install that has only ever run one
/// major version has only that version's tables, and saying so on every poll
/// would turn the normal case into a complaint.
fn read_layout(
    conn: &rusqlite::Connection,
    path: &Path,
    layout: Layout,
    directory: Option<&str>,
    since_ms: Option<i64>,
    out: &mut ParseOutput,
) {
    if !has_table(conn, layout.messages()) {
        return;
    }
    // Built rather than matched, because the two narrowings are independent
    // and the four-way match this used to be would only grow.
    let mut sql = format!(
        "SELECT m.id, m.session_id, m.time_created, m.data,
                COALESCE(s.directory, s.path, '')
         FROM {} m
         LEFT JOIN {} s ON s.id = m.session_id",
        layout.messages(),
        layout.sessions()
    );
    let mut clauses: Vec<&str> = Vec::new();
    if directory.is_some() {
        clauses.push("COALESCE(s.directory, s.path, '') = :dir");
    }
    if since_ms.is_some() {
        clauses.push("m.time_created >= :since");
    }
    // Version 2 keeps the role in a column, so the rows that carry no usage
    // are left in the database rather than parsed and thrown away.
    if matches!(layout, Layout::V2) {
        clauses.push("m.type = 'assistant'");
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
            return;
        }
    };

    let filter = directory.unwrap_or_default().to_string();
    let floor = since_ms.unwrap_or_default();
    let mut params: Vec<(&str, &dyn rusqlite::ToSql)> = Vec::new();
    if directory.is_some() {
        params.push((":dir", &filter));
    }
    if since_ms.is_some() {
        params.push((":since", &floor));
    }
    let rows = match stmt.query_map(params.as_slice(), |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
        ))
    }) {
        Ok(rows) => rows,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return;
        }
    };

    for row in rows {
        let Ok((id, session, time_created, data, directory)) = row else {
            continue;
        };
        let Ok(msg) = serde_json::from_str::<MessageData>(&data) else {
            out.warnings.push(Warning::MalformedLine {
                path: path.to_path_buf(),
                line: 0,
            });
            continue;
        };
        if msg.role.as_deref() == Some("user") {
            continue;
        }
        let Some(tokens) = msg.tokens else { continue };

        let input = tokens.input.unwrap_or(0);
        let output = tokens.output.unwrap_or(0);
        let reasoning = tokens.reasoning.unwrap_or(0);
        let cache_read = tokens.cache.as_ref().and_then(|c| c.read).unwrap_or(0);
        let cache_write = tokens.cache.as_ref().and_then(|c| c.write).unwrap_or(0);
        if input == 0 && output == 0 && reasoning == 0 && cache_read == 0 && cache_write == 0 {
            continue;
        }

        out.rows_seen += 1;
        let project = directory
            .rsplit(['/', '\\'])
            .find(|s| !s.is_empty())
            .unwrap_or("unknown")
            .to_string();
        let model = msg
            .model_id
            .or_else(|| msg.model.and_then(|m| m.id))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".to_string());
        let ts_ms = msg.time.and_then(|t| t.created).unwrap_or(time_created);

        // Reasoning is additive in OpenCode's own total, so fold it into output
        // and keep the split in extras for transparency.
        out.events.push(UsageEvent {
            id: EventId::derive(&["opencode", &id]),
            source: SourceId::OpenCode,
            ts: Timestamp::from_ms(ts_ms),
            model,
            session,
            project,
            counters: Counters {
                input_fresh: Some(input),
                cache_read: tokens.cache.as_ref().and_then(|c| c.read),
                cache_write_5m: tokens.cache.as_ref().and_then(|c| c.write),
                cache_write_1h: None,
                output: Some(output.saturating_add(reasoning)),
            },
            extras: Extras {
                reasoning_within_output: tokens.reasoning.filter(|&r| r > 0),
                web_search_requests: None,
                web_fetch_requests: None,
            },
            // A zero cost on a non-zero token row usually means plan coverage.
            billing: match msg.cost {
                Some(0.0) => BillingMode::Plan,
                Some(_) => BillingMode::Metered,
                None => BillingMode::Unknown,
            },
            confidence: Confidence::Exact,
        });
    }
}

/// Whether this database has that table, so a one-version install is quiet.
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

    fn temp_db(rows: &[(&str, &str, i64, &str, &str)]) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("tokenstat-opencode-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("opencode.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, path TEXT);
             CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);",
        )
        .unwrap();
        for (id, sid, tc, data, directory) in rows {
            conn.execute(
                "INSERT OR IGNORE INTO session (id, directory, path) VALUES (?1, ?2, '')",
                rusqlite::params![sid, directory],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO message (id, session_id, time_created, data) VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![id, sid, tc, data],
            )
            .unwrap();
        }
        path
    }

    /// A version 2 database, whose tables the version 1 query cannot see.
    fn temp_db_v2(rows: &[(&str, &str, i64, &str, &str)]) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("tokenstat-opencode2-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("opencode.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, path TEXT);
             CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);",
        )
        .unwrap();
        for (id, sid, tc, data, directory) in rows {
            conn.execute(
                "INSERT OR IGNORE INTO session_v2 (id, directory, path) VALUES (?1, ?2, '')",
                rusqlite::params![sid, directory],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO session_message (id, session_id, type, time_created, data)
                 VALUES (?1, ?2, 'assistant', ?3, ?4)",
                rusqlite::params![id, sid, tc, data],
            )
            .unwrap();
        }
        path
    }

    #[test]
    fn version_two_messages_are_read() {
        // No `role`, no `modelID`: the role is a column and the model is
        // nested. Read against the version 1 query this row counts as zero,
        // which is exactly what an OpenCode 2 session used to report.
        let data = r#"{"model":{"id":"gpt-5.6-luna","providerID":"opencode-go"},"tokens":{"input":3,"output":44,"reasoning":0,"cache":{"read":13182,"write":135}},"cost":0.00035}"#;
        let dir = "/Users/me/git/www";
        let path = temp_db_v2(&[("msg1", "ses1", 10, data, dir)]);
        let out = parse_db_in(&path, Some(dir), None);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].model, "gpt-5.6-luna");
        assert_eq!(out.events[0].counters.input_fresh, Some(3));
        assert_eq!(out.events[0].counters.cache_read, Some(13182));
        assert_eq!(out.events[0].billing, BillingMode::Metered);
        // The other folder is still excluded, and the missing version 1
        // tables are silence rather than a warning.
        assert!(
            parse_db_in(&path, Some("/Users/me/git/other"), None)
                .events
                .is_empty()
        );
        assert!(out.warnings.is_empty());
    }

    #[test]
    fn a_directory_filter_keeps_only_that_folders_messages() {
        let data = r#"{"role":"assistant","modelID":"opencode/big","tokens":{"input":10,"output":5},"cost":0}"#;
        let path = temp_db(&[
            ("msg1", "ses1", 1, data, "/Users/me/git/tokenstat"),
            ("msg2", "ses2", 2, data, "/Users/me/git/other"),
        ]);
        assert_eq!(parse_db(&path).events.len(), 2, "unfiltered reads both");
        let mine = parse_db_in(&path, Some("/Users/me/git/tokenstat"), None);
        assert_eq!(mine.events.len(), 1);
        assert_eq!(mine.events[0].project, "tokenstat");
        // Whole path, not a label: a basename cannot tell two checkouts apart.
        assert!(
            parse_db_in(&path, Some("tokenstat"), None)
                .events
                .is_empty()
        );
    }

    #[test]
    fn a_time_floor_keeps_only_messages_a_session_could_have_written() {
        let data = r#"{"role":"assistant","modelID":"opencode/big","tokens":{"input":10,"output":5},"cost":0}"#;
        let dir = "/Users/me/git/tokenstat";
        let path = temp_db(&[
            ("old", "ses1", 1_000, data, dir),
            ("new", "ses1", 9_000, data, dir),
        ]);
        // The whole point: the rows below the floor are never read, rather than
        // read and then discarded. One folder here is thousands of messages.
        let mine = parse_db_in(&path, Some(dir), Some(5_000));
        assert_eq!(mine.events.len(), 1);
        assert_eq!(mine.rows_seen, 1, "the old row is not even parsed");
        assert_eq!(parse_db_in(&path, Some(dir), None).events.len(), 2);
    }

    #[test]
    fn cache_is_disjoint_from_input() {
        let data = r#"{"role":"assistant","modelID":"opencode/big","tokens":{"input":193,"output":370,"reasoning":46,"cache":{"read":8192,"write":0}},"cost":0,"time":{"created":1781704954969}}"#;
        let path = temp_db(&[(
            "msg1",
            "ses1",
            1781704954969,
            data,
            "/Users/me/git/tokenstat",
        )]);
        let out = parse_db(&path);
        assert_eq!(out.events.len(), 1);
        let c = out.events[0].counters;
        assert_eq!(c.input_fresh, Some(193));
        assert_eq!(c.cache_read, Some(8192));
        assert_eq!(c.output, Some(370 + 46));
        assert_eq!(out.events[0].extras.reasoning_within_output, Some(46));
        assert_eq!(out.events[0].model, "opencode/big");
        assert_eq!(out.events[0].project, "tokenstat");
        assert_eq!(out.events[0].billing, BillingMode::Plan);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn user_rows_are_skipped() {
        let data = r#"{"role":"user","tokens":{"input":10,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}"#;
        let path = temp_db(&[("msg1", "ses1", 1, data, "/tmp/x")]);
        assert!(parse_db(&path).events.is_empty());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn identities_use_the_message_primary_key() {
        let data = r#"{"role":"assistant","modelID":"m","tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#;
        let path = temp_db(&[("msg_abc", "ses1", 1, data, "/tmp/x")]);
        let a = parse_db(&path);
        let b = parse_db(&path);
        assert_eq!(a.events[0].id, b.events[0].id);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
