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
    /// The device-token endpoint answered and definitively refused the grant.
    /// Kept structured so a GUI never retries it as though a packet was lost.
    #[error("login failed: {code}{detail}")]
    DeviceRejected { code: String, detail: String },
    /// Apple/server accepted the one-use device code, but its bearer could not
    /// be made durable locally. A retry of the consumed code cannot recover it.
    #[error("could not save your sign-in: {0}")]
    LoginStorage(String),
    #[error("{message}")]
    RateLimited {
        message: String,
        retry_after: Option<u64>,
        next_allowed_at: Option<String>,
    },
    /// The account host does not implement this route at all (404/405).
    ///
    /// Separated from every other refusal because it is the only failure a
    /// caller may answer by falling back to an older protocol. A 400 or a 402
    /// means the request was understood and refused, and a fallback there
    /// hides a real problem behind a path that still happens to work.
    #[error("{0}")]
    Unsupported(String),
    /// The machine row is not on the account (never registered, unlinked, or
    /// re-registered elsewhere).
    ///
    /// Structured so a caller can drive the one fix that works: re-register
    /// the machine, then mint again. A generic message would force a string
    /// match against prose the server can reword.
    #[error("this machine is not registered on the account")]
    MachineNotRegistered,
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
    /// Whether this account is the website's App Review demo account, during
    /// an open review round. False everywhere else, and false against a server
    /// old enough not to send the field: a flag that has to be present to be
    /// safe is a flag that fails open.
    pub review_demo: bool,
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
    // The one refusal with a fix the caller can perform itself. The machine
    // is not on the account: re-registering it (PUT /api/v1/machines/me) is
    // exactly the repair, and the caller needs the structured signal to know
    // to do it rather than give up.
    if body.error.as_deref() == Some("machine_not_registered") {
        return ProfileError::MachineNotRegistered;
    }
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
    let text = limited_text(resp)?;
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
    // Say what this machine is, now that there is an account to tell. Signing
    // in is the explicit act that permits it, and without this a CLI-only
    // install sits in everybody's device list as a row of hex. Best effort: an
    // account that could not be told the name is still an account.
    let _ = publish_machine_profile(Some(&host));
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
    device_start_kind(host_flag, "host")
}

/// Begin device login, declaring whether this is a host or a phone client.
///
/// `kind` is `"host"` (uploads usage) or `"client"` (phone: no usage upload).
/// Both use one device slot.
pub fn device_start_kind(host_flag: Option<&str>, kind: &str) -> Result<DeviceLogin, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let machine = config::ensure_machine_id()?;
    let _salt = config::ensure_project_salt()?;
    let client = http_client()?;
    let kind = if kind == "client" { "client" } else { "host" };

    // Learn the server range early so a hopeless mismatch fails before the
    // browser dance.
    let envelope = schema::fetch_schema(&client, &host)?;
    let _ = envelope.choose_payload_v()?;

    let resp = client
        .post(format!("{host}/api/v1/device/code"))
        .header("content-type", "application/json")
        .json(&serde_json::json!({ "machine": machine, "kind": kind }))
        .send()?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = limited_text(resp).unwrap_or_default();
        return Err(ProfileError::Message(format!(
            "device code request failed ({status}): {body}"
        )));
    }

    let device: DeviceCodeResponse = resp.json()?;
    // Refuse phishing / non-HTTPS schemes before any UI opens a browser.
    crate::host::assert_safe_verification_url(&device.verification_uri, &host)
        .map_err(|e| ProfileError::Message(e.to_string()))?;
    if let Some(ref complete) = device.verification_uri_complete {
        crate::host::assert_safe_verification_url(complete, &host)
            .map_err(|e| ProfileError::Message(e.to_string()))?;
    }
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
    let text = limited_text(poll)?;

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
        keychain::store_token(&login.host, &ok.token)
            .map_err(|e| ProfileError::LoginStorage(format!("credential file: {e}")))?;
        config::set_sync_host(&login.host)
            .map_err(|e| ProfileError::LoginStorage(format!("account host setting: {e}")))?;
        // Same as the pairing path: name this machine on the account it just
        // joined, and do not fail the login if that call does not land.
        let _ = publish_machine_profile(Some(&login.host));
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
    Err(ProfileError::DeviceRejected {
        code: err.error.unwrap_or_else(|| status.to_string()),
        detail: err.message.map(|m| format!(" ({m})")).unwrap_or_default(),
    })
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

