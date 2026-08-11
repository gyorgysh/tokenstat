// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! The account's activity grid, across every machine that syncs.
//!
//! The local archive is one machine's logs, which is the whole design: the
//! parser reads what is on this disk. "What did I spend everywhere" is a
//! different question, and the only place that knows is the account the
//! machines already upload to.
//!
//! What comes back is token counts at day × source × model. Pricing happens
//! here, against the same local price book the local grid uses, so the two
//! figures are computed the same way and can be compared. The service never
//! prices anything, which is why it can hold aggregate counts and stay a place
//! that holds no money.
//!
//! Cached, because this is drawn on the screen that opens first and a window
//! that dials out on every visit is a window that dials out constantly.

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use tokenstat_core::activity::{self, HeatCalendar};
use tokenstat_core::model::Counters;
use tokenstat_core::pricing::{EquivalentValue, PriceTable};
use tokenstat_core::store::DayPart;
use tokenstat_sync::profile::{self, SeriesRow};

/// How long a fetched series stays good.
///
/// Sync itself runs hourly at its fastest, so a grid younger than this cannot
/// be missing anything the account knows. Long enough that moving between
/// screens is free, short enough that a machine that just synced shows up
/// while somebody is still looking.
const FRESH_FOR: Duration = Duration::from_secs(10 * 60);

/// How long to wait before asking again after a failure.
///
/// Being signed out is a failure that does not fix itself, and retrying it on
/// every redraw is how a client earns a rate limit. The service allows sixty
/// reads a minute; this keeps us nowhere near it even when everything is
/// broken.
const RETRY_AFTER: Duration = Duration::from_secs(60);

/// Why the account grid could not be built.
///
/// `expected` separates "you do not have this" from "it went wrong". Not being
/// signed in, and the read API being a paid feature, are both settled facts
/// about the account rather than faults, and repeating either of them on the
/// screen that opens first is nagging. The caller falls back either way, but
/// only says why when there is something to say.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureReason {
    /// Not signed in, or the token was rejected. The fix is a sign-in, and a
    /// front end can offer one instead of quoting a CLI command.
    Authentication,
    /// The account exists but does not include this route.
    UpgradeRequired,
    /// Anything else: network, server, cache.
    Other,
}

pub struct FetchError {
    pub message: String,
    pub reason: FailureReason,
    pub expected: bool,
}

impl FetchError {
    fn new(message: String) -> FetchError {
        let lower = message.to_lowercase();
        let authentication = lower.contains("not signed in")
            || lower.contains("not logged in")
            || lower.contains("sign in")
            || lower.contains("token missing or revoked");
        let upgrade =
            lower.contains("(402") || lower.contains("upgrade_required") || lower.contains("(403)");
        let reason = if authentication {
            FailureReason::Authentication
        } else if upgrade {
            FailureReason::UpgradeRequired
        } else {
            FailureReason::Other
        };
        let expected = authentication || upgrade;
        FetchError {
            message,
            reason,
            expected,
        }
    }
}

struct Cache {
    rows: Vec<SeriesRow>,
    /// The oldest day the service actually covered. A plan's history span, not
    /// what was asked for.
    covered_from: Option<String>,
    fetched_at: Instant,
    /// The same moment on the wall clock, which is the only one that survives
    /// the process. `Instant` has no meaning across a restart, and on a phone a
    /// restart is the normal case rather than the rare one.
    fetched_at_ms: i64,
    /// Set when the last attempt failed, so the message can be shown without
    /// asking again immediately.
    last_error: Option<(String, Instant)>,
}

fn cache() -> &'static Mutex<Option<Cache>> {
    static CACHE: OnceLock<Mutex<Option<Cache>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// Drop the cached series, so the next call goes to the service.
///
/// Called after a successful upload: the account just changed, and the figure
/// on screen is the one the user came to check.
pub fn invalidate() {
    if let Ok(mut guard) = cache().lock() {
        *guard = None;
    }
    // The per-machine answers came from the same upload. Leaving them would
    // show a device list that disagrees with the grid it sits under.
    if let Ok(mut guard) = machine_cache().lock() {
        *guard = None;
    }
    let _ = stored::remove();
}

