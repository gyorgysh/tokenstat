// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! What Grok's own account says is left of the plan.
//!
//! Here rather than in `tokenstat-core` because it makes a request, for the
//! same reason the Claude Code reader lives here.
//!
//! **The token is the one the Grok CLI already stored on this machine.** It is
//! read from `~/.grok/auth.json`, used against xAI's own endpoint, and dropped.
//! It is never written into the archive, never included in a sync payload, and
//! never sent anywhere except to the vendor it belongs to.
//!
//! Read only, and that includes the token itself. The stored credential carries
//! a refresh token, and using it would rotate the one the CLI is holding and
//! sign the user out of their own tool. An expired token is reported as an
//! expired token, and refreshing it stays the CLI's job.

use std::time::Duration;

use serde::Deserialize;
use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};

/// Monthly credits. `?format=credits` on the same path answers with the weekly
/// window instead, which is a different shape rather than a subset.
const BILLING_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing";

/// The CLI identifies itself with this on the billing call, and the endpoint
/// answers 401 without it.
const TOKEN_AUTH: &str = "xai-grok-cli";

/// The account file the CLI keeps, keyed by `<issuer>::<client id>`.
///
/// One entry per signed-in client. The keys are not known ahead of time, so the
/// whole map is read and the freshest usable entry wins.
#[derive(Debug, Deserialize)]
struct StoredAccounts(std::collections::BTreeMap<String, StoredAccount>);

#[derive(Debug, Deserialize)]
struct StoredAccount {
    /// The access token. Named `key` by the CLI, not `access_token`.
    key: String,
    /// RFC 3339, e.g. `2026-08-05T09:26:42.270306Z`.
    #[serde(default)]
    expires_at: Option<String>,
}

/// `{"config": {...}}` for both shapes the endpoint answers with.
#[derive(Debug, Deserialize)]
struct BillingResponse {
    #[serde(default)]
    config: Option<BillingConfig>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BillingConfig {
    /// Monthly shape.
    #[serde(default)]
    monthly_limit: Option<Credits>,
    #[serde(default)]
    used: Option<Credits>,
    /// Weekly shape.
    #[serde(default)]
    credit_usage_percent: Option<f64>,
    #[serde(default)]
    current_period: Option<Period>,
    /// Present in both.
    #[serde(default)]
    billing_period_end: Option<String>,
}

/// Every quantity is wrapped: `{"val": 15000}`.
#[derive(Debug, Deserialize)]
struct Credits {
    #[serde(default)]
    val: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct Period {
    #[serde(default, rename = "type")]
    kind: Option<String>,
}

/// Read the limits for the Grok account signed in on this machine.
///
/// Never returns an error, for the reason the other providers do not: a missing
/// login, an expired token or an unreachable endpoint are all "we cannot say",
/// and this lands on a dashboard beside numbers that are known.
pub fn fetch() -> ProviderLimits {
    let account = match stored_account() {
        Some(a) => a,
        None => {
            return ProviderLimits::unavailable(
                "grok",
                "Not signed in to Grok on this machine, so its limits cannot be read.",
            );
        }
    };

    if account
        .expires_at
        .as_deref()
        .and_then(parse_iso_ms)
        .is_some_and(|ms| ms <= now_ms().saturating_add(60_000))
    {
        // Refreshing is the CLI's own job and it holds the refresh token.
        return ProviderLimits::unavailable(
            "grok",
            "The stored Grok login has expired. Run any `grok` command to refresh it.",
        );
    }

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
    {
        Ok(c) => c,
        Err(e) => return ProviderLimits::unavailable("grok", e.to_string()),
    };

    let monthly = match get(&client, &account.key, BILLING_URL) {
        Ok(c) => c,
        Err(note) => return ProviderLimits::unavailable("grok", note),
    };

    // The weekly window is the one that actually bites, but it is a second
    // call, so a failure there loses that window rather than the whole reading.
    let weekly = get(
        &client,
        &account.key,
        &format!("{BILLING_URL}?format=credits"),
    )
    .ok();

    let mut windows = Vec::new();
    if let Some(window) = weekly.as_ref().and_then(weekly_window) {
        windows.push(window);
    }
    if let Some(window) = monthly_window(&monthly) {
        windows.push(window);
    }

    if windows.is_empty() {
        return ProviderLimits::unavailable(
            "grok",
            "xAI reported no usage windows for this account.",
        );
    }

    ProviderLimits {
        source: "grok".to_string(),
        plan: None,
        windows,
        observed_at_ms: now_ms(),
        note: None,
        stale: false,
    }
}

fn get(
    client: &reqwest::blocking::Client,
    token: &str,
    url: &str,
) -> Result<BillingConfig, String> {
    let response = client
        .get(url)
        .bearer_auth(token)
        .header("x-xai-token-auth", TOKEN_AUTH)
        .header("accept", "application/json")
        .send()
        .map_err(|e| format!("Could not reach xAI: {e}"))?;

    if !response.status().is_success() {
        let status = response.status();
        return Err(if status == reqwest::StatusCode::UNAUTHORIZED {
            "The stored Grok login was refused. Run any `grok` command to refresh it.".to_string()
        } else if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            "xAI is rate limiting the billing endpoint. Try again shortly.".to_string()
        } else {
            format!("xAI returned {status} for the billing endpoint.")
        });
    }

