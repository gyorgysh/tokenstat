// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! The account's activity grid, across every machine that syncs.
//!
//! The local archive is one machine's logs, which is the whole design: the
//! parser reads what is on this disk. "What did I spend everywhere" is a
//! different question, and the only place that knows is the account the
//! machines already upload to.
//!
//! What comes back is token counts at day × source × model. Pricing happens
//! here, against the same local price book the local grid uses, so the two
//! figures are computed the same way and can be compared. The service never
//! prices anything, which is why it can hold aggregate counts and stay a place
//! that holds no money.
//!
//! Cached, because this is drawn on the screen that opens first and a window
//! that dials out on every visit is a window that dials out constantly.

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use tokenstat_core::activity::{self, HeatCalendar};
use tokenstat_core::model::Counters;
use tokenstat_core::pricing::{EquivalentValue, PriceTable};
use tokenstat_sync::profile::{self, SeriesRow};

/// How long a fetched series stays good.
///
/// Sync itself runs hourly at its fastest, so a grid younger than this cannot
/// be missing anything the account knows. Long enough that moving between
/// screens is free, short enough that a machine that just synced shows up
/// while somebody is still looking.
const FRESH_FOR: Duration = Duration::from_secs(10 * 60);

/// How long to wait before asking again after a failure.
///
/// Being signed out is a failure that does not fix itself, and retrying it on
/// every redraw is how a client earns a rate limit. The service allows sixty
/// reads a minute; this keeps us nowhere near it even when everything is
/// broken.
const RETRY_AFTER: Duration = Duration::from_secs(60);

/// Why the account grid could not be built.
///
/// `expected` separates "you do not have this" from "it went wrong". Not being
/// signed in, and the read API being a paid feature, are both settled facts
/// about the account rather than faults, and repeating either of them on the
/// screen that opens first is nagging. The caller falls back either way, but
/// only says why when there is something to say.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureReason {
    /// Not signed in, or the token was rejected. The fix is a sign-in, and a
    /// front end can offer one instead of quoting a CLI command.
    Authentication,
    /// The account exists but does not include this route.
    UpgradeRequired,
    /// Anything else: network, server, cache.
    Other,
}

pub struct FetchError {
    pub message: String,
    pub reason: FailureReason,
    pub expected: bool,
}

impl FetchError {
    fn new(message: String) -> FetchError {
        let lower = message.to_lowercase();
        let authentication = lower.contains("not signed in")
            || lower.contains("not logged in")
            || lower.contains("sign in")
            || lower.contains("token missing or revoked");
        let upgrade =
            lower.contains("(402") || lower.contains("upgrade_required") || lower.contains("(403)");
        let reason = if authentication {
            FailureReason::Authentication
        } else if upgrade {
            FailureReason::UpgradeRequired
        } else {
            FailureReason::Other
        };
        let expected = authentication || upgrade;
        FetchError {
            message,
            reason,
            expected,
        }
    }
}

struct Cache {
    rows: Vec<SeriesRow>,
    /// The oldest day the service actually covered. A plan's history span, not
    /// what was asked for.
    covered_from: Option<String>,
    fetched_at: Instant,
    /// Set when the last attempt failed, so the message can be shown without
    /// asking again immediately.
    last_error: Option<(String, Instant)>,
}

fn cache() -> &'static Mutex<Option<Cache>> {
    static CACHE: OnceLock<Mutex<Option<Cache>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// Drop the cached series, so the next call goes to the service.
///
/// Called after a successful upload: the account just changed, and the figure
/// on screen is the one the user came to check.
pub fn invalidate() {
    if let Ok(mut guard) = cache().lock() {
        *guard = None;
    }
}

/// The account's grid, priced here and built by the core.
///
/// `Ok(None)` means the account has nothing in the window, which is an answer.
/// `Err` means we could not ask, which is a different answer and the caller
/// must not draw it as an empty year.
///
/// The returned `weeks` can be narrower than the `weeks` asked for. A plan's
/// history span decides how far back the service will go, and a grid drawn
/// wider than that would render days it was never sent as days on which
/// nothing happened. Narrower and honest beats wider and wrong.
pub fn calendar(
    prices: &PriceTable,
    tz: &jiff::tz::TimeZone,
    weeks: usize,
) -> Result<Option<HeatCalendar>, FetchError> {
    let today = activity::today(tz);
    let fetched = series(weeks, today)?;
    let rows = fetched.rows;
    let weeks = covered_weeks(weeks, today, fetched.covered_from.as_deref());

    // Priced, then folded by day. Per model rather than per day, because a
    // rate belongs to a model: summing tokens across models first and pricing
    // the total would charge every model at whichever rate came last.
    let mut by_day: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
    for row in &rows {
        let counters = Counters {
            input_fresh: Some(row.input),
            cache_read: Some(row.cr),
            cache_write_5m: Some(row.cw5),
            cache_write_1h: Some(row.cw1),
            output: Some(row.output),
        };
        // Value at list rates, for plan usage as well as metered. That is what
        // the local grid colours by, and a plan day that reads as empty here
        // and full there is the two screens disagreeing.
        let micros = EquivalentValue::price(prices, &row.model, &counters)
            .map(|v| v.micros().max(0) as u64)
            .unwrap_or(0);
        *by_day.entry(row.day.clone()).or_insert(0) += micros;
    }

    let days: Vec<(String, u64)> = by_day.into_iter().collect();
    Ok(activity::calendar(&days, weeks, today))
}