/// The last good answer, kept on disk beside the archive.
///
/// A memory cache is close to no cache where the process dies constantly, which
/// is every mobile app and, less often, a desktop one. Without this a cold
/// launch shows an empty grid until the network answers, on the screen that
/// opens first. With it the grid is the previous answer, dated, and it is
/// replaced the moment a fetch lands.
///
/// It holds day, source, model and counts, which is what the account already
/// holds. No project keys, no paths, nothing that is not already in the reply
/// this file is a copy of.
mod stored {
    use std::path::PathBuf;

    use serde::{Deserialize, Serialize};
    use tokenstat_sync::profile::SeriesRow;

    /// Bump when the shape changes. An older file is dropped rather than
    /// migrated: it is a cache, and the fix for a stale cache is a fetch.
    const VERSION: u32 = 1;

    /// A file older than this is not worth opening on. Beyond a fortnight the
    /// grid it would draw is mostly a picture of a fortnight ago.
    const KEEP_FOR_MS: i64 = 14 * 24 * 60 * 60 * 1000;

    #[derive(Serialize, Deserialize)]
    pub(super) struct Snapshot {
        pub v: u32,
        pub fetched_at_ms: i64,
        pub covered_from: Option<String>,
        pub rows: Vec<SeriesRow>,
    }

    fn path() -> Option<PathBuf> {
        let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")?;
        Some(dirs.data_dir().join("account-series.json"))
    }

    /// Whether a file this old is still worth opening on.
    ///
    /// A clock that moved backwards makes the age negative. That reads as
    /// "unknown, use it": a wrong clock is not a reason to throw away the only
    /// answer we have.
    pub(super) fn worth_opening(fetched_at_ms: i64, now_ms: i64) -> bool {
        now_ms - fetched_at_ms <= KEEP_FOR_MS
    }

    pub(super) fn load(now_ms: i64) -> Option<Snapshot> {
        let path = path()?;
        let text = std::fs::read_to_string(path).ok()?;
        let snapshot: Snapshot = serde_json::from_str(&text).ok()?;
        if snapshot.v != VERSION {
            return None;
        }
        if !worth_opening(snapshot.fetched_at_ms, now_ms) {
            return None;
        }
        Some(snapshot)
    }

    pub(super) fn save(snapshot: &Snapshot) {
        let Some(path) = path() else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let Ok(text) = serde_json::to_string(snapshot) else {
            return;
        };
        // Written beside the target and renamed, so a process that dies
        // mid-write leaves the previous answer rather than half of a new one.
        let temp = path.with_extension("json.tmp");
        if std::fs::write(&temp, text).is_ok() {
            let _ = std::fs::rename(&temp, &path);
        }
    }

    pub(super) fn remove() -> std::io::Result<()> {
        match path() {
            Some(path) => match std::fs::remove_file(path) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                other => other,
            },
            None => Ok(()),
        }
    }
}

/// The account's grid, priced here and built by the core.
///
/// `Ok(None)` means the account has nothing in the window, which is an answer.
/// `Err` means we could not ask, which is a different answer and the caller
/// must not draw it as an empty year.
///
/// The returned `weeks` can be narrower than the `weeks` asked for. A plan's
/// history span decides how far back the service will go, and a grid drawn
/// wider than that would render days it was never sent as days on which
/// nothing happened. Narrower and honest beats wider and wrong.
pub fn calendar(
    prices: &PriceTable,
    tz: &jiff::tz::TimeZone,
    weeks: usize,
) -> Result<AccountCalendar, FetchError> {
    let today = activity::today(tz);
    let fetched = series(weeks, today)?;
    let fetched_at_ms = fetched.fetched_at_ms;
    let stale = fetched.stale;
    let rows = fetched.rows;
    let weeks = covered_weeks(weeks, today, fetched.covered_from.as_deref());

    // Priced, then folded by day. Per model rather than per day, because a
    // rate belongs to a model: summing tokens across models first and pricing
    // the total would charge every model at whichever rate came last.
    let mut by_day: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
    for row in &rows {
        let counters = Counters {
            input_fresh: Some(row.input),
            cache_read: Some(row.cr),
            cache_write_5m: Some(row.cw5),
            cache_write_1h: Some(row.cw1),
            output: Some(row.output),
        };
        // Value at list rates, for plan usage as well as metered. That is what
        // the local grid colours by, and a plan day that reads as empty here
        // and full there is the two screens disagreeing.
        let micros = EquivalentValue::price(prices, &row.model, &counters)
            .map(|v| v.micros().max(0) as u64)
            .unwrap_or(0);
        *by_day.entry(row.day.clone()).or_insert(0) += micros;
    }

    let days: Vec<(String, u64)> = by_day.into_iter().collect();
    Ok(AccountCalendar {
        calendar: activity::calendar(&days, weeks, today),
        fetched_at_ms,
        stale,
    })
}

