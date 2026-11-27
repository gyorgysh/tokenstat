// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Antigravity (Google) sync.
//!
//! Everything here is local. tokenstat holds no Antigravity credential and
//! makes no request to Google.
//!
//! 1. **CLI conversations** (`~/.gemini/antigravity-cli/conversations/*.db`) are
//!    parsed offline by `tokenstat-core` (protobuf `gen_metadata`).
//! 2. **IDE sessions** need a running language server. This crate discovers it
//!    on loopback, pulls generator metadata over Connect-RPC, and writes JSONL
//!    under the tokenstat data dir for core to ingest.
//! 3. **Plan limits** come from the running language server, or else from
//!    `agy -p /usage --output-format json`, the same groups the interactive
//!    `/usage` command shows. agy holds the login, tokenstat only parses the
//!    answer.

use std::fs;
use std::time::Duration;

use serde_json::Value;
use tokenstat_core::Store;
use tokenstat_core::limits::ProviderLimits;
use tokenstat_core::sources::antigravity_cache;

use crate::FetchReport;
use crate::antigravity_ide;

const CLI_TIMEOUT: Duration = Duration::from_secs(45);

/// Plan limits for Home: running IDE first, then `agy /usage`.
///
/// The language server needs no credential from us. The CLI path lets agy
/// use its own login and returns the same group windows `/usage` shows.
pub fn limits() -> ProviderLimits {
    let ide = antigravity_ide::limits();
    if ide.has_reading() {
        return ide;
    }
    if let Some(cli) = cli_usage() {
        return cli;
    }
    ide
}

fn cli_usage() -> Option<ProviderLimits> {
    let program = crate::vendor_cli::program("agy", AGY_DIRS)?;
    let raw = crate::vendor_cli::run(
        &program,
        &[
            "-p",
            "/usage",
            "--output-format",
            "json",
            "--print-timeout",
            "30s",
        ],
        AGY_DIRS,
        CLI_TIMEOUT,
    )?;
    let value: Value = serde_json::from_str(raw.trim()).ok()?;
    cli_usage_reading(&value)
}

/// Where agy's Windows installer puts it, beside the shared defaults.
#[cfg(windows)]
const AGY_DIRS: &[&str] = &["AppData/Local/Programs/agy"];
#[cfg(not(windows))]
const AGY_DIRS: &[&str] = &[];

fn cli_usage_reading(value: &Value) -> Option<ProviderLimits> {
    if value.get("status").and_then(Value::as_str) != Some("SUCCESS") {
        return None;
    }
    let command = value.get("command")?;
    if command.get("name").and_then(Value::as_str) != Some("usage") {
        return None;
    }
    let data = command.get("data").unwrap_or(command);
    let windows = antigravity_ide::quota_summary_windows(data);
    if windows.is_empty() {
        return None;
    }
    Some(ProviderLimits {
        profile_id: None,
        source: "antigravity".into(),
        plan: None,
        windows,
        observed_at_ms: jiff::Timestamp::now().as_millisecond(),
        note: None,
        stale: false,
    })
}

/// Sync the IDE session cache (when the app is open) and ingest cached events.
pub fn fetch_into(
    store: &mut Store,
    tz: &jiff::tz::TimeZone,
    force: bool,
) -> anyhow::Result<FetchReport> {
    let mut parts: Vec<String> = Vec::new();
    let mut from_cache = false;
    let mut failed = false;

    match antigravity_ide::sync_sessions(force) {
        Ok(ide) => {
            from_cache = ide.from_cache;
            parts.push(ide.message);
        }
        Err(e) => {
            failed = true;
            parts.push(format!("IDE sync failed: {e}"));
        }
    }

    let events = ingest_ide_cache(store, tz)?;
    if events > 0 {
        parts.push(format!("{events} IDE usage events"));
    }

    Ok(FetchReport {
        vendor: "antigravity",
        events,
        from_cache,
        skipped_no_token: false,
        failed,
        message: Some(parts.join(" · ")),
    })
}

fn ingest_ide_cache(store: &mut Store, tz: &jiff::tz::TimeZone) -> anyhow::Result<usize> {
    let Some(root) = antigravity_cache::discover() else {
        return Ok(0);
    };
    let mut events = Vec::new();
    for path in antigravity_cache::shards(&root) {
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let parsed = antigravity_cache::parse_file(&path, &text);
        events.extend(parsed.events);
    }
    if events.is_empty() {
        return Ok(0);
    }
    let n = events.len();
    store.insert_events(&events, tz)?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_summary_body_maps_like_the_ide_envelope() {
        let bare = serde_json::json!({"groups": [
            {"displayName": "Gemini Models", "buckets": [
                {"window": "weekly", "remainingFraction": 0.5, "resetTime": "2026-11-30T01:00:00Z"},
                {"window": "5h", "remainingFraction": 0.97, "resetTime": "2026-11-25T23:30:00Z"}
            ]}
        ]});
        let windows = antigravity_ide::quota_summary_windows(&bare);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "Gemini Models · weekly");
        assert_eq!(windows[0].percent, 50.0);
        assert_eq!(windows[1].label, "Gemini Models · 5-hour");
        assert!((windows[1].percent - 3.0).abs() < 1e-9);
    }

    #[test]
    fn agy_usage_json_maps_group_windows() {
        let raw = serde_json::json!({
            "status": "SUCCESS",
            "command": {
                "name": "usage",
                "data": {
                    "groups": [{
                        "name": "Gemini Models",
                        "buckets": [
                            {"window": "weekly", "remaining_fraction": 0.5, "reset_time": "2026-11-30T01:00:00Z"},
                            {"window": "5h", "remaining_fraction": 0.97, "reset_time": "2026-11-25T23:30:00Z"}
                        ]
                    }]
                }
            }
        });
        let limits = cli_usage_reading(&raw).unwrap();
        assert_eq!(limits.windows.len(), 2);
        assert_eq!(limits.windows[0].label, "Gemini Models · weekly");
        assert_eq!(limits.windows[0].percent, 50.0);
        assert_eq!(limits.windows[1].label, "Gemini Models · 5-hour");
        assert!((limits.windows[1].percent - 3.0).abs() < 1e-9);
    }

    #[test]
    #[ignore = "requires an installed, signed-in agy or Antigravity app"]
    fn installed_agy_or_ide_limits_report_windows() {
        let limits = limits();
        eprintln!(
            "plan={:?} note={:?} windows={}",
            limits.plan,
            limits.note,
            limits.windows.len()
        );
        for window in &limits.windows {
            eprintln!(
                "  {} {:.1}% resets={:?}",
                window.label, window.percent, window.resets_at_ms
            );
        }
        assert!(limits.has_reading(), "{:?}", limits.note);
    }
}
