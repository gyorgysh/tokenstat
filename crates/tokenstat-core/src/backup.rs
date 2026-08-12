// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Rotating local copies of the archive, logrotate style.
//!
//! The archive is not reconstructible. Transcripts are deleted by the tools
//! that wrote them after about 30 days, and a vendor rollup's per-day window
//! slides, so a scan run today against a machine that has been running for
//! months reads a strictly smaller world than the archive already holds. Losing
//! the file means losing history that no longer exists anywhere else, and the
//! way it gets lost is not disk failure: it is `scan --reset`, which is one
//! flag away from a full rescan of a world that has since shrunk.
//!
//! So: one copy a day, seven kept, oldest dropped. `tokenstat.db.0` is the
//! newest. They are never read back automatically. Restoring is a deliberate
//! act by a person who knows why, which is the only kind of restore that should
//! ever happen to a file like this.
//!
//! Copies are made with `VACUUM INTO`, not by copying bytes. The archive runs
//! in WAL mode, where the file on disk is only part of the database: a plain
//! copy taken while a scan holds a write transaction is a torn database that
//! looks fine until the day it is needed. `VACUUM INTO` takes a read lock,
//! writes a consistent and compacted snapshot, and cannot observe a half-
//! written page.

use std::path::{Path, PathBuf};

use crate::error::CoreError;

/// How many daily copies to keep. Seven covers a week away from the machine,
/// which is the gap that matters: a scan that quietly went wrong on Monday is
/// noticed when the numbers look odd on Friday, not within the hour.
pub const KEEP: usize = 7;

/// One day, in milliseconds. The rotation is daily rather than per scan
/// because scans run hourly, and twenty-four copies of the same day would push
/// the only pre-mistake copy off the end within a day.
const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// Archive key holding when the last copy was taken.
const STAMP: &str = "last_backup_ms";

/// `path` with `.N` appended, the numbering `rotate` shifts through.
fn slot(path: &Path, n: usize) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(format!(".{n}"));
    PathBuf::from(s)
}

/// True when no copy exists yet, or the newest one is a day old.
pub fn is_due(last_backup_ms: Option<i64>, now_ms: i64) -> bool {
    match last_backup_ms {
        // A stamp in the future means the clock moved backwards, which is a
        // reason to take a copy rather than to skip one indefinitely.
        Some(t) => now_ms.saturating_sub(t) >= DAY_MS || t > now_ms,
        None => true,
    }
}

/// Shift every copy one slot older, dropping the last, then leave slot 0 free.
///
/// Renames rather than copies, so the cost does not grow with the number kept
/// and no slot is ever briefly absent while a copy is in flight. Walks
/// backwards for the obvious reason: forwards would overwrite each slot with
/// the one behind it and leave seven copies of the same day.
fn rotate(path: &Path, keep: usize) -> std::io::Result<()> {
    let oldest = slot(path, keep - 1);
    if oldest.exists() {
        std::fs::remove_file(&oldest)?;
    }
    for n in (0..keep - 1).rev() {
        let from = slot(path, n);
        if from.exists() {
            std::fs::rename(&from, slot(path, n + 1))?;
        }
    }
    Ok(())
}

