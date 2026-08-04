//! OpenCode Go/Zen subscription quota.

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

/// Read OpenCode Go/Zen's vendor-reported dollar quota windows.
pub fn fetch() -> ProviderLimits {
    let Some(token) = auth_token() else {
        return ProviderLimits::unavailable(
            "opencode",
            "No OpenCode Go/Zen API key was found, so its limits cannot be read.",
        );
    };

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
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
            return local_limits();
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
    }
}

fn auth_token() -> Option<String> {
    if let Some(token) = std::env::var("PANTHEON_OPENCODE_API_KEY")
        .ok()
        .or_else(|| std::env::var("OPENCODE_API_KEY").ok())
        .filter(|token| !token.trim().is_empty())
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
                if let Some(token) = value.get(key).and_then(serde_json::Value::as_str) {
                    if !token.trim().is_empty() {
                        return Some(token.to_string());
                    }
                }
            }
        }
    }
    None
}

/// Estimate Go/Zen windows from OpenCode's local message costs when its public
/// quota endpoint is not available yet. The provider and limits are explicit,
/// while the missing reset timestamps stay unknown rather than invented.
fn local_limits() -> ProviderLimits {
    let Some(home) = directories::BaseDirs::new().map(|dirs| dirs.home_dir().to_path_buf()) else {
        return unavailable(
            "No home directory was found for OpenCode's local database.".to_string(),
        );
    };
    let path = [
        home.join(".local/share/opencode/opencode.db"),
        home.join("Library/Application Support/opencode/opencode.db"),
    ]
    .into_iter()
    .find(|path| path.is_file());
    let Some(path) = path else {
        return unavailable("OpenCode's local database was not found.".to_string());
    };
    let Ok(connection) = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return unavailable("OpenCode's local database could not be read.".to_string());
    };
    let Ok(mut statement) = connection.prepare(
        "SELECT time_created, data FROM message WHERE json_extract(data, '$.providerID') IN ('opencode-go', 'opencode')",
    ) else {
        return unavailable("OpenCode's local database has no readable message table.".to_string());
    };
    let now = now_ms();
    let mut totals = [0.0_f64; 3];
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
    });
    let Ok(rows) = rows else {
        return unavailable("OpenCode's local usage rows could not be read.".to_string());
    };
    for row in rows.flatten() {
        let (created, data) = row;
        let Ok(data) = serde_json::from_str::<serde_json::Value>(&data) else {
            continue;
        };
        let Some(cost) = data.get("cost").and_then(serde_json::Value::as_f64) else {
            continue;
        };
        if !cost.is_finite() || cost < 0.0 {
            continue;
        }
        let age = now.saturating_sub(created);
        if age <= 5 * 60 * 60 * 1000 {
            totals[0] += cost;
        }
        if age <= 7 * 24 * 60 * 60 * 1000 {
            totals[1] += cost;
        }
        if age <= 30 * 24 * 60 * 60 * 1000 {
            totals[2] += cost;
        }
    }
    let limits = [12.0, 30.0, 60.0];
    let labels = ["5-hour", "weekly", "monthly"];
    let windows = totals
        .into_iter()
        .zip(limits)
        .zip(labels)
        .map(|((used, limit), label)| {
            let percent = (used / limit * 100.0).clamp(0.0, 100.0);
            UsageWindow {
                label: label.to_string(),
                percent,
                resets_at_ms: None,
                severity: LimitSeverity::from_percent(percent),
            }
        })
        .collect();
    ProviderLimits {
        source: "opencode".to_string(),
        plan: Some("Go/Zen (local estimate)".to_string()),
        windows,
        observed_at_ms: now,
        note: None,
    }
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
    fn response_fields_match_the_opencode_endpoint() {
        let response: UsageResponse = serde_json::from_str(
            r#"{"rolling5h":{"usagePercent":42,"resetInSec":60},"weekly":{"usagePercent":12.5,"resetInSec":3600},"monthly":{"usagePercent":3,"resetInSec":7200}}"#,
        )
        .unwrap();
        assert_eq!(response.rolling5h.unwrap().usage_percent, Some(42.0));
        assert_eq!(response.weekly.unwrap().reset_in_sec, Some(3600));
    }
}
