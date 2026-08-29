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

#[cfg(feature = "local-host")]
use std::collections::HashMap;
#[cfg(feature = "local-host")]
use std::sync::OnceLock;
use std::sync::{Mutex, PoisonError};
#[cfg(feature = "local-host")]
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};
use tokenstat_core::pricing::{EquivalentValue, display_usage_model_id};
use tokenstat_core::{DayPart, GroupBy, Query};

use crate::PROTOCOL_VERSION;
use crate::account_activity::FailureReason;
#[cfg(feature = "local-host")]
use crate::automations::Automation;
use crate::dto::{
    AccountBillingDto, AccountDto, AccountReportDto, BlockDto, BucketDto, CalendarDto,
    DayDetailDto, DayPartDto, DeviceLoginDto, DevicePollDto, GroupByDto, InfoDto, MachineDto,
    MachineUsageDto, QueryDto, ScanReportDto, SplitBucketDto, SyncResultDto, TotalsDto,
};
#[cfg(feature = "local-host")]
use crate::dto::{WorkspaceDto, WorkspaceSummaryDto};
use crate::error::DispatchError;
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
    /// Drop the ten-minute series cache first. A pull-to-refresh after a
    /// plan change must not redraw Free's locked year.
    #[serde(default)]
    force: bool,
}

impl Default for CalendarParams {
    fn default() -> Self {
        CalendarParams {
            weeks: default_weeks(),
            query: QueryDto::default(),
            scope: None,
            force: false,
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

/// Params for `account.report`: which dimension to fold by, over how long.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AccountReportParams {
    /// `"model"`, `"source"` or `"day"`. See `account_activity::Dimension` for
    /// why there is no `"project"`.
    #[serde(default)]
    group: Option<String>,
    #[serde(default = "default_weeks")]
    weeks: usize,
}

impl Default for AccountReportParams {
    fn default() -> Self {
        AccountReportParams {
            group: None,
            weeks: default_weeks(),
        }
    }
}

/// Params for `account.machineUsage`: which machines, over how many days.
///
/// The caller passes the ids because it already has them from `account.status`,
/// and asking the service for the same list twice to answer one question is a
/// round trip nobody needs.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MachineUsageParams {
    #[serde(default)]
    machines: Vec<String>,
    #[serde(default = "default_machine_days")]
    days: u16,
}

impl Default for MachineUsageParams {
    fn default() -> Self {
        MachineUsageParams {
            machines: Vec::new(),
            days: default_machine_days(),
        }
    }
}

/// A month. Long enough to say which computer does the work, short enough that
/// one request per machine stays cheap.
fn default_machine_days() -> u16 {
    30
}

#[cfg(feature = "local-host")]
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspacePathParams {
    path: String,
}

/// `workspace.summary` takes an optional id: one folder, or every folder.
#[cfg(feature = "local-host")]
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceSummaryParams {
    #[serde(default)]
    id: Option<String>,
}

#[cfg(feature = "local-host")]
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceIdParams {
    id: String,
    /// Only used by `workspace.rename`.
    #[serde(default)]
    name: Option<String>,
    /// Branch checkout source, or the new branch name.
    #[serde(default)]
    branch: Option<String>,
    /// Whether `branch` names a remote-tracking ref.
    #[serde(default)]
    remote: bool,
    /// Optional start point for a new branch.
    #[serde(default)]
    from: Option<String>,
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

#[cfg(feature = "local-host")]
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
    /// The client is painting a dark background. Absent from an older client,
    /// which then spawns exactly as it did before.
    #[serde(default)]
    dark: Option<bool>,
    /// Optional local model selection. The host converts this to environment
    /// variables for the selected harness and never persists it.
    #[serde(default)]
    model_provider: Option<String>,
    #[serde(default)]
    model_id: Option<String>,
    /// True for inspector consoles and other daemon-owned shells that must
    /// not appear as a workspace tab. The process still runs in the folder.
    #[serde(default)]
    hidden: bool,
}

/// Fold the activity sampler's verdict into a serialized session.
///
/// Added here rather than on `SessionInfo` itself: the pty crate owns
/// processes and buffers and has no business measuring CPU, and the detector
/// wants a sampling thread the pty crate should not own either. A session the
/// sampler has not reached yet simply carries no verdict, which a client
/// reads as "not known" rather than as "idle".
#[cfg(feature = "local-host")]
fn add_activity(item: &mut Value) {
    // Started here rather than at daemon boot: a host that never lists a
    // terminal never needs a sampling thread, and this is idempotent. The
    // first verdict lands a tick later, which is why an unknown session
    // carries no field instead of a made-up one.
    crate::activity::start();
    if let Some(pid) = item.get("pid").and_then(|v| v.as_u64())
        && let Some(reading) = crate::activity::reading(pid as u32)
        && let Some(map) = item.as_object_mut()
    {
        map.insert("activity".into(), json!(reading.activity.as_str()));
        // Rounded to a tenth: this is a smoothed average of a noisy sample and
        // printing it to six decimals would claim a precision it does not have.
        map.insert(
            "cpuPercent".into(),
            json!((reading.cpu_percent * 10.0).round() / 10.0),
        );
        map.insert("memoryMb".into(), json!(reading.memory_mb.round()));
        if let Some(attention) = reading.attention {
            map.insert("attention".into(), json!(attention.as_str()));
        }
    }
    add_meter(item);
}

/// Fold the live token meter onto the same session object.
///
/// Independent of the CPU sampler: a session the sampler has not reached
/// can still have a log, and a session with no log must not grow fake
/// zeros. Fields are omitted until there is a real reading.
#[cfg(feature = "local-host")]
fn add_meter(item: &mut Value) {
    let command = item
        .get("command")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let cwd = item
        .get("cwd")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let started_at_ms = item
        .get("startedAtMs")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    if command.is_empty() || cwd.is_empty() || started_at_ms == 0 {
        return;
    }
    let Some(meter) = crate::session_meter::reading(&command, &cwd, started_at_ms) else {
        // A harness we can meter but which has not written a turn yet starts
        // at zero rather than at nothing. The row then counts up from $0.00
        // instead of showing the command and later jumping to a figure.
        if crate::session_meter::can_meter(&command) {
            if let Some(map) = item.as_object_mut() {
                map.insert("tokens".into(), json!(0));
                map.insert("costMicros".into(), json!(0));
                map.insert("costComplete".into(), json!(true));
            }
        }
        return;
    };
    let Some(map) = item.as_object_mut() else {
        return;
    };
    map.insert("tokens".into(), json!(meter.tokens));
    map.insert("billing".into(), json!(meter.billing.as_str()));
    if let Some(micros) = meter.cost_micros {
        map.insert("costMicros".into(), json!(micros));
        map.insert("costEstimated".into(), json!(meter.estimated));
        map.insert("costComplete".into(), json!(meter.complete));
    }
    if !meter.model.is_empty() {
        map.insert("model".into(), json!(meter.model));
    }
    // The used figure ships on its own. Without a window there is no bar, but
    // "142K of context" is still worth saying, and dropping both was what left
    // a Grok row with nothing but a lifetime total.
    if let Some(used) = meter.context_used {
        map.insert("contextUsed".into(), json!(used));
    }
    if let Some(window) = meter.context_window {
        map.insert("contextWindow".into(), json!(window));
        map.insert("contextEstimated".into(), json!(meter.context_estimated));
    }
}

#[cfg(feature = "local-host")]
fn default_rows() -> u16 {
    24
}

#[cfg(feature = "local-host")]
fn default_cols() -> u16 {
    80
}

#[cfg(feature = "local-host")]
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
    /// `pty.read` only: how long the host may hold the call open waiting for
    /// output, in milliseconds. Zero is the old behaviour, answer with whatever
    /// is there.
    ///
    /// This is what makes a terminal feel like a terminal. A client that polls
    /// meets its own interval on every keystroke: the echo is ready a
    /// millisecond after the write and sits in the buffer until the next
    /// scheduled read asks for it. Holding the call open instead means the
    /// answer leaves the moment the bytes exist, so the round trip is the only
    /// delay left.
    #[serde(default)]
    wait_ms: Option<u64>,
    /// Opaque id for the front end making the call, stable while it is showing
    /// the session.
    ///
    /// A pty has one size and can have two front ends, so `pty.resize` states
    /// what *this* viewer can show rather than what the session must become,
    /// and the host sizes the session to suit every viewer at once. `pty.read`
    /// carries it to keep the viewer's lease alive, and `pty.detach` gives it
    /// up. Absent means an older client, which resizes the session outright
    /// exactly as before.
    #[serde(default)]
    viewer: Option<String>,
}

#[cfg(feature = "local-host")]
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct WorkflowParams {
    id: Option<String>,
    workflow: Option<crate::workflows::Workflow>,
    input: Option<String>,
    workspace_id: Option<String>,
    backend: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    prompt: Option<String>,
    node_id: Option<String>,
    offset: Option<u64>,
}

#[cfg(feature = "local-host")]
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AutomationParams {
    id: Option<String>,
    job: Option<Automation>,
    enabled: Option<bool>,
    /// `automation.transcript` only: where the caller got to last time.
    offset: Option<u64>,
    default_budget_seconds: Option<u64>,
    max_concurrent: Option<u32>,
    /// `automation.interactiveCommand` only.
    backend: Option<String>,
    prompt: Option<String>,
    model: Option<String>,
    effort: Option<String>,
}

#[cfg(feature = "local-host")]
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
    include_archived: Option<bool>,
}

#[cfg(feature = "local-host")]
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ChatParams {
    id: Option<String>,
    workspace_id: Option<String>,
    title: Option<String>,
    backend: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    mode: Option<String>,
    autonomy: Option<String>,
    budget_seconds: Option<u64>,
    allowed_tools: Option<Vec<String>>,
    allowed_shell_prefixes: Option<Vec<String>>,
    text: Option<String>,
    attachment_ids: Option<Vec<String>>,
    name: Option<String>,
    data: Option<String>,
    media_type: Option<String>,
    offset: Option<u64>,
}

#[cfg(feature = "local-host")]
impl ChatParams {
    fn create(self) -> crate::chat::Create {
        crate::chat::Create {
            workspace_id: self.workspace_id.unwrap_or_default(),
            title: self.title,
            backend: self.backend.unwrap_or_default(),
            model: self.model,
            effort: self.effort,
            mode: self.mode,
            autonomy: self.autonomy,
            budget_seconds: self.budget_seconds,
        }
    }

