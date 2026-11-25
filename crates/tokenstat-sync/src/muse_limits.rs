// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Muse's own subscription windows, read without starting a model turn.
//!
//! Prefer `muse usage --json`: the CLI already holds the login (file or
//! keychain) and returns the same Everyday / weekly snapshot shown by `/usage`.
//! That keeps keychain access inside Muse. Only when the CLI is missing or
//! silent do we call Meta's account endpoint with a local OAuth credential
//! (file first, keychain only when `auth.json` says so). Never replace Muse's
//! credentials or renew its OAuth login. API-key-only accounts cannot read
//! the account endpoint.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde::Deserialize;
use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};
use zeroize::{Zeroize, Zeroizing};

// This account route is outside /v1, unlike Muse's model API.
const ACCOUNT_URL: &str = "https://api.meta.ai/muse-code/key";
const MAX_BYTES: u64 = 128 * 1024;
const CLI_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Deserialize)]
struct StoredAuth {
    providers: Providers,
}

#[derive(Deserialize)]
struct Providers {
    meta: StoredProvider,
}

#[derive(Deserialize)]
struct StoredProvider {
    #[serde(default)]
    mechanism: Option<String>,
    #[serde(default)]
    storage: Option<String>,
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    expires_at: Option<i64>,
}

impl Drop for StoredProvider {
    fn drop(&mut self) {
        self.access_token.zeroize();
    }
}

#[derive(Deserialize)]
struct AccountResponse {
    #[serde(default)]
    is_subs_active: Option<bool>,
    #[serde(default)]
    subs_tier_name: Option<String>,
    #[serde(default)]
    subs_usage: Option<SubscriptionUsage>,
}

#[derive(Deserialize)]
struct SubscriptionUsage {
    #[serde(default)]
    window: Option<Window>,
    #[serde(default)]
    weekly: Option<Window>,
}

#[derive(Deserialize)]
struct Window {
    used_percent: f64,
    #[serde(default)]
    window_duration_mins: Option<i64>,
    #[serde(default)]
    resets_at: Option<i64>,
}

/// `muse usage --json` schema (v1): camelCase, resets already in milliseconds.
#[derive(Deserialize)]
struct CliUsage {
    #[serde(default)]
    allowance: Option<CliAllowance>,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    hint: Option<String>,
}

#[derive(Deserialize)]
struct CliAllowance {
    #[serde(default)]
    tier: Option<String>,
    #[serde(default)]
    window: Option<CliWindow>,
    #[serde(default)]
    weekly: Option<CliWindow>,
    #[serde(default, rename = "asOfMs")]
    as_of_ms: Option<i64>,
}

#[derive(Deserialize)]
struct CliWindow {
    #[serde(rename = "usedPercent")]
    used_percent: f64,
    #[serde(default, rename = "resetsAtMs")]
    resets_at_ms: Option<i64>,
}

/// Fetch the vendor-reported subscription quota using Muse's own tools.
pub fn fetch() -> ProviderLimits {
    if let Some(limits) = cli_usage() {
        return limits;
    }
    account_usage()
}

fn cli_usage() -> Option<ProviderLimits> {
    let program = muse_program()?;
    let mut command = Command::new(&program);
    command
        .args(["usage", "--json"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("PATH", muse_search_path());
    if let Some(home) = directories::BaseDirs::new() {
        command.current_dir(home.home_dir());
    }
    let mut child = command.spawn().ok()?;
    let stdout = child.stdout.take()?;
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut raw = Zeroizing::new(String::new());
        let _ = stdout.take(MAX_BYTES + 1).read_to_string(&mut raw);
        let _ = sender.send(raw);
    });
    let raw = match receiver.recv_timeout(CLI_TIMEOUT) {
        Ok(raw) => raw,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
    };
    let status = child.wait().ok()?;
    if !status.success() || raw.len() as u64 > MAX_BYTES || raw.trim().is_empty() {
        return None;
    }
    let parsed: CliUsage = serde_json::from_str(&raw).ok()?;
    Some(cli_reading(parsed))
}

