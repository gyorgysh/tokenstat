// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Vendor-reported hourly totals, kept only where the archive falls short.
//!
//! Some vendors stop exposing individual requests and report token totals per
//! hour instead. Cursor accounts on xAI's unified billing are the case that
//! needs this: their November usage exists only as hourly totals, while their
//! October usage is in the archive twice over if both are stored as is (once
//! as request events, once inside the totals).
//!
//! So a vendor total never stands beside what the archive already has. For
//! each source and UTC day, it adds only the remainder: the vendor's figure
//! for that day minus every token the archive already holds for that source on
//! that day from anywhere else. A day the archive already covers adds nothing.
//! A day it does not cover gets the vendor's hours, scaled down by whatever
//! part of the day is already known.
//!
//! The remainder rows for a day are replaced as a unit, inside one
//! transaction, so a later fetch can shrink them when a better source fills
//! the same day in. Nothing outside those rows is touched.

use std::collections::BTreeMap;

use rusqlite::params;

use super::Store;
use crate::error::CoreError;
use crate::model::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp, UsageEvent,
};

const DAY_MS: i64 = 86_400_000;

/// One hour of one model's usage, as the vendor states it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VendorHour {
    /// The tool this usage belongs to in reports.
    pub source: SourceId,
    /// Start of the hour, UTC milliseconds.
    pub hour_start_ms: i64,
    pub model: String,
    /// The project these rows report under.
    pub project: String,
    /// Every token the vendor counted, cache included. The vendor gives no
    /// split, so this is all that is known.
    pub tokens: u64,
    pub billing: BillingMode,
}

impl Store {
    /// Store vendor hourly totals as remainder rows, one UTC day at a time.
    ///
    /// `prefix` names the feed, and each day's rows carry the session
    /// `<prefix>:<YYYY-MM-DD>`. Every (source, day) that appears in `hours`, including a day
    /// whose hours are all zero, is recomputed: its old remainder rows are
    /// deleted and the new remainder is written. Returns the rows written.
    pub fn reconcile_vendor_hours(
        &mut self,
        prefix: &str,
        hours: &[VendorHour],
        tz: &jiff::tz::TimeZone,
    ) -> Result<u64, CoreError> {
        let mut days: BTreeMap<(SourceId, i64), Vec<&VendorHour>> = BTreeMap::new();
        for hour in hours {
            let day = hour.hour_start_ms.div_euclid(DAY_MS) * DAY_MS;
            days.entry((hour.source, day)).or_default().push(hour);
        }

        let tx = self.conn.transaction()?;
        let mut rows = Vec::new();
        for ((source, day_ms), day_hours) in days {
            let session = format!("{prefix}:{}", utc_day(day_ms));
            tx.execute(
                "DELETE FROM event WHERE source = ?1 AND session = ?2",
                params![source.as_str(), session],
            )?;
            let vendor: u64 = day_hours.iter().map(|h| h.tokens).sum();
            if vendor == 0 {
                continue;
            }
            let known: i64 = tx.query_row(
                "SELECT COALESCE(SUM(COALESCE(input_fresh, 0) + COALESCE(cache_read, 0)
                        + COALESCE(cache_write_5m, 0) + COALESCE(cache_write_1h, 0)
                        + COALESCE(output, 0)), 0)
                   FROM event
                  WHERE source = ?1 AND ts_ms >= ?2 AND ts_ms < ?3",
                params![source.as_str(), day_ms, day_ms + DAY_MS],
                |row| row.get(0),
            )?;
            let known = u64::try_from(known).unwrap_or(0);
            if known >= vendor {
                continue;
            }
            let remainder = vendor - known;
            let mut allocated = 0u64;
            let mut cumulative = 0u64;
            for (index, hour) in day_hours.iter().enumerate().filter(|(_, h)| h.tokens > 0) {
                // Scale each hour by the same share, in 128 bits so a large
                // day cannot overflow. Cumulative rounding preserves the total.
                cumulative += hour.tokens;
                let target =
                    (u128::from(cumulative) * u128::from(remainder) / u128::from(vendor)) as u64;
                let tokens = target - allocated;
                allocated = target;
                if tokens == 0 {
                    continue;
                }
                rows.push(UsageEvent {
                    id: EventId::derive(&[
                        prefix,
                        source.as_str(),
                        &hour.hour_start_ms.to_string(),
                        &hour.model,
                        &index.to_string(),
                    ]),
                    source,
                    ts: Timestamp::from_ms(hour.hour_start_ms),
                    model: hour.model.clone(),
                    session: session.clone(),
                    project: hour.project.clone(),
                    counters: Counters {
                        input_fresh: Some(tokens),
                        cache_read: None,
                        cache_write_5m: None,
                        cache_write_1h: None,
                        output: None,
                    },
                    extras: Extras::default(),
                    billing: hour.billing,
                    confidence: Confidence::Derived,
                });
            }
        }
        let written = Self::insert_events_in_tx(&tx, &rows, tz)?;
        tx.commit()?;
        Ok(written)
    }
}

