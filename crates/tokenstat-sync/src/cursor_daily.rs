// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Cursor's hourly usage totals, for accounts the request list no longer covers.
//!
//! A Cursor account merged into xAI's unified billing stops appearing in
//! `GetFilteredUsageEvents` from the day it moved: the request list simply
//! ends, while the plan meter keeps counting. Its usage is still on Cursor's
//! own dashboard, which reports hourly token totals per product and model:
//!
//! `POST https://cursor.com/api/dashboard/v2/query-daily-usage`
//!
//! with `{"scope":"user","startTime","endTime","groupBy":[...],"granularity"}`.
//! An hourly range may span at most 7 days and a daily one 31, so the last
//! days are read by the hour and everything older by the day. It signs in with the same Cursor session as
//! the CSV export, so nothing new is asked of the person: the app token already
//! read for the request list becomes `WorkosCursorSessionToken`.
//!
//! The totals carry no input, output or cache split, so they are stored as
//! derived rows through [`Store::reconcile_vendor_hours`], which adds only what
//! the archive does not already hold for that source and UTC day. A day the
//! request list covered (every legacy account, and a merged account before it
//! moved) gains nothing. Products from the same bundle go to their own tool:
//! Grok Build and Grok API to Grok, again only past what Grok's local logs hold.

use std::collections::BTreeMap;
use std::fs;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokenstat_core::{BillingMode, SourceId, Store, VendorHour};

use crate::creds::{cache_is_fresh, cache_path};
use crate::{FETCH_TTL, Vendor};

const DAILY_USAGE_URL: &str = "https://cursor.com/api/dashboard/v2/query-daily-usage";

/// Session prefix of the rows this feed writes. Also part of their ids.
const PREFIX: &str = "cursor-daily";

/// The widest ranges the endpoint accepts, by granularity.
const HOURLY_DAYS: i64 = 7;
const WINDOW_DAYS: i64 = 30;
const DAY_MS: i64 = 86_400_000;
const HOUR_MS: i64 = 3_600_000;

/// How far back the history walk goes, in windows.
const MAX_WINDOWS: usize = 12;

/// Older windows change rarely, so they are walked once a day. The hourly
/// days follow the usual fetch cache.
const HISTORY_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// What one fetch added, for the report line.
#[derive(Debug, Default)]
pub struct DailyOutcome {
    pub rows: u64,
    pub from_cache: bool,
}

/// Fetch the account's hourly totals and store what the archive lacks.
pub fn fetch_into(
    store: &mut Store,
    tz: &jiff::tz::TimeZone,
    token: &str,
    account: &str,
    force: bool,
) -> anyhow::Result<DailyOutcome> {
    let cookie = session_cookie(token)
        .ok_or_else(|| anyhow::anyhow!("the Cursor sign-in names no account"))?;
    let now_ms = jiff::Timestamp::now().as_millisecond();
    let end_ms = (now_ms.div_euclid(HOUR_MS) + 1) * HOUR_MS;
    // Start the hourly range on a UTC day boundary, so no day is split
    // between the two granularities. Six whole days plus today stays inside
    // the hourly limit.
    let recent_start = (now_ms.div_euclid(DAY_MS) - (HOURLY_DAYS - 1)) * DAY_MS;

    let recent_path = cache_path(Vendor::Cursor, &format!("{account}-hourly-recent.json"))?;
    let history_path = cache_path(Vendor::Cursor, &format!("{account}-hourly-history.json"))?;

    let mut from_cache = true;
    let recent = match cached(&recent_path, FETCH_TTL, force) {
        Some(points) => points,
        None => {
            from_cache = false;
            let points = query(&cookie, recent_start, end_ms, Granularity::Hour)?;
            store_cache(&recent_path, &points)?;
            points
        }
    };
    let history = match cached(&history_path, HISTORY_TTL, force) {
        Some(points) => points,
        None => {
            from_cache = false;
            // Best effort: a history that stopped early is still worth
            // keeping, and an empty one is retried on the next fetch.
            // A transient failure in the older range must not discard a
            // successful recent reading. Leave the failed history uncached
            // so the next fetch retries it.
            let points = walk_history(&cookie, recent_start).unwrap_or_default();
            if !points.is_empty() {
                store_cache(&history_path, &points)?;
            }
            points
        }
    };

    // The ranges meet on a day boundary. Should a point appear in both, the
    // hourly reading is the fresher one and wins.
    let mut merged: BTreeMap<(i64, String, String), Point> = BTreeMap::new();
    for point in history.into_iter().chain(recent) {
        merged.insert(
            (point.hour_ms, point.product.clone(), point.model.clone()),
            point,
        );
    }
    let hours: Vec<VendorHour> = merged.into_values().filter_map(vendor_hour).collect();
    let rows = store.reconcile_vendor_hours(PREFIX, &hours, tz)?;
    Ok(DailyOutcome { rows, from_cache })
}