/// Take today's copy, if one is not already taken.
///
/// Returns the path written, or `None` when a copy for today already exists.
/// Errors are the caller's to soften: a failed backup must never fail a scan,
/// because the scan is the thing that is actually collecting the data.
///
/// **The new copy is written before anything is rotated.** The other order is
/// the obvious one and it is a trap: rotation deletes the oldest copy, so a
/// `VACUUM INTO` that then fails has destroyed a backup and produced nothing.
/// The failure that matters here is a full disk, which is also the failure that
/// repeats: the stamp is only advanced on success, so the next hourly scan
/// tries again, and seven of those would shift every copy off the end. Writing
/// first means a failed backup costs nothing at all.
pub fn run(
    conn: &rusqlite::Connection,
    path: &Path,
    last_backup_ms: Option<i64>,
    now_ms: i64,
    keep: usize,
) -> Result<Option<PathBuf>, CoreError> {
    if keep == 0 || !is_due(last_backup_ms, now_ms) {
        return Ok(None);
    }
    // A temporary name, because `VACUUM INTO` refuses to overwrite and slot 0
    // is still occupied by yesterday's copy at this point.
    let tmp = slot(path, keep).with_extension("part");
    if tmp.exists() {
        let _ = std::fs::remove_file(&tmp);
    }
    if let Err(e) = conn.execute("VACUUM INTO ?1", [tmp.to_string_lossy().as_ref()]) {
        // Leave no half-written file behind to be mistaken for a copy, and
        // leave the existing copies exactly as they were.
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    rotate(path, keep).map_err(|source| CoreError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let dest = slot(path, 0);
    std::fs::rename(&tmp, &dest).map_err(|source| CoreError::Io {
        path: dest.clone(),
        source,
    })?;
    Ok(Some(dest))
}

/// Every copy that exists, newest first, with its size in bytes.
pub fn list(path: &Path, keep: usize) -> Vec<(PathBuf, u64)> {
    (0..keep)
        .map(|n| slot(path, n))
        .filter_map(|p| {
            let len = std::fs::metadata(&p).ok()?.len();
            Some((p, len))
        })
        .collect()
}

/// The archive key holding the last backup time, for callers that persist it.
pub fn stamp_key() -> &'static str {
    STAMP
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_archive_is_due_and_a_just_copied_one_is_not() {
        assert!(is_due(None, 0));
        assert!(!is_due(Some(1_000), 1_000 + DAY_MS - 1));
        assert!(is_due(Some(1_000), 1_000 + DAY_MS));
    }

    /// A clock that jumped backwards must not park the rotation forever.
    #[test]
    fn a_stamp_from_the_future_is_due_now() {
        assert!(is_due(Some(10 * DAY_MS), 0));
    }

    #[test]
    fn rotation_shifts_every_slot_and_drops_the_oldest() {
        let dir = std::env::temp_dir().join(format!("ts-backup-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("a.db");
        for n in 0..3 {
            std::fs::write(slot(&db, n), format!("gen{n}")).unwrap();
        }
        rotate(&db, 3).unwrap();
        // gen2 was the oldest of three and is gone, the rest moved up one.
        assert!(
            !slot(&db, 0).exists(),
            "slot 0 is left free for the new copy"
        );
        assert_eq!(std::fs::read_to_string(slot(&db, 1)).unwrap(), "gen0");
        assert_eq!(std::fs::read_to_string(slot(&db, 2)).unwrap(), "gen1");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The copy has to be openable and hold the same rows, which is the whole
    /// point and the thing a byte copy of a WAL database silently fails at.
    #[test]
    fn a_copy_is_a_readable_archive_with_the_same_contents() {
        let dir = std::env::temp_dir().join(format!("ts-backup-run-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("a.db");
        {
            let conn = rusqlite::Connection::open(&db).unwrap();
            conn.pragma_update(None, "journal_mode", "WAL").unwrap();
            conn.execute("CREATE TABLE t (v INTEGER)", []).unwrap();
            conn.execute("INSERT INTO t VALUES (42)", []).unwrap();
            let made = run(&conn, &db, None, 0, 3).unwrap().unwrap();
            assert_eq!(made, slot(&db, 0));
        }
        let copy = rusqlite::Connection::open(slot(&db, 0)).unwrap();
        let v: i64 = copy.query_row("SELECT v FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(v, 42);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The failure that matters: a copy that cannot be written must leave the
    /// copies that already exist untouched. Rotating first would have deleted
    /// the oldest and produced nothing in its place, once an hour, until none
    /// were left.
    #[test]
    fn a_failed_copy_destroys_nothing() {
        let dir = std::env::temp_dir().join(format!("ts-backup-fail-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("a.db");
        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.execute("CREATE TABLE t (v INTEGER)", []).unwrap();
        for n in 0..3 {
            std::fs::write(slot(&db, n), format!("gen{n}")).unwrap();
        }
        // A directory where the copy wants to write is a write that cannot
        // succeed, without needing to fill a disk to prove it.
        std::fs::create_dir_all(slot(&db, 3).with_extension("part")).unwrap();

        assert!(run(&conn, &db, None, 0, 3).is_err());

        for n in 0..3 {
            assert_eq!(
                std::fs::read_to_string(slot(&db, n)).unwrap(),
                format!("gen{n}"),
                "slot {n} must be exactly as it was"
            );
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_copy_already_taken_today_is_skipped() {
        let dir = std::env::temp_dir().join(format!("ts-backup-skip-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("a.db");
        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.execute("CREATE TABLE t (v INTEGER)", []).unwrap();
        assert!(run(&conn, &db, Some(0), 1_000, 3).unwrap().is_none());
        assert!(!slot(&db, 0).exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
