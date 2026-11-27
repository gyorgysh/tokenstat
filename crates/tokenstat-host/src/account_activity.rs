// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.
//! The account's activity grid, across every machine that syncs.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
static GENERATION: AtomicU64 = AtomicU64::new(0);
use std::time::{Duration, Instant};

use tokenstat_core::activity::{self, HeatCalendar};
use tokenstat_core::model::Counters;
use tokenstat_core::pricing::{EquivalentValue, PriceTable};
use tokenstat_core::store::DayPart;
use tokenstat_sync::profile::{self, LockedDay, SeriesRow};

const FRESH_FOR: Duration = Duration::from_secs(10 * 60);

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
    account: String,
    requested_from: String,
    requested_to: String,
    rows: Vec<SeriesRow>,
    covered_from: Option<String>,
    unlock_from: Option<String>,
    history_locked: bool,
    history_days: Option<u16>,
    locked: Vec<LockedDay>,
    fetched_at: Instant,
    fetched_at_ms: i64,
    last_error: Option<(String, Instant)>,
}

impl Cache {
    fn fresh_for(&self, account: &str, from: &str, to: &str) -> bool {
        self.account == account
            && self.requested_from == from
            && self.requested_to == to
            && self.last_error.is_none()
            && self.fetched_at_ms > 0
            && self.fetched_at.elapsed() < FRESH_FOR
    }

    fn fetched(&self, stale: bool) -> Fetched {
        Fetched {
            rows: self.rows.clone(),
            covered_from: self.covered_from.clone(),
            unlock_from: self.unlock_from.clone(),
            history_locked: self.history_locked,
            history_days: self.history_days,
            locked: self.locked.clone(),
            fetched_at_ms: self.fetched_at_ms,
            stale,
        }
    }
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
    GENERATION.fetch_add(1, Ordering::SeqCst);
    if let Ok(mut guard) = cache().lock() {
        *guard = None;
        let _ = stored::remove();
    }

    if let Ok(mut guard) = machine_cache().lock() {
        *guard = None;
    }
}

mod stored {
    use std::path::PathBuf;

    use serde::{Deserialize, Serialize};
    use tokenstat_sync::profile::SeriesRow;

    const VERSION: u32 = 2;

    const KEEP_FOR_MS: i64 = 14 * 24 * 60 * 60 * 1000;

    #[derive(Serialize, Deserialize)]
    pub(super) struct Snapshot {
        pub v: u32,
        /// Which login wrote the answer. The account id itself only arrives
        /// over the network, so this is the offline identity the host builds
        /// from the host and bearer token; a snapshot from another login is
        /// not this login's answer, however recent it is.
        #[serde(default)]
        pub account: String,
        pub fetched_at_ms: i64,
        pub covered_from: Option<String>,
        pub rows: Vec<SeriesRow>,
        #[serde(default)]
        pub unlock_from: Option<String>,
        #[serde(default)]
        pub history_locked: bool,
        #[serde(default)]
        pub history_days: Option<u16>,
        #[serde(default)]
        pub locked: Vec<tokenstat_sync::profile::LockedDay>,
    }

    fn path() -> Option<PathBuf> {
        Some(tokenstat_paths::data_dir()?.join("account-series.json"))
    }

    /// Whether a stored answer belongs to the login in hand.
    ///
    /// Signed out means no login in hand, so nothing on disk is adopted.
    /// That is deliberate, not a gap: a snapshot is another account's grid,
    /// and serving it while signed out (or after switching accounts) would
    /// show one login's numbers as another's. Signed out therefore always
    /// fetches or reports empty, never the remembered answer.
    pub(super) fn belongs_to(stored: &str, current: Option<&str>) -> bool {
        current == Some(stored)
    }

    /// Whether a file this old is still worth opening on.
    ///
    /// A clock that moved backwards makes the age negative. That reads as
    /// "unknown, use it": a wrong clock is not a reason to throw away the only
    /// answer we have.
    pub(super) fn worth_opening(fetched_at_ms: i64, now_ms: i64) -> bool {
        now_ms.saturating_sub(fetched_at_ms) <= KEEP_FOR_MS
    }

