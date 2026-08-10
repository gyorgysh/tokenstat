//! Local SQLite archive.
//!
//! This is an archive, not a cache. Claude Code deletes transcripts after
//! `cleanupPeriodDays` (30 by default), so anything not captured before then is
//! gone from the machine entirely. Keeping raw events also means a timezone
//! change can rebuild daily buckets from scratch instead of re-splitting an
//! already-bucketed aggregate, which is how usage gets double counted.
//!
//! Deduplication is `INSERT OR IGNORE` on the event id. Because ids are derived
//! from provider-assigned fields, re-reading a file that was rewritten during a
//! session resume is idempotent for free.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension, params};

use crate::error::CoreError;
use crate::model::{BillingMode, Counters, UsageEvent};
use crate::sync_payload::SyncRollupBucket;
use crate::watermark::Watermark;

const SCHEMA_VERSION: i64 = 1;

/// Length of a Claude-style usage block. A new block starts when activity
/// resumes after this gap, or when the previous block's window has elapsed.
pub const BLOCK_DURATION_MS: i64 = 5 * 60 * 60 * 1000;

pub struct Store {
    conn: Connection,
}

/// One row of a grouped report.
#[derive(Debug, Clone)]
pub struct Bucket {
    pub key: String,
    pub counters: Counters,
    pub events: u64,
    pub sessions: u64,
}

/// One row of a report grouped by a key *and* by a second dimension.
///
/// Two things need this. Pricing needs a model id, so a day or project bucket
/// cannot be valued from its own totals and has to be split by model first.
/// And any "what ran where" question is a split: which harnesses touched this
/// project, which models a session used.
#[derive(Debug, Clone)]
pub struct SplitBucket {
    /// The requested grouping key: a date, project path, source, and so on.
    pub key: String,
    /// The second dimension's value, raw as recorded.
    pub split: String,
    pub counters: Counters,
    pub events: u64,
    pub sessions: u64,
}

/// One `model × source` slice of a single day.
///
/// This is the day hover detail on the public profile: which models ran
/// through which harnesses, and how the day's tokens split between fresh
/// input, cache reads, cache writes and output. A day with events keeps one
/// row per pair, so the client can draw the same rows the website draws
/// without joining two reports.
#[derive(Debug, Clone)]
pub struct DayPart {
    pub model: String,
    pub source: String,
    pub counters: Counters,
    pub events: u64,
}

impl DayPart {
    /// Total tokens across every disjoint counter field.
    pub fn tokens(&self) -> u64 {
        self.counters.total()
    }
}

/// One 5 hour usage block, gap-based like Claude's rate-limit windows.
#[derive(Debug, Clone)]
pub struct UsageBlock {
    /// Instant the block opened (first event in the window).
    pub start_ms: i64,
    /// Instant the block closes (`start_ms + BLOCK_DURATION_MS`).
    pub end_ms: i64,
    pub counters: Counters,
    pub events: u64,
    pub sessions: u64,
    /// True when `now` still falls inside this block's window.
    pub active: bool,
}

/// Flat event row for export. Counters and identifiers only, never prompts.
#[derive(Debug, Clone)]
pub struct EventRow {
    pub id: String,
    pub source: String,
    pub ts_ms: i64,
    pub local_date: String,
    pub model: String,
    pub session: String,
    pub project: String,
    pub counters: Counters,
}

/// How to group a report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupBy {
    Day,
    /// ISO week (`YYYY-Www`), derived from `local_date`.
    Week,
    Model,
    Project,
    Source,
    Session,
}

impl GroupBy {
    fn column(self) -> &'static str {
        match self {
            GroupBy::Day => "local_date",
            // %G/%V are ISO year and week. local_date is YYYY-MM-DD text.
            GroupBy::Week => "strftime('%G-W%V', local_date)",
            GroupBy::Model => "model",
            GroupBy::Project => "project",
            GroupBy::Source => "source",
            GroupBy::Session => "session",
        }
    }
}

/// Filters applied to a report.
#[derive(Debug, Clone, Default)]
pub struct Query {
    pub since: Option<String>,
    pub until: Option<String>,
    pub model: Option<String>,
    pub project: Option<String>,
    pub billing: Option<BillingMode>,
}

/// Totals across everything the archive holds.
#[derive(Debug, Clone, Default)]
pub struct Totals {
    pub counters: Counters,
    pub events: u64,
    pub sessions: u64,
    pub days: u64,
    pub first_date: Option<String>,
    pub last_date: Option<String>,
}

impl Store {
    /// Default location, following platform conventions.
    pub fn default_path() -> Result<PathBuf, CoreError> {
        let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .ok_or(CoreError::NoDataDir)?;
        Ok(dirs.data_dir().join("tokenstat.db"))
    }

