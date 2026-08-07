//! tokenstat.ai device login and profile sync client.
//!
//! Opt-in only. Builds a sealed day × source × model × opaque-project payload
//! in core, then gzip-posts it with a bearer token from the OS keychain.
//! Project paths, sessions, prompts, and hostnames never enter this path.

use std::io::Write;
use std::thread;
use std::time::Duration;

use flate2::Compression;
use flate2::write::GzEncoder;
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokenstat_core::{
    Store, SyncBuildArgs, SyncWindow, build_sync_payload, default_sync_window, parse_window_arg,
};

use crate::config::{self, ConfigError};
use crate::host::{self, HostError};
use crate::keychain::{self, KeychainError};
use crate::schema;

#[derive(Debug, thiserror::Error)]
pub enum ProfileError {
    #[error(transparent)]
    Host(#[from] HostError),
    #[error(transparent)]
    Config(#[from] ConfigError),
    #[error(transparent)]
    Keychain(#[from] KeychainError),
    #[error(transparent)]
    Core(#[from] tokenstat_core::CoreError),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("{message}")]
    RateLimited {
        message: String,
        retry_after: Option<u64>,
        next_allowed_at: Option<String>,
    },
    #[error("{0}")]
    Message(String),
}

/// Shown when no token exists for the resolved host.
pub const NOT_LOGGED_IN: &str = "not logged in. run `tokenstat login` first";

/// Shown when the server rejects the token we do have.
pub const TOKEN_REVOKED: &str = "token missing or revoked. run `tokenstat login`";

impl ProfileError {
    /// Whether this means "nobody is signed in" rather than something broke.
    ///
    /// A GUI needs the difference: one is a sign-in button, the other is an
    /// error banner. The check lives here, next to the strings it matches, so
    /// rewording a message cannot silently turn a sign-in prompt into an error
    /// somewhere else in the tree.
    pub fn is_unauthenticated(&self) -> bool {
        match self {
            ProfileError::Message(m) => m == NOT_LOGGED_IN || m == TOKEN_REVOKED,
            _ => false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct LoginResult {
    pub host: String,
    pub handle: String,
    pub machine: String,
    pub schema_min_v: u32,
    pub schema_max_v: u32,
}

#[derive(Debug, Clone)]
pub struct SyncResult {
    pub host: String,
    pub window: SyncWindow,
    pub rows: u64,
    pub idempotency_key: String,
    pub dry_run: bool,
    pub schema_v: u32,
}

#[derive(Debug, Clone)]
pub struct StatusResult {
    pub host: String,
    pub handle: Option<String>,
    pub tier: Option<String>,
    pub last_sync_at: Option<String>,
    pub machines: Vec<Value>,
    pub schema_min_v: Option<u32>,
    pub schema_max_v: Option<u32>,
    pub schema_current: Option<u32>,
    pub raw: Value,
}

#[derive(Debug, Deserialize)]
struct DeviceCodeResponse {
    device_code: String,
    user_code: String,
    verification_uri: String,
    #[serde(default)]
    verification_uri_complete: Option<String>,
    expires_in: u64,
    interval: u64,
}

#[derive(Debug, Deserialize)]
struct TokenSuccess {
    token: String,
    #[serde(default)]
    handle: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ApiErrorBody {
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    message: Option<String>,
}

/// Turn a non-401 refusal into an error that names the server's own reason.
///
/// A `401` means the token itself was rejected and becomes the revoked-token
/// message. Other refusals (most often a `403` when the account's plan does
/// not cover the route) are facts about the account, not about the token, and
/// telling somebody whose token is fine to sign in again sends them through a
/// login for nothing. The server's message says which fact it is, so surface
/// it. A refusal with no reason at all is indistinguishable from a revoked
/// token, and signing in again is the honest move there.
fn refusal_error(text: &str, status: u16) -> ProfileError {
    let body: ApiErrorBody = serde_json::from_str(text).unwrap_or(ApiErrorBody {
        error: None,
        message: None,
    });
    let detail = body
        .message
        .or(body.error)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| text.trim().to_string());
    if detail.is_empty() {
        return ProfileError::Message(TOKEN_REVOKED.into());
    }
    ProfileError::Message(format!(
        "the account refused this request ({status}): {detail}"
    ))
}

fn http_client() -> Result<reqwest::blocking::Client, ProfileError> {
    // No cookie jar: bearer routes must not attach a web session cookie.
    Ok(reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        // A dead network must fail fast, not eat the whole request timeout.
        // `timeout` covers connect, but the OS default connect phase can be
        // far longer than ten seconds on a network that drops packets.
        .connect_timeout(Duration::from_secs(10))
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}

fn env_api_base() -> Option<String> {
    std::env::var("TOKENSTAT_API_BASE")
        .ok()
        .filter(|s| !s.trim().is_empty())
}

pub fn resolve_api_host(flag: Option<&str>) -> Result<String, ProfileError> {
    let cfg = config::load()?;
    Ok(host::resolve_host(
        flag,
        env_api_base().as_deref(),
        cfg.sync.host.as_deref(),
    )?)
}

/// Redeem a pairing code minted on the website, skipping the browser round trip.
///
/// The other direction of `login`: instead of printing a code and waiting for
/// someone to approve it in a browser, this hands back a code they already have
/// from a signed-in page. Same result, one less window to move between.
pub fn login_with_code(host_flag: Option<&str>, code: &str) -> Result<LoginResult, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let machine = config::ensure_machine_id()?;
    let _salt = config::ensure_project_salt()?;
    let client = http_client()?;

    let envelope = schema::fetch_schema(&client, &host)?;
    let _ = envelope.choose_payload_v()?;

    let code = normalize_pairing_code(code)?;
    let resp = client
        .post(format!("{host}/api/v1/device/redeem"))
        .header("content-type", "application/json")
        .json(&serde_json::json!({ "code": code, "machine": machine }))
        .send()?;

    let status = resp.status();
    let text = resp.text()?;
    if !status.is_success() {
        let body: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let detail = body
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or_else(|| text.trim());
        return Err(ProfileError::Message(format!(
            "pairing failed ({}): {detail}",
            status.as_u16()
        )));
    }

    let ok: TokenSuccess = serde_json::from_str(&text)?;
    if !ok.token.starts_with("tsk_") {
        return Err(ProfileError::Message(
            "server returned a token that is not a tsk_ sync token".into(),
        ));
    }
    keychain::store_token(&host, &ok.token)?;
    config::set_sync_host(&host)?;
    Ok(LoginResult {
        host,
        handle: ok.handle.unwrap_or_else(|| "(unknown)".into()),
        machine,
        schema_min_v: envelope.min_v,
        schema_max_v: envelope.max_v,
    })
}

/// Accept a pairing code the way people actually paste it.
///
/// Lowercase, missing dash, stray spaces or quotes from a copy that grabbed too
/// much: all of that is the same code, and refusing it would be pedantry. The
/// alphabet has no O/0 or I/1 to confuse, so there is nothing ambiguous to guess.
fn normalize_pairing_code(raw: &str) -> Result<String, ProfileError> {
    let cleaned: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    if cleaned.len() != 8 {
        return Err(ProfileError::Message(format!(
            "that does not look like a pairing code: expected eight characters like WXYZ-1234, got {:?}",
            raw.trim()
        )));
    }
    Ok(format!("{}-{}", &cleaned[..4], &cleaned[4..]))
}

/// A device authorization in progress.
///
/// Returned by [`device_start`] and handed back to [`device_poll`] until the
/// user confirms. Holding it rather than a bare code keeps the caller from
/// having to remember the host and schema range across the two calls.
#[derive(Debug, Clone)]
pub struct DeviceLogin {
    pub host: String,
    pub machine: String,
    /// Shown to the user. Short, and the only part they have to read.
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: Option<String>,
    /// Seconds until the authorization expires.
    pub expires_in: u64,
    /// Seconds the server asks the caller to wait between polls.
    pub interval: u64,
    /// Secret half of the grant. Never display this.
    device_code: String,
    schema_min_v: u32,
    schema_max_v: u32,
}

impl DeviceLogin {
    /// The URL to open. Prefers the pre-filled form when the server offers one,
    /// so the user does not have to type the code at all.
    pub fn open_url(&self) -> &str {
        self.verification_uri_complete
            .as_deref()
            .unwrap_or(self.verification_uri.as_str())
    }
}

/// Outcome of one poll.
#[derive(Debug, Clone)]
pub enum DeviceStatus {
    /// Nobody has confirmed yet. Wait `interval` seconds and poll again. The
    /// server can raise the interval, so use this value rather than the
    /// original one.
    Pending {
        interval: u64,
    },
    Confirmed(Box<LoginResult>),
}

/// Begin an RFC 8628 device authorization against `{host}/api/v1/device/*`.
///
/// Split from the polling half so a GUI can show the user code in its own
/// window and stay responsive. [`login`] composes the two for the CLI.
pub fn device_start(host_flag: Option<&str>) -> Result<DeviceLogin, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let machine = config::ensure_machine_id()?;
    let _salt = config::ensure_project_salt()?;
    let client = http_client()?;

    // Learn the server range early so a hopeless mismatch fails before the
    // browser dance.
    let envelope = schema::fetch_schema(&client, &host)?;
    let _ = envelope.choose_payload_v()?;

    let resp = client
        .post(format!("{host}/api/v1/device/code"))
        .header("content-type", "application/json")
        .json(&serde_json::json!({ "machine": machine }))
        .send()?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().unwrap_or_default();
        return Err(ProfileError::Message(format!(
            "device code request failed ({status}): {body}"
        )));
    }

    let device: DeviceCodeResponse = resp.json()?;
    Ok(DeviceLogin {
        host,
        machine,
        user_code: device.user_code,
        verification_uri: device.verification_uri,
        verification_uri_complete: device.verification_uri_complete,
        expires_in: device.expires_in.max(1),
        interval: device.interval.max(1),
        device_code: device.device_code,
        schema_min_v: envelope.min_v,
        schema_max_v: envelope.max_v,
    })
}

/// Poll once for confirmation.
///
/// Does not sleep and does not loop: the caller decides how to wait, which is
/// what lets a UI stay responsive and cancel. On success the token is written
/// to the keychain, the same entry the CLI reads, so both see one account.
pub fn device_poll(login: &DeviceLogin) -> Result<DeviceStatus, ProfileError> {
    let client = http_client()?;
    let poll = client
        .post(format!("{}/api/v1/device/token", login.host))
        .header("content-type", "application/json")
        .json(&serde_json::json!({ "device_code": login.device_code }))
        .send()?;

    let status = poll.status();
    let text = poll.text()?;

    if status.as_u16() == 428
        || text.contains("authorization_pending")
        || text.contains("slow_down")
    {
        // `slow_down` is the server asking for more room, so widen rather than
        // keep hammering at the original interval.
        let interval = if text.contains("slow_down") {
            login.interval.saturating_add(5)
        } else {
            login.interval
        };
        return Ok(DeviceStatus::Pending { interval });
    }

    if status.is_success() {
        let ok: TokenSuccess = serde_json::from_str(&text)?;
        if !ok.token.starts_with("tsk_") {
            return Err(ProfileError::Message(
                "server returned a token that is not a tsk_ sync token".into(),
            ));
        }
        keychain::store_token(&login.host, &ok.token)?;
        config::set_sync_host(&login.host)?;
        return Ok(DeviceStatus::Confirmed(Box::new(LoginResult {
            host: login.host.clone(),
            handle: ok.handle.unwrap_or_else(|| "(unknown)".into()),
            machine: login.machine.clone(),
            schema_min_v: login.schema_min_v,
            schema_max_v: login.schema_max_v,
        })));
    }

    let err: ApiErrorBody = serde_json::from_str(&text).unwrap_or(ApiErrorBody {
        error: Some(format!("http_{}", status.as_u16())),
        message: Some(text.clone()),
    });
    Err(ProfileError::Message(format!(
        "login failed: {}{}",
        err.error.unwrap_or_else(|| status.to_string()),
        err.message.map(|m| format!(" ({m})")).unwrap_or_default()
    )))
}

/// RFC 8628 device authorization grant, driven to completion for the CLI.
///
/// Prints the code, opens a browser, and blocks until the user confirms.
/// A GUI wants [`device_start`] and [`device_poll`] instead: this one owns
/// stdout and the clock.
pub fn login(host_flag: Option<&str>) -> Result<LoginResult, ProfileError> {
    let device = device_start(host_flag)?;

    println!("Open: {}", device.verification_uri);
    if let Some(complete) = &device.verification_uri_complete {
        println!("Or:   {complete}");
    }
    println!("Code: {}", device.user_code);
    println!();
    println!("Waiting for confirmation…");

    let _ = open_browser(device.open_url());

    let deadline = std::time::Instant::now() + Duration::from_secs(device.expires_in);
    let mut interval = Duration::from_secs(device.interval);

    loop {
        if std::time::Instant::now() >= deadline {
            return Err(ProfileError::Message(
                "device login timed out before confirmation".into(),
            ));
        }
        thread::sleep(interval);

        match device_poll(&device)? {
            DeviceStatus::Pending { interval: next } => {
                interval = Duration::from_secs(next);
            }
            DeviceStatus::Confirmed(result) => return Ok(*result),
        }
    }
}

/// Delete the keychain entry for the resolved host. No server call.
pub fn logout(host_flag: Option<&str>) -> Result<String, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    keychain::delete_token(&host)?;
    Ok(host)
}

/// `GET /api/v1/me` with the bearer token.
pub fn sync_status(host_flag: Option<&str>) -> Result<StatusResult, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let resp = client
        .get(format!("{host}/api/v1/me"))
        .header("authorization", format!("Bearer {token}"))
        .send()?;
    let status = resp.status();
    let text = resp.text()?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if status.as_u16() == 403 {
        return Err(refusal_error(&text, 403));
    }
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "status request failed ({status}): {text}"
        )));
    }
    let raw: Value = serde_json::from_str(&text)?;
    let handle = raw
        .get("handle")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let tier = raw.get("tier").and_then(|v| v.as_str()).map(str::to_string);
    let last_sync_at = raw
        .get("last_sync_at")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let machines = raw
        .get("machines")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let schema = raw.get("schema");
    let schema_min_v = schema
        .and_then(|s| s.get("min_v"))
        .and_then(|v| v.as_u64())
        .map(|n| n as u32);
    let schema_max_v = schema
        .and_then(|s| s.get("max_v"))
        .and_then(|v| v.as_u64())
        .map(|n| n as u32);
    let schema_current = schema
        .and_then(|s| s.get("current"))
        .and_then(|v| v.as_u64())
        .map(|n| n as u32);
    Ok(StatusResult {
        host,
        handle,
        tier,
        last_sync_at,
        machines,
        schema_min_v,
        schema_max_v,
        schema_current,
        raw,
    })
}