    fn changes(self) -> crate::chat::Update {
        crate::chat::Update {
            title: self.title,
            backend: self.backend,
            model: self.model,
            effort: self.effort,
            mode: self.mode,
            autonomy: self.autonomy,
            allowed_tools: self.allowed_tools,
            allowed_shell_prefixes: self.allowed_shell_prefixes,
            budget_seconds: self.budget_seconds,
        }
    }
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

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppleActivateParams {
    signed_transaction: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppleRenewalParams {
    signed_renewal_info: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleActivateParams {
    package_name: String,
    product_id: String,
    purchase_token: String,
}

fn billing_from_raw(raw: &Value) -> Option<AccountBillingDto> {
    let b = raw.get("billing")?;
    if b.is_null() {
        return None;
    }
    Some(AccountBillingDto {
        provider: b
            .get("provider")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        status: b
            .get("status")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        entitled: b.get("entitled").and_then(|v| v.as_bool()).unwrap_or(false),
        period_end: b
            .get("period_end")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        cancel_scheduled: b
            .get("cancel_scheduled")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        scheduled_tier: b
            .get("scheduled_tier")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        trial_used: b
            .get("trial_used")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        has_live_sub: b
            .get("has_live_sub")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        app_account_token: b
            .get("app_account_token")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string),
    })
}

fn account_dto_from_status(s: tokenstat_sync::StatusResult) -> AccountDto {
    AccountDto {
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
        this_machine_id: tokenstat_sync::config::ensure_machine_id().ok(),
        machines: s.machines.iter().map(MachineDto::from_value).collect(),
        schema_current: s.schema_current,
        machine_limit: s
            .raw
            .get("sync")
            .and_then(|v| v.get("machine_limit"))
            .and_then(|v| v.as_u64())
            .map(|n| n as u32),
        hosts_linked: s
            .raw
            .get("sync")
            .and_then(|v| v.get("hosts_linked"))
            .and_then(|v| v.as_u64())
            .map(|n| n as u32),
        can_remote: s
            .raw
            .get("sync")
            .and_then(|v| v.get("remote"))
            .and_then(|v| v.as_bool()),
        sync_interval: s
            .raw
            .get("sync")
            .and_then(|v| v.get("min_interval"))
            .and_then(|v| v.as_u64())
            .map(|n| n as u32),
        billing: billing_from_raw(&s.raw),
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

/// Turn any failure into the envelope's error, under the general code.
///
/// Every fallible call inside [`dispatch`] ends with this. It replaced a
/// hundred copies of `map_err(|e| e.to_string())`, which said the same thing at
/// more length and left no room for a code. A method that has something more
/// specific to say builds its [`DispatchError`] directly instead.
trait IntoEnvelope<T> {
    fn envelope(self) -> Result<T, DispatchError>;
}

/// Keep the device-flow failure classes intact across the JSON bridge. The UI
/// can retry a transport failure, but retrying a refused or already-consumed
/// grant only produces a spinner that can never succeed.
fn device_poll_error(error: tokenstat_sync::profile::ProfileError) -> DispatchError {
    use tokenstat_sync::profile::ProfileError;
    match error {
        ProfileError::DeviceRejected { code, detail } => {
            let envelope_code = if code == "invalid_grant" {
                "device_invalid_grant"
            } else {
                "device_refused"
            };
            DispatchError::new(envelope_code, format!("login failed: {code}{detail}"))
        }
        ProfileError::LoginStorage(message) => DispatchError::new(
            "device_storage",
            format!("could not save your sign-in: {message}"),
        ),
        ProfileError::Http(error) => DispatchError::new("device_transport", error.to_string()),
        ProfileError::Io(error) => DispatchError::new("device_transport", error.to_string()),
        other => DispatchError::new("device_failed", other.to_string()),
    }
}

impl<T, E: std::fmt::Display> IntoEnvelope<T> for Result<T, E> {
    fn envelope(self) -> Result<T, DispatchError> {
        self.map_err(|e| DispatchError::from(e.to_string()))
    }
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
#[cfg(feature = "local-host")]
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

/// How long a folder's git description is reused without re-running git.
///
/// Long enough to absorb a launch fan-out and a file-watcher debounce burst,
/// short enough that a save still shows up within a beat. Without this,
/// every concurrent `workspace.list` and every 600ms refresh after a build
/// paid three git process spawns per folder again.
#[cfg(feature = "local-host")]
const WORKSPACE_STATUS_TTL: Duration = Duration::from_millis(400);

#[cfg(feature = "local-host")]
struct WorkspaceStatusCache {
    entries: HashMap<String, (Instant, WorkspaceDto)>,
}

#[cfg(feature = "local-host")]
fn workspace_status_cache() -> &'static Mutex<WorkspaceStatusCache> {
    static CACHE: OnceLock<Mutex<WorkspaceStatusCache>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Mutex::new(WorkspaceStatusCache {
            entries: HashMap::new(),
        })
    })
}

/// Drop cached git state for one folder, or for every folder.
///
/// Called after mutations that change what `git status` would report, so the
/// next list is honest rather than a few hundred milliseconds behind the write.
#[cfg(feature = "local-host")]
fn invalidate_workspace_status(id: Option<&str>) {
    let Ok(mut cache) = workspace_status_cache().lock() else {
        return;
    };
    match id {
        Some(id) => {
            cache.entries.remove(id);
        }
        None => cache.entries.clear(),
    }
}

/// Describe a registered folder, reading git only when it is actually there.
///
/// A missing folder gets `git: None` rather than an empty status, so a caller
/// cannot mistake "we did not look" for "nothing has changed".
#[cfg(feature = "local-host")]
fn describe(ws: &tokenstat_workspace::Workspace) -> WorkspaceDto {
    if let Ok(cache) = workspace_status_cache().lock() {
        if let Some((at, dto)) = cache.entries.get(&ws.id) {
            if at.elapsed() < WORKSPACE_STATUS_TTL {
                return dto.clone();
            }
        }
    }

    let exists = ws.exists();
    let dto = WorkspaceDto {
        id: ws.id.clone(),
        path: ws.path.display().to_string(),
        name: ws.name.clone(),
        added_at_ms: ws.added_at_ms,
        exists,
        git: exists.then(|| tokenstat_workspace::git::status(&ws.path)),
    };

    if let Ok(mut cache) = workspace_status_cache().lock() {
        cache
            .entries
            .insert(ws.id.clone(), (Instant::now(), dto.clone()));
    }
    dto
}

/// Apply a closure to the session.
///
/// A thin wrapper kept because it reads well at every call site and because it
/// is the seam a future per-request permission check would sit in.
fn with_session<T>(
    s: &mut Session,
    f: impl FnOnce(&mut Session) -> Result<T, DispatchError>,
) -> Result<T, DispatchError> {
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
        Err(e) => err(&e.code, e.message),
    }
}

/// Account mutations, login, and update downloads belong to the person at
/// this machine. An approved phone can work in a folder. It cannot log the
/// host out, admit another peer's update, or unlink a device.
fn owner_only_method(method: &str) -> bool {
    method.starts_with("app.update")
        || matches!(
            method,
            "account.logout"
                | "account.appleActivate"
                | "account.appleRenewal"
                | "account.googleActivate"
                | "account.deviceStart"
                | "account.devicePoll"
                | "account.cancelLogin"
                | "account.renameMachine"
                | "account.unlinkMachine"
                | "account.registerMachine"
        )
}

fn dispatch(s: &mut Session, method: &str, params: &str) -> Result<Value, DispatchError> {
    if owner_only_method(method) {
        crate::request_context::refuse_remote("account and update methods")?;
    }
    match method {
        // Re-open against a different archive or timezone. Also the hook a
        // future remote transport uses to point at another machine.
        "open" => {
            let p: OpenParams = parse(params)?;
            *s = Session::open(&p)?;
            Ok(json!({"opened": true}))
        }

        "info" => with_session(s, |b| {
            let peers = crate::remote::connection_counts();
            let info = InfoDto {
                protocol_version: PROTOCOL_VERSION.to_string(),
                core_version: tokenstat_core::VERSION.to_string(),
                db_path: b.engine().ok().map(|e| e.db_path().display().to_string()),
                has_archive: b.has_archive(),
                timezone: b.timezone().iana_name().unwrap_or("unknown").to_string(),
                price_book_effective_from: b.prices.effective_from.clone(),
                has_prices: !b.prices.is_empty(),
                open_files: crate::open_files::open_file_count().map(|n| n as u64),
                open_file_limit: crate::open_files::open_file_limit().map(|(soft, _)| soft),
                // One reading, so the two numbers are of the same moment
                // rather than of two turns of the pool's lock.
                peer_calls_live: peers.0,
                peer_connections_idle: peers.1,
            };
            serde_json::to_value(info).envelope()
        }),

        "totals" => {
            let p: QueryParams = parse(params)?;
            with_session(s, |b| {
                let t = b.engine()?.totals(&Query::from(p.query)).envelope()?;
                serde_json::to_value(TotalsDto::from(t)).envelope()
            })
        }

        "report" => {
            let p: ReportParams = serde_json::from_str(params.trim()).envelope()?;
            let group = GroupBy::from(p.group);
            with_session(s, |b| {
                let rows = b
                    .engine()?
                    .priced_report(group, &Query::from(p.query), &b.prices)
                    .envelope()?;
                let dtos: Vec<BucketDto> = rows.into_iter().map(BucketDto::from).collect();
                serde_json::to_value(dtos).envelope()
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
                    if p.force {
                        crate::account_activity::invalidate();
                    }
                    let today = tokenstat_core::activity::today(b.timezone());
                    match crate::account_activity::calendar(&b.prices, b.timezone(), p.weeks) {
                        Ok(account) if account.calendar.is_some() => {
                            // Unwrapped rather than matched: the guard above is
                            // the check, and `Some` is why we are here.
                            let Some(calendar) = account.calendar else {
                                return Ok(Value::Null);
                            };
                            // A remembered grid says so. The numbers are real
                            // and they are dated, which is a different thing
                            // from a fallback to another scope: this is still
                            // the account's year, just not this minute's.
                            let (notice, code) = if account.stale {
                                (
                                    Some(
                                        "Showing the last usage this device fetched. \
                                         The refresh did not go through."
                                            .to_string(),
                                    ),
                                    Some("stale"),
                                )
                            } else {
                                (None, None)
                            };
                            let mut dto = CalendarDto::from(calendar)
                                .scoped("account", notice, code)
                                .fetched_at(account.fetched_at_ms);
                            if let Some(lock) = account.lock {
                                dto = dto
                                    .history_lock(lock.unlock_from.to_string(), lock.history_days);
                            }
                            return serde_json::to_value(dto).envelope();
                        }
                        // The account exists and has nothing in it. Not an
                        // error, and not a reason to show this machine's grid
                        // labelled as everybody's.
                        Ok(_) => return Ok(Value::Null),
                        Err(failure) => {
                            let code = match failure.reason {
                                FailureReason::Authentication => "auth",
                                FailureReason::UpgradeRequired => "upgrade",
                                FailureReason::Other => "other",
                            };
                            // A client has no machine of its own to fall back
                            // to, so the failure is the answer. It carries the
                            // same code the notice would have, which is what the
                            // front end reads to offer a sign-in, so one client
                            // handles both shapes with one branch.
                            let Ok(engine) = b.engine() else {
                                return Err(DispatchError::new(
                                    code,
                                    match failure.reason {
                                        FailureReason::Authentication => {
                                            "Sign in to tokenstat.ai to see your usage.".to_string()
                                        }
                                        _ => failure.message.clone(),
                                    },
                                ));
                            };
                            let rows = engine
                                .priced_report(GroupBy::Day, &Query::from(p.query), &b.prices)
                                .envelope()?;
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
                            let notice = match failure.reason {
                                FailureReason::Authentication => {
                                    "Showing this machine only. Sign in to tokenstat.ai \
                                     to see usage from every machine."
                                        .to_string()
                                }
                                _ => format!("Showing this machine only: {}", failure.message),
                            };
                            return match tokenstat_core::activity::calendar(&days, p.weeks, today) {
                                Some(calendar) => {
                                    serde_json::to_value(CalendarDto::from(calendar).scoped(
                                        "local",
                                        Some(notice),
                                        Some(code),
                                    ))
                                    .envelope()
                                }
                                None => Ok(Value::Null),
                            };
                        }
                    }
                }

                let rows = b
                    .engine()?
                    .priced_report(GroupBy::Day, &Query::from(p.query), &b.prices)
                    .envelope()?;
                // Cost in microdollars: what the day's work actually spent.
                // Token counts would favour high-volume cheap models over
                // expensive ones; cost reflects real spend instead.
                let days: Vec<(String, u64)> = rows
                    .iter()
                    .map(|r| (r.key.clone(), r.value.micros().max(0) as u64))
                    .collect();
                // Anchored on today rather than on the newest day with data, so
                // a quiet week reads as a quiet week instead of vanishing.
                let today = tokenstat_core::activity::today(b.timezone());
                match tokenstat_core::activity::calendar(&days, p.weeks, today) {
                    Some(calendar) => serde_json::to_value(CalendarDto::from(calendar)).envelope(),
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
                    crate::account_activity::day_detail(&p.date, b.timezone(), p.weeks)
                        .map_err(|e| e.message)?
                } else {
                    b.engine()?.store().day_detail(&p.date).envelope()?
                };
                // Nothing happened that day. An answer, not an error: the
                // client only asks for days the grid lit up, so a miss is
                // usually the account cache being narrower than the local
                // archive, and the hover just shows nothing to add.
                if rows.is_empty() {
                    return Ok(Value::Null);
                }
                let dto = day_detail_dto(&p.date, &rows, &b.prices);
                serde_json::to_value(dto).envelope()
            })
        }

        // The account's own breakdown, across every machine that syncs.
        //
        // The sibling of `report`, which reads this machine's archive. A client
        // has no archive, so without this its Insights screen could only ever
        // say "no local archive", and a phone is exactly where somebody wants to
        // know which model ate the month.
        //
        // Built from the same cached series as `activity.calendar`, so the
        // breakdown and the grid above it cannot disagree and opening the screen
        // costs no network call of its own.
        "account.report" => {
            let p: AccountReportParams = parse(params)?;
            let group = p.group.as_deref().unwrap_or("model");
            let dimension = crate::account_activity::Dimension::from_wire(group);
            with_session(s, |b| {
                let built =
                    crate::account_activity::breakdown(&b.prices, b.timezone(), p.weeks, dimension)
                        .map_err(|failure| {
                            DispatchError::new(
                                match failure.reason {
                                    FailureReason::Authentication => "auth",
                                    FailureReason::UpgradeRequired => "upgrade",
                                    FailureReason::Other => "other",
                                },
                                match failure.reason {
                                    FailureReason::Authentication => {
                                        "Sign in to tokenstat.ai to see your usage.".to_string()
                                    }
                                    _ => failure.message.clone(),
                                },
                            )
                        })?;
                serde_json::to_value(AccountReportDto {
                    rows: built.rows.into_iter().map(BucketDto::from).collect(),
                    group: group.to_string(),
                    fetched_at_ms: built.fetched_at_ms,
                    stale: built.stale,
                })
                .envelope()
            })
        }

        // What each machine on the account contributed. One request per machine,
        // so this is asked for by a screen somebody opened rather than warmed
        // behind one they might.
        "account.machineUsage" => {
            let p: MachineUsageParams = parse(params)?;
            with_session(s, |b| {
                let rows = crate::account_activity::machine_usage(
                    &b.prices,
                    b.timezone(),
                    &p.machines,
                    p.days,
                )
                .map_err(|failure| {
                    DispatchError::new(
                        match failure.reason {
                            FailureReason::Authentication => "auth",
                            FailureReason::UpgradeRequired => "upgrade",
                            FailureReason::Other => "other",
                        },
                        failure.message.clone(),
                    )
                })?;
                let dtos: Vec<MachineUsageDto> = rows
                    .into_iter()
                    .map(|r| MachineUsageDto {
                        machine: r.machine,
                        value_micros: r.micros,
                        events: r.events,
                        active_days: r.active_days,
                        days: p.days,
                    })
                    .collect();
                serde_json::to_value(dtos).envelope()
            })
        }

        // Two-level report: "which harnesses ran in which project", and any
        // other cross-tabulation. One query, not one per key.
        "report.split" => {
            let p: SplitParams = serde_json::from_str(params.trim()).envelope()?;
            let group = GroupBy::from(p.group);
            let split = GroupBy::from(p.split_by);
            with_session(s, |b| {
                let rows = b
                    .engine()?
                    .report_split(group, split, &Query::from(p.query))
                    .envelope()?;
                let dtos: Vec<SplitBucketDto> =
                    rows.into_iter().map(SplitBucketDto::from).collect();
                serde_json::to_value(dtos).envelope()
            })
        }

        "blocks" => {
            let p: QueryParams = parse(params)?;
            with_session(s, |b| {
                let rows = b.engine()?.blocks(&Query::from(p.query)).envelope()?;
                let dtos: Vec<BlockDto> = rows.into_iter().map(BlockDto::from).collect();
                serde_json::to_value(dtos).envelope()
            })
        }

        "blocks.active" => {
            let p: QueryParams = parse(params)?;
            with_session(s, |b| {
                let row = b.engine()?.active_block(&Query::from(p.query)).envelope()?;
                let dtos: Vec<BlockDto> = row.into_iter().map(BlockDto::from).collect();
                serde_json::to_value(dtos).envelope()
            })
        }

        // Long running. The caller must not run this on a UI thread.
        "scan" => with_session(s, |b| {
            let r = b.engine_mut()?.scan().envelope()?;
            serde_json::to_value(ScanReportDto::from(r)).envelope()
        }),

        // Signed out is a state, not a failure. The bridge reports
        // `signedIn: false` so the app can offer sign-in, and reserves the
        // error path for a host that is unreachable or a token that was
        // revoked, which need different words.
        "account.status" => {
            let host = tokenstat_sync::profile::resolve_api_host(None).envelope()?;
            match tokenstat_sync::sync_status(None) {
                Ok(s) => serde_json::to_value(account_dto_from_status(s)).envelope(),
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
                    machine_limit: None,
                    hosts_linked: None,
                    can_remote: None,
                    sync_interval: None,
                    billing: None,
                })
                .envelope(),
                Err(e) => Err(e.to_string().into()),
            }
        }

        // Bind a StoreKit transaction to the signed-in account, then return
        // a fresh status so the paywall can redraw without a second round trip.
        "account.appleActivate" => {
            let p: AppleActivateParams = serde_json::from_str(params.trim()).envelope()?;
            if p.signed_transaction.trim().is_empty() {
                return Err(DispatchError::new(
                    "invalid",
                    "signedTransaction is required",
                ));
            }
            tokenstat_sync::apple_activate(None, &p.signed_transaction).envelope()?;
            // The Home grid caches Free's lock for ten minutes. A purchase
            // just changed that answer, so the next calendar read must hit
            // the account rather than replay the locked year.
            crate::account_activity::invalidate();
            let s = tokenstat_sync::sync_status(None).envelope()?;
            serde_json::to_value(account_dto_from_status(s)).envelope()
        }

        // StoreKit queued a downgrade or turned auto-renew off. No new
        // transaction yet. The signed renewal info is the proof.
        "account.appleRenewal" => {
            let p: AppleRenewalParams = serde_json::from_str(params.trim()).envelope()?;
            if p.signed_renewal_info.trim().is_empty() {
                return Err(DispatchError::new(
                    "invalid",
                    "signedRenewalInfo is required",
                ));
            }
            tokenstat_sync::apple_renewal(None, &p.signed_renewal_info).envelope()?;
            crate::account_activity::invalidate();
            let s = tokenstat_sync::sync_status(None).envelope()?;
            serde_json::to_value(account_dto_from_status(s)).envelope()
        }

        // Google Play purchase verification happens on the account service.
        // The Android client cannot safely hold a Play Developer credential.
        "account.googleActivate" => {
            let p: GoogleActivateParams = serde_json::from_str(params.trim()).envelope()?;
            if p.package_name != "ai.tokenstat.tokenstat"
                || p.product_id.trim().is_empty()
                || p.purchase_token.trim().is_empty()
            {
                return Err(DispatchError::new(
                    "invalid",
                    "packageName, productId and purchaseToken are required",
                ));
            }
            tokenstat_sync::google_activate(
                None,
                &p.package_name,
                &p.product_id,
                &p.purchase_token,
            )
            .envelope()?;
            crate::account_activity::invalidate();
            let s = tokenstat_sync::sync_status(None).envelope()?;
            serde_json::to_value(account_dto_from_status(s)).envelope()
        }

        // Begin a device authorization. Returns the code to show and the URL to
        // open. Opening the browser is the front end's job: this crate has no
        // business deciding how a window behaves.
        "account.deviceStart" => {
            // Phones declare client so they do not upload usage. They still use a slot.
            #[cfg(feature = "local-host")]
            let device = tokenstat_sync::device_start(None).envelope()?;
            #[cfg(not(feature = "local-host"))]
            let device = tokenstat_sync::device_start_kind(None, "client").envelope()?;
            let dto = DeviceLoginDto::from(&device);
            with_session(s, |b| {
                b.pending_login = Some(device);
                Ok(())
            })?;
            serde_json::to_value(dto).envelope()
        }

        // Poll once. Never sleeps, so the caller controls the cadence and can
        // cancel. On confirmation the token lands in the keychain, the same
        // entry the CLI reads.
        "account.devicePoll" => {
            let pending = with_session(s, |b| {
                b.pending_login
                    .clone()
                    .ok_or_else(|| DispatchError::from("no sign-in is in progress"))
            })?;
            match tokenstat_sync::device_poll(&pending).map_err(device_poll_error)? {
                tokenstat_sync::DeviceStatus::Pending { interval } => {
                    serde_json::to_value(DevicePollDto {
                        state: "pending",
                        interval: Some(interval),
                        handle: None,
                        host: None,
                        machine: None,
                    })
                    .envelope()
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
                    .envelope()
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
            crate::remote::stop_tunnel();
            let host = tokenstat_sync::logout(None).envelope()?;
            with_session(s, |b| {
                b.pending_login = None;
                Ok(())
            })?;
            Ok(json!({"host": host}))
        }

        // Push notifications. A phone with the app closed cannot see a run
        // end, so it asks the account to be told. Registration is per device
        // and repeated on every launch: iOS reissues the token when it likes,
        // and the server keys devices by the token itself.
        //
        // The payload a device can ask for is a fixed reason, never text. See
        // `tokenstat_sync::push` and the website's `lib/push.js`.
        "push.register" => {
            #[derive(Default, Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct RegisterParams {
                token: String,
                platform: String,
                #[serde(default)]
                environment: Option<String>,
            }
            let p: RegisterParams = parse(params)?;
            if p.token.is_empty() {
                return Err("push.register needs a device token".into());
            }
            tokenstat_sync::push::register_device(
                &p.token,
                &p.platform,
                p.environment.as_deref().unwrap_or("production"),
            )
            .envelope()?;
            Ok(json!({"registered": true}))
        }

        "push.unregister" => {
            #[derive(Default, Deserialize)]
            struct UnregisterParams {
                token: String,
            }
            let p: UnregisterParams = parse(params)?;
            if p.token.is_empty() {
                return Err("push.unregister needs a device token".into());
            }
            tokenstat_sync::push::unregister_device(&p.token).envelope()?;
            Ok(json!({"registered": false}))
        }

        // "Send a test notification", from the app's own settings. Answers how
        // many devices took it, which is the only way somebody can tell the
        // difference between "off" and "on but nothing has happened yet".
        "push.test" => {
            let sent =
                tokenstat_sync::push::notify(tokenstat_sync::push::Reason::Test).envelope()?;
            Ok(json!({
                "sent": sent.devices,
                // Whether the server has an APNs key at all. A test that sent
                // to nobody and a server that cannot send are different
                // answers and the settings row says different things.
                "enabled": sent.enabled,
                "signedIn": sent.signed_in,
            }))
        }

        // Opt-in plan-limits posting (P2). Stored in SyncConfig so CLI and app
        // share one switch. Default off.
        "config.limitsSync" => {
            #[derive(Default, Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct LimitsSyncParams {
                #[serde(default)]
                enabled: Option<bool>,
                #[serde(default)]
                skip: Option<Vec<String>>,
                #[serde(default)]
                source: Option<String>,
                #[serde(default)]
                shared: Option<bool>,
            }
            let p: LimitsSyncParams = parse(params)?;
            if let Some(on) = p.enabled {
                tokenstat_sync::config::set_limits_sync(on).envelope()?;
            }
            if let Some(skip) = p.skip {
                tokenstat_sync::config::set_limits_skip(skip).envelope()?;
            }
            if let (Some(source), Some(shared)) = (p.source, p.shared) {
                tokenstat_sync::config::set_limits_source_shared(&source, shared).envelope()?;
            }
            let providers: Vec<tokenstat_core::limits::ProviderLimits> =
                tokenstat_core::limits::cache::load()
                    .into_values()
                    .collect();
            Ok(json!({
                "enabled": tokenstat_sync::config::limits_sync_enabled(),
                "skip": tokenstat_sync::config::limits_skip(),
                "providers": providers,
            }))
        }

        // Long running and it talks to the network. Same rule as `scan`: not
        // from a thread that draws.
        "sync.run" => {
            let p: SyncParams = parse(params)?;
            with_session(s, |b| {
                let tz = b.timezone().iana_name().map(str::to_string);
                let r = tokenstat_sync::sync(
                    b.engine()?.store(),
                    tokenstat_sync::SyncOptions {
                        host_flag: None,
                        prune: p.prune,
                        window: p.window.as_deref(),
                        dry_run: p.dry_run,
                        tz_name: tz.as_deref(),
                    },
                )
                .envelope()?;
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
                .envelope()
            })
        }

        // Adopt the price book an app bundle ships with, when this machine has
        // none of its own. Cheap, offline, and safe to call on every launch:
        // an existing book is never replaced. See `crate::pricing::seed`.
        "pricing.seed" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct SeedParams {
                path: String,
            }
            let p: SeedParams = serde_json::from_str(params.trim()).envelope()?;
            with_session(s, |b| {
                let seeded = crate::pricing::seed(b, std::path::Path::new(&p.path))?;
                Ok(json!({
                    "adopted": seeded.adopted,
                    "effectiveFrom": seeded.effective_from,
                    "models": seeded.models,
                    "hasPrices": !b.prices.is_empty(),
                }))
            })
        }

        // Long running and it talks to the network, same rule as `sync.run`:
        // not from a thread that draws. This is the in-process path to the
        // refresh the daemon already runs on its own schedule — a machine
        // with no host agent installed has no scheduler of its own, so the
        // app asks for it.
        "pricing.refresh" => with_session(s, |b| {
            let refreshed = tokenstat_sync::pricing::refresh(false).envelope()?;
            // The session's cached book predates this fetch. Reload it here so
            // the very next report prices against the new rates instead of the
            // empty book the session opened with.
            crate::pricing::reload(b);
            serde_json::to_value(json!({
                "effectiveFrom": refreshed.effective_from,
                "models": refreshed.models,
                "hasPrices": !b.prices.is_empty(),
            }))
            .envelope()
        }),

        // Remote vendor usage is fetched only after an explicit user action.
        // Local log scanning remains separate and never needs the network.
        "fetch" => with_session(s, |b| {
            let tz = b.timezone().clone();
            let reports = tokenstat_sync::fetch_remotes(b.engine_mut()?.store_mut(), &tz, false)
                .envelope()?;
            serde_json::to_value(reports).envelope()
        }),

        other => match local_jobs(other, params) {
            Some(result) => result,
            None => match sessionless(other, params) {
                Some(result) => result.map_err(DispatchError::from),
                None => Err(DispatchError::new(
                    "unknown_method",
                    format!("unknown method: {other}"),
                )),
            },
        },
    }
}

