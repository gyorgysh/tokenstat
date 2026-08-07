//! Method dispatch. One implementation, however the request arrived.
//!
//! Every method takes one JSON object and returns one JSON envelope:
//!
//! ```json
//! {"ok": true, "result": ...}
//! {"ok": false, "error": {"code": "...", "message": "..."}}
//! ```
//!
//! A front end therefore has exactly one decoding path and one error path, no
//! matter which method it called. The C ABI and the socket server both call
//! straight into here, so a method cannot exist over one transport and not the
//! other, and there is no second copy to keep in step.

use std::sync::{Mutex, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};
use tokenstat_core::pricing::{EquivalentValue, display_usage_model_id};
use tokenstat_core::{DayPart, GroupBy, Query};

use crate::PROTOCOL_VERSION;
use crate::account_activity::FailureReason;
use crate::automations::Automation;
use crate::dto::{
    AccountDto, BlockDto, BucketDto, CalendarDto, DayDetailDto, DayPartDto, DeviceLoginDto,
    DevicePollDto, GroupByDto, InfoDto, MachineDto, QueryDto, ScanReportDto, SplitBucketDto,
    SyncResultDto, TotalsDto, WorkspaceDto,
};
use crate::session::{OpenParams, Session};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReportParams {
    group: GroupByDto,
    #[serde(default)]
    query: QueryDto,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct QueryParams {
    query: QueryDto,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SplitParams {
    group: GroupByDto,
    /// The second dimension. `project` split by `source` answers "which
    /// harnesses ran in this folder".
    split_by: GroupByDto,
    #[serde(default)]
    query: QueryDto,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalendarParams {
    /// Columns in the grid, clamped to 1..=53 by the core. 53 is the rolling
    /// year the CLI draws.
    #[serde(default = "default_weeks")]
    weeks: usize,
    #[serde(default)]
    query: QueryDto,
    /// `"local"` or `"account"`. Anything else is treated as local.
    ///
    /// Local is this machine's own archive: complete, offline, and including
    /// whatever has not been uploaded yet. Account is every machine that syncs,
    /// which needs the network and an account, so it can fail in ways a local
    /// grid cannot. The caller picks, and is told which one it got.
    #[serde(default)]
    scope: Option<String>,
}

impl Default for CalendarParams {
    fn default() -> Self {
        CalendarParams {
            weeks: default_weeks(),
            query: QueryDto::default(),
            scope: None,
        }
    }
}

/// Params for `activity.day`: one `YYYY-MM-DD`, plus the same scope/weeks the
/// calendar accepts so an account hover reuses the calendar's series cache.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DayDetailParams {
    date: String,
    #[serde(default = "default_weeks")]
    weeks: usize,
    #[serde(default)]
    scope: Option<String>,
}

impl Default for DayDetailParams {
    fn default() -> Self {
        DayDetailParams {
            date: String::new(),
            weeks: default_weeks(),
            scope: None,
        }
    }
}

fn default_weeks() -> usize {
    53
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspacePathParams {
    path: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceIdParams {
    id: String,
    /// Only used by `workspace.rename`.
    #[serde(default)]
    name: Option<String>,
    /// Only used by `workspace.log`.
    #[serde(default)]
    limit: Option<u32>,
    /// Directory to list, for `workspace.tree`, or the file to diff, for
    /// `workspace.diff`. Always relative to the workspace root.
    #[serde(default)]
    path: Option<String>,
    /// Paths to stage or unstage.
    #[serde(default)]
    paths: Option<Vec<String>>,
    /// Commit message.
    #[serde(default)]
    message: Option<String>,
    /// Text content for `workspace.write`.
    #[serde(default)]
    content: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PtySpawnParams {
    /// Workspace to run in. The command inherits its folder as the cwd.
    workspace_id: String,
    command: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default = "default_rows")]
    rows: u16,
    #[serde(default = "default_cols")]
    cols: u16,
    /// The user opted out of colour in settings.
    #[serde(default)]
    no_color: bool,
}

fn default_rows() -> u16 {
    24
}

fn default_cols() -> u16 {
    80
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PtyIdParams {
    id: String,
    /// `pty.read` only: where the caller got to last time.
    #[serde(default)]
    offset: u64,
    /// `pty.write` only: base64, because a keystroke is bytes.
    #[serde(default)]
    data: Option<String>,
    /// `pty.resize` only.
    #[serde(default)]
    rows: Option<u16>,
    #[serde(default)]
    cols: Option<u16>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AutomationParams {
    id: Option<String>,
    job: Option<Automation>,
    enabled: Option<bool>,
    /// `automation.transcript` only: where the caller got to last time.
    offset: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct TodoParams {
    id: Option<String>,
    title: Option<String>,
    kind: Option<crate::todo::CardKind>,
    notes: Option<String>,
    column: Option<String>,
    order: Option<i64>,
    priority: Option<crate::todo::Priority>,
    backend: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    workspace_id: Option<String>,
    budget_seconds: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct HighlightParams {
    /// The buffer to colour, which is what is on screen rather than what is on
    /// disk. `highlight.syntax` leaves it empty.
    text: String,
    /// Used to work out the language. The file is never opened.
    path: String,
    /// Overrides `path`, for a buffer whose name says nothing useful.
    language: Option<String>,
}

impl HighlightParams {
    fn language(&self) -> Option<tokenstat_highlight::Language> {
        match self.language.as_deref() {
            Some(id) => tokenstat_highlight::Language::from_id(id),
            None => tokenstat_highlight::Language::detect(&self.path),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct SyncParams {
    /// Build and validate the payload without sending it.
    dry_run: bool,
    /// Ask the server to drop rows outside the window.
    prune: bool,
    /// Window expression, for example `30d`. Server default when absent.
    window: Option<String>,
}

fn ok(result: Value) -> String {
    json!({"ok": true, "result": result}).to_string()
}

fn err(code: &str, message: impl std::fmt::Display) -> String {
    json!({
        "ok": false,
        "error": {"code": code, "message": message.to_string()}
    })
    .to_string()
}

/// Decode params, treating absent and empty as the default.
///
/// A transport that has no params to send should not have to invent `{}`.
fn parse<T: for<'de> Deserialize<'de> + Default>(params: &str) -> Result<T, String> {
    let trimmed = params.trim();
    if trimmed.is_empty() || trimmed == "null" {
        return Ok(T::default());
    }
    serde_json::from_str(trimmed).map_err(|e| e.to_string())
}

/// Wall clock in milliseconds, or 0 if the clock is before the epoch.
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// When this account last synced, from anywhere.
///
/// Derived rather than read. `/api/v1/me` carries a `last_sync_at` per machine
/// and none for the account, so reading the top level gave `None` and every
/// front end said "never" for an account that had synced minutes earlier.
/// Deriving it is also the more honest definition: an account's last sync is
/// the most recent one across its machines, not this machine's.
///
/// Timestamps are RFC 3339 from the server, which sorts correctly as text, so
/// this compares strings rather than parsing dates it would only re-serialize.
fn latest_sync(raw_machines: &[Value]) -> Option<String> {
    raw_machines
        .iter()
        .filter_map(|m| m.get("last_sync_at")?.as_str())
        .filter(|s| !s.is_empty())
        .max()
        .map(str::to_string)
}

/// The account's profile picture, as something a front end can fetch.
///
/// The API sends `/avatar/<name>`, relative, because it never hands out a third
/// party URL: hotlinking a provider avatar would report every view of it back to
/// that provider. Resolving it here rather than in each client means one place
/// knows that a leading slash is relative to the host the token authenticated
/// to. An absolute URL is passed through untouched, so the API can start
/// sending one without breaking anything.
fn avatar_url(host: &str, raw: &Value) -> Option<String> {
    let value = raw.get("avatar")?.as_str()?.trim();
    if value.is_empty() {
        return None;
    }
    if value.starts_with("http://") || value.starts_with("https://") {
        return Some(value.to_string());
    }
    Some(format!(
        "{}/{}",
        host.trim_end_matches('/'),
        value.trim_start_matches('/')
    ))
}

/// Describe a registered folder, reading git only when it is actually there.
///
/// A missing folder gets `git: None` rather than an empty status, so a caller
/// cannot mistake "we did not look" for "nothing has changed".
fn describe(ws: &tokenstat_workspace::Workspace) -> WorkspaceDto {
    let exists = ws.exists();
    WorkspaceDto {
        id: ws.id.clone(),
        path: ws.path.display().to_string(),
        name: ws.name.clone(),
        added_at_ms: ws.added_at_ms,
        exists,
        git: exists.then(|| tokenstat_workspace::git::status(&ws.path)),
    }
}

/// Apply a closure to the session.
///
/// A thin wrapper kept because it reads well at every call site and because it
/// is the seam a future per-request permission check would sit in.
fn with_session<T>(
    s: &mut Session,
    f: impl FnOnce(&mut Session) -> Result<T, String>,
) -> Result<T, String> {
    f(s)
}

/// Build the wire detail for a day, pricing every row at list rates.
///
/// The same `EquivalentValue` pricing the calendar's day buckets use, applied
/// per `model × source` row, so the detail's value is the cell's value and the
/// two surfaces cannot drift apart.
fn day_detail_dto(
    date: &str,
    rows: &[DayPart],
    prices: &tokenstat_core::pricing::PriceTable,
) -> DayDetailDto {
    let mut value_micros = 0i64;
    let mut estimated = false;
    let mut unpriced_models: Vec<String> = Vec::new();
    let mut tokens = 0u64;
    let mut events = 0u64;

    for row in rows {
        let lookup = display_usage_model_id(&row.model);
        tokens = tokens.saturating_add(row.tokens());
        events = events.saturating_add(row.events);
        match EquivalentValue::price(prices, &lookup, &row.counters) {
            Some(v) => {
                value_micros = value_micros.saturating_add(v.micros().max(0));
                estimated |= prices.is_estimate(&lookup);
            }
            None => {
                if !unpriced_models.iter().any(|m| m == &lookup) {
                    unpriced_models.push(lookup);
                }
            }
        }
    }

    DayDetailDto {
        date: date.to_string(),
        tokens,
        events,
        value_micros,
        estimated,
        unpriced_models,
        rows: rows.iter().map(DayPartDto::from).collect(),
    }
}

/// Handle one call. Never panics on bad input, and never returns a non-JSON
/// string, so the caller can decode unconditionally.
pub fn call(session: &mut Session, method: &str, params: &str) -> String {
    match dispatch(session, method, params) {
        Ok(v) => ok(v),
        Err(e) => err("call_failed", e),
    }
}

fn dispatch(s: &mut Session, method: &str, params: &str) -> Result<Value, String> {
    match method {
        // Re-open against a different archive or timezone. Also the hook a
        // future remote transport uses to point at another machine.
        "open" => {
            let p: OpenParams = parse(params)?;
            *s = Session::open(&p)?;
            Ok(json!({"opened": true}))
        }

        "info" => with_session(s, |b| {
            let info = InfoDto {
                protocol_version: PROTOCOL_VERSION.to_string(),
                core_version: tokenstat_core::VERSION.to_string(),
                db_path: b.engine.db_path().display().to_string(),
                timezone: b
                    .engine
                    .timezone()
                    .iana_name()
                    .unwrap_or("unknown")
                    .to_string(),
                price_book_effective_from: b.prices.effective_from.clone(),
                has_prices: !b.prices.is_empty(),
            };
            serde_json::to_value(info).map_err(|e| e.to_string())
        }),

        "totals" => {
            let p: QueryParams = parse(params)?;
            with_session(s, |b| {
                let t = b
                    .engine
                    .totals(&Query::from(p.query))
                    .map_err(|e| e.to_string())?;
                serde_json::to_value(TotalsDto::from(t)).map_err(|e| e.to_string())
            })
        }

        "report" => {
            let p: ReportParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let group = GroupBy::from(p.group);
            with_session(s, |b| {
                let rows = b
                    .engine
                    .priced_report(group, &Query::from(p.query), &b.prices)
                    .map_err(|e| e.to_string())?;
                let dtos: Vec<BucketDto> = rows.into_iter().map(BucketDto::from).collect();
                serde_json::to_value(dtos).map_err(|e| e.to_string())
            })
        }

        // The activity calendar behind the Home screen's heatmap and streaks.
        //
        // Built here rather than in the client from a day report, because the
        // grid has to align a real week to a column and the archive only stores
        // days that had events. A client that packed those together would draw
        // a plausible grid with every date in the wrong place.
        "activity.calendar" => {
            let p: CalendarParams = parse(params)?;
            let wants_account = p.scope.as_deref() == Some("account");
            with_session(s, |b| {
                // The account's own grid, across every machine that syncs.
                //
                // Tried first when asked for, and it falls back rather than
                // failing: an empty Home because the network is down is a worse
                // answer than this machine's own year with a line saying so.
                if wants_account {
                    let today = tokenstat_core::activity::today(b.engine.timezone());
                    match crate::account_activity::calendar(&b.prices, b.engine.timezone(), p.weeks)
                    {
                        Ok(Some(calendar)) => {
                            return serde_json::to_value(
                                CalendarDto::from(calendar).scoped("account", None, None),
                            )
                            .map_err(|e| e.to_string());
                        }
                        // The account exists and has nothing in it. Not an
                        // error, and not a reason to show this machine's grid
                        // labelled as everybody's.
                        Ok(None) => return Ok(Value::Null),
                        Err(failure) => {
                            let rows = b
                                .engine
                                .priced_report(GroupBy::Day, &Query::from(p.query), &b.prices)
                                .map_err(|e| e.to_string())?;
                            let days: Vec<(String, u64)> = rows
                                .iter()
                                .map(|r| (r.key.clone(), r.value.micros().max(0) as u64))
                                .collect();
                            // The scope always says `local`, so the grid is
                            // never labelled as the account's. The notice says
                            // why in one line and the code tells the front end
                            // what to do about it. An auth failure gets an
                            // actionable sentence rather than a CLI incantation
                            // quoted at someone who is already sitting in the
                            // app; the front end offers a sign-in from the code.
                            let (notice, code) = match failure.reason {
                                FailureReason::Authentication => (
                                    Some(
                                        "Showing this machine only. Sign in to tokenstat.ai \
                                         to see usage from every machine."
                                            .to_string(),
                                    ),
                                    Some("auth"),
                                ),
                                FailureReason::UpgradeRequired => (
                                    Some(format!("Showing this machine only: {}", failure.message)),
                                    Some("upgrade"),
                                ),
                                FailureReason::Other => (
                                    Some(format!("Showing this machine only: {}", failure.message)),
                                    Some("other"),
                                ),
                            };
                            return match tokenstat_core::activity::calendar(&days, p.weeks, today) {
                                Some(calendar) => serde_json::to_value(
                                    CalendarDto::from(calendar).scoped("local", notice, code),
                                )
                                .map_err(|e| e.to_string()),
                                None => Ok(Value::Null),
                            };
                        }
                    }
                }

                let rows = b
                    .engine
                    .priced_report(GroupBy::Day, &Query::from(p.query), &b.prices)
                    .map_err(|e| e.to_string())?;
                // Cost in microdollars: what the day's work actually spent.
                // Token counts would favour high-volume cheap models over
                // expensive ones; cost reflects real spend instead.
                let days: Vec<(String, u64)> = rows
                    .iter()
                    .map(|r| (r.key.clone(), r.value.micros().max(0) as u64))
                    .collect();
                // Anchored on today rather than on the newest day with data, so
                // a quiet week reads as a quiet week instead of vanishing.
                let today = tokenstat_core::activity::today(b.engine.timezone());
                match tokenstat_core::activity::calendar(&days, p.weeks, today) {
                    Some(calendar) => {
                        serde_json::to_value(CalendarDto::from(calendar)).map_err(|e| e.to_string())
                    }
                    // An empty archive is not an error. The client draws an
                    // empty grid and says the archive has nothing in it yet.
                    None => Ok(Value::Null),
                }
            })
        }

        // One day's hover detail for the Home heatmap: totals plus every
        // `model × source` row, the same shape the public profile draws.
        //
        // Priced here against the same price book the calendar uses, so a
        // hovered day's value always matches its cell. Local comes from the
        // archive; account comes from the same cached series the account
        // calendar is built from, so moving across the grid costs no extra
        // network calls.
        "activity.day" => {
            let p: DayDetailParams = parse(params)?;
            with_session(s, |b| {
                let rows = if p.scope.as_deref() == Some("account") {
                    crate::account_activity::day_detail(&p.date, b.engine.timezone(), p.weeks)
                        .map_err(|e| e.message)?
                } else {
                    b.engine
                        .store()
                        .day_detail(&p.date)
                        .map_err(|e| e.to_string())?
                };
                // Nothing happened that day. An answer, not an error: the
                // client only asks for days the grid lit up, so a miss is
                // usually the account cache being narrower than the local
                // archive, and the hover just shows nothing to add.
                if rows.is_empty() {
                    return Ok(Value::Null);
                }
                let dto = day_detail_dto(&p.date, &rows, &b.prices);
                serde_json::to_value(dto).map_err(|e| e.to_string())
            })
        }

        // Two-level report: "which harnesses ran in which project", and any
        // other cross-tabulation. One query, not one per key.
        "report.split" => {
            let p: SplitParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let group = GroupBy::from(p.group);
            let split = GroupBy::from(p.split_by);
            with_session(s, |b| {
                let rows = b
                    .engine
                    .store()
                    .report_split(group, split, &Query::from(p.query))
                    .map_err(|e| e.to_string())?;
                let dtos: Vec<SplitBucketDto> =
                    rows.into_iter().map(SplitBucketDto::from).collect();
                serde_json::to_value(dtos).map_err(|e| e.to_string())
            })
        }

        "blocks" => {
            let p: QueryParams = parse(params)?;
            with_session(s, |b| {
                let rows = b
                    .engine
                    .blocks(&Query::from(p.query))
                    .map_err(|e| e.to_string())?;
                let dtos: Vec<BlockDto> = rows.into_iter().map(BlockDto::from).collect();
                serde_json::to_value(dtos).map_err(|e| e.to_string())
            })
        }

        // Long running. The caller must not run this on a UI thread.
        "scan" => with_session(s, |b| {
            let r = b.engine.scan().map_err(|e| e.to_string())?;
            serde_json::to_value(ScanReportDto::from(r)).map_err(|e| e.to_string())
        }),

        // Signed out is a state, not a failure. The bridge reports
        // `signedIn: false` so the app can offer sign-in, and reserves the
        // error path for a host that is unreachable or a token that was
        // revoked, which need different words.
        "account.status" => {
            let host =
                tokenstat_sync::profile::resolve_api_host(None).map_err(|e| e.to_string())?;
            match tokenstat_sync::sync_status(None) {
                Ok(s) => serde_json::to_value(AccountDto {
                    signed_in: true,
                    avatar: avatar_url(&s.host, &s.raw),
                    host: s.host,
                    handle: s.handle,
                    display_name: s
                        .raw
                        .get("display_name")
                        .and_then(|v| v.as_str())
                        .filter(|v| !v.is_empty())
                        .map(str::to_string),
                    tier: s.tier,
                    last_sync_at: s.last_sync_at.clone().or_else(|| latest_sync(&s.machines)),
                    // Which of the machines below is the one you are sitting
                    // at. Without it the list is a set of opaque ids and the
                    // only machine anyone can act on is unidentifiable.
                    this_machine_id: tokenstat_sync::config::ensure_machine_id().ok(),
                    machines: s.machines.iter().map(MachineDto::from_value).collect(),
                    schema_current: s.schema_current,
                })
                .map_err(|e| e.to_string()),
                Err(e) if e.is_unauthenticated() => serde_json::to_value(AccountDto {
                    signed_in: false,
                    host,
                    handle: None,
                    display_name: None,
                    tier: None,
                    avatar: None,
                    last_sync_at: None,
                    this_machine_id: None,
                    machines: Vec::new(),
                    schema_current: None,
                })
                .map_err(|e| e.to_string()),
                Err(e) => Err(e.to_string()),
            }
        }

        // Begin a device authorization. Returns the code to show and the URL to
        // open. Opening the browser is the front end's job: this crate has no
        // business deciding how a window behaves.
        "account.deviceStart" => {
            let device = tokenstat_sync::device_start(None).map_err(|e| e.to_string())?;
            let dto = DeviceLoginDto::from(&device);
            with_session(s, |b| {
                b.pending_login = Some(device);
                Ok(())
            })?;
            serde_json::to_value(dto).map_err(|e| e.to_string())
        }

        // Poll once. Never sleeps, so the caller controls the cadence and can
        // cancel. On confirmation the token lands in the keychain, the same
        // entry the CLI reads.
        "account.devicePoll" => {
            let pending = with_session(s, |b| {
                b.pending_login
                    .clone()
                    .ok_or_else(|| "no sign-in is in progress".to_string())
            })?;
            match tokenstat_sync::device_poll(&pending).map_err(|e| e.to_string())? {
                tokenstat_sync::DeviceStatus::Pending { interval } => {
                    serde_json::to_value(DevicePollDto {
                        state: "pending",
                        interval: Some(interval),
                        handle: None,
                        host: None,
                        machine: None,
                    })
                    .map_err(|e| e.to_string())
                }
                tokenstat_sync::DeviceStatus::Confirmed(result) => {
                    with_session(s, |b| {
                        b.pending_login = None;
                        Ok(())
                    })?;
                    serde_json::to_value(DevicePollDto {
                        state: "confirmed",
                        interval: None,
                        handle: Some(result.handle),
                        host: Some(result.host),
                        machine: Some(result.machine),
                    })
                    .map_err(|e| e.to_string())
                }
            }
        }

        "account.cancelLogin" => {
            with_session(s, |b| {
                b.pending_login = None;
                Ok(())
            })?;
            Ok(json!({"cancelled": true}))
        }

        "account.logout" => {
            let host = tokenstat_sync::logout(None).map_err(|e| e.to_string())?;
            with_session(s, |b| {
                b.pending_login = None;
                Ok(())
            })?;
            Ok(json!({"host": host}))
        }

        // Long running and it talks to the network. Same rule as `scan`: not
        // from a thread that draws.
        "sync.run" => {
            let p: SyncParams = parse(params)?;
            with_session(s, |b| {
                let tz = b.engine.timezone().iana_name().map(str::to_string);
                let r = tokenstat_sync::sync(
                    b.engine.store(),
                    tokenstat_sync::SyncOptions {
                        host_flag: None,
                        prune: p.prune,
                        window: p.window.as_deref(),
                        dry_run: p.dry_run,
                        tz_name: tz.as_deref(),
                    },
                )
                .map_err(|e| e.to_string())?;
                if !r.dry_run {
                    // Same reason as the scheduled run: what the account holds
                    // just changed, and the cached grid predates it.
                    crate::account_activity::invalidate();
                }
                serde_json::to_value(SyncResultDto {
                    host: r.host,
                    rows: r.rows,
                    dry_run: r.dry_run,
                    schema_v: r.schema_v,
                    from: r.window.from,
                    to: r.window.to,
                })
                .map_err(|e| e.to_string())
            })
        }

        // Long running and it talks to the network, same rule as `sync.run`:
        // not from a thread that draws. This is the in-process path to the
        // refresh the daemon already runs on its own schedule — a machine
        // with no host agent installed has no scheduler of its own, so the
        // app asks for it.
        "pricing.refresh" => with_session(s, |b| {
            let refreshed = tokenstat_sync::pricing::refresh(false).map_err(|e| e.to_string())?;
            // The session's cached book predates this fetch. Reload it here so
            // the very next report prices against the new rates instead of the
            // empty book the session opened with.
            crate::pricing::reload(b);
            serde_json::to_value(json!({
                "effectiveFrom": refreshed.effective_from,
                "models": refreshed.models,
                "hasPrices": !b.prices.is_empty(),
            }))
            .map_err(|e| e.to_string())
        }),

        // Remote vendor usage is fetched only after an explicit user action.
        // Local log scanning remains separate and never needs the network.
        "fetch" => with_session(s, |b| {
            let tz = b.engine.timezone().clone();
            let reports = tokenstat_sync::fetch_remotes(b.engine.store_mut(), &tz, false)
                .map_err(|e| e.to_string())?;
            serde_json::to_value(reports).map_err(|e| e.to_string())
        }),

        // Workspaces are registered folders, nothing to do with the archive.
        "automation.list" => {
            serde_json::to_value(crate::automations::shared().list()).map_err(|e| e.to_string())
        }
        "automation.create" => {
            let mut p: AutomationParams = parse(params)?;
            let mut job = p.job.take().ok_or("automation.create needs job")?;
            if job.id.is_empty() {
                job.id = format!("automation-{}", now_ms());
            }
            serde_json::to_value(crate::automations::shared().create(job)?)
                .map_err(|e| e.to_string())
        }
        "automation.update" => {
            let p: AutomationParams = parse(params)?;
            serde_json::to_value(
                crate::automations::shared().update(p.job.ok_or("automation.update needs job")?)?,
            )
            .map_err(|e| e.to_string())
        }
        "automation.remove" => {
            let p: AutomationParams = parse(params)?;
            Ok(
                json!({"removed": crate::automations::shared().remove(&p.id.ok_or("automation.remove needs id")?)?}),
            )
        }
        "automation.enable" | "automation.disable" => {
            let p: AutomationParams = parse(params)?;
            let enabled = method == "automation.enable";
            serde_json::to_value(
                crate::automations::shared()
                    .set_enabled(&p.id.ok_or("automation needs id")?, enabled)?,
            )
            .map_err(|e| e.to_string())
        }
        "automation.run" => {
            let p: AutomationParams = parse(params)?;
            serde_json::to_value(
                crate::automations::shared().run(&p.id.ok_or("automation.run needs id")?)?,
            )
            .map_err(|e| e.to_string())
        }
        "automation.runs" => {
            serde_json::to_value(crate::automations::shared().runs()).map_err(|e| e.to_string())
        }
        "automation.backends" => Ok(serde_json::Value::Array(crate::automations::backends())),
        "automation.transcript" => {
            let p: AutomationParams = parse(params)?;
            let id = p.id.ok_or("automation.transcript needs a run id")?;
            let (text, next) =
                crate::automations::shared().transcript(&id, p.offset.unwrap_or(0))?;
            Ok(json!({"text": text, "nextOffset": next}))
        }
        "automation.kill" => {
            let p: AutomationParams = parse(params)?;
            crate::automations::shared()
                .kill_run(&p.id.ok_or("automation.kill needs a run id")?)?;
            Ok(json!({"killed": true}))
        }

        "todo.list" => {
            serde_json::to_value(crate::todo::shared().list()).map_err(|e| e.to_string())
        }
        "todo.create" => {
            let p: TodoParams = parse(params)?;
            let card = crate::todo::Card {
                id: String::new(),
                title: p.title.ok_or("todo.create needs a title")?,
                kind: p.kind.unwrap_or_default(),
                notes: p.notes.unwrap_or_default(),
                column: p.column.unwrap_or_else(|| "backlog".into()),
                order: p.order.unwrap_or(0),
                priority: p.priority.unwrap_or_default(),
                backend: p.backend.unwrap_or_else(|| "claude".into()),
                model: p.model,
                effort: p.effort,
                workspace_id: p.workspace_id.ok_or("todo.create needs a workspace")?,
                budget_seconds: p.budget_seconds.unwrap_or(900),
                created_at_ms: 0,
                updated_at_ms: 0,
                delegate: None,
            };
            serde_json::to_value(crate::todo::shared().create(card)?).map_err(|e| e.to_string())
        }
        "todo.update" => {
            let p: TodoParams = parse(params)?;
            let changes = crate::todo::CardUpdate {
                column: p.column,
                order: p.order,
                title: p.title,
                kind: p.kind,
                notes: p.notes,
                backend: p.backend,
                model: p.model,
                effort: p.effort,
                workspace_id: p.workspace_id,
                budget_seconds: p.budget_seconds,
            };
            serde_json::to_value(
                crate::todo::shared().update(&p.id.ok_or("todo.update needs an id")?, &changes)?,
            )
            .map_err(|e| e.to_string())
        }
        "todo.remove" => {
            let p: TodoParams = parse(params)?;
            Ok(
                json!({"removed": crate::todo::shared().remove(&p.id.ok_or("todo.remove needs an id")?)?}),
            )
        }
        "todo.delegate" => {
            let p: TodoParams = parse(params)?;
            serde_json::to_value(
                crate::todo::shared().delegate(&p.id.ok_or("todo.delegate needs an id")?)?,
            )
            .map_err(|e| e.to_string())
        }
        "todo.stop" => {
            let p: TodoParams = parse(params)?;
            serde_json::to_value(crate::todo::shared().stop(&p.id.ok_or("todo.stop needs an id")?)?)
                .map_err(|e| e.to_string())
        }

        other => match sessionless(other, params) {
            Some(result) => result,
            None => Err(format!("unknown method: {other}")),
        },
    }
}

/// Anything under the system temp directory is hidden from the workspace list.
///
/// Test repositories live there and must never appear in the user's list if a
/// test process was interrupted mid-cleanup. This used to match two known name
/// prefixes, which is exactly the wrong shape: it hid the leaks it already knew
/// about and showed every new one. A third prefix duly appeared and landed in
/// the interface. The location is the signal, not the name, and nobody keeps a
/// project they are working in inside a folder the system deletes.
fn is_test_workspace(ws: &tokenstat_workspace::Workspace) -> bool {
    let temp = std::fs::canonicalize(std::env::temp_dir()).unwrap_or_else(|_| std::env::temp_dir());
    ws.path.starts_with(temp)
}

/// Methods that never touch the session.
///
/// The pty manager is process-wide and independent of the archive, so none of
/// these need the session at all. That is not a detail: a transport keeps the
/// session behind a lock, and a terminal polls for output continuously. Routing
/// these through the lock made every keystroke queue behind whatever else was
/// running, and a `workspace.list` shells out to git three times per folder. A
/// terminal that stalls for the length of a git status is not a terminal.
///
/// `pty.spawn` is deliberately not here: it resolves a workspace id, which only
/// the session knows. It happens once per session rather than per frame.
///
/// `highlight` is here for the same reason as the terminal: it is called on a
/// keystroke debounce, and it is a pure function of the text the caller already
/// has. It deliberately takes the *buffer*, not a workspace path, so an unsaved
/// file colours correctly and so highlighting never reads the disk.
/// The registered folders, and the terminals that run in them.
///
/// A separate function, and tried before the session lock, because all of this
/// reads git and the filesystem and none of it reads the archive. It used to
/// sit behind the one daemon-wide mutex, and the cost was exactly what you
/// would expect: pressing a button to open a terminal waited for whatever scan
/// or report happened to hold the session.
///
/// Returns `None` for a method it does not own, the same shape as
/// `machine::call` and `remote::call`.
fn folders(method: &str, params: &str) -> Option<Result<Value, String>> {
    match method {
        "workspace.list" | "workspace.add" | "workspace.remove" | "workspace.rename"
        | "workspace.status" | "workspace.log" | "workspace.tree" | "workspace.show"
        | "workspace.diff" | "workspace.read" | "workspace.stage" | "workspace.unstage"
        | "workspace.commit" | "workspace.write" | "workspace.push" | "pty.spawn" => {}
        _ => return None,
    }
    Some(folder_call(method, params))
}

/// The bodies, split out so they can use `?` on a `Result`.
///
/// Each takes the registry lock only long enough to copy the folder it needs.
/// Nothing here runs a subprocess with a guard in hand.
fn folder_call(method: &str, params: &str) -> Result<Value, String> {
    match method {
        // The registered folders, and the terminals that run in them. All of
        // this reads git and the filesystem, never the archive, so none of it
        // belongs behind the session lock. It used to be, and the cost was
        // exactly what you would expect: pressing a button to open a terminal
        // waited for whatever scan or report happened to hold the session.
        //
        // Each arm takes the registry lock only long enough to copy the folder
        // it needs. Nothing below runs a subprocess with a guard in hand.
        //
        // Git is read for each on every list: a status call is cheap, and a
        // cached one that lies about a dirty tree is worse than none.
        "workspace.list" => {
            let folders: Vec<tokenstat_workspace::Workspace> = crate::workspaces::read()
                .workspaces
                .iter()
                .filter(|ws| !is_test_workspace(ws))
                .cloned()
                .collect();
            // One thread per folder. Reading git means three subprocesses, and
            // doing that serially made the whole list cost the sum of every
            // repository rather than the slowest one. The folders are
            // independent, so there is nothing to coordinate.
            let dtos: Vec<WorkspaceDto> = std::thread::scope(|scope| {
                let handles: Vec<_> = folders
                    .iter()
                    .map(|ws| scope.spawn(move || describe(ws)))
                    .collect();
                handles
                    .into_iter()
                    // A panic reading one folder must not lose the others, and
                    // there is nothing useful to say about it here.
                    .filter_map(|h| h.join().ok())
                    .collect()
            });
            serde_json::to_value(dtos).map_err(|e| e.to_string())
        }

        "workspace.add" => {
            let p: WorkspacePathParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let ws = {
                let mut registry = crate::workspaces::write();
                let ws = registry
                    .add(std::path::Path::new(&p.path), now_ms())
                    .map_err(|e| e.to_string())?;
                crate::workspaces::save(&registry)?;
                ws
            };
            // Described after the guard is dropped: this runs git.
            serde_json::to_value(describe(&ws)).map_err(|e| e.to_string())
        }

        // Forgets the entry. Never touches the folder.
        "workspace.remove" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let mut registry = crate::workspaces::write();
            let removed = registry.remove(&p.id);
            if removed {
                crate::workspaces::save(&registry)?;
            }
            Ok(json!({"removed": removed}))
        }

        "workspace.rename" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let name = p.name.unwrap_or_default();
            let mut registry = crate::workspaces::write();
            let renamed = registry.rename(&p.id, &name);
            if renamed {
                crate::workspaces::save(&registry)?;
            }
            Ok(json!({"renamed": renamed}))
        }

        "workspace.status" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let ws = crate::workspaces::get(&p.id)?;
            serde_json::to_value(describe(&ws)).map_err(|e| e.to_string())
        }

        // Recent commits. Separate from `workspace.status` because status runs
        // on a file-change timer and history does not change nearly as often,
        // so joining them would spawn a `git log` every time a file is saved.
        "workspace.log" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            // Enough to scroll, few enough that a repository with a decade of
            // history does not send its whole life over the bridge.
            let limit = p.limit.unwrap_or(100).min(500);
            let ws = crate::workspaces::get(&p.id)?;
            let commits = if ws.exists() {
                tokenstat_workspace::git::log(&ws.path, limit)
            } else {
                Vec::new()
            };
            serde_json::to_value(commits).map_err(|e| e.to_string())
        }

        // One directory of the file tree. Lazy per directory: a monorepo has
        // hundreds of thousands of files and nobody looks at more than one
        // level at a time.
        "workspace.tree" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let relative = p.path.unwrap_or_default();
            let ws = crate::workspaces::folder(&p.id)?;
            let entries =
                tokenstat_workspace::tree::list(&ws.path, &relative).map_err(|e| e.to_string())?;
            serde_json::to_value(entries).map_err(|e| e.to_string())
        }

        // One commit in full. Separate from `workspace.log`, which is a list:
        // reading every commit's diff to draw a list would be absurd.
        "workspace.show" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let rev = p.path.ok_or("workspace.show needs a commit id")?;
            let ws = crate::workspaces::folder(&p.id)?;
            match tokenstat_workspace::git::show(&ws.path, &rev) {
                Some(detail) => serde_json::to_value(detail).map_err(|e| e.to_string()),
                None => Err(format!("no commit {rev} in this workspace")),
            }
        }

        "workspace.diff" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let path = p.path.ok_or("workspace.diff needs a path")?;
            let ws = crate::workspaces::folder(&p.id)?;
            let diff = tokenstat_workspace::git::diff(&ws.path, &path);
            serde_json::to_value(diff).map_err(|e| e.to_string())
        }

        "workspace.read" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let path = p.path.ok_or("workspace.read needs a path")?;
            let ws = crate::workspaces::folder(&p.id)?;
            let content =
                tokenstat_workspace::tree::read_text(&ws.path, &path).map_err(|e| e.to_string())?;
            serde_json::to_value(json!({"path": path, "content": content}))
                .map_err(|e| e.to_string())
        }

        // Everything below changes the repository. These exist because the app
        // is a place to work, not a reporter: they run when someone presses a
        // button and are never reachable from a timer or a status path. See
        // `tokenstat_workspace::gitwrite`.
        "workspace.stage" | "workspace.unstage" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let paths = p.paths.unwrap_or_default();
            let staging = method == "workspace.stage";
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = if staging {
                tokenstat_workspace::gitwrite::stage(&ws.path, &paths)
            } else {
                tokenstat_workspace::gitwrite::unstage(&ws.path, &paths)
            };
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        "workspace.commit" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let message = p.message.unwrap_or_default();
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = tokenstat_workspace::gitwrite::commit(&ws.path, &message);
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        "workspace.write" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let path = p.path.ok_or("workspace.write needs a path")?;
            let content = p.content.ok_or("workspace.write needs content")?;
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = tokenstat_workspace::gitwrite::write_text(&ws.path, &path, &content);
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        "workspace.push" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = tokenstat_workspace::gitwrite::push(&ws.path);
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        // Terminals. The process is owned here rather than by the front end,
        // which is what lets an iPad watch a session running on a Mac and what
        // keeps an automation alive after a window closes.
        //
        // This is the arm the session lock hurt most. Spawning a shell is a
        // fork away, but it used to queue behind every scan and report first,
        // so opening a terminal took tens of seconds on a busy daemon.
        "pty.spawn" => {
            let p: PtySpawnParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            // A workspace on another machine: spawn there through the peer's
            // own daemon and hand back the session namespaced to this machine,
            // so the caller can poll, type and resize it like a local one.
            if let Some((peer, workspace)) = split_remote(&p.workspace_id) {
                let forwarded = json!({
                    "workspaceId": workspace,
                    "command": p.command,
                    "args": p.args,
                    "rows": p.rows,
                    "cols": p.cols,
                    "noColor": p.no_color,
                });
                let mut value =
                    crate::remote::call_peer_result(peer, "pty.spawn", &forwarded.to_string())?;
                renamespace_session(&mut value, peer);
                // A session just appeared on the peer; the cached pty list
                // must not hide it from the parity watch for another 30s.
                crate::remote_stream::invalidate_pty_list(peer);
                return Ok(value);
            }
            let ws = crate::workspaces::folder(&p.workspace_id)?;
            let info = tokenstat_pty::manager()
                .spawn(&tokenstat_pty::Spawn {
                    command: p.command.clone(),
                    args: p.args.clone(),
                    cwd: ws.path.clone(),
                    workspace_id: Some(ws.id.clone()),
                    rows: p.rows,
                    cols: p.cols,
                    no_color: p.no_color,
                })
                .map_err(|e| e.to_string())?;
            serde_json::to_value(info).map_err(|e| e.to_string())
        }
        // `folders` filtered these, so nothing else can arrive.
        other => Err(format!("unknown folder method: {other}")),
    }
}

fn sessionless(method: &str, params: &str) -> Option<Result<Value, String>> {
    // Identity and the peer list. Sessionless because the Machines screen is
    // where somebody goes when something is wrong, and an archive that will not
    // open must not take it away from them.
    if let Some(answer) = crate::machine::call(method, params) {
        return Some(answer);
    }

    // Serving and reaching other machines. None of these read the archive, and
    // a call being forwarded to an idle machine must not queue behind a scan
    // running on this one.
    if let Some(answer) = crate::remote::call(method, params) {
        return Some(answer);
    }

    // Folders and terminals. Same reasoning: none of it reads the archive.
    if let Some(answer) = folders(method, params) {
        return Some(answer);
    }

    Some(match method {
        // Where a daemon on this machine would be listening.
        //
        // A client needs this before it has a connection, so it is answered by
        // the in-process transport and is sessionless by necessity. It exists
        // so no front end reimplements the data directory rules: a client that
        // computed the path itself would silently look in the wrong place on
        // the day those rules change, and report "no daemon" rather than a
        // mismatch.
        "host.socketPath" => crate::server::default_socket_path()
            .map(|path| json!({"path": path.display().to_string()})),

        "highlight" => highlight(params),

        "highlight.syntax" => serde_json::from_str::<HighlightParams>(params.trim())
            .map_err(|e| e.to_string())
            .and_then(|p| {
                let Some(language) = p.language() else {
                    return Ok(json!({"language": Value::Null}));
                };
                serde_json::to_value(json!({
                    "language": language.id(),
                    "syntax": language.syntax(),
                }))
                .map_err(|e| e.to_string())
            }),

        // The app only asks whether a release exists. Applying an update to an
        // installed application needs its signed installer and is deliberately
        // left to the release updater, not the daemon process.
        "app.updateCheck" => tokenstat_sync::check_latest()
            .map(|check| {
                json!({
                    "current": check.current,
                    "latest": check.latest,
                    "newer": check.newer,
                    "htmlUrl": check.html_url,
                    // The disk image itself, so the app can offer the download
                    // rather than the release page it is one click inside.
                    "dmgUrl": check.app_dmg_url,
                })
            })
            .map_err(|e| e.to_string()),

        // Fetch the disk image and prove it is the one the release published.
        //
        // Stops at a verified file on disk. Mounting it, checking who signed it
        // and replacing the application are the app's, because those need
        // Apple's own tools and knowledge of where the running bundle lives,
        // neither of which a daemon should be guessing at.
        "app.updateDownload" => tokenstat_sync::download_app_image()
            .map(|path| json!({"path": path.display().to_string()}))
            .map_err(|e| e.to_string()),

        "sync.scheduleStatus" => sync_schedule_status(),

        // What each vendor says is left of its plan. Not derived from the
        // archive: these are the vendor's own numbers about a quota, and a
        // percentage we worked out ourselves would be a guess wearing a
        // number's clothes.
        //
        // Codex reads off the disk and is instant. The other providers make a
        // request, so this is a refresh rather than something to poll.
        //
        // Sessionless, and that is the important part. Five vendor requests
        // with timeouts measured in tens of seconds used to run while holding
        // the session, so one unreachable vendor froze reports, the workspace
        // list and every other screen for as long as it took to give up. None
        // of this reads the archive.
        "usage.limits" => Ok(usage_limits()),

        "pty.list" => {
            let include_remote = serde_json::from_str::<PtyListParams>(params.trim())
                .map(|p| p.include_remote)
                .unwrap_or(true);
            let mut items: Vec<Value> = match serde_json::to_value(tokenstat_pty::manager().list())
            {
                Ok(Value::Array(items)) => items,
                Ok(_) => return Some(Err("pty.list returned a non-array".into())),
                Err(e) => return Some(Err(e.to_string())),
            };
            if include_remote {
                // One level deep on purpose: each peer is asked with
                // includeRemote=false, so the account cannot recurse A→B→A,
                // and cached so the app's parity poll does not dial every
                // peer on every tick.
                items.extend(crate::remote_stream::remote_pty_lists());
            }
            Ok(Value::Array(items))
        }

        "pty.info" => {
            if let Some(answer) = route_remote_pty("pty.info", params) {
                return Some(answer);
            }
            pty_id(params).and_then(|p| {
                let info = tokenstat_pty::manager()
                    .info(&p.id)
                    .map_err(|e| e.to_string())?;
                serde_json::to_value(info).map_err(|e| e.to_string())
            })
        }

        // Poll for output. Returns immediately, so the caller sets the pace.
        // `dropped` is non-zero when the reader fell behind the buffer, and a
        // terminal should say so rather than pretend the output never existed.
        "pty.read" => {
            // A remote session reads from a pushed cache when a subscription
            // is live, so the poll loop is local and the remote hop happened
            // in the background. Falls back to forwarding when there is no
            // subscription yet or it ended.
            if let Ok(parsed) = serde_json::from_str::<PtyIdParams>(params.trim())
                && let Some((peer, session)) = split_remote(&parsed.id)
            {
                crate::remote_stream::ensure_pty_subscription(peer, session);
                if let Some(answer) =
                    crate::remote_stream::cached_pty_read(peer, session, parsed.offset)
                {
                    return Some(Ok(answer));
                }
            }
            if let Some(answer) = route_remote_pty("pty.read", params) {
                return Some(answer);
            }
            pty_id(params).and_then(|p| {
                let chunk = tokenstat_pty::manager()
                    .read(&p.id, p.offset)
                    .map_err(|e| e.to_string())?;
                Ok(json!({
                    "data": crate::base64::encode(&chunk.bytes),
                    "nextOffset": chunk.next_offset,
                    "dropped": chunk.dropped,
                }))
            })
        }

        "pty.write" => {
            // Keystrokes to a subscribed remote session ride the session's
            // channel instead of a request round trip per key.
            if let Ok(parsed) = serde_json::from_str::<PtyIdParams>(params.trim())
                && let Some((peer, session)) = split_remote(&parsed.id)
                && let Some(data) = parsed.data
            {
                match crate::base64::decode(&data) {
                    Ok(bytes) => match crate::remote_stream::write_pty_input(peer, session, &bytes)
                    {
                        Ok(true) => return Some(Ok(json!({"written": bytes.len()}))),
                        Ok(false) => {}
                        Err(error) => return Some(Err(error)),
                    },
                    Err(error) => return Some(Err(error)),
                }
            }
            if let Some(answer) = route_remote_pty("pty.write", params) {
                return Some(answer);
            }
            pty_id(params).and_then(|p| {
                let data = p.data.ok_or("pty.write needs base64 data")?;
                let bytes = crate::base64::decode(&data)?;
                tokenstat_pty::manager()
                    .write(&p.id, &bytes)
                    .map_err(|e| e.to_string())?;
                Ok(json!({"written": bytes.len()}))
            })
        }

        "pty.resize" => {
            if let Some(answer) = route_remote_pty("pty.resize", params) {
                return Some(answer);
            }
            pty_id(params).and_then(|p| {
                let (rows, cols) = match (p.rows, p.cols) {
                    (Some(r), Some(c)) => (r, c),
                    _ => return Err("pty.resize needs rows and cols".into()),
                };
                tokenstat_pty::manager()
                    .resize(&p.id, rows, cols)
                    .map_err(|e| e.to_string())?;
                Ok(json!({"rows": rows, "cols": cols}))
            })
        }

        "pty.kill" => {
            if let Some(answer) = route_remote_pty("pty.kill", params) {
                return Some(answer);
            }
            pty_id(params).and_then(|p| {
                tokenstat_pty::manager()
                    .kill(&p.id)
                    .map_err(|e| e.to_string())?;
                Ok(json!({"killed": true}))
            })
        }

        "pty.close" => {
            if let Ok(parsed) = serde_json::from_str::<PtyIdParams>(params.trim())
                && let Some((peer, _)) = split_remote(&parsed.id)
            {
                crate::remote_stream::invalidate_pty_list(peer);
            }
            if let Some(answer) = route_remote_pty("pty.close", params) {
                return Some(answer);
            }
            pty_id(params).and_then(|p| {
                tokenstat_pty::manager()
                    .close(&p.id)
                    .map_err(|e| e.to_string())?;
                Ok(json!({"closed": true}))
            })
        }

        // What can be launched in a workspace on this machine. The app answers
        // this from its own PATH for a local folder; a remote folder asks the
        // machine that owns it through `remote.call`, so the launcher always
        // means the machine the session would actually run on.
        "launcher.catalog" => Ok(crate::launcher::catalog()),

        // Remove a machine from the account directory. The server deletes its
        // uploaded rows, so this is an explicit action for a machine id that
        // is stale (a reinstall) or otherwise holding a machine-cap slot.
        "account.unlinkMachine" => {
            #[derive(Deserialize)]
            struct UnlinkParams {
                id: String,
            }
            let p: UnlinkParams = match serde_json::from_str(params.trim()) {
                Ok(p) => p,
                Err(e) => return Some(Err(e.to_string())),
            };
            if let Err(e) = tokenstat_sync::profile::unlink_machine(None, &p.id) {
                return Some(Err(e.to_string()));
            }
            crate::account_activity::invalidate();
            Ok(json!({"removed": true}))
        }

        // A byte stream between machines. Runs on the machine that owns the
        // resource: it reserves a stream and returns a token; the caller then
        // dials a fresh connection and claims it with `{"stream": token}` as
        // its first message.
        "stream.open" => stream_open(params),

        // Bind a loopback port here and bridge every accepted connection to a
        // proxy stream on the peer, so a browser tab can reach a service on
        // the other machine's own localhost. The listener binds loopback only.
        "proxy.listen" => proxy_listen(params),

        _ => return None,
    })
}

/// Ask every vendor what is left of its plan.
///
/// One refresh at a time, and that lock is the only thing this serializes
/// against. The session used to provide the same guarantee by accident, and it
/// charged every other screen for it. Two screens asking at once should share
/// the wait, not fan out ten requests.
fn usage_limits() -> Value {
    static REFRESH: Mutex<()> = Mutex::new(());
    let _one_at_a_time = REFRESH.lock().unwrap_or_else(PoisonError::into_inner);

    let providers = std::thread::scope(|scope| {
        let claude = scope.spawn(tokenstat_sync::claude_limits::fetch);
        let cursor = scope.spawn(tokenstat_sync::cursor::limits);
        let grok = scope.spawn(tokenstat_sync::grok_limits::fetch);
        let opencode = scope.spawn(tokenstat_sync::opencode_limits::fetch);
        let antigravity = scope.spawn(tokenstat_sync::antigravity_ide::limits);
        let codex = tokenstat_core::limits::codex_limits();
        let claude = claude.join().unwrap_or_else(|_| {
            tokenstat_core::limits::ProviderLimits::unavailable(
                "claude_code",
                "Reading the Claude Code limits failed unexpectedly.",
            )
        });
        let cursor = cursor.join().unwrap_or_else(|_| {
            tokenstat_core::limits::ProviderLimits::unavailable(
                "cursor",
                "Reading the Cursor limits failed unexpectedly.",
            )
        });
        let grok = grok.join().unwrap_or_else(|_| {
            tokenstat_core::limits::ProviderLimits::unavailable(
                "grok",
                "Reading the Grok limits failed unexpectedly.",
            )
        });
        let opencode = opencode.join().unwrap_or_else(|_| {
            tokenstat_core::limits::ProviderLimits::unavailable(
                "opencode",
                "Reading the OpenCode limits failed unexpectedly.",
            )
        });
        let antigravity = antigravity.join().unwrap_or_else(|_| {
            tokenstat_core::limits::ProviderLimits::unavailable(
                "antigravity",
                "Reading the Antigravity limits failed unexpectedly.",
            )
        });
        vec![claude, codex, cursor, grok, opencode, antigravity]
    });
    // A vendor that could not be read this time is not a vendor whose quota is
    // unknown. Remember every real reading and hand back the last one, marked
    // stale and dated, when a refresh comes back with only a reason.
    tokenstat_core::limits::cache::store(&providers);
    let providers = tokenstat_core::limits::cache::backfill(providers);
    // Every field here is plain data the vendors just returned, so the only way
    // this fails is a bug in the DTO, and an empty list says that plainly.
    serde_json::to_value(providers).unwrap_or_else(|_| json!([]))
}

fn sync_schedule_status() -> Result<Value, String> {
    let info = tokenstat_sync::scheduling_info(None).map_err(|e| e.to_string())?;
    let due = info.next_allowed_at.as_deref().is_none_or(|next| {
        next.parse::<jiff::Timestamp>()
            .map(|at| jiff::Timestamp::now() >= at)
            .unwrap_or(true)
    });
    Ok(json!({
        "loggedIn": info.logged_in,
        "cliScheduleActive": tokenstat_sync::cli_sync_schedule_active(),
        "due": due,
    }))
}

fn pty_id(params: &str) -> Result<PtyIdParams, String> {
    serde_json::from_str(params.trim()).map_err(|e| e.to_string())
}

/// `stream.open`: reserve a byte stream on this machine and hand out the token
/// the caller claims it with. The pump starts immediately and waits for the
/// connection, so `proxy` and `pty.subscribe` are ready the moment the token
/// is sent back over the call channel.
fn stream_open(params: &str) -> Result<Value, String> {
    let p: StreamOpenParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let kind = match p.kind.as_str() {
        "proxy" => {
            let host = p.host.unwrap_or_else(|| "127.0.0.1".to_string());
            // The proxy bridges to the far machine's own loopback: the point
            // is "reach the service on that computer", not "use that computer
            // as a gateway into its network". Anything else is refused.
            if !matches!(host.as_str(), "127.0.0.1" | "localhost" | "::1" | "[::1]") {
                return Err("proxy target must be on the far machine's own loopback".into());
            }
            let port = p.port.ok_or("proxy stream needs a port")?;
            crate::remote_stream::StreamKind::Proxy { host, port }
        }
        "pty.subscribe" => {
            let session = p.id.ok_or("pty.subscribe needs a session id")?;
            // The session must exist here; the pump reads it by offset.
            tokenstat_pty::manager()
                .info(&session)
                .map_err(|e| e.to_string())?;
            crate::remote_stream::StreamKind::PtySubscribe { session }
        }
        other => return Err(format!("unknown stream kind {other}")),
    };
    let token = crate::remote_stream::open(kind)?;
    Ok(json!({"token": token}))
}

/// `proxy.listen`: bind a loopback port on this machine and bridge every
/// accepted connection to a proxy stream on the peer. Loopback only, so
/// nothing on this machine's network is exposed; the caller (a browser tab)
/// talks to the port as if the service were local.
fn proxy_listen(params: &str) -> Result<Value, String> {
    let p: ProxyListenParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("could not bind a loopback port: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let peer = p.peer;
    let host = p.host.unwrap_or_else(|| "127.0.0.1".to_string());
    let target = p.port;

    // Replacing the same target stops the previous bridge, and a cap bounds
    // how many listeners a session of clicking can accumulate. Without this
    // every Browse click leaked a listener and a parked thread forever.
    let key = format!("{peer}:{host}:{target}");
    let mut registry = proxy_listeners().lock().map_err(|e| e.to_string())?;
    if let Some(stop) = registry.remove(&key) {
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
    }
    if registry.len() >= MAX_PROXY_LISTENERS {
        return Err(format!(
            "too many local port bridges (max {MAX_PROXY_LISTENERS}); close some browser tabs"
        ));
    }
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    registry.insert(key.clone(), std::sync::Arc::clone(&stop));
    drop(registry);

    let _ = listener.set_nonblocking(true);
    std::thread::spawn(move || {
        loop {
            if stop.load(std::sync::atomic::Ordering::Relaxed) {
                break;
            }
            match listener.accept() {
                Ok((tcp, _)) => {
                    let _ = tcp.set_nodelay(true);
                    match crate::remote_stream::open_proxy_stream(&peer, &host, target) {
                        Ok(connection) => crate::remote_stream::pump_local(tcp, connection),
                        Err(error) => {
                            eprintln!("remote proxy: {peer} {host}:{target} failed: {error}");
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(_) => break,
            }
        }
        if let Ok(mut registry) = proxy_listeners().lock() {
            registry.remove(&key);
        }
    });
    Ok(json!({"url": format!("http://127.0.0.1:{port}/")}))
}

/// How many loopback bridges a daemon will hold at once. Browsed ports are
/// cheap but not free, and each one parks a thread.
const MAX_PROXY_LISTENERS: usize = 16;

fn proxy_listeners()
-> &'static Mutex<std::collections::HashMap<String, std::sync::Arc<std::sync::atomic::AtomicBool>>>
{
    static LISTENERS: std::sync::OnceLock<
        Mutex<std::collections::HashMap<String, std::sync::Arc<std::sync::atomic::AtomicBool>>>,
    > = std::sync::OnceLock::new();
    LISTENERS.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

// MARK: - Remote pty routing

/// A resource id namespaced to another machine: `remote:<peer hex>:<inner>`.
///
/// The same prefix the app uses for remote folder ids, so a terminal spawned
/// in a remote folder and a session listed from a peer read as one namespace
/// and group under the remote folder in the sidebar.
const REMOTE_PREFIX: &str = "remote:";

fn split_remote(value: &str) -> Option<(&str, &str)> {
    value.strip_prefix(REMOTE_PREFIX)?.split_once(':')
}

fn remote_id(peer: &str, inner: &str) -> String {
    format!("{REMOTE_PREFIX}{peer}:{inner}")
}

/// Rewrite a peer's session info so it reads as one of this machine's: the id
/// gains the peer namespace and the workspace id becomes the same
/// `remote:<peer>:<id>` the app's folder list uses.
pub(crate) fn renamespace_session(value: &mut Value, peer: &str) {
    let Some(obj) = value.as_object_mut() else {
        return;
    };
    if let Some(id) = obj.get("id").and_then(Value::as_str) {
        obj.insert("id".into(), json!(remote_id(peer, id)));
    }
    if let Some(workspace) = obj.get("workspaceId").and_then(Value::as_str) {
        obj.insert("workspaceId".into(), json!(remote_id(peer, workspace)));
    }
}

/// Forward a pty method whose session id belongs to another machine. Returns
/// `None` when the id is local or unparseable, so the caller falls through to
/// the local manager.
fn route_remote_pty(method: &str, params: &str) -> Option<Result<Value, String>> {
    let parsed: PtyIdParams = serde_json::from_str(params.trim()).ok()?;
    let (peer, inner) = split_remote(&parsed.id)?;
    Some((|| {
        let mut forwarded: Value =
            serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
        forwarded["id"] = json!(inner);
        let mut value = crate::remote::call_peer_result(peer, method, &forwarded.to_string())?;
        if method == "pty.info" {
            renamespace_session(&mut value, peer);
        }
        Ok(value)
    })())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct PtyListParams {
    include_remote: bool,
}

impl Default for PtyListParams {
    fn default() -> Self {
        Self {
            include_remote: true,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StreamOpenParams {
    kind: String,
    id: Option<String>,
    host: Option<String>,
    port: Option<u16>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProxyListenParams {
    peer: String,
    host: Option<String>,
    port: u16,
}

/// Colour a buffer.
///
/// Answers with `spans: []` and a reason rather than failing when the language
/// is unknown or the file is too large. Both are ordinary states of an editor,
/// and an error would put a red banner over a file that opened perfectly well
/// and simply is not colourable.
fn highlight(params: &str) -> Result<Value, String> {
    let p: HighlightParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let Some(language) = p.language() else {
        return Ok(json!({
            "language": Value::Null,
            "spans": [],
            "note": "No grammar for this file type.",
        }));
    };
    match tokenstat_highlight::spans(language, &p.text) {
        Ok(spans) => Ok(json!({
            "language": language.id(),
            "syntax": language.syntax(),
            "spans": spans,
            "note": Value::Null,
        })),
        Err(e) => Ok(json!({
            "language": language.id(),
            "syntax": language.syntax(),
            "spans": [],
            "note": e.to_string(),
        })),
    }
}

/// Answer a call that needs no session, or `None` when it needs one.
///
/// Transports call this **before** taking whatever lock guards their session.
/// See [`sessionless`] for why that matters.
pub fn call_sessionless(method: &str, params: &str) -> Option<String> {
    sessionless(method, params).map(|result| match result {
        Ok(v) => ok(v),
        Err(e) => err("call_failed", e),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A clock alone is not unique enough: two threads entering within the same
    /// tick would build the same path and fight over one SQLite file.
    static SEQ: AtomicU64 = AtomicU64::new(0);

    /// The identity directory is chosen by a process-wide environment
    /// variable, so the tests that point it at their own temp directory must
    /// not run at the same time: two stores at once would read each other's
    /// identity and approvals, and the failure would look like a refusal bug
    /// rather than a harness bug. `tokenstat-remote`'s handshake test chose to
    /// fold into one function for the same reason; these stay separate and
    /// take the lock instead. Poisoned by a panicking test, which must not
    /// take the rest of the suite down with it.
    static IDENTITY_LOCK: Mutex<()> = Mutex::new(());

    /// A fresh archive per test.
    ///
    /// Sessions are no longer a process-wide singleton, so these run in
    /// parallel again. While they were, every test that touched one had to
    /// take a lock first.
    fn session() -> Session {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-host-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Session::open(&OpenParams {
            db_path: Some(dir.join("tokenstat.db").display().to_string()),
            timezone: Some("UTC".into()),
        })
        .expect("open temp archive")
    }

    #[test]
    fn every_response_is_a_decodable_envelope() {
        let mut s = session();
        // Including the failure paths: a front end must never have to guess
        // whether it got JSON back.
        for (method, params) in [
            ("info", "{}"),
            ("nonsense", "{}"),
            ("totals", "not json at all"),
            ("report", "{}"),
            ("automation.list", "{}"),
        ] {
            let out = call(&mut s, method, params);
            let v: Value = serde_json::from_str(&out)
                .unwrap_or_else(|e| panic!("{method} returned non-JSON: {out} ({e})"));
            assert!(v["ok"].is_boolean(), "{method} lacks ok: {out}");
            if v["ok"] == false {
                assert!(v["error"]["message"].is_string(), "{method}: {out}");
            }
        }
    }

    #[test]
    fn the_terminal_hot_path_never_needs_the_session() {
        // Both transports keep the session behind a mutex, so anything routed
        // through it serializes against archive reads and against `git status`
        // for every registered folder. A terminal polls for output continuously
        // and cannot wait behind that. If a method moves off this list, typing
        // in a terminal starts stalling whenever anything else runs, and the
        // symptom looks nothing like the cause.
        for method in [
            "pty.list",
            "pty.info",
            "pty.read",
            "pty.write",
            "pty.resize",
            "pty.kill",
            "pty.close",
            // The editor re-highlights on a keystroke debounce, so it is on the
            // same footing as the terminal. It is also a pure function of the
            // text the caller sent, so it has nothing to ask the session about.
            "highlight",
            "highlight.syntax",
            // Asked before a client has a connection to ask over, so it can
            // never be behind a session.
            "host.socketPath",
            // The Machines screen has to answer on a machine whose archive
            // will not open, because that is when somebody goes looking at it.
            "machine.peers",
        ] {
            let out = call_sessionless(method, r#"{"id":"pty-none"}"#)
                .unwrap_or_else(|| panic!("{method} must be answerable without a session"));
            let v: Value = serde_json::from_str(&out)
                .unwrap_or_else(|e| panic!("{method} returned non-JSON: {out} ({e})"));
            assert!(v["ok"].is_boolean(), "{method} lacks ok: {out}");
        }

        // `usage.limits` belongs on that list too, for a stronger reason: it
        // makes five vendor requests with timeouts in the tens of seconds, and
        // behind the session it froze every other screen for the length of the
        // slowest one. It is not exercised here because calling it would make
        // those requests from the test suite.

        // `pty.spawn` is on the list too, and that is the point of the folder
        // registry living outside the session. Spawning a shell is a fork away,
        // but while the workspace lookup needed the session it queued behind
        // every scan and report first, and opening a terminal took tens of
        // seconds on a busy daemon. Empty params fail to parse, so this reaches
        // the envelope without starting a process.
        let out = call_sessionless("pty.spawn", "{}")
            .expect("pty.spawn must be answerable without a session");
        let v: Value = serde_json::from_str(&out).expect("pty.spawn returned non-JSON");
        assert!(v["ok"].is_boolean(), "pty.spawn lacks ok: {out}");

        // The folder methods are sessionless for the same reason. Not called
        // here: `workspace.list` runs git over whatever this machine actually
        // has registered, which is not a test's business.
        assert!(
            folders("workspace.list", "{}").is_some(),
            "workspace.list must not need the session"
        );

        // Anything that reads the archive still does.
        // Pricing talks to the network and mutates the session's cached book,
        // so it needs the lock like any other state-changing call.
        for method in ["info", "totals", "pricing.refresh"] {
            assert!(
                call_sessionless(method, "{}").is_none(),
                "{method} must not bypass the session"
            );
        }
    }

    /// The whole peer lifecycle over the real store, in one process.
    ///
    /// One test rather than six, because the states only mean anything in
    /// sequence: the claim being pinned is that trust goes up only when
    /// somebody says so and comes straight back down when they change their
    /// mind. `TOKENSTAT_IDENTITY_DIR` keeps it out of the developer's own
    /// peer list, which is a thing a test has no business writing to.
    #[test]
    fn a_peer_is_paired_revoked_and_forgotten() {
        // The identity directory is process-wide, so this and the other
        // tests that set TOKENSTAT_IDENTITY_DIR take IDENTITY_LOCK for the
        // whole test. See the lock's comment.
        let _identity_guard = IDENTITY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-identity-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", &dir) };

        // A machine has an identity the first time it is asked, with no setup
        // step and no empty state to explain.
        let me: Value =
            serde_json::from_str(&call_sessionless("machine.identity", "{}").expect("sessionless"))
                .expect("json");
        assert!(me["ok"].as_bool().unwrap_or(false), "{me}");
        let my_key = me["result"]["key"].as_str().expect("key").to_string();
        assert_eq!(my_key.len(), 64, "a public key is 32 bytes of hex");
        assert!(
            me["result"]["fingerprint"]
                .as_str()
                .is_some_and(|f| f.contains('-'))
        );

        // Any 32 bytes are a valid X25519 public key, so a fixed stranger key
        // is the cheapest real key to pin. It must not be this machine's own
        // key: pairing with yourself is now refused, because it is a loop
        // nobody can click by accident.
        let stranger = "01".repeat(32);
        let paired: Value = serde_json::from_str(
            &call_sessionless(
                "machine.pair",
                &json!({"key": stranger, "label": "desk"}).to_string(),
            )
            .expect("sessionless"),
        )
        .expect("json");
        assert!(paired["ok"].as_bool().unwrap_or(false), "{paired}");
        assert_eq!(
            paired["result"]["trust"], "approved",
            "typing a key is the approval"
        );
        assert_eq!(paired["result"]["label"], "desk");

        let listed: Value =
            serde_json::from_str(&call_sessionless("machine.peers", "{}").expect("sessionless"))
                .expect("json");
        assert_eq!(listed["result"].as_array().map(Vec::len), Some(1));
        assert_eq!(listed["result"][0]["key"], stranger);

        // Revoking leaves the record, so the same key coming back is known as
        // one that was turned away rather than arriving as a stranger.
        let revoked: Value = serde_json::from_str(
            &call_sessionless("machine.revoke", &json!({"key": stranger}).to_string())
                .expect("sessionless"),
        )
        .expect("json");
        assert_eq!(revoked["result"]["changed"], true);
        let listed: Value =
            serde_json::from_str(&call_sessionless("machine.peers", "{}").expect("sessionless"))
                .expect("json");
        assert_eq!(listed["result"][0]["trust"], "revoked");

        let forgotten: Value = serde_json::from_str(
            &call_sessionless("machine.forget", &json!({"key": stranger}).to_string())
                .expect("sessionless"),
        )
        .expect("json");
        assert_eq!(forgotten["result"]["forgotten"], true);
        let listed: Value =
            serde_json::from_str(&call_sessionless("machine.peers", "{}").expect("sessionless"))
                .expect("json");
        assert_eq!(listed["result"].as_array().map(Vec::len), Some(0));

        // A fingerprint where a key belongs is the likeliest paste error, and
        // it has to fail rather than pin nothing.
        let bad: Value = serde_json::from_str(
            &call_sessionless("machine.pair", &json!({"key": "1234-5678"}).to_string())
                .expect("sessionless"),
        )
        .expect("json");
        assert_eq!(bad["ok"], false, "{bad}");

        unsafe { std::env::remove_var("TOKENSTAT_IDENTITY_DIR") };
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Pinning your own key is a loop somebody can only hit by accident, and
    /// every path (typed, pasted, account-supplied) answers the same way.
    #[test]
    fn pairing_with_your_own_key_is_refused() {
        // See IDENTITY_LOCK: the environment variable is process-wide, so the
        // identity tests are serialised rather than racing each other's dirs.
        let _identity_guard = IDENTITY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-identity-self-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", &dir) };

        let me: Value =
            serde_json::from_str(&call_sessionless("machine.identity", "{}").expect("sessionless"))
                .expect("json");
        let my_key = me["result"]["key"].as_str().expect("key").to_string();

        let paired: Value = serde_json::from_str(
            &call_sessionless(
                "machine.pair",
                &json!({"key": my_key, "label": "desk"}).to_string(),
            )
            .expect("sessionless"),
        )
        .expect("json");
        assert_eq!(
            paired["ok"], false,
            "self-pairing must be refused: {paired}"
        );
        assert!(
            paired["error"]["message"]
                .as_str()
                .is_some_and(|m| m.contains("own key")),
            "{paired}"
        );

        unsafe { std::env::remove_var("TOKENSTAT_IDENTITY_DIR") };
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A machine can be called something, and the name survives the rename
    /// round trip without touching the key.
    ///
    /// The key is what a peer pinned, so the property worth asserting is not
    /// that the name changed but that renaming did not make this a different
    /// machine to anybody who already trusts it.
    #[test]
    fn naming_a_machine_leaves_its_identity_alone() {
        // See IDENTITY_LOCK: the environment variable is process-wide, so the
        // identity tests are serialised rather than racing each other's dirs.
        let _identity_guard = IDENTITY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-name-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", &dir) };

        let before: Value =
            serde_json::from_str(&call_sessionless("machine.identity", "{}").expect("sessionless"))
                .expect("json");
        let key = before["result"]["key"].as_str().expect("key").to_string();
        assert_eq!(before["result"]["labelIsChosen"], false);

        let named: Value = serde_json::from_str(
            &call_sessionless(
                "machine.rename",
                &json!({"name": " the desk one "}).to_string(),
            )
            .expect("sessionless"),
        )
        .expect("json");
        assert!(named["ok"].as_bool().unwrap_or(false), "{named}");
        assert_eq!(named["result"]["label"], "the desk one", "trimmed");
        assert_eq!(named["result"]["labelIsChosen"], true);
        assert_eq!(named["result"]["key"], key, "renaming is not a new machine");

        // Blank is the undo, and it puts the computer's own name back rather
        // than leaving a machine called "".
        let cleared: Value = serde_json::from_str(
            &call_sessionless("machine.rename", &json!({"name": "  "}).to_string())
                .expect("sessionless"),
        )
        .expect("json");
        assert_eq!(cleared["result"]["labelIsChosen"], false, "{cleared}");
        assert!(
            !cleared["result"]["label"]
                .as_str()
                .unwrap_or_default()
                .is_empty()
        );
        assert_eq!(cleared["result"]["key"], key);

        unsafe { std::env::remove_var("TOKENSTAT_IDENTITY_DIR") };
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The API sends a relative avatar path on purpose, so it never hands out
    /// a third party URL. A client that treated it as a URL would render a
    /// broken image with nothing to explain why.
    #[test]
    fn a_relative_avatar_resolves_against_its_host() {
        let raw = json!({"avatar": "/avatar/abc123.webp"});
        assert_eq!(
            avatar_url("https://tokenstat.ai", &raw).as_deref(),
            Some("https://tokenstat.ai/avatar/abc123.webp")
        );
        // A trailing slash on the host must not produce a double slash.
        assert_eq!(
            avatar_url("https://tokenstat.ai/", &raw).as_deref(),
            Some("https://tokenstat.ai/avatar/abc123.webp")
        );
        // An absolute URL passes through, so the API can start sending one.
        let absolute = json!({"avatar": "https://cdn.example/a.png"});
        assert_eq!(
            avatar_url("https://tokenstat.ai", &absolute).as_deref(),
            Some("https://cdn.example/a.png")
        );
        // Absent, empty and blank are all "no picture", not an empty URL.
        for value in [json!({}), json!({"avatar": ""}), json!({"avatar": "   "})] {
            assert_eq!(avatar_url("https://tokenstat.ai", &value), None, "{value}");
        }
    }

    /// An empty archive is a valid answer, not a failure.
    ///
    /// Home draws this grid the moment the window opens, before anything has
    /// been scanned, and the first run of the app is exactly the case where
    /// there is nothing yet. An error here would put a banner across a brand
    /// new install.
    #[test]
    fn the_calendar_answers_for_an_empty_archive() {
        let mut s = session();
        let out = call(&mut s, "activity.calendar", "{}");
        let v: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(v["ok"], true, "{out}");
        assert!(v["result"].is_null(), "{out}");
    }

    /// The hover detail is priced, grouped per model × source, and a quiet day
    /// is a null answer rather than an error.
    #[test]
    fn the_day_detail_answers_with_priced_rows() {
        let mut s = session();
        use tokenstat_core::model::{Confidence, EventId, Extras, SourceId, Timestamp, UsageEvent};
        let make = |id: &str, source: SourceId, out: u64| UsageEvent {
            id: EventId::derive(&[id]),
            source,
            ts: Timestamp::from_ms(1_699_920_000_000), // 2023-11-14 UTC
            model: "gpt-4.1".into(),
            session: "s1".into(),
            project: "p".into(),
            counters: tokenstat_core::Counters {
                input_fresh: Some(1),
                cache_read: Some(2),
                cache_write_5m: Some(3),
                cache_write_1h: None,
                output: Some(out),
            },
            extras: Extras::default(),
            billing: tokenstat_core::model::BillingMode::Plan,
            confidence: Confidence::Exact,
        };
        s.engine
            .store_mut()
            .insert_events(
                &[
                    make("a", SourceId::ClaudeCode, 10),
                    make("b", SourceId::Codex, 20),
                ],
                &jiff::tz::TimeZone::UTC,
            )
            .unwrap();

        let out = call(&mut s, "activity.day", r#"{"date":"2023-11-14"}"#);
        let v: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(v["ok"], true, "{out}");
        let r = &v["result"];
        assert_eq!(r["date"], "2023-11-14");
        assert_eq!(r["tokens"].as_u64(), Some(42), "{out}"); // (1+2+3+10) + (1+2+3+20)
        assert_eq!(r["events"].as_u64(), Some(2), "{out}");
        // Pricing depends on the local price book, which a CI checkout does not
        // have. The contract this test pins is the shape of the answer (rows,
        // totals, ordering), not the rate table, so the value stays structural.
        assert!(r["valueMicros"].is_number(), "{out}");
        assert!(r["unpricedModels"].is_array(), "{out}");

        let rows = r["rows"].as_array().expect("rows");
        assert_eq!(rows.len(), 2, "{out}");
        // Largest slice first: the Codex row has 26 tokens, the Claude one 16.
        assert_eq!(rows[0]["src"], "codex", "{out}");
        assert_eq!(rows[0]["model"], "gpt-4.1", "{out}");
        assert_eq!(rows[0]["tokens"].as_u64(), Some(26), "{out}");
        assert_eq!(rows[1]["src"], "claude_code", "{out}");

        // A day with no events is an answer, not a failure.
        let quiet = call(&mut s, "activity.day", r#"{"date":"2023-11-13"}"#);
        let q: Value = serde_json::from_str(&quiet).expect("json");
        assert_eq!(q["ok"], true, "{quiet}");
        assert!(q["result"].is_null(), "{quiet}");
    }

    /// The editor's contract, pinned at the transport rather than only in the
    /// highlight crate: an uncolourable file is a normal answer with a reason,
    /// not an error, because an error puts a red banner over a file that opened
    /// perfectly well.
    #[test]
    fn highlighting_answers_for_files_it_cannot_colour() {
        let coloured = call_sessionless(
            "highlight",
            r#"{"path":"src/main.rs","text":"fn main() {}\n"}"#,
        )
        .expect("highlight is sessionless");
        let v: Value = serde_json::from_str(&coloured).expect("json");
        assert_eq!(v["ok"], true, "{coloured}");
        assert_eq!(v["result"]["language"], "rust");
        assert!(
            v["result"]["spans"]
                .as_array()
                .is_some_and(|s| !s.is_empty()),
            "{coloured}"
        );
        // The editor needs these to indent and to toggle a comment, and it must
        // not carry its own second table of them.
        assert_eq!(v["result"]["syntax"]["lineComment"], "//");
        assert_eq!(v["result"]["syntax"]["indent"], 4);

        let unknown = call_sessionless("highlight", r#"{"path":"LICENSE","text":"anything"}"#)
            .expect("highlight is sessionless");
        let v: Value = serde_json::from_str(&unknown).expect("json");
        assert_eq!(v["ok"], true, "an unknown file type is not a failure");
        assert!(v["result"]["language"].is_null());
        assert!(v["result"]["note"].is_string(), "{unknown}");
    }

    #[test]
    fn a_workspace_can_be_listed_diffed_and_committed() {
        let mut s = session();
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-dispatch-git-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .expect("git must be installed to run this test");
        };
        run(&["init", "-q", "."]);
        run(&["config", "user.email", "t@example.invalid"]);
        run(&["config", "user.name", "t"]);
        std::fs::write(dir.join("src/main.rs"), "fn main() {}\n").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-qm", "init"]);

        let added: Value = serde_json::from_str(&call(
            &mut s,
            "workspace.add",
            &json!({"path": dir.display().to_string()}).to_string(),
        ))
        .unwrap();
        let id = added["result"]["id"].as_str().unwrap().to_string();

        // The tree lists one directory at a time, root first.
        let tree: Value = serde_json::from_str(&call(
            &mut s,
            "workspace.tree",
            &json!({"id": id}).to_string(),
        ))
        .unwrap();
        assert_eq!(tree["ok"], true, "{tree}");
        assert!(
            tree["result"]
                .as_array()
                .unwrap()
                .iter()
                .any(|e| e["name"] == "src" && e["isDir"] == true)
        );

        // Edit, diff, stage, commit: the whole loop the Changes tab drives.
        std::fs::write(dir.join("src/main.rs"), "fn main() {\n    work();\n}\n").unwrap();
        let diff: Value = serde_json::from_str(&call(
            &mut s,
            "workspace.diff",
            &json!({"id": id, "path": "src/main.rs"}).to_string(),
        ))
        .unwrap();
        assert_eq!(diff["ok"], true, "{diff}");
        assert!(!diff["result"]["hunks"].as_array().unwrap().is_empty());

        let staged: Value = serde_json::from_str(&call(
            &mut s,
            "workspace.stage",
            &json!({"id": id, "paths": ["src/main.rs"]}).to_string(),
        ))
        .unwrap();
        assert_eq!(staged["result"]["ok"], true, "{staged}");

        let committed: Value = serde_json::from_str(&call(
            &mut s,
            "workspace.commit",
            &json!({"id": id, "message": "feat: work"}).to_string(),
        ))
        .unwrap();
        assert_eq!(committed["result"]["ok"], true, "{committed}");

        let log: Value = serde_json::from_str(&call(
            &mut s,
            "workspace.log",
            &json!({"id": id}).to_string(),
        ))
        .unwrap();
        assert_eq!(log["result"][0]["subject"], "feat: work");

        // A failure comes back as a readable outcome, not as a broken envelope.
        let empty: Value = serde_json::from_str(&call(
            &mut s,
            "workspace.commit",
            &json!({"id": id, "message": "  "}).to_string(),
        ))
        .unwrap();
        assert_eq!(empty["ok"], true, "the call succeeded, the commit did not");
        assert_eq!(empty["result"]["ok"], false);
        assert!(
            empty["result"]["message"]
                .as_str()
                .unwrap()
                .contains("message")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn info_reports_the_protocol_version() {
        let mut s = session();
        let v: Value = serde_json::from_str(&call(&mut s, "info", "{}")).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["result"]["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(v["result"]["timezone"], "UTC");
    }

    #[test]
    fn an_empty_archive_reports_zero_rather_than_failing() {
        let mut s = session();
        let v: Value = serde_json::from_str(&call(&mut s, "totals", "{}")).unwrap();
        assert_eq!(v["ok"], true, "{v}");
        assert_eq!(v["result"]["events"], 0);
        // Unknown, not zero: an empty archive has no first date to report.
        assert!(v["result"]["firstDate"].is_null());
    }

    #[test]
    fn missing_params_are_treated_as_defaults() {
        let mut s = session();
        for params in ["", "null", "{}"] {
            let v: Value = serde_json::from_str(&call(&mut s, "totals", params)).unwrap();
            assert_eq!(v["ok"], true, "params {params:?} rejected: {v}");
        }
    }

    #[test]
    fn report_requires_a_group_and_says_so() {
        let mut s = session();
        let v: Value = serde_json::from_str(&call(&mut s, "report", "{}")).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["error"]["message"].as_str().unwrap().contains("group"));
    }

    #[test]
    fn report_accepts_every_grouping() {
        let mut s = session();
        for group in ["day", "week", "model", "project", "source", "session"] {
            let out = call(&mut s, "report", &json!({"group": group}).to_string());
            let v: Value = serde_json::from_str(&out).unwrap();
            assert_eq!(v["ok"], true, "group {group} failed: {out}");
            assert!(v["result"].is_array());
        }
    }

    #[test]
    fn a_split_report_needs_both_dimensions() {
        let mut s = session();
        let ok = call(
            &mut s,
            "report.split",
            &json!({"group": "project", "splitBy": "source"}).to_string(),
        );
        assert_eq!(
            serde_json::from_str::<Value>(&ok).unwrap()["ok"],
            true,
            "{ok}"
        );

        let bad = call(
            &mut s,
            "report.split",
            &json!({"group": "project"}).to_string(),
        );
        assert_eq!(serde_json::from_str::<Value>(&bad).unwrap()["ok"], false);
    }

    #[test]
    fn workspaces_start_empty_and_survive_a_round_trip() {
        let mut s = session();
        // A fresh session may inherit the real registry from the data dir, so
        // this asserts the shape rather than emptiness.
        let v: Value = serde_json::from_str(&call(&mut s, "workspace.list", "{}")).unwrap();
        assert_eq!(v["ok"], true, "{v}");
        assert!(v["result"].is_array());
    }

    #[test]
    fn adding_a_workspace_reports_its_git_state() {
        let mut s = session();
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-ws-dispatch-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();

        let out = call(
            &mut s,
            "workspace.add",
            &json!({"path": dir.display().to_string()}).to_string(),
        );
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true, "{out}");
        assert_eq!(v["result"]["exists"], true);
        // A plain folder is a legitimate workspace with no branch, not an error.
        assert_eq!(v["result"]["git"]["isRepo"], false);

        let id = v["result"]["id"].as_str().unwrap().to_string();
        let gone = call(&mut s, "workspace.remove", &json!({"id": id}).to_string());
        assert_eq!(
            serde_json::from_str::<Value>(&gone).unwrap()["result"]["removed"],
            true
        );
        assert!(dir.is_dir(), "removing a workspace must not touch the disk");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn adding_something_that_is_not_a_folder_is_rejected() {
        let mut s = session();
        let out = call(
            &mut s,
            "workspace.add",
            &json!({"path": "/definitely/not/here/at/all"}).to_string(),
        );
        assert_eq!(serde_json::from_str::<Value>(&out).unwrap()["ok"], false);
    }

    #[test]
    fn status_for_an_unknown_workspace_says_so() {
        let mut s = session();
        let out = call(
            &mut s,
            "workspace.status",
            &json!({"id": "nope"}).to_string(),
        );
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["error"]["message"].as_str().unwrap().contains("nope"));
    }

    #[test]
    fn account_methods_answer_without_a_network() {
        let mut s = session();
        // No server is reachable in a test run, so these must fail as an
        // envelope rather than hang or panic. The point is the contract, not
        // the verdict: a caller always gets decodable JSON back.
        for method in [
            "account.status",
            "account.deviceStart",
            "account.devicePoll",
        ] {
            let out = call(&mut s, method, "{}");
            let v: Value = serde_json::from_str(&out)
                .unwrap_or_else(|e| panic!("{method} returned non-JSON: {out} ({e})"));
            assert!(v["ok"].is_boolean(), "{method}: {out}");
        }
    }

    #[test]
    fn polling_without_a_started_login_says_so() {
        let mut s = session();
        let v: Value = serde_json::from_str(&call(&mut s, "account.devicePoll", "{}")).unwrap();
        assert_eq!(v["ok"], false);
        assert!(
            v["error"]["message"]
                .as_str()
                .unwrap()
                .contains("no sign-in is in progress"),
            "{v}"
        );
    }

    #[test]
    fn cancelling_a_login_is_safe_when_none_is_pending() {
        let mut s = session();
        let v: Value = serde_json::from_str(&call(&mut s, "account.cancelLogin", "{}")).unwrap();
        assert_eq!(v["ok"], true, "{v}");
    }

    #[test]
    fn opening_a_different_archive_replaces_the_session() {
        let mut s = session();
        let other = std::env::temp_dir().join(format!(
            "tokenstat-host-reopen-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&other).unwrap();
        let out = call(
            &mut s,
            "open",
            &json!({
                "dbPath": other.join("tokenstat.db").display().to_string(),
                "timezone": "Europe/Budapest"
            })
            .to_string(),
        );
        assert_eq!(
            serde_json::from_str::<Value>(&out).unwrap()["ok"],
            true,
            "{out}"
        );

        let v: Value = serde_json::from_str(&call(&mut s, "info", "{}")).unwrap();
        assert_eq!(v["result"]["timezone"], "Europe/Budapest");
    }
}
