// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
//
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.
//! Refreshing the list-rate price book, and keeping a session's cached copy in
//! step.

use tokenstat_core::PriceTable;

use crate::session::Session;

const MAX_SEED_BYTES: u64 = 32 * 1024 * 1024;

/// Replace a session's cached book with what is on disk.
///
/// Called after a successful refresh. Cheap enough for the hourly cadence: one
/// read and one parse of the snapshot file, and the catalog behind it is
/// shared, not re-read per report.
pub fn reload(session: &mut Session) {
    if let Ok(path) = PriceTable::default_path() {
        reload_from(session, &path);
    } else {
        session.prices = PriceTable::load_with_catalog();
    }
}

fn reload_from(session: &mut Session, path: &std::path::Path) {
    session.prices = PriceTable::load_from(path)
        .unwrap_or_default()
        .with_catalog(std::sync::Arc::new(tokenstat_core::catalog::Catalog::load()))
        .with_local_models(tokenstat_core::pricing::local_models::load());
}

/// Attach the local model list again once a server has shown a new one, so
/// its usage prices at zero without waiting for a restart.
pub fn refresh_local_models(session: &mut Session) {
    if session.prices.local_models_stale() {
        session.prices = session
            .prices
            .clone()
            .with_local_models(tokenstat_core::pricing::local_models::load());
    }
}

/// What seeding did, so a front end can say so rather than guess.
#[derive(Debug)]
pub struct Seeded {
    /// False when a book was already there. Not a failure: the local one is
    /// newer than anything a bundle could carry.
    pub adopted: bool,
    pub effective_from: String,
    pub models: usize,
}

/// Adopt a bundled price book when this machine has none.
///
/// A desktop install fetches its own book: the CLI does it on demand and the
/// daemon does it on a schedule. A phone has neither a CLI nor a daemon, so its
/// first launch would price every model as unknown until a refresh landed, on
/// the screen that opens first.
///
/// The app therefore ships a book and points this at it. Three rules make that
/// safe to call on every launch:
///
/// - It never overwrites an existing book. A fetched one is always newer than
///   anything a bundle can carry, and a build from March must not undo an
///   August refresh.
/// - It parses before it copies, so a corrupt resource leaves no book rather
///   than an unreadable one.
/// - It reloads the session, so the very first report prices against it instead
///   of against the empty book the session opened with.
pub fn seed(session: &mut Session, from: &std::path::Path) -> Result<Seeded, String> {
    let destination = PriceTable::default_path().map_err(|e| e.to_string())?;
    seed_into(session, from, &destination)
}