/// Automations: local work, and nothing to do with the archive.
///
/// Split out of the big match so the whole family carries one `cfg` rather than
/// fifteen. Still called from `dispatch`, so an automation runs under the
/// session lock. Its sibling family, the todo board, is answered from
/// `sessionless` instead: see the note there. Automations stayed because they
/// start and stop real processes, which is a larger change to make on the
/// strength of the same argument.
#[cfg(feature = "local-host")]
fn local_jobs(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    if !method.starts_with("automation.") {
        return None;
    }
    Some(local_job_call(method, params))
}

/// The same split `folders` and `folder_call` use: one function decides whether
/// the method belongs here, the other answers it. That keeps `?` usable in the
/// arms, which a function returning `Option` cannot do.
#[cfg(feature = "local-host")]
fn chat_call(method: &str, params: &str) -> Result<Value, DispatchError> {
    let p: ChatParams = parse(params)?;
    let store = crate::chat::shared();
    match method {
        "chat.list" => serde_json::to_value(
            store.list(&p.workspace_id.ok_or("chat.list needs a workspaceId")?),
        )
        .envelope(),
        "chat.create" => serde_json::to_value(store.create(p.create())?).envelope(),
        "chat.update" => serde_json::to_value(
            store.update(&p.id.clone().ok_or("chat.update needs id")?, p.changes())?,
        )
        .envelope(),
        "chat.remove" => {
            Ok(json!({ "removed": store.remove(&p.id.ok_or("chat.remove needs id")?)? }))
        }
        "chat.send" => serde_json::to_value(store.send(
            &p.id.ok_or("chat.send needs id")?,
            &p.text.ok_or("chat.send needs text")?,
            &p.attachment_ids.unwrap_or_default(),
        )?)
        .envelope(),
        "chat.attach" => serde_json::to_value(store.attach(
            &p.id.ok_or("chat.attach needs id")?,
            &p.name.ok_or("chat.attach needs name")?,
            &p.data.ok_or("chat.attach needs data")?,
            p.media_type,
        )?)
        .envelope(),
        "chat.stop" => {
            store.stop(&p.id.ok_or("chat.stop needs id")?)?;
            Ok(json!({ "stopped": true }))
        }
        "chat.events" => {
            let (events, next) =
                store.events(&p.id.ok_or("chat.events needs id")?, p.offset.unwrap_or(0))?;
            Ok(json!({ "events": events, "nextOffset": next }))
        }
        "chat.backends" => Ok(Value::Array(crate::chat::backends())),
        other => Err(format!("unknown chat method: {other}").into()),
    }
}

