// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Claude plan limits as Claude Code itself reports them.
//!
//! Claude Code knows the account's limits without anybody asking, because
//! every reply from Anthropic carries them. It hands them out two ways that
//! need neither its login nor a request of ours:
//!
//! - the status line command receives `rate_limits` after each reply, and
//! - the SDK `get_usage` control request answers with the full usage report,
//!   fetched by Claude Code with its own credentials.
//!
//! This module turns both shapes into a [`ProviderLimits`], and keeps the
//! latest status line reading on disk so the host can use it. Reading another
//! tool's login is what made the older path fragile: a renewed login, a
//! changed Keychain item or a rate limited endpoint all left the panel stale.
//! Here the tool that owns the login does the asking.
//!
//! Percentages and reset times only. The status line payload also holds the
//! working directory, the transcript path and the model, and none of that is
//! kept.

use std::path::PathBuf;

use serde_json::Value;

use crate::limits::{LimitSeverity, ProviderLimits, UsageWindow};

/// Source id shared with every other Claude Code reading.
pub const SOURCE: &str = "claude_code";

/// A status line reading this recent is used as it is, without asking
/// Claude Code again. It is pushed after every reply, so during work it is
/// never older than the last message.
pub const LIVE_FOR_MS: i64 = 90_000;

/// A status line reading older than this is shown as remembered rather than
/// current. Usage only moves while something is using the plan, so a reading
/// from a few minutes ago is still the true one on an idle machine, but it
/// says nothing about the claude.ai apps that share the same limits.
pub const CURRENT_FOR_MS: i64 = 10 * 60_000;

fn window(label: &str, scope: Option<String>, percent: f64, resets: Option<i64>) -> UsageWindow {
    let percent = percent.clamp(0.0, 100.0);
    UsageWindow {
        label: label.to_string(),
        scope,
        percent,
        resets_at_ms: resets,
        severity: LimitSeverity::from_percent(percent),
    }
}

/// Seconds or milliseconds since the epoch, or an ISO 8601 instant. Claude
/// Code sends epoch seconds to the status line and ISO strings from
/// `get_usage`.
fn instant_ms(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => {
            let n = n.as_f64()?;
            if !n.is_finite() || n <= 0.0 {
                return None;
            }
            let ms = if n > 1e12 { n } else { n * 1000.0 };
            Some(ms as i64)
        }
        Value::String(s) => s
            .parse::<jiff::Timestamp>()
            .ok()
            .map(|t| t.as_millisecond()),
        _ => None,
    }
}

fn percent_of(value: Option<&Value>) -> Option<f64> {
    value?.as_f64().filter(|p| p.is_finite())
}

/// Plan names as people write them: `pro` becomes `Pro`.
fn plan_name(raw: Option<&Value>) -> Option<String> {
    let raw = raw?.as_str()?.trim();
    let mut chars = raw.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().chain(chars).collect())
}

/// The answer to Claude Code's `get_usage` control request.
///
/// `limits` is the server's own list of meters and is preferred: it carries
/// the per-model weekly windows in the order the server shows them. The older
/// `five_hour` / `seven_day` pair is the fallback for a Claude Code that does
/// not send it yet.
pub fn from_get_usage(response: &Value, now_ms: i64) -> ProviderLimits {
    let plan = plan_name(response.get("subscription_type"));
    let Some(limits) = response.get("rate_limits").filter(|v| v.is_object()) else {
        let note = if response.get("rate_limits_available") == Some(&Value::Bool(false)) {
            "Claude Code is not signed in with a Claude plan, so there are no plan limits to show."
        } else {
            "Claude Code could not read the plan usage just now."
        };
        return ProviderLimits {
            plan,
            ..ProviderLimits::unavailable(SOURCE, note)
        };
    };

    let mut windows = Vec::new();
    if let Some(meters) = limits.get("limits").and_then(Value::as_array) {
        for meter in meters {
            let Some(percent) = percent_of(meter.get("percent")) else {
                continue;
            };
            let resets = instant_ms(meter.get("resets_at"));
            let model = meter
                .pointer("/scope/model/display_name")
                .or_else(|| meter.pointer("/scope/surface/display_name"))
                .and_then(Value::as_str)
                .map(str::to_string);
            match meter.get("kind").and_then(Value::as_str) {
                Some("session") => windows.push(window("5-hour", None, percent, resets)),
                Some("weekly_all") => windows.push(window("weekly", None, percent, resets)),
                Some("weekly_scoped") if model.is_some() => {
                    windows.push(window("weekly", model, percent, resets))
                }
                _ => {}
            }
        }
    }
    if windows.is_empty() {
        for (key, label) in [("five_hour", "5-hour"), ("seven_day", "weekly")] {
            let entry = limits.get(key);
            if let Some(percent) = percent_of(entry.and_then(|e| e.get("utilization"))) {
                let resets = instant_ms(entry.and_then(|e| e.get("resets_at")));
                windows.push(window(label, None, percent, resets));
            }
        }
    }
    if windows.is_empty() {
        return ProviderLimits {
            plan,
            ..ProviderLimits::unavailable(
                SOURCE,
                "Claude Code reported no usage windows for this account.",
            )
        };
    }
    ProviderLimits {
        source: SOURCE.to_string(),
        plan,
        windows,
        observed_at_ms: now_ms,
        note: None,
        stale: false,
    }
}

