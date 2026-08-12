//! Error and warning types.
//!
//! A parser meeting an unfamiliar line records a [`Warning`] and keeps going.
//! Aborting a scan because one vendor shipped a schema change would make the
//! tool useless exactly when it is most needed.

use std::path::PathBuf;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("could not read {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),

    #[error("could not determine the tokenstat data directory")]
    NoDataDir,

    #[error("unknown timezone: {0}")]
    UnknownTimezone(String),

    #[error("invalid budget: {0}")]
    InvalidBudget(String),

    #[error("json ({context}): {source}")]
    Json {
        context: String,
        #[source]
        source: serde_json::Error,
    },

    #[error("invalid machine id (want m_ + 16 hex): {0}")]
    InvalidMachineId(String),

    #[error("invalid salt id (want s_ + 8 hex): {0}")]
    InvalidSaltId(String),

    #[error("invalid project key (want p_ + 24 hex): {0}")]
    InvalidProjectKey(String),

    #[error("invalid sync window {from}..{to}")]
    InvalidSyncWindow { from: String, to: String },

    #[error("sync totals do not match row sums")]
    SyncTotalsMismatch,

    #[error("duplicate sync row for {d}/{src}/{model}/{proj}")]
    DuplicateSyncRow {
        d: String,
        src: String,
        model: String,
        proj: String,
    },

    #[error("unsupported sync schema version {0}")]
    UnsupportedSyncSchema(u32),

    #[error("CLI sync schema is outside server range [{min_v}, {max_v}]")]
    UnsupportedSyncSchemaRange { min_v: u32, max_v: u32 },

    #[error("sync {field} value {value:?} is not in the server allowlist")]
    UnsupportedSyncEnum { field: String, value: String },

    #[error("forbidden sync field: {0}")]
    ForbiddenSyncField(String),
}

impl CoreError {
    /// True when SQLite refused the call because another connection holds a lock.
    ///
    /// Scheduled jobs treat this as "try again next tick" rather than a hard
    /// failure: a scan can hold a write transaction longer than a sync wants to wait.
    pub fn is_busy(&self) -> bool {
        match self {
            CoreError::Db(err) => matches!(
                err.sqlite_error_code(),
                Some(rusqlite::ErrorCode::DatabaseBusy) | Some(rusqlite::ErrorCode::DatabaseLocked)
            ),
            _ => false,
        }
    }
}

/// A non-fatal problem worth telling the user about, surfaced by `doctor`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Warning {
    /// A line did not parse as JSON.
    MalformedLine { path: PathBuf, line: usize },
    /// A record looked like usage but lacked a field needed to identify it.
    MissingIdentity { path: PathBuf, line: usize },
    /// A directory a source expected was absent. Normal when a tool is not
    /// installed, so this is informational rather than an error.
    SourceNotInstalled { source: &'static str },
    /// A file could not be opened.
    Unreadable { path: PathBuf, reason: String },
    /// Per-request deltas did not add up to the running total the same file
    /// reports, so one of the two is wrong.
    DeltaMismatch {
        path: PathBuf,
        summed: u64,
        reported: u64,
    },
    /// `usage.iterations` did not restate the top-level counters as expected.
    /// Worth knowing about, because it would mean the vendor changed what the
    /// correct arithmetic is.
    IterationMismatch { path: PathBuf, line: usize },
    /// The tool is installed (or commonly used) but keeps usage on its servers.
    /// Reporting zero would look like "no usage", so say so instead.
    UsageNotOnDisk { source: &'static str },
    /// Recovering history from a vendor rollup derived more of some bucket than
    /// the vendor says that model ever produced, so the file is not being read
    /// the way it is written and nothing was recovered for it.
    ///
    /// This is the guard that would have caught reading Claude Code's per-day
    /// totals as input plus output: it derived 9.7 billion output tokens
    /// against a lifetime figure of 90 million, in the same file.
    RecoveryImplausible {
        source: &'static str,
        model: String,
        bucket: &'static str,
        derived: u64,
        lifetime: u64,
    },
}

impl std::fmt::Display for Warning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Warning::MalformedLine { path, line } => {
                write!(f, "{}:{line}: line is not valid JSON", path.display())
            }
            Warning::MissingIdentity { path, line } => {
                write!(
                    f,
                    "{}:{line}: usage record has no usable identity",
                    path.display()
                )
            }
            Warning::SourceNotInstalled { source } => {
                write!(f, "{source}: no data directory found, tool not installed")
            }
            Warning::Unreadable { path, reason } => {
                write!(f, "{}: {reason}", path.display())
            }
            Warning::DeltaMismatch {
                path,
                summed,
                reported,
            } => write!(
                f,
                "{}: per-request deltas sum to {summed} but the file reports {reported}",
                path.display()
            ),
            Warning::IterationMismatch { path, line } => write!(
                f,
                "{}:{line}: usage.iterations does not match the top-level counters",
                path.display()
            ),
            Warning::UsageNotOnDisk { source } => write!(
                f,
                "{source}: usage is not stored on disk, needs an explicit login later"
            ),
            Warning::RecoveryImplausible {
                source,
                model,
                bucket,
                derived,
                lifetime,
            } => write!(
                f,
                "{source}: recovering {model} derived {derived} {bucket} tokens against a \
                 lifetime total of {lifetime} in the same file, so nothing was recovered for it"
            ),
        }
    }
}