#[cfg(feature = "local-host")]
fn local_job_call(method: &str, params: &str) -> Result<Value, DispatchError> {
    match method {
        // Workspaces are registered folders, nothing to do with the archive.
        "automation.list" => serde_json::to_value(crate::automations::shared().list()).envelope(),
        "automation.create" => {
            let mut p: AutomationParams = parse(params)?;
            let mut job = p.job.take().ok_or("automation.create needs job")?;
            if job.id.is_empty() {
                job.id = format!("automation-{}", now_ms());
            }
            serde_json::to_value(crate::automations::shared().create(job)?).envelope()
        }
        "automation.update" => {
            let p: AutomationParams = parse(params)?;
            serde_json::to_value(
                crate::automations::shared().update(p.job.ok_or("automation.update needs job")?)?,
            )
            .envelope()
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
            .envelope()
        }
        "automation.run" => {
            let p: AutomationParams = parse(params)?;
            serde_json::to_value(
                crate::automations::shared().run(&p.id.ok_or("automation.run needs id")?)?,
            )
            .envelope()
        }
        "automation.runs" => serde_json::to_value(crate::automations::shared().runs()).envelope(),
        "automation.backends" => Ok(serde_json::Value::Array(crate::automations::backends())),
        "automation.interactiveCommand" => {
            let p: AutomationParams = parse(params)?;
            let backend = p
                .backend
                .as_deref()
                .ok_or("automation.interactiveCommand needs backend")?;
            let prompt = p
                .prompt
                .as_deref()
                .ok_or("automation.interactiveCommand needs prompt")?;
            let argv = crate::automations::interactive_agent_command(
                backend,
                prompt,
                p.model.as_deref(),
                p.effort.as_deref(),
            )?;
            Ok(json!({"argv": argv}))
        }
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
        "automation.queue" => {
            serde_json::to_value(crate::automations::shared().queue_config()).envelope()
        }
        "automation.setQueue" => {
            let p: AutomationParams = parse(params)?;
            let current = crate::automations::shared().queue_config();
            let next = crate::automations::QueueConfig {
                default_budget_seconds: p
                    .default_budget_seconds
                    .unwrap_or(current.default_budget_seconds),
                max_concurrent: p.max_concurrent.unwrap_or(current.max_concurrent),
            };
            serde_json::to_value(crate::automations::shared().apply_queue_config(next)?).envelope()
        }

        "todo.list" => {
            let p: TodoParams = parse(params)?;
            serde_json::to_value(
                crate::todo::shared().list_with(p.include_archived.unwrap_or(false)),
            )
            .envelope()
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
                backend: p.backend.unwrap_or_default(),
                model: p.model,
                effort: p.effort,
                workspace_id: p.workspace_id.unwrap_or_default(),
                budget_seconds: p.budget_seconds.unwrap_or_else(|| {
                    crate::automations::shared()
                        .queue_config()
                        .default_budget_seconds
                }),
                created_at_ms: 0,
                updated_at_ms: 0,
                delegate: None,
            };
            serde_json::to_value(crate::todo::shared().create(card)?).envelope()
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
            .envelope()
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
            .envelope()
        }
        "todo.stop" => {
            let p: TodoParams = parse(params)?;
            serde_json::to_value(crate::todo::shared().stop(&p.id.ok_or("todo.stop needs an id")?)?)
                .envelope()
        }

        other => Err(DispatchError::new(
            "unknown_method",
            format!("unknown method: {other}"),
        )),
    }
}

/// Without `local-host` there is nothing here to run.
#[cfg(not(feature = "local-host"))]
fn local_jobs(_method: &str, _params: &str) -> Option<Result<Value, DispatchError>> {
    None
}

/// Anything under the system temp directory is hidden from the workspace list.
///
/// Test repositories live there and must never appear in the user's list if a
/// test process was interrupted mid-cleanup. This used to match two known name
/// prefixes, which is exactly the wrong shape: it hid the leaks it already knew
/// about and showed every new one. A third prefix duly appeared and landed in
/// the interface. The location is the signal, not the name, and nobody keeps a
/// project they are working in inside a folder the system deletes.
#[cfg(feature = "local-host")]
fn is_test_workspace(ws: &tokenstat_workspace::Workspace) -> bool {
    let temp = std::fs::canonicalize(std::env::temp_dir()).unwrap_or_else(|_| std::env::temp_dir());
    ws.path.starts_with(temp)
}

#[cfg(feature = "local-host")]
fn workflows(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("workflow.") {
        return None;
    }
    Some(workflow_call(method, params))
}

/// Workflow graphs live on their own store. Design drains a backend for up
/// to three minutes, so it must not sit on the archive lock.
#[cfg(feature = "local-host")]
fn workflow_call(method: &str, params: &str) -> Result<Value, String> {
    match method {
        "workflow.list" => {
            serde_json::to_value(crate::workflows::shared().list()).map_err(|e| e.to_string())
        }
        "workflow.get" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            serde_json::to_value(
                crate::workflows::shared().get(&p.id.ok_or("workflow.get needs id")?)?,
            )
            .map_err(|e| e.to_string())
        }
        "workflow.create" => {
            let mut p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let mut workflow = p.workflow.take().ok_or("workflow.create needs workflow")?;
            if workflow.id.is_empty() {
                workflow.id = format!("wf-{}", now_ms());
            }
            serde_json::to_value(crate::workflows::shared().create(workflow)?)
                .map_err(|e| e.to_string())
        }
        "workflow.update" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            serde_json::to_value(
                crate::workflows::shared()
                    .update(p.workflow.ok_or("workflow.update needs workflow")?)?,
            )
            .map_err(|e| e.to_string())
        }
        "workflow.remove" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            Ok(json!({
                "removed": crate::workflows::shared()
                    .remove(&p.id.ok_or("workflow.remove needs id")?)?
            }))
        }
        "workflow.run" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            serde_json::to_value(crate::workflows::shared().run(
                &p.id.ok_or("workflow.run needs id")?,
                p.input,
                p.workspace_id,
            )?)
            .map_err(|e| e.to_string())
        }
        "workflow.runs" => {
            serde_json::to_value(crate::workflows::shared().runs()).map_err(|e| e.to_string())
        }
        "workflow.transcript" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let id = p.id.ok_or("workflow.transcript needs a run id")?;
            let node = p.node_id.ok_or("workflow.transcript needs nodeId")?;
            let (text, next) =
                crate::workflows::shared().transcript(&id, &node, p.offset.unwrap_or(0))?;
            Ok(json!({"text": text, "nextOffset": next}))
        }
        "workflow.kill" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            crate::workflows::shared().kill(&p.id.ok_or("workflow.kill needs a run id")?)?;
            Ok(json!({"killed": true}))
        }
        "workflow.continue" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            serde_json::to_value(
                crate::workflows::shared()
                    .continue_run(&p.id.ok_or("workflow.continue needs a run id")?)?,
            )
            .map_err(|e| e.to_string())
        }
        "workflow.design" => {
            let p: WorkflowParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            crate::workflows::design(
                p.prompt.as_deref().ok_or("workflow.design needs prompt")?,
                p.workspace_id.as_deref(),
                p.backend.as_deref(),
                p.model.as_deref(),
                p.effort.as_deref(),
            )
        }
        other => Err(format!("unknown method: {other}")),
    }
}

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
#[cfg(feature = "local-host")]
fn folders(method: &str, params: &str) -> Option<Result<Value, String>> {
    match method {
        "workspace.list"
        | "workspace.add"
        | "workspace.remove"
        | "workspace.rename"
        | "workspace.status"
        | "workspace.summary"
        | "workspace.log"
        | "workspace.tree"
        | "workspace.branches"
        | "workspace.checkout"
        | "workspace.createBranch"
        | "workspace.show"
        | "workspace.diff"
        | "workspace.read"
        | "workspace.stage"
        | "workspace.unstage"
        | "workspace.commit"
        | "workspace.write"
        | "workspace.push"
        | "pty.spawn" => {}
        _ => return None,
    }
    Some(folder_call(method, params))
}