/// Register this machine's remote-reach identity on its account record.
///
/// Called by the host daemon when "Reach machines from anywhere" is on: the
/// account's machine directory then carries the public key the tunnel routes
/// by and the name the other screens should show. Never called from a plain
/// sync, and never without the user's opt-in toggle, because the name is
/// identifying and the sync envelope must stay free of it.
pub fn register_machine_identity(
    host_flag: Option<&str>,
    machine_id: &str,
    public_identity: &str,
    label: &str,
) -> Result<(), ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let resp = client
        .put(format!("{host}/api/v1/machines/me"))
        .header("authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "machine": machine_id,
            "public_identity": public_identity,
            "label": label,
        }))
        .send()?;
    let status = resp.status();
    let text = resp.text()?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "remote reach registration failed ({status}): {text}"
        )));
    }
    Ok(())
}

/// Remove a machine from the account directory. The server deletes the
/// machine's uploaded rows too, which is what makes this an explicit action
/// rather than something a client does on its own: a stale machine id (a
/// reinstall, a dead machine) can otherwise hold a machine-cap slot that a
/// live machine needs.
pub fn unlink_machine(host_flag: Option<&str>, machine_id: &str) -> Result<(), ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let resp = client
        .delete(format!("{host}/api/v1/machines/{machine_id}"))
        .header("authorization", format!("Bearer {token}"))
        .send()?;
    let status = resp.status();
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if !status.is_success() {
        let text = resp.text().unwrap_or_default();
        return Err(ProfileError::Message(format!(
            "could not remove the machine from the account ({status}): {text}"
        )));
    }
    Ok(())
}

