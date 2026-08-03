use anstream::println;
use anyhow::Result;
use tokenstat_core::{EquivalentValue, EstimateSource, GroupBy, PriceTable, Query, Store};

use super::*;
use crate::ui::{self, BOLD, DIM, accent};

pub fn overview(store: &Store, tz: &jiff::tz::TimeZone, q: &Query, json: bool) -> Result<()> {
    let totals = store.totals(q)?;
    if totals.events == 0 {
        return empty_range(json);
    }
    let models = store.report(GroupBy::Model, q)?;
    let days = store.report(GroupBy::Day, q)?;
    let peak = store.peak_hour()?;

    if json {
        println!(
            r#"{{"total_tokens":{},"events":{},"sessions":{},"active_days":{},"first_date":{},"last_date":{},"top_model":{}}}"#,
            totals.counters.total(),
            totals.events,
            totals.sessions,
            totals.days,
            json_opt(totals.first_date.as_deref()),
            json_opt(totals.last_date.as_deref()),
            json_opt(models.first().map(|m| m.key.as_str())),
        );
        return Ok(());
    }

    let c = &totals.counters;
    // Split the headline the way the tools themselves do. Cache reads dwarf
    // everything else, often by two orders of magnitude, so folding them into
    // one "total tokens" figure makes it unrecognizable next to what Claude
    // Code's own usage view reports.
    let in_out = c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0);
    let cache_write = c.cache_write_5m.unwrap_or(0) + c.cache_write_1h.unwrap_or(0);

    println!();
    let stats = [
        ("Sessions", ui::exact(totals.sessions)),
        ("Requests", ui::exact(totals.events)),
        ("Input + output", ui::tokens(in_out)),
        ("Active days", ui::exact(totals.days)),
    ];
    let mut labels = String::from("  ");
    let mut values = String::from("  ");
    for (l, v) in &stats {
        labels.push_str(&ui::pad_right(l, 16));
        values.push_str(&ui::pad_right(&format!("{BOLD}{v}{BOLD:#}"), 16 + 8));
    }
    println!("{DIM}{labels}{DIM:#}");
    println!("{values}");
    let sep = ui::separator();
    println!(
        "  {DIM}cache read {}  {sep}  cache write {}  {sep}  {} counting cache{DIM:#}",
        ui::tokens(c.cache_read.unwrap_or(0)),
        ui::tokens(cache_write),
        ui::tokens(c.total()),
    );

    if let (Some(first), Some(last)) = (&totals.first_date, &totals.last_date) {
        let peak_txt = peak
            .map(|h| format!("  {sep}  peak hour {h:02}:00"))
            .unwrap_or_default();
        println!("  {DIM}{first} to {last}{peak_txt}{DIM:#}");
    }

    if !days.is_empty() {
        println!();
        let pairs: Vec<(String, u64)> = days
            .iter()
            .map(|d| {
                let c = &d.counters;
                (
                    d.key.clone(),
                    c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0),
                )
            })
            .collect();
        if let Some(cal) = ui::heat_calendar(&pairs, heat_weeks(53), today(tz)) {
            heat_block(&cal, false);
        }
    }

    // One load for the table and the notes below it. The catalog is a megabyte
    // of JSON, so parsing it twice per report is not free.
    let prices = PriceTable::load_with_catalog();

    if !models.is_empty() {
        println!();
        let grand: u64 = models
            .iter()
            .map(|m| m.counters.total())
            .sum::<u64>()
            .max(1);
        let w = models
            .iter()
            .map(|m| model_label(&m.key).chars().count())
            .max()
            .unwrap_or(10)
            .clamp(8, 26);
        println!(
            "  {DIM}{}  {}  {}  {}  {}  {}{DIM:#}",
            ui::pad_right("Model", w),
            ui::pad_left("input", 8),
            ui::pad_left("output", 8),
            ui::pad_left("cache", 8),
            ui::pad_left("total", 9),
            ui::pad_left("value", 8),
        );
        for m in &models {
            let share = m.counters.total() as f64 / grand as f64;
            let a = accent();
            let c = &m.counters;
            let label = model_label(&m.key);
            // What this model's usage would have cost at list rates. It was not
            // billed that way on a plan, so it is labelled as value, never as
            // money charged. `~` marks estimate floors (Cursor Auto).
            println!(
                "  {}  {}  {}  {}  {}  {}  {a}{}{a:#}",
                ui::pad_right(&label, w),
                ui::pad_left(&cell(c.input_fresh), 8),
                ui::pad_left(&cell(c.output), 8),
                ui::pad_left(&cache_cell(c), 8),
                ui::pad_left(&total_cell(c), 9),
                ui::pad_left(&price_cell(&prices, &m.key, c), 8),
                ui::pad_left(&format!("{:.1}%", share * 100.0), 6),
            );
        }
    }

    // Plan usage is not money. Saying so explicitly is a product requirement,
    // not a nicety.
    let mut router_floor = false;
    let mut from_catalog = false;
    let mut missing: Vec<String> = Vec::new();
    let total_value: EquivalentValue = models
        .iter()
        .filter_map(|m| {
            let lookup = model_label(&m.key);
            match prices.estimate_source(&lookup) {
                Some(EstimateSource::CursorRouterFloor) => router_floor = true,
                Some(EstimateSource::Catalog) => from_catalog = true,
                None => {}
            }
            if !prices.is_known(&lookup) {
                missing.push(lookup.clone());
            }
            EquivalentValue::price(&prices, &lookup, &m.counters)
        })
        .sum();

    println!();
    println!(
        "  {BOLD}{}{BOLD:#} {DIM}if this had been billed per token{DIM:#}",
        format_args!("{}", ui::usd(total_value.dollars()))
    );
    println!(
        "  {DIM}List-rate equivalent only. Plan usage is not money charged; metered API usage may have been.{DIM:#}"
    );
    // Name what each `~` actually is. "Estimate" alone leaves the reader
    // guessing whether it means rounded or sourced from somewhere else. Both
    // reasons can apply at once, so they share one line rather than stacking.
    let mut why: Vec<&str> = Vec::new();
    if router_floor {
        why.push("Cursor Auto at Composer 2.5 list rates as a floor");
    }
    if from_catalog {
        why.push("published provider rates, not the list-rate book");
    }
    if !why.is_empty() {
        println!("  {DIM}~ values are estimates ({}).{DIM:#}", why.join("; "));
    }
    if prices.is_empty() {
        let a = accent();
        println!(
            "  {DIM}No local price book yet. Run {DIM:#}{a}tokenstat pricing --refresh{a:#}{DIM}.{DIM:#}"
        );
    } else if !missing.is_empty() {
        println!(
            "  {DIM}No list price yet for: {}{DIM:#}",
            missing.join(", ")
        );
        if prices.catalog().is_none() {
            let a = accent();
            println!(
                "  {DIM}Some of those have published rates. Run {DIM:#}{a}tokenstat catalog --refresh{a:#}{DIM}.{DIM:#}"
            );
        }
    }
    println!();
    Ok(())
}