/// Everything a batch of summaries counts, read once.
///
/// Hoisted out of `summarize` because none of it is per-folder. Reading it
/// inside the loop meant a summary of eight folders did eight of each read,
/// and `Board::list_with` is not a getter: it reconciles delegate statuses
/// against the run list and writes the board when one moved, so the call that
/// exists to save work was doing eight times the work it replaced.
#[cfg(feature = "local-host")]
struct FolderContents {
    sessions: Vec<tokenstat_pty::SessionInfo>,
    cards: Vec<crate::todo::Card>,
    automations: Vec<Automation>,
    workflows: Vec<crate::workflows::Workflow>,
    runs: Vec<crate::workflows::WorkflowRun>,
}

#[cfg(feature = "local-host")]
impl FolderContents {
    fn read() -> Self {
        Self {
            sessions: tokenstat_pty::manager().list(),
            cards: crate::todo::shared().list_with(false),
            automations: crate::automations::shared().list(),
            workflows: crate::workflows::shared().list(),
            runs: crate::workflows::shared().runs(),
        }
    }
}

/// Count what one folder is holding.
///
/// A session is matched by its workspace id, falling back to its working
/// directory for a pty the host spawned without one. Hidden ptys are daemon
/// jobs and are not sessions a person opened, so they are not counted as any.
#[cfg(feature = "local-host")]
fn summarize(ws: &tokenstat_workspace::Workspace, live: &FolderContents) -> WorkspaceSummaryDto {
    let described = describe(ws);
    let path = ws.path.display().to_string();
    let inside = format!("{path}/");
    WorkspaceSummaryDto {
        id: ws.id.clone(),
        sessions: live
            .sessions
            .iter()
            .filter(|s| s.alive && !s.hidden)
            .filter(|s| match s.workspace_id.as_deref() {
                Some(id) if !id.is_empty() => id == ws.id,
                _ => s.cwd == path || s.cwd.starts_with(&inside),
            })
            .count(),
        changed: described.git.as_ref().map(|g| g.files.len()),
        pulls: crate::pulls::cached_open_count(&ws.id),
        tasks: live
            .cards
            .iter()
            .filter(|c| {
                c.workspace_id == ws.id
                    && c.kind != crate::todo::CardKind::Note
                    && c.column != "done"
                    && c.column != "archive"
            })
            .count(),
        notes: live
            .cards
            .iter()
            .filter(|c| {
                c.workspace_id == ws.id
                    && c.kind == crate::todo::CardKind::Note
                    && c.column != "archive"
            })
            .count(),
        workflows: live
            .workflows
            .iter()
            .filter(|w| {
                w.scope == crate::workflows::WorkflowScope::Workspace
                    && w.workspace_id.as_deref() == Some(ws.id.as_str())
            })
            .count(),
        workflows_running: live
            .runs
            .iter()
            .filter(|r| r.workspace_id == ws.id && (r.status == "running" || r.status == "waiting"))
            .count(),
        automations: live
            .automations
            .iter()
            .filter(|j| j.workspace_id == ws.id)
            .count(),
    }
}

/// The bodies, split out so they can use `?` on a `Result`.
///
/// Each takes the registry lock only long enough to copy the folder it needs.
/// Nothing here runs a subprocess with a guard in hand.
#[cfg(feature = "local-host")]
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
            invalidate_workspace_status(Some(&ws.id));
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
                invalidate_workspace_status(Some(&p.id));
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
                invalidate_workspace_status(Some(&p.id));
            }
            Ok(json!({"renamed": renamed}))
        }

        "workspace.status" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            // Explicit status is a "tell me now" call: never serve a cached
            // answer for it.
            invalidate_workspace_status(Some(&p.id));
            let ws = crate::workspaces::get(&p.id)?;
            serde_json::to_value(describe(&ws)).map_err(|e| e.to_string())
        }

        "workspace.branches" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let ws = crate::workspaces::folder(&p.id)?;
            serde_json::to_value(tokenstat_workspace::git::branches(&ws.path))
                .map_err(|e| e.to_string())
        }

        // Counts for a folder's badges, or every folder's. One call because a
        // front end drawing six folders' badges was making five list calls per
        // folder and counting them itself, which is thirty round trips from a
        // phone for a screen that is mostly numbers, and it put the definition
        // of "what a folder has in it" in two clients at once.
        //
        // Cheap by construction: git comes from the same cached `describe` the
        // folder list uses, and the other four are in-memory registry reads.
        // Nothing here touches the archive.
        "workspace.summary" => {
            let p: WorkspaceSummaryParams = serde_json::from_str(params.trim()).unwrap_or_default();
            let folders: Vec<tokenstat_workspace::Workspace> = match p.id {
                Some(id) => vec![crate::workspaces::get(&id)?],
                None => crate::workspaces::read().workspaces.clone(),
            };
            let live = FolderContents::read();
            let summaries: Vec<WorkspaceSummaryDto> =
                folders.iter().map(|ws| summarize(ws, &live)).collect();
            serde_json::to_value(summaries).map_err(|e| e.to_string())
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
        "workspace.checkout" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let branch = p.branch.ok_or("workspace.checkout needs a branch")?;
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = tokenstat_workspace::gitwrite::checkout(&ws.path, &branch, p.remote);
            invalidate_workspace_status(Some(&p.id));
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        "workspace.createBranch" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let branch = p.branch.ok_or("workspace.createBranch needs a branch")?;
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome =
                tokenstat_workspace::gitwrite::create_branch(&ws.path, &branch, p.from.as_deref());
            invalidate_workspace_status(Some(&p.id));
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

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
            invalidate_workspace_status(Some(&p.id));
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        "workspace.commit" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let message = p.message.unwrap_or_default();
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = tokenstat_workspace::gitwrite::commit(&ws.path, &message);
            invalidate_workspace_status(Some(&p.id));
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        "workspace.write" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let path = p.path.ok_or("workspace.write needs a path")?;
            let content = p.content.ok_or("workspace.write needs content")?;
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = tokenstat_workspace::gitwrite::write_text(&ws.path, &path, &content);
            invalidate_workspace_status(Some(&p.id));
            serde_json::to_value(outcome).map_err(|e| e.to_string())
        }

        "workspace.push" => {
            let p: WorkspaceIdParams =
                serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let ws = crate::workspaces::folder(&p.id)?;
            let outcome = tokenstat_workspace::gitwrite::push(&ws.path);
            invalidate_workspace_status(Some(&p.id));
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
                    "dark": p.dark,
                    "modelProvider": p.model_provider,
                    "modelId": p.model_id,
                    "hidden": p.hidden,
                });
                let mut value =
                    crate::remote::call_peer_result(peer, "pty.spawn", &forwarded.to_string())?;
                // Peer-local ids, before we prefix them. The cache is served
                // as the live list, so a stamp-only invalidate still hid this
                // session and the app treated it as gone.
                crate::remote_stream::remember_pty_session(peer, &value);
                renamespace_session(&mut value, peer);
                return Ok(value);
            }
            let ws = crate::workspaces::folder(&p.workspace_id)?;
            let environment = crate::launcher::model_environment(
                &p.command,
                p.model_provider.as_deref(),
                p.model_id.as_deref(),
            )?;
            // The selection's arguments are appended here rather than sent by
            // the caller, so the two halves of one harness contract are decided
            // together and a remote spawn gets the peer's own mapping.
            let mut args = p.args.clone();
            args.extend(crate::launcher::model_arguments(
                &p.command,
                p.model_provider.as_deref(),
                p.model_id.as_deref(),
            ));
            let info = tokenstat_pty::manager()
                .spawn(&tokenstat_pty::Spawn {
                    command: p.command.clone(),
                    args,
                    cwd: ws.path.clone(),
                    workspace_id: Some(ws.id.clone()),
                    hidden: p.hidden,
                    rows: p.rows,
                    cols: p.cols,
                    no_color: p.no_color,
                    dark: p.dark,
                    environment,
                })
                .map_err(|e| e.to_string())?;
            serde_json::to_value(info).map_err(|e| e.to_string())
        }
        // `folders` filtered these, so nothing else can arrive.
        other => Err(format!("unknown folder method: {other}")),
    }
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
fn sessionless(method: &str, params: &str) -> Option<Result<Value, String>> {
    if owner_only_method(method)
        && let Err(e) = crate::request_context::refuse_remote("account and update methods")
    {
        return Some(Err(e));
    }
    // Who is answering, without opening an archive to say it.
    //
    // A front end prefers a running daemon, and that daemon outlives the app
    // that installed it, so an app can end up talking to a helper from an
    // older release. Every method added since is then "unknown method", which
    // is true and useless. This is the one call a client can make first to
    // find out, and it is deliberately cheap: `info` opens the archive.
    if method == "protocol" {
        return Some(Ok(json!({
            "protocolVersion": crate::PROTOCOL_VERSION,
            "coreVersion": tokenstat_core::VERSION,
        })));
    }
    if let Some(answer) = crate::cloud_import::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::screen_viewer::call(method, params) {
        return Some(answer);
    }
    #[cfg(feature = "local-host")]
    if let Some(answer) = crate::screen_runtime::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::screen_transfer::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::workspace_policy::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::screen_policy::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::ssh_client::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::ssh_records::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::vault::call(method, params) {
        return Some(answer);
    }
    // Identity and the peer list. Sessionless because the Machines screen is
    // where somebody goes when something is wrong, and an archive that will not
    // open must not take it away from them.
    if let Some(answer) = crate::machine::call(method, params) {
        return Some(answer);
    }

    if let Some(answer) = crate::host_policy::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = crate::host_stats::call(method, params) {
        return Some(answer);
    }

    // Serving and reaching other machines. None of these read the archive, and
    // a call being forwarded to an idle machine must not queue behind a scan
    // running on this one.
    if let Some(answer) = crate::remote::call(method, params) {
        return Some(answer);
    }

    // The tasks board. Its own store behind its own lock, and it never touches
    // the archive, so it has no business waiting on one. Under the session lock
    // the board queued behind whatever else held it: a report, a sync, or
    // another machine asking this one for a report over the tunnel. The menu
    // bar knew there were six tasks and the list they belonged to never
    // arrived.
    #[cfg(feature = "local-host")]
    if method.starts_with("todo.") {
        return Some(local_job_call(method, params).map_err(|e| e.message));
    }

    #[cfg(feature = "local-host")]
    if method.starts_with("chat.") {
        return Some(chat_call(method, params).map_err(|e| e.message));
    }

    // Folders and terminals. Same reasoning: none of it reads the archive.
    #[cfg(feature = "local-host")]
    if let Some(answer) = folders(method, params) {
        return Some(answer);
    }
    #[cfg(feature = "local-host")]
    if let Some(answer) = crate::pulls::call(method, params) {
        return Some(answer);
    }
    if let Some(answer) = terminals(method, params) {
        return Some(answer);
    }

    #[cfg(feature = "local-host")]
    if let Some(answer) = workflows(method, params) {
        return Some(answer);
    }

    #[cfg(feature = "local-host")]
    if method == "local.models" {
        return Some(
            crate::local_models::discover()
                .and_then(|providers| serde_json::to_value(providers).map_err(|e| e.to_string())),
        );
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
                    // Windows desktop zip. Distinct from the CLI's
                    // target-triple zip. Unsigned preview builds skip
                    // Authenticode in the app, the way a local Mac build
                    // skips Developer ID.
                    "winZipUrl": check.app_win_url,
                    "winZipName": check.app_win_name,
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

        // Same contract as `app.updateDownload`, for the Windows zip.
        "app.updateDownloadWin" => tokenstat_sync::download_windows_app_archive()
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

        // Call a device on this account something, from any front end. The
        // label lives on the account row rather than on the machine, which is
        // what lets this app name a headless server it will never log into.
        "account.renameMachine" => {
            #[derive(Deserialize)]
            struct RenameParams {
                id: String,
                #[serde(default)]
                name: String,
            }
            let p: RenameParams = match serde_json::from_str(params.trim()) {
                Ok(p) => p,
                Err(e) => return Some(Err(e.to_string())),
            };
            if let Err(e) = tokenstat_sync::profile::rename_machine(None, &p.id, &p.name) {
                return Some(Err(e.to_string()));
            }
            crate::account_activity::invalidate();
            Ok(json!({"renamed": true, "id": p.id, "name": p.name.trim()}))
        }

        // Say what this computer is, again.
        //
        // The record is published at login and never retried, so one failed
        // call there left the machine unknown to the account and every call
        // that needs a device (the vault, above all) refused from then on. The
        // vault heals this by itself now; this is the button for a person who
        // has been told their computer is not on their account and wants to do
        // something about it.
        "account.registerMachine" => {
            if let Err(e) = tokenstat_sync::profile::publish_machine_profile(None) {
                return Some(Err(e.to_string()));
            }
            crate::account_activity::invalidate();
            Ok(json!({"registered": true}))
        }

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

        _ => return None,
    })
}