/// The account's grid, and how current it is.
///
/// The date travels with the grid rather than being fetched separately, because
/// a figure and its age are one fact. A client that could get the grid without
/// the date would eventually draw one without it.
pub struct AccountCalendar {
    /// `None` when the account has nothing in the window. An answer, and not
    /// the same as a failure.
    pub calendar: Option<HeatCalendar>,
    pub fetched_at_ms: i64,
    /// The refresh failed and this is the remembered answer.
    pub stale: bool,
}

/// One day's `model × source` rows from the account's series, largest first.
///
/// The same cached series the calendar is built from, so a hover costs no
/// network call of its own. Pricing is the caller's job (it owns the price
/// book); this only folds the raw counters by `model × source`.
///
/// An empty list means the account has no events for that day, which is an
/// answer rather than a failure. A fetch that fails is reported as an error
/// exactly like [`calendar`], so the client can fall back or say why.
pub fn day_detail(
    date: &str,
    tz: &jiff::tz::TimeZone,
    weeks: usize,
) -> Result<Vec<DayPart>, FetchError> {
    let today = activity::today(tz);
    let fetched = series(weeks, today)?;

    let mut parts: Vec<DayPart> = Vec::new();
    let mut index: std::collections::HashMap<(String, String), usize> =
        std::collections::HashMap::new();
    for row in fetched.rows.iter().filter(|r| r.day == date) {
        let counters = Counters {
            input_fresh: Some(row.input),
            cache_read: Some(row.cr),
            cache_write_5m: Some(row.cw5),
            cache_write_1h: Some(row.cw1),
            output: Some(row.output),
        };
        let key = (row.model.clone(), row.src.clone());
        match index.get(&key) {
            Some(&i) => {
                parts[i].counters = add_counters(parts[i].counters, counters);
                parts[i].events = parts[i].events.saturating_add(row.ev);
            }
            None => {
                index.insert(key, parts.len());
                parts.push(DayPart {
                    model: row.model.clone(),
                    source: row.src.clone(),
                    counters,
                    events: row.ev,
                });
            }
        }
    }

    parts.sort_by_key(|b| std::cmp::Reverse(b.tokens()));
    Ok(parts)
}

/// Which dimension an account breakdown folds by.
///
/// Three, and deliberately not four. The account holds day, source and model,
/// because that is all the sync envelope was ever allowed to carry: a project
/// key is an opaque HMAC and a session id never leaves the machine. So a client
/// can report by model, by harness and by day, and it must not offer a Projects
/// tab that would only ever be empty.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dimension {
    Model,
    Source,
    Day,
}

impl Dimension {
    /// Parse the wire name. Unknown falls back to the model breakdown rather
    /// than failing: a newer front end asking for something this build has not
    /// got should see a report, not an error dialog.
    pub fn from_wire(name: &str) -> Dimension {
        match name {
            "source" | "harness" | "tool" => Dimension::Source,
            "day" | "date" => Dimension::Day,
            _ => Dimension::Model,
        }
    }