/// Today in the user's timezone. The heatmap anchors on it rather than on the
/// newest day with data, so a quiet week still shows as a quiet week.
pub(super) fn today(tz: &jiff::tz::TimeZone) -> jiff::civil::Date {
    jiff::Timestamp::now().to_zoned(tz.clone()).date()
}

/// Weeks that fit the current terminal, so a wide window is not required to
/// read the grid and a narrow one does not wrap into noise.
fn heat_weeks(max_weeks: usize) -> usize {
    // COLUMNS wins when set, so a piped or captured run can still ask for the
    // full year that a narrow window would otherwise trim.
    let cols = std::env::var("COLUMNS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .or_else(|| crossterm::terminal::size().ok().map(|(w, _)| w as usize))
        .unwrap_or(80);
    let fits = cols.saturating_sub(2 + ui::HEAT_GUTTER) / ui::HEAT_COL;
    max_weeks.clamp(1, fits.max(8))
}

/// Draw the calendar: month strip, weekday gutter, cells, legend.
fn heat_block(cal: &ui::HeatCalendar, legend: bool) {
    println!("  {DIM}{}{DIM:#}", cal.header());
    for (r, row) in cal.rows.iter().enumerate() {
        let mut line = String::new();
        for cell in row {
            match cell {
                None => line.push_str("  "),
                Some(c) => {
                    let s = ui::heat_style(c.level);
                    line.push_str(&format!("{s}{}{s:#} ", ui::heat_cell()));
                }
            }
        }
        println!(
            "  {DIM}{}{DIM:#}{}",
            ui::pad_right(ui::HeatCalendar::row_label(r), ui::HEAT_GUTTER),
            line.trim_end()
        );
    }
    if legend {
        let mut scale = String::new();
        for level in 0..5u8 {
            let s = ui::heat_style(level);
            scale.push_str(&format!("{s}{}{s:#} ", ui::heat_cell()));
        }
        // "less" + five swatches + "more", flush with the right edge of the
        // grid the way the web version sits under its last column.
        let plain = "less ".len() + 5 * ui::HEAT_COL + "more".len();
        let lead = cal.width().saturating_sub(plain);
        println!(
            "  {}{DIM}less{DIM:#} {scale}{DIM}more{DIM:#}",
            " ".repeat(lead)
        );
    }
}

/// Standalone activity heatmap (same grid as summary, tunable window).
pub fn heatmap(store: &Store, tz: &jiff::tz::TimeZone, q: &Query, json: bool) -> Result<()> {
    let days = store.report(GroupBy::Day, q)?;
    if days.is_empty() {
        return empty_range(json);
    }
    let pairs: Vec<(String, u64)> = days
        .iter()
        .map(|d| {
            let c = &d.counters;
            let in_out = c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0);
            (d.key.clone(), in_out)
        })
        .collect();
    let weeks = if json { 53 } else { heat_weeks(53) };
    let Some(cal) = ui::heat_calendar(&pairs, weeks, today(tz)) else {
        return empty_range(json);
    };

    if json {
        let cells: Vec<String> = cal
            .days()
            .map(|c| {
                format!(
                    r#"{{"date":"{}","in_out":{},"level":{}}}"#,
                    c.date, c.value, c.level
                )
            })
            .collect();
        println!(
            r#"{{"days":[{}],"weeks":{},"in_out":{},"active_days":{},"streak_current":{},"streak_best":{},"busiest_day":{}}}"#,
            cells.join(","),
            cal.weeks,
            cal.total,
            cal.active_days,
            cal.streak_current,
            cal.streak_best,
            json_opt(cal.busiest.map(|b| b.date.to_string()).as_deref()),
        );
        return Ok(());
    }

    let a = accent();
    println!();
    println!("  {DIM}ACTIVITY{DIM:#}");
    println!(
        "  {BOLD}{a}{}{a:#} tokens over {a}{}{a:#} active days{BOLD:#}",
        ui::tokens(cal.total),
        cal.active_days,
    );
    let mut sub = format!(
        "Averaging {} on a day worked.",
        ui::tokens(cal.total / cal.active_days.max(1) as u64)
    );
    if let Some(b) = cal.busiest {
        sub.push_str(&format!(
            " Busiest was {} at {}.",
            b.date,
            ui::tokens(b.value)
        ));
    }
    if cal.streak_current > 1 {
        sub.push_str(&format!(" On a {} day streak.", cal.streak_current));
    }
    println!("  {DIM}{sub}{DIM:#}");
    println!(
        "  {DIM}{} to {} {} input+output per day{DIM:#}",
        cal.first,
        cal.last,
        ui::separator()
    );
    println!();
    heat_block(&cal, true);
    println!();
    Ok(())
}

