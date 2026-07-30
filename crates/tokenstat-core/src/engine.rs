//! Shared front-end facade over the local archive.
//!
//! CLI, MCP, and (later) GUI should open an [`Engine`] rather than constructing
//! a [`Store`] and timezone by hand. Keeps path and zone resolution in one place.

use std::path::{Path, PathBuf};

use crate::error::CoreError;
use crate::store::{Bucket, GroupBy, Query, Store, Totals, UsageBlock};
use crate::{ScanReport, timezone};

/// Open handle to the local archive plus the timezone used for bucketing.
pub struct Engine {
    store: Store,
    tz: jiff::tz::TimeZone,
    db_path: PathBuf,
}

impl Engine {
    /// Open the archive at `db`, or the platform default under the tokenstat
    /// data directory when `db` is `None`.
    pub fn open(db: Option<&Path>, tz_name: Option<&str>) -> Result<Self, CoreError> {
        let db_path = match db {
            Some(p) => p.to_path_buf(),
            None => Store::default_path()?,
        };
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| CoreError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let store = Store::open(&db_path)?;
        let tz = timezone(tz_name)?;
        Ok(Self { store, tz, db_path })
    }

    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    pub fn timezone(&self) -> &jiff::tz::TimeZone {
        &self.tz
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut Store {
        &mut self.store
    }

    pub fn totals(&self, q: &Query) -> Result<Totals, CoreError> {
        self.store.totals(q)
    }

    pub fn report(&self, group: GroupBy, q: &Query) -> Result<Vec<Bucket>, CoreError> {
        self.store.report(group, q)
    }

    pub fn blocks(&self, q: &Query) -> Result<Vec<UsageBlock>, CoreError> {
        let now_ms = jiff::Timestamp::now().as_millisecond();
        self.store.blocks(q, now_ms)
    }

    pub fn scan(&mut self) -> Result<ScanReport, CoreError> {
        crate::scan(&mut self.store, &self.tz)
    }
}