/// Sign out of the resolved host.
///
/// Revokes the bearer on the server first, then deletes the local keychain
/// entry. A local-only delete left the credential valid for its whole life,
/// so "signed out" on a phone someone was handing on did nothing online.
///
/// The server call is best-effort and short: a hung revoke must not pin Sign
/// out for the full 60s profile timeout. Keychain delete always runs after the
/// attempt, so a dead network still signs this device out. An already-revoked
/// or expired token is treated the same as success.
pub fn logout(host_flag: Option<&str>) -> Result<String, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    if let Some(token) = keychain::load_token(&host)? {
        // Dedicated client with a short budget. Reusing `http_client` meant a
        // dropped path could hold the whole logout for 60 seconds, and the
        // keychain only cleared after that.
        if let Ok(client) = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(4))
            .connect_timeout(Duration::from_secs(2))
            .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
            .redirect(reqwest::redirect::Policy::none())
            .build()
        {
            let _ = client
                .post(format!("{host}/api/v1/logout"))
                .header("authorization", format!("Bearer {token}"))
                .send();
        }
    }
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
    let text = limited_text(resp)?;
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
    let review_demo = raw
        .get("review_demo")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(StatusResult {
        host,
        handle,
        tier,
        last_sync_at,
        machines,
        schema_min_v,
        schema_max_v,
        schema_current,
        review_demo,
        raw,
    })
}

/// Bind a StoreKit transaction JWS to the signed-in account.
///
/// The website verifies Apple's signature and the `appAccountToken`. This
/// crate only carries the bearer token and the JWS. No StoreKit types here.
pub fn apple_activate(
    host_flag: Option<&str>,
    signed_transaction: &str,
) -> Result<Value, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let resp = client
        .post(format!("{host}/api/v1/billing/apple/activate"))
        .header("authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "signedTransaction": signed_transaction }))
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("message")
                    .and_then(|m| m.as_str())
                    .map(str::to_string)
                    .or_else(|| v.get("error").and_then(|e| e.as_str()).map(str::to_string))
            })
            .unwrap_or(text);
        return Err(ProfileError::Message(detail));
    }
    let raw: Value = serde_json::from_str(&text)?;
    Ok(raw)
}

/// Post StoreKit signed renewal info so a queued downgrade or a cancelled
/// auto-renew shows on the website before Apple issues a new transaction.
pub fn apple_renewal(
    host_flag: Option<&str>,
    signed_renewal_info: &str,
) -> Result<Value, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let resp = client
        .post(format!("{host}/api/v1/billing/apple/renewal"))
        .header("authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "signedRenewalInfo": signed_renewal_info }))
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("message")
                    .and_then(|m| m.as_str())
                    .map(str::to_string)
                    .or_else(|| v.get("error").and_then(|e| e.as_str()).map(str::to_string))
            })
            .unwrap_or(text);
        return Err(ProfileError::Message(detail));
    }
    let raw: Value = serde_json::from_str(&text)?;
    Ok(raw)
}

/// Bind a verified Google Play purchase token to the signed-in account.
///
/// Verification and acknowledgement belong to the account service, which has
/// the Play Developer API credential. The client supplies only the opaque
/// purchase token and the immutable catalog identifiers returned by Billing.
pub fn google_activate(
    host_flag: Option<&str>,
    package_name: &str,
    product_id: &str,
    purchase_token: &str,
) -> Result<Value, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let resp = client
        .post(format!("{host}/api/v1/billing/google/activate"))
        .header("authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "packageName": package_name,
            "productId": product_id,
            "purchaseToken": purchase_token,
        }))
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("message")
                    .and_then(|m| m.as_str())
                    .or_else(|| v.get("error").and_then(|e| e.as_str()))
                    .map(str::to_string)
            })
            .unwrap_or(text);
        return Err(ProfileError::Message(detail));
    }
    Ok(serde_json::from_str(&text)?)
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
    register_machine_identity_kind(host_flag, machine_id, public_identity, label, "host")
}

/// Register a host or a client on the account.
///
/// `kind` is `"host"` (default, uploads usage) or `"client"` (phone: reaches
/// hosts over the tunnel). Both use one device slot.
pub fn register_machine_identity_kind(
    host_flag: Option<&str>,
    machine_id: &str,
    public_identity: &str,
    label: &str,
    kind: &str,
) -> Result<(), ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let kind = if kind == "client" { "client" } else { "host" };
    let resp = client
        .put(format!("{host}/api/v1/machines/me"))
        .header("authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({
            "machine": machine_id,
            "public_identity": public_identity,
            "label": label,
            "kind": kind,
            // What this machine is, in the words a person reads: "Ubuntu 24.04
            // · x86_64". Coarse on purpose, and the machine's own answer
            // rather than a name, so it is refreshed on every registration
            // while a name somebody typed is not.
            "platform": tokenstat_identity::platform().pretty(),
        }))
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
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

