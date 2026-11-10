// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Home presentation state. Calendar placement, levels and totals belong to the host.

pub mod day;
pub mod layout;
pub mod plans;
pub mod scan;
pub mod work;

use crate::{design::heatmap, localization};
use serde::{Deserialize, Serialize};

fn optional_bool<'de, D: serde::Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(Option::<bool>::deserialize(d)?.unwrap_or(false))
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityScope {
    ThisMachine,
    #[default]
    AllMachines,
}

impl ActivityScope {
    pub const ALL: [Self; 2] = [Self::ThisMachine, Self::AllMachines];
    pub fn wire(self) -> &'static str {
        match self {
            Self::ThisMachine => "local",
            Self::AllMachines => "account",
        }
    }
    pub fn label_key(self) -> &'static str {
        match self {
            Self::ThisMachine => "apple.homemodel.this_device.d052579c",
            Self::AllMachines => "apple.homemodel.all_devices.0594fe82",
        }
    }
    pub fn symbol(self) -> &'static str {
        match self {
            Self::ThisMachine => "laptopcomputer",
            Self::AllMachines => "network",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeatCell {
    pub date: String,
    pub value: u64,
    pub level: i32,
    #[serde(default, deserialize_with = "optional_bool")]
    pub locked: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MonthLabel {
    pub column: usize,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Calendar {
    pub rows: Vec<Vec<Option<HeatCell>>>,
    pub months: Vec<MonthLabel>,
    pub weeks: usize,
    pub total: u64,
    pub active_days: usize,
    pub streak_current: usize,
    pub streak_best: usize,
    pub busiest: Option<HeatCell>,
    pub first: String,
    pub last: String,
    pub scope: Option<String>,
    pub notice: Option<String>,
    pub notice_code: Option<String>,
    pub fetched_at_ms: Option<i64>,
    pub unlock_from: Option<String>,
    #[serde(default, deserialize_with = "optional_bool")]
    pub history_locked: bool,
    pub history_days: Option<u16>,
    #[serde(default, deserialize_with = "optional_bool")]
    pub history_upgrade: bool,
}

impl Calendar {
    pub fn sorted_days(&self) -> Vec<&HeatCell> {
        let mut days: Vec<_> = self
            .rows
            .iter()
            .flatten()
            .filter_map(Option::as_ref)
            .collect();
        days.sort_by(|a, b| a.date.cmp(&b.date));
        days
    }
    pub fn today_value(&self) -> String {
        format_spend(
            self.sorted_days()
                .into_iter()
                .rev()
                .find(|d| d.date == self.last)
                .map(|d| d.value)
                .unwrap_or(0),
        )
    }
    pub fn week_value(&self) -> String {
        let days = self.sorted_days();
        format_spend(
            days.into_iter()
                .rev()
                .take(7)
                .fold(0_u64, |total, day| total.saturating_add(day.value)),
        )
    }
    pub fn delivered_scope(&self) -> ActivityScope {
        if self.scope.as_deref() == Some("account") {
            ActivityScope::AllMachines
        } else {
            ActivityScope::ThisMachine
        }
    }
    pub fn cell(&self, date: &str) -> Option<&HeatCell> {
        self.rows
            .iter()
            .flatten()
            .flatten()
            .find(|cell| cell.date == date)
    }
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            (1..=53).contains(&self.weeks)
                && !self.rows.is_empty()
                && self.rows.len() <= 7
                && self.rows.iter().all(|row| row.len() <= self.weeks),
            "The host returned an invalid activity grid"
        );
        Ok(())
    }

    /// A synthetic year is built by the real shared calendar code, never by a
    /// second GUI calendar implementation. No logs, identity or archive are opened.
    pub fn fixture(scope: ActivityScope) -> anyhow::Result<Self> {
        let days = [
            ("2025-12-04", 800_000),
            ("2026-02-16", 1_400_000),
            ("2026-04-03", 7_300_000),
            ("2026-06-16", 3_000_000),
            ("2026-08-11", 1_000_000),
            ("2026-09-12", 15_000_000),
            ("2026-10-24", 4_300_000),
            ("2026-11-06", 500_000),
            ("2026-11-07", 7_100_000),
            ("2026-11-08", 9_700_000),
            ("2026-11-09", 1_500_000),
        ]
        .map(|(date, value)| (date.to_owned(), value))
        .to_vec();
        let grid = tokenstat_core::activity::calendar(&days, 53, "2026-11-09".parse()?)
            .ok_or_else(|| anyhow::anyhow!("The synthetic activity fixture is empty"))?;
        let cell = |c: tokenstat_core::activity::HeatCell| HeatCell {
            date: c.date.to_string(),
            value: c.value,
            level: i32::from(c.level),
            locked: c.locked,
        };
        Ok(Self {
            rows: grid
                .rows
                .into_iter()
                .map(|row| row.into_iter().map(|c| c.map(cell)).collect())
                .collect(),
            months: grid
                .months
                .into_iter()
                .map(|(column, name)| MonthLabel {
                    column,
                    name: name.to_owned(),
                })
                .collect(),
            weeks: grid.weeks,
            total: grid.total,
            active_days: grid.active_days,
            streak_current: grid.streak_current,
            streak_best: grid.streak_best,
            busiest: grid.busiest.map(cell),
            first: grid.first.to_string(),
            last: grid.last.to_string(),
            scope: Some(scope.wire().into()),
            notice: None,
            notice_code: None,
            fetched_at_ms: None,
            unlock_from: None,
            history_locked: false,
            history_days: None,
            history_upgrade: false,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CalendarRequest {
    generation: u64,
    pub scope: ActivityScope,
}

#[derive(Debug, Default)]
pub struct HomeState {
    pub days: day::DayState,
    pub requested_scope: ActivityScope,
    pub calendar: Option<Calendar>,
    pub error: Option<String>,
    pub loading: bool,
    pub refreshing: bool,
    pub confirmed_empty: bool,
    pub selected: Option<HeatCell>,
    pub hovered: Option<HeatCell>,
    generation: u64,
}

impl HomeState {
    /// Retire both archive and day reads without reusing their request ids.
    pub fn reset_owner(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.days.invalidate(false);
        self.calendar = None;
        self.error = None;
        self.loading = false;
        self.refreshing = false;
        self.confirmed_empty = false;
        self.selected = None;
        self.hovered = None;
    }
    /// A new scope supersedes the previous request without waiting for its IO.
    pub fn begin(&mut self, scope: ActivityScope, quiet: bool) -> CalendarRequest {
        self.days.invalidate(scope == self.requested_scope);
        self.requested_scope = scope;
        self.generation = self.generation.wrapping_add(1);
        self.loading = !quiet || self.calendar.is_none();
        self.refreshing = !self.loading;
        self.confirmed_empty = false;
        self.hovered = None;
        CalendarRequest {
            generation: self.generation,
            scope,
        }
    }

    /// Stale completions cannot clear a newer spinner, scope or pinned selection.
    pub fn finish(
        &mut self,
        request: CalendarRequest,
        result: Result<Option<Calendar>, String>,
    ) -> bool {
        if request.generation != self.generation || request.scope != self.requested_scope {
            return false;
        }
        self.loading = false;
        self.refreshing = false;
        match result {
            Ok(calendar) => {
                let previous_scope = self.calendar.as_ref().map(Calendar::delivered_scope);
                let next_scope = calendar.as_ref().map(Calendar::delivered_scope);
                let date = self.selected.as_ref().map(|c| c.date.clone());
                self.confirmed_empty = calendar.is_none();
                self.calendar = calendar;
                self.error = None;
                // The source pins today once, retains a user's date on refresh,
                // and adopts fresh cell values when switching delivered scope.
                self.selected = self.calendar.as_ref().and_then(|grid| {
                    date.as_deref()
                        .and_then(|date| grid.cell(date))
                        .cloned()
                        .or_else(|| grid.cell(&grid.last).cloned())
                });
                if previous_scope != next_scope {
                    self.hovered = None;
                    self.days.invalidate(false);
                }
            }
            Err(error) => {
                self.error = Some(error);
                self.confirmed_empty = false;
            }
        }
        true
    }

    pub fn select(&mut self, day: HeatCell) {
        if !day.locked {
            self.selected = Some(day);
        }
    }
    pub fn needs_sign_in(&self) -> bool {
        self.calendar
            .as_ref()
            .is_some_and(|c| c.notice_code.as_deref() == Some("auth"))
    }
    pub fn subtitle(&self) -> String {
        let Some(grid) = &self.calendar else {
            return localization::text(
                "apple.homeview.what_each_day_was_worth_at_api_list_price.c29a2633",
                &[],
            );
        };
        let spend = format_spend(grid.total);
        let count = grid.active_days.to_string();
        let mut text = localization::text(
            "apple.homeview.0_at_api_list_price_over_1_active_days.a929a181",
            &[&spend, &count],
        );
        text.push_str(&localization::text(
            if grid.delivered_scope() == ActivityScope::AllMachines {
                "apple.homeview.across_every_device_on_your_account.de7d54ab"
            } else {
                "apple.homeview.on_this_device"
            },
            &[],
        ));
        if let Some(notice) = &grid.notice
            && !self.needs_sign_in()
        {
            text.push_str(". ");
            text.push_str(notice);
        }
        text
    }
}

/// Logical points shared by the canvas, month/day labels and pointer hit testing.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeatmapGeometry {
    pub cell: f64,
    pub gap: f64,
    pub gutter: f64,
    pub weeks: usize,
    pub rows: usize,
}
impl HeatmapGeometry {
    pub fn new(width: f64, weeks: usize, rows: usize) -> Self {
        let width = (width / 4.).round() * 4.;
        let gutter = heatmap::GUTTER;
        let ratio = heatmap::GAP_RATIO;
        let cell = if weeks == 0 || width <= 0. {
            11.
        } else {
            ((width - gutter) / (ratio + weeks as f64 * (1. + ratio))).clamp(7., heatmap::MAX_CELL)
        };
        let gap = if weeks == 0 || width <= 0. {
            cell * ratio
        } else {
            ((width - gutter - weeks as f64 * cell) / (weeks as f64 + 1.))
                .clamp(cell * ratio, cell * heatmap::MAX_GAP_RATIO)
        };
        Self {
            cell,
            gap,
            gutter,
            weeks,
            rows,
        }
    }
    pub fn stride(self) -> f64 {
        self.cell + self.gap
    }
    pub fn content_width(self) -> f64 {
        self.weeks as f64 * self.cell + self.weeks.saturating_sub(1) as f64 * self.gap
    }
    pub fn content_height(self) -> f64 {
        self.rows as f64 * self.cell + self.rows.saturating_sub(1) as f64 * self.gap
    }
    pub fn reserved_height(self) -> f64 {
        11. + self.rows as f64 * self.stride()
    }
    pub fn slot(self, x: f64, y: f64, rows: &[Vec<Option<HeatCell>>]) -> Option<(usize, usize)> {
        if x < 0. || y < 0. || !x.is_finite() || !y.is_finite() || self.cell <= 0. {
            return None;
        }
        let column = (x / self.stride()) as usize;
        let row = (y / self.stride()) as usize;
        let day = rows.get(row)?.get(column)?.as_ref()?;
        if day.locked
            || x - column as f64 * self.stride() > self.cell
            || y - row as f64 * self.stride() > self.cell
        {
            return None;
        }
        Some((row, column))
    }
}

/// Same fixed USD presentation as Money.formatted, with grouping and two decimals.
pub fn format_spend(micros: u64) -> String {
    let dollars = micros.min(i64::MAX as u64) as f64 / 1_000_000.;
    // NumberFormatter rounds decimal half-even. Multiplying the binary float
    // by 100 misrounds values such as 1.015, so round its shortest decimal form.
    let decimal = dollars.to_string();
    let fraction = decimal.split_once('.').map_or("", |(_, f)| f);
    let mut digits = fraction.bytes().map(|c| u64::from(c - b'0'));
    let minor = digits.next().unwrap_or(0) * 10 + digits.next().unwrap_or(0);
    let next = digits.next().unwrap_or(0);
    let increment = next > 5 || (next == 5 && (minor % 2 == 1 || digits.any(|n| n != 0)));
    let cents = (dollars.trunc() as u64) * 100 + minor + u64::from(increment);
    let raw = cents.to_string();
    let padded = if raw.len() < 3 {
        format!("{raw:0>3}")
    } else {
        raw
    };
    let (whole, fraction) = padded.split_at(padded.len() - 2);
    let mut grouped = String::new();
    for (index, c) in whole.chars().enumerate() {
        if index > 0 && (whole.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(c);
    }
    format!("${grouped}.{fraction}")
}

pub fn greeting_phrase(hour: u32, has_history: bool, day_of_year: i32) -> String {
    let timed = match hour {
        5..=11 => "apple.greeting.good_morning.90a90a48",
        12..=16 => "apple.greeting.good_afternoon.d325e1bb",
        17..=21 => "apple.greeting.good_evening.15a421e4",
        _ => "apple.greeting.hello.185f8db3",
    };
    let pool = [
        timed,
        "apple.greeting.hello.185f8db3",
        "apple.greeting.what_s_up.11ec53bc",
        if has_history {
            "apple.greeting.welcome_back.66212495"
        } else {
            "apple.greeting.welcome.0e2226b5"
        },
        if has_history {
            "apple.greeting.back_at_it.9ce858b7"
        } else {
            timed
        },
    ];
    localization::text(pool[day_of_year.unsigned_abs() as usize % pool.len()], &[])
}

/// Home's clock is the user's local wall clock, independent of host/archive timezone.
#[cfg(unix)]
pub fn greeting(name: Option<&str>, has_history: bool) -> String {
    let mut parts = std::mem::MaybeUninit::<libc::tm>::uninit();
    // SAFETY: time and the output tm are valid for localtime_r. The initialized
    // result is read only after the function confirms the output pointer.
    let clock = unsafe {
        let now = libc::time(std::ptr::null_mut());
        if libc::localtime_r(&now, parts.as_mut_ptr()).is_null() {
            None
        } else {
            Some(parts.assume_init())
        }
    };
    let mut phrase = clock
        .map(|tm| greeting_phrase(tm.tm_hour as u32, has_history, tm.tm_yday + 1))
        .unwrap_or_else(|| localization::text("apple.greeting.hello.185f8db3", &[]));
    if let Some(name) = name.filter(|name| !name.is_empty()) {
        phrase.push_str(", ");
        phrase.push_str(name.split_whitespace().next().unwrap_or(name.trim()));
    }
    phrase
}

#[cfg(unix)]
impl crate::client::Client {
    pub fn activity_calendar(
        &self,
        scope: ActivityScope,
        force: bool,
    ) -> anyhow::Result<Option<Calendar>> {
        self.prepare()?;
        let grid: Option<Calendar> = serde_json::from_value(self.call(
            "activity.calendar",
            serde_json::json!({"scope":scope.wire(),"force":force}),
        )?)?;
        if let Some(grid) = &grid {
            grid.validate()?;
        }
        Ok(grid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_retirement_never_reuses_a_calendar_or_day_request_identity() {
        let mut home = HomeState::default();
        let old = home.begin(ActivityScope::AllMachines, false);
        let day = HeatCell {
            date: "2026-11-09".into(),
            value: 1,
            level: 1,
            locked: false,
        };
        let detail = home
            .days
            .begin_selected(&day, ActivityScope::AllMachines)
            .unwrap();
        home.reset_owner();
        let fresh = home.begin(ActivityScope::AllMachines, false);
        home.days
            .begin_selected(&day, ActivityScope::AllMachines)
            .unwrap();
        assert!(!home.finish(
            old,
            Ok(Some(Calendar::fixture(ActivityScope::AllMachines).unwrap()))
        ));
        assert!(!home.days.finish_detail(&detail, Ok(None)));
        assert!(home.loading && home.days.selected.loading);
        assert!(home.finish(fresh, Ok(None)));
        assert!(home.calendar.is_none() && home.confirmed_empty);
    }
    #[test]
    fn stale_scope_results_cannot_replace_the_newer_grid_or_spinner() {
        let mut home = HomeState::default();
        let old = home.begin(ActivityScope::AllMachines, false);
        let new = home.begin(ActivityScope::ThisMachine, true);
        assert!(!home.finish(
            old,
            Ok(Some(Calendar::fixture(ActivityScope::AllMachines).unwrap()))
        ));
        assert!(home.loading);
        home.finish(
            new,
            Ok(Some(Calendar::fixture(ActivityScope::ThisMachine).unwrap())),
        );
        assert_eq!(
            home.calendar.as_ref().unwrap().delivered_scope(),
            ActivityScope::ThisMachine
        );
        let failed = home.begin(ActivityScope::ThisMachine, true);
        assert!(home.refreshing && !home.loading);
        home.finish(failed, Err("fixture offline".into()));
        assert!(home.calendar.is_some() && !home.confirmed_empty && home.error.is_some());
        let empty = home.begin(ActivityScope::ThisMachine, true);
        home.finish(empty, Ok(None));
        assert!(home.confirmed_empty && home.calendar.is_none() && home.selected.is_none());
    }
    #[test]
    fn selection_and_disclosed_fallback_use_delivered_data() {
        let mut home = HomeState::default();
        let mut grid = Calendar::fixture(ActivityScope::ThisMachine).unwrap();
        grid.notice_code = Some("auth".into());
        let request = home.begin(ActivityScope::AllMachines, false);
        home.finish(request, Ok(Some(grid)));
        assert!(home.needs_sign_in());
        assert!(home.subtitle().contains("on this device"));
        let selected = home
            .calendar
            .as_ref()
            .unwrap()
            .cell("2026-11-07")
            .unwrap()
            .clone();
        home.select(selected.clone());
        let request = home.begin(ActivityScope::AllMachines, true);
        home.finish(
            request,
            Ok(Some(Calendar::fixture(ActivityScope::AllMachines).unwrap())),
        );
        assert_eq!(home.selected.unwrap().date, selected.date);
    }
    #[test]
    fn grid_hit_testing_excludes_gaps_future_and_locked_cells() {
        let mut grid = Calendar::fixture(ActivityScope::ThisMachine).unwrap();
        let g = HeatmapGeometry::new(720., grid.weeks, grid.rows.len());
        assert_eq!(g.slot(1., 1., &grid.rows), Some((0, 0)));
        assert_eq!(g.slot(g.cell + g.gap / 2., 1., &grid.rows), None);
        grid.rows[0][0].as_mut().unwrap().locked = true;
        assert_eq!(g.slot(1., 1., &grid.rows), None);
        assert_eq!(g.slot(-1., 1., &grid.rows), None);
        assert_eq!(
            g.slot(52. * g.stride() + 1., 6. * g.stride() + 1., &grid.rows),
            None
        );
    }

    #[test]
    fn older_optional_flags_decode_like_the_swift_optional_booleans() {
        let mut wire =
            serde_json::to_value(Calendar::fixture(ActivityScope::ThisMachine).unwrap()).unwrap();
        wire["historyLocked"] = serde_json::Value::Null;
        wire["historyUpgrade"] = serde_json::Value::Null;
        wire["rows"][0][0]["locked"] = serde_json::Value::Null;
        wire.as_object_mut().unwrap().remove("scope");
        let grid: Calendar = serde_json::from_value(wire).unwrap();
        assert!(
            !grid.history_locked
                && !grid.history_upgrade
                && !grid.rows[0][0].as_ref().unwrap().locked
        );
        assert_eq!(grid.delivered_scope(), ActivityScope::ThisMachine);
        grid.validate().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn calendar_request_keeps_scope_and_force_and_null_is_an_authoritative_answer() {
        use serde_json::{Value, json};
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
        };
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let thread = std::thread::spawn(move || {
            drop(listener.accept().unwrap());
            for (method, value) in [
                ("protocol", json!({"protocolVersion":"53"})),
                ("activity.calendar", Value::Null),
            ] {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                if method == "activity.calendar" {
                    assert_eq!(request["params"], json!({"scope":"account","force":true}));
                }
                writeln!(
                    reader.get_mut(),
                    "{}",
                    json!({"id":request["id"],"ok":true,"result":value})
                )
                .unwrap();
            }
        });
        let result = crate::client::Client {
            socket,
            allow_spawn: false,
        }
        .activity_calendar(ActivityScope::AllMachines, true)
        .unwrap();
        assert!(result.is_none());
        thread.join().unwrap();
    }
}
