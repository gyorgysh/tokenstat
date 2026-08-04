//! What Claude Code's own account says is left of the plan.
//!
//! Here rather than in `tokenstat-core` because it makes a request. Codex
//! writes its limits into its session log so core can read them off the disk;
//! Anthropic does not, so the numbers have to be asked for.
//!
//! **The token is the one Claude Code already stored on this machine.** It is
//! read, used against Anthropic's own API, and dropped. It is never written
//! into the archive, never included in a sync payload, and never sent anywhere
//! except to the vendor it belongs to. That is the same rule the Cursor and
//! Antigravity credential discovery follows and it is not negotiable.

use std::time::Duration;

use serde::Deserialize;
use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};

/// Anthropic's OAuth API wants this on every call, and returns 401 without it.
const OAUTH_BETA: &str = "oauth-2025-04-20";
const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";

#[derive(Debug, Deserialize)]
struct StoredCredentials {
    #[serde(rename = "claudeAiOauth")]
    claude_ai_oauth: Option<OauthToken>,
}

#[derive(Debug, Deserialize)]
struct OauthToken {
    #[serde(rename = "accessToken")]
    access_token: String,
    /// Unix milliseconds.
    #[serde(rename = "expiresAt", default)]
    expires_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct UsageResponse {
    #[serde(default)]
    five_hour: Option<UsageWindowDto>,
    #[serde(default)]
    seven_day: Option<UsageWindowDto>,
}

#[derive(Debug, Deserialize)]
struct UsageWindowDto {
    /// Percent used, 0 to 100.
    #[serde(default)]
    utilization: Option<f64>,
    /// ISO 8601, and Anthropic writes microseconds with a `+00:00` offset
    /// rather than a `Z`, so this must not be parsed as RFC 3339 millis only.
    #[serde(default)]
    resets_at: Option<String>,
}

/// Read the limits for the Claude Code account signed in on this machine.
///
/// Never returns an error: a missing login, an expired token or an unreachable
/// API are all "we cannot say", and this ends up on a dashboard next to numbers
/// that are known. Saying so in words is the honest answer, and reporting zero
/// would be a lie about someone's remaining quota.
pub fn fetch() -> ProviderLimits {
    let token = match stored_token() {
        Some(t) => t,
        None => {
            return ProviderLimits::unavailable(
                "claude_code",
                "Not signed in to Claude Code on this machine, so its limits cannot be read.",
            );
        }
    };

    if token
        .expires_at
        .is_some_and(|ms| ms <= now_ms().saturating_add(60_000))
    {
        // Refreshing is Claude Code's own job and it holds the refresh token.
        // Doing it here would mean writing to another tool's credential store.
        return ProviderLimits::unavailable(
            "claude_code",
            "The stored Claude Code login has expired. Run any `claude` command to refresh it.",
        );
    }

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
    {
        Ok(c) => c,
        Err(e) => return ProviderLimits::unavailable("claude_code", e.to_string()),
    };

    let response = client
        .get(USAGE_URL)
        .bearer_auth(&token.access_token)
        .header("anthropic-beta", OAUTH_BETA)
        .header("content-type", "application/json")
        .send();

    let response = match response {
        Ok(r) => r,
        Err(e) => {
            return ProviderLimits::unavailable(
                "claude_code",
                format!("Could not reach Anthropic: {e}"),
            );
        }
    };

    if !response.status().is_success() {
        let status = response.status();
        let hint = if status == reqwest::StatusCode::UNAUTHORIZED {
            "The stored Claude Code login was refused. Run any `claude` command to refresh it."
                .to_string()
        } else if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            "Anthropic is rate limiting the usage endpoint. Try again shortly.".to_string()
        } else {
            format!("Anthropic returned {status} for the usage endpoint.")
        };
        return ProviderLimits::unavailable("claude_code", hint);
    }

    let usage: UsageResponse = match response.json() {
        Ok(u) => u,
        Err(e) => {
            return ProviderLimits::unavailable(
                "claude_code",
                format!("Could not read Anthropic's answer: {e}"),
            );
        }
    };

