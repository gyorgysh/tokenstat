//! Cursor remote usage fetch.
//!
//! Preferred path: the newest unexpired Bearer JWT on this machine, from the
//! Cursor app's own state database or the keychain item `cursor-agent login`
//! writes (see `discover`), calling
//! `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents`.
//!
//! Fallback: pasted `WorkosCursorSessionToken` against the dashboard CSV export.
//! Tokens stay on this machine. They are never written into the archive.

use std::fs;

use serde::Deserialize;
use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};
use tokenstat_core::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Store, Timestamp, UsageEvent,
};

use crate::creds::{self, CursorToken, TokenSource, cache_is_fresh, cache_path};
use crate::{FETCH_TTL, FetchReport, Vendor};

const CSV_URL: &str = "https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens";
const PERIOD_USAGE_URL: &str =
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
const PLAN_INFO_URL: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo";
const EVENTS_URL: &str =
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents";

/// Store a Cursor session token for later fetches.
pub fn auth(token: &str) -> anyhow::Result<std::path::PathBuf> {
    let path = creds::save_token(Vendor::Cursor, token)?;
    Ok(path)
}

/// Prefer a live keychain token; otherwise require a stored/pasted one.
pub fn auth_auto() -> anyhow::Result<(std::path::PathBuf, TokenSource)> {
    let discovered = crate::discover::cursor_sign_in();
    if let crate::discover::CursorSignIn::Live(_) = discovered {
        // Do not persist discovered tokens: they rotate in the keychain and a
        // stored copy would shadow the live one after expiry.
        let path = creds::session_path(Vendor::Cursor)?;
        return Ok((path, TokenSource::Discovered));
    }
    if let crate::discover::CursorSignIn::Lapsed {
        expired_at_ms: expired_ms,
    } = discovered
    {
        anyhow::bail!(
            "Cursor's sign-in on this machine expired on {}. Open the Cursor app, \
             or run `cursor-agent login`, then try again.",
            expiry_day(expired_ms)
        );
    }
    anyhow::bail!(
        "no Cursor sign-in found. Sign in to the Cursor app or run `cursor-agent login`, \
         or pass --token with a WorkosCursorSessionToken from cursor.com cookies."
    )
}

pub fn logout() -> anyhow::Result<()> {
    creds::clear_token(Vendor::Cursor)?;
    Ok(())
}

