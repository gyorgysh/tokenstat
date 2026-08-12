// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The activity calendar: a day grid, its heat levels, and the streaks.
//!
//! This lived in the CLI, next to the code that draws it in a terminal. That
//! was fine while the CLI was the only thing that drew it. The desktop app
//! shows the same grid on its Home screen, and a second implementation in Swift
//! would be a second answer to "how long is my streak", disagreeing with the
//! first at the edges nobody tests.
//!
//! So the calendar is computed here and drawn by whoever asked. What stayed
//! behind in the CLI is the part that is genuinely about a terminal: the column
//! width, the month header string, and the weekday gutter labels.

use crate::pricing::{EquivalentValue, PriceTable, display_usage_model_id};
use crate::store::SplitBucket;

/// List-rate spend per calendar day, in microdollars, ready for [`calendar`].
///
/// The heat ramp is money rather than tokens, so a day of cheap high-volume
/// completions does not out-burn a day on an expensive model. Pricing runs on
/// the day x model split because a date cannot be looked up as a model, and a
/// day bucket on its own has no rate to apply.
///
/// A day whose models are all unpriced comes back as zero and draws idle. That
/// is the honest answer: with no rate there is no spend to show.
pub fn cost_by_day(split: &[SplitBucket], prices: &PriceTable) -> Vec<(String, u64)> {
    let mut out: Vec<(String, u64)> = Vec::new();
    let mut index: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for row in split {
        let lookup = display_usage_model_id(&row.split);
        let micros = EquivalentValue::price(prices, &lookup, &row.counters)
            .map(|v| v.micros().max(0) as u64)
            .unwrap_or(0);
        match index.get(row.key.as_str()) {
            Some(&i) => out[i].1 = out[i].1.saturating_add(micros),
            None => {
                index.insert(row.key.as_str(), out.len());
                out.push((row.key.clone(), micros));
            }
        }
    }
    out
}

/// Today, in the user's timezone.
///
/// The calendar anchors on this rather than on the newest day with data, so a
/// quiet week reads as a quiet week instead of the grid quietly ending early.
/// Here rather than in each caller so that a front end does not need its own
/// date library to ask a question the archive already knows the answer to.
pub fn today(tz: &jiff::tz::TimeZone) -> jiff::civil::Date {
    jiff::Timestamp::now().to_zoned(tz.clone()).date()
}

/// One day in the activity calendar.
#[derive(Debug, Clone, Copy)]
pub struct HeatCell {
    pub date: jiff::civil::Date,
    pub value: u64,
    /// Heat level `0..=4`. Level 0 means the day is inside the range but idle.
    pub level: u8,
    /// The day was worked and its usage is not known.
    ///
    /// Distinct from level 0, and the distinction is the whole point: a day off
    /// and a day whose transcripts were deleted before the first scan both have
    /// no tokens, and drawing them the same way tells the reader the second one
    /// did not happen. Set from a vendor's own activity record, which outlives
    /// its token counts.
    pub unmeasured: bool,
}

impl HeatCalendar {
    /// Mark days that were worked but have no measurable usage.
    ///
    /// Applied after building rather than passed in, so every caller that has
    /// no such list is unaffected and keeps the grid it already drew.
    pub fn mark_unmeasured(&mut self, dates: &[String]) {
        use std::collections::HashSet;
        let want: HashSet<jiff::civil::Date> = dates
            .iter()
            .filter_map(|d| d.parse::<jiff::civil::Date>().ok())
            .collect();
        if want.is_empty() {
            return;
        }
        let mut marked = false;
        for row in &mut self.rows {
            for cell in row.iter_mut().flatten() {
                if cell.value == 0 && want.contains(&cell.date) {
                    cell.unmeasured = true;
                    marked = true;
                }
            }
        }
        if marked {
            self.recount();
        }
    }

    /// Redo the counts that treat a day as worked or not.
    ///
    /// Marking a cell is not a drawing change. "Active days" and both streaks
    /// answer *was this day worked*, and for a day whose transcripts were
    /// deleted the answer is yes on the vendor's own record. Leaving them out
    /// reported 50 active days out of 57 and broke a 57 day streak into 47,
    /// which reads as a week off that never happened.
    ///
    /// Spend is deliberately untouched: those days are worked and unpriced, and
    /// a total is a floor rather than wrong.
    fn recount(&mut self) {
        let mut days: Vec<(jiff::civil::Date, bool)> = self
            .rows
            .iter()
            .flatten()
            .flatten()
            .map(|c| (c.date, c.value > 0 || c.unmeasured))
            .collect();
        days.sort_by_key(|(d, _)| *d);
        self.active_days = days.iter().filter(|(_, worked)| *worked).count();
        let mut run = 0usize;
        let mut best = 0usize;
        for (date, worked) in &days {
            if *worked {
                run += 1;
                best = best.max(run);
            } else if *date < self.last {
                // Same rule as the build: today being quiet is not a break,
                // because the day is not over.
                run = 0;
            }
            self.streak_current = run;
        }
        self.streak_best = best;
    }