    response
        .json::<BillingResponse>()
        .map_err(|e| format!("Could not read xAI's answer: {e}"))?
        .config
        .ok_or_else(|| "xAI answered without a billing configuration.".to_string())
}

/// Credits used against the monthly allowance.
///
/// The percentage is worked out here because the endpoint gives the two counts
/// rather than a percentage, which is the one case where deriving it is not a
/// guess: both numbers are the vendor's own.
fn monthly_window(config: &BillingConfig) -> Option<UsageWindow> {
    let limit = config.monthly_limit.as_ref()?.val?;
    let used = config.used.as_ref()?.val?;
    if limit <= 0.0 {
        return None;
    }
    let percent = (used / limit * 100.0).clamp(0.0, 100.0);
    Some(UsageWindow {
        label: "monthly".to_string(),
        percent,
        resets_at_ms: config.billing_period_end.as_deref().and_then(parse_iso_ms),
        severity: LimitSeverity::from_percent(percent),
    })
}

/// The weekly window, when this account is on one.
///
/// Guarded on the period the endpoint names rather than assumed: an account
/// billed on some other cycle would otherwise have that cycle's number
/// reported as a week's.
fn weekly_window(config: &BillingConfig) -> Option<UsageWindow> {
    let kind = config.current_period.as_ref()?.kind.as_deref()?;
    if kind != "USAGE_PERIOD_TYPE_WEEKLY" {
        return None;
    }
    // Absent at the start of a fresh period rather than sent as zero.
    let percent = config.credit_usage_percent.unwrap_or(0.0).clamp(0.0, 100.0);
    Some(UsageWindow {
        label: "weekly".to_string(),
        percent,
        resets_at_ms: config.billing_period_end.as_deref().and_then(parse_iso_ms),
        severity: LimitSeverity::from_percent(percent),
    })
}

/// The account the CLI stored, or nothing.
///
/// The freshest entry wins. A machine that has signed in more than once holds
/// several, and the one that expires last is the one still usable.
fn stored_account() -> Option<StoredAccount> {
    let home = directories::UserDirs::new()?.home_dir().to_path_buf();
    let raw = std::fs::read_to_string(home.join(".grok/auth.json")).ok()?;
    serde_json::from_str::<StoredAccounts>(&raw)
        .ok()?
        .0
        .into_values()
        .filter(|a| !a.key.is_empty())
        .max_by_key(|a| a.expires_at.as_deref().and_then(parse_iso_ms).unwrap_or(0))
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn parse_iso_ms(raw: &str) -> Option<i64> {
    raw.parse::<jiff::Timestamp>()
        .ok()
        .map(|t| t.as_millisecond())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_account_file_parses_the_way_the_cli_writes_it() {
        let raw = r#"{
            "https://auth.x.ai::b1a00492": {
                "key": "token-a", "auth_mode": "oidc",
                "expires_at": "2026-08-05T09:26:42.270306Z",
                "refresh_token": "r", "email": "someone@example.com"
            }
        }"#;
        let accounts: StoredAccounts = serde_json::from_str(raw).unwrap();
        let account = accounts.0.into_values().next().unwrap();
        assert_eq!(account.key, "token-a");
        assert!(account.expires_at.is_some());
    }

    #[test]
    fn the_entry_that_lasts_longest_is_the_one_used() {
        // A machine signed in more than once holds several. Taking the first
        // would report an expired login while a usable one sat beside it.
        let raw = r#"{
            "a": {"key": "old", "expires_at": "2026-08-01T00:00:00Z"},
            "b": {"key": "new", "expires_at": "2026-09-01T00:00:00Z"}
        }"#;
        let accounts: StoredAccounts = serde_json::from_str(raw).unwrap();
        let best = accounts
            .0
            .into_values()
            .max_by_key(|a| a.expires_at.as_deref().and_then(parse_iso_ms).unwrap_or(0))
            .unwrap();
        assert_eq!(best.key, "new");
    }