/// One day × source × model row of the account's own usage.
///
/// Token counts only. The service has never priced anything and does not start
/// here: it hands back the grain, and the price book on this machine turns it
/// into a figure. That is also what makes an account-wide number comparable
/// with a local one, rather than two prices computed in two places.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct SeriesRow {
    pub day: String,
    pub src: String,
    pub model: String,
    #[serde(rename = "in")]
    pub input: u64,
    #[serde(rename = "out")]
    pub output: u64,
    pub cr: u64,
    pub cw5: u64,
    pub cw1: u64,
    #[serde(default)]
    pub ev: u64,
    #[serde(default)]
    pub plan: u8,
}

/// `GET /api/v1/usage/series`, the account's usage across every machine.
///
/// `machine` narrows it to one. Both come from the same store, so "this
/// machine" and "all machines" cannot disagree with each other the way a local
/// archive and an account total can.
///
/// Not logged in is a plain error, not a panic and not an empty result: an
/// empty grid and "we could not ask" are different answers and the caller has
/// to be able to tell them apart.
pub struct SeriesResult {
    pub rows: Vec<SeriesRow>,
    /// The window the service actually covered.
    ///
    /// Not the window that was asked for. A plan's history span narrows it, and
    /// a caller that drew the days outside it would be showing days it was
    /// never sent as days on which nothing happened.
    pub from: Option<String>,
    pub to: Option<String>,
}