/// Terminals, agent launches, and the streams and proxies that carry them.
///
/// One `cfg` for the whole family rather than one per arm, and the same
/// decide-then-answer split `folders` uses so `?` still works in the arms.
/// None of it exists without `local-host`: a platform with no fork has no
/// terminal to list, and a client asking for one is asking the wrong machine.
#[cfg(feature = "local-host")]
fn terminals(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("pty.")
        && !method.starts_with("launcher.")
        && !method.starts_with("harness.")
        && !method.starts_with("stream.")
        && !method.starts_with("proxy.")
    {
        return None;
    }
    Some(terminal_call(method, params))
}

#[cfg(feature = "local-host")]
fn terminal_call(method: &str, params: &str) -> Result<Value, String> {
    match method {
        "pty.list" => {
            let include_remote = serde_json::from_str::<PtyListParams>(params.trim())
                .map(|p| p.include_remote)
                .unwrap_or(true);
            let mut items: Vec<Value> = match serde_json::to_value(tokenstat_pty::manager().list())
            {
                Ok(Value::Array(items)) => items,
                Ok(_) => return Err("pty.list returned a non-array".into()),
                Err(e) => return Err(e.to_string()),
            };
            for item in &mut items {
                add_activity(item);
            }
            if include_remote {
                // One level deep on purpose: each peer is asked with
                // includeRemote=false, so the account cannot recurse A→B→A.
                // The merge is served from cache and refreshed off this
                // thread: a tunnel redial after a path change must not hold
                // the local list (the app's patience is 10s, the channel
                // open is also 10s).
                items.extend(crate::remote_stream::remote_pty_lists());
            }
            Ok(Value::Array(items))
        }

        "pty.info" => {
            if let Some(answer) = route_remote_pty("pty.info", params) {
                return answer;
            }
            pty_id(params).and_then(|p| {
                let manager = tokenstat_pty::manager();
                // Also a lease refresh, and for one caller it is the only one.
                // A Mac showing another machine's terminal has its `pty.read`
                // answered from a locally pushed cache, so those reads never
                // reach the machine that owns the pty and cannot say anybody is
                // still watching. Liveness polling does reach it, so without
                // this that viewer expires every fifteen seconds and the
                // terminal's width flaps between the two machines.
                if let Some(viewer) = p.viewer.as_deref().filter(|v| !v.is_empty()) {
                    let _ = manager.touch_viewer(&p.id, viewer);
                }
                let info = manager.info(&p.id).map_err(|e| e.to_string())?;
                let mut value = serde_json::to_value(info).map_err(|e| e.to_string())?;
                add_activity(&mut value);
                Ok(value)
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
                    return Ok(answer);
                }
            }
            if let Some(answer) = route_remote_pty("pty.read", params) {
                return answer;
            }
            pty_id(params).and_then(|p| {
                let manager = tokenstat_pty::manager();
                // Watching is what keeps a viewer's lease alive, so the size
                // agreement needs nothing the client has to remember to send.
                // Before the hold, not after: a held read can park for a
                // quarter second, and a lease that only refreshed on the way
                // out would be that much staler for no reason.
                if let Some(viewer) = p.viewer.as_deref().filter(|v| !v.is_empty()) {
                    let _ = manager.touch_viewer(&p.id, viewer);
                }
                let mut chunk = match p.viewer.as_deref() {
                    Some(viewer) => manager
                        .read_for_viewer(&p.id, viewer, p.offset)
                        .map_err(|e| e.to_string())?,
                    None => manager.read(&p.id, p.offset).map_err(|e| e.to_string())?,
                };
                // Hold the call open until there is something to say, or the
                // caller's patience runs out. Capped so a connection is never
                // parked for long: this occupies one socket and one thread, and
                // only the session somebody is looking at asks for it.
                //
                // Polled rather than woken by the buffer, because the buffer has
                // no condition variable and giving it one reaches into every
                // writer. At three milliseconds the wait costs a few hundred
                // cheap lock-and-look passes a second on one session, and it
                // buys back the interval a client would otherwise wait on every
                // single keystroke.
                if let Some(wait) = p.wait_ms.filter(|w| *w > 0) {
                    let deadline =
                        std::time::Instant::now() + Duration::from_millis(wait.min(1_000));
                    while chunk.bytes.is_empty() && std::time::Instant::now() < deadline {
                        std::thread::sleep(Duration::from_millis(3));
                        chunk = match p.viewer.as_deref() {
                            Some(viewer) => manager
                                .read_for_viewer(&p.id, viewer, p.offset)
                                .map_err(|e| e.to_string())?,
                            None => manager.read(&p.id, p.offset).map_err(|e| e.to_string())?,
                        };
                    }
                }
                Ok(json!({
                    "data": crate::base64::encode(&chunk.bytes),
                    "nextOffset": chunk.next_offset,
                    "dropped": chunk.dropped,
                    "paused": chunk.paused,
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
                let bytes = crate::base64::decode(&data)?;
                // False means there is no live channel to that session, which
                // is not a failure: fall through to the request round trip.
                if crate::remote_stream::write_pty_input(peer, session, &bytes)? {
                    return Ok(json!({"written": bytes.len()}));
                }
            }
            if let Some(answer) = route_remote_pty("pty.write", params) {
                return answer;
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
                return answer;
            }
            pty_id(params).and_then(|p| {
                let (rows, cols) = match (p.rows, p.cols) {
                    (Some(r), Some(c)) => (r, c),
                    _ => return Err("pty.resize needs rows and cols".into()),
                };
                let manager = tokenstat_pty::manager();
                match p.viewer.as_deref() {
                    Some(viewer) if !viewer.is_empty() => manager
                        .resize_viewer(&p.id, viewer, rows, cols)
                        .map_err(|e| e.to_string())?,
                    _ => manager
                        .resize(&p.id, rows, cols)
                        .map_err(|e| e.to_string())?,
                }
                // What the session actually became, which is not what was asked
                // for when a smaller viewer is also attached. The caller needs
                // the real answer: it draws that geometry.
                let info = manager.info(&p.id).map_err(|e| e.to_string())?;
                Ok(json!({"rows": info.rows, "cols": info.cols}))
            })
        }

        // A front end has stopped showing a session, without killing it.
        //
        // Only the size agreement cares. The lease would expire on its own, so
        // this is not what makes the feature correct, it is what makes it feel
        // immediate: close a session on the phone and the Mac is back to its
        // own width before the animation finishes.
        "pty.detach" => {
            if let Some(answer) = route_remote_pty("pty.detach", params) {
                return answer;
            }
            pty_id(params).and_then(|p| {
                if let Some(viewer) = p.viewer.as_deref().filter(|v| !v.is_empty()) {
                    tokenstat_pty::manager()
                        .drop_viewer(&p.id, viewer)
                        .map_err(|e| e.to_string())?;
                }
                Ok(json!({"detached": true}))
            })
        }

        "pty.kill" => {
            if let Some(answer) = route_remote_pty("pty.kill", params) {
                return answer;
            }
            pty_id(params).and_then(|p| {
                tokenstat_pty::manager()
                    .kill(&p.id)
                    .map_err(|e| e.to_string())?;
                Ok(json!({"killed": true}))
            })
        }

        "pty.close" => {
            if let Some(answer) = route_remote_pty("pty.close", params) {
                if answer.is_ok()
                    && let Ok(parsed) = serde_json::from_str::<PtyIdParams>(params.trim())
                    && let Some((peer, inner)) = split_remote(&parsed.id)
                {
                    crate::remote_stream::forget_pty_session(peer, inner);
                }
                return answer;
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

        // Run a catalog profile's official installer on this machine. The id
        // names a command hardcoded in the catalog, never one supplied by the
        // client, so over a remote connection this stays "the user clicked
        // Install on a known tile" rather than "a peer runs anything".
        "launcher.install" => {
            #[derive(Deserialize)]
            struct InstallParams {
                id: String,
            }
            let p: InstallParams = match serde_json::from_str(params.trim()) {
                Ok(p) => p,
                Err(e) => return Err(e.to_string()),
            };
            crate::launcher::install(&p.id)
        }

        // Take a profile off this machine's launcher, or put it back. The
        // set lives on the host so a phone that asks `launcher.catalog`
        // sees the same grid as the Mac. Id only, same rule as install.
        "launcher.hide" => {
            #[derive(Deserialize)]
            struct HideParams {
                id: String,
            }
            let p: HideParams = match serde_json::from_str(params.trim()) {
                Ok(p) => p,
                Err(e) => return Err(e.to_string()),
            };
            crate::launcher::hide(&p.id)
        }
        "launcher.show" => {
            #[derive(Deserialize)]
            struct ShowParams {
                id: String,
            }
            let p: ShowParams = match serde_json::from_str(params.trim()) {
                Ok(p) => p,
                Err(e) => return Err(e.to_string()),
            };
            crate::launcher::show(&p.id)
        }

        // Allowlisted settings behind the launcher (i) badge. The form
        // names the file. Save is the only write. Unknown keys are refused.
        "harness.config.get" => {
            #[derive(Deserialize)]
            struct GetParams {
                id: String,
            }
            let p: GetParams = match serde_json::from_str(params.trim()) {
                Ok(p) => p,
                Err(e) => return Err(e.to_string()),
            };
            crate::harness_config::get(&p.id)
        }
        "harness.config.set" => {
            #[derive(Deserialize)]
            struct SetParams {
                id: String,
                values: serde_json::Map<String, serde_json::Value>,
            }
            let p: SetParams = match serde_json::from_str(params.trim()) {
                Ok(p) => p,
                Err(e) => return Err(e.to_string()),
            };
            crate::harness_config::set(&p.id, &p.values)
        }

        // Remove a machine from the account directory. The server deletes its
        // uploaded rows, so this is an explicit action for a machine id that
        // is stale (a reinstall) or otherwise holding a machine-cap slot.
        // A byte stream between machines. Runs on the machine that owns the
        // resource: it reserves a stream and returns a token; the caller then
        // dials a fresh connection and claims it with `{"stream": token}` as
        // its first message.
        "stream.open" => stream_open(params),

        // Bind a loopback port here and bridge every accepted connection to a
        // proxy stream on the peer, so a browser tab can reach a service on
        // the other machine's own localhost. The listener binds loopback only.
        "proxy.listen" => proxy_listen(params),
        "proxy.unlisten" => proxy_unlisten(params),

        other => Err(format!("unknown method: {other}")),
    }
}

/// Client builds: no local pty, but a phone can still bridge a loopback port
/// to a service on a host (Browse port in the mobile workspace UI).
#[cfg(not(feature = "local-host"))]
fn terminals(method: &str, params: &str) -> Option<Result<Value, String>> {
    match method {
        "proxy.listen" => Some(client_proxy_listen(params)),
        "proxy.unlisten" => Some(client_proxy_unlisten(params)),
        _ => None,
    }
}

#[cfg(not(feature = "local-host"))]
fn client_proxy_listen(params: &str) -> Result<Value, String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Params {
        peer: String,
        host: Option<String>,
        port: u16,
    }
    let p: Params = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    crate::remote_proxy::listen(&p.peer, p.host.as_deref().unwrap_or("127.0.0.1"), p.port)
}

#[cfg(not(feature = "local-host"))]
fn client_proxy_unlisten(params: &str) -> Result<Value, String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Params {
        peer: String,
        host: Option<String>,
        port: u16,
    }
    let p: Params = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    crate::remote_proxy::unlisten(&p.peer, p.host.as_deref().unwrap_or("127.0.0.1"), p.port)
}

/// Ask the vendors again, and post the answer if the user opted in.
///
/// The scheduler's door into the same pass a front end triggers, so there is
/// one place that decides what a reading is and one place that sends it. See
/// `sync_scheduler::post_limits` for why this cannot wait for somebody to open
/// a window. Windows hostd runs the same scheduler as macOS, so this cannot
/// stay unix-only.
#[cfg(feature = "local-host")]
pub(crate) fn refresh_plan_limits() {
    let _ = usage_limits();
}

/// Ask every vendor what is left of its plan.
///
/// On a host (Mac and Windows): live vendor reads, optional post to the
/// account when the opt-in switch is on (P2). On a client (phone): GET the
/// account store, which is what hosts posted.
///
/// One refresh at a time, and that lock is the only thing this serializes
/// against. The session used to provide the same guarantee by accident, and it
/// charged every other screen for it. Two screens asking at once should share
/// the wait, not fan out ten requests.
fn usage_limits() -> Value {
    static REFRESH: Mutex<()> = Mutex::new(());
    let _one_at_a_time = REFRESH.lock().unwrap_or_else(PoisonError::into_inner);

    // A tail expression, not a `return`: with `local-host` off this block is
    // the whole function body, and clippy's client-build pass rejects the
    // early return that reads naturally when both halves are present.
    #[cfg(not(feature = "local-host"))]
    {
        account_plane_limits()
    }

    #[cfg(feature = "local-host")]
    {
        let skip = tokenstat_sync::config::limits_skip();
        let skipped = |id: &str| skip.iter().any(|s| s == id);
        let providers = std::thread::scope(|scope| {
            let claude = (!skipped("claude_code"))
                .then(|| scope.spawn(tokenstat_sync::claude_limits::fetch));
            let cursor = (!skipped("cursor")).then(|| scope.spawn(tokenstat_sync::cursor::limits));
            let grok = (!skipped("grok")).then(|| scope.spawn(tokenstat_sync::grok_limits::fetch));
            let opencode =
                (!skipped("opencode")).then(|| scope.spawn(tokenstat_sync::opencode_limits::fetch));
            let antigravity = (!skipped("antigravity"))
                .then(|| scope.spawn(tokenstat_sync::antigravity_ide::limits));
            let mut out = Vec::new();
            if !skipped("codex") {
                out.push(tokenstat_core::limits::codex_limits());
            }
            let take = |handle: Option<
                std::thread::ScopedJoinHandle<'_, tokenstat_core::limits::ProviderLimits>,
            >,
                        source: &str,
                        fail: &str| {
                handle.map(|h| {
                    h.join().unwrap_or_else(|_| {
                        tokenstat_core::limits::ProviderLimits::unavailable(source, fail)
                    })
                })
            };
            if let Some(p) = take(
                claude,
                "claude_code",
                "Reading the Claude Code limits failed unexpectedly.",
            ) {
                out.push(p);
            }
            if let Some(p) = take(
                cursor,
                "cursor",
                "Reading the Cursor limits failed unexpectedly.",
            ) {
                out.push(p);
            }
            if let Some(p) = take(grok, "grok", "Reading the Grok limits failed unexpectedly.") {
                out.push(p);
            }
            if let Some(p) = take(
                opencode,
                "opencode",
                "Reading the OpenCode limits failed unexpectedly.",
            ) {
                out.push(p);
            }
            if let Some(p) = take(
                antigravity,
                "antigravity",
                "Reading the Antigravity limits failed unexpectedly.",
            ) {
                out.push(p);
            }
            out
        });
        // A vendor that could not be read this time is not a vendor whose quota is
        // unknown. Remember every real reading and hand back the last one, marked
        // stale and dated, when a refresh comes back with only a reason.
        tokenstat_core::limits::cache::store(&providers);
        let providers = tokenstat_core::limits::cache::backfill(providers)
            .into_iter()
            .filter(|p| !skipped(&p.source))
            .collect::<Vec<_>>();
        // Opt-in P2 post: ride the same refresh the Mac already paid for.
        if tokenstat_sync::config::limits_sync_enabled() {
            let _ = tokenstat_sync::post_limits(None, Some(&providers));
        }
        // Every field here is plain data the vendors just returned, so the only way
        // this fails is a bug in the DTO, and an empty list says that plainly.
        serde_json::to_value(providers).unwrap_or_else(|_| json!([]))
    }
}

/// Plan limits from the account store (phone / client shape).
///
/// How old a posted reading may be before the phone marks it stale.
///
/// Wider than the host's refresh interval, so an ordinary hourly pass never
/// makes its own readings look doubtful, and narrow enough that a Mac that has
/// been shut since yesterday is not still quoting yesterday's quota as though
/// it were now.
#[cfg(not(feature = "local-host"))]
const READING_GOES_STALE_MS: i64 = 3 * 60 * 60 * 1000;

/// Hosts post; this only reads. Multiple machines can report the same source:
/// the newest reading wins so Home shows one row per provider.
#[cfg(not(feature = "local-host"))]
fn account_plane_limits() -> Value {
    use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};

    let Ok(rows) = tokenstat_sync::fetch_account_limits(None, None) else {
        return json!([]);
    };
    let mut best: std::collections::BTreeMap<String, ProviderLimits> =
        std::collections::BTreeMap::new();
    for row in rows {
        let windows: Vec<UsageWindow> = row
            .windows
            .iter()
            .map(|w| UsageWindow {
                label: w.label.clone(),
                percent: w.percent,
                resets_at_ms: w.resets_at_ms,
                severity: LimitSeverity::from_percent(w.percent),
            })
            .collect();
        if windows.is_empty() {
            continue;
        }
        // Staleness is decided here, from when the reading was taken, not
        // taken from the row. The account stores what a host posted and hands
        // it back with `stale: false` forever, so a percentage from last week
        // arrived on the phone looking like the current one. A quota display
        // that is confidently wrong about how much is left is worse than one
        // that admits its age.
        let age_ms = jiff::Timestamp::now().as_millisecond() - row.observed_at_ms;
        let stale = row.stale || age_ms > READING_GOES_STALE_MS;
        let reading = ProviderLimits {
            source: row.src.clone(),
            plan: row.plan.clone(),
            windows,
            observed_at_ms: row.observed_at_ms,
            note: row.machine.map(|m| format!("from {m}")),
            stale,
        };
        match best.get(&reading.source) {
            Some(prev) if prev.observed_at_ms >= reading.observed_at_ms => {}
            _ => {
                best.insert(reading.source.clone(), reading);
            }
        }
    }
    let out: Vec<_> = best.into_values().collect();
    serde_json::to_value(out).unwrap_or_else(|_| json!([]))
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
        "scheduledNetworkAllowed": tokenstat_sync::scheduled_network_allowed(),
        "due": due,
    }))
}

