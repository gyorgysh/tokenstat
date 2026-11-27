// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Antigravity (Google) sync.
//!
//! Three layers, kept separate on purpose:
//!
//! 1. **CLI conversations** (`~/.gemini/antigravity-cli/conversations/*.db`) are
//!    parsed offline by `tokenstat-core` (protobuf `gen_metadata`).
//! 2. **IDE sessions** need a running language server. This crate discovers it,
//!    pulls generator metadata over Connect-RPC, and writes JSONL under the
//!    tokenstat data dir for core to ingest.
//! 3. **Cloud Code quota** (`remainingFraction` / `resetTime`) is plan status
//!    for doctor/fetch messaging when a token is already available. Never
//!    invents usage events.
//!
//! Plan limits prefer the running language server (no login of ours). When it
//! is closed, `agy -p /usage --output-format json` supplies the same groups
//! the interactive `/usage` command shows. agy holds the login; tokenstat only
//! parses the answer.

use std::fs;
use std::time::Duration;

use serde_json::Value;
use tokenstat_core::Store;
use tokenstat_core::limits::ProviderLimits;
use tokenstat_core::sources::antigravity_cache;

use crate::antigravity_ide;
use crate::creds::{self, TokenSource, cache_is_fresh, cache_path, token_with_source};
use crate::{FETCH_TTL, FetchReport, Vendor};

const LOAD_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
const MODELS_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels";
const META_QUOTA: &str = "antigravity.quota_json";
const CLI_TIMEOUT: Duration = Duration::from_secs(45);

/// One model's remaining plan quota.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelQuota {
    pub model: String,
    pub display_name: String,
    /// `None` when the vendor omitted remainingFraction (unavailable, not 100%).
    pub remaining_fraction: Option<f64>,
    pub reset_time: Option<String>,
    pub exhausted: bool,
}

/// Snapshot of Antigravity plan + per-model quotas.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct QuotaSnapshot {
    pub plan_type: Option<String>,
    pub available_prompt_credits: Option<i64>,
    pub monthly_prompt_credits: Option<i64>,
    pub models: Vec<ModelQuota>,
}

impl QuotaSnapshot {
    /// Short status line for fetch / doctor.
    pub fn summary_line(&self) -> String {
        let plan = self.plan_type.as_deref().unwrap_or("plan");
        let credits = match (self.available_prompt_credits, self.monthly_prompt_credits) {
            (Some(a), Some(m)) => format!(" · {a}/{m} prompt credits"),
            (Some(a), None) => format!(" · {a} prompt credits left"),
            _ => String::new(),
        };
        let mut parts: Vec<String> = self
            .models
            .iter()
            .filter(|m| m.exhausted || m.remaining_fraction.is_some_and(|f| f < 1.0))
            .take(4)
            .filter_map(|m| {
                let frac = m.remaining_fraction?;
                Some(format!("{} {:.0}%", short_model(&m.model), frac * 100.0))
            })
            .collect();
        if parts.is_empty() {
            parts = self
                .models
                .iter()
                .filter_map(|m| {
                    let frac = m.remaining_fraction?;
                    Some(format!("{} {:.0}%", short_model(&m.model), frac * 100.0))
                })
                .take(3)
                .collect();
        }
        if parts.is_empty() {
            format!("{plan}{credits} · no model quotas returned")
        } else {
            format!("{plan}{credits} · {}", parts.join(", "))
        }
    }
}

fn short_model(id: &str) -> &str {
    id.rsplit('/').next().unwrap_or(id)
}

/// Store an Antigravity / Google session token for later fetches.
pub fn auth(token: &str) -> anyhow::Result<std::path::PathBuf> {
    Ok(creds::save_token(Vendor::Antigravity, token)?)
}

pub fn auth_auto() -> anyhow::Result<(std::path::PathBuf, TokenSource)> {
    if crate::discover::local_token(Vendor::Antigravity).is_some() {
        // Live discovery only. Persisting would shadow a rotated keychain /
        // oauth_creds access token after expiry.
        let path = creds::session_path(Vendor::Antigravity)?;
        return Ok((path, TokenSource::Discovered));
    }
    anyhow::bail!(
        "no Antigravity token in the OS keychain or ~/.gemini/oauth_creds.json. \
         Sign in to the Antigravity app, or pass --token."
    )
}

pub fn logout() -> anyhow::Result<()> {
    creds::clear_token(Vendor::Antigravity)?;
    Ok(())
}

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

