// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Kilo Code reader.
//!
//! Layout on disk:
//!
//! ```text
//! ~/.local/share/kilo/kilo.db
//! ```
//!
//! Kilo Code's CLI is an OpenCode fork and kept the storage: the same
//! `message` and `session` tables, the same JSON in the `data` column, the same
//! `tokens.{input,output,reasoning,cache.{read,write}}`, and a log file still
//! named `opencode.log` beside the database. So this is a location and a name,
//! and the reading is [`crate::sources::opencode`].
//!
//! It stays a separate tool rather than being folded into OpenCode, because a
//! person running both is running two products, is billed by two accounts, and
//! would not accept one row for the pair.
//!
//! Verified against a real database: `tokens.total` of 17,728 for a turn with
//! input 15,493, output 28, reasoning 31 and cache read 2,176, which sums
//! exactly, so reasoning is **beside** output here rather than inside it. That
//! is the arithmetic the OpenCode reader already folds.

use std::path::{Path, PathBuf};

use crate::model::SourceId;
use crate::sources::opencode::{self, ParseOutput};

/// Locate the Kilo Code database.
pub fn discover(home: &Path) -> Option<PathBuf> {
    // XDG data home, which is what it uses on macOS too rather than
    // Application Support.
    let candidates = [
        home.join(".local/share/kilo/kilo.db"),
        home.join("Library/Application Support/kilo/kilo.db"),
    ];
    candidates.into_iter().find(|p| p.is_file())
}

/// Read every message that carries token counters.
pub fn parse_db(path: &Path) -> ParseOutput {
    opencode::parse_db_as(path, SourceId::Kilo)
}

/// The live meter's narrowed read: one folder, since one moment.
pub fn parse_db_in(path: &Path, directory: Option<&str>, since_ms: Option<i64>) -> ParseOutput {
    opencode::parse_db_in_as(path, SourceId::Kilo, directory, since_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A database shaped like the real one, with the turn quoted in the module
    /// comment.
    fn temp_db() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("tokenstat-kilo-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("kilo.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, path TEXT);
             CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO session (id, directory, path) VALUES ('ses_1', '/Users/x/git/demo', '')",
            [],
        )
        .unwrap();
        let assistant = r#"{"role":"assistant","modelID":"kilo-auto/free","providerID":"kilo",
            "cost":0,"tokens":{"total":17728,"input":15493,"output":28,"reasoning":31,
            "cache":{"write":0,"read":2176}},"time":{"created":1787174892555}}"#;
        conn.execute(
            "INSERT INTO message (id, session_id, time_created, data) VALUES ('m1','ses_1',1787174892555,?1)",
            [assistant],
        )
        .unwrap();
        // A model that refused before it spent anything.
        let empty = r#"{"role":"assistant","modelID":"google/gemini-3-pro-image","cost":0,
            "tokens":{"input":0,"output":0,"reasoning":0,"cache":{"write":0,"read":0}},
            "time":{"created":1787174892600}}"#;
        conn.execute(
            "INSERT INTO message (id, session_id, time_created, data) VALUES ('m2','ses_1',1787174892600,?1)",
            [empty],
        )
        .unwrap();
        path
    }

    #[test]
    fn reads_a_turn_as_kilo() {
        let out = parse_db(&temp_db());
        assert_eq!(out.events.len(), 1);
        let e = &out.events[0];
        assert_eq!(e.source, SourceId::Kilo);
        assert_eq!(e.model, "kilo-auto/free");
        assert_eq!(e.project, "demo");
        assert_eq!(e.counters.input_fresh, Some(15493));
        assert_eq!(e.counters.cache_read, Some(2176));
        // Reasoning is beside output in this vendor's own total, so it is
        // folded in and the split kept in extras.
        assert_eq!(e.counters.output, Some(28 + 31));
        assert_eq!(e.extras.reasoning_within_output, Some(31));
    }

    #[test]
    fn its_ids_cannot_collide_with_opencodes() {
        let path = temp_db();
        let kilo = parse_db(&path);
        let as_opencode = opencode::parse_db(&path);
        assert_ne!(kilo.events[0].id, as_opencode.events[0].id);
    }

    #[test]
    fn a_free_model_reads_as_plan() {
        let out = parse_db(&temp_db());
        assert_eq!(out.events[0].billing, crate::model::BillingMode::Plan);
    }
}
