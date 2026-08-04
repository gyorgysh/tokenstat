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

    let max = parsed
        .iter()
        .filter(|(d, _)| *d >= start)
        .map(|(_, v)| *v)
        .max()
        .unwrap_or(1)
        .max(1);

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
            level: heat_level(value, max),
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

fn heat_level(v: u64, max: u64) -> u8 {
    if v == 0 {
        0
    } else {
        // Fourth root spreads the low end out, so a quiet day is still
        // distinguishable from an empty one.
        let ratio = (v as f64 / max as f64).powf(0.25);
        ((ratio * 4.0).ceil() as u8).clamp(1, 4)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Wednesday 2026-07-29, the anchor most of these cases hang off.
    fn anchor() -> jiff::civil::Date {
        jiff::civil::date(2026, 7, 29)
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
}