fn cli_reading(usage: CliUsage) -> ProviderLimits {
    let Some(allowance) = usage.allowance else {
        let note = usage
            .hint
            .or(usage.reason)
            .filter(|text| !text.trim().is_empty())
            .unwrap_or_else(|| {
                "Muse reported no subscription usage windows for this account.".into()
            });
        return unavailable(note);
    };
    let observed_at_ms = allowance.as_of_ms.unwrap_or_else(now_ms);
    let mut windows = Vec::new();
    // Everyday's rolling window is the same 5-hour gauge Home already knows.
    if let Some(window) = allowance.window.and_then(|w| w.reading("5-hour".into())) {
        windows.push(window);
    }
    if let Some(window) = allowance.weekly.and_then(|w| w.reading("weekly".into())) {
        windows.push(window);
    }
    if windows.is_empty() {
        return unavailable("Muse reported no valid subscription usage windows for this account.");
    }
    ProviderLimits {
        source: "muse".into(),
        plan: allowance
            .tier
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty() && name.len() <= 160),
        windows,
        observed_at_ms,
        note: None,
        stale: false,
    }
}

impl CliWindow {
    fn reading(self, label: String) -> Option<UsageWindow> {
        if !self.used_percent.is_finite() || self.used_percent < 0.0 {
            return None;
        }
        let percent = self.used_percent.min(100.0);
        Some(UsageWindow {
            label,
            scope: None,
            percent,
            resets_at_ms: self.resets_at_ms.filter(|ms| *ms > 0),
            severity: LimitSeverity::from_percent(percent),
        })
    }
}

fn account_usage() -> ProviderLimits {
    let token = match stored_token() {
        Ok(token) => token,
        Err(note) => return unavailable(note),
    };
    let client = match crate::http::client_builder()
        .timeout(Duration::from_secs(15))
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(client) => client,
        Err(_) => return unavailable("Could not prepare the Muse account request."),
    };
    // Stamp the request, rather than making a delayed reply look newer.
    let observed_at_ms = now_ms();
    let response = match client
        .post(ACCOUNT_URL)
        .bearer_auth(token.as_str())
        .header("accept", "application/json")
        .header("x-api-version", "1.0.0")
        .header("x-client-id", "tbh:tui")
        .json(&serde_json::json!({"show_subs_upsell": false}))
        .send()
    {
        Ok(response) => response,
        Err(_) => return unavailable("Could not reach Muse's account service."),
    };
    if !response.status().is_success() {
        return unavailable(match response.status() {
            reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN => {
                "The stored Muse login was refused. Sign in again with Muse to refresh it.".into()
            }
            reqwest::StatusCode::TOO_MANY_REQUESTS => {
                "Muse is rate limiting account requests. Try again shortly.".into()
            }
            status => format!("Muse returned {status} for its account endpoint."),
        });
    }
    // The reply also contains a credential. Bound it, do not log it, and
    // deserialize only the fields eligible for the limits cache/sync.
    let mut raw = Zeroizing::new(String::new());
    if response
        .take(MAX_BYTES + 1)
        .read_to_string(&mut raw)
        .is_err()
        || raw.len() as u64 > MAX_BYTES
    {
        return unavailable("Could not read Muse's account answer.");
    }
    match serde_json::from_str::<AccountResponse>(&raw) {
        Ok(account) => reading(account, observed_at_ms),
        Err(_) => unavailable("Muse returned an unrecognized account answer."),
    }
}

fn reading(account: AccountResponse, observed_at_ms: i64) -> ProviderLimits {
    if account.is_subs_active == Some(false) {
        return unavailable("This Muse account has no active subscription.");
    }
    let Some(usage) = account.subs_usage else {
        return unavailable("Muse reported no subscription usage windows for this account.");
    };
    let mut windows = Vec::new();
    if let Some(window) = usage.window
        && let Some(minutes) = window.window_duration_mins.filter(|minutes| *minutes > 0)
    {
        let label = if minutes % 60 == 0 {
            format!("{}-hour", minutes / 60)
        } else {
            format!("{minutes}-minute")
        };
        if let Some(window) = window.reading(label) {
            windows.push(window);
        }
    }
    if let Some(window) = usage.weekly.and_then(|w| w.reading("weekly".into())) {
        windows.push(window);
    }
    if windows.is_empty() {
        return unavailable("Muse reported no valid subscription usage windows for this account.");
    }
    ProviderLimits {
        source: "muse".into(),
        plan: account
            .subs_tier_name
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty() && name.len() <= 160),
        windows,
        observed_at_ms,
        note: None,
        stale: false,
    }
}