pub fn account_series(
    host_flag: Option<&str>,
    from: Option<&str>,
    to: Option<&str>,
    machine: Option<&str>,
) -> Result<SeriesResult, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;

    let mut url = format!("{host}/api/v1/usage/series");
    let mut query: Vec<String> = Vec::new();
    if let Some(from) = from {
        query.push(format!("from={from}"));
    }
    if let Some(to) = to {
        query.push(format!("to={to}"));
    }
    if let Some(machine) = machine {
        query.push(format!("machine={machine}"));
    }
    if !query.is_empty() {
        url.push('?');
        url.push_str(&query.join("&"));
    }

    let client = http_client()?;
    let resp = client
        .get(url)
        .header("authorization", format!("Bearer {token}"))
        .send()?;
    let status = resp.status();
    let text = resp.text()?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if status.as_u16() == 403 {
        return Err(refusal_error(&text, 403));
    }
    if status.as_u16() == 429 {
        return Err(ProfileError::Message(
            "the service asked us to slow down. The last figures stay on screen.".into(),
        ));
    }
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "usage request failed ({status}): {text}"
        )));
    }
    let raw: Value = serde_json::from_str(&text)?;
    let rows = raw.get("rows").cloned().unwrap_or(Value::Array(vec![]));
    let window = raw.get("window");
    let field = |name: &str| {
        window
            .and_then(|w| w.get(name))
            .and_then(|v| v.as_str())
            .map(str::to_string)
    };
    Ok(SeriesResult {
        rows: serde_json::from_value(rows)?,
        from: field("from"),
        to: field("to"),
    })
}

pub struct SyncOptions<'a> {
    pub host_flag: Option<&'a str>,
    pub prune: bool,
    pub window: Option<&'a str>,
    pub dry_run: bool,
    pub tz_name: Option<&'a str>,
}

/// Build and POST a complete window from the local archive.
pub fn sync(store: &Store, opts: SyncOptions<'_>) -> Result<SyncResult, ProfileError> {
    if opts.dry_run {
        return sync_unlocked(store, opts);
    }
    let _lock = try_sync_lock()?
        .ok_or_else(|| ProfileError::Message("another sync is already running".into()))?;
    sync_unlocked(store, opts)
}