    /// How many days in this grid were worked without a usable measurement.
    pub fn unmeasured_days(&self) -> usize {
        self.rows
            .iter()
            .flatten()
            .flatten()
            .filter(|c| c.unmeasured)
            .count()
    }
}

/// A calendar-aligned activity grid, newest week last.
///
/// The point of the calendar, rather than a packed run of active days, is that
/// a column really is a week and a row really is a weekday. Days with no usage
/// have to be filled in, because the archive only stores days that had events
/// and rendering those back to back silently shifts every later column.
#[derive(Debug, Clone)]
pub struct HeatCalendar {
    /// Seven rows, Monday first. `None` is outside the rendered range.
    pub rows: Vec<Vec<Option<HeatCell>>>,
    /// `(column, short month name)` for the header strip.
    pub months: Vec<(usize, &'static str)>,
    pub weeks: usize,
    pub total: u64,
    pub active_days: usize,
    /// Consecutive active days ending on the most recent day with data.
    pub streak_current: usize,
    /// Longest run of consecutive active days in the rendered range.
    pub streak_best: usize,
    pub busiest: Option<HeatCell>,
    pub first: jiff::civil::Date,
    pub last: jiff::civil::Date,
}

impl HeatCalendar {
    /// Every rendered day, oldest first. The grid is stored row-major for
    /// drawing, so consumers that want a date series come through here.
    pub fn days(&self) -> impl Iterator<Item = &HeatCell> {
        (0..self.weeks).flat_map(move |c| (0..7).filter_map(move |r| self.rows[r][c].as_ref()))
    }
}

/// Build the calendar from `(YYYY-MM-DD, value)` pairs in any order.
///
/// The grid is a fixed window of `weeks` columns ending on `anchor`, so the
/// usual call is a rolling twelve months: the archive can hold years, the grid
/// shows the last 53 weeks and pads the quiet ones with idle cells rather than
/// shrinking. Days after `anchor` are left blank instead of reading as idle.
pub fn calendar(
    days: &[(String, u64)],
    weeks: usize,
    anchor: jiff::civil::Date,
) -> Option<HeatCalendar> {
    use jiff::civil::Date;

    let mut parsed: Vec<(Date, u64)> = days
        .iter()
        .filter_map(|(d, v)| d.parse::<Date>().ok().map(|d| (d, *v)))
        .collect();
    if parsed.is_empty() {
        return None;
    }
    parsed.sort_by_key(|(d, _)| *d);

    let last = anchor;
    let weeks = weeks.clamp(1, 53);

    // Grid edges: end on the Sunday of the anchor's week, start on a Monday.
    let end = shift_days(
        anchor,
        6 - i64::from(anchor.weekday().to_monday_zero_offset()),
    );
    let start = shift_days(end, -((weeks * 7 - 1) as i64));

    let scale = Scale::from_days(parsed.iter().filter(|(d, _)| *d >= start).map(|(_, v)| *v));

    let span = (days_between(start, end) as usize) + 1;
    let cols = span.div_ceil(7);
    let mut total = 0u64;
    let mut active_days = 0usize;
    let mut busiest: Option<HeatCell> = None;
    let mut run = 0usize;
    let mut streak_best = 0usize;
    let mut streak_current = 0usize;

    // One ascending walk over the calendar. `parsed` is ascending too, so the
    // lookup advances alongside it instead of searching per day.
    let mut lookup = parsed.iter().peekable();
    let mut cells: Vec<Option<HeatCell>> = Vec::with_capacity(span);
    let mut date = start;
    for _ in 0..span {
        if date > anchor {
            cells.push(None);
            date = shift_days(date, 1);
            continue;
        }
        let mut value = 0u64;
        while let Some((d, v)) = lookup.peek() {
            if *d < date {
                lookup.next();
            } else if *d == date {
                value += *v;
                lookup.next();
            } else {
                break;
            }
        }
        let cell = HeatCell {
            date,
            value,
            level: scale.level(value),
            unmeasured: false,
        };
        if value > 0 {
            total += value;
            active_days += 1;
            run += 1;
            streak_best = streak_best.max(run);
            if busiest.is_none_or(|b| value > b.value) {
                busiest = Some(cell);
            }
        } else if date < last {
            // A quiet anchor day does not break the streak. The day is not
            // over yet, and reporting "0 day streak" every morning is wrong.
            run = 0;
        }
        streak_current = run;
        cells.push(Some(cell));
        date = shift_days(date, 1);
    }

    let rows: Vec<Vec<Option<HeatCell>>> = (0..7)
        .map(|r| {
            (0..cols)
                .map(|c| cells.get(c * 7 + r).copied().flatten())
                .collect()
        })
        .collect();
    let months: Vec<(usize, &'static str)> = (0..cols).fold(Vec::new(), |mut acc, col| {
        let monday = shift_days(start, (col * 7) as i64);
        if let Some(name) = month_label(monday, col, acc.last()) {
            acc.push((col, name));
        }
        acc
    });