impl Window {
    fn reading(self, label: String) -> Option<UsageWindow> {
        if !self.used_percent.is_finite() || self.used_percent < 0.0 {
            return None;
        }
        // Muse permits overage; the existing client contract caps the gauge.
        let percent = self.used_percent.min(100.0);
        Some(UsageWindow {
            label,
            scope: None,
            percent,
            resets_at_ms: self
                .resets_at
                .filter(|seconds| *seconds > 0)
                .and_then(|seconds| seconds.checked_mul(1000)),
            severity: LimitSeverity::from_percent(percent),
        })
    }
}

fn muse_program() -> Option<String> {
    let path = muse_search_path();
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join("muse");
        if is_executable(&candidate) {
            return Some(candidate.display().to_string());
        }
        #[cfg(windows)]
        {
            for ext in ["cmd", "bat", "exe"] {
                let with_ext = candidate.with_extension(ext);
                if is_executable(&with_ext) {
                    return Some(with_ext.display().to_string());
                }
            }
        }
    }
    None
}

fn muse_search_path() -> String {
    let mut dirs = Vec::new();
    if let Some(home) = directories::BaseDirs::new() {
        dirs.push(home.home_dir().join(".local").join("bin"));
        #[cfg(windows)]
        dirs.push(home.data_local_dir().join("Programs").join("muse"));
    }
    if let Ok(existing) = std::env::var("PATH") {
        for part in std::env::split_paths(&existing) {
            if !dirs.iter().any(|known| known == &part) {
                dirs.push(part);
            }
        }
    }
    std::env::join_paths(dirs)
        .ok()
        .and_then(|value| value.into_string().ok())
        .unwrap_or_else(|| std::env::var("PATH").unwrap_or_default())
}

fn is_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn config_path() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| Some(directories::BaseDirs::new()?.home_dir().join(".config")))
        .map(|path| path.join("muse/auth.json"))
}

fn read_auth(path: &Path) -> Option<StoredProvider> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path).ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut raw = Zeroizing::new(String::new());
    file.take(MAX_BYTES + 1).read_to_string(&mut raw).ok()?;
    if raw.len() as u64 > MAX_BYTES {
        return None;
    }
    Some(
        serde_json::from_str::<StoredAuth>(&raw)
            .ok()?
            .providers
            .meta,
    )
}

fn stored_token() -> Result<Zeroizing<String>, &'static str> {
    let mut provider = config_path().and_then(|path| read_auth(&path)).ok_or(
        "Not signed in to Muse on this machine, so its subscription limits cannot be read.",
    )?;
    if provider
        .mechanism
        .as_deref()
        .is_some_and(|mechanism| mechanism != "oauth")
    {
        return Err("Muse subscription limits require an OAuth login, rather than an API key.");
    }
    // Muse's file expiry is epoch seconds. Never rotate its refresh token.
    // Keychain-backed logins often omit expires_at from auth.json; the
    // keychain secret itself carries the live access token.
    if provider.storage.as_deref() != Some("keychain")
        && provider
            .expires_at
            .is_some_and(|seconds| seconds <= now_ms() / 1000 + 60)
    {
        return Err("The stored Muse login has expired. Sign in again with Muse to refresh it.");
    }
    let token = match provider.storage.as_deref() {
        Some("keychain") => keychain_token(),
        None | Some("file") => provider.access_token.take().map(Zeroizing::new),
        _ => None,
    };
    token.filter(|token| !token.trim().is_empty()).ok_or(
        "Muse's stored login could not be read. Check its Keychain access or sign in with Muse again.",
    )
}

#[cfg(target_os = "macos")]
fn keychain_token() -> Option<Zeroizing<String>> {
    let crate::discover::KeychainItem::Found(raw) =
        crate::discover::keychain_item("ai.meta.dev.credentials", "meta")
    else {
        return None;
    };
    let raw = Zeroizing::new(raw);
    let mut secret: StoredProvider = serde_json::from_str(&raw).ok()?;
    secret.access_token.take().map(Zeroizing::new)
}