/// Tell the account what this machine is called and what it is.
///
/// The same record as [`register_machine_identity_kind`] with no public key,
/// because this is not remote reach: a CLI install on a server should still
/// appear in the device list under its own name rather than as a row of hex,
/// and it has no tunnel to offer. Called after a login, which is an explicit
/// act, and never from a plain sync.
pub fn publish_machine_profile(host_flag: Option<&str>) -> Result<(), ProfileError> {
    let machine_id = crate::config::ensure_machine_id()?;
    register_machine_identity_kind(
        host_flag,
        &machine_id,
        "",
        &tokenstat_identity::machine_label(),
        default_machine_kind(),
    )
}

/// What kind of device this build runs on.
///
/// A phone reaches hosts and never uploads an archive. The server pins the
/// kind at first registration, so this only has to be right, not defended.
fn default_machine_kind() -> &'static str {
    if cfg!(target_os = "ios") {
        "client"
    } else {
        "host"
    }
}

/// Call a device on this account something.
///
/// The label on the account row, not the one on that machine's disk. That is
/// the point: a headless server cannot be reached to be renamed, so the name
/// people see has to be settable from whichever machine they are holding. The
/// server marks it as chosen, so the named machine's own registration stops
/// overwriting it.
///
/// An empty name is a reset rather than an error, the same undo the local
/// field has: the device goes back to the name it gives itself.
pub fn rename_machine(
    host_flag: Option<&str>,
    machine_id: &str,
    label: &str,
) -> Result<(), ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let label = label.trim();
    let resp = client
        .patch(format!("{host}/api/v1/machines/{machine_id}"))
        .header("authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "label": label }))
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "could not rename the device on the account ({status}): {text}"
        )));
    }
    // Clearing only drops the choice. The row is now nameless until the named
    // machine registers again, which on a machine with remote reach off may be
    // never, so this machine says its own name straight away. Only for itself:
    // clearing another device's name cannot be answered with this one's.
    if label.is_empty() && crate::config::ensure_machine_id().is_ok_and(|mine| mine == machine_id) {
        publish_machine_profile(host_flag)?;
    }
    Ok(())
}

/// Short-lived tunnel HELLO credential for one machine.
///
/// Minted with the long-lived login/sync bearer. The returned secret is
/// `tunnel:connect` only and expires; it is not written to the keychain.
#[derive(Debug, Clone)]
pub struct TunnelToken {
    pub token: String,
    pub expires_at: String,
    pub expires_in: u64,
    pub machine: String,
}

#[derive(Debug, Deserialize)]
struct TunnelTokenResponse {
    token: String,
    expires_at: String,
    expires_in: u64,
    machine: String,
}

/// Mint (or rotate) a short-lived tunnel token for `machine_id`.
///
/// Call after [`register_machine_identity`] so the machine has a
/// `public_identity` the relay can bind the token to.
pub fn mint_tunnel_token(
    host_flag: Option<&str>,
    machine_id: &str,
) -> Result<TunnelToken, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let resp = client
        .post(format!("{host}/api/v1/tunnel/token"))
        .header("authorization", format!("Bearer {token}"))
        .json(&serde_json::json!({ "machine": machine_id }))
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    // Only a missing route means "this host predates tunnel tokens". Every
    // other refusal is a real answer and must reach the caller intact.
    if status.as_u16() == 404 || status.as_u16() == 405 {
        return Err(ProfileError::Unsupported(format!(
            "this account host has no tunnel token endpoint ({status})"
        )));
    }
    if !status.is_success() {
        return Err(refusal_error(&text, status.as_u16()));
    }
    let body: TunnelTokenResponse = serde_json::from_str(&text)
        .map_err(|e| ProfileError::Message(format!("tunnel token response unreadable: {e}")))?;
    if body.token.is_empty() {
        return Err(ProfileError::Message("tunnel token response empty".into()));
    }
    Ok(TunnelToken {
        token: body.token,
        expires_at: body.expires_at,
        expires_in: body.expires_in,
        machine: body.machine,
    })
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
/// `Serialize` as well, so a client can keep the last answer on disk and open
/// on it. The wire shape and the cached shape are deliberately the same file
/// format: a cache that re-encoded would be a second schema to keep in step.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
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
/// Intensity-only day for a locked Free year.
///
/// Exact counts stay off the wire. A shade is enough to keep the year shape
/// from reading as a month of empty squares.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct LockedDay {
    pub d: String,
    #[serde(default)]
    pub level: u8,
}