    pub(super) fn load(now_ms: i64, account: Option<&str>) -> Option<Snapshot> {
        let path = path()?;
        use std::io::Read;
        let mut text = String::new();
        std::fs::File::open(path)
            .ok()?
            .take(32 * 1024 * 1024 + 1)
            .read_to_string(&mut text)
            .ok()?;
        if text.len() > 32 * 1024 * 1024 {
            return None;
        }
        let snapshot: Snapshot = serde_json::from_str(&text).ok()?;
        if snapshot.v != VERSION {
            return None;
        }
        if !belongs_to(&snapshot.account, account) {
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
        let _ = tokenstat_sync::snapshot::write_private_atomically(&path, &text);
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
/// The grid is always the `weeks` asked for (a rolling year). A Free plan's
/// history span is thirty days of exact counts. Older days stay on the
/// calendar as locked cells so the card keeps a year shape, the same
/// treatment as the public profile. Shrinking to the unlocked month made
/// four weeks fill a year-sized card.
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
    let lock = history_lock(
        today,
        fetched.history_locked,
        fetched.unlock_from.as_deref(),
        fetched.covered_from.as_deref(),
        fetched.history_days,
    );

    let mut by_day: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
    for row in &rows {
        let counters = Counters {
            input_fresh: Some(row.input),
            cache_read: Some(row.cr),
            cache_write_5m: Some(row.cw5),
            cache_write_1h: Some(row.cw1),
            output: Some(row.output),
        };

        let model = tokenstat_core::pricing::display_usage_model_id(&row.model);
        let micros = EquivalentValue::price(prices, &model, &counters)
            .map(|v| v.micros().max(0) as u64)
            .unwrap_or(0);
        let total = by_day.entry(row.day.clone()).or_insert(0);
        *total = total.saturating_add(micros);
    }

    let mut days: Vec<(String, u64)> = by_day.into_iter().collect();

    if days.is_empty() && !fetched.locked.is_empty() {
        days.push((today.to_string(), 0));
    }
    let mut calendar = activity::calendar(&days, weeks, today);
    if let (Some(cal), Some(lock)) = (calendar.as_mut(), lock.as_ref()) {
        let levels: Vec<(String, u8)> = fetched
            .locked
            .iter()
            .map(|d| (d.d.clone(), d.level))
            .collect();
        cal.lock_before(lock.unlock_from, &levels);
    }
    Ok(AccountCalendar {
        calendar,
        fetched_at_ms,
        stale,
        lock,
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
    /// Free year lock, when the plan's exact window is shorter than a year.
    pub lock: Option<HistoryLock>,
}

/// The recent window a Free grid may show in full.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistoryLock {
    pub unlock_from: jiff::civil::Date,
    pub history_days: u16,
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
                entry.0 = entry.0.saturating_add(v.micros());
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
                sessions: 0,
                value: EquivalentValue::from_micros(micros),
                estimated,
                unpriced_models: unpriced,

                local: false,
            }
        })
        .collect();

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

const MACHINE_FRESH_FOR: Duration = Duration::from_secs(10 * 60);

const MAX_MACHINE_USAGE: usize = 64;

struct MachineCache {
    account: String,
    today: String,
    pricing_date: String,
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

    let owner = crate::account_session::current_or_capture().map_err(FetchError::new)?;
    let client = owner
        .client
        .as_ref()
        .ok_or_else(|| FetchError::new(profile::NOT_LOGGED_IN.into()))?;
    let account = client.authentication_id();
    let generation = GENERATION.load(Ordering::SeqCst);
    let today = activity::today(tz);
    let machines = &machines[..machines.len().min(MAX_MACHINE_USAGE)];
    if let Ok(guard) = machine_cache().lock()
        && let Some(c) = guard.as_ref()
        && c.account == account
        && c.today == today.to_string()
        && c.pricing_date == prices.effective_from
        && c.days == days
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

    let today = activity::today(tz);

    let from = today
        .checked_add(jiff::Span::new().days(-(days.clamp(1, 3650) as i64 - 1)))
        .map_err(|e| FetchError::new(e.to_string()))?
        .to_string();
    let to = today.to_string();