/// How many whole weeks the service actually covered, capped at what was asked.
fn covered_weeks(asked: usize, today: jiff::civil::Date, covered_from: Option<&str>) -> usize {
    let Some(from) = covered_from.and_then(|d| d.parse::<jiff::civil::Date>().ok()) else {
        return asked;
    };
    let days = (today - from).get_days().max(0) as usize;
    // Round down: a partial week at the far edge is a column with days in it
    // that were never covered, which is the thing this exists to prevent.
    (days / 7).clamp(1, asked)
}

struct Fetched {
    rows: Vec<SeriesRow>,
    covered_from: Option<String>,
}

/// The cached series, fetched if it is stale.
fn series(weeks: usize, today: jiff::civil::Date) -> Result<Fetched, FetchError> {
    {
        let guard = cache()
            .lock()
            .map_err(|_| FetchError::new("the usage cache is poisoned".into()))?;
        if let Some(c) = guard.as_ref() {
            if c.fetched_at.elapsed() < FRESH_FOR {
                return Ok(Fetched {
                    rows: c.rows.clone(),
                    covered_from: c.covered_from.clone(),
                });
            }
            // A recent failure is reported from here rather than by dialling
            // again. Nothing about being signed out changes in a second.
            if let Some((message, at)) = &c.last_error {
                if at.elapsed() < RETRY_AFTER {
                    return Err(FetchError::new(message.clone()));
                }
            }
        }
    }

    // A whole column wider than the grid asks for, so the first partial week
    // is complete rather than starting mid-week.
    let span = (weeks.clamp(1, 53) * 7 + 7) as i64;
    let from = today
        .checked_add(jiff::Span::new().days(-span))
        .map_err(|e| FetchError::new(e.to_string()))?
        .to_string();
    let to = today.to_string();

    match profile::account_series(None, Some(&from), Some(&to), None) {
        Ok(result) => {
            if let Ok(mut guard) = cache().lock() {
                *guard = Some(Cache {
                    rows: result.rows.clone(),
                    covered_from: result.from.clone(),
                    fetched_at: Instant::now(),
                    last_error: None,
                });
            }
            Ok(Fetched {
                rows: result.rows,
                covered_from: result.from,
            })
        }
        Err(e) => {
            let message = e.to_string();
            if let Ok(mut guard) = cache().lock() {
                match guard.as_mut() {
                    // Keep the rows that are already there. A grid that was
                    // right ten minutes ago beats an empty one, as long as the
                    // caller is told the refresh failed.
                    Some(c) => c.last_error = Some((message.clone(), Instant::now())),
                    None => {
                        *guard = Some(Cache {
                            rows: Vec::new(),
                            covered_from: None,
                            fetched_at: Instant::now() - FRESH_FOR,
                            last_error: Some((message.clone(), Instant::now())),
                        })
                    }
                }
            }
            Err(FetchError::new(message))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_auth_failure_is_expected_and_actionable() {
        // A front end turns `Authentication` into a sign-in button rather than
        // an error banner, so the two revoked-token strings must classify
        // the same way whether they come from the keychain or the server.
        for message in [
            tokenstat_sync::profile::NOT_LOGGED_IN.to_string(),
            tokenstat_sync::profile::TOKEN_REVOKED.to_string(),
        ] {
            let error = FetchError::new(message);
            assert!(error.expected);
            assert_eq!(error.reason, FailureReason::Authentication);
        }
    }

    #[test]
    fn a_plan_limitation_is_expected_but_not_an_auth_problem() {
        // "Your plan does not include this" is a settled fact about the
        // account, not a fault, but signing in again would not fix it.
        let error =
            FetchError::new("the account refused this request (403): upgrade_required".to_string());
        assert!(error.expected);
        assert_eq!(error.reason, FailureReason::UpgradeRequired);
    }

    #[test]
    fn a_real_failure_is_neither_expected_nor_an_auth_problem() {
        let error = FetchError::new("usage request failed (500): boom".to_string());
        assert!(!error.expected);
        assert_eq!(error.reason, FailureReason::Other);
    }
}