    pub fn open(path: &Path) -> Result<Self, CoreError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| CoreError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        // An existing archive must open without DDL. CREATE TABLE takes a write
        // lock, and the hourly scan holds write transactions for far longer than
        // a statusline or sync wants to wait. Fresh files still get the full
        // schema on first open.
        let fresh = !path.exists()
            || std::fs::metadata(path)
                .map(|m| m.len() == 0)
                .unwrap_or(true);
        let conn = Connection::open(path)?;
        Self::configure(&conn)?;
        if fresh || !Self::schema_ready(&conn)? {
            Self::migrate(&conn)?;
        } else {
            // Indexes added after first ship. IF NOT EXISTS is a catalog check
            // when present, so a ready archive still gains new ones without a
            // full migrate write path.
            Self::ensure_indexes(&conn)?;
        }
        Ok(Store { conn })
    }

    pub fn open_in_memory() -> Result<Self, CoreError> {
        let conn = Connection::open_in_memory()?;
        Self::configure(&conn)?;
        Self::migrate(&conn)?;
        Ok(Store { conn })
    }

    /// WAL + busy wait. Safe to call on a connection that will only read.
    fn configure(conn: &Connection) -> Result<(), CoreError> {
        // WAL keeps a statusline read from ever blocking behind a scan.
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        // Scan insert_events can hold a write lock for tens of seconds on a
        // large archive. Five seconds was too short for overlapping sync opens.
        conn.busy_timeout(std::time::Duration::from_secs(60))?;
        Ok(())
    }

    /// True when `meta.schema_version` is present (tables already created).
    fn schema_ready(conn: &Connection) -> Result<bool, CoreError> {
        let has_meta: bool = conn
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'",
                [],
                |_| Ok(true),
            )
            .optional()?
            .unwrap_or(false);
        if !has_meta {
            return Ok(false);
        }
        Ok(conn
            .query_row("SELECT v FROM meta WHERE k = 'schema_version'", [], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
            .is_some())
    }

    fn migrate(conn: &Connection) -> Result<(), CoreError> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS event (
              id             BLOB PRIMARY KEY,
              source         TEXT NOT NULL,
              ts_ms          INTEGER NOT NULL,
              local_date     TEXT NOT NULL,
              local_hour     INTEGER NOT NULL,
              model          TEXT NOT NULL,
              session        TEXT NOT NULL,
              project        TEXT NOT NULL,
              input_fresh    INTEGER,
              cache_read     INTEGER,
              cache_write_5m INTEGER,
              cache_write_1h INTEGER,
              output         INTEGER,
              billing        TEXT NOT NULL,
              confidence     TEXT NOT NULL
            ) STRICT;

            CREATE INDEX IF NOT EXISTS event_date  ON event(local_date);
            CREATE INDEX IF NOT EXISTS event_model ON event(model);
            CREATE INDEX IF NOT EXISTS event_proj  ON event(project);
            CREATE INDEX IF NOT EXISTS event_ts    ON event(ts_ms);
            CREATE INDEX IF NOT EXISTS event_source ON event(source);

            CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL) STRICT;

            -- Per file scan state, so a rescan opens only what changed.
            -- The path is local only and never leaves the machine.
            CREATE TABLE IF NOT EXISTS shard (
              path        TEXT PRIMARY KEY,
              size        INTEGER NOT NULL,
              mtime_ms    INTEGER NOT NULL,
              head_sig    TEXT NOT NULL,
              sig_len     INTEGER NOT NULL,
              byte_offset INTEGER NOT NULL
            ) STRICT;
            "#,
        )?;
        conn.execute(
            "INSERT OR IGNORE INTO meta (k, v) VALUES ('schema_version', ?1)",
            params![SCHEMA_VERSION.to_string()],
        )?;
        Ok(())
    }

    /// Ensure post-ship indexes exist on archives that already had a schema.
    fn ensure_indexes(conn: &Connection) -> Result<(), CoreError> {
        conn.execute_batch(
            r#"
            CREATE INDEX IF NOT EXISTS event_date  ON event(local_date);
            CREATE INDEX IF NOT EXISTS event_model ON event(model);
            CREATE INDEX IF NOT EXISTS event_proj  ON event(project);
            CREATE INDEX IF NOT EXISTS event_ts    ON event(ts_ms);
            CREATE INDEX IF NOT EXISTS event_source ON event(source);
            "#,
        )?;
        Ok(())
    }

    /// Insert events, collapsing repeats of the same request.
    ///
    /// Returns how many rows were written or updated. Identical re-ingests
    /// contribute zero. The gap between that and the number passed in is the
    /// duplication the logs contained (or rows whose counters did not grow).
    ///
    /// # Why this takes the maximum rather than ignoring repeats
    ///
    /// A tool may write the same assistant message several times while it
    /// streams, each copy carrying a larger `output_tokens` than the last while
    /// the prompt-side counters stay fixed. Keeping whichever copy happened to
    /// be read first would silently undercount generated tokens, sometimes by
    /// more than an order of magnitude on a single request.
    ///
    /// Taking the per-field maximum is correct because those counters only grow
    /// within one request, and it makes ingestion commutative: the result no
    /// longer depends on the order files are read in, which matters because a
    /// session resume moves rows between files. NULL stays NULL until a real
    /// value arrives, so unknown is never materialised as zero.
    pub fn insert_events(
        &mut self,
        events: &[UsageEvent],
        tz: &jiff::tz::TimeZone,
    ) -> Result<u64, CoreError> {
        let tx = self.conn.transaction()?;
        let mut touched = 0u64;
        {
            let mut stmt = tx.prepare(
                r#"INSERT INTO event
                   (id, source, ts_ms, local_date, local_hour, model, session, project,
                    input_fresh, cache_read, cache_write_5m, cache_write_1h, output,
                    billing, confidence)
                   VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
                   ON CONFLICT(id) DO UPDATE SET
                     input_fresh    = CASE
                       WHEN excluded.input_fresh IS NULL THEN input_fresh
                       WHEN input_fresh IS NULL THEN excluded.input_fresh
                       ELSE MAX(input_fresh, excluded.input_fresh) END,
                     cache_read     = CASE
                       WHEN excluded.cache_read IS NULL THEN cache_read
                       WHEN cache_read IS NULL THEN excluded.cache_read
                       ELSE MAX(cache_read, excluded.cache_read) END,
                     cache_write_5m = CASE
                       WHEN excluded.cache_write_5m IS NULL THEN cache_write_5m
                       WHEN cache_write_5m IS NULL THEN excluded.cache_write_5m
                       ELSE MAX(cache_write_5m, excluded.cache_write_5m) END,
                     cache_write_1h = CASE
                       WHEN excluded.cache_write_1h IS NULL THEN cache_write_1h
                       WHEN cache_write_1h IS NULL THEN excluded.cache_write_1h
                       ELSE MAX(cache_write_1h, excluded.cache_write_1h) END,
                     output         = CASE
                       WHEN excluded.output IS NULL THEN output
                       WHEN output IS NULL THEN excluded.output
                       ELSE MAX(output, excluded.output) END
                   WHERE COALESCE(excluded.output, -1)         > COALESCE(event.output, -1)
                      OR COALESCE(excluded.input_fresh, -1)    > COALESCE(event.input_fresh, -1)
                      OR COALESCE(excluded.cache_read, -1)     > COALESCE(event.cache_read, -1)
                      OR COALESCE(excluded.cache_write_5m, -1) > COALESCE(event.cache_write_5m, -1)
                      OR COALESCE(excluded.cache_write_1h, -1) > COALESCE(event.cache_write_1h, -1)"#,
            )?;
            for e in events {
                let n = stmt.execute(params![
                    &e.id.0[..],
                    e.source.as_str(),
                    e.ts.utc_ms,
                    e.ts.local_date(tz),
                    e.ts.local_hour(tz) as i64,
                    e.model,
                    e.session,
                    e.project,
                    e.counters.input_fresh.map(|v| v as i64),
                    e.counters.cache_read.map(|v| v as i64),
                    e.counters.cache_write_5m.map(|v| v as i64),
                    e.counters.cache_write_1h.map(|v| v as i64),
                    e.counters.output.map(|v| v as i64),
                    e.billing.as_str(),
                    e.confidence.as_str(),
                ])?;
                touched += n as u64;
            }
        }
        tx.commit()?;
        // Count both brand-new ids and counter upgrades. A streaming partial
        // that only raises output would otherwise look like "nothing new".
        Ok(touched)
    }

    fn where_clause(q: &Query) -> (String, Vec<Box<dyn rusqlite::ToSql>>) {
        let mut sql = String::new();
        let mut args: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        let mut push = |cond: &str, val: Box<dyn rusqlite::ToSql>, sql: &mut String| {
            sql.push_str(if sql.is_empty() { " WHERE " } else { " AND " });
            sql.push_str(cond);
            args.push(val);
        };
        if let Some(v) = &q.since {
            push("local_date >= ?", Box::new(v.clone()), &mut sql);
        }
        if let Some(v) = &q.until {
            push("local_date <= ?", Box::new(v.clone()), &mut sql);
        }
        if let Some(v) = &q.model {
            push("model = ?", Box::new(v.clone()), &mut sql);
        }
        if let Some(v) = &q.project {
            push("project = ?", Box::new(v.clone()), &mut sql);
        }
        if let Some(v) = q.billing {
            push("billing = ?", Box::new(v.as_str().to_string()), &mut sql);
        }
        (sql, args)
    }

    /// Grouped totals, ordered by total tokens descending, or by key ascending
    /// when grouping by day so a timeline reads left to right.
    pub fn report(&self, group: GroupBy, q: &Query) -> Result<Vec<Bucket>, CoreError> {
        let (where_sql, args) = Self::where_clause(q);
        let order = if matches!(group, GroupBy::Day | GroupBy::Week) {
            "ORDER BY k ASC"
        } else {
            "ORDER BY (COALESCE(SUM(input_fresh),0)+COALESCE(SUM(cache_read),0)\
             +COALESCE(SUM(cache_write_5m),0)+COALESCE(SUM(cache_write_1h),0)\
             +COALESCE(SUM(output),0)) DESC"
        };
        let sql = format!(
            r#"SELECT {col} AS k,
                      SUM(input_fresh), SUM(cache_read), SUM(cache_write_5m),
                      SUM(cache_write_1h), SUM(output),
                      COUNT(*), COUNT(DISTINCT session)
               FROM event{where_sql}
               GROUP BY k {order}"#,
            col = group.column(),
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::ToSql> = args.iter().map(|b| b.as_ref()).collect();
        let rows = stmt.query_map(params.as_slice(), |r| {
            Ok(Bucket {
                key: r.get::<_, Option<String>>(0)?.unwrap_or_default(),
                counters: Counters {
                    input_fresh: r.get::<_, Option<i64>>(1)?.map(|v| v as u64),
                    cache_read: r.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                    cache_write_5m: r.get::<_, Option<i64>>(3)?.map(|v| v as u64),
                    cache_write_1h: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
                    output: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
                },
                events: r.get::<_, i64>(6)? as u64,
                sessions: r.get::<_, i64>(7)? as u64,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// [`Store::report`] split one level further, by any second dimension.
    ///
    /// One query rather than a report followed by a filtered query per key,
    /// which on a year of daily buckets is the difference between 1 and 366
    /// round trips.
    ///
    /// Ordering is by key in the same direction [`Store::report`] uses, then by
    /// tokens descending inside each key, so the largest slice of a bucket
    /// comes first.
    ///
    /// Passing the same dimension twice is allowed and simply returns one slice
    /// per bucket. It is not worth rejecting, since the result is still true.
    pub fn report_split(
        &self,
        group: GroupBy,
        split: GroupBy,
        q: &Query,
    ) -> Result<Vec<SplitBucket>, CoreError> {
        let (where_sql, args) = Self::where_clause(q);
        let key_order = if matches!(group, GroupBy::Day | GroupBy::Week) {
            "k ASC"
        } else {
            "k DESC"
        };
        let sql = format!(
            r#"SELECT {col} AS k, {split_col} AS s,
                      SUM(input_fresh), SUM(cache_read), SUM(cache_write_5m),
                      SUM(cache_write_1h), SUM(output),
                      COUNT(*), COUNT(DISTINCT session)
               FROM event{where_sql}
               GROUP BY k, s
               ORDER BY {key_order},
                        (COALESCE(SUM(input_fresh),0)+COALESCE(SUM(cache_read),0)
                         +COALESCE(SUM(cache_write_5m),0)+COALESCE(SUM(cache_write_1h),0)
                         +COALESCE(SUM(output),0)) DESC"#,
            col = group.column(),
            split_col = split.column(),
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::ToSql> = args.iter().map(|b| b.as_ref()).collect();
        let rows = stmt.query_map(params.as_slice(), |r| {
            Ok(SplitBucket {
                key: r.get::<_, Option<String>>(0)?.unwrap_or_default(),
                split: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                counters: Counters {
                    input_fresh: r.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                    cache_read: r.get::<_, Option<i64>>(3)?.map(|v| v as u64),
                    cache_write_5m: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
                    cache_write_1h: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
                    output: r.get::<_, Option<i64>>(6)?.map(|v| v as u64),
                },
                events: r.get::<_, i64>(7)? as u64,
                sessions: r.get::<_, i64>(8)? as u64,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// [`Store::report_split`] against the model dimension, which is the split
    /// pricing needs.
    pub fn report_by_model(
        &self,
        group: GroupBy,
        q: &Query,
    ) -> Result<Vec<SplitBucket>, CoreError> {
        self.report_split(group, GroupBy::Model, q)
    }

    /// One day's `model × source` rows, largest slice first.
    ///
    /// The day detail the profile page shows on hover. Grouped by both
    /// dimensions because "Codex ran model X" is a different fact from "Claude
    /// Code ran model X": the counters came from different providers and the
    /// cache convention differs between them.
    pub fn day_detail(&self, date: &str) -> Result<Vec<DayPart>, CoreError> {
        let sql = r#"SELECT model, source,
                            SUM(input_fresh), SUM(cache_read), SUM(cache_write_5m),
                            SUM(cache_write_1h), SUM(output),
                            COUNT(*)
                     FROM event
                     WHERE local_date = ?1
                     GROUP BY model, source
                     ORDER BY (COALESCE(SUM(input_fresh),0)+COALESCE(SUM(cache_read),0)
                              +COALESCE(SUM(cache_write_5m),0)+COALESCE(SUM(cache_write_1h),0)
                              +COALESCE(SUM(output),0)) DESC"#;
        let mut stmt = self.conn.prepare(sql)?;
        let rows = stmt.query_map(params![date], |r| {
            Ok(DayPart {
                model: r.get::<_, Option<String>>(0)?.unwrap_or_default(),
                source: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                counters: Counters {
                    input_fresh: r.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                    cache_read: r.get::<_, Option<i64>>(3)?.map(|v| v as u64),
                    cache_write_5m: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
                    cache_write_1h: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
                    output: r.get::<_, Option<i64>>(6)?.map(|v| v as u64),
                },
                events: r.get::<_, i64>(7)? as u64,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn totals(&self, q: &Query) -> Result<Totals, CoreError> {
        let (where_sql, args) = Self::where_clause(q);
        let sql = format!(
            r#"SELECT SUM(input_fresh), SUM(cache_read), SUM(cache_write_5m),
                      SUM(cache_write_1h), SUM(output), COUNT(*),
                      COUNT(DISTINCT session), COUNT(DISTINCT local_date),
                      MIN(local_date), MAX(local_date)
               FROM event{where_sql}"#
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::ToSql> = args.iter().map(|b| b.as_ref()).collect();
        let t = stmt.query_row(params.as_slice(), |r| {
            Ok(Totals {
                counters: Counters {
                    input_fresh: r.get::<_, Option<i64>>(0)?.map(|v| v as u64),
                    cache_read: r.get::<_, Option<i64>>(1)?.map(|v| v as u64),
                    cache_write_5m: r.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                    cache_write_1h: r.get::<_, Option<i64>>(3)?.map(|v| v as u64),
                    output: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
                },
                events: r.get::<_, i64>(5)? as u64,
                sessions: r.get::<_, i64>(6)? as u64,
                days: r.get::<_, i64>(7)? as u64,
                first_date: r.get(8)?,
                last_date: r.get(9)?,
            })
        })?;
        Ok(t)
    }

    /// Event counts by confidence, so a report can say how much of a number is
    /// backed by a provider-assigned id rather than a guess.
    pub fn confidence_breakdown(&self) -> Result<Vec<(String, u64)>, CoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT confidence, COUNT(*) FROM event GROUP BY confidence ORDER BY 2 DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Everything a statusline needs, in one pass.
    ///
    /// A statusline runs on every shell prompt, so this must never scan the
    /// filesystem and must touch the database as little as possible. Both
    /// queries hit the `local_date` index.
    pub fn statusline_snapshot(
        &self,
        today: &str,
        month_start: &str,
    ) -> Result<(Counters, Counters), CoreError> {
        let one = |since: &str, until: Option<&str>| -> Result<Counters, CoreError> {
            let sql = match until {
                Some(_) => {
                    "SELECT SUM(input_fresh), SUM(cache_read), SUM(cache_write_5m), \
                            SUM(cache_write_1h), SUM(output) FROM event \
                            WHERE local_date >= ?1 AND local_date <= ?2"
                }
                None => {
                    "SELECT SUM(input_fresh), SUM(cache_read), SUM(cache_write_5m), \
                         SUM(cache_write_1h), SUM(output) FROM event WHERE local_date >= ?1"
                }
            };
            let mut stmt = self.conn.prepare(sql)?;
            let map = |r: &rusqlite::Row| -> rusqlite::Result<Counters> {
                Ok(Counters {
                    input_fresh: r.get::<_, Option<i64>>(0)?.map(|v| v as u64),
                    cache_read: r.get::<_, Option<i64>>(1)?.map(|v| v as u64),
                    cache_write_5m: r.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                    cache_write_1h: r.get::<_, Option<i64>>(3)?.map(|v| v as u64),
                    output: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
                })
            };
            Ok(match until {
                Some(u) => stmt.query_row(params![since, u], map)?,
                None => stmt.query_row(params![since], map)?,
            })
        };
        Ok((one(today, Some(today))?, one(month_start, Some(today))?))
    }

    /// Busiest local hour, used for the overview.
    pub fn peak_hour(&self) -> Result<Option<u8>, CoreError> {
        Ok(self
            .conn
            .query_row(
                "SELECT local_hour FROM event GROUP BY local_hour ORDER BY COUNT(*) DESC LIMIT 1",
                [],
                |r| r.get::<_, i64>(0),
            )
            .optional()?
            .map(|h| h as u8))
    }

    /// Contiguous 5 hour usage windows.
    ///
    /// A block opens on the first event after a quiet gap (or when the previous
    /// window has already elapsed) and closes five hours later. That matches
    /// how Claude's rate-limit windows behave, and is more useful than fixed
    /// clock-aligned buckets for "how much of my current block have I used".
    pub fn blocks(&self, q: &Query, now_ms: i64) -> Result<Vec<UsageBlock>, CoreError> {
        let (where_sql, args) = Self::where_clause(q);
        let sql = format!(
            "SELECT ts_ms, session, input_fresh, cache_read, cache_write_5m, \
             cache_write_1h, output FROM event{where_sql} ORDER BY ts_ms ASC"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::ToSql> = args.iter().map(|b| b.as_ref()).collect();
        let rows = stmt.query_map(params.as_slice(), |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                Counters {
                    input_fresh: r.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                    cache_read: r.get::<_, Option<i64>>(3)?.map(|v| v as u64),
                    cache_write_5m: r.get::<_, Option<i64>>(4)?.map(|v| v as u64),
                    cache_write_1h: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
                    output: r.get::<_, Option<i64>>(6)?.map(|v| v as u64),
                },
            ))
        })?;

        let mut blocks: Vec<(UsageBlock, HashSet<String>)> = Vec::new();
        for row in rows {
            let (ts_ms, session, counters) = row?;
            let open_new = match blocks.last() {
                None => true,
                Some((b, _)) => ts_ms >= b.end_ms,
            };
            if open_new {
                let mut sessions = HashSet::new();
                sessions.insert(session);
                blocks.push((
                    UsageBlock {
                        start_ms: ts_ms,
                        end_ms: ts_ms + BLOCK_DURATION_MS,
                        counters,
                        events: 1,
                        sessions: 1,
                        active: false,
                    },
                    sessions,
                ));
            } else if let Some((b, sessions)) = blocks.last_mut() {
                b.counters.accumulate(&counters);
                b.events += 1;
                sessions.insert(session);
                b.sessions = sessions.len() as u64;
            }
        }

        Ok(blocks
            .into_iter()
            .map(|(mut b, _)| {
                b.active = now_ms >= b.start_ms && now_ms < b.end_ms;
                b
            })
            .collect())
    }

    /// Events matching a query, oldest first. Used by `export`.
    pub fn events(&self, q: &Query) -> Result<Vec<EventRow>, CoreError> {
        let (where_sql, args) = Self::where_clause(q);
        let sql = format!(
            "SELECT id, source, ts_ms, local_date, model, session, project, \
             input_fresh, cache_read, cache_write_5m, cache_write_1h, output \
             FROM event{where_sql} ORDER BY ts_ms ASC"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::ToSql> = args.iter().map(|b| b.as_ref()).collect();
        let rows = stmt.query_map(params.as_slice(), |r| {
            let id_bytes: Vec<u8> = r.get(0)?;
            let id = id_bytes.iter().map(|b| format!("{b:02x}")).collect();
            Ok(EventRow {
                id,
                source: r.get(1)?,
                ts_ms: r.get(2)?,
                local_date: r.get(3)?,
                model: r.get(4)?,
                session: r.get(5)?,
                project: r.get(6)?,
                counters: Counters {
                    input_fresh: r.get::<_, Option<i64>>(7)?.map(|v| v as u64),
                    cache_read: r.get::<_, Option<i64>>(8)?.map(|v| v as u64),
                    cache_write_5m: r.get::<_, Option<i64>>(9)?.map(|v| v as u64),
                    cache_write_1h: r.get::<_, Option<i64>>(10)?.map(|v| v as u64),
                    output: r.get::<_, Option<i64>>(11)?.map(|v| v as u64),
                },
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Input plus output only, excluding cache. This matches the definition
    /// Claude Code uses for its own headline figure, so the two are comparable.
    pub fn in_out_total(&self) -> Result<u64, CoreError> {
        Ok(self.conn.query_row(
            "SELECT COALESCE(SUM(input_fresh),0)+COALESCE(SUM(output),0) FROM event",
            [],
            |r| r.get::<_, i64>(0),
        )? as u64)
    }

    /// Every recorded file watermark, keyed by path.
    pub fn watermarks(&self) -> Result<std::collections::HashMap<String, Watermark>, CoreError> {
        let mut stmt = self
            .conn
            .prepare("SELECT path, size, mtime_ms, head_sig, sig_len, byte_offset FROM shard")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                Watermark {
                    size: r.get::<_, i64>(1)? as u64,
                    mtime_ms: r.get::<_, i64>(2)?,
                    head_sig: r.get::<_, String>(3)?,
                    sig_len: r.get::<_, i64>(4)? as u64,
                    byte_offset: r.get::<_, i64>(5)? as u64,
                },
            ))
        })?;
        Ok(rows.collect::<Result<std::collections::HashMap<_, _>, _>>()?)
    }

    /// Record where each file was read up to.
    pub fn set_watermarks(&mut self, marks: &[(String, Watermark)]) -> Result<(), CoreError> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO shard (path, size, mtime_ms, head_sig, sig_len, byte_offset)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(path) DO UPDATE SET
                   size = excluded.size, mtime_ms = excluded.mtime_ms,
                   head_sig = excluded.head_sig, sig_len = excluded.sig_len,
                   byte_offset = excluded.byte_offset",
            )?;
            for (path, w) in marks {
                stmt.execute(params![
                    path,
                    w.size as i64,
                    w.mtime_ms,
                    w.head_sig,
                    w.sig_len as i64,
                    w.byte_offset as i64
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Forget all scan state, forcing the next scan to read everything.
    pub fn clear_watermarks(&self) -> Result<(), CoreError> {
        self.conn.execute("DELETE FROM shard", [])?;
        Ok(())
    }

    /// Input plus output per (date, model) from transcripts only.
    ///
    /// This is what a vendor rollup is compared against to work out how much of
    /// each day was lost to log cleanup.
    pub fn in_out_by_date_model(
        &self,
    ) -> Result<std::collections::BTreeMap<(String, String), u64>, CoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT local_date, model, COALESCE(SUM(input_fresh),0)+COALESCE(SUM(output),0)
             FROM event WHERE source = 'claude_code' GROUP BY local_date, model",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                (r.get::<_, String>(0)?, r.get::<_, String>(1)?),
                r.get::<_, i64>(2)? as u64,
            ))
        })?;
        Ok(rows.collect::<Result<std::collections::BTreeMap<_, _>, _>>()?)
    }

    /// SQL for [`Self::sync_rollup`]. Groups by day × source × model × project.
    /// Session is never selected. Project paths stay local until hashed into
    /// opaque `proj` keys in the payload builder.
    pub const SYNC_ROLLUP_SQL: &'static str = r#"
        SELECT local_date,
               source,
               model,
               project,
               COALESCE(SUM(input_fresh), 0),
               COALESCE(SUM(output), 0),
               COALESCE(SUM(cache_read), 0),
               COALESCE(SUM(cache_write_5m), 0),
               COALESCE(SUM(cache_write_1h), 0),
               COUNT(*),
               MIN(CASE WHEN billing = 'plan' THEN 1 ELSE 0 END),
               MIN(CASE confidence
                     WHEN 'derived' THEN 0
                     WHEN 'strong'  THEN 1
                     WHEN 'exact'   THEN 2
                     ELSE 0
                   END)
        FROM event
        WHERE local_date >= ?1 AND local_date <= ?2
        GROUP BY local_date, source, model, project
        ORDER BY local_date, source, model, project
    "#;

    /// Day × source × model × project rollup for sync.
    pub fn sync_rollup(&self, from: &str, to: &str) -> Result<Vec<SyncRollupBucket>, CoreError> {
        let mut stmt = self.conn.prepare(Self::SYNC_ROLLUP_SQL)?;
        let rows = stmt.query_map(params![from, to], |r| {
            let plan_all: i64 = r.get(10)?;
            let conf_rank: i64 = r.get(11)?;
            let conf = match conf_rank {
                2 => "exact",
                1 => "strong",
                _ => "derived",
            };
            let mut model: String = r.get(2)?;
            if model.len() > 128 {
                model.truncate(128);
            }
            Ok(SyncRollupBucket {
                d: r.get(0)?,
                src: r.get(1)?,
                model,
                project: r.get(3)?,
                input: r.get::<_, i64>(4)? as u64,
                out: r.get::<_, i64>(5)? as u64,
                cr: r.get::<_, i64>(6)? as u64,
                cw5: r.get::<_, i64>(7)? as u64,
                cw1: r.get::<_, i64>(8)? as u64,
                ev: r.get::<_, i64>(9)? as u64,
                plan: plan_all == 1,
                conf: conf.to_string(),
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Drop recovered rows so a scan can recompute them.
    ///
    /// Recovered events are derived state: the shortfall they represent shrinks
    /// as more transcripts are read and grows as the vendor rollup advances.
    /// Recomputing from scratch each scan keeps them correct without needing an
    /// update path, and it stays idempotent because the inputs are unchanged.
    pub fn clear_recovered(&self) -> Result<(), CoreError> {
        self.conn
            .execute("DELETE FROM event WHERE source = 'claude_code_rollup'", [])?;
        Ok(())
    }

    pub fn set_meta(&self, k: &str, v: &str) -> Result<(), CoreError> {
        self.conn.execute(
            "INSERT INTO meta (k, v) VALUES (?1, ?2)
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            params![k, v],
        )?;
        Ok(())
    }

    pub fn meta(&self, k: &str) -> Result<Option<String>, CoreError> {
        Ok(self
            .conn
            .query_row("SELECT v FROM meta WHERE k = ?1", params![k], |r| r.get(0))
            .optional()?)
    }

    pub fn delete_meta(&self, k: &str) -> Result<(), CoreError> {
        self.conn
            .execute("DELETE FROM meta WHERE k = ?1", params![k])?;
        Ok(())
    }

    /// Remove every event, keeping settings. Used by `scan --reset`.
    pub fn clear_events(&self) -> Result<(), CoreError> {
        self.conn.execute("DELETE FROM event", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{BillingMode, Confidence, EventId, Extras, SourceId, Timestamp};

    fn ev(id: &str, date_ms: i64, model: &str, out: u64) -> UsageEvent {
        UsageEvent {
            id: EventId::derive(&[id]),
            source: SourceId::ClaudeCode,
            ts: Timestamp::from_ms(date_ms),
            model: model.into(),
            session: "s1".into(),
            project: "p".into(),
            counters: Counters {
                input_fresh: Some(1),
                cache_read: Some(2),
                cache_write_5m: Some(3),
                cache_write_1h: None,
                output: Some(out),
            },
            extras: Extras::default(),
            billing: BillingMode::Plan,
            confidence: Confidence::Exact,
        }
    }

    #[test]
    fn reinserting_the_same_events_is_a_no_op() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let events = vec![
            ev("a", 1_700_000_000_000, "m1", 10),
            ev("b", 1_700_000_000_000, "m1", 20),
        ];

        assert_eq!(s.insert_events(&events, &tz).unwrap(), 2);
        // Ingesting twice must not change any total. This is the property that
        // makes re-scanning a rewritten transcript safe.
        assert_eq!(s.insert_events(&events, &tz).unwrap(), 0);

        let t = s.totals(&Query::default()).unwrap();
        assert_eq!(t.events, 2);
        assert_eq!(t.counters.output, Some(30));
    }

    #[test]
    fn grouping_by_model_orders_by_volume() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        s.insert_events(
            &[
                ev("a", 1_700_000_000_000, "small", 1),
                ev("b", 1_700_000_000_000, "big", 500),
            ],
            &tz,
        )
        .unwrap();
        let r = s.report(GroupBy::Model, &Query::default()).unwrap();
        assert_eq!(r[0].key, "big");
        assert_eq!(r[1].key, "small");
    }

    #[test]
    fn day_detail_groups_by_model_and_source_and_filters_the_date() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        // 2023-11-14 and 2023-11-15. The same model on the same day through two
        // harnesses stays two rows; the same pair on another day stays out.
        let mut codex = ev("a", 1_699_920_000_000, "gpt-x", 10);
        codex.source = SourceId::Codex;
        let mut claude = ev("b", 1_699_920_000_000, "gpt-x", 30);
        claude.source = SourceId::ClaudeCode;
        let mut next_day = ev("c", 1_700_006_400_000, "gpt-x", 50);
        next_day.source = SourceId::Codex;
        s.insert_events(&[codex, claude, next_day], &tz).unwrap();

        let rows = s.day_detail("2023-11-14").unwrap();
        assert_eq!(rows.len(), 2);
        // Ordered by tokens descending: the Claude Code row is the larger one.
        assert_eq!(rows[0].source, "claude_code");
        assert_eq!(rows[0].model, "gpt-x");
        assert_eq!(rows[0].counters.output, Some(30));
        assert_eq!(rows[0].events, 1);
        assert_eq!(rows[0].tokens(), 36); // 1 fresh + 2 cache read + 3 cache write + 30 out
        assert_eq!(rows[1].source, "codex");
        assert_eq!(rows[1].tokens(), 16);

        // A day with no events is an empty list, not an error.
        assert!(s.day_detail("2023-11-13").unwrap().is_empty());
    }

    #[test]
    fn date_filters_apply() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        // 2023-11-14 and 2023-11-15
        s.insert_events(
            &[
                ev("a", 1_699_920_000_000, "m", 5),
                ev("b", 1_700_006_400_000, "m", 7),
            ],
            &tz,
        )
        .unwrap();
        let q = Query {
            since: Some("2023-11-15".into()),
            ..Default::default()
        };
        let t = s.totals(&q).unwrap();
        assert_eq!(t.events, 1);
        assert_eq!(t.counters.output, Some(7));
    }

    #[test]
    fn billing_filter_keeps_plan_usage_separate() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let mut metered = ev("metered", 1_700_000_000_000, "m", 11);
        metered.billing = BillingMode::Metered;
        s.insert_events(&[ev("plan", 1_700_000_000_000, "m", 7), metered], &tz)
            .unwrap();

        let plan = s
            .report(
                GroupBy::Source,
                &Query {
                    billing: Some(BillingMode::Plan),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].counters.output, Some(7));
    }

    #[test]
    fn statusline_snapshot_scopes_today_separately_from_the_month() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        // 2023-11-14 and 2023-11-15, both in the same month.
        s.insert_events(
            &[
                ev("a", 1_699_920_000_000, "m", 5),
                ev("b", 1_700_006_400_000, "m", 7),
            ],
            &tz,
        )
        .unwrap();

        let (day, month) = s.statusline_snapshot("2023-11-15", "2023-11-01").unwrap();
        assert_eq!(day.output, Some(7), "today should exclude yesterday");
        assert_eq!(month.output, Some(12), "month should include both days");
    }

    #[test]
    fn statusline_snapshot_on_an_empty_archive_is_not_an_error() {
        let s = Store::open_in_memory().unwrap();
        let (day, month) = s.statusline_snapshot("2026-07-29", "2026-07-01").unwrap();
        // Nothing recorded is unknown, not zero, and must not panic.
        assert_eq!(day.output, None);
        assert_eq!(month.total(), 0);
    }

    #[test]
    fn a_quiet_gap_opens_a_new_five_hour_block() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let t0 = 1_700_000_000_000i64;
        s.insert_events(
            &[
                ev("a", t0, "m", 1),
                ev("b", t0 + 60_000, "m", 2), // same block
                ev("c", t0 + BLOCK_DURATION_MS + 1, "m", 3), // next block
            ],
            &tz,
        )
        .unwrap();
        let blocks = s.blocks(&Query::default(), t0 + 30_000).unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].events, 2);
        assert_eq!(blocks[0].counters.output, Some(3));
        assert!(blocks[0].active);
        assert!(!blocks[1].active);
        assert_eq!(blocks[1].events, 1);
    }

    #[test]
    fn unknown_counter_stays_unknown_through_aggregation() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        s.insert_events(&[ev("a", 1_700_000_000_000, "m", 1)], &tz)
            .unwrap();
        let t = s.totals(&Query::default()).unwrap();
        // cache_write_1h was never reported, so it must not read as zero.
        assert_eq!(t.counters.cache_write_1h, None);
        assert!(t.counters.has_unknown());
    }

    #[test]
    fn cache_only_growth_updates_and_null_stays_null() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let mut first = ev("a", 1_700_000_000_000, "m", 10);
        first.counters.cache_read = Some(1);
        first.counters.cache_write_5m = None;
        s.insert_events(&[first.clone()], &tz).unwrap();

        let mut second = first.clone();
        second.counters.cache_read = Some(50);
        second.counters.output = Some(10); // same output: no output growth
        assert_eq!(s.insert_events(&[second], &tz).unwrap(), 1);

        let t = s.totals(&Query::default()).unwrap();
        assert_eq!(t.counters.cache_read, Some(50));
        assert_eq!(t.counters.cache_write_5m, None);
        assert_eq!(t.counters.output, Some(10));
    }

    #[test]
    fn statusline_snapshot_excludes_dates_after_today() {
        let mut s = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        // 2023-11-15 and 2023-11-20. Snapshot for the 15th must not include the 20th.
        s.insert_events(
            &[
                ev("a", 1_700_006_400_000, "m", 7),
                ev("b", 1_700_438_400_000, "m", 100),
            ],
            &tz,
        )
        .unwrap();
        let (day, month) = s.statusline_snapshot("2023-11-15", "2023-11-01").unwrap();
        assert_eq!(day.output, Some(7));
        assert_eq!(month.output, Some(7));
    }

    #[test]
    fn opening_an_existing_archive_does_not_need_the_writer_to_finish() {
        // The old open path ran CREATE TABLE on every call, which takes a write
        // lock and lost to a concurrent scan. Re-opening an existing file must
        // stay read-only enough to succeed while another connection holds a
        // write transaction.
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-store-busy-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tokenstat.db");

        {
            let mut s = Store::open(&path).unwrap();
            let tz = jiff::tz::TimeZone::UTC;
            s.insert_events(&[ev("a", 1_700_000_000_000, "m", 1)], &tz)
                .unwrap();
        }

        let writer = Connection::open(&path).unwrap();
        writer
            .busy_timeout(std::time::Duration::from_secs(60))
            .unwrap();
        writer.pragma_update(None, "journal_mode", "WAL").unwrap();
        let tx = writer.unchecked_transaction().unwrap();
        tx.execute("UPDATE event SET output = output WHERE 1 = 1", [])
            .unwrap();

        let reader = Store::open(&path).expect("open must not wait on DDL behind a writer");
        let totals = reader
            .totals(&Query::default())
            .expect("WAL reads must work during a write transaction");
        assert_eq!(totals.events, 1);

        tx.commit().unwrap();
        drop(writer);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