    let results: Vec<Result<MachineUsage, String>> = std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(machines.len());
        let from = from.as_str();
        let to = to.as_str();
        for chunk in machines.chunks(4) {
            let mut batch = Vec::with_capacity(chunk.len());
            for machine in chunk {
                let machine = machine.as_str();
                batch.push(scope.spawn(move || {
                    match client.account_series(from, to, Some(machine)) {
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
                                let lookup =
                                    tokenstat_core::pricing::display_usage_model_id(&row.model);
                                if let Some(v) = EquivalentValue::price(prices, &lookup, &counters)
                                {
                                    micros = micros.saturating_add(v.micros());
                                }
                                events = events.saturating_add(row.ev);
                                active.insert(row.day.clone());
                            }
                            Ok(MachineUsage {
                                machine: machine.to_string(),
                                micros,
                                events,
                                active_days: active.len(),
                            })
                        }
                        Err(e) => Err(e.to_string()),
                    }
                }));
            }
            for handle in batch {
                handles.push(
                    handle
                        .join()
                        .unwrap_or_else(|_| Err("device spend worker failed".to_string())),
                );
            }
        }
        handles
    });

    owner.ensure_current().map_err(FetchError::new)?;
    if generation != GENERATION.load(Ordering::SeqCst) {
        return Err(FetchError::new(
            "usage changed during refresh; retry".into(),
        ));
    }
    let mut out: Vec<MachineUsage> = Vec::new();
    let mut last_error: Option<String> = None;
    for result in results {
        match result {
            Ok(row) => out.push(row),
            Err(e) => last_error = Some(e),
        }
    }

    if out.is_empty() {
        return Err(FetchError::new(last_error.unwrap_or_else(|| {
            "the account did not answer for any device".to_string()
        })));
    }

    if let Ok(mut guard) = machine_cache().lock() {
        if generation != GENERATION.load(Ordering::SeqCst) {
            return Err(FetchError::new(
                "usage changed during refresh; retry".into(),
            ));
        }
        *guard = Some(MachineCache {
            account,
            today: today.to_string(),
            pricing_date: prices.effective_from.clone(),
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

const HISTORY_DISPLAY_CAP_DAYS: u16 = 365;

fn history_lock(
    today: jiff::civil::Date,
    flagged: bool,
    unlock_from: Option<&str>,
    covered_from: Option<&str>,
    history_days: Option<u16>,
) -> Option<HistoryLock> {
    let from = unlock_from
        .or(covered_from)
        .and_then(|d| d.parse::<jiff::civil::Date>().ok())?;
    let spanned = history_days
        .unwrap_or_else(|| u16::try_from((today - from).get_days().max(0) + 1).unwrap_or(u16::MAX));
    if flagged || spanned < HISTORY_DISPLAY_CAP_DAYS {
        Some(HistoryLock {
            unlock_from: from,
            history_days: spanned.max(1),
        })
    } else {
        None
    }
}

pub struct Fetched {
    rows: Vec<SeriesRow>,
    covered_from: Option<String>,
    unlock_from: Option<String>,
    history_locked: bool,
    history_days: Option<u16>,
    locked: Vec<LockedDay>,
    /// When these numbers came off the service, in unix milliseconds.
    pub fetched_at_ms: i64,
    /// This is a remembered answer, served because the refresh failed. The
    /// numbers are real, they are just old, and a caller must say so. Same rule
    /// as a stale limit reading: a figure with no date is a quiet claim to be
    /// current.
    pub stale: bool,
}

impl Fetched {
    fn within(mut self, from: &str, to: &str) -> Self {
        self.rows
            .retain(|row| row.day.as_str() >= from && row.day.as_str() <= to);
        self.locked
            .retain(|day| day.d.as_str() >= from && day.d.as_str() <= to);
        self
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn adopt_stored(guard: &mut Option<Cache>, account: &str) {
    if guard.is_some() {
        return;
    }
    if let Some(snapshot) = stored::load(now_ms(), Some(account)) {
        *guard = Some(adopted(snapshot));
    }
}

fn adopted(snapshot: stored::Snapshot) -> Cache {
    Cache {
        account: snapshot.account,
        requested_from: String::new(),
        requested_to: String::new(),
        rows: snapshot.rows,
        covered_from: snapshot.covered_from,
        unlock_from: snapshot.unlock_from,
        history_locked: snapshot.history_locked,
        history_days: snapshot.history_days,
        locked: snapshot.locked,

        fetched_at: Instant::now()
            .checked_sub(FRESH_FOR)
            .unwrap_or_else(Instant::now),
        fetched_at_ms: snapshot.fetched_at_ms,
        last_error: None,
    }
}

fn series(weeks: usize, today: jiff::civil::Date) -> Result<Fetched, FetchError> {
    let owner = crate::account_session::current_or_capture().map_err(FetchError::new)?;
    let client = owner
        .client
        .as_ref()
        .ok_or_else(|| FetchError::new(profile::NOT_LOGGED_IN.into()))?;
    let account = client.authentication_id();
    let generation = GENERATION.load(Ordering::SeqCst);
    let span = (weeks.clamp(1, 53) * 7 + 7) as i64;
    let from = today
        .checked_add(jiff::Span::new().days(-span))
        .map_err(|e| FetchError::new(e.to_string()))?
        .to_string();
    let to = today.to_string();
    {
        let mut guard = cache()
            .lock()
            .map_err(|_| FetchError::new("the usage cache is poisoned".into()))?;
        if guard.as_ref().is_some_and(|cache| cache.account != account) {
            *guard = None;
        }
        adopt_stored(&mut guard, &account);
        if let Some(c) = guard.as_ref() {
            if c.fresh_for(&account, &from, &to) {
                return Ok(c.fetched(false).within(&from, &to));
            }

            if let Some((message, at)) = &c.last_error
                && at.elapsed() < RETRY_AFTER
            {
                if !c.rows.is_empty() {
                    return Ok(c.fetched(true).within(&from, &to));
                }
                return Err(FetchError::new(message.clone()));
            }
        }
    }

    let result = client.account_series(&from, &to, None);
    owner.ensure_current().map_err(FetchError::new)?;
    let mut guard = cache()
        .lock()
        .map_err(|_| FetchError::new("the usage cache is poisoned".into()))?;
    if generation != GENERATION.load(Ordering::SeqCst) {
        return Err(FetchError::new(
            "usage changed during refresh; retry".into(),
        ));
    }
    match result {
        Ok(result) => {
            let fetched_at_ms = now_ms();
            let entry = Cache {
                account: account.clone(),
                requested_from: from,
                requested_to: to,
                rows: result.rows,
                covered_from: result.from.clone(),
                unlock_from: result.unlock_from.clone(),
                history_locked: result.history_locked,
                history_days: result.history_days,
                locked: result.locked,
                fetched_at: Instant::now(),
                fetched_at_ms,
                last_error: None,
            };
            stored::save(&stored::Snapshot {
                v: 2,
                account,
                fetched_at_ms,
                covered_from: entry.covered_from.clone(),
                rows: entry.rows.clone(),
                unlock_from: entry.unlock_from.clone(),
                history_locked: entry.history_locked,
                history_days: entry.history_days,
                locked: entry.locked.clone(),
            });
            let fetched = entry
                .fetched(false)
                .within(&entry.requested_from, &entry.requested_to);
            *guard = Some(entry);
            Ok(fetched)
        }
        Err(e) => {
            let message = e.to_string();
            let mut remembered = None;
            {
                match guard.as_mut() {
                    Some(c) => {
                        c.last_error = Some((message.clone(), Instant::now()));
                        if !c.rows.is_empty() {
                            remembered = Some(c.fetched(true));
                        }
                    }
                    None => {
                        *guard = Some(Cache {
                            account,
                            requested_from: from.clone(),
                            requested_to: to.clone(),
                            rows: Vec::new(),
                            covered_from: None,
                            unlock_from: None,
                            history_locked: false,
                            history_days: None,
                            locked: Vec::new(),
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
                Some(fetched) => Ok(fetched.within(&from, &to)),
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
        assert_eq!(Dimension::from_wire("model"), Dimension::Model);
        assert_eq!(Dimension::from_wire("source"), Dimension::Source);
        assert_eq!(Dimension::from_wire("harness"), Dimension::Source);
        assert_eq!(Dimension::from_wire("day"), Dimension::Day);
        assert_eq!(Dimension::from_wire("project"), Dimension::Model);
        assert_eq!(Dimension::from_wire(""), Dimension::Model);
    }

    #[test]
    fn an_auth_failure_is_expected_and_actionable() {
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
        let cache = adopted(stored::Snapshot {
            v: 2,
            account: "host:digest".into(),
            fetched_at_ms: now_ms() - 60_000,
            covered_from: Some("2026-01-01".into()),
            rows: vec![a_row("2026-08-11")],
            unlock_from: None,
            history_locked: false,
            history_days: None,
            locked: Vec::new(),
        });
        assert_eq!(cache.rows.len(), 1);
        assert!(cache.last_error.is_none());
        assert!(
            cache.fetched_at.elapsed() >= FRESH_FOR
                || Instant::now().checked_sub(FRESH_FOR).is_none(),
            "an adopted answer must not count as fresh"
        );
    }

    #[test]
    fn fresh_usage_requires_the_same_login_and_requested_window() {
        let mut cache = adopted(stored::Snapshot {
            v: 2,
            account: "account-a".into(),
            fetched_at_ms: now_ms(),
            covered_from: None,
            rows: vec![a_row("2026-01-01"), a_row("2026-10-01")],
            unlock_from: None,
            history_locked: false,
            history_days: None,
            locked: vec![],
        });
        cache.fetched_at = Instant::now();
        cache.requested_from = "2026-10-01".into();
        cache.requested_to = "2026-10-12".into();
        assert!(cache.fresh_for("account-a", "2026-10-01", "2026-10-12"));
        assert!(!cache.fresh_for("account-b", "2026-10-01", "2026-10-12"));
        assert!(!cache.fresh_for("account-a", "2026-01-01", "2026-10-12"));
        let fetched = cache.fetched(true).within("2026-10-01", "2026-10-12");
        assert_eq!(fetched.rows.len(), 1);
        assert_eq!(fetched.rows[0].day, "2026-10-01");
        assert!(!stored::worth_opening(i64::MIN, i64::MAX));
    }

    #[test]
    fn a_snapshot_from_another_login_is_not_adopted() {
        assert!(stored::belongs_to("host:digest", Some("host:digest")));
        assert!(!stored::belongs_to("host:digest", Some("host:other")));
        assert!(!stored::belongs_to("host:digest", None));
    }

    #[test]
    fn a_snapshot_survives_a_round_trip() {
        let snapshot = stored::Snapshot {
            v: 2,
            account: "host:digest".into(),
            fetched_at_ms: 1_786_000_000_000,
            covered_from: Some("2026-07-01".into()),
            rows: vec![a_row("2026-08-10"), a_row("2026-08-11")],
            unlock_from: Some("2026-07-16".into()),
            history_locked: true,
            history_days: Some(30),
            locked: vec![tokenstat_sync::profile::LockedDay {
                d: "2026-07-01".into(),
                level: 2,
            }],
        };
        let text = serde_json::to_string(&snapshot).expect("encode");
        let back: stored::Snapshot = serde_json::from_str(&text).expect("decode");
        assert_eq!(back.v, 2);
        assert_eq!(back.account, "host:digest");
        assert_eq!(back.fetched_at_ms, snapshot.fetched_at_ms);
        assert_eq!(back.covered_from.as_deref(), Some("2026-07-01"));
        assert_eq!(back.rows.len(), 2);
        assert_eq!(back.rows[0].cw1, 5, "the cache split must survive");
        assert_eq!(back.rows[1].day, "2026-08-11");
        assert!(back.history_locked);
        assert_eq!(back.history_days, Some(30));
        assert_eq!(back.locked.len(), 1);
        assert_eq!(back.locked[0].level, 2);
    }

    #[test]
    fn a_thirty_day_window_locks_the_year() {
        let today = jiff::civil::date(2026, 8, 14);
        let lock = history_lock(today, false, None, Some("2026-07-16"), None)
            .expect("free window is locked");
        assert_eq!(lock.unlock_from.to_string(), "2026-07-16");
        assert_eq!(lock.history_days, 30);
        assert!(
            history_lock(today, false, None, Some("2025-08-15"), None).is_none(),
            "a year of coverage is not a lock"
        );
        let flagged = history_lock(
            today,
            true,
            Some("2026-07-16"),
            Some("2026-07-16"),
            Some(30),
        )
        .expect("server flag wins");
        assert_eq!(flagged.history_days, 30);
    }

    #[test]
    fn a_file_is_kept_for_a_fortnight_and_no_longer() {
        let day = 24 * 60 * 60 * 1000i64;
        let now = 30 * day;
        assert!(stored::worth_opening(now - day, now));
        assert!(stored::worth_opening(now - 14 * day, now));
        assert!(!stored::worth_opening(now - 15 * day, now));

        assert!(stored::worth_opening(now + day, now));
    }
}
