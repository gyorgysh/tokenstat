// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Core types and logic for tokenstat.
//!
//! Parsing, normalization, pricing, and aggregation live here so that the CLI,
//! the desktop app, and any future sync agent share one implementation.
//!
//! # Privacy
//!
//! This crate has no network dependency, directly or transitively, and must
//! never gain one. That is the mechanism behind the product's central claim:
//! the code that reads your session logs has no way to send them anywhere.
//! Anything that makes a request belongs in `tokenstat-sync`.
//!
//! Conversation text is dropped at the parser boundary. Only counters and
//! identifiers reach the store, so the local database holds numbers rather than
//! transcripts.

#![forbid(unsafe_code)]

pub mod budget;
pub mod catalog;
pub mod engine;
pub mod error;
pub mod model;
pub mod pricing;
pub mod scan;
pub mod sources;
pub mod store;
pub mod sync_payload;
pub mod watermark;

pub use budget::{BudgetLimits, BudgetStatus, list_value, status as budget_status};
pub use catalog::{
    CanonicalOffer, Catalog, CatalogModel, CheapestOffer, Plan, PlanLimit, PlanModel, Plans, Scores,
};
pub use engine::Engine;
pub use error::{CoreError, Warning};
pub use model::{
    BillingMode, Confidence, Counters, Cumulative, Delta, EventId, Extras, SourceId, Timestamp,
    UsageEvent,
};
pub use pricing::{
    Charged, EquivalentValue, EstimateSource, PriceTable, Rates, display_usage_model_id,
};
pub use scan::{ScanReport, reconcile, scan};
pub use sources::claude_stats::Reconciliation;
pub use store::{BLOCK_DURATION_MS, Bucket, EventRow, GroupBy, Query, Store, Totals, UsageBlock};
pub use sync_payload::{
    ALLOWED_SYNC_KEYS, FORBIDDEN_SYNC_KEYS, SYNC_SCHEMA_VERSION, SYNC_WINDOW_MAX_DAYS,
    SyncBuildArgs, SyncPayload, SyncRollupBucket, SyncRow, SyncTotals, SyncWindow,
    build_sync_payload, choose_schema_v, default_sync_window, is_valid_machine_id,
    is_valid_project_key, is_valid_salt_id, parse_window_arg, project_key,
};
pub use watermark::{Change, Watermark};

/// Version of the crate, taken from the workspace manifest.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Resolve a timezone name, falling back to the system zone.
pub fn timezone(name: Option<&str>) -> Result<jiff::tz::TimeZone, CoreError> {
    match name {
        Some(n) => {
            jiff::tz::TimeZone::get(n).map_err(|_| CoreError::UnknownTimezone(n.to_string()))
        }
        None => Ok(jiff::tz::TimeZone::system()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_populated() {
        assert!(!VERSION.is_empty());
    }

    #[test]
    fn unknown_timezone_is_an_error_not_a_silent_fallback() {
        assert!(timezone(Some("Mars/Olympus")).is_err());
        assert!(timezone(Some("UTC")).is_ok());
    }
}