pub struct SeriesResult {
    pub rows: Vec<SeriesRow>,
    /// The window the service actually covered.
    ///
    /// Not the window that was asked for. A plan's history span narrows the
    /// exact rows. Older days, when the plan locks them, arrive as
    /// intensity-only stubs on [`locked`] so the grid can keep a year of
    /// squares instead of shrinking to a month.
    pub from: Option<String>,
    pub to: Option<String>,
    /// First unlocked day. Days before this are year-shape only.
    pub unlock_from: Option<String>,
    pub history_locked: bool,
    pub history_days: Option<u16>,
    pub locked: Vec<LockedDay>,
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
    let text = limited_text(resp)?;
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
    let unlock_from = raw
        .get("unlockFrom")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .or_else(|| field("from"));
    let history_locked = raw
        .get("historyLocked")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let history_days = raw
        .get("historyDays")
        .and_then(|v| v.as_u64())
        .and_then(|n| u16::try_from(n).ok());
    let locked = raw
        .get("locked")
        .cloned()
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default();
    Ok(SeriesResult {
        rows: serde_json::from_value(rows)?,
        from: field("from"),
        to: field("to"),
        unlock_from,
        history_locked,
        history_days,
        locked,
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

    // Opt-in plan limits post (P2). Failures are not a failed sync: the
    // counters already landed, and a vendor that is down must not block that.
    if config::limits_sync_enabled() {
        let _ = post_limits(Some(&host), None);
    }

    Ok(SyncResult {
        host,
        window,
        rows: payload.totals.rows,
        idempotency_key,
        dry_run: false,
        schema_v,
    })
}

/// One provider in a limits POST / GET (account plane, P2).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AccountLimitProvider {
    pub src: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    pub observed_at_ms: i64,
    #[serde(default)]
    pub stale: bool,
    pub windows: Vec<AccountLimitWindow>,
    /// Present on GET only: which machine posted this reading.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AccountLimitWindow {
    pub label: String,
    pub percent: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at_ms: Option<i64>,
}

/// Readings that may leave this machine: numbers, current, and not skipped.
pub(crate) fn eligible_limit_providers<'a>(
    list: &'a [tokenstat_core::limits::ProviderLimits],
    skip: &[String],
) -> Vec<&'a tokenstat_core::limits::ProviderLimits> {
    list.iter()
        .filter(|p| p.has_reading() && !p.stale && !skip.iter().any(|s| s == &p.source))
        .collect()
}

/// POST current plan-limit readings for this machine.
///
/// Only readings that have windows and are not stale. Uses the same local
/// cache the Mac Insights card uses after a limits refresh; callers that want
/// a fresh vendor pass should refresh first. Sources in the skip list stay
/// on this machine.
pub fn post_limits(
    host_flag: Option<&str>,
    providers: Option<&[tokenstat_core::limits::ProviderLimits]>,
) -> Result<u32, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let machine = config::ensure_machine_id()?;
    let list: Vec<tokenstat_core::limits::ProviderLimits> = match providers {
        Some(p) => p.to_vec(),
        None => tokenstat_core::limits::cache::load()
            .into_values()
            .collect(),
    };
    let skip = config::limits_skip();
    let body_providers: Vec<serde_json::Value> = eligible_limit_providers(&list, &skip)
        .into_iter()
        .map(|p| {
            serde_json::json!({
                "src": p.source,
                "plan": p.plan,
                "observed_at_ms": p.observed_at_ms,
                "stale": false,
                "windows": p.windows.iter().map(|w| serde_json::json!({
                    "label": w.label,
                    "percent": w.percent,
                    "resets_at_ms": w.resets_at_ms,
                })).collect::<Vec<_>>(),
            })
        })
        .collect();
    if body_providers.is_empty() {
        return Ok(0);
    }
    let observed_at = jiff::Timestamp::now()
        .strftime("%Y-%m-%dT%H:%M:%SZ")
        .to_string();
    let body = serde_json::json!({
        "v": 1,
        "machine": machine,
        "observed_at": observed_at,
        "providers": body_providers,
    });
    let client = http_client()?;
    let resp = client
        .post(format!("{host}/api/v1/limits"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .json(&body)
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "limits post failed ({status}): {text}"
        )));
    }
    Ok(body_providers.len() as u32)
}