/// Read Cursor's own subscription windows from its dashboard summary.
pub fn limits() -> ProviderLimits {
    let token = match creds::cursor_token() {
        Ok(CursorToken::Token(token, _)) => token,
        Ok(CursorToken::Lapsed(expired_ms)) => {
            return unavailable_limits(format!(
                "Cursor's sign-in on this machine expired on {}. Open the Cursor app, \
                 or run `cursor-agent login`, to read its limits again.",
                expiry_day(expired_ms)
            ));
        }
        Ok(CursorToken::Missing) | Err(_) => {
            return ProviderLimits::unavailable(
                "cursor",
                "No Cursor session was found, so its limits cannot be read.",
            );
        }
    };
    let client = match reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .connect_timeout(std::time::Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            return unavailable_limits(format!("Could not prepare the Cursor request: {error}"));
        }
    };
    let mut request = client
        .post(PERIOD_USAGE_URL)
        .header("Content-Type", "application/json")
        .json(&serde_json::json!({}))
        .header("Referer", "https://cursor.com/settings");
    let bearer = looks_like_jwt(&token);
    request = authorize(request, &token);
    let response = match request.send() {
        Ok(response) => response,
        Err(error) => return unavailable_limits(format!("Could not reach Cursor: {error}")),
    };
    if !response.status().is_success() {
        let status = response.status();
        let note = if status == reqwest::StatusCode::UNAUTHORIZED
            || status == reqwest::StatusCode::FORBIDDEN
        {
            if bearer {
                "Cursor rejected the sign-in found on this machine. Open the Cursor app, \
                 or run `cursor-agent login`, to read its limits again."
                    .to_string()
            } else {
                "Cursor rejected the saved session token. Run `tokenstat auth cursor` \
                 after signing in to the Cursor app."
                    .to_string()
            }
        } else {
            format!("Cursor returned {status} for its usage endpoint.")
        };
        return unavailable_limits(note);
    }
    let body: serde_json::Value = match response.json() {
        Ok(body) => body,
        Err(error) => {
            return unavailable_limits(format!("Could not read Cursor's usage answer: {error}"));
        }
    };
    let observed_at_ms = now_ms();
    let mut windows = [
        (
            "5-hour",
            ["rolling5h", "fiveHour", "five_hour", "5h"].as_slice(),
        ),
        (
            "weekly",
            ["weekly", "sevenDay", "seven_day", "7d"].as_slice(),
        ),
        ("monthly", ["monthly", "month", "30d"].as_slice()),
    ]
    .into_iter()
    .filter_map(|(label, keys)| {
        let value = find_named_object(&body, keys)?;
        let percent = number(value, &["usagePercent", "usedPercent", "percentUsed"])?;
        if !percent.is_finite() || !(0.0..=100.0).contains(&percent) {
            return None;
        }
        Some(UsageWindow {
            label: label.to_string(),
            scope: None,
            percent,
            resets_at_ms: reset_at_ms(value, observed_at_ms),
            severity: LimitSeverity::from_percent(percent),
        })
    })
    .collect::<Vec<_>>();
    if windows.is_empty()
        && let Some(plan) = body.get("planUsage").or_else(|| {
            body.get("individualUsage")
                .and_then(|usage| usage.get("plan"))
        })
        && let Some(percent) = number(
            plan,
            &["totalPercentUsed", "apiPercentUsed", "autoPercentUsed"],
        )
        && percent.is_finite()
        && (0.0..=100.0).contains(&percent)
    {
        windows.push(UsageWindow {
            label: "billing cycle".to_string(),
            scope: None,
            percent,
            resets_at_ms: body.get("billingCycleEnd").and_then(epoch_or_iso_ms),
            severity: LimitSeverity::from_percent(percent),
        });
    }
    if windows.is_empty() {
        return unavailable_limits("Cursor reported no subscription usage windows.".to_string());
    }
    // The usage answer does not name the plan. A second, smaller call does,
    // and a failure there costs only the label, never the reading.
    let plan = string_value(&body, &["plan", "membershipType", "planName", "planType"])
        .or_else(|| cached_plan_name(&client, &token));
    ProviderLimits {
        source: "cursor".to_string(),
        plan,
        windows,
        observed_at_ms,
        note: None,
        stale: false,
    }
}

fn authorize(
    request: reqwest::blocking::RequestBuilder,
    token: &str,
) -> reqwest::blocking::RequestBuilder {
    if looks_like_jwt(token) {
        request.bearer_auth(token.trim())
    } else {
        request.header(
            "Cookie",
            format!("WorkosCursorSessionToken={}", token.trim()),
        )
    }
}

/// How long a plan name is trusted before it is asked for again. A plan
/// changes when somebody upgrades, which is rare next to a limits refresh, and
/// asking every time doubled the requests and the worst-case wait.
const PLAN_TTL: std::time::Duration = std::time::Duration::from_secs(6 * 60 * 60);

/// The plan name, from a small file beside the usage cache when it is fresh
/// and belongs to the same account, otherwise from Cursor.
///
/// The file holds the plan and a hash of the account id, never the token.
fn cached_plan_name(client: &reqwest::blocking::Client, token: &str) -> Option<String> {
    let account = account_key(token);
    let path = cache_path(Vendor::Cursor, "plan.json").ok();
    if let Some(path) = &path
        && cache_is_fresh(path, PLAN_TTL)
        && let Some(plan) = fs::read_to_string(path)
            .ok()
            .and_then(|text| cached_plan_for(&text, &account))
    {
        return Some(plan);
    }
    let plan = plan_name(client, token)?;
    if let Some(path) = &path {
        let record = serde_json::json!({ "account": account, "plan": plan }).to_string();
        let _ = crate::snapshot::write_private_atomically(path, &record);
    }
    Some(plan)
}

fn cached_plan_for(text: &str, account: &str) -> Option<String> {
    let record: serde_json::Value = serde_json::from_str(text).ok()?;
    if record.get("account")?.as_str()? != account {
        return None;
    }
    record.get("plan")?.as_str().map(str::to_string)
}