    let windows: Vec<UsageWindow> = [("5-hour", usage.five_hour), ("weekly", usage.seven_day)]
        .into_iter()
        .filter_map(|(label, dto)| {
            let dto = dto?;
            let percent = dto.utilization?;
            Some(UsageWindow {
                label: label.to_string(),
                percent,
                resets_at_ms: dto.resets_at.as_deref().and_then(parse_iso_ms),
                severity: LimitSeverity::from_percent(percent),
            })
        })
        .collect();

    if windows.is_empty() {
        return ProviderLimits::unavailable(
            "claude_code",
            "Anthropic reported no usage windows for this account.",
        );
    }

    ProviderLimits {
        source: "claude_code".to_string(),
        plan: None,
        windows,
        observed_at_ms: now_ms(),
        note: None,
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Anthropic writes `2026-07-27T15:19:59.625679+00:00`: microseconds, and an
/// offset rather than a `Z`.
fn parse_iso_ms(raw: &str) -> Option<i64> {
    raw.parse::<jiff::Timestamp>()
        .ok()
        .map(|t| t.as_millisecond())
}

/// The credentials Claude Code stored, from wherever it put them.
///
/// The Keychain first, because that is where it puts them on a Mac, then the
/// file it falls back to. Read only: nothing here writes to either.
fn stored_token() -> Option<OauthToken> {
    let raw = keychain_blob().or_else(credentials_file)?;
    serde_json::from_str::<StoredCredentials>(&raw)
        .ok()?
        .claude_ai_oauth
}

#[cfg(target_os = "macos")]
fn keychain_blob() -> Option<String> {
    let account = std::env::var("USER").ok()?;
    let out = std::process::Command::new("security")
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a"])
        .arg(&account)
        .arg("-w")
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(not(target_os = "macos"))]
fn keychain_blob() -> Option<String> {
    None
}

fn credentials_file() -> Option<String> {
    let home = directories::UserDirs::new()?.home_dir().to_path_buf();
    std::fs::read_to_string(home.join(".claude/.credentials.json")).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_credential_blob_parses_the_way_claude_code_writes_it() {
        let raw = r#"{"claudeAiOauth":{"accessToken":"sk-test","refreshToken":"r","expiresAt":1785180175976,"subscriptionType":"max"}}"#;
        let creds: StoredCredentials = serde_json::from_str(raw).unwrap();
        let token = creds.claude_ai_oauth.unwrap();
        assert_eq!(token.access_token, "sk-test");
        assert_eq!(token.expires_at, Some(1785180175976));
    }

    #[test]
    fn a_blob_without_an_oauth_section_is_not_a_login() {
        let creds: StoredCredentials = serde_json::from_str(r#"{"somethingElse":{}}"#).unwrap();
        assert!(creds.claude_ai_oauth.is_none());
    }

    #[test]
    fn the_usage_shape_parses_with_anthropics_own_timestamps() {
        // Microseconds and a `+00:00` offset, which is what the API actually
        // sends. Parsing this as plain RFC 3339 millis drops the reset time and
        // every window renders as "resets: unknown".
        let raw = r#"{
            "five_hour": {"utilization": 84.0, "resets_at": "2026-07-27T15:19:59.625679+00:00",
                          "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
            "seven_day": {"utilization": 17.0, "resets_at": "2026-08-03T05:59:59.625701+00:00"}
        }"#;
        let usage: UsageResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(usage.five_hour.as_ref().unwrap().utilization, Some(84.0));

        let ms = parse_iso_ms(usage.five_hour.unwrap().resets_at.as_deref().unwrap()).unwrap();
        assert_eq!(ms, 1785165599625);
        assert_eq!(
            LimitSeverity::from_percent(84.0),
            LimitSeverity::Warning,
            "84% of a five hour window is worth a warning"
        );
    }

    #[test]
    fn a_missing_login_is_words_and_not_a_zero() {
        let out = ProviderLimits::unavailable("claude_code", "not signed in");
        assert!(out.windows.is_empty());
        assert!(out.note.is_some());
    }
}
