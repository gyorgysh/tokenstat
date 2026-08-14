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
    BillingMode, Counters, DayPart, GroupBy, PricedBucket, Query, ScanReport, SplitBucket, Totals,
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
    pub limit: Option<u32>,
}

impl From<QueryDto> for Query {
    fn from(q: QueryDto) -> Query {
        Query {
            since: q.since,
            until: q.until,
            model: q.model,
            project: q.project,
            billing: q.billing,
            limit: q.limit,
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
    /// Where this machine's archive is, and `null` on a build that keeps none.
    ///
    /// Null rather than an empty string: a client has no archive, which is a
    /// different fact from an archive at a path nobody set, and a front end
    /// that showed "" as a location would be inventing one.
    pub db_path: Option<String>,
    /// Whether this host can answer questions about its own machine's logs.
    ///
    /// The one flag a front end needs to decide whether to offer local reports
    /// at all, instead of offering them and rendering the refusal.
    pub has_archive: bool,
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
    /// The name the user chose to be shown as, when they set one. The handle is
    /// the identifier and this is the label, and a UI that shows only the
    /// handle is showing a slug where a name belongs.
    pub display_name: Option<String>,
    pub tier: Option<String>,
    /// Profile picture URL, when the account has one. Fetched by the front end
    /// rather than here: this crate has no business downloading images, and a
    /// slow avatar host must not hold up the account call.
    ///
    /// **The API does not send this yet.** `/api/v1/me` currently returns
    /// `display_name`, `handle`, `machines`, `profile_public`, `schema`, `sync`
    /// and `tier`, so this is always `None` and the front ends draw a monogram.
    /// The key is read rather than removed because the field belongs to the
    /// account and the website is a separate project.
    pub avatar: Option<String>,
    pub last_sync_at: Option<String>,
    /// The id of the machine this process is running on, so a client can mark
    /// which row in `machines` is the one in front of the user.
    pub this_machine_id: Option<String>,
    pub machines: Vec<MachineDto>,
    pub schema_current: Option<u32>,
    /// How many devices this plan may link. A computer, phone, or tablet each uses one.
    pub machine_limit: Option<u32>,
    pub hosts_linked: Option<u32>,
    /// Whether the relay will accept a HELLO from this account.
    pub can_remote: Option<bool>,
    /// Minimum seconds between accepted syncs from one host.
    pub sync_interval: Option<u32>,
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
    /// Presence and trust are optional because older account APIs omit them.
    /// Keeping them in the normalized DTO lets newer servers power the
    /// Machines screen without breaking older profiles.
    pub online: Option<bool>,
    pub last_seen_at: Option<String>,
    pub public_identity: Option<String>,
    pub trust_state: Option<String>,
    /// `"host"` uploads usage; `"client"` is a phone (P5). Missing means host.
    pub kind: Option<String>,
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
            online: v.get("online").and_then(|x| x.as_bool()),
            last_seen_at: field("last_seen_at").or_else(|| field("last_seen")),
            public_identity: field("public_identity").or_else(|| field("identity")),
            trust_state: field("trust_state").or_else(|| field("trust")),
            kind: field("kind"),
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
/// A registered folder. Local only: a client has no folders of its own, and
/// another machine's folders arrive already described.
#[cfg(feature = "local-host")]
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
    /// Which grid this actually is: `"local"` or `"account"`.
    ///
    /// Asked for and got are not the same thing. An account grid that could not
    /// be fetched falls back to the local one, and a client that drew it as the
    /// account's would be reporting one machine's spend as everybody's.
    #[serde(default = "local_scope")]
    pub scope: String,
    /// Why the answer is not what was asked for, in words a person reads.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
    /// What kind of fallback this is, so a front end can act on it rather
    /// than parse the sentence: `"auth"` (a sign-in would fix it), `"upgrade"`
    /// (the account does not include it), `"stale"` (this is a remembered
    /// answer, the refresh failed), `"other"`. Absent when the grid is the one
    /// asked for.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notice_code: Option<String>,
    /// When an account grid's numbers came off the service, in unix
    /// milliseconds. Absent on a local grid, which is read from disk every time
    /// and is never a remembered answer.
    ///
    /// Sent as a moment rather than as a sentence so the front end can phrase
    /// the age in the user's own locale, and so "3 minutes ago" does not go on
    /// growing stale inside a string.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fetched_at_ms: Option<i64>,
    /// First unlocked day (`YYYY-MM-DD`). Days before this keep the year
    /// shape only. Absent when the whole grid is live.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unlock_from: Option<String>,
    /// The grid is a year with a locked past, the public profile's Free
    /// treatment. A client draws muted cells rather than shrinking to a month.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub history_locked: bool,
    /// How many recent days stay exact. The banner names this number.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history_days: Option<u16>,
    /// The signed-in owner should be offered an upgrade. Public pages mute
    /// older days without pitching. The app is always the owner.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub history_upgrade: bool,
}

fn local_scope() -> String {
    "local".into()
}

/// An account-plane breakdown, and how current it is.
///
/// The date rides with the rows for the same reason it rides with the calendar:
/// a figure and its age are one fact, and a client that could fetch the rows
/// without the date would eventually draw them without it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountReportDto {
    pub rows: Vec<BucketDto>,
    /// Which dimension these are folded by, echoed back so a late answer that
    /// arrives after the reader switched tabs can be discarded.
    pub group: String,
    pub fetched_at_ms: i64,
    /// These are remembered numbers, served because the refresh failed.
    pub stale: bool,
}

/// What one machine on the account contributed over a window.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineUsageDto {
    /// The account's machine id, which is what the caller matches rows to
    /// devices by.
    pub machine: String,
    /// List rates, never a charge. Same rule as everywhere else.
    pub value_micros: i64,
    pub events: u64,
    pub active_days: usize,
    /// The window this covers, in days, so the front end can label it rather
    /// than assume one.
    pub days: u16,
}