    fn key(self, row: &SeriesRow) -> String {
        match self {
            Dimension::Model => row.model.clone(),
            Dimension::Source => row.src.clone(),
            Dimension::Day => row.day.clone(),
        }
    }
}

/// The account's breakdown by one dimension, priced here.
pub struct AccountBreakdown {
    pub rows: Vec<tokenstat_core::engine::PricedBucket>,
    pub fetched_at_ms: i64,
    /// The refresh failed and these are remembered numbers. Same rule as the
    /// calendar: a figure with no date is a quiet claim to be current.
    pub stale: bool,
}

/// What the account spent, folded by one dimension, largest first.
///
/// The same cached series Home's grid is built from, so opening Insights on a
/// phone costs no network call of its own and cannot disagree with the heatmap
/// above it. Priced per model inside each bucket, because a rate belongs to a
/// model: summing tokens first and pricing the total would charge everything at
/// whichever rate came last.
///
/// `sessions` is zero on every row and that is not a placeholder. The account
/// never receives session identifiers, so the honest count is "we do not know",
/// and a front end must not render a zero there as a fact.
pub fn breakdown(
    prices: &PriceTable,
    tz: &jiff::tz::TimeZone,
    weeks: usize,
    dimension: Dimension,
) -> Result<AccountBreakdown, FetchError> {
    let today = activity::today(tz);
    let fetched = series(weeks, today)?;

    // Counters fold by key. Money folds by key × model, because pricing is
    // per model and the two cannot be done in one pass without charging one
    // model's tokens at another's rate.
    let mut order: Vec<String> = Vec::new();
    let mut totals: std::collections::HashMap<String, (Counters, u64)> =
        std::collections::HashMap::new();
    let mut value: std::collections::HashMap<String, (i64, bool, Vec<String>)> =
        std::collections::HashMap::new();

    for row in &fetched.rows {
        let key = dimension.key(row);
        let counters = Counters {
            input_fresh: Some(row.input),
            cache_read: Some(row.cr),
            cache_write_5m: Some(row.cw5),
            cache_write_1h: Some(row.cw1),
            output: Some(row.output),
        };
        match totals.get_mut(&key) {
            Some(entry) => {
                entry.0 = add_counters(entry.0, counters);
                entry.1 = entry.1.saturating_add(row.ev);
            }
            None => {
                order.push(key.clone());
                totals.insert(key.clone(), (counters, row.ev));
            }
        }

        let lookup = tokenstat_core::pricing::display_usage_model_id(&row.model);
        let entry = value.entry(key).or_default();
        match EquivalentValue::price(prices, &lookup, &counters) {
            Some(v) => {
                entry.0 += v.micros();
                entry.1 |= prices.is_estimate(&lookup);
            }
            None => {
                if !entry.2.contains(&lookup) {
                    entry.2.push(lookup);
                }
            }
        }
    }

    let mut rows: Vec<tokenstat_core::engine::PricedBucket> = order
        .into_iter()
        .map(|key| {
            let (counters, events) = totals.remove(&key).unwrap_or_default();
            let (micros, estimated, unpriced) = value.remove(&key).unwrap_or_default();
            tokenstat_core::engine::PricedBucket {
                key,
                counters,
                events,
                // The account holds no session ids. See the doc comment.
                sessions: 0,
                value: EquivalentValue::from_micros(micros),
                estimated,
                unpriced_models: unpriced,
            }
        })
        .collect();

    // Days read best newest first, everything else biggest first. A date list
    // sorted by size is a list nobody can scan.
    match dimension {
        Dimension::Day => rows.sort_by(|a, b| b.key.cmp(&a.key)),
        _ => rows.sort_by_key(|b| std::cmp::Reverse(b.value.micros())),
    }

    Ok(AccountBreakdown {
        rows,
        fetched_at_ms: fetched.fetched_at_ms,
        stale: fetched.stale,
    })
}

/// What one machine on the account contributed, over a window of days.
pub struct MachineUsage {
    pub machine: String,
    pub micros: i64,
    pub events: u64,
    /// Days in the window that machine recorded anything on.
    pub active_days: usize,
}