fn utc_day(day_ms: i64) -> String {
    jiff::Timestamp::from_millisecond(day_ms)
        .map(|t| t.strftime("%Y-%m-%d").to_string())
        .unwrap_or_else(|_| day_ms.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOV_10: i64 = 1_794_268_800_000; // 2026-11-10T00:00:00Z

    fn hour(source: SourceId, offset_h: i64, model: &str, tokens: u64) -> VendorHour {
        VendorHour {
            source,
            hour_start_ms: NOV_10 + offset_h * 3_600_000,
            model: model.into(),
            project: "p".into(),
            tokens,
            billing: BillingMode::Plan,
        }
    }

    fn request(id: &str, ts_ms: i64, tokens: u64) -> UsageEvent {
        UsageEvent {
            id: EventId::derive(&[id]),
            source: SourceId::Cursor,
            ts: Timestamp::from_ms(ts_ms),
            model: "composer".into(),
            session: "cursor:conv".into(),
            project: "cursor".into(),
            counters: Counters {
                input_fresh: Some(tokens),
                ..Counters::default()
            },
            extras: Extras::default(),
            billing: BillingMode::Plan,
            confidence: Confidence::Strong,
        }
    }

    fn total(store: &Store, source: SourceId) -> i64 {
        store
            .conn
            .query_row(
                "SELECT COALESCE(SUM(input_fresh), 0) FROM event WHERE source = ?1",
                [source.as_str()],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[test]
    fn a_day_with_no_requests_takes_the_vendor_hours_as_they_are() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let hours = [
            hour(SourceId::Cursor, 3, "a", 100),
            hour(SourceId::Cursor, 9, "b", 300),
            hour(SourceId::Cursor, 10, "b", 0),
        ];
        let n = store
            .reconcile_vendor_hours("cursor-daily", &hours, &tz)
            .unwrap();
        assert_eq!(n, 2);
        assert_eq!(total(&store, SourceId::Cursor), 400);
    }

    #[test]
    fn a_day_the_requests_already_cover_adds_nothing() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        store
            .insert_events(&[request("r", NOV_10 + 5 * 3_600_000, 450)], &tz)
            .unwrap();
        store
            .reconcile_vendor_hours("cursor-daily", &[hour(SourceId::Cursor, 5, "a", 440)], &tz)
            .unwrap();
        assert_eq!(total(&store, SourceId::Cursor), 450);
    }

    #[test]
    fn a_partly_covered_day_adds_only_the_remainder() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        store
            .insert_events(&[request("r", NOV_10 + 3_600_000, 100)], &tz)
            .unwrap();
        let hours = [
            hour(SourceId::Cursor, 1, "a", 200),
            hour(SourceId::Cursor, 2, "a", 200),
        ];
        store
            .reconcile_vendor_hours("cursor-daily", &hours, &tz)
            .unwrap();
        assert_eq!(total(&store, SourceId::Cursor), 400);
    }

    #[test]
    fn refetching_replaces_a_day_instead_of_stacking_it() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        for tokens in [500, 800, 800] {
            store
                .reconcile_vendor_hours(
                    "cursor-daily",
                    &[hour(SourceId::Cursor, 4, "a", tokens)],
                    &tz,
                )
                .unwrap();
        }
        assert_eq!(total(&store, SourceId::Cursor), 800);
        // A later request import shrinks the day back to the remainder.
        store
            .insert_events(&[request("r", NOV_10 + 4 * 3_600_000, 800)], &tz)
            .unwrap();
        store
            .reconcile_vendor_hours("cursor-daily", &[hour(SourceId::Cursor, 4, "a", 800)], &tz)
            .unwrap();
        assert_eq!(total(&store, SourceId::Cursor), 800);
    }

    #[test]
    fn sources_are_reconciled_separately() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        store
            .insert_events(&[request("r", NOV_10, 1_000)], &tz)
            .unwrap();
        store
            .reconcile_vendor_hours(
                "cursor-daily",
                &[hour(SourceId::Grok, 7, "grok-build", 640)],
                &tz,
            )
            .unwrap();
        assert_eq!(total(&store, SourceId::Grok), 640);
        assert_eq!(total(&store, SourceId::Cursor), 1_000);
    }

    #[test]
    fn duplicate_series_and_rounding_preserve_the_remainder() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        store
            .insert_events(&[request("r", NOV_10, 1)], &tz)
            .unwrap();
        let hours = [
            hour(SourceId::Cursor, 1, "a", 1),
            hour(SourceId::Cursor, 1, "a", 1),
            hour(SourceId::Cursor, 1, "a", 1),
        ];
        store
            .reconcile_vendor_hours("cursor-daily", &hours, &tz)
            .unwrap();
        assert_eq!(total(&store, SourceId::Cursor), 3);
    }
}