/// The JSON Claude Code pipes into a status line command. `None` when it
/// carries no limits, which is normal before the first reply of a session
/// and for API key sign-ins.
pub fn from_status_line(payload: &Value, now_ms: i64) -> Option<ProviderLimits> {
    let limits = payload.get("rate_limits")?;
    let mut windows = Vec::new();
    for (key, label) in [("five_hour", "5-hour"), ("seven_day", "weekly")] {
        let entry = limits.get(key);
        if let Some(percent) = percent_of(entry.and_then(|e| e.get("used_percentage"))) {
            let resets = instant_ms(entry.and_then(|e| e.get("resets_at")));
            windows.push(window(label, None, percent, resets));
        }
    }
    if windows.is_empty() {
        return None;
    }
    Some(ProviderLimits {
        source: SOURCE.to_string(),
        plan: None,
        windows,
        observed_at_ms: now_ms,
        note: None,
        stale: false,
    })
}

/// The short line printed back to Claude Code when no other status line was
/// set up before, so the person sees the same numbers in the terminal.
pub fn status_line_text(reading: &ProviderLimits) -> String {
    reading
        .windows
        .iter()
        .filter(|w| w.scope.is_none())
        .map(|w| {
            let label = if w.label == "5-hour" { "5h" } else { "week" };
            format!("{label} {:.0}%", w.percent)
        })
        .collect::<Vec<_>>()
        .join(" · ")
}

/// The latest status line reading, kept between Claude Code's calls and the
/// host's limits pass.
pub mod live {
    use super::*;

    fn path() -> Option<PathBuf> {
        Some(tokenstat_paths::data_dir()?.join("claude-live-limits.json"))
    }

    /// The remembered reading, if there is one.
    pub fn load() -> Option<ProviderLimits> {
        let raw = std::fs::read_to_string(path()?).ok()?;
        serde_json::from_str::<ProviderLimits>(&raw)
            .ok()
            .filter(ProviderLimits::has_reading)
    }

    /// Replace the remembered reading. Claude Code calls the status line
    /// several times a second while it draws, so an unchanged reading is only
    /// rewritten once its timestamp has moved on by a while. The write is
    /// atomic, so a reader never sees half a file.
    pub fn store(reading: &ProviderLimits) -> std::io::Result<()> {
        let Some(path) = path() else {
            return Ok(());
        };
        if let Some(old) = load()
            && same_numbers(&old, reading)
            && reading.observed_at_ms.saturating_sub(old.observed_at_ms) < 15_000
        {
            return Ok(());
        }
        let parent = path
            .parent()
            .ok_or_else(|| std::io::Error::other("no data directory"))?;
        std::fs::create_dir_all(parent)?;
        let json = serde_json::to_string(reading).map_err(std::io::Error::other)?;
        // Several Claude Code sessions can draw at once, so each writer gets
        // its own staging name and the rename decides who was last.
        let staging = parent.join(format!(
            ".claude-live-limits.{}.{}.tmp",
            std::process::id(),
            reading.observed_at_ms
        ));
        std::fs::write(&staging, json.as_bytes())?;
        std::fs::rename(&staging, &path).inspect_err(|_| {
            let _ = std::fs::remove_file(&staging);
        })
    }