/// How long a per-machine answer stays good. The same reasoning as the series
/// cache, and it matters more here: this is one request per machine, so a
/// screen that refetched on every appearance would multiply itself.
const MACHINE_FRESH_FOR: Duration = Duration::from_secs(10 * 60);

struct MachineCache {
    days: u16,
    rows: Vec<MachineUsage>,
    fetched_at: Instant,
}

fn machine_cache() -> &'static Mutex<Option<MachineCache>> {
    static CACHE: OnceLock<Mutex<Option<MachineCache>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// What each machine contributed, so a device list can say which computer is
/// doing the work.
///
/// One request per machine, because the series endpoint answers per machine and
/// the rows it returns carry no machine of their own. That is why the window is
/// a month rather than a year by default, and why the answer is cached: this is
/// the most expensive thing the client asks for and it belongs to a screen
/// people open occasionally.
///
/// A machine that fails is left out rather than failing the whole list. Four
/// devices and a shrug about the fifth beats an error card where the devices
/// should be.
pub fn machine_usage(
    prices: &PriceTable,
    tz: &jiff::tz::TimeZone,
    machines: &[String],
    days: u16,
) -> Result<Vec<MachineUsage>, FetchError> {
    if machines.is_empty() {
        return Ok(Vec::new());
    }
    if let Ok(guard) = machine_cache().lock() {
        if let Some(c) = guard.as_ref() {
            if c.days == days
                && c.fetched_at.elapsed() < MACHINE_FRESH_FOR
                && machines
                    .iter()
                    .all(|m| c.rows.iter().any(|r| &r.machine == m))
            {
                return Ok(c
                    .rows
                    .iter()
                    .filter(|r| machines.contains(&r.machine))
                    .map(|r| MachineUsage {
                        machine: r.machine.clone(),
                        micros: r.micros,
                        events: r.events,
                        active_days: r.active_days,
                    })
                    .collect());
            }
        }
    }

    let today = activity::today(tz);
    // Inclusive of both ends, so "30 days" covers thirty of them. Asking for
    // `today - 30` returns thirty-one, and a device that reported on every one
    // of them then reads as "31 active days" under a label saying 30.
    //
    // Cap is a decade, not a month: free accounts ask for 30, supporter for a
    // year, patron for all-time, and the series endpoint already enforces the
    // account's own history depth. Clamping to 400 used to silently truncate
    // a patron year-and-change to a little over a year.
    let from = today
        .checked_add(jiff::Span::new().days(-(days.clamp(1, 3650) as i64 - 1)))
        .map_err(|e| FetchError::new(e.to_string()))?
        .to_string();
    let to = today.to_string();

    let mut out: Vec<MachineUsage> = Vec::new();
    let mut last_error: Option<String> = None;
    for machine in machines {
        match profile::account_series(None, Some(&from), Some(&to), Some(machine)) {
            Ok(result) => {
                let mut micros: i64 = 0;
                let mut events: u64 = 0;
                let mut active: std::collections::BTreeSet<String> =
                    std::collections::BTreeSet::new();
                for row in &result.rows {
                    let counters = Counters {
                        input_fresh: Some(row.input),
                        cache_read: Some(row.cr),
                        cache_write_5m: Some(row.cw5),
                        cache_write_1h: Some(row.cw1),
                        output: Some(row.output),
                    };
                    let lookup = tokenstat_core::pricing::display_usage_model_id(&row.model);
                    if let Some(v) = EquivalentValue::price(prices, &lookup, &counters) {
                        micros += v.micros();
                    }
                    events = events.saturating_add(row.ev);
                    active.insert(row.day.clone());
                }
                out.push(MachineUsage {
                    machine: machine.clone(),
                    micros,
                    events,
                    active_days: active.len(),
                });
            }
            Err(e) => last_error = Some(e.to_string()),
        }
    }

    // Every one of them failed, which is a different thing from a quiet month:
    // report it rather than drawing five devices that all spent nothing.
    if out.is_empty() {
        return Err(FetchError::new(last_error.unwrap_or_else(|| {
            "the account did not answer for any device".to_string()
        })));
    }

    if let Ok(mut guard) = machine_cache().lock() {
        *guard = Some(MachineCache {
            days,
            rows: out
                .iter()
                .map(|r| MachineUsage {
                    machine: r.machine.clone(),
                    micros: r.micros,
                    events: r.events,
                    active_days: r.active_days,
                })
                .collect(),
            fetched_at: Instant::now(),
        });
    }
    Ok(out)
}

