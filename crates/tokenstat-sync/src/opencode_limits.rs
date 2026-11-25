// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! OpenCode Go/Zen subscription quota.
//!
//! Asked of OpenCode first: `opencode api --standalone GET
//! /api/experimental/usage/limits` answers from OpenCode's own login, on a
//! private server that exits with the call. A stored API key against the Go
//! usage endpoint is the fallback, for an OpenCode without that route or an
//! account it has no reading for.

use std::time::Duration;

use serde::Deserialize;
use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};

const USAGE_URL: &str = "https://opencode.ai/zen/go/v1/usage";

#[derive(Debug, Deserialize)]
struct UsageResponse {
    #[serde(default)]
    rolling5h: Option<UsageWindowResponse>,
    #[serde(default)]
    weekly: Option<UsageWindowResponse>,
    #[serde(default)]
    monthly: Option<UsageWindowResponse>,
}

#[derive(Debug, Deserialize)]
struct UsageWindowResponse {
    #[serde(rename = "usagePercent")]
    usage_percent: Option<f64>,
    #[serde(rename = "resetInSec")]
    reset_in_sec: Option<i64>,
}

/// Read OpenCode Go/Zen's vendor-reported quota windows.
pub fn fetch() -> ProviderLimits {
    if let Some(reading) = cli_usage() {
        return reading;
    }
    key_usage()
}

/// A cold start of OpenCode's private server plus one request.
const CLI_TIMEOUT: Duration = Duration::from_secs(20);
/// Where OpenCode's installer puts it, beside the shared defaults.
const OPENCODE_DIRS: &[&str] = &[".opencode/bin"];

fn cli_usage() -> Option<ProviderLimits> {
    let program = crate::vendor_cli::program("opencode", OPENCODE_DIRS)?;
    let raw = crate::vendor_cli::run(
        &program,
        &[
            "api",
            "--standalone",
            "GET",
            "/api/experimental/usage/limits",
        ],
        OPENCODE_DIRS,
        CLI_TIMEOUT,
    )?;
    cli_reading(&serde_json::from_str(raw.trim()).ok()?, now_ms())
}

/// The Go plan's three meters, from OpenCode's `UsageLimits.Info`. `data` is
/// null for an account OpenCode has no reading for, and that is not a
/// reading: the key path gets its turn.
fn cli_reading(value: &serde_json::Value, observed_at_ms: i64) -> Option<ProviderLimits> {
    let go = value.get("data")?.get("go")?;
    let windows = [
        ("5-hour", "rolling"),
        ("weekly", "weekly"),
        ("monthly", "monthly"),
    ]
    .into_iter()
    .filter_map(|(label, key)| {
        let meter = go.get(key)?;
        let percent = meter.get("percent")?.as_f64()?;
        if !percent.is_finite() || !(0.0..=100.0).contains(&percent) {
            return None;
        }
        Some(UsageWindow {
            label: label.to_string(),
            scope: None,
            percent,
            resets_at_ms: meter
                .get("resetsAt")
                .and_then(serde_json::Value::as_f64)
                .filter(|ms| ms.is_finite() && *ms > 0.0)
                .map(|ms| ms as i64),
            severity: LimitSeverity::from_percent(percent),
        })
    })
    .collect::<Vec<_>>();
    (!windows.is_empty()).then(|| ProviderLimits {
        source: "opencode".to_string(),
        plan: Some("Go".to_string()),
        windows,
        observed_at_ms,
        note: None,
        stale: false,
    })
}