fn sync_unlocked(store: &Store, opts: SyncOptions<'_>) -> Result<SyncResult, ProfileError> {
    let host = resolve_api_host(opts.host_flag)?;
    let client = http_client()?;

    let token = if opts.dry_run {
        None
    } else {
        Some(
            keychain::load_token(&host)?
                .ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?,
        )
    };

    let envelope = if opts.dry_run {
        schema::try_fetch_schema(&client, &host)
    } else {
        Some(schema::fetch_schema(&client, &host)?)
    };

    let (schema_v, sources, confidence) = match &envelope {
        Some(env) => {
            let v = env.choose_payload_v()?;
            (v, Some(env.sources.clone()), Some(env.confidence.clone()))
        }
        None => (tokenstat_core::SYNC_SCHEMA_VERSION, None, None),
    };

    let machine = config::ensure_machine_id()?;
    let salt = config::ensure_project_salt()?;
    let tz = tokenstat_core::timezone(opts.tz_name)?;
    let tz_name = tz.iana_name().unwrap_or("UTC");

    let window = if let Some(raw) = opts.window {
        parse_window_arg(raw)?
    } else {
        let totals = store.totals(&tokenstat_core::Query::default())?;
        let today = jiff::Timestamp::now()
            .to_zoned(tz.clone())
            .date()
            .to_string();
        let cursor_from = config::cursor_for(&host)?.map(|c| c.from);
        default_sync_window(
            totals.first_date.as_deref(),
            totals.last_date.as_deref(),
            &today,
            cursor_from.as_deref(),
        )
        .ok_or_else(|| ProfileError::Message("archive is empty; nothing to sync".into()))?
    };

    let prune = opts.prune;
    let payload = build_sync_payload(
        store,
        SyncBuildArgs {
            machine: &machine,
            salt_id: &salt.id,
            salt_key: &salt.key,
            tz: tz_name,
            window: window.clone(),
            prune,
            schema_v,
            allowed_sources: sources.as_deref(),
            allowed_confidence: confidence.as_deref(),
        },
    )?;
    let canonical = payload.canonical_bytes()?;
    let idempotency_key = hex_sha256(&canonical);

    if opts.dry_run {
        println!("{}", String::from_utf8_lossy(&canonical));
        return Ok(SyncResult {
            host,
            window,
            rows: payload.totals.rows,
            idempotency_key,
            dry_run: true,
            schema_v,
        });
    }

    let Some(token) = token else {
        return Err(ProfileError::Message(NOT_LOGGED_IN.into()));
    };
    let body = gzip_bytes(&canonical)?;
    let url = format!("{host}/api/v1/sync");

    let mut attempt = 0u32;
    let response_text = loop {
        attempt += 1;
        let resp = client
            .post(&url)
            .header("authorization", format!("Bearer {token}"))
            .header("content-type", "application/json")
            .header("content-encoding", "gzip")
            .header("idempotency-key", &idempotency_key)
            .body(body.clone())
            .send();

        let resp = match resp {
            Ok(r) => r,
            Err(_) if attempt < 4 => {
                thread::sleep(Duration::from_secs(u64::from(attempt)));
                continue;
            }
            Err(e) => return Err(e.into()),
        };

        let status = resp.status();
        let retry_after = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok());
        let text = resp.text().unwrap_or_default();

        if status.is_success() {
            break text;
        }

        // A 429 from the per-machine interval gate can be an hour away, so it is
        // an answer, not a hiccup: sleeping on it would park the process for the
        // whole window. Only a short Retry-After (the coarse abuse bucket, or a
        // proxy) is worth waiting out in place.
        if status.as_u16() == 429 {
            let hold = pacing_from_body(&text, retry_after);
            let short = retry_after.is_some_and(|s| s <= 30);
            if short && attempt < 4 {
                thread::sleep(Duration::from_secs(retry_after.unwrap_or(1).max(1)));
                continue;
            }
            let _ = config::record_sync_hold(&host, hold.clone());
            let body: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
            let message = body
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("the server is not accepting a sync from this machine yet")
                .to_string();
            return Err(ProfileError::RateLimited {
                message,
                retry_after: hold.min_interval.or(retry_after),
                next_allowed_at: hold.next_allowed_at,
            });
        }

        if status.is_server_error() {
            if attempt >= 4 {
                return Err(map_sync_error(status, &text));
            }
            // Cap like the 429 short-wait path: a day-long Retry-After on a 503
            // must not park a foreground sync for hours.
            let wait = retry_after.unwrap_or(u64::from(attempt) * 2).clamp(1, 30);
            thread::sleep(Duration::from_secs(wait));
            continue;
        }

        return Err(map_sync_error(status, &text));
    };

    let last_sync_at = jiff::Timestamp::now()
        .strftime("%Y-%m-%dT%H:%M:%SZ")
        .to_string();
    // The success body carries the plan's interval and the next slot, so a
    // scheduled run can pace itself without a second request.
    let pacing = pacing_from_body(&response_text, None);
    config::record_sync_cursor(&host, &window.from, &window.to, &last_sync_at, pacing)?;

    Ok(SyncResult {
        host,
        window,
        rows: payload.totals.rows,
        idempotency_key,
        dry_run: false,
        schema_v,
    })
}

/// Pull the pacing hints out of a sync response (success or 429).
///
/// Falls back to `Retry-After` when the body carries no absolute time, so an
/// intermediary that rate-limits without our JSON still teaches us something.
fn pacing_from_body(text: &str, retry_after: Option<u64>) -> config::SyncPacing {
    let body: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let min_interval = body.get("min_interval").and_then(|v| v.as_u64());
    let next_allowed_at = body
        .get("next_allowed_at")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            let secs = retry_after?;
            Some(
                (jiff::Timestamp::now() + Duration::from_secs(secs))
                    .strftime("%Y-%m-%dT%H:%M:%SZ")
                    .to_string(),
            )
        });
    config::SyncPacing {
        next_allowed_at,
        min_interval,
    }
}

/// How wide the scheduled-sync jitter window is.
///
/// Timers on every platform here start counting from install or boot, so phases
/// are already spread in practice. This covers the cases where they are not: a
/// fleet that boots together, a systemd timer replaying after downtime, or
/// someone driving `sync` from an on-the-hour cron entry.
pub const JITTER_WINDOW_SECS: u64 = 180;

/// Where inside the jitter window this machine belongs.
///
/// Derived from the machine id rather than drawn fresh each run, so a machine
/// keeps its offset for life: the spread is even with ten clients as well as
/// with ten thousand, and every run stays a full interval after the last one
/// instead of walking around the clock. The server derives the same kind of
/// offset from the same id, so the two agree without exchanging it.
pub fn jitter_offset(machine: &str, window_secs: u64) -> u64 {
    if window_secs == 0 {
        return 0;
    }
    let digest = Sha256::digest(machine.as_bytes());
    let n = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]);
    u64::from(n) % window_secs
}

/// `TOKENSTAT_SYNC_JITTER` in seconds, for tests and for a first sync run right
/// after login where waiting three minutes would just look broken. Capped at an
/// hour so a typo cannot park a scheduled job indefinitely.
fn jitter_override() -> Option<u64> {
    let raw = std::env::var("TOKENSTAT_SYNC_JITTER").ok()?;
    let secs = raw.trim().parse::<u64>().ok()?;
    Some(secs.min(3600))
}

/// A few seconds on top of the fixed offset, so a machine that happens to land
/// on an awkward second is not stuck there every single hour.
fn jitter_smear() -> u64 {
    let mut b = [0u8; 1];
    if getrandom::fill(&mut b).is_err() {
        return 0;
    }
    u64::from(b[0]) % 16
}

