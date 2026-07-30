//! GitHub Copilot CLI session reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.copilot/session-store.db
//! ```
//!
//! Usage lives in `assistant_usage_events` with disjoint cache fields and an
//! optional `reasoning_tokens` count. Plain-text process logs under
//! `~/.copilot/logs/` are ignored (no counters). Conversation text in `turns`
//! is never selected.

use std::path::{Path, PathBuf};

use crate::error::Warning;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

/// Locate the Copilot CLI session store.
pub fn discover(home: &Path) -> Option<PathBuf> {
    let path = home.join(".copilot").join("session-store.db");
    path.is_file().then_some(path)
}

#[derive(Debug, Default)]
pub struct ParseOutput {
    pub events: Vec<UsageEvent>,
    pub warnings: Vec<Warning>,
    pub rows_seen: u64,
}

/// Read every assistant usage row that carries token counters.
pub fn parse_db(path: &Path) -> ParseOutput {
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

    // Fail soft when an older Copilot build lacks the usage table.
    let has_table: bool = conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='assistant_usage_events'",
            [],
            |_| Ok(true),
        )
        .unwrap_or(false);
    if !has_table {
        out.warnings.push(Warning::Unreadable {
            path: path.to_path_buf(),
            reason: "assistant_usage_events table missing (upgrade Copilot CLI)".into(),
        });
        return out;
    }

    let sql = r#"
        SELECT u.id, u.session_id, u.turn_index, u.model,
               COALESCE(u.input_tokens, 0),
               COALESCE(u.output_tokens, 0),
               COALESCE(u.cache_read_tokens, 0),
               COALESCE(u.cache_write_tokens, 0),
               COALESCE(u.reasoning_tokens, 0),
               u.created_at,
               COALESCE(s.cwd, ''),
               COALESCE(s.repository, '')
        FROM assistant_usage_events u
        LEFT JOIN sessions s ON s.id = u.session_id
        ORDER BY u.id
    "#;
    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => {
            out.warnings.push(Warning::Unreadable {
                path: path.to_path_buf(),
                reason: e.to_string(),
            });
            return out;
        }
    };

    let rows = match stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<i64>>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, i64>(6)?,
            r.get::<_, i64>(7)?,
            r.get::<_, i64>(8)?,
            r.get::<_, Option<String>>(9)?,
            r.get::<_, String>(10)?,
            r.get::<_, String>(11)?,
        ))
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
        let Ok((
            id,
            session,
            turn_index,
            model,
            input,
            output,
            cache_read,
            cache_write,
            reasoning,
            created_at,
            cwd,
            repository,
        )) = row
        else {
            continue;
        };

        let input = to_u64(input);
        let output_text = to_u64(output);
        let cache_read = to_u64(cache_read);
        let cache_write = to_u64(cache_write);
        let reasoning = to_u64(reasoning);
        let output = output_text.saturating_add(reasoning);
        if input == 0 && output == 0 && cache_read == 0 && cache_write == 0 {
            continue;
        }

        out.rows_seen += 1;
        let project = project_label(&cwd, &repository, &session);
        let model = if model.trim().is_empty() {
            "unknown".to_string()
        } else {
            model
        };
        let ts_ms = parse_created_at(created_at.as_deref());
        let turn = turn_index.unwrap_or(-1).to_string();

        out.events.push(UsageEvent {
            id: EventId::derive(&["copilot", &session, &id.to_string(), &turn]),
            source: SourceId::Copilot,
            ts: Timestamp::from_ms(ts_ms),
            model,
            session,
            project,
            counters: Counters {
                input_fresh: Some(input),
                cache_read: Some(cache_read),
                cache_write_5m: Some(cache_write),
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras {
                reasoning_within_output: (reasoning > 0).then_some(reasoning),
                ..Extras::default()
            },
            billing: BillingMode::Plan,
            confidence: Confidence::Exact,
        });
    }

    out
}

fn to_u64(v: i64) -> u64 {
    u64::try_from(v.max(0)).unwrap_or(0)
}

fn project_label(cwd: &str, repository: &str, session: &str) -> String {
    let from_cwd = cwd
        .rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .map(str::to_string);
    if let Some(name) = from_cwd.filter(|s| s != "." && s != "..") {
        return name;
    }
    if !repository.trim().is_empty() {
        return repository
            .rsplit('/')
            .next()
            .unwrap_or(repository)
            .to_string();
    }
    session.chars().take(8).collect::<String>()
}

fn parse_created_at(s: Option<&str>) -> i64 {
    s.and_then(|text| {
        text.parse::<jiff::Timestamp>()
            .ok()
            .map(|ts| ts.as_millisecond())
            .or_else(|| {
                // SQLite datetime('now') shape without timezone.
                jiff::civil::DateTime::strptime("%Y-%m-%d %H:%M:%S", text)
                    .ok()
                    .and_then(|dt| dt.to_zoned(jiff::tz::TimeZone::UTC).ok())
                    .map(|z| z.timestamp().as_millisecond())
            })
    })
    .unwrap_or(0)
    .max(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn tempfile_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-copilot-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn seed_db(path: &Path) {
        let conn = Connection::open(path).unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              cwd TEXT,
              repository TEXT
            );
            CREATE TABLE assistant_usage_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              turn_index INTEGER,
              model TEXT NOT NULL,
              input_tokens INTEGER,
              output_tokens INTEGER,
              cache_read_tokens INTEGER,
              cache_write_tokens INTEGER,
              reasoning_tokens INTEGER,
              created_at TEXT
            );
            INSERT INTO sessions (id, cwd, repository)
              VALUES ('sess-1', '/Users/me/git/demo', 'me/demo');
            INSERT INTO assistant_usage_events
              (session_id, turn_index, model, input_tokens, output_tokens,
               cache_read_tokens, cache_write_tokens, reasoning_tokens, created_at)
              VALUES
              ('sess-1', 0, 'gpt-5-mini', 100, 20, 50, 10, 7, '2026-07-28T20:44:39.972Z'),
              ('sess-1', 1, 'gpt-5-mini', 0, 0, 0, 0, 0, '2026-07-28T20:45:00.000Z');
            "#,
        )
        .unwrap();
    }

    #[test]
    fn maps_disjoint_counters_and_folds_reasoning() {
        let dir = tempfile_dir();
        let path = dir.join("session-store.db");
        seed_db(&path);
        let out = parse_db(&path);
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.source, SourceId::Copilot);
        assert_eq!(e.model, "gpt-5-mini");
        assert_eq!(e.project, "demo");
        assert_eq!(e.counters.input_fresh, Some(100));
        assert_eq!(e.counters.cache_read, Some(50));
        assert_eq!(e.counters.cache_write_5m, Some(10));
        assert_eq!(e.counters.output, Some(27));
        assert_eq!(e.extras.reasoning_within_output, Some(7));
        assert_eq!(e.billing, BillingMode::Plan);
        assert_eq!(e.confidence, Confidence::Exact);
        assert!(e.ts.utc_ms > 0);
    }

    #[test]
    fn missing_usage_table_warns() {
        let dir = tempfile_dir();
        let path = dir.join("empty.db");
        Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE sessions (id TEXT);")
            .unwrap();
        let out = parse_db(&path);
        assert!(out.events.is_empty());
        assert_eq!(out.warnings.len(), 1);
    }
}