/// The stored API key against OpenCode's Go usage endpoint.
fn key_usage() -> ProviderLimits {
    let Some(token) = auth_token() else {
        return ProviderLimits::unavailable(
            "opencode",
            "No OpenCode Go/Zen API key was found, so its limits cannot be read.",
        );
    };

    let client = match crate::http::client_builder()
        .timeout(Duration::from_secs(15))
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            return unavailable(format!("Could not prepare the OpenCode request: {error}"));
        }
    };
    let response = match client.get(USAGE_URL).bearer_auth(token).send() {
        Ok(response) => response,
        Err(error) => return unavailable(format!("Could not reach OpenCode: {error}")),
    };
    if !response.status().is_success() {
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            // No quota endpoint for this account yet. There was an estimate
            // here, built from local message costs against dollar ceilings
            // written down in this file. Those ceilings were a guess, so every
            // percentage it drew was a guess wearing a real number's clothes.
            // Saying nothing is the honest answer until OpenCode reports one.
            return unavailable("OpenCode does not report quota for this account yet.".to_string());
        }
        return unavailable(format!(
            "OpenCode returned {} for its usage endpoint.",
            response.status()
        ));
    }

    let usage: UsageResponse = match response.json() {
        Ok(usage) => usage,
        Err(error) => {
            return unavailable(format!("Could not read OpenCode's usage answer: {error}"));
        }
    };
    let observed_at_ms = now_ms();
    let windows = [
        ("5-hour", usage.rolling5h),
        ("weekly", usage.weekly),
        ("monthly", usage.monthly),
    ]
    .into_iter()
    .filter_map(|(label, window)| {
        let window = window?;
        let percent = window.usage_percent?;
        if !percent.is_finite() || !(0.0..=100.0).contains(&percent) {
            return None;
        }
        Some(UsageWindow {
            label: label.to_string(),
            scope: None,
            percent,
            resets_at_ms: window
                .reset_in_sec
                .map(|seconds| observed_at_ms.saturating_add(seconds.saturating_mul(1000))),
            severity: LimitSeverity::from_percent(percent),
        })
    })
    .collect::<Vec<_>>();

    if windows.is_empty() {
        return unavailable("OpenCode reported no usage windows for this account.".to_string());
    }
    ProviderLimits {
        source: "opencode".to_string(),
        plan: Some("Go/Zen".to_string()),
        windows,
        observed_at_ms,
        note: None,
        stale: false,
    }
}

fn auth_token() -> Option<String> {
    if let Some(token) = std::env::var("PANTHEON_OPENCODE_API_KEY")
        .ok()
        .filter(|token| !token.trim().is_empty())
        .or_else(|| {
            std::env::var("OPENCODE_API_KEY")
                .ok()
                .filter(|token| !token.trim().is_empty())
        })
    {
        return Some(token);
    }

    let home = directories::BaseDirs::new()?.home_dir().to_path_buf();
    for path in [
        home.join(".local/share/opencode/auth.json"),
        home.join("Library/Application Support/opencode/auth.json"),
    ] {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let Ok(root) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        for provider in ["opencode-go", "opencode"] {
            let Some(value) = root.get(provider) else {
                continue;
            };
            for key in ["key", "token", "apiKey"] {
                if let Some(token) = value.get(key).and_then(serde_json::Value::as_str)
                    && !token.trim().is_empty()
                {
                    return Some(token.to_string());
                }
            }
        }
    }
    None
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn unavailable(note: String) -> ProviderLimits {
    ProviderLimits::unavailable("opencode", note)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cli_answer_reads_the_go_meters_and_a_null_is_no_reading() {
        let answer = serde_json::json!({"location": {"directory": "/home"}, "data": {
            "workspace": {"id": "w", "usageURL": "u"}, "budgets": [],
            "go": {
                "rolling": {"percent": 42, "limited": false, "resetsAt": 1_800_000_000_000_i64},
                "weekly": {"percent": 12.5, "limited": false, "resetsAt": 1_800_000_100_000_i64},
                "monthly": {"percent": 140, "limited": true, "resetsAt": 1_800_000_200_000_i64}
            }
        }});
        let reading = cli_reading(&answer, 7).unwrap();
        assert_eq!(reading.source, "opencode");
        assert_eq!(reading.observed_at_ms, 7);
        // An impossible figure is dropped, not clamped.
        assert_eq!(
            reading
                .windows
                .iter()
                .map(|w| (w.label.as_str(), w.percent))
                .collect::<Vec<_>>(),
            [("5-hour", 42.0), ("weekly", 12.5)]
        );
        assert_eq!(reading.windows[0].resets_at_ms, Some(1_800_000_000_000));
        assert!(cli_reading(&serde_json::json!({"location": {}, "data": null}), 7).is_none());
        let no_go = serde_json::json!({"data": {"workspace": {}, "budgets": []}});
        assert!(cli_reading(&no_go, 7).is_none());
    }

    #[test]
    fn response_fields_match_the_opencode_endpoint() {
        let response: UsageResponse = serde_json::from_str(
            r#"{"rolling5h":{"usagePercent":42,"resetInSec":60},"weekly":{"usagePercent":12.5,"resetInSec":3600},"monthly":{"usagePercent":3,"resetInSec":7200}}"#,
        )
        .unwrap();
        assert_eq!(response.rolling5h.unwrap().usage_percent, Some(42.0));
        assert_eq!(response.weekly.unwrap().reset_in_sec, Some(3600));
    }
}