    fn same_numbers(a: &ProviderLimits, b: &ProviderLimits) -> bool {
        a.windows.len() == b.windows.len()
            && a.windows.iter().zip(&b.windows).all(|(x, y)| {
                x.label == y.label
                    && x.scope == y.scope
                    && x.percent == y.percent
                    && x.resets_at_ms == y.resets_at_ms
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn get_usage_prefers_the_server_meter_list_and_keeps_model_windows() {
        let response = json!({
            "subscription_type": "pro",
            "rate_limits_available": true,
            "rate_limits": {
                "five_hour": {"utilization": 44, "resets_at": "2026-11-10T09:20:00.082007+00:00"},
                "seven_day": {"utilization": 9, "resets_at": "2026-11-16T06:00:00+00:00"},
                "limits": [
                    {"kind": "session", "group": "session", "percent": 44,
                     "resets_at": "2026-11-10T09:20:00.082007+00:00", "scope": null},
                    {"kind": "weekly_all", "group": "weekly", "percent": 9,
                     "resets_at": "2026-11-16T06:00:00+00:00", "scope": null},
                    {"kind": "weekly_scoped", "group": "weekly", "percent": 0,
                     "resets_at": "2026-11-16T06:00:00+00:00",
                     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}},
                    {"kind": "something_new", "percent": 50}
                ]
            }
        });
        let reading = from_get_usage(&response, 7);
        assert_eq!(reading.plan.as_deref(), Some("Pro"));
        assert_eq!(reading.observed_at_ms, 7);
        let shown: Vec<_> = reading
            .windows
            .iter()
            .map(|w| (w.label.as_str(), w.scope.as_deref(), w.percent))
            .collect();
        assert_eq!(
            shown,
            vec![
                ("5-hour", None, 44.0),
                ("weekly", None, 9.0),
                ("weekly", Some("Fable"), 0.0)
            ]
        );
        assert_eq!(reading.windows[1].resets_at_ms, Some(1_794_808_800_000));
    }

    #[test]
    fn get_usage_falls_back_to_the_window_pair() {
        let response = json!({"rate_limits": {
            "five_hour": {"utilization": 97, "resets_at": "2026-11-10T09:20:00Z"},
            "seven_day": null
        }});
        let reading = from_get_usage(&response, 1);
        assert_eq!(reading.windows.len(), 1);
        assert_eq!(reading.windows[0].severity, LimitSeverity::Critical);
    }

    #[test]
    fn get_usage_without_limits_is_words_not_zero() {
        let reading = from_get_usage(
            &json!({"rate_limits_available": false, "rate_limits": null}),
            1,
        );
        assert!(!reading.has_reading());
        assert!(reading.note.unwrap().contains("not signed in"));
        let reading = from_get_usage(&json!({"rate_limits": null}), 1);
        assert!(reading.note.is_some());
    }

    #[test]
    fn status_line_reads_epoch_seconds_and_ignores_everything_else() {
        let payload = json!({
            "cwd": "/somewhere/private",
            "transcript_path": "/somewhere/private.jsonl",
            "rate_limits": {
                "five_hour": {"used_percentage": 23.5, "resets_at": 1_794_302_400},
                "seven_day": {"used_percentage": 41}
            }
        });
        let reading = from_status_line(&payload, 5).unwrap();
        assert_eq!(reading.windows[0].percent, 23.5);
        assert_eq!(reading.windows[0].resets_at_ms, Some(1_794_302_400_000));
        assert_eq!(reading.windows[1].resets_at_ms, None);
        let json = serde_json::to_string(&reading).unwrap();
        assert!(!json.contains("private"));
        assert_eq!(status_line_text(&reading), "5h 24% · week 41%");
    }

    #[test]
    fn status_line_without_limits_is_no_reading() {
        assert!(from_status_line(&json!({"model": {"id": "x"}}), 1).is_none());
        assert!(from_status_line(&json!({"rate_limits": {}}), 1).is_none());
    }
}