/// Sum two counters, treating a missing field as zero.
///
/// The series rows always carry every field, so this is only needed while
/// folding them by `model × source`.
fn add_counters(a: Counters, b: Counters) -> Counters {
    Counters {
        input_fresh: Some(
            a.input_fresh
                .unwrap_or(0)
                .saturating_add(b.input_fresh.unwrap_or(0)),
        ),
        cache_read: Some(
            a.cache_read
                .unwrap_or(0)
                .saturating_add(b.cache_read.unwrap_or(0)),
        ),
        cache_write_5m: Some(
            a.cache_write_5m
                .unwrap_or(0)
                .saturating_add(b.cache_write_5m.unwrap_or(0)),
        ),
        cache_write_1h: Some(
            a.cache_write_1h
                .unwrap_or(0)
                .saturating_add(b.cache_write_1h.unwrap_or(0)),
        ),
        output: Some(a.output.unwrap_or(0).saturating_add(b.output.unwrap_or(0))),
    }
}

/// How many whole weeks the service actually covered, capped at what was asked.
fn covered_weeks(asked: usize, today: jiff::civil::Date, covered_from: Option<&str>) -> usize {
    let Some(from) = covered_from.and_then(|d| d.parse::<jiff::civil::Date>().ok()) else {
        return asked;
    };
    let days = (today - from).get_days().max(0) as usize;
    // Round down: a partial week at the far edge is a column with days in it
    // that were never covered, which is the thing this exists to prevent.
    (days / 7).clamp(1, asked)
}

pub struct Fetched {
    rows: Vec<SeriesRow>,
    covered_from: Option<String>,
    /// When these numbers came off the service, in unix milliseconds.
    pub fetched_at_ms: i64,
    /// This is a remembered answer, served because the refresh failed. The
    /// numbers are real, they are just old, and a caller must say so. Same rule
    /// as a stale limit reading: a figure with no date is a quiet claim to be
    /// current.
    pub stale: bool,
}

/// Wall clock in milliseconds, or 0 if the clock is before the epoch.
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Adopt the answer left on disk by an earlier run of this process.
///
/// Deliberately adopted as already stale: it is good enough to draw, and not
/// good enough to skip a fetch. The first call after launch therefore paints
/// immediately and refreshes behind it.
fn adopt_stored(guard: &mut Option<Cache>) {
    if guard.is_some() {
        return;
    }
    if let Some(snapshot) = stored::load(now_ms()) {
        *guard = Some(adopted(snapshot));
    }
}

/// A stored answer, entered into the cache as already past its freshness.
fn adopted(snapshot: stored::Snapshot) -> Cache {
    Cache {
        rows: snapshot.rows,
        covered_from: snapshot.covered_from,
        // `checked_sub` because a process younger than FRESH_FOR has no
        // `Instant` that far back, and saturating at "now" would make an
        // adopted answer look fresh on exactly the launches this exists for.
        // Falling back to now is still correct there, only slower: the very
        // first call refreshes rather than the second.
        fetched_at: Instant::now()
            .checked_sub(FRESH_FOR)
            .unwrap_or_else(Instant::now),
        fetched_at_ms: snapshot.fetched_at_ms,
        last_error: None,
    }
}

