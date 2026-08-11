// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Whatever state a conversation needs, and an archive only if there is one.
//!
//! Deliberately a plain struct with no global. The C ABI keeps one in a static,
//! the socket server keeps one behind its own lock, and a test makes as many as
//! it likes. That last one matters: while the session was a process-wide
//! singleton, every test that touched it had to take a lock and run serially.
//!
//! # Why the archive is optional
//!
//! iOS and iPadOS keep no session logs, because nothing on them can run an
//! agent. A mobile client is a client of the account and of machines that do,
//! so it needs prices and a timezone and no `Engine` at all.
//!
//! The account grid already worked that way before this split:
//! [`crate::account_activity::calendar`] takes a price book and a timezone and
//! never touches a store. It was only reachable through a session that insisted
//! on opening SQLite first. Holding the price book and the zone here, rather
//! than reaching through the engine for them, is what lets that path run on a
//! machine with nothing to open.

use serde::Deserialize;
use tokenstat_core::{Engine, PriceTable};

use crate::error::DispatchError;

/// How to open an archive.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OpenParams {
    /// Override the archive location. Omit for the platform default.
    pub db_path: Option<String>,
    /// IANA name. Omit for the system zone.
    pub timezone: Option<String>,
}

/// Cached price book, the day boundary, an archive when this build has one,
/// and any sign-in in flight.
///
/// Opening an archive means opening SQLite and resolving the timezone, far too
/// expensive to repeat per call from a UI that reports on scroll. The price
/// book is cached for the same reason: the interactive CLI was re-reading it
/// every frame before that was fixed, and a GUI would make the same mistake
/// more often.
///
/// The registered folders are deliberately **not** here. They live in
/// `crate::workspaces`, behind their own lock, because a folder method reads
/// git rather than the archive and must not queue behind a scan. See that
/// module for why.
pub struct Session {
    /// Absent on a client build. Reach it through [`Session::engine`] rather
    /// than matching on it, so the refusal is worded once.
    engine: Option<Engine>,
    pub prices: PriceTable,
    /// The zone every day boundary is drawn in.
    ///
    /// Held here rather than read back off the engine because the account grid
    /// needs it on a machine that has no engine, and because two copies of the
    /// same fact eventually disagree.
    timezone: jiff::tz::TimeZone,
    /// Device authorization awaiting confirmation.
    ///
    /// Held here rather than returned to the caller because it carries the
    /// secret half of the grant. A front end sees only the short user code it
    /// displays, and polls with no arguments.
    pub pending_login: Option<tokenstat_sync::DeviceLogin>,
}

impl Session {
    /// Open the way this build is meant to run.
    ///
    /// With `local-host` that means opening the archive. Without it there is
    /// nothing to open, and asking would create an empty database in an app
    /// container that no parser will ever write to, which is worse than not
    /// having one: an empty archive answers "you have spent nothing" to a
    /// question it cannot see.
    pub fn open(p: &OpenParams) -> Result<Session, String> {
        #[cfg(feature = "local-host")]
        {
            Session::open_local(p)
        }
        #[cfg(not(feature = "local-host"))]
        {
            Session::open_client(p.timezone.as_deref())
        }
    }

    /// Open against an archive, whatever the build.
    ///
    /// Kept available without the feature so a test can exercise both shapes
    /// on one platform, and so a desktop tool that wants an archive can say so
    /// rather than depending on how the crate happened to be compiled.
    pub fn open_local(p: &OpenParams) -> Result<Session, String> {
        let path = p.db_path.as_ref().map(std::path::PathBuf::from);
        let engine =
            Engine::open(path.as_deref(), p.timezone.as_deref()).map_err(|e| e.to_string())?;
        let timezone = engine.timezone().clone();
        Ok(Session {
            engine: Some(engine),
            prices: PriceTable::load_with_catalog(),
            timezone,
            pending_login: None,
        })
    }

    /// Open with no archive: prices, a timezone, and the account.
    ///
    /// This is what a phone runs, and what any front end that only asks about
    /// the account or about another machine could run.
    pub fn open_client(timezone: Option<&str>) -> Result<Session, String> {
        let timezone = tokenstat_core::timezone(timezone).map_err(|e| e.to_string())?;
        Ok(Session {
            engine: None,
            prices: PriceTable::load_with_catalog(),
            timezone,
            pending_login: None,
        })
    }

    /// Open against the platform default archive and the system timezone.
    pub fn open_default() -> Result<Session, String> {
        Session::open(&OpenParams::default())
    }

    /// The archive, or the one worded refusal.
    pub fn engine(&self) -> Result<&Engine, DispatchError> {
        self.engine
            .as_ref()
            .ok_or_else(DispatchError::no_local_archive)
    }

    /// The archive for a method that writes to it, such as a scan.
    pub fn engine_mut(&mut self) -> Result<&mut Engine, DispatchError> {
        self.engine
            .as_mut()
            .ok_or_else(DispatchError::no_local_archive)
    }

    /// Whether this session can answer questions about this machine's own logs.
    ///
    /// For a front end deciding what to put on screen, not for a method
    /// deciding whether to fail: a method should ask for the engine and let the
    /// refusal happen in one place.
    pub fn has_archive(&self) -> bool {
        self.engine.is_some()
    }

    /// The zone every day boundary is drawn in.
    pub fn timezone(&self) -> &jiff::tz::TimeZone {
        &self.timezone
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::NO_LOCAL_ARCHIVE;

    #[test]
    fn a_client_session_has_prices_and_a_zone_but_no_archive() {
        let s = Session::open_client(Some("Europe/Budapest")).expect("client session");
        assert!(!s.has_archive());
        assert_eq!(s.timezone().iana_name(), Some("Europe/Budapest"));
        assert!(s.engine().is_err());
    }

    #[test]
    fn asking_a_client_session_for_the_archive_names_the_reason() {
        let mut s = Session::open_client(None).expect("client session");
        let read = s.engine().err().expect("no archive");
        assert_eq!(
            read.code, NO_LOCAL_ARCHIVE,
            "a front end matches on the code, not on the sentence"
        );
        let write = s.engine_mut().err().expect("no archive");
        assert_eq!(write.code, NO_LOCAL_ARCHIVE);
    }

    #[test]
    fn a_local_session_carries_the_engines_zone() {
        let dir = std::env::temp_dir().join(format!("tokenstat-session-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let db = dir.join("archive.db");
        let s = Session::open_local(&OpenParams {
            db_path: Some(db.display().to_string()),
            timezone: Some("UTC".to_string()),
        })
        .expect("local session");
        assert!(s.has_archive());
        assert_eq!(s.timezone().iana_name(), Some("UTC"));
        assert_eq!(
            s.engine().expect("archive").timezone().iana_name(),
            s.timezone().iana_name(),
            "one zone, not two that can drift"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