/// Which account a token signs in, as a hash: the JWT subject when there is
/// one, the token itself otherwise.
fn account_key(token: &str) -> String {
    use sha2::{Digest, Sha256};
    let subject = crate::discover::jwt_subject(token).unwrap_or_else(|| token.trim().to_string());
    Sha256::digest(subject.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// `planInfo.planName` from Cursor's plan endpoint, for example `Pro`.
fn plan_name(client: &reqwest::blocking::Client, token: &str) -> Option<String> {
    let request = client
        .post(PLAN_INFO_URL)
        .header("Content-Type", "application/json")
        .json(&serde_json::json!({}));
    let response = authorize(request, token).send().ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: serde_json::Value = response.json().ok()?;
    plan_name_from(&body)
}

fn plan_name_from(body: &serde_json::Value) -> Option<String> {
    body.pointer("/planInfo/planName")?
        .as_str()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}

/// A calendar day for a sentence, in UTC, since this only says roughly when.
fn expiry_day(ms: i64) -> String {
    jiff::Timestamp::from_millisecond(ms)
        .map(|timestamp| timestamp.strftime("%Y-%m-%d").to_string())
        .unwrap_or_else(|_| "an earlier date".to_string())
}

fn unavailable_limits(note: String) -> ProviderLimits {
    ProviderLimits::unavailable("cursor", note)
}

fn find_named_object<'a>(
    value: &'a serde_json::Value,
    names: &[&str],
) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(object) => {
            for name in names {
                if let Some(value) = object.get(*name)
                    && value.is_object()
                {
                    return Some(value);
                }
            }
            object
                .values()
                .find_map(|value| find_named_object(value, names))
        }
        serde_json::Value::Array(values) => values
            .iter()
            .find_map(|value| find_named_object(value, names)),
        _ => None,
    }
}

fn number(value: &serde_json::Value, names: &[&str]) -> Option<f64> {
    names.iter().find_map(|name| value.get(*name)?.as_f64())
}

fn string_value(value: &serde_json::Value, names: &[&str]) -> Option<String> {
    names
        .iter()
        .find_map(|name| value.get(*name)?.as_str().map(str::to_string))
}

fn epoch_or_iso_ms(value: &serde_json::Value) -> Option<i64> {
    if let Some(ms) = value.as_i64() {
        return Some(ms);
    }
    let raw = value.as_str()?;
    if let Ok(ms) = raw.parse::<i64>() {
        return Some(ms);
    }
    raw.parse::<jiff::Timestamp>()
        .ok()
        .map(|timestamp| timestamp.as_millisecond())
}