/// Sync IDE session cache (when the app is open), ingest cached events, and
/// refresh Cloud Code quota when a token is available.
pub fn fetch_into(
    store: &mut Store,
    tz: &jiff::tz::TimeZone,
    force: bool,
) -> anyhow::Result<FetchReport> {
    let mut parts: Vec<String> = Vec::new();
    let mut events = 0usize;
    let mut from_cache = false;
    let mut skipped_no_token = false;
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

    let ingested = ingest_ide_cache(store, tz)?;
    if ingested > 0 {
        events += ingested;
        parts.push(format!("{ingested} IDE usage events"));
    }

    match fetch_quota(store, force) {
        Ok(QuotaFetch {
            summary,
            from_cache: q_cache,
            skipped_no_token: no_tok,
        }) => {
            from_cache = from_cache && (q_cache || summary.is_none());
            skipped_no_token = no_tok;
            if let Some(s) = summary {
                parts.push(s);
            } else if no_tok {
                parts.push(
                    "no Antigravity token for quota. Sign in to the app, or: \
                     tokenstat auth antigravity --token <token>"
                        .into(),
                );
            }
        }
        Err(e) => {
            failed = true;
            parts.push(format!("quota fetch failed: {e}"));
        }
    }

    Ok(FetchReport {
        vendor: "antigravity",
        events,
        from_cache,
        skipped_no_token,
        failed,
        message: Some(parts.join(" · ")),
    })
}

struct QuotaFetch {
    summary: Option<String>,
    from_cache: bool,
    skipped_no_token: bool,
}