/// What a scheduled run did, so the caller can stay quiet about the boring cases.
#[derive(Debug)]
pub enum ScheduledOutcome {
    /// No token for this host. Nothing to do, and not an error: the sync unit
    /// can outlive a `tokenstat logout`.
    NotLoggedIn,
    /// The plan's interval has not elapsed. No request was made.
    Held {
        until: Option<String>,
    },
    /// A transient failure (archive busy, network blip). Log it and exit 0 so
    /// the next timer tick retries. Manual `tokenstat sync` still fails loud.
    Deferred {
        reason: String,
    },
    Synced(Box<SyncResult>),
}

/// `sync` as a background job: jittered, self-paced, and quiet when there is
/// nothing to do.
///
/// The pacing check happens before the sleep so a held-back machine costs
/// nothing, and it is measured from when the request would actually go out.
pub fn sync_scheduled(
    store: &Store,
    opts: SyncOptions<'_>,
) -> Result<ScheduledOutcome, ProfileError> {
    let host = resolve_api_host(opts.host_flag)?;
    if keychain::load_token(&host)?.is_none() {
        return Ok(ScheduledOutcome::NotLoggedIn);
    }

    let machine = config::ensure_machine_id()?;
    let sleep_secs = match jitter_override() {
        Some(secs) => secs,
        None => jitter_offset(&machine, JITTER_WINDOW_SECS) + jitter_smear(),
    };

    if let Some(cursor) = config::cursor_for(&host)? {
        if let Some(next) = cursor.next_allowed_at.as_deref() {
            if let Ok(next_ts) = next.parse::<jiff::Timestamp>() {
                // Measured from when the POST would land, and with the same
                // grace the server allows, so a couple of seconds of timer drift
                // never costs a whole interval.
                let at = jiff::Timestamp::now() + Duration::from_secs(sleep_secs);
                let grace = Duration::from_secs(SERVER_GRACE_SECS);
                if at + grace < next_ts {
                    return Ok(ScheduledOutcome::Held {
                        until: Some(next.to_string()),
                    });
                }
            }
        }
    }

    thread::sleep(Duration::from_secs(sleep_secs));
    sync_scheduled_now(store, opts)
}

/// Run one scheduled sync without sleeping.
///
/// This is for the long-lived desktop host, which must not hold its archive
/// mutex while the normal scheduled jitter is elapsing.
pub fn sync_scheduled_now(
    store: &Store,
    opts: SyncOptions<'_>,
) -> Result<ScheduledOutcome, ProfileError> {
    let host = resolve_api_host(opts.host_flag)?;
    if keychain::load_token(&host)?.is_none() {
        return Ok(ScheduledOutcome::NotLoggedIn);
    }

    if let Some(cursor) = config::cursor_for(&host)? {
        if let Some(next) = cursor.next_allowed_at.as_deref() {
            if let Ok(next_ts) = next.parse::<jiff::Timestamp>() {
                let grace = Duration::from_secs(SERVER_GRACE_SECS);
                if jiff::Timestamp::now() + grace < next_ts {
                    return Ok(ScheduledOutcome::Held {
                        until: Some(next.to_string()),
                    });
                }
            }
        }
    }

    let Some(_lock) = try_sync_lock()? else {
        return Ok(ScheduledOutcome::Deferred {
            reason: "another sync is already running".into(),
        });
    };
    match sync_unlocked(store, opts) {
        Ok(result) => Ok(ScheduledOutcome::Synced(Box::new(result))),
        Err(ProfileError::RateLimited {
            next_allowed_at, ..
        }) => Ok(ScheduledOutcome::Held {
            until: next_allowed_at,
        }),
        Err(err) if err.is_transient() => Ok(ScheduledOutcome::Deferred {
            reason: err.to_string(),
        }),
        Err(err) => Err(err),
    }
}

impl ProfileError {
    /// Failures a background timer should swallow and retry on the next tick.
    ///
    /// Auth mistakes, empty archives, and unsupported schemas stay hard so the
    /// log still surfaces things that will not fix themselves.
    pub fn is_transient(&self) -> bool {
        match self {
            ProfileError::Core(e) => e.is_busy(),
            ProfileError::Http(e) => {
                e.is_connect() || e.is_timeout() || e.is_request() || e.status().is_none()
            }
            ProfileError::Message(m) => {
                m.starts_with("schema fetch failed:")
                    || m.contains("database is locked")
                    || m.contains("database is busy")
            }
            _ => false,
        }
    }
}

/// What the scheduler needs to know about sync, without touching the network.
#[derive(Debug, Clone)]
pub struct SchedulingInfo {
    pub host: String,
    pub logged_in: bool,
    /// The interval the server last told us, if this machine has ever synced.
    pub min_interval: Option<u64>,
    /// Earliest time the server will accept the next sync, remembered locally.
    pub next_allowed_at: Option<String>,
}

/// Read locally what sync's cadence should be.
///
/// Offline on purpose: installing a timer should not depend on the network being
/// up, and the interval only needs to be right enough. The server enforces the
/// real one and every response corrects us.
pub fn scheduling_info(host_flag: Option<&str>) -> Result<SchedulingInfo, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let logged_in = keychain::load_token(&host)?.is_some();
    let cursor = config::cursor_for(&host)?;
    let min_interval = cursor.as_ref().and_then(|c| c.min_interval);
    let next_allowed_at = cursor.and_then(|c| c.next_allowed_at);
    Ok(SchedulingInfo {
        host,
        logged_in,
        min_interval,
        next_allowed_at,
    })
}

