//! The wire contract between the core and any front end.
//!
//! These types are deliberately separate from the core's own types. The core is
//! free to refactor; this shape is a published interface that a shipped app
//! binary may still be speaking. Field names are camelCase because the first
//! consumer is Swift `Codable`.
//!
//! Money is carried as micros of a dollar, never as a float, and never as a
//! preformatted string. Formatting is the front end's job and depends on the
//! user's locale.

use serde::{Deserialize, Serialize};
use tokenstat_core::{
    Counters, GroupBy, PricedBucket, Query, ScanReport, Totals, UsageBlock, Warning,
};

/// Filters accepted by every reporting method.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QueryDto {
    /// Inclusive local date, `YYYY-MM-DD`.
    pub since: Option<String>,
    /// Inclusive local date, `YYYY-MM-DD`.
    pub until: Option<String>,
    pub model: Option<String>,
    pub project: Option<String>,
}

impl From<QueryDto> for Query {
    fn from(q: QueryDto) -> Query {
        Query {
            since: q.since,
            until: q.until,
            model: q.model,
            project: q.project,
        }
    }
}

/// How to group a report. Mirrors [`GroupBy`].
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GroupByDto {
    Day,
    Week,
    Model,
    Project,
    Source,
    Session,
}

impl From<GroupByDto> for GroupBy {
    fn from(g: GroupByDto) -> GroupBy {
        match g {
            GroupByDto::Day => GroupBy::Day,
            GroupByDto::Week => GroupBy::Week,
            GroupByDto::Model => GroupBy::Model,
            GroupByDto::Project => GroupBy::Project,
            GroupByDto::Source => GroupBy::Source,
            GroupByDto::Session => GroupBy::Session,
        }
    }
}

/// Token counters.
///
/// Every field is optional because "this tool does not report cache writes" and
/// "this tool reported zero cache writes" are different facts, and collapsing
/// them into `0` is the one reporting mistake the product must never make.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CountersDto {
    pub input_fresh: Option<u64>,
    pub cache_read: Option<u64>,
    pub cache_write_5m: Option<u64>,
    pub cache_write_1h: Option<u64>,
    pub output: Option<u64>,
    /// Sum of every known field. Present so front ends do not each reimplement
    /// the rule about which counters are additive.
    pub total: u64,
    /// Input side only, cache included.
    pub input_total: u64,
    /// True when at least one counter was unknown rather than zero.
    pub has_unknown: bool,
}

impl From<&Counters> for CountersDto {
    fn from(c: &Counters) -> CountersDto {
        CountersDto {
            input_fresh: c.input_fresh,
            cache_read: c.cache_read,
            cache_write_5m: c.cache_write_5m,
            cache_write_1h: c.cache_write_1h,
            output: c.output,
            total: c.total(),
            input_total: c.input_total(),
            has_unknown: c.has_unknown(),
        }
    }
}

/// One report row with its list-rate value.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BucketDto {
    pub key: String,
    pub counters: CountersDto,
    pub events: u64,
    pub sessions: u64,
    /// List-rate value in micros of a dollar. Never a charge: subscription
    /// usage is valued the same way, so a front end must not label this as
    /// money billed.
    pub value_micros: i64,
    /// At least one model here was valued from an estimate. Render with a
    /// qualifier, the CLI uses `~`.
    pub estimated: bool,
    /// Models nothing could price. Non-empty means `valueMicros` is a floor.
    pub unpriced_models: Vec<String>,
}

impl From<PricedBucket> for BucketDto {
    fn from(b: PricedBucket) -> BucketDto {
        BucketDto {
            key: b.key,
            counters: CountersDto::from(&b.counters),
            events: b.events,
            sessions: b.sessions,
            value_micros: b.value.micros(),
            estimated: b.estimated,
            unpriced_models: b.unpriced_models,
        }
    }
}

/// Archive-wide totals for the current filter.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TotalsDto {
    pub counters: CountersDto,
    pub events: u64,
    pub sessions: u64,
    pub days: u64,
    pub first_date: Option<String>,
    pub last_date: Option<String>,
}

impl From<Totals> for TotalsDto {
    fn from(t: Totals) -> TotalsDto {
        TotalsDto {
            counters: CountersDto::from(&t.counters),
            events: t.events,
            sessions: t.sessions,
            days: t.days,
            first_date: t.first_date,
            last_date: t.last_date,
        }
    }
}

/// One five hour usage block.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockDto {
    pub start_ms: i64,
    pub end_ms: i64,
    pub counters: CountersDto,
    pub events: u64,
    pub sessions: u64,
    pub active: bool,
}

impl From<UsageBlock> for BlockDto {
    fn from(b: UsageBlock) -> BlockDto {
        BlockDto {
            start_ms: b.start_ms,
            end_ms: b.end_ms,
            counters: CountersDto::from(&b.counters),
            events: b.events,
            sessions: b.sessions,
            active: b.active,
        }
    }
}

/// Outcome of a scan.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanReportDto {
    pub files_found: u64,
    pub files_read: u64,
    pub rows_seen: u64,
    pub events_new: u64,
    pub events_recovered: u64,
    pub days_recovered: u64,
    pub elapsed_ms: u64,
    /// Rendered warnings. A parser that meets a line it does not understand
    /// records one of these and carries on, so a non-empty list is normal and
    /// not a failure.
    pub warnings: Vec<String>,
}

impl From<ScanReport> for ScanReportDto {
    fn from(r: ScanReport) -> ScanReportDto {
        ScanReportDto {
            files_found: r.files_found,
            files_read: r.files_read,
            rows_seen: r.rows_seen,
            events_new: r.events_new,
            events_recovered: r.events_recovered,
            days_recovered: r.days_recovered,
            // u128 does not survive JSON. A scan measured in milliseconds has
            // no business overflowing u64.
            elapsed_ms: r.elapsed_ms.min(u64::MAX as u128) as u64,
            warnings: r.warnings.iter().map(Warning::to_string).collect(),
        }
    }
}

/// Static facts a front end needs once at launch.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InfoDto {
    pub protocol_version: String,
    pub core_version: String,
    pub db_path: String,
    pub timezone: String,
    /// Date the loaded price book took effect, empty when no book is present.
    pub price_book_effective_from: String,
    /// False when no price book has been fetched yet, which means every value
    /// in every report will be zero for a reason the user can fix.
    pub has_prices: bool,
}
