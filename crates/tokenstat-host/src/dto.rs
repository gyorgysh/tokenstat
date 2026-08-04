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
    BillingMode, Counters, GroupBy, PricedBucket, Query, ScanReport, SplitBucket, Totals,
    UsageBlock, Warning,
};
use tokenstat_sync::DeviceLogin as SyncDeviceLogin;

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
    pub billing: Option<BillingMode>,
}

impl From<QueryDto> for Query {
    fn from(q: QueryDto) -> Query {
        Query {
            since: q.since,
            until: q.until,
            model: q.model,
            project: q.project,
            billing: q.billing,
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

/// A device authorization the user has not confirmed yet.
///
/// The device code itself is deliberately absent. It is the secret half of the
/// grant, the front end has no use for it, and the bridge holds the pending
/// login so polling needs no arguments.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceLoginDto {
    pub host: String,
    /// Short code the user reads off the screen.
    pub user_code: String,
    /// Where to send the user. Already pre-filled with the code when the server
    /// offers that form, so most people never type it.
    pub open_url: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}

impl From<&SyncDeviceLogin> for DeviceLoginDto {
    fn from(d: &SyncDeviceLogin) -> DeviceLoginDto {
        DeviceLoginDto {
            host: d.host.clone(),
            user_code: d.user_code.clone(),
            open_url: d.open_url().to_string(),
            verification_uri: d.verification_uri.clone(),
            expires_in: d.expires_in,
            interval: d.interval,
        }
    }
}

/// Result of one poll. `state` is `pending` or `confirmed`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DevicePollDto {
    pub state: &'static str,
    /// Seconds to wait before polling again. Only meaningful while pending, and
    /// the server may raise it, so use this rather than the original interval.
    pub interval: Option<u64>,
    pub handle: Option<String>,
    pub host: Option<String>,
    pub machine: Option<String>,
}

/// Who is signed in, and what the server knows about this account.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountDto {
    /// False when there is no token for this host. Everything below is then
    /// absent, and the caller should offer sign-in rather than an error.
    pub signed_in: bool,
    pub host: String,
    pub handle: Option<String>,
    pub tier: Option<String>,
    /// Profile picture URL, when the account has one. Fetched by the front end
    /// rather than here: this crate has no business downloading images, and a
    /// slow avatar host must not hold up the account call.
    pub avatar: Option<String>,
    pub last_sync_at: Option<String>,
    pub machines: Vec<MachineDto>,
    pub schema_current: Option<u32>,
}

/// Outcome of a sync.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncResultDto {
    pub host: String,
    pub rows: u64,
    pub dry_run: bool,
    pub schema_v: u32,
    /// Window actually sent, mirroring the payload's own `from`/`to`.
    pub from: String,
    pub to: String,
}

/// One machine on the account.
///
/// Normalized rather than passed through. The server speaks snake_case and may
/// add fields; this contract is camelCase and stable, and translating here is
/// the whole reason the DTO layer exists. Every field is optional so an
/// unfamiliar record still renders instead of failing the account decode.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineDto {
    pub id: Option<String>,
    pub label: Option<String>,
    pub last_sync_at: Option<String>,
}

impl MachineDto {
    /// Read one server record. Anything that is not an object becomes an empty
    /// machine rather than an error: one odd row must not cost the user the
    /// whole list.
    pub fn from_value(v: &serde_json::Value) -> MachineDto {
        let field = |k: &str| v.get(k).and_then(|x| x.as_str()).map(str::to_string);
        MachineDto {
            id: field("id"),
            label: field("label"),
            last_sync_at: field("last_sync_at"),
        }
    }
}

/// One row of a two-level report: a key, and one slice of it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitBucketDto {
    pub key: String,
    /// Value of the second dimension, for example the harness that ran in a
    /// project.
    pub split: String,
    pub counters: CountersDto,
    pub events: u64,
    pub sessions: u64,
}

impl From<SplitBucket> for SplitBucketDto {
    fn from(b: SplitBucket) -> SplitBucketDto {
        SplitBucketDto {
            key: b.key,
            split: b.split,
            counters: CountersDto::from(&b.counters),
            events: b.events,
            sessions: b.sessions,
        }
    }
}

/// A registered folder, with whatever git says about it.
///
/// Workspaces are chosen by the user, never inferred from the usage archive.
/// The archive's `project` is a display label recovered from a slug that lost
/// the difference between `/` and `-`, so it cannot name a folder on disk, and
/// a folder an agent touched once is not somewhere anyone wants a terminal.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceDto {
    pub id: String,
    pub path: String,
    pub name: String,
    pub added_at_ms: i64,
    /// False when the folder is gone. Kept and marked rather than dropped: an
    /// unplugged disk is not a decision to forget it.
    pub exists: bool,
    /// Absent when the folder is missing, so a caller cannot mistake "we did
    /// not look" for "no changes".
    pub git: Option<tokenstat_workspace::GitStatus>,
}

/// The activity calendar, flattened for a front end that draws its own grid.
///
/// The rows are sent as they are computed, seven of them, Monday first, with
/// `null` for a day outside the range. A client must not rebuild the grid from
/// the day list: the calendar's whole point is that a column is a real week and
/// a row a real weekday, and packing active days back to back silently shifts
/// every later column.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarDto {
    pub rows: Vec<Vec<Option<HeatCellDto>>>,
    /// `(column, short month name)` for a header strip.
    pub months: Vec<MonthLabelDto>,
    pub weeks: usize,
    pub total: u64,
    pub active_days: usize,
    /// Consecutive active days ending on the most recent day with data. A quiet
    /// day that has not finished yet does not break it.
    pub streak_current: usize,
    pub streak_best: usize,
    pub busiest: Option<HeatCellDto>,
    pub first: String,
    pub last: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeatCellDto {
    /// `YYYY-MM-DD`, so a client formats it in its own locale.
    pub date: String,
    pub value: u64,
    /// `0..=4`. Zero is a day inside the range with no usage, which reads as
    /// "nothing happened" and not as "no data".
    pub level: u8,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MonthLabelDto {
    pub column: usize,
    pub name: String,
}

impl From<&tokenstat_core::activity::HeatCell> for HeatCellDto {
    fn from(c: &tokenstat_core::activity::HeatCell) -> HeatCellDto {
        HeatCellDto {
            date: c.date.to_string(),
            value: c.value,
            level: c.level,
        }
    }
}

impl From<tokenstat_core::activity::HeatCalendar> for CalendarDto {
    fn from(c: tokenstat_core::activity::HeatCalendar) -> CalendarDto {
        CalendarDto {
            rows: c
                .rows
                .iter()
                .map(|row| {
                    row.iter()
                        .map(|c| c.as_ref().map(HeatCellDto::from))
                        .collect()
                })
                .collect(),
            months: c
                .months
                .iter()
                .map(|(column, name)| MonthLabelDto {
                    column: *column,
                    name: (*name).to_string(),
                })
                .collect(),
            weeks: c.weeks,
            total: c.total,
            active_days: c.active_days,
            streak_current: c.streak_current,
            streak_best: c.streak_best,
            busiest: c.busiest.as_ref().map(HeatCellDto::from),
            first: c.first.to_string(),
            last: c.last.to_string(),
        }
    }
}