/// `<account id>%3A%3A<jwt>`, the form Cursor's web dashboard signs in with.
/// A pasted session token is already in that form.
fn session_cookie(token: &str) -> Option<String> {
    let token = token.trim();
    if token.contains("%3A%3A") || token.contains("::") {
        return Some(format!("WorkosCursorSessionToken={token}"));
    }
    let subject = crate::discover::jwt_subject(token)?;
    let user = subject.rsplit('|').next().filter(|id| !id.is_empty())?;
    Some(format!("WorkosCursorSessionToken={user}%3A%3A{token}"))
}

/// One hour of one product and model, as cached. Zero hours are kept so a
/// day that went quiet is recomputed rather than left with stale rows.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Point {
    hour_ms: i64,
    product: String,
    model: String,
    tokens: u64,
    included: u64,
}

#[derive(Debug, Deserialize)]
struct UsageAnswer {
    #[serde(default)]
    series: Vec<Series>,
}

#[derive(Debug, Deserialize)]
struct Series {
    #[serde(default)]
    dimensions: BTreeMap<String, String>,
    #[serde(default)]
    points: Vec<RawPoint>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPoint {
    day_start_time: String,
    #[serde(default)]
    tokens: u64,
    #[serde(default)]
    included_tokens: u64,
}

/// Walk back window by window until two in a row are empty.
///
/// Cursor answers some windows with a 500, around and before the day an
/// account was created. The walk stops at the first failure and keeps what it
/// has. Only a failure on the newest window is an error, because then nothing
/// at all is known.
fn walk_history(cookie: &str, until_ms: i64) -> anyhow::Result<Vec<Point>> {
    let mut points = Vec::new();
    let mut end = until_ms;
    let mut empty_in_a_row = 0;
    for _ in 0..MAX_WINDOWS {
        let start = end - WINDOW_DAYS * DAY_MS;
        let window = match query(cookie, start, end, Granularity::Day) {
            Ok(window) => window,
            Err(error) if end == until_ms => return Err(error),
            Err(_) => break,
        };
        if window.iter().all(|p| p.tokens == 0) {
            empty_in_a_row += 1;
            if empty_in_a_row == 2 {
                break;
            }
        } else {
            empty_in_a_row = 0;
        }
        points.extend(window);
        end = start;
    }
    Ok(points)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Granularity {
    Hour,
    Day,
}

fn query(
    cookie: &str,
    start_ms: i64,
    end_ms: i64,
    granularity: Granularity,
) -> anyhow::Result<Vec<Point>> {
    let client = crate::http::client_builder()
        .timeout(Duration::from_secs(60))
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .build()?;
    let body = serde_json::json!({
        "scope": "user",
        "startTime": rfc3339(start_ms)?,
        "endTime": rfc3339(end_ms)?,
        "groupBy": ["product", "model"],
        "granularity": match granularity {
            Granularity::Hour => "hour",
            Granularity::Day => "day",
        },
    });
    let response = client
        .post(DAILY_USAGE_URL)
        .header("Cookie", cookie)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header("Origin", "https://cursor.com")
        .header("Referer", "https://cursor.com/dashboard/usage")
        .header("x-cursor-dashboard-surface", "v2")
        .json(&body)
        .send()?;
    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        anyhow::bail!("Cursor's dashboard refused the sign-in ({status})");
    }
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        anyhow::bail!("Cursor's dashboard is rate limiting. Retrying later.");
    }
    if !status.is_success() {
        anyhow::bail!("Cursor's hourly usage returned {status}");
    }
    parse(&response.text()?, granularity)
}

/// A daily point is placed at noon UTC, so it lands on the same calendar
/// date in every timezone within twelve hours of UTC.
fn parse(text: &str, granularity: Granularity) -> anyhow::Result<Vec<Point>> {
    let offset = match granularity {
        Granularity::Hour => 0,
        Granularity::Day => DAY_MS / 2,
    };
    let answer: UsageAnswer = serde_json::from_str(text)?;
    let mut points = Vec::new();
    for series in answer.series {
        let product = series
            .dimensions
            .get("product")
            .cloned()
            .unwrap_or_default();
        let model = series.dimensions.get("model").cloned().unwrap_or_default();
        for raw in series.points {
            let Ok(hour) = raw.day_start_time.parse::<jiff::Timestamp>() else {
                continue;
            };
            points.push(Point {
                hour_ms: hour.as_millisecond() + offset,
                product: product.clone(),
                model: model.clone(),
                tokens: raw.tokens,
                included: raw.included_tokens,
            });
        }
    }
    Ok(points)
}