#[cfg(feature = "local-host")]
fn pty_id(params: &str) -> Result<PtyIdParams, String> {
    serde_json::from_str(params.trim()).map_err(|e| e.to_string())
}

/// `stream.open`: reserve a byte stream on this machine and hand out the token
/// the caller claims it with. The pump starts immediately and waits for the
/// connection, so `proxy` and `pty.subscribe` are ready the moment the token
/// is sent back over the call channel.
#[cfg(feature = "local-host")]
fn stream_open(params: &str) -> Result<Value, String> {
    let p: StreamOpenParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let (kind, screen_id) = match p.kind.as_str() {
        "proxy" => {
            let host = p.host.unwrap_or_else(|| "127.0.0.1".to_string());
            // The proxy bridges to the far machine's own loopback: the point
            // is "reach the service on that computer", not "use that computer
            // as a gateway into its network". Anything else is refused.
            if !matches!(host.as_str(), "127.0.0.1" | "localhost" | "::1" | "[::1]") {
                return Err("proxy target must be on the far machine's own loopback".into());
            }
            let port = p.port.ok_or("proxy stream needs a port")?;
            (crate::remote_stream::StreamKind::Proxy { host, port }, None)
        }
        "pty.subscribe" => {
            let session = p.id.ok_or("pty.subscribe needs a session id")?;
            // The session must exist here; the pump reads it by offset.
            tokenstat_pty::manager()
                .info(&session)
                .map_err(|e| e.to_string())?;
            (
                crate::remote_stream::StreamKind::PtySubscribe { session },
                None,
            )
        }
        "screen.video" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("screen.video must arrive over an authenticated remote connection")?;
            let capability = p.capability.ok_or("screen.video needs a capability")?;
            crate::screen_policy::verify_capability(&peer, &capability, p.control)?;
            let mut random = [0u8; 12];
            getrandom::fill(&mut random).map_err(|e| e.to_string())?;
            let id = format!("screen-{}", tokenstat_identity::hex(&random));
            (
                crate::remote_stream::StreamKind::Screen {
                    id: id.clone(),
                    peer,
                    control: p.control,
                    quality: p.quality,
                },
                Some(id),
            )
        }
        other => return Err(format!("unknown stream kind {other}")),
    };
    let token = crate::remote_stream::open(kind)?;
    Ok(json!({"token": token, "sessionID": screen_id}))
}