#[cfg(not(target_os = "macos"))]
fn keychain_token() -> Option<Zeroizing<String>> {
    None
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn unavailable(note: impl Into<String>) -> ProviderLimits {
    ProviderLimits::unavailable("muse", note)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(raw: &str) -> ProviderLimits {
        reading(serde_json::from_str(raw).unwrap(), 1_791_829_616_048)
    }

    #[test]
    fn account_response_maps_real_subscription_windows_without_credentials() {
        let limits = parse(
            r#"{"api_key":"must-not-be-saved","user_email":"private@example.com","is_subs_active":true,"subs_tier_name":"Muse Code Everyday Usage","subs_usage":{"window":{"used_percent":4,"window_duration_mins":300,"resets_at":1791847496},"weekly":{"used_percent":1,"resets_at":1792368000},"tier":"27681393394859588"}}"#,
        );
        assert_eq!(limits.plan.as_deref(), Some("Muse Code Everyday Usage"));
        assert_eq!(limits.windows.len(), 2);
        assert_eq!(limits.windows[0].label, "5-hour");
        assert_eq!(limits.windows[0].percent, 4.0);
        assert_eq!(limits.windows[0].resets_at_ms, Some(1_791_847_496_000));
        assert_eq!(limits.windows[1].label, "weekly");
        assert_eq!(limits.windows[1].resets_at_ms, Some(1_792_368_000_000));
        let serialized = serde_json::to_string(&limits).unwrap();
        assert!(!serialized.contains("must-not-be-saved"));
        assert!(!serialized.contains("private@example.com"));
        assert!(!serialized.contains("27681393394859588"));
    }

    #[test]
    fn cli_usage_json_maps_everyday_windows() {
        let limits = cli_reading(
            serde_json::from_str(
                r#"{"schemaVersion":1,"allowance":{"tier":"Muse Code Everyday Usage","window":{"usedPercent":3,"resetsAtMs":1795645853000},"weekly":{"usedPercent":1,"resetsAtMs":1795996800000},"asOfMs":1795629921492,"source":"mint"},"reason":null,"hint":null}"#,
            )
            .unwrap(),
        );
        assert_eq!(limits.plan.as_deref(), Some("Muse Code Everyday Usage"));
        assert_eq!(limits.observed_at_ms, 1_795_629_921_492);
        assert_eq!(limits.windows.len(), 2);
        assert_eq!(limits.windows[0].label, "5-hour");
        assert_eq!(limits.windows[0].percent, 3.0);
        assert_eq!(limits.windows[0].resets_at_ms, Some(1_795_645_853_000));
        assert_eq!(limits.windows[1].label, "weekly");
        assert_eq!(limits.windows[1].percent, 1.0);
    }

    #[test]
    fn absent_or_unsubscribed_quota_is_not_zero_usage() {
        for raw in [
            "{}",
            r#"{"subs_usage":null}"#,
            r#"{"is_subs_active":false,"subs_usage":{"weekly":{"used_percent":0}}}"#,
        ] {
            let limits = parse(raw);
            assert!(limits.windows.is_empty());
            assert!(limits.note.is_some());
        }
    }

    #[test]
    fn overage_and_invalid_resets_keep_a_safe_gauge() {
        let limits = parse(
            r#"{"subs_usage":{"window":{"used_percent":112,"window_duration_mins":90,"resets_at":9223372036854775807},"weekly":{"used_percent":-1}}}"#,
        );
        assert_eq!(limits.windows.len(), 1);
        assert_eq!(limits.windows[0].label, "90-minute");
        assert_eq!(limits.windows[0].percent, 100.0);
        assert_eq!(limits.windows[0].severity, LimitSeverity::Critical);
        assert_eq!(limits.windows[0].resets_at_ms, None);
    }

    #[test]
    fn file_credentials_follow_the_muse_provider_slot() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("auth.json");
        std::fs::write(&path, r#"{"schema_version":1,"providers":{"meta":{"mechanism":"oauth","storage":"file","access_token":"fixture","expires_at":2000000000}}}"#).unwrap();
        let provider = read_auth(&path).unwrap();
        assert_eq!(provider.access_token.as_deref(), Some("fixture"));
        assert_eq!(provider.expires_at, Some(2_000_000_000));
        std::fs::write(&path, "x".repeat(MAX_BYTES as usize + 1)).unwrap();
        assert!(read_auth(&path).is_none());
        assert!(read_auth(root.path()).is_none());
    }

    #[test]
    #[ignore = "requires an installed, signed-in Muse subscription"]
    fn installed_muse_subscription_reports_limits_without_a_turn() {
        let limits = fetch();
        assert!(limits.has_reading(), "{:?}", limits.note);
        assert!(limits.windows.iter().any(|window| window.label == "5-hour"));
        assert!(limits.windows.iter().any(|window| window.label == "weekly"));
    }
}