fn seed_into(
    session: &mut Session,
    from: &std::path::Path,
    destination: &std::path::Path,
) -> Result<Seeded, String> {
    if destination.exists() {
        return Ok(Seeded {
            adopted: false,
            effective_from: session.prices.effective_from.clone(),
            models: 0,
        });
    }

    let metadata = std::fs::metadata(from).map_err(|e| format!("{}: {e}", from.display()))?;
    if !metadata.is_file() {
        return Err(format!("{} is not a regular price book", from.display()));
    }
    if metadata.len() > MAX_SEED_BYTES {
        return Err(format!(
            "{} is larger than {} MiB and is not a price book",
            from.display(),
            MAX_SEED_BYTES / (1024 * 1024)
        ));
    }
    use std::io::Read;
    let mut text = String::new();
    std::fs::File::open(from)
        .map_err(|e| e.to_string())?
        .take(MAX_SEED_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|e| e.to_string())?;
    if text.len() as u64 > MAX_SEED_BYTES {
        return Err("price book grew beyond its size limit".into());
    }
    let table = PriceTable::parse(&text)
        .ok_or_else(|| format!("{} is not a price book", from.display()))?;
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    if !tokenstat_sync::snapshot::write_private_if_missing(destination, &text)
        .map_err(|e| e.to_string())?
    {
        reload_from(session, destination);
        return Ok(Seeded {
            adopted: false,
            effective_from: session.prices.effective_from.clone(),
            models: 0,
        });
    }

    session.prices = PriceTable::load_from(destination)
        .unwrap_or_default()
        .with_catalog(std::sync::Arc::new(tokenstat_core::catalog::Catalog::load()))
        .with_local_models(tokenstat_core::pricing::local_models::load());
    Ok(Seeded {
        adopted: true,
        models: table.len(),
        effective_from: table.effective_from,
    })
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static SEQ: AtomicU64 = AtomicU64::new(0);

    const SNAPSHOT: &str = r#"{
      "effective_from": "2026-08-01",
      "note": "List-rate snapshot generated by tokenstat.ai.",
      "models": [{
        "match": "example/model",
        "input": 3.0,
        "output": 15.0,
        "cache_read": 0.3,
        "cache_write_5m": 3.75,
        "cache_write_1h": 0.0
      }]
    }"#;

    #[test]
    fn a_refreshed_book_replaces_the_cached_one() {
        let dir = tempfile::tempdir().unwrap();
        let book = dir.path().join("current.json");
        std::fs::write(&book, SNAPSHOT).unwrap();
        let mut session = Session::open_client(Some("UTC")).unwrap();
        session.prices = PriceTable::default();
        assert!(
            session.prices.is_empty(),
            "precondition: session is unpriced"
        );

        reload_from(&mut session, &book);

        assert!(!session.prices.is_empty(), "reload must pick up the book");
        assert_eq!(session.prices.effective_from, "2026-08-01");
        assert_eq!(
            session.prices.get_exact("example/model").map(|r| r.input),
            Some(3.0)
        );
    }

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-seed-{tag}-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_bundled_book_is_adopted_only_when_there_is_none() {
        let dir = temp_dir("adopt");
        let bundled = dir.join("bundled.json");
        let book = dir.join("data").join("current.json");
        std::fs::write(&bundled, SNAPSHOT).unwrap();

        let mut session = Session::open_client(Some("UTC")).expect("client session");
        session.prices = PriceTable::default();

        let first = seed_into(&mut session, &bundled, &book).expect("seed");
        assert!(first.adopted);
        assert_eq!(first.effective_from, "2026-08-01");
        assert_eq!(first.models, 1);
        assert!(
            !session.prices.is_empty(),
            "seeding must leave the session priced, not just the disk"
        );

        std::fs::write(&book, SNAPSHOT.replace("2026-08-01", "2026-09-09").as_str()).unwrap();
        let again = seed_into(&mut session, &bundled, &book).expect("seed again");
        assert!(!again.adopted, "an existing book must not be replaced");
        assert!(
            std::fs::read_to_string(&book)
                .unwrap()
                .contains("2026-09-09"),
            "the fetched book survived"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_corrupt_bundle_leaves_no_book_at_all() {
        let dir = temp_dir("corrupt");
        let bundled = dir.join("bundled.json");
        let book = dir.join("data").join("current.json");
        std::fs::write(&bundled, "{ this is not a price book").unwrap();

        let mut session = Session::open_client(Some("UTC")).expect("client session");
        assert!(seed_into(&mut session, &bundled, &book).is_err());
        assert!(
            !book.exists(),
            "a book that will not parse must not be copied into place: an \
             unreadable book is worse than none, because none is refreshable"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_too_large_to_be_a_book_is_refused() {
        let dir = temp_dir("oversize");
        let bundled = dir.join("bundled.json");
        let file = std::fs::File::create(&bundled).unwrap();
        file.set_len(MAX_SEED_BYTES + 1).unwrap();

        let mut session = Session::open_client(Some("UTC")).expect("client session");
        let book = dir.join("data").join("current.json");
        let error = seed_into(&mut session, &bundled, &book).expect_err("must refuse");
        assert!(error.contains("larger than"), "{error}");
        assert!(!book.exists(), "nothing may be copied into place");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