/// `proxy.listen`: bind a loopback port on this machine and bridge every
/// accepted connection to a proxy stream on the peer. Loopback only, so
/// nothing on this machine's network is exposed; the caller (a browser tab)
/// talks to the port as if the service were local.
#[cfg(feature = "local-host")]
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
                        Ok(connection) => {
                            crate::remote_stream::pump_local(tcp, connection, &host, target, port)
                        }
                        Err(error) => {
                            eprintln!("remote proxy: {peer} {host}:{target} failed: {error}");
                            crate::remote_stream::write_proxy_error(tcp, &error);
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

#[cfg(feature = "local-host")]
fn proxy_unlisten(params: &str) -> Result<Value, String> {
    let p: ProxyListenParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let host = p.host.as_deref().unwrap_or("127.0.0.1");
    let key = format!("{}:{host}:{}", p.peer, p.port);
    if let Some(stop) = proxy_listeners()
        .lock()
        .map_err(|e| e.to_string())?
        .remove(&key)
    {
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
    }
    Ok(json!({"stopped": true}))
}

/// How many loopback bridges a daemon will hold at once. Browsed ports are
/// cheap but not free, and each one parks a thread.
#[cfg(feature = "local-host")]
const MAX_PROXY_LISTENERS: usize = 16;

#[cfg(feature = "local-host")]
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
#[cfg(feature = "local-host")]
const REMOTE_PREFIX: &str = "remote:";

#[cfg(feature = "local-host")]
fn split_remote(value: &str) -> Option<(&str, &str)> {
    value.strip_prefix(REMOTE_PREFIX)?.split_once(':')
}

#[cfg(feature = "local-host")]
fn remote_id(peer: &str, inner: &str) -> String {
    format!("{REMOTE_PREFIX}{peer}:{inner}")
}

/// Rewrite a peer's session info so it reads as one of this machine's: the id
/// gains the peer namespace and the workspace id becomes the same
/// `remote:<peer>:<id>` the app's folder list uses.
#[cfg(feature = "local-host")]
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
#[cfg(feature = "local-host")]
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

#[cfg(feature = "local-host")]
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct PtyListParams {
    include_remote: bool,
}

#[cfg(feature = "local-host")]
impl Default for PtyListParams {
    fn default() -> Self {
        Self {
            include_remote: true,
        }
    }
}

#[cfg(feature = "local-host")]
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StreamOpenParams {
    kind: String,
    id: Option<String>,
    host: Option<String>,
    port: Option<u16>,
    capability: Option<String>,
    #[serde(default)]
    control: bool,
    /// Screen streams only. A name from a fixed set, checked where the session
    /// is made. Absent means the host decides from the route.
    quality: Option<String>,
}

#[cfg(feature = "local-host")]
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

    #[test]
    fn device_poll_refusal_keeps_invalid_grant_structured() {
        let error = tokenstat_sync::profile::ProfileError::DeviceRejected {
            code: "invalid_grant".into(),
            detail: " (That code is not valid.)".into(),
        };
        let mapped = device_poll_error(error);
        assert_eq!(mapped.code, "device_invalid_grant");
        assert_eq!(
            mapped.message,
            "login failed: invalid_grant (That code is not valid.)"
        );
    }

    #[test]
    fn device_poll_storage_failure_is_not_a_network_failure() {
        let mapped = device_poll_error(tokenstat_sync::profile::ProfileError::LoginStorage(
            "disk is read-only".into(),
        ));
        assert_eq!(mapped.code, "device_storage");
        assert!(mapped.message.contains("could not save your sign-in"));
    }

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
        // `open_local` rather than `open`, so these keep testing an archive
        // when the crate is built without `local-host`.
        Session::open_local(&OpenParams {
            db_path: Some(dir.join("tokenstat.db").display().to_string()),
            timezone: Some("UTC".into()),
        })
        .expect("open temp archive")
    }

    /// Notes and tasks are counted apart.
    ///
    /// They live in one store as cards, so the only thing keeping a folder's
    /// task badge honest is the kind filter. An archived note is not counted
    /// at all: put away is put away, and a badge nobody can clear is a badge
    /// nobody reads.
    ///
    /// Gated like everything it touches: `summarize`, `FolderContents` and the
    /// card store are all behind `local-host`, and the client-only build has
    /// no folders of its own to count.
    #[cfg(feature = "local-host")]
    #[test]
    fn a_folder_counts_notes_apart_from_tasks() {
        fn card(kind: crate::todo::CardKind, column: &str, workspace: &str) -> crate::todo::Card {
            crate::todo::Card {
                id: String::new(),
                title: "x".into(),
                kind,
                notes: String::new(),
                column: column.into(),
                order: 0,
                priority: Default::default(),
                backend: String::new(),
                model: None,
                effort: None,
                workspace_id: workspace.into(),
                budget_seconds: 0,
                created_at_ms: 0,
                updated_at_ms: 0,
                delegate: None,
            }
        }
        let ws = tokenstat_workspace::Workspace {
            id: "ws1".into(),
            path: std::path::PathBuf::from("/tmp/does-not-exist-ws1"),
            name: "ws1".into(),
            added_at_ms: 0,
        };
        let live = FolderContents {
            sessions: Vec::new(),
            cards: vec![
                card(crate::todo::CardKind::Task, "backlog", "ws1"),
                card(crate::todo::CardKind::Note, "backlog", "ws1"),
                card(crate::todo::CardKind::Note, "backlog", "ws1"),
                card(crate::todo::CardKind::Note, "archive", "ws1"),
                card(crate::todo::CardKind::Note, "backlog", "ws2"),
            ],
            automations: Vec::new(),
            workflows: Vec::new(),
            runs: Vec::new(),
        };
        let summary = summarize(&ws, &live);
        assert_eq!(summary.tasks, 1, "a note is not a task");
        assert_eq!(summary.notes, 2, "archived and another folder's are out");
    }

    #[test]
    fn a_client_says_which_methods_it_cannot_answer() {
        let mut s = Session::open_client(Some("UTC")).expect("client session");

        // Every archive method refuses with the same code, so one branch in a
        // front end covers all of them, and none of them fails as if something
        // had gone wrong.
        for (method, params) in [
            ("totals", "{}"),
            ("report", r#"{"group":"day"}"#),
            ("report.split", r#"{"group":"day","splitBy":"model"}"#),
            ("blocks", "{}"),
            ("scan", "{}"),
            ("sync.run", "{}"),
            ("activity.day", r#"{"date":"2026-08-11"}"#),
        ] {
            let out = call(&mut s, method, params);
            let v: Value = serde_json::from_str(&out).expect("envelope");
            assert_eq!(v["ok"], false, "{method} answered from nothing: {out}");
            assert_eq!(
                v["error"]["code"],
                crate::error::NO_LOCAL_ARCHIVE,
                "{method}: {out}"
            );
        }

        // And it says so up front, rather than only when asked to do the
        // impossible.
        let info: Value = serde_json::from_str(&call(&mut s, "info", "{}")).expect("info envelope");
        assert_eq!(info["ok"], true, "{info}");
        assert_eq!(info["result"]["hasArchive"], false);
        assert!(info["result"]["dbPath"].is_null(), "{info}");
        assert_eq!(info["result"]["timezone"], "UTC");
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
            ("workflow.list", "{}"),
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
            "pty.detach",
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
            "host.policy",
            "host.stats",
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
        #[cfg(feature = "local-host")]
        {
            let out = call_sessionless("pty.spawn", "{}")
                .expect("pty.spawn must be answerable without a session");
            let v: Value = serde_json::from_str(&out).expect("pty.spawn returned non-JSON");
            assert!(v["ok"].is_boolean(), "pty.spawn lacks ok: {out}");

            // The folder methods are sessionless for the same reason. Not
            // called here: `workspace.list` runs git over whatever this machine
            // actually has registered, which is not a test's business.
            assert!(
                folders("workspace.list", "{}").is_some(),
                "workspace.list must not need the session"
            );
            let listed = call_sessionless("workflow.list", "{}")
                .expect("workflow.list must be answerable without a session");
            let listed: Value = serde_json::from_str(&listed).expect("workflow.list JSON");
            assert!(
                listed["ok"].is_boolean(),
                "workflow.list lacks ok: {listed}"
            );
            let design = call_sessionless("workflow.design", "{}")
                .expect("workflow.design must be answerable without a session");
            let design: Value = serde_json::from_str(&design).expect("workflow.design JSON");
            assert_eq!(design["ok"], false, "{design}");

            // The tasks board keeps its own store behind its own lock. Under
            // the session lock it queued behind reports, syncs, and another
            // machine asking this one for a report, so the menu bar could know
            // the count while the list never arrived.
            //
            // Asked without an id on purpose: this must prove the routing, not
            // exercise the board. `todo.list` reconciles and auto-archives the
            // real `todo.json` of whoever runs the suite, and a test that tidies
            // somebody's finished cards away is a test that costs more than it
            // proves. This arm answers before it touches the store.
            let tasks = call_sessionless("todo.remove", "{}")
                .expect("the todo family must be answerable without a session");
            let tasks: Value = serde_json::from_str(&tasks).expect("todo.remove JSON");
            assert_eq!(tasks["ok"], false, "{tasks}");
            assert!(
                tasks["error"]["message"]
                    .as_str()
                    .is_some_and(|m| m.contains("needs an id")),
                "reached the board instead of failing on the missing id: {tasks}"
            );
        }

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

    #[test]
    fn host_policy_persists_and_reads_back() {
        let _identity_guard = IDENTITY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-host-policy-dispatch-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", &dir) };
        crate::host_policy::set_battery_override_for_tests(Some(true));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                crate::host_policy::set_battery_override_for_tests(None);
                crate::host_policy::reset_settings_cache_for_tests();
                unsafe { std::env::remove_var("TOKENSTAT_IDENTITY_DIR") };
            }
        }
        let _reset = Reset;

        let first: Value =
            serde_json::from_str(&call_sessionless("host.policy", "{}").expect("sessionless"))
                .expect("json");
        assert!(first["ok"].as_bool().unwrap_or(false), "{first}");
        assert_eq!(first["result"]["hasInternalBattery"], true, "{first}");
        assert_eq!(first["result"]["defaultAlwaysOn"], false, "{first}");

        let set: Value = serde_json::from_str(
            &call_sessionless("host.setPolicy", r#"{"alwaysOn":true}"#).expect("sessionless"),
        )
        .expect("json");
        assert!(set["ok"].as_bool().unwrap_or(false), "{set}");
        assert_eq!(set["result"]["alwaysOn"], true, "{set}");

        let again: Value =
            serde_json::from_str(&call_sessionless("host.policy", "{}").expect("sessionless"))
                .expect("json");
        assert_eq!(again["result"]["alwaysOn"], true, "{again}");

        let written = std::fs::read_to_string(dir.join("host.json")).expect("host.json");
        assert!(written.contains("\"alwaysOn\": true"), "{written}");

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
        s.engine_mut()
            .expect("test session has an archive")
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

    // Both of these are about a method that only exists with `local-host`.
    // A build without the feature has no folders to summarise and no params
    // type to parse, so the whole pair is gated rather than asserting on an
    // answer that would be "unknown method" there.
    #[cfg(feature = "local-host")]
    #[test]
    fn a_summary_needs_no_params_and_answers_every_folder() {
        // No id is the whole list. A front end drawing a sidebar asks once
        // rather than once per folder.
        let parsed: WorkspaceSummaryParams = serde_json::from_str("{}").unwrap();
        assert!(parsed.id.is_none());
        let mut s = session();
        let out = call(&mut s, "workspace.summary", "{}");
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true, "{out}");
        assert!(v["result"].is_array(), "{out}");
    }

    #[cfg(feature = "local-host")]
    #[test]
    fn a_summary_for_an_unknown_workspace_says_so() {
        let mut s = session();
        let out = call(
            &mut s,
            "workspace.summary",
            &json!({"id": "nope"}).to_string(),
        );
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["error"]["message"].as_str().unwrap().contains("nope"));
    }

    #[test]
    fn a_calendar_refresh_can_ask_to_drop_the_series_cache() {
        let parsed: CalendarParams =
            serde_json::from_str(r#"{"scope":"account","force":true}"#).unwrap();
        assert_eq!(parsed.scope.as_deref(), Some("account"));
        assert!(parsed.force);
        let quiet: CalendarParams = serde_json::from_str(r#"{"scope":"account"}"#).unwrap();
        assert!(!quiet.force);
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
            "account.appleActivate",
            "account.appleRenewal",
        ] {
            let out = call(&mut s, method, "{}");
            let v: Value = serde_json::from_str(&out)
                .unwrap_or_else(|e| panic!("{method} returned non-JSON: {out} ({e})"));
            assert!(v["ok"].is_boolean(), "{method}: {out}");
        }
    }

    #[test]
    fn google_activation_rejects_an_unrelated_android_package_before_network() {
        let mut s = session();
        let out = call(
            &mut s,
            "account.googleActivate",
            &json!({
                "packageName": "example.impostor",
                "productId": "ai.tokenstat.supporter.yearly",
                "purchaseToken": "not-sent"
            })
            .to_string(),
        );
        let value: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(value["ok"], false, "{out}");
        assert_eq!(value["error"]["code"], "invalid", "{out}");
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

    #[test]
    fn a_remote_peer_cannot_log_the_host_out_or_fetch_updates() {
        crate::request_context::with_remote_peer("phone", || {
            let mut s = session();
            let logout: Value =
                serde_json::from_str(&call(&mut s, "account.logout", "{}")).unwrap();
            assert_eq!(logout["ok"], false, "{logout}");
            assert!(
                logout["error"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("local-only"),
                "{logout}"
            );
            let update = call_sessionless("app.updateCheck", "{}").expect("sessionless");
            let v: Value = serde_json::from_str(&update).unwrap();
            assert_eq!(v["ok"], false, "{update}");
            assert!(
                v["error"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("local-only"),
                "{update}"
            );
        });
    }
}