/// Which tool a product's usage belongs to, and the model name to show for it.
/// Products not listed are left out rather than guessed at.
fn vendor_hour(point: Point) -> Option<VendorHour> {
    let named = |fallback: &str| {
        if point.model.is_empty() || point.model == "Other" {
            fallback.to_string()
        } else {
            point.model.clone()
        }
    };
    let (source, project, model) = match point.product.as_str() {
        // `grok-bot` is how the same Cursor usage is labelled before the
        // account's move finished. The request list usually has those days.
        "cursor" => (SourceId::Cursor, "cursor", named("cursor-unknown")),
        "grok-bot" => (SourceId::Cursor, "cursor", named("grok-bot")),
        "grok-build" => (SourceId::Grok, "grok", named("grok-build")),
        "grok-api" => (SourceId::Grok, "grok", named("grok-api")),
        _ => return None,
    };
    // Included usage is plan usage. Anything charged beyond it is metered.
    let billing = if point.included.saturating_mul(2) >= point.tokens {
        BillingMode::Plan
    } else {
        BillingMode::Metered
    };
    Some(VendorHour {
        source,
        hour_start_ms: point.hour_ms,
        model,
        project: project.to_string(),
        tokens: point.tokens,
        billing,
    })
}

fn cached(path: &std::path::Path, ttl: Duration, force: bool) -> Option<Vec<Point>> {
    if force || !cache_is_fresh(path, ttl) {
        return None;
    }
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

fn store_cache(path: &std::path::Path, points: &[Point]) -> anyhow::Result<()> {
    crate::snapshot::write_private_atomically(path, &serde_json::to_string(points)?)
}

fn rfc3339(ms: i64) -> anyhow::Result<String> {
    Ok(jiff::Timestamp::from_millisecond(ms)?
        .strftime("%Y-%m-%dT%H:%M:%SZ")
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ANSWER: &str = r#"{
      "availability": "available",
      "totalTokens": 52548182,
      "series": [
        {"dimensions": {"product": "cursor", "model": "cursor-grok-4.5-medium"},
         "points": [
           {"dayStartTime": "2026-11-11T20:00:00.000Z", "contractedCost": "0", "tokens": 219600, "includedTokens": 219600},
           {"dayStartTime": "2026-11-11T21:00:00.000Z", "contractedCost": "0", "tokens": 0, "includedTokens": 0}
         ]},
        {"dimensions": {"product": "grok-build", "model": "Other"},
         "points": [{"dayStartTime": "2026-11-07T10:00:00.000Z", "tokens": 639412, "includedTokens": 639412}]},
        {"dimensions": {"product": "grok-imagine", "model": "Other"},
         "points": [{"dayStartTime": "2026-11-07T10:00:00.000Z", "tokens": 5, "includedTokens": 5}]}
      ],
      "other": {"totalTokens": 0, "points": []}
    }"#;

    #[test]
    fn hours_map_to_their_own_tool_and_unknown_products_are_left_out() {
        let hours: Vec<_> = parse(ANSWER, Granularity::Hour)
            .unwrap()
            .into_iter()
            .filter_map(vendor_hour)
            .collect();
        assert_eq!(hours.len(), 3);
        assert_eq!(hours[0].source, SourceId::Cursor);
        assert_eq!(hours[0].model, "cursor-grok-4.5-medium");
        assert_eq!(hours[0].tokens, 219_600);
        assert_eq!(hours[0].billing, BillingMode::Plan);
        assert_eq!(hours[1].tokens, 0);
        assert_eq!(hours[2].source, SourceId::Grok);
        assert_eq!(hours[2].model, "grok-build");
        assert_eq!(hours[2].project, "grok");
    }

    #[test]
    fn a_daily_point_is_placed_at_noon_utc() {
        let daily = parse(ANSWER, Granularity::Day).unwrap();
        let hourly = parse(ANSWER, Granularity::Hour).unwrap();
        assert_eq!(daily[0].hour_ms - hourly[0].hour_ms, 12 * HOUR_MS);
    }

    #[test]
    fn charged_usage_beyond_the_plan_is_metered() {
        let hour = vendor_hour(Point {
            hour_ms: 0,
            product: "cursor".into(),
            model: "m".into(),
            tokens: 100,
            included: 10,
        })
        .unwrap();
        assert_eq!(hour.billing, BillingMode::Metered);
    }

    #[test]
    fn the_cookie_names_the_account_the_app_token_signs_in() {
        // header.{"sub":"grok|user_01ABC"}.signature
        let token = "e30.eyJzdWIiOiJncm9rfHVzZXJfMDFBQkMifQ.sig";
        assert_eq!(
            session_cookie(token).unwrap(),
            format!("WorkosCursorSessionToken=user_01ABC%3A%3A{token}")
        );
        assert_eq!(
            session_cookie("user_01ABC%3A%3Ajwt").unwrap(),
            "WorkosCursorSessionToken=user_01ABC%3A%3Ajwt"
        );
    }

    #[test]
    fn ranges_are_sent_as_rfc3339() {
        assert_eq!(rfc3339(1_794_268_800_000).unwrap(), "2026-11-10T00:00:00Z");
    }
}