/// GET plan-limit readings for this account (every machine, or one).
pub fn fetch_account_limits(
    host_flag: Option<&str>,
    machine: Option<&str>,
) -> Result<Vec<AccountLimitProvider>, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let mut url = format!("{host}/api/v1/limits");
    if let Some(m) = machine {
        url.push_str(&format!("?machine={m}"));
    }
    let client = http_client()?;
    let resp = client
        .get(&url)
        .header("authorization", format!("Bearer {token}"))
        .send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    if status.as_u16() == 401 {
        return Err(ProfileError::Message(TOKEN_REVOKED.into()));
    }
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "limits request failed ({status}): {text}"
        )));
    }
    let raw: Value = serde_json::from_str(&text)?;
    let providers = raw
        .get("providers")
        .cloned()
        .unwrap_or(Value::Array(vec![]));
    Ok(serde_json::from_value(providers)?)
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
    /// macOS is asleep or in DarkWake. The next timer tick can try again.
    Asleep,
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
    if !crate::scheduled_network_allowed() {
        return Ok(ScheduledOutcome::Asleep);
    }
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
    if !crate::scheduled_network_allowed() {
        return Ok(ScheduledOutcome::Asleep);
    }
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
    if !crate::scheduled_network_allowed() {
        return Ok(ScheduledOutcome::Asleep);
    }
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
        tokenstat_paths::data_local_dir()
            .map(|dirs| dirs.join("schedule/ai.tokenstat.sync.vbs").is_file())
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
    let dir = tokenstat_paths::data_dir()
        .ok_or_else(|| ProfileError::Message("no tokenstat data directory".into()))?;
    std::fs::create_dir_all(&dir)?;
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

fn limited_text(resp: reqwest::blocking::Response) -> Result<String, ProfileError> {
    const MAX: usize = 256 * 1024;
    let bytes = read_capped(resp, MAX)?;
    if bytes.len() > MAX {
        return Ok(format!("[response truncated: over {MAX}-byte cap]"));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn read_capped(mut resp: reqwest::blocking::Response, max: usize) -> Result<Vec<u8>, ProfileError> {
    use std::io::Read;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8 * 1024];
    loop {
        let n = resp.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        let take = n.min(max.saturating_add(1).saturating_sub(buf.len()));
        buf.extend_from_slice(&chunk[..take]);
        if buf.len() > max {
            break;
        }
    }
    Ok(buf)
}

/// Hand a URL to whatever the platform opens links with.
///
/// Silent on a platform with no such command, which is iOS and iPadOS: opening
/// a URL there goes through UIKit, not through a process, and the sign-in flow
/// that calls this already prints the address for the user to open themselves.
/// A client that cannot exec is not a client that cannot sign in.
fn open_browser(url: &str) -> Result<(), ProfileError> {
    // Named with a leading underscore so the platforms below can use it and
    // the ones with no branch do not warn about it.
    let _url = url;
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open").arg(_url).status();
    }
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("xdg-open").arg(_url).status();
    }
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("cmd")
            .args(["/C", "start", "", _url])
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

    fn reading(source: &str, stale: bool) -> tokenstat_core::limits::ProviderLimits {
        tokenstat_core::limits::ProviderLimits {
            source: source.into(),
            plan: Some("pro".into()),
            windows: vec![tokenstat_core::limits::UsageWindow {
                label: "weekly".into(),
                percent: 40.0,
                resets_at_ms: None,
                severity: tokenstat_core::limits::LimitSeverity::Normal,
            }],
            observed_at_ms: 1,
            note: None,
            stale,
        }
    }

    #[test]
    fn a_skipped_or_stale_limit_does_not_leave_the_machine() {
        let list = vec![
            reading("claude_code", false),
            reading("cursor", false),
            reading("grok", true),
            tokenstat_core::limits::ProviderLimits::unavailable("codex", "not signed in"),
        ];
        let posted = eligible_limit_providers(&list, &["cursor".into()]);
        assert_eq!(
            posted.iter().map(|p| p.source.as_str()).collect::<Vec<_>>(),
            vec!["claude_code"]
        );
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