/// Whether the CLI's platform scheduler has an active sync entry.
///
/// The desktop host uses this to avoid taking ownership of sync when the CLI
/// already has it configured. The executable itself is not enough evidence:
/// many users install the CLI but never enable its scheduler.
pub fn cli_sync_schedule_active() -> bool {
    #[cfg(target_os = "macos")]
    {
        directories::BaseDirs::new()
            .map(|dirs| {
                dirs.home_dir()
                    .join("Library/LaunchAgents/ai.tokenstat.sync.plist")
                    .is_file()
            })
            .unwrap_or(false)
    }
    #[cfg(target_os = "linux")]
    {
        directories::BaseDirs::new()
            .map(|dirs| {
                dirs.config_dir()
                    .join("systemd/user/ai.tokenstat.sync.timer")
                    .is_file()
            })
            .unwrap_or(false)
    }
    #[cfg(target_os = "windows")]
    {
        directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .map(|dirs| {
                dirs.data_local_dir()
                    .join("schedule/ai.tokenstat.sync.vbs")
                    .is_file()
            })
            .unwrap_or(false)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        false
    }
}

struct SyncLock {
    path: std::path::PathBuf,
}

impl Drop for SyncLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn try_sync_lock() -> Result<Option<SyncLock>, ProfileError> {
    let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .ok_or_else(|| ProfileError::Message("no tokenstat data directory".into()))?;
    let dir = dirs.data_dir();
    std::fs::create_dir_all(dir)?;
    let path = dir.join("sync.lock");
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(_) => Ok(Some(SyncLock { path })),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let stale = std::fs::metadata(&path)
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age > Duration::from_secs(15 * 60));
            if stale {
                let _ = std::fs::remove_file(&path);
                return try_sync_lock();
            }
            Ok(None)
        }
        Err(error) => Err(error.into()),
    }
}

/// The tolerance the server applies to its own interval check (lib/sync.js
/// SYNC_GRACE_SECS). Kept in step by hand; erring low only costs a retry.
const SERVER_GRACE_SECS: u64 = 60;