    Some(HeatCalendar {
        rows,
        months,
        weeks: cols,
        total,
        active_days,
        streak_current,
        streak_best,
        busiest,
        first: start,
        last,
    })
}

/// Month name for a column, or `None` when the label would repeat or crowd the
/// previous one. Three-character names need two columns of clearance.
fn month_label(
    monday: jiff::civil::Date,
    col: usize,
    prev: Option<&(usize, &'static str)>,
) -> Option<&'static str> {
    const NAMES: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let name = NAMES[(monday.month() as usize) - 1];
    match prev {
        Some((_, p)) if *p == name => None,
        Some((c, _)) if col.saturating_sub(*c) < 2 => None,
        _ => Some(name),
    }
}

fn shift_days(d: jiff::civil::Date, n: i64) -> jiff::civil::Date {
    d.checked_add(jiff::Span::new().days(n)).unwrap_or(d)
}

fn days_between(a: jiff::civil::Date, b: jiff::civil::Date) -> i64 {
    b.since(a).map(|s| s.get_days() as i64).unwrap_or(0)
}

/// Where the four shades change, taken from the days themselves.
///
/// Scaling against the maximum does not work here. One expensive day sets the
/// ceiling and, with a fourth root to lift the low end, everything from a tenth
/// of that day upwards landed on the top two shades: a $44 day and a $144 day
/// drew the same square while the grid as a whole read as uniformly hot.
///
/// So the shades are quartiles of the active days instead. A quarter of the
/// days you worked sit in each shade whatever the amounts are, which is what
/// makes a busy month look different from a quiet one rather than every month
/// looking like its own busiest day.
#[derive(Debug, Clone, Copy)]
struct Scale {
    /// Upper bound of levels 1, 2 and 3. A day above the last one is level 4.
    breaks: [u64; 3],
}

impl Scale {
    fn from_days(values: impl Iterator<Item = u64>) -> Self {
        let mut active: Vec<u64> = values.filter(|v| *v > 0).collect();
        active.sort_unstable();
        if active.is_empty() {
            return Self { breaks: [0; 3] };
        }
        // Nearest-rank quartiles. With very few active days the ranks collide,
        // which is correct: three days of work cannot fill four shades, and
        // spreading them out would invent a difference that is not there.
        let at = |q: f64| -> u64 {
            let last = active.len() - 1;
            let rank = ((active.len() as f64) * q).ceil() as usize;
            active[rank.saturating_sub(1).min(last)]
        };
        Self {
            breaks: [at(0.25), at(0.5), at(0.75)],
        }
    }