/// One day's hover detail: the totals line plus every `model × source` row.
///
/// The shape the public profile page draws on hover. A client shows the
/// totals, the first rows, a "+N more" line when the list is longer, and the
/// input/output/cache split the counters add up to.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DayDetailDto {
    /// `YYYY-MM-DD`, echoed so a client does not have to hold it.
    pub date: String,
    pub tokens: u64,
    pub events: u64,
    /// List-rate value in micros, matching the heatmap cell's own unit.
    pub value_micros: i64,
    pub estimated: bool,
    /// Models nothing could price. Non-empty means `value_micros` is a floor.
    pub unpriced_models: Vec<String>,
    pub rows: Vec<DayPartDto>,
}

/// One `model × source` slice of a day.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DayPartDto {
    pub model: String,
    /// The harness that recorded the events, e.g. `"codex"` or `"claude_code"`.
    pub src: String,
    pub fresh: Option<u64>,
    pub cache_read: Option<u64>,
    pub cache_write_5m: Option<u64>,
    pub cache_write_1h: Option<u64>,
    pub output: Option<u64>,
    /// Sum of every known counter field.
    pub tokens: u64,
    pub events: u64,
}

impl From<&DayPart> for DayPartDto {
    fn from(p: &DayPart) -> DayPartDto {
        DayPartDto {
            model: p.model.clone(),
            src: p.source.clone(),
            fresh: p.counters.input_fresh,
            cache_read: p.counters.cache_read,
            cache_write_5m: p.counters.cache_write_5m,
            cache_write_1h: p.counters.cache_write_1h,
            output: p.counters.output,
            tokens: p.counters.total(),
            events: p.events,
        }
    }
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
    /// Older than the plan's unlocked window. Shade may remain. Value is
    /// zero. A missing field is not locked, so an older host stays drawable.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub locked: bool,
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
            locked: c.locked,
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
            scope: local_scope(),
            notice: None,
            notice_code: None,
            fetched_at_ms: None,
            unlock_from: None,
            history_locked: false,
            history_days: None,
            history_upgrade: false,
        }
    }
}

impl CalendarDto {
    /// Say which grid this is, and why if it is not the one asked for.
    pub fn scoped(
        mut self,
        scope: &str,
        notice: Option<String>,
        notice_code: Option<&str>,
    ) -> CalendarDto {
        self.scope = scope.to_string();
        self.notice = notice;
        self.notice_code = notice_code.map(str::to_string);
        self
    }

    /// Date the account's numbers, so a client can say how old they are.
    pub fn fetched_at(mut self, at_ms: i64) -> CalendarDto {
        self.fetched_at_ms = (at_ms > 0).then_some(at_ms);
        self
    }

    /// Mark a Free year: older days stay as shape, the recent window is live.
    pub fn history_lock(mut self, unlock_from: String, history_days: u16) -> CalendarDto {
        self.unlock_from = Some(unlock_from);
        self.history_locked = true;
        self.history_days = Some(history_days);
        // The app is the owner looking at their own grid.
        self.history_upgrade = true;
        self
    }
}