fn map_sync_error(status: reqwest::StatusCode, text: &str) -> ProfileError {
    let body: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let code = body.get("error").and_then(|v| v.as_str()).unwrap_or("");
    let detail = body.get("message").and_then(|v| v.as_str()).unwrap_or(text);

    let msg = match (status.as_u16(), code) {
        (400, "unknown_field") => {
            let field = body
                .get("field")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            format!("bug: payload has a forbidden field ({field}). {detail}")
        }
        (400, "totals_mismatch") => {
            "bug: client totals do not match rows. cursor not advanced.".into()
        }
        (400, "clock_skew") => {
            "local clock is more than 24h off. fix the system time and retry.".into()
        }
        (400, "unsupported_schema") => {
            let min_v = body
                .get("min_v")
                .and_then(|v| v.as_u64())
                .map(|n| n.to_string())
                .unwrap_or_else(|| "?".into());
            let max_v = body
                .get("max_v")
                .and_then(|v| v.as_u64())
                .map(|n| n.to_string())
                .unwrap_or_else(|| "?".into());
            format!(
                "unsupported_schema: server accepts v in [{min_v}, {max_v}]. \
                 upgrade the CLI or wait for the server. {detail}"
            )
        }
        (400, "invalid_schema") => format!("invalid schema: {detail}"),
        (400, "session_not_allowed") => {
            "server rejected a session cookie on a bearer route. bug in the HTTP client.".into()
        }
        (401, _) => "unauthorized. run `tokenstat login`".into(),
        (403, _) => "forbidden. run `tokenstat login` again".into(),
        (409, "prune_guard") => {
            let mut bits = Vec::new();
            if let Some(obj) = body.as_object() {
                for (k, v) in obj {
                    if k == "error" || k == "message" {
                        continue;
                    }
                    bits.push(format!("{k}={v}"));
                }
            }
            let extra = bits.join(", ");
            format!(
                "server refused a destructive replace ({extra}). \
                 re-run `tokenstat sync --prune` after you confirm"
            )
        }
        (413, _) => "window too large. shrink with --window from..to".into(),
        (_, _) => format!("sync failed ({status}): {detail}"),
    };
    ProfileError::Message(msg)
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let dig = hasher.finalize();
    let mut out = String::with_capacity(64);
    for b in dig {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn gzip_bytes(bytes: &[u8]) -> Result<Vec<u8>, ProfileError> {
    let mut enc = GzEncoder::new(Vec::new(), Compression::default());
    enc.write_all(bytes)?;
    Ok(enc.finish()?)
}

fn open_browser(url: &str) -> Result<(), ProfileError> {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open").arg(url).status();
    }
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("xdg-open").arg(url).status();
    }
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("cmd")
            .args(["/C", "start", "", url])
            .status();
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use tokenstat_core::{
        BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
    };

    #[test]
    fn a_pairing_code_is_accepted_however_it_was_pasted() {
        // People paste from a web page: lowercase, dash eaten, a stray space or
        // quote picked up by the selection. All the same code.
        for raw in [
            "WXYZ-1234",
            "wxyz-1234",
            "wxyz1234",
            "  WXYZ-1234  ",
            "\"WXYZ-1234\"",
            "WXYZ 1234",
        ] {
            assert_eq!(
                normalize_pairing_code(raw).unwrap(),
                "WXYZ-1234",
                "failed for {raw:?}"
            );
        }
    }

    #[test]
    fn a_code_of_the_wrong_length_is_refused_before_the_network() {
        for raw in ["WXYZ-123", "WXYZ-12345", "", "tokenstat login --code"] {
            assert!(normalize_pairing_code(raw).is_err(), "accepted {raw:?}");
        }
    }

    #[test]
    fn the_jitter_offset_is_stable_for_a_machine_and_inside_the_window() {
        let a = jitter_offset("m_0123456789abcdef", JITTER_WINDOW_SECS);
        assert_eq!(a, jitter_offset("m_0123456789abcdef", JITTER_WINDOW_SECS));
        assert!(a < JITTER_WINDOW_SECS);
    }

    #[test]
    fn different_machines_land_on_different_offsets() {
        // Not a guarantee for any two ids, but a spread this coarse would show up
        // as an outright collision across a handful of them.
        let offsets: Vec<u64> = [
            "m_0000000000000001",
            "m_0000000000000002",
            "m_0000000000000003",
            "m_0000000000000004",
        ]
        .iter()
        .map(|m| jitter_offset(m, JITTER_WINDOW_SECS))
        .collect();
        let mut sorted = offsets.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), offsets.len(), "offsets collided: {offsets:?}");
    }

    #[test]
    fn a_zero_window_asks_for_no_wait() {
        assert_eq!(jitter_offset("m_0123456789abcdef", 0), 0);
    }

    #[test]
    fn pacing_is_read_from_the_response_body() {
        let body = r#"{"ok":true,"min_interval":1800,"next_allowed_at":"2026-07-30T09:00:00Z"}"#;
        let p = pacing_from_body(body, None);
        assert_eq!(p.min_interval, Some(1800));
        assert_eq!(p.next_allowed_at.as_deref(), Some("2026-07-30T09:00:00Z"));
    }

    #[test]
    fn retry_after_stands_in_for_a_missing_body() {
        // An intermediary can rate-limit us without speaking our JSON.
        let p = pacing_from_body("Too many requests", Some(120));
        assert_eq!(p.min_interval, None);
        assert!(p.next_allowed_at.is_some());
    }

    #[test]
    fn pacing_from_an_unhelpful_response_is_empty_rather_than_wrong() {
        let p = pacing_from_body("", None);
        assert!(p.min_interval.is_none());
        assert!(p.next_allowed_at.is_none());
    }

    #[test]
    fn idempotency_key_stable_for_same_canonical_bytes() {
        let bytes = br#"{"generated_at":"2026-07-29T00:00:00Z","machine":"m_0123456789abcdef","prune":false,"rows":[],"salt_id":"s_abcdef01","totals":{"cr":0,"cw":0,"in":0,"out":0,"rows":0},"tz":"UTC","v":1,"window":{"from":"2026-07-25","to":"2026-07-25"}}"#;
        assert_eq!(hex_sha256(bytes), hex_sha256(bytes));
        assert_eq!(hex_sha256(bytes).len(), 64);
    }

    #[test]
    fn gzip_roundtrip_prefix() {
        let gz = gzip_bytes(b"hello").unwrap();
        assert_eq!(&gz[..2], &[0x1f, 0x8b]);
    }

    #[test]
    fn build_path_hashes_project() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let ms = 1_753_444_800_000i64;
        let day = Timestamp::from_ms(ms).local_date(&tz);
        store
            .insert_events(
                &[UsageEvent {
                    id: EventId::derive(&["x"]),
                    source: SourceId::ClaudeCode,
                    ts: Timestamp::from_ms(ms),
                    model: "claude-opus-4-8".into(),
                    session: "s".into(),
                    project: "/tmp/secret".into(),
                    counters: Counters {
                        input_fresh: Some(1),
                        cache_read: Some(0),
                        cache_write_5m: Some(0),
                        cache_write_1h: None,
                        output: Some(2),
                    },
                    extras: Extras::default(),
                    billing: BillingMode::Plan,
                    confidence: Confidence::Exact,
                }],
                &tz,
            )
            .unwrap();
        let salt = [9u8; 32];
        let payload = build_sync_payload(
            &store,
            SyncBuildArgs {
                machine: "m_0123456789abcdef",
                salt_id: "s_abcdef01",
                salt_key: &salt,
                tz: "UTC",
                window: SyncWindow {
                    from: day.clone(),
                    to: day,
                },
                prune: false,
                schema_v: 1,
                allowed_sources: None,
                allowed_confidence: None,
            },
        )
        .unwrap();
        assert!(!payload.prune);
        assert!(payload.rows[0].proj.is_some());
        let json = String::from_utf8(payload.canonical_bytes().unwrap()).unwrap();
        assert!(!json.contains("/tmp/secret"));
        assert!(json.contains("\"salt_id\":\"s_abcdef01\""));
    }
}

#[cfg(test)]
mod auth_state_tests {
    use super::*;

    #[test]
    fn the_signed_out_messages_are_recognised_as_signed_out() {
        // A GUI shows a sign-in button for these and an error banner for
        // anything else, so the two must not drift apart.
        assert!(ProfileError::Message(NOT_LOGGED_IN.into()).is_unauthenticated());
        assert!(ProfileError::Message(TOKEN_REVOKED.into()).is_unauthenticated());
    }

    #[test]
    fn a_real_failure_is_not_mistaken_for_being_signed_out() {
        assert!(!ProfileError::Message("status request failed (500)".into()).is_unauthenticated());
        assert!(!ProfileError::Message(String::new()).is_unauthenticated());
        assert!(
            !ProfileError::RateLimited {
                message: "slow down".into(),
                retry_after: None,
                next_allowed_at: None,
            }
            .is_unauthenticated()
        );
    }
}