    fn level(&self, value: u64) -> u8 {
        if value == 0 {
            return 0;
        }
        match self.breaks.iter().position(|b| value <= *b) {
            Some(i) => (i as u8) + 1,
            None => 4,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Wednesday 2026-07-29, the anchor most of these cases hang off.
    fn anchor() -> jiff::civil::Date {
        jiff::civil::date(2026, 7, 29)
    }

    const PRICES: &str = r#"{
      "effective_from": "2026-07-29",
      "models": [
        {"match":"claude-opus-4-5","input":5.0,"output":25.0,"cache_read":0.5,"cache_write_5m":6.25,"cache_write_1h":10.0}
      ]
    }"#;

    fn split(day: &str, model: &str, input: u64, output: u64) -> SplitBucket {
        SplitBucket {
            key: day.to_string(),
            split: model.to_string(),
            counters: crate::model::Counters {
                input_fresh: Some(input),
                output: Some(output),
                ..Default::default()
            },
            events: 1,
            sessions: 1,
        }
    }

    #[test]
    fn a_day_costs_the_sum_of_its_models() {
        let prices = PriceTable::parse(PRICES).unwrap();
        let rows = [
            split("2026-07-29", "claude-opus-4-5", 1_000_000, 0),
            split("2026-07-29", "claude-opus-4-5", 0, 1_000_000),
            split("2026-07-28", "claude-opus-4-5", 1_000_000, 0),
        ];
        let costs = cost_by_day(&rows, &prices);
        assert_eq!(
            costs,
            vec![
                ("2026-07-29".to_string(), 30_000_000),
                ("2026-07-28".to_string(), 5_000_000),
            ]
        );
    }

    #[test]
    fn an_unpriced_model_contributes_nothing_rather_than_a_guess() {
        let prices = PriceTable::parse(PRICES).unwrap();
        let rows = [split(
            "2026-07-29",
            "some-unknown-model",
            1_000_000,
            1_000_000,
        )];
        assert_eq!(
            cost_by_day(&rows, &prices),
            vec![("2026-07-29".to_string(), 0)]
        );
    }

    #[test]
    fn marking_a_day_worked_makes_it_count_as_worked() {
        // The whole point: "active days" and the streaks answer *was this day
        // worked*, and for a day whose transcripts were deleted the answer is
        // yes. Marking used to change only the drawing, which reported 50
        // active days out of 57 and split one streak into two.
        let days: Vec<_> = (1..=14)
            .filter(|d| !(6..=8).contains(d))
            .map(|d| (format!("2026-07-{d:02}"), 100u64))
            .collect();
        let mut cal = calendar(&days, 4, jiff::civil::date(2026, 7, 14)).expect("calendar");
        assert_eq!(cal.active_days, 11);
        assert_eq!(cal.streak_best, 6);

        cal.mark_unmeasured(&[
            "2026-07-06".to_string(),
            "2026-07-07".to_string(),
            "2026-07-08".to_string(),
        ]);
        assert_eq!(cal.unmeasured_days(), 3);
        assert_eq!(cal.active_days, 14);
        assert_eq!(cal.streak_best, 14);
        // Spend is untouched: those days are worked and unpriced, so the total
        // is a floor rather than wrong.
        assert_eq!(cal.total, 1100);
    }

    #[test]
    fn marking_a_day_that_already_has_usage_changes_nothing() {
        let days: Vec<_> = (1..=10)
            .map(|d| (format!("2026-07-{d:02}"), 100u64))
            .collect();
        let mut cal = calendar(&days, 4, jiff::civil::date(2026, 7, 10)).expect("calendar");
        let before = (cal.active_days, cal.streak_best, cal.total);
        cal.mark_unmeasured(&["2026-07-05".to_string()]);
        assert_eq!(cal.unmeasured_days(), 0);
        assert_eq!((cal.active_days, cal.streak_best, cal.total), before);
    }

    #[test]
    fn calendar_has_seven_rows_and_whole_weeks() {
        let days: Vec<_> = (1..=28)
            .map(|d| (format!("2026-07-{d:02}"), d as u64 * 100))
            .collect();
        let cal = calendar(&days, 5, anchor()).expect("calendar");
        assert_eq!(cal.rows.len(), 7);
        assert_eq!(cal.weeks, 5);
        assert!(cal.rows.iter().all(|r| r.len() == cal.weeks));
    }

    #[test]
    fn calendar_puts_each_day_in_its_real_weekday_row() {
        let days = vec![("2026-07-29".to_string(), 10)];
        let cal = calendar(&days, 4, anchor()).expect("calendar");
        // 2026-07-29 is a Wednesday: row 2, Monday first.
        let found = cal.rows[2]
            .iter()
            .flatten()
            .find(|c| c.value == 10)
            .expect("cell");
        assert_eq!(found.date.to_string(), "2026-07-29");
    }

    #[test]
    fn calendar_holds_the_window_open_when_the_archive_is_young() {
        // A week-old archive still renders a full rolling year of idle cells,
        // rather than collapsing to the days that happen to have data.
        let days = vec![("2026-07-27".to_string(), 5)];
        let cal = calendar(&days, 53, anchor()).expect("calendar");
        assert_eq!(cal.weeks, 53);
        assert_eq!(cal.active_days, 1);
        // A year back from the anchor week: starts in the previous August.
        assert_eq!(cal.first.to_string(), "2025-07-28");
        assert_eq!(cal.months.first().map(|m| m.1), Some("Jul"));
    }

    #[test]
    fn calendar_leaves_days_after_the_anchor_blank() {
        // The rest of this week has not happened. Blank, not idle.
        let days = vec![("2026-07-29".to_string(), 5)];
        let cal = calendar(&days, 2, anchor()).expect("calendar");
        let last_col = cal.weeks - 1;
        assert!(cal.rows[2][last_col].is_some(), "Wednesday is the anchor");
        assert!(cal.rows[3][last_col].is_none(), "Thursday is the future");
        assert!(cal.rows[6][last_col].is_none(), "Sunday is the future");
    }

    #[test]
    fn calendar_fills_gaps_between_active_days() {
        // The archive stores only active days. The grid must still show the
        // idle days between them, or every later column drifts.
        let days = vec![("2026-07-06".to_string(), 5), ("2026-07-10".to_string(), 7)];
        let cal = calendar(&days, 4, jiff::civil::date(2026, 7, 12)).expect("calendar");
        assert_eq!(cal.active_days, 2);
        assert_eq!(cal.total, 12);
        assert_eq!(cal.busiest.map(|b| b.value), Some(7));
        // Mon and Fri active, Tue to Thu idle: no run longer than one day.
        assert_eq!(cal.streak_best, 1);
    }

    #[test]
    fn calendar_counts_the_trailing_streak() {
        let days: Vec<_> = (20..=24)
            .map(|d| (format!("2026-07-{d:02}"), 100u64))
            .collect();
        let cal = calendar(&days, 4, jiff::civil::date(2026, 7, 24)).expect("calendar");
        assert_eq!(cal.streak_current, 5);
        assert_eq!(cal.streak_best, 5);
    }

    #[test]
    fn a_quiet_anchor_day_does_not_break_the_streak() {
        // Worked through yesterday, nothing logged yet today. The day is not
        // over, so the streak stands.
        let days: Vec<_> = (26..=28)
            .map(|d| (format!("2026-07-{d:02}"), 100u64))
            .collect();
        let cal = calendar(&days, 4, anchor()).expect("calendar");
        assert_eq!(cal.streak_current, 3);
        // Two idle days before the anchor do break it.
        let cal = calendar(&days, 4, jiff::civil::date(2026, 7, 30)).expect("calendar");
        assert_eq!(cal.streak_current, 0);
    }

    #[test]
    fn calendar_handles_empty_input() {
        assert!(calendar(&[], 5, anchor()).is_none());
    }

    #[test]
    fn the_shades_split_the_active_days_evenly() {
        // Twelve active days, so three per shade. Scaling against the maximum
        // put nine of these twelve on the top two shades.
        let values: Vec<u64> = (1..=12).map(|n| n * 10).collect();
        let scale = Scale::from_days(values.iter().copied());
        let levels: Vec<u8> = values.iter().map(|v| scale.level(*v)).collect();
        assert_eq!(levels, vec![1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4]);
        assert_eq!(scale.level(0), 0, "an idle day is not a quiet day");
    }

    #[test]
    fn one_expensive_day_does_not_flatten_the_rest() {
        // The case that started this: a run of ordinary days and one that cost
        // ten times as much. The ordinary days must still differ from each
        // other rather than all collapsing into the bottom shade, and $44 and
        // $144 must not draw the same square.
        let values = [10u64, 20, 44, 144, 300];
        let scale = Scale::from_days(values.iter().copied());
        let levels: Vec<u8> = values.iter().map(|v| scale.level(*v)).collect();
        assert!(
            levels.windows(2).all(|w| w[0] <= w[1]),
            "shades rise with the amount: {levels:?}"
        );
        assert_ne!(scale.level(44), scale.level(144));
        assert_eq!(scale.level(300), 4);
    }

    #[test]
    fn too_few_days_to_fill_the_shades_is_not_an_invented_difference() {
        // Two active days cannot honestly occupy four shades, so some of them
        // stay empty rather than the two days being pushed apart.
        let scale = Scale::from_days([5u64, 9].into_iter());
        assert!(scale.level(5) < scale.level(9));
        assert!(scale.level(9) <= 4);
        assert_eq!(scale.level(0), 0);
    }
}