/// The cached series, fetched if it is stale.
fn series(weeks: usize, today: jiff::civil::Date) -> Result<Fetched, FetchError> {
    {
        let mut guard = cache()
            .lock()
            .map_err(|_| FetchError::new("the usage cache is poisoned".into()))?;
        adopt_stored(&mut guard);
        if let Some(c) = guard.as_ref() {
            if c.fetched_at.elapsed() < FRESH_FOR {
                return Ok(Fetched {
                    rows: c.rows.clone(),
                    covered_from: c.covered_from.clone(),
                    fetched_at_ms: c.fetched_at_ms,
                    stale: false,
                });
            }
            // A recent failure is reported from here rather than by dialling
            // again. Nothing about being signed out changes in a second.
            if let Some((message, at)) = &c.last_error {
                if at.elapsed() < RETRY_AFTER {
                    // Unless there is a real answer to serve. A remembered grid
                    // beats a blank one, and on a client there is no local
                    // archive to fall back to.
                    if !c.rows.is_empty() {
                        return Ok(Fetched {
                            rows: c.rows.clone(),
                            covered_from: c.covered_from.clone(),
                            fetched_at_ms: c.fetched_at_ms,
                            stale: true,
                        });
                    }
                    return Err(FetchError::new(message.clone()));
                }
            }
        }
    }

    // A whole column wider than the grid asks for, so the first partial week
    // is complete rather than starting mid-week.
    let span = (weeks.clamp(1, 53) * 7 + 7) as i64;
    let from = today
        .checked_add(jiff::Span::new().days(-span))
        .map_err(|e| FetchError::new(e.to_string()))?
        .to_string();
    let to = today.to_string();

    match profile::account_series(None, Some(&from), Some(&to), None) {
        Ok(result) => {
            let fetched_at_ms = now_ms();
            if let Ok(mut guard) = cache().lock() {
                *guard = Some(Cache {
                    rows: result.rows.clone(),
                    covered_from: result.from.clone(),
                    fetched_at: Instant::now(),
                    fetched_at_ms,
                    last_error: None,
                });
            }
            // Kept for the next cold start. Best effort on purpose: a cache
            // that cannot be written is a slower launch, not a failure, and
            // refusing the answer in hand over it would be absurd.
            stored::save(&stored::Snapshot {
                v: 1,
                fetched_at_ms,
                covered_from: result.from.clone(),
                rows: result.rows.clone(),
            });
            Ok(Fetched {
                rows: result.rows,
                covered_from: result.from,
                fetched_at_ms,
                stale: false,
            })
        }
        Err(e) => {
            let message = e.to_string();
            let mut remembered = None;
            if let Ok(mut guard) = cache().lock() {
                match guard.as_mut() {
                    // Keep the rows that are already there. A grid that was
                    // right ten minutes ago beats an empty one, as long as the
                    // caller is told the refresh failed.
                    Some(c) => {
                        c.last_error = Some((message.clone(), Instant::now()));
                        if !c.rows.is_empty() {
                            remembered = Some(Fetched {
                                rows: c.rows.clone(),
                                covered_from: c.covered_from.clone(),
                                fetched_at_ms: c.fetched_at_ms,
                                stale: true,
                            });
                        }
                    }
                    None => {
                        *guard = Some(Cache {
                            rows: Vec::new(),
                            covered_from: None,
                            fetched_at: Instant::now()
                                .checked_sub(FRESH_FOR)
                                .unwrap_or_else(Instant::now),
                            fetched_at_ms: 0,
                            last_error: Some((message.clone(), Instant::now())),
                        })
                    }
                }
            }
            match remembered {
                Some(fetched) => Ok(fetched),
                None => Err(FetchError::new(message)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_breakdown_dimension_falls_back_to_models() {
        // A front end asking for something this build has not got should get a
        // report rather than an error dialog, and `project` is the one it will
        // ask for: the Mac has that breakdown and the account cannot.
        assert_eq!(Dimension::from_wire("model"), Dimension::Model);
        assert_eq!(Dimension::from_wire("source"), Dimension::Source);
        assert_eq!(Dimension::from_wire("harness"), Dimension::Source);
        assert_eq!(Dimension::from_wire("day"), Dimension::Day);
        assert_eq!(Dimension::from_wire("project"), Dimension::Model);
        assert_eq!(Dimension::from_wire(""), Dimension::Model);
    }

    #[test]
    fn an_auth_failure_is_expected_and_actionable() {
        // A front end turns `Authentication` into a sign-in button rather than
        // an error banner, so the two revoked-token strings must classify
        // the same way whether they come from the keychain or the server.
        for message in [
            tokenstat_sync::profile::NOT_LOGGED_IN.to_string(),
            tokenstat_sync::profile::TOKEN_REVOKED.to_string(),
        ] {
            let error = FetchError::new(message);
            assert!(error.expected);
            assert_eq!(error.reason, FailureReason::Authentication);
        }
    }

    #[test]
    fn a_plan_limitation_is_expected_but_not_an_auth_problem() {
        // "Your plan does not include this" is a settled fact about the
        // account, not a fault, but signing in again would not fix it.
        let error =
            FetchError::new("the account refused this request (403): upgrade_required".to_string());
        assert!(error.expected);
        assert_eq!(error.reason, FailureReason::UpgradeRequired);
    }

    #[test]
    fn a_real_failure_is_neither_expected_nor_an_auth_problem() {
        let error = FetchError::new("usage request failed (500): boom".to_string());
        assert!(!error.expected);
        assert_eq!(error.reason, FailureReason::Other);
    }

    fn a_row(day: &str) -> SeriesRow {
        SeriesRow {
            day: day.to_string(),
            src: "claude_code".into(),
            model: "claude-sonnet-4".into(),
            input: 1,
            output: 2,
            cr: 3,
            cw5: 4,
            cw1: 5,
            ev: 1,
            plan: 0,
        }
    }

    #[test]
    fn a_stored_answer_is_adopted_as_already_stale() {
        // Good enough to draw on a cold launch, not good enough to skip the
        // fetch. Both halves matter: the first is why the file exists, the
        // second is why a phone still ends up showing this minute's numbers.
        let cache = adopted(stored::Snapshot {
            v: 1,
            fetched_at_ms: now_ms() - 60_000,
            covered_from: Some("2026-01-01".into()),
            rows: vec![a_row("2026-08-11")],
        });
        assert_eq!(cache.rows.len(), 1);
        assert!(cache.last_error.is_none());
        assert!(
            cache.fetched_at.elapsed() >= FRESH_FOR
                // A process younger than the freshness window cannot name an
                // `Instant` that far back. Adopting as "now" there is still
                // correct, it just refreshes one call later.
                || Instant::now().checked_sub(FRESH_FOR).is_none(),
            "an adopted answer must not count as fresh"
        );
    }

    #[test]
    fn a_snapshot_survives_a_round_trip() {
        // The cache file is the wire shape, so a change to `SeriesRow` that
        // broke this would also have broken the fetch it is a copy of.
        let snapshot = stored::Snapshot {
            v: 1,
            fetched_at_ms: 1_786_000_000_000,
            covered_from: Some("2026-07-01".into()),
            rows: vec![a_row("2026-08-10"), a_row("2026-08-11")],
        };
        let text = serde_json::to_string(&snapshot).expect("encode");
        let back: stored::Snapshot = serde_json::from_str(&text).expect("decode");
        assert_eq!(back.v, 1);
        assert_eq!(back.fetched_at_ms, snapshot.fetched_at_ms);
        assert_eq!(back.covered_from.as_deref(), Some("2026-07-01"));
        assert_eq!(back.rows.len(), 2);
        assert_eq!(back.rows[0].cw1, 5, "the cache split must survive");
        assert_eq!(back.rows[1].day, "2026-08-11");
    }

    #[test]
    fn a_file_is_kept_for_a_fortnight_and_no_longer() {
        // Past that the grid it would draw is a picture of a fortnight ago.
        // Better to open empty and fetch than to open on fiction.
        let day = 24 * 60 * 60 * 1000i64;
        let now = 30 * day;
        assert!(stored::worth_opening(now - day, now));
        assert!(stored::worth_opening(now - 14 * day, now));
        assert!(!stored::worth_opening(now - 15 * day, now));
        // A clock that jumped backwards must not throw the answer away.
        assert!(stored::worth_opening(now + day, now));
    }
}