fn fetch_quota(store: &mut Store, force: bool) -> anyhow::Result<QuotaFetch> {
    let Some((token, source)) = resolve_token()? else {
        return Ok(QuotaFetch {
            summary: None,
            from_cache: false,
            skipped_no_token: true,
        });
    };

    let cache = cache_path(Vendor::Antigravity, "quota.json")?;
    let loaded = if !force && cache_is_fresh(&cache, FETCH_TTL) {
        fs::read_to_string(&cache)
            .ok()
            .and_then(|t| cached_quota(&t, &token).map(|s| (s, true)))
    } else {
        None
    };
    let (snapshot, from_cache) = match loaded {
        Some(v) => v,
        None => match download_quota_bundle(&token) {
            Ok(text) => match parse_quota_bundle(&text) {
                Ok(snap) => {
                    let mut cached: Value = serde_json::from_str(&text)?;
                    cached["credentialSha256"] = crate::snapshot::sha256(&token).into();
                    let _ = write_cache(&cache, &serde_json::to_string(&cached)?);
                    (snap, false)
                }
                Err(e) => {
                    return Ok(QuotaFetch {
                        summary: Some(format!("quota parse failed: {e}")),
                        from_cache: false,
                        skipped_no_token: false,
                    });
                }
            },
            Err(e) => {
                return Ok(QuotaFetch {
                    summary: Some(format!("quota fetch failed: {e}")),
                    from_cache: false,
                    skipped_no_token: false,
                });
            }
        },
    };

    store.set_meta(
        META_QUOTA,
        &serde_json::to_string(&snapshot_json(&snapshot))?,
    )?;

    let src = match source {
        TokenSource::Env => "env",
        TokenSource::Stored => "stored",
        TokenSource::Discovered => "local discover",
    };
    let origin = if from_cache { "cache" } else { "network" };
    Ok(QuotaFetch {
        summary: Some(format!(
            "quota via {src} ({origin}): {}",
            snapshot.summary_line()
        )),
        from_cache,
        skipped_no_token: false,
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

fn write_cache(path: &std::path::Path, text: &str) -> anyhow::Result<()> {
    crate::snapshot::write_private_atomically(path, text)
}

/// Latest quota snapshot stored in archive meta, if any.
pub fn stored_quota(store: &Store) -> Option<QuotaSnapshot> {
    let raw = store.meta(META_QUOTA).ok().flatten()?;
    serde_json::from_str::<Value>(&raw)
        .ok()
        .and_then(|v| parse_stored_meta(&v))
}

fn resolve_token() -> anyhow::Result<Option<(String, TokenSource)>> {
    if let Some(pair) = token_with_source(Vendor::Antigravity)? {
        return Ok(Some(pair));
    }
    Ok(None)
}

fn download_quota_bundle(access_token: &str) -> anyhow::Result<String> {
    let client = crate::http::client_builder()
        .timeout(std::time::Duration::from_secs(60))
        .connect_timeout(std::time::Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("antigravity")
        .build()?;

    let token = access_token.trim().to_string();

    let load_body = serde_json::json!({
        "metadata": {
            "ideType": "ANTIGRAVITY",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI"
        }
    });

    let load_resp = post_json(&client, LOAD_URL, &token, &load_body)?;
    if load_resp.status() == reqwest::StatusCode::UNAUTHORIZED
        || load_resp.status() == reqwest::StatusCode::FORBIDDEN
    {
        anyhow::bail!(
            "token rejected ({}). Sign in to the Antigravity app again.",
            load_resp.status()
        );
    }

    if !load_resp.status().is_success() {
        anyhow::bail!("Antigravity loadCodeAssist returned {}", load_resp.status());
    }
    let load_text = crate::profile::limited_text(load_resp)?;
    let load: Value = serde_json::from_str(&load_text)?;
    let project = load
        .get("cloudaicompanionProject")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            load.get("cloudaicompanionProject")
                .and_then(|v| v.get("id"))
                .and_then(Value::as_str)
                .map(str::to_string)
        });

    let models_body = match project {
        Some(p) => serde_json::json!({ "project": p }),
        None => serde_json::json!({}),
    };
    let models_resp = post_json(&client, MODELS_URL, &token, &models_body)?;
    if !models_resp.status().is_success() {
        anyhow::bail!(
            "Antigravity fetchAvailableModels returned {}",
            models_resp.status()
        );
    }
    let models_text = crate::profile::limited_text(models_resp)?;

    let bundle = serde_json::json!({
        "loadCodeAssist": serde_json::from_str::<Value>(&load_text)?,
        "fetchAvailableModels": serde_json::from_str::<Value>(&models_text)?,
    });
    Ok(serde_json::to_string(&bundle)?)
}

fn post_json(
    client: &reqwest::blocking::Client,
    url: &str,
    token: &str,
    body: &Value,
) -> anyhow::Result<reqwest::blocking::Response> {
    Ok(client
        .post(url)
        .bearer_auth(token)
        .header("Content-Type", "application/json")
        .header("User-Agent", "antigravity")
        .body(serde_json::to_vec(body)?)
        .send()?)
}

fn cached_quota(text: &str, token: &str) -> Option<QuotaSnapshot> {
    let value: Value = serde_json::from_str(text).ok()?;
    if value.get("credentialSha256")?.as_str()? != crate::snapshot::sha256(token) {
        return None;
    }
    parse_quota_bundle(text).ok()
}

pub fn parse_quota_bundle(text: &str) -> anyhow::Result<QuotaSnapshot> {
    let root: Value = serde_json::from_str(text)?;
    // Accept either the bundled shape or a bare fetchAvailableModels payload.
    let load = root.get("loadCodeAssist").cloned().unwrap_or(Value::Null);
    let models_root = root
        .get("fetchAvailableModels")
        .cloned()
        .unwrap_or_else(|| root.clone());
    if !models_root.get("models").is_some_and(Value::is_object) {
        anyhow::bail!("Antigravity did not return a model quota map");
    }
    Ok(parse_parts(&load, &models_root))
}

fn parse_parts(load: &Value, models_root: &Value) -> QuotaSnapshot {
    let plan_type = load
        .pointer("/planInfo/planType")
        .and_then(Value::as_str)
        .or_else(|| load.pointer("/currentTier/name").and_then(Value::as_str))
        .map(str::to_string);
    let available_prompt_credits = load.get("availablePromptCredits").and_then(Value::as_i64);
    let monthly_prompt_credits = load
        .pointer("/planInfo/monthlyPromptCredits")
        .and_then(Value::as_i64);

    let mut models = Vec::new();
    if let Some(map) = models_root.get("models").and_then(Value::as_object) {
        for (id, meta) in map {
            let quota = meta.get("quotaInfo").cloned().unwrap_or(Value::Null);
            let remaining = quota.get("remainingFraction").and_then(Value::as_f64);
            let exhausted = quota
                .get("isExhausted")
                .and_then(Value::as_bool)
                .unwrap_or_else(|| remaining.is_some_and(|f| f <= 0.0));
            let display_name = meta
                .get("displayName")
                .or_else(|| meta.get("label"))
                .and_then(Value::as_str)
                .unwrap_or(id)
                .to_string();
            let reset_time = quota
                .get("resetTime")
                .and_then(Value::as_str)
                .map(str::to_string);
            models.push(ModelQuota {
                model: id.clone(),
                display_name,
                remaining_fraction: remaining,
                reset_time,
                exhausted,
            });
        }
    }
    models.sort_by(|a, b| match (a.remaining_fraction, b.remaining_fraction) {
        (Some(x), Some(y)) => x
            .partial_cmp(&y)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.model.cmp(&b.model)),
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, None) => a.model.cmp(&b.model),
    });

    QuotaSnapshot {
        plan_type,
        available_prompt_credits,
        monthly_prompt_credits,
        models,
    }
}