fn reset_at_ms(value: &serde_json::Value, observed_at_ms: i64) -> Option<i64> {
    for key in ["resetAtMs", "resetsAtMs"] {
        if let Some(ms) = value.get(key).and_then(serde_json::Value::as_i64) {
            return Some(ms);
        }
    }
    for key in ["resetInSec", "resetInSeconds", "resetsInSeconds"] {
        if let Some(seconds) = value.get(key).and_then(serde_json::Value::as_i64) {
            return Some(observed_at_ms.saturating_add(seconds.saturating_mul(1000)));
        }
    }
    for key in ["resetAt", "resetsAt", "resetTime"] {
        if let Some(raw) = value.get(key).and_then(serde_json::Value::as_str)
            && let Ok(timestamp) = raw.parse::<jiff::Timestamp>()
        {
            return Some(timestamp.as_millisecond());
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

/// Pull Cursor usage into the archive, using the on-disk cache when fresh.
pub fn fetch_into(
    store: &mut Store,
    tz: &jiff::tz::TimeZone,
    force: bool,
) -> anyhow::Result<FetchReport> {
    let (token, source) = match creds::cursor_token()? {
        CursorToken::Token(token, source) => (token, source),
        CursorToken::Lapsed(expired_ms) => return Ok(no_token_report(Some(expired_ms))),
        CursorToken::Missing => return Ok(no_token_report(None)),
    };

    let use_bearer = looks_like_jwt(&token);
    let cache_name = if use_bearer {
        "usage-events.json"
    } else {
        "usage.csv"
    };
    let cache = cache_path(Vendor::Cursor, cache_name)?;

    let (events, from_cache) = if !force && cache_is_fresh(&cache, FETCH_TTL) {
        let text = fs::read_to_string(&cache)?;
        let events = if use_bearer {
            parse_events_json(&text)?
        } else {
            parse_csv(&text)?
        };
        (events, true)
    } else {
        let (events, raw) = if use_bearer {
            let raw = download_events_json(&token)?;
            (parse_events_json(&raw)?, raw)
        } else {
            let raw = download_csv(&token)?;
            (parse_csv(&raw)?, raw)
        };
        crate::snapshot::write_private_atomically(&cache, &raw).map_err(|e| anyhow::anyhow!(e))?;
        (events, false)
    };

    let n = events.len();
    store.insert_events(&events, tz)?;
    let src = match source {
        TokenSource::Env => "env",
        TokenSource::Stored => "stored",
        TokenSource::Discovered => "cursor keychain",
    };
    Ok(FetchReport {
        vendor: "cursor",
        events: n,
        from_cache,
        skipped_no_token: false,
        message: Some(format!("auth via {src}")),
    })
}

/// A fetch that had no token to use, and the sentence that says why.
fn no_token_report(lapsed_at_ms: Option<i64>) -> FetchReport {
    let message = match lapsed_at_ms {
        Some(expired_ms) => format!(
            "Cursor's sign-in expired on {}. Open the Cursor app, or run `cursor-agent login`.",
            expiry_day(expired_ms)
        ),
        None => "no Cursor token. Sign in to the Cursor app, run `cursor-agent login`, or: \
                 tokenstat auth cursor --token <WorkosCursorSessionToken>"
            .into(),
    };
    FetchReport {
        vendor: "cursor",
        skipped_no_token: true,
        message: Some(message),
        ..FetchReport::default()
    }
}

fn looks_like_jwt(token: &str) -> bool {
    let t = token.trim();
    t.matches('.').count() == 2 && !t.contains("%3A%3A") && !t.contains("::")
}

fn download_events_json(access_token: &str) -> anyhow::Result<String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .connect_timeout(std::time::Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .build()?;

    let mut all: Vec<serde_json::Value> = Vec::new();
    let mut page: u32 = 1;
    loop {
        let body = serde_json::json!({ "page": page, "pageSize": 200 });
        let resp = client
            .post(EVENTS_URL)
            .bearer_auth(access_token.trim())
            .header("Content-Type", "application/json")
            .body(serde_json::to_vec(&body)?)
            .send()?;

        if resp.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let retry = resp
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("60");
            anyhow::bail!("Cursor rate limited. Retry after {retry}s.");
        }
        if resp.status() == reqwest::StatusCode::UNAUTHORIZED
            || resp.status() == reqwest::StatusCode::FORBIDDEN
        {
            anyhow::bail!(
                "Cursor access token rejected ({}). Sign in to the Cursor app again.",
                resp.status()
            );
        }
        if !resp.status().is_success() {
            anyhow::bail!("Cursor usage events returned {}", resp.status());
        }

        let text = resp.text()?;
        let root: EventsResponse = serde_json::from_str(&text)?;
        let total = root.total_usage_events_count;
        let batch = root.usage_events_display;
        if batch.is_empty() {
            break;
        }
        let n = batch.len();
        all.extend(batch);
        if all.len() as u64 >= total || n < 200 {
            break;
        }
        page += 1;
        if page > 50 {
            break;
        }
    }

    Ok(serde_json::to_string(&EventsResponse {
        total_usage_events_count: all.len() as u64,
        usage_events_display: all,
    })?)
}

#[derive(Debug, Deserialize, serde::Serialize)]
struct EventsResponse {
    #[serde(rename = "totalUsageEventsCount", default)]
    total_usage_events_count: u64,
    #[serde(rename = "usageEventsDisplay", default)]
    usage_events_display: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct RemoteEvent {
    timestamp: Option<String>,
    model: Option<String>,
    kind: Option<String>,
    #[serde(rename = "conversationId")]
    conversation_id: Option<String>,
    #[serde(rename = "isTokenBasedCall")]
    is_token_based: Option<bool>,
    #[serde(rename = "tokenUsage")]
    token_usage: Option<TokenUsage>,
}

#[derive(Debug, Deserialize)]
struct TokenUsage {
    #[serde(rename = "inputTokens")]
    input: Option<u64>,
    #[serde(rename = "outputTokens")]
    output: Option<u64>,
    #[serde(rename = "cacheReadTokens")]
    cache_read: Option<u64>,
    #[serde(rename = "cacheWriteTokens")]
    cache_write: Option<u64>,
}

fn parse_events_json(text: &str) -> anyhow::Result<Vec<UsageEvent>> {
    let root: EventsResponse = serde_json::from_str(text)?;
    let mut events = Vec::new();
    for raw in root.usage_events_display.iter() {
        let ev: RemoteEvent = match serde_json::from_value(raw.clone()) {
            Ok(e) => e,
            Err(_) => continue,
        };
        if ev.is_token_based == Some(false) {
            continue;
        }
        let Some(tu) = ev.token_usage else {
            continue;
        };
        let input = tu.input.unwrap_or(0);
        let output = tu.output.unwrap_or(0);
        let cache_read = tu.cache_read.unwrap_or(0);
        let cache_write = tu.cache_write.unwrap_or(0);
        if input == 0 && output == 0 && cache_read == 0 && cache_write == 0 {
            continue;
        }
        let model = ev
            .model
            .as_deref()
            .filter(|s| !s.is_empty())
            .unwrap_or("cursor-unknown");
        let ts_raw = ev.timestamp.as_deref().unwrap_or("0");
        let ts_ms: i64 = ts_raw.parse().unwrap_or(0);
        let session = ev
            .conversation_id
            .as_deref()
            .filter(|s| !s.is_empty() && *s != "null")
            .map(|s| format!("cursor:{s}"))
            .unwrap_or_else(|| format!("cursor:{ts_raw}"));

        let id = EventId::derive(&[
            "cursor",
            "events",
            ts_raw,
            model,
            &session,
            &input.to_string(),
            &output.to_string(),
            &cache_read.to_string(),
            &cache_write.to_string(),
        ]);

        events.push(UsageEvent {
            id,
            source: SourceId::Cursor,
            ts: Timestamp::from_ms(ts_ms),
            model: model.to_string(),
            session,
            project: "cursor".into(),
            counters: Counters {
                input_fresh: Some(input),
                cache_read: Some(cache_read),
                cache_write_5m: Some(cache_write),
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras::default(),
            billing: billing_from_kind(ev.kind.as_deref()),
            confidence: Confidence::Strong,
        });
    }
    Ok(events)
}

fn billing_from_kind(kind: Option<&str>) -> BillingMode {
    match kind.unwrap_or("") {
        "USAGE_EVENT_KIND_USAGE_BASED"
        | "USAGE_EVENT_KIND_ON_DEMAND"
        | "USAGE_EVENT_KIND_USER_API_KEY" => BillingMode::Metered,
        "USAGE_EVENT_KIND_ERRORED_NOT_CHARGED" => BillingMode::Unknown,
        // Included in Pro / custom subscription: plan usage, not a cash charge.
        _ if kind
            .map(|k| k.contains("INCLUDED") || k.contains("SUBSCRIPTION"))
            .unwrap_or(false) =>
        {
            BillingMode::Plan
        }
        _ => BillingMode::Plan,
    }
}

fn download_csv(session_token: &str) -> anyhow::Result<String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .connect_timeout(std::time::Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .build()?;

    let resp = client
        .get(CSV_URL)
        .header(
            "Cookie",
            format!("WorkosCursorSessionToken={}", session_token.trim()),
        )
        .header("Referer", "https://cursor.com/settings")
        .send()?;

    if resp.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
        let retry = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("60");
        anyhow::bail!("Cursor rate limited. Retry after {retry}s.");
    }
    if resp.status() == reqwest::StatusCode::UNAUTHORIZED
        || resp.status() == reqwest::StatusCode::FORBIDDEN
    {
        anyhow::bail!("Cursor session expired. Re-run: tokenstat auth cursor");
    }
    if !resp.status().is_success() {
        anyhow::bail!("Cursor usage export returned {}", resp.status());
    }

    let text = resp.text()?;
    if !text.starts_with("Date,") {
        anyhow::bail!("Cursor usage export was not CSV (session may be wrong)");
    }
    Ok(text)
}

/// Parse the dashboard CSV into normalized events.
///
/// Supports both:
/// - `Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,...`
/// - `Date,Kind,Model,...` (newer dashboard)
pub fn parse_csv(text: &str) -> anyhow::Result<Vec<UsageEvent>> {
    let mut lines = text.lines();
    let header = lines.next().unwrap_or("");
    let cols: Vec<&str> = header.split(',').map(str::trim).collect();
    if cols.is_empty() || cols[0] != "Date" {
        anyhow::bail!("unexpected Cursor CSV header");
    }

    let idx = |name: &str| cols.iter().position(|c| *c == name);
    let date_i = idx("Date").unwrap_or(0);
    let model_i =
        idx("Model").or_else(|| cols.iter().position(|c| c.eq_ignore_ascii_case("Model")));
    let Some(model_i) = model_i else {
        anyhow::bail!("Cursor CSV missing Model column");
    };
    let with_write_i = idx("Input (w/ Cache Write)");
    let without_write_i = idx("Input (w/o Cache Write)");
    let cache_read_i = idx("Cache Read");
    let output_i = idx("Output Tokens");

    let mut events = Vec::new();
    for (row_n, line) in lines.enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let fields = split_csv_line(line);
        if fields.len() <= model_i.max(date_i) {
            continue;
        }
        let date = fields[date_i].trim();
        let model = fields[model_i].trim();
        if date.is_empty() || model.is_empty() {
            continue;
        }

        let num = |i: Option<usize>| -> u64 {
            i.and_then(|i| fields.get(i))
                .and_then(|s| parse_number(s))
                .unwrap_or(0)
        };

        let with_write = num(with_write_i);
        let without_write = num(without_write_i);
        let cache_read = num(cache_read_i);
        let output = num(output_i);
        let cache_write = with_write.saturating_sub(without_write);
        let input_fresh = without_write;

        if input_fresh == 0 && cache_read == 0 && cache_write == 0 && output == 0 {
            continue;
        }

        let ts_ms = date_to_ms(date).unwrap_or(0);
        let id = EventId::derive(&[
            "cursor",
            date,
            model,
            &row_n.to_string(),
            &input_fresh.to_string(),
            &output.to_string(),
            &cache_read.to_string(),
        ]);

        events.push(UsageEvent {
            id,
            source: SourceId::Cursor,
            ts: Timestamp::from_ms(ts_ms),
            model: model.to_string(),
            session: format!("cursor:{date}"),
            project: "cursor".into(),
            counters: Counters {
                input_fresh: Some(input_fresh),
                cache_read: Some(cache_read),
                cache_write_5m: Some(cache_write),
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras::default(),
            billing: BillingMode::Plan,
            confidence: Confidence::Strong,
        });
    }
    Ok(events)
}

fn split_csv_line(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    for c in line.chars() {
        match c {
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                out.push(std::mem::take(&mut cur));
            }
            _ => cur.push(c),
        }
    }
    out.push(cur);
    out
}

fn parse_number(s: &str) -> Option<u64> {
    let cleaned: String = s.chars().filter(|c| c.is_ascii_digit()).collect();
    cleaned.parse().ok()
}

fn date_to_ms(date: &str) -> Option<i64> {
    // "2026-07-28" or "2026-07-28 12:34:56"
    let day = date.get(..10)?;
    let d = day.parse::<jiff::civil::Date>().ok()?;
    let zdt = d.at(12, 0, 0, 0).to_zoned(jiff::tz::TimeZone::UTC).ok()?;
    Some(zdt.timestamp().as_millisecond())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_classic_cursor_csv() {
        let csv = "\
Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
2026-07-20,gpt-4o,100,80,50,20
";
        let ev = parse_csv(csv).unwrap();
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].source, SourceId::Cursor);
        assert_eq!(ev[0].model, "gpt-4o");
        assert_eq!(ev[0].counters.input_fresh, Some(80));
        assert_eq!(ev[0].counters.cache_write_5m, Some(20));
        assert_eq!(ev[0].counters.cache_read, Some(50));
        assert_eq!(ev[0].counters.output, Some(20));
    }

    #[test]
    fn parses_dashboard_events_json() {
        let raw = r#"{
          "totalUsageEventsCount": 1,
          "usageEventsDisplay": [{
            "timestamp": "1785264223155",
            "model": "cursor-grok-4.5-high-fast",
            "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
            "isTokenBasedCall": true,
            "conversationId": "abc",
            "tokenUsage": {
              "inputTokens": 100,
              "outputTokens": 20,
              "cacheReadTokens": 500,
              "cacheWriteTokens": 50
            }
          }]
        }"#;
        let ev = parse_events_json(raw).unwrap();
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].model, "cursor-grok-4.5-high-fast");
        assert_eq!(ev[0].counters.input_fresh, Some(100));
        assert_eq!(ev[0].counters.output, Some(20));
        assert_eq!(ev[0].counters.cache_read, Some(500));
        assert_eq!(ev[0].counters.cache_write_5m, Some(50));
        assert_eq!(ev[0].billing, BillingMode::Plan);
        assert_eq!(ev[0].ts.utc_ms, 1785264223155);
    }

    #[test]
    fn jwt_heuristic_distinguishes_cookie_sessions() {
        assert!(looks_like_jwt("aaa.bbb.ccc"));
        assert!(!looks_like_jwt("user_01ABC%3A%3AeyJhbGciOiJ"));
        assert!(!looks_like_jwt("user_01ABC::eyJhbGciOiJ"));
    }

    #[test]
    fn parses_nested_summary_windows() {
        let summary = serde_json::json!({
            "plan": "Pro",
            "includedUsage": {
                "fiveHour": {"usagePercent": 42.0, "resetInSec": 60},
                "weekly": {"usagePercent": 12.5, "resetInSec": 3600}
            }
        });
        let observed = 1_000_000;
        let windows: Vec<_> = [
            (
                "5-hour",
                ["rolling5h", "fiveHour", "five_hour", "5h"].as_slice(),
            ),
            (
                "weekly",
                ["weekly", "sevenDay", "seven_day", "7d"].as_slice(),
            ),
        ]
        .into_iter()
        .filter_map(|(label, keys)| {
            let value = find_named_object(&summary, keys)?;
            let percent = number(value, &["usagePercent", "usedPercent", "percentUsed"])?;
            Some(UsageWindow {
                label: label.to_string(),
                scope: None,
                percent,
                resets_at_ms: reset_at_ms(value, observed),
                severity: LimitSeverity::from_percent(percent),
            })
        })
        .collect();
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].resets_at_ms, Some(1_060_000));
        assert_eq!(string_value(&summary, &["plan"]), Some("Pro".to_string()));
    }

    #[test]
    fn a_cached_plan_belongs_to_one_account() {
        let token = "header.eyJzdWIiOiJ1c2VyLTEifQ.signature";
        let account = account_key(token);
        assert_eq!(account, account_key("other.eyJzdWIiOiJ1c2VyLTEifQ.sig"));
        assert_ne!(
            account,
            account_key("header.eyJzdWIiOiJ1c2VyLTIifQ.signature")
        );
        let record = serde_json::json!({"account": account, "plan": "Pro"}).to_string();
        assert_eq!(cached_plan_for(&record, &account), Some("Pro".to_string()));
        assert_eq!(cached_plan_for(&record, "someone-else"), None);
        assert!(!record.contains("signature"));
    }

    #[test]
    fn reads_the_plan_name_from_plan_info() {
        let body = serde_json::json!({
            "planInfo": {"planName": "Pro", "price": "$20/mo"},
            "nextUpgrade": {"name": "Pro+"}
        });
        assert_eq!(plan_name_from(&body), Some("Pro".to_string()));
        assert_eq!(plan_name_from(&serde_json::json!({"planInfo": {}})), None);
    }

    #[test]
    fn parses_cursor_billing_cycle_summary() {
        let summary = serde_json::json!({
            "billingCycleEnd": "1787650795000",
            "planUsage": {"autoPercentUsed": 100, "apiPercentUsed": 100}
        });
        let plan = summary.get("planUsage").unwrap();
        assert_eq!(
            number(
                plan,
                &["totalPercentUsed", "apiPercentUsed", "autoPercentUsed"]
            ),
            Some(100.0)
        );
        assert_eq!(
            epoch_or_iso_ms(summary.get("billingCycleEnd").unwrap()),
            Some(1787650795000)
        );
    }
}