    #[test]
    fn the_monthly_window_is_the_share_of_the_allowance_spent() {
        let config: BillingConfig = serde_json::from_str(
            r#"{"monthlyLimit": {"val": 15000}, "used": {"val": 4597},
                "billingPeriodEnd": "2026-09-01T00:00:00+00:00"}"#,
        )
        .unwrap();
        let window = monthly_window(&config).unwrap();
        assert_eq!(window.label, "monthly");
        assert!((window.percent - 30.646).abs() < 0.01);
        assert!(window.resets_at_ms.is_some());
        assert_eq!(window.severity, LimitSeverity::Normal);
    }

    #[test]
    fn an_account_with_no_monthly_allowance_reports_no_monthly_window() {
        // Dividing by it would be a percentage of nothing, which renders as
        // either 0% or infinity and means neither.
        let config: BillingConfig =
            serde_json::from_str(r#"{"monthlyLimit": {"val": 0}, "used": {"val": 12}}"#).unwrap();
        assert!(monthly_window(&config).is_none());
    }

    #[test]
    fn the_weekly_window_carries_the_vendors_own_percentage() {
        let config: BillingConfig = serde_json::from_str(
            r#"{"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY"},
                "creditUsagePercent": 99.0,
                "billingPeriodEnd": "2026-08-08T21:34:24.186519+00:00"}"#,
        )
        .unwrap();
        let window = weekly_window(&config).unwrap();
        assert_eq!(window.label, "weekly");
        assert_eq!(window.percent, 99.0);
        assert_eq!(window.severity, LimitSeverity::Critical);
    }

    #[test]
    fn a_fresh_period_without_a_percentage_is_nothing_used_rather_than_nothing_known() {
        let config: BillingConfig = serde_json::from_str(
            r#"{"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY"},
                "billingPeriodEnd": "2026-08-08T21:34:24Z"}"#,
        )
        .unwrap();
        assert_eq!(weekly_window(&config).unwrap().percent, 0.0);
    }

    #[test]
    fn a_period_that_is_not_weekly_is_not_reported_as_a_week() {
        let config: BillingConfig = serde_json::from_str(
            r#"{"currentPeriod": {"type": "USAGE_PERIOD_TYPE_MONTHLY"},
                "creditUsagePercent": 40.0}"#,
        )
        .unwrap();
        assert!(weekly_window(&config).is_none());
    }
}