/// Year-in-review from the local archive only.
pub fn wrapped(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    year: Option<i32>,
    json: bool,
) -> Result<()> {
    let y = year
        .unwrap_or_else(|| i32::from(jiff::Timestamp::now().to_zoned(tz.clone()).date().year()));
    let q = Query {
        since: Some(format!("{y:04}-01-01")),
        until: Some(format!("{y:04}-12-31")),
        ..Query::default()
    };
    let totals = store.totals(&q)?;
    if totals.events == 0 {
        if json {
            println!(r#"{{"year":{y},"events":0}}"#);
            return Ok(());
        }
        println!();
        println!("  {BOLD}Wrapped {y}{BOLD:#}");
        println!("  {DIM}No usage in the archive for this year.{DIM:#}");
        println!();
        return Ok(());
    }

    let models = store.report(GroupBy::Model, &q)?;
    let projects = store.report(GroupBy::Project, &q)?;
    let days = store.report(GroupBy::Day, &q)?;
    let peak = store.peak_hour()?;
    let prices = PriceTable::load_with_catalog();
    let top_model_label = models.first().map(|m| model_label(&m.key));
    let value: EquivalentValue = models
        .iter()
        .filter_map(|m| EquivalentValue::price(&prices, &model_label(&m.key), &m.counters))
        .sum();
    let busiest_day = days
        .iter()
        .max_by_key(|d| d.counters.input_fresh.unwrap_or(0) + d.counters.output.unwrap_or(0));
    let top_project = projects.first();
    let in_out = totals.counters.input_fresh.unwrap_or(0) + totals.counters.output.unwrap_or(0);

    if json {
        println!(
            r#"{{"year":{y},"events":{},"sessions":{},"active_days":{},"input_output":{},"list_value_usd":{:.6},"top_model":{},"top_project":{},"busiest_day":{},"peak_hour":{}}}"#,
            totals.events,
            totals.sessions,
            totals.days,
            in_out,
            value.dollars(),
            json_opt(top_model_label.as_deref()),
            json_opt(top_project.map(|p| p.key.as_str())),
            json_opt(busiest_day.map(|d| d.key.as_str())),
            peak.map(|h| h.to_string()).unwrap_or_else(|| "null".into()),
        );
        return Ok(());
    }

    println!();
    println!("  {BOLD}Wrapped {y}{BOLD:#}  {DIM}local archive only{DIM:#}");
    println!();
    println!("  {DIM}requests{DIM:#}     {}", ui::exact(totals.events));
    println!("  {DIM}sessions{DIM:#}     {}", ui::exact(totals.sessions));
    println!("  {DIM}active days{DIM:#}  {}", ui::exact(totals.days));
    println!("  {DIM}input+output{DIM:#} {}", ui::tokens(in_out));
    println!(
        "  {DIM}list value{DIM:#}   {}  {DIM}(not billed){DIM:#}",
        ui::usd(value.dollars())
    );
    if let Some(label) = top_model_label {
        println!("  {DIM}top model{DIM:#}    {label}");
    }
    if let Some(p) = top_project {
        println!("  {DIM}top project{DIM:#}  {}", p.key);
    }
    if let Some(d) = busiest_day {
        let io = d.counters.input_fresh.unwrap_or(0) + d.counters.output.unwrap_or(0);
        println!("  {DIM}busiest day{DIM:#}  {}  ({})", d.key, ui::tokens(io));
    }
    if let Some(h) = peak {
        println!("  {DIM}peak hour{DIM:#}    {h:02}:00");
    }
    if !days.is_empty() {
        println!();
        let pairs: Vec<(String, u64)> = days
            .iter()
            .map(|d| {
                (
                    d.key.clone(),
                    d.counters.input_fresh.unwrap_or(0) + d.counters.output.unwrap_or(0),
                )
            })
            .collect();
        // Wrapped is a calendar year, not a rolling window: anchor on the last
        // day of the year that has already happened, and reach back to January.
        let year_end = jiff::civil::date(y as i16, 12, 31);
        let now = today(tz);
        let anchor = if now < year_end { now } else { year_end };
        let weeks = (anchor.day_of_year() as usize).div_ceil(7) + 1;
        if let Some(cal) = ui::heat_calendar(&pairs, heat_weeks(weeks), anchor) {
            heat_block(&cal, true);
        }
    }
    println!();
    Ok(())
}
