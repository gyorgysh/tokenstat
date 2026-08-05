//! One open archive, plus whatever state a conversation needs.
//!
//! Deliberately a plain struct with no global. The C ABI keeps one in a static,
//! the socket server keeps one behind its own lock, and a test makes as many as
//! it likes. That last one matters: while the session was a process-wide
//! singleton, every test that touched it had to take a lock and run serially.

use serde::Deserialize;
use tokenstat_core::{Engine, PriceTable};

/// How to open an archive.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OpenParams {
    /// Override the archive location. Omit for the platform default.
    pub db_path: Option<String>,
    /// IANA name. Omit for the system zone.
    pub timezone: Option<String>,
}

/// Open archive, cached price book, and any sign-in in flight.
///
/// Opening means opening SQLite and resolving the timezone, far too expensive
/// to repeat per call from a UI that reports on scroll. The price book is
/// cached for the same reason: the interactive CLI was re-reading it every
/// frame before that was fixed, and a GUI would make the same mistake more
/// often.
/// The registered folders are deliberately **not** here. They live in
/// `crate::workspaces`, behind their own lock, because a folder method reads
/// git rather than the archive and must not queue behind a scan. See that
/// module for why.
pub struct Session {
    pub engine: Engine,
    pub prices: PriceTable,
    /// Device authorization awaiting confirmation.
    ///
    /// Held here rather than returned to the caller because it carries the
    /// secret half of the grant. A front end sees only the short user code it
    /// displays, and polls with no arguments.
    pub pending_login: Option<tokenstat_sync::DeviceLogin>,
}

impl Session {
    pub fn open(p: &OpenParams) -> Result<Session, String> {
        let path = p.db_path.as_ref().map(std::path::PathBuf::from);
        let engine =
            Engine::open(path.as_deref(), p.timezone.as_deref()).map_err(|e| e.to_string())?;
        Ok(Session {
            engine,
            prices: PriceTable::load_with_catalog(),
            pending_login: None,
        })
    }

    /// Open against the platform default archive and the system timezone.
    pub fn open_default() -> Result<Session, String> {
        Session::open(&OpenParams::default())
    }
}