fn snapshot_json(s: &QuotaSnapshot) -> Value {
    serde_json::json!({
        "plan_type": s.plan_type,
        "available_prompt_credits": s.available_prompt_credits,
        "monthly_prompt_credits": s.monthly_prompt_credits,
        "models": s.models.iter().map(|m| serde_json::json!({
            "model": m.model,
            "display_name": m.display_name,
            "remaining_fraction": m.remaining_fraction,
            "reset_time": m.reset_time,
            "exhausted": m.exhausted,
        })).collect::<Vec<_>>(),
    })
}

fn parse_stored_meta(v: &Value) -> Option<QuotaSnapshot> {
    let plan_type = v
        .get("plan_type")
        .and_then(Value::as_str)
        .map(str::to_string);
    let available_prompt_credits = v.get("available_prompt_credits").and_then(Value::as_i64);
    let monthly_prompt_credits = v.get("monthly_prompt_credits").and_then(Value::as_i64);
    let mut models = Vec::new();
    for m in v.get("models")?.as_array()? {
        models.push(ModelQuota {
            model: m.get("model")?.as_str()?.to_string(),
            display_name: m
                .get("display_name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            remaining_fraction: m.get("remaining_fraction").and_then(Value::as_f64),
            reset_time: m
                .get("reset_time")
                .and_then(Value::as_str)
                .map(str::to_string),
            exhausted: m.get("exhausted").and_then(Value::as_bool).unwrap_or(false),
        });
    }
    Some(QuotaSnapshot {
        plan_type,
        available_prompt_credits,
        monthly_prompt_credits,
        models,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
      "loadCodeAssist": {
        "planInfo": { "monthlyPromptCredits": 1000, "planType": "PRO" },
        "availablePromptCredits": 850,
        "currentTier": { "name": "Pro" }
      },
      "fetchAvailableModels": {
        "models": {
          "claude-sonnet-4-5": {
            "displayName": "Claude 4 Sonnet",
            "quotaInfo": {
              "remainingFraction": 0.85,
              "resetTime": "2026-01-26T12:00:00Z",
              "isExhausted": false
            }
          },
          "gemini-3-flash": {
            "displayName": "Gemini 3 Flash",
            "quotaInfo": {
              "remainingFraction": 1.0,
              "resetTime": "2026-01-26T14:00:00Z",
              "isExhausted": false
            }
          }
        }
      }
    }"#;

    #[test]
    fn parses_quota_bundle() {
        let s = parse_quota_bundle(SAMPLE).unwrap();
        assert_eq!(s.plan_type.as_deref(), Some("PRO"));
        assert_eq!(s.available_prompt_credits, Some(850));
        assert_eq!(s.monthly_prompt_credits, Some(1000));
        assert_eq!(s.models.len(), 2);
        assert!((s.models[0].remaining_fraction.unwrap() - 0.85).abs() < 1e-9);
        assert!(s.summary_line().contains("85%"));
    }

    #[test]
    fn parses_bare_models_payload() {
        let bare = r#"{
          "models": {
            "m1": {
              "label": "M1",
              "quotaInfo": { "remainingFraction": 0.2, "isExhausted": false }
            }
          }
        }"#;
        let s = parse_quota_bundle(bare).unwrap();
        assert_eq!(s.models.len(), 1);
        assert!((s.models[0].remaining_fraction.unwrap() - 0.2).abs() < 1e-9);
    }

    #[test]
    fn missing_remaining_fraction_is_unavailable_not_full() {
        let bare = r#"{
          "models": {
            "m1": {
              "label": "M1",
              "quotaInfo": { "isExhausted": false }
            }
          }
        }"#;
        let s = parse_quota_bundle(bare).unwrap();
        assert_eq!(s.models.len(), 1);
        assert!(s.models[0].remaining_fraction.is_none());
        assert!(!s.summary_line().contains("100%"));
    }
    #[test]
    fn a_quota_cache_belongs_to_one_credential() {
        let mut value: Value = serde_json::from_str(SAMPLE).unwrap();
        assert!(cached_quota(SAMPLE, "first").is_none());
        value["credentialSha256"] = crate::snapshot::sha256("first").into();
        let encoded = serde_json::to_string(&value).unwrap();
        assert!(cached_quota(&encoded, "first").is_some());
        assert!(cached_quota(&encoded, "second").is_none());
        assert!(parse_quota_bundle("null").is_err());
        assert!(parse_quota_bundle("{}").is_err());
    }

    #[test]
    fn cloud_summary_body_maps_like_the_ide_envelope() {
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
