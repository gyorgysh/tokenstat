//! Output formatting for every command.
//!
//! Two rules shape what appears here. Plan usage is never printed as money,
//! because it was not charged. And an unreported counter renders as `-` rather
//! than `0`, with totals marked `+` when they are a lower bound, so a partial
//! figure never masquerades as a complete one.

use std::io::Write;
use std::path::Path;

use anstream::println;
use anyhow::{Context, Result};
use tokenstat_core::{
    Bucket, Counters, EquivalentValue, GroupBy, PriceTable, Query, ScanReport, Store,
    display_usage_model_id,
};

use crate::ui::{self, BOLD, DIM, accent, good, warn};

/// Render `Some(n)` compactly, `None` as a dash.
fn cell(v: Option<u64>) -> String {
    match v {
        Some(n) => ui::tokens(n),
        None => "-".to_string(),
    }
}

/// Total with a `+` suffix when some contributing field was never reported.
fn total_cell(c: &Counters) -> String {
    let t = ui::tokens(c.total());
    if c.has_unknown() { format!("{t}+") } else { t }
}

/// List-rate equivalent for a row, or `-` when the model is unknown / unpriced.
/// Never a cash charge: subscription usage is valued the same way.
/// Estimates (e.g. Cursor Auto → Composer floor) get a `~` prefix, same idea
/// as tokenstat.ai and the upcoming CLI 0.1.2 note on opaque routers.
fn price_cell(prices: &PriceTable, model: &str, c: &Counters) -> String {
    let lookup = display_usage_model_id(model);
    match EquivalentValue::price(prices, &lookup, c) {
        Some(v) if prices.is_estimate(&lookup) && v.dollars() > 0.0 => {
            format!("~{}", ui::usd(v.dollars()))
        }
        Some(v) => ui::usd(v.dollars()),
        None => "-".to_string(),
    }
}

fn model_label(model: &str) -> String {
    display_usage_model_id(model)
}

/// Price only when `key` looks like a model id. Day/project buckets would
/// otherwise look up a date or path as a model and almost always show `-`.
fn price_cell_for_group(prices: &PriceTable, group: GroupBy, key: &str, c: &Counters) -> String {
    match group {
        GroupBy::Model => price_cell(prices, key, c),
        _ => "-".to_string(),
    }
}

/// Cache read tokens only. Writes stay in `total` / the priced figure.
fn cache_cell(c: &Counters) -> String {
    cell(c.cache_read)
}

pub fn empty_archive(json: bool) -> Result<()> {
    if json {
        println!(
            "{}",
            r#"{"events":0,"hint":"run: tokenstat scan","sources_on_disk":["claude_code","codex","grok","opencode","cline","antigravity","openclaw","zed","copilot"],"sources_remote":["cursor"],"sources_ide_sync":["antigravity"]}"#
        );
        return Ok(());
    }
    println!();
    println!("  {BOLD}No usage recorded yet.{BOLD:#}");
    println!();
    let a = accent();
    println!("  Run {a}tokenstat scan{a:#} to read your local logs.");
    println!("  Or open the interactive client with {a}tokenstat{a:#} and type {a}/scan{a:#}.");
    println!();
    println!(
        "  {DIM}On disk:{DIM:#} Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI"
    );
    println!("  {DIM}Remote:{DIM:#}   Cursor  {DIM}(tokenstat auth cursor){DIM:#}");
    println!("  {DIM}IDE sync:{DIM:#} Antigravity  {DIM}(open app, then tokenstat fetch){DIM:#}");
    println!();
    Ok(())
}

/// Filtered query matched nothing, but the archive itself may have data.
pub fn empty_range(json: bool) -> Result<()> {
    if json {
        println!(
            "{}",
            r#"{"rows":0,"hint":"widen --since/--until or drop filters"}"#
        );
        return Ok(());
    }
    println!();
    println!("  {DIM}Nothing in this range.{DIM:#}");
    println!("  {DIM}Try widening --since / --until, or drop --model / --project.{DIM:#}");
    println!();
    Ok(())
}

pub fn scan_report(r: &ScanReport, json: bool) -> Result<()> {
    if json {
        println!(
            r#"{{"files_found":{},"files_read":{},"rows_seen":{},"events_new":{},"duplicate_ratio":{:.4},"warnings":{},"elapsed_ms":{}}}"#,
            r.files_found,
            r.files_read,
            r.rows_seen,
            r.events_new,
            r.duplicate_ratio(),
            r.warnings.len(),
            r.elapsed_ms
        );
        return Ok(());
    }

    println!();
    let skipped = r.files_found.saturating_sub(r.files_read);
    println!(
        "  {BOLD}Scanned{BOLD:#} {} of {} files in {}",
        ui::exact(r.files_read),
        ui::exact(r.files_found),
        format_ms(r.elapsed_ms)
    );
    if skipped > 0 {
        println!(
            "  {DIM}{} unchanged since the last scan{DIM:#}",
            ui::exact(skipped)
        );
    }

    if r.rows_seen > 0 {
        println!(
            "  {} rows read, {} new",
            ui::exact(r.rows_seen),
            ui::exact(r.events_new)
        );
        let dup = r.duplicate_ratio();
        if dup > 0.01 {
            // Worth surfacing: it is the single biggest source of wrong numbers
            // in tools that key on the wrong field.
            println!(
                "  {DIM}{:.1}% were duplicates, collapsed by request id{DIM:#}",
                dup * 100.0
            );
        }
    }

    if r.events_recovered > 0 {
        let g = good();
        println!(
            "  {g}recovered {} days from Claude Code's rollup{g:#}  {DIM}({} entries){DIM:#}",
            r.days_recovered, r.events_recovered
        );
        println!("  {DIM}those transcripts were already deleted, the totals survive{DIM:#}");
    }

    if r.files_found == 0 {
        println!();
        println!("  {DIM}No supported tool logs found on this machine.{DIM:#}");
        println!(
            "  {DIM}On disk: Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI,{DIM:#}"
        );
        println!("  {DIM}OpenClaw, Zed, Copilot CLI. Then scan again.{DIM:#}");
        println!("  {DIM}Cursor keeps usage on its servers (tokenstat auth cursor).{DIM:#}");
        println!("  {DIM}Antigravity IDE needs the app open + tokenstat fetch.{DIM:#}");
    } else if r.rows_seen == 0 && r.events_recovered == 0 {
        println!();
        println!("  {DIM}Logs were found, but no new usage rows were readable.{DIM:#}");
        println!("  {DIM}Run tokenstat doctor for source coverage.{DIM:#}");
    }

    if !r.warnings.is_empty() {
        let w = warn();
        println!(
            "  {w}{} warnings{w:#}  {DIM}run: tokenstat doctor{DIM:#}",
            r.warnings.len()
        );
    }
    println!();
    Ok(())
}

fn format_ms(ms: u128) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else {
        format!("{:.1}s", ms as f64 / 1000.0)
    }
}

/// Shared table for any grouping: label, bar, split counters, total.
///
/// Day (and month) rows stay oldest→newest so a long one-shot print ends on
/// the most recent day. The interactive client reverses that on screen.
pub fn grouped(store: &Store, group: GroupBy, q: &Query, label: &str, json: bool) -> Result<()> {
    let rows = store.report(group, q)?;
    if rows.is_empty() {
        return empty_range(json);
    }
    if json {
        return print_json_buckets(&rows);
    }
    print_table(&rows, label, group);
    Ok(())
}

fn print_table(rows: &[Bucket], label: &str, group: GroupBy) {
    // Caller already handles the empty case so the table always has a body.
    let chronological = group == GroupBy::Day;

    let key_w = rows
        .iter()
        .map(|r| {
            if group == GroupBy::Model {
                model_label(&r.key).chars().count()
            } else {
                r.key.chars().count()
            }
        })
        .max()
        .unwrap_or(8)
        .clamp(label.len().max(10), 36);
    let max = rows
        .iter()
        .map(|r| r.counters.total())
        .max()
        .unwrap_or(1)
        .max(1);
    let grand: u64 = rows.iter().map(|r| r.counters.total()).sum();
    let prices = PriceTable::load();

    println!();
    println!(
        "  {DIM}{}  {}  {}  {}  {}  {}{DIM:#}",
        ui::pad_right(label, key_w),
        ui::pad_left("input", 8),
        ui::pad_left("output", 8),
        ui::pad_left("cache", 8),
        ui::pad_left("total", 9),
        ui::pad_left("value", 8),
    );

    for r in rows {
        let c = &r.counters;
        let frac = c.total() as f64 / max as f64;
        let a = accent();
        let key_label = if group == GroupBy::Model {
            model_label(&r.key)
        } else {
            r.key.clone()
        };
        println!(
            "  {}  {}  {}  {}  {}  {}  {a}{}{a:#}",
            ui::pad_right(&key_label, key_w),
            ui::pad_left(&cell(c.input_fresh), 8),
            ui::pad_left(&cell(c.output), 8),
            ui::pad_left(&cache_cell(c), 8),
            ui::pad_left(&total_cell(c), 9),
            ui::pad_left(&price_cell_for_group(&prices, group, &r.key, c), 8),
            ui::bar(frac, 12),
        );
    }

    // A single summary line rather than a repeated footer: the eye should land
    // on the data, not the chrome.
    println!(
        "  {DIM}{}{DIM:#}  {BOLD}{}{BOLD:#} total across {} {}",
        ui::pad_right("", key_w),
        ui::tokens(grand),
        rows.len(),
        if chronological { "days" } else { "rows" },
    );
    if group == GroupBy::Model {
        println!("  {DIM}value = list-rate equivalent, not billed dollars{DIM:#}");
        if rows
            .iter()
            .any(|r| prices.is_estimate(&model_label(&r.key)))
        {
            println!(
                "  {DIM}~ values are estimates (Cursor Auto at Composer 2.5 list rates as a floor).{DIM:#}"
            );
        }
    }
    println!();
}

pub fn monthly(store: &Store, q: &Query, json: bool) -> Result<()> {
    // Months are days rolled up by prefix, so there is no separate query.
    let days = store.report(GroupBy::Day, q)?;
    let mut months: Vec<Bucket> = Vec::new();
    for d in days {
        let key = d.key.get(..7).unwrap_or(&d.key).to_string();
        match months.last_mut() {
            Some(m) if m.key == key => {
                m.counters.accumulate(&d.counters);
                m.events += d.events;
            }
            _ => months.push(Bucket {
                key,
                counters: d.counters,
                events: d.events,
                sessions: 0,
            }),
        }
    }
    if months.is_empty() {
        return empty_range(json);
    }
    if json {
        return print_json_buckets(&months);
    }
    print_table(&months, "Month", GroupBy::Day);
    Ok(())
}

pub fn sessions(store: &Store, q: &Query, top: usize, json: bool) -> Result<()> {
    let mut rows = store.report(GroupBy::Session, q)?;
    rows.truncate(top);
    if rows.is_empty() {
        return empty_range(json);
    }
    if json {
        return print_json_buckets(&rows);
    }
    print_table(&rows, "Session", GroupBy::Session);
    Ok(())
}

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
    println!(
        "  {DIM}cache read {}  ·  cache write {}  ·  {} counting cache{DIM:#}",
        ui::tokens(c.cache_read.unwrap_or(0)),
        ui::tokens(cache_write),
        ui::tokens(c.total()),
    );

    if let (Some(first), Some(last)) = (&totals.first_date, &totals.last_date) {
        let peak_txt = peak
            .map(|h| format!("  ·  peak hour {h:02}:00"))
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
        let prices = PriceTable::load();
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
    let prices = PriceTable::load();
    let mut any_estimate = false;
    let mut missing: Vec<String> = Vec::new();
    let total_value: EquivalentValue = models
        .iter()
        .filter_map(|m| {
            let lookup = model_label(&m.key);
            if prices.is_estimate(&lookup) {
                any_estimate = true;
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
    if any_estimate {
        println!(
            "  {DIM}~ values are estimates (Cursor Auto at Composer 2.5 list rates as a floor).{DIM:#}"
        );
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
    }
    println!();
    Ok(())
}

/// Today in the user's timezone. The heatmap anchors on it rather than on the
/// newest day with data, so a quiet week still shows as a quiet week.
fn today(tz: &jiff::tz::TimeZone) -> jiff::civil::Date {
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
                    line.push_str(&format!("{s}{}{s:#} ", ui::HEAT_CELL));
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
            scale.push_str(&format!("{s}{}{s:#} ", ui::HEAT_CELL));
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
        "  {DIM}{} to {} · input+output per day{DIM:#}",
        cal.first, cal.last
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
    let prices = PriceTable::load();
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

pub fn doctor(store: &Store, db_path: &Path, json: bool) -> Result<()> {
    let totals = store.totals(&Query::default())?;
    let confidence = store.confidence_breakdown()?;
    let last_scan = store.meta("last_scan_ms")?;

    if json {
        let conf: Vec<String> = confidence
            .iter()
            .map(|(k, v)| format!(r#"{{"level":"{k}","events":{v}}}"#))
            .collect();
        println!(
            r#"{{"db":"{}","events":{},"confidence":[{}]}}"#,
            db_path.display(),
            totals.events,
            conf.join(",")
        );
        return Ok(());
    }

    println!();
    println!("  {BOLD}Archive{BOLD:#}");
    println!("  {DIM}path{DIM:#}     {}", db_path.display());
    println!("  {DIM}events{DIM:#}   {}", ui::exact(totals.events));
    if let (Some(a), Some(b)) = (&totals.first_date, &totals.last_date) {
        println!(
            "  {DIM}range{DIM:#}    {a} to {b} ({} active days)",
            totals.days
        );
    }
    match last_scan.as_deref().and_then(|s| s.parse::<i64>().ok()) {
        Some(ms) => {
            let age = (jiff::Timestamp::now().as_millisecond() - ms).max(0) / 1000;
            println!("  {DIM}scanned{DIM:#}  {} ago", format_age(age));
        }
        None => println!("  {DIM}scanned{DIM:#}  never"),
    }

    println!();
    println!("  {BOLD}Confidence{BOLD:#}");
    if confidence.is_empty() {
        println!("  {DIM}No events yet, so there is nothing to score.{DIM:#}");
    } else {
        for (level, count) in &confidence {
            let share = *count as f64 / totals.events.max(1) as f64;
            let style = if level == "exact" { good() } else { warn() };
            println!(
                "  {}  {style}{}{style:#}  {}  {:.1}%",
                ui::pad_right(level, 9),
                ui::pad_right(&ui::bar(share, 20), 20),
                ui::pad_left(&ui::exact(*count), 9),
                share * 100.0,
            );
        }
        println!();
        println!("  {DIM}exact means the provider assigned a request id that survives a{DIM:#}");
        println!("  {DIM}session resume, so duplicates collapse reliably.{DIM:#}");
    }

    if let Some(rec) = tokenstat_core::reconcile(store)? {
        println!();
        println!("  {BOLD}Against Claude Code's own rollup{BOLD:#}");
        println!(
            "  {DIM}it reports{DIM:#}   {} input + output over {} sessions",
            ui::tokens(rec.vendor_in_out),
            ui::exact(rec.vendor_sessions)
        );
        println!(
            "  {DIM}archive has{DIM:#}  {} input + output over {} sessions",
            ui::tokens(rec.archive_in_out),
            ui::exact(rec.archive_sessions)
        );

        if totals.events == 0 {
            println!();
            let a = accent();
            println!(
                "  Archive is empty. Run {a}tokenstat scan{a:#} to import what is still on disk."
            );
            println!(
                "  {DIM}Claude's rollup can recover pruned transcript days once you scan.{DIM:#}"
            );
        } else if rec.is_significant() {
            let w = warn();
            println!();
            println!(
                "  {w}{} ({:.0}%) is no longer recoverable from your transcripts.{w:#}",
                ui::tokens(rec.missing()),
                rec.missing_ratio() * 100.0
            );
            if let (Some(v), Some(a)) = (&rec.vendor_first_date, &rec.archive_first_date) {
                println!("  {DIM}your history starts {v}, surviving transcripts start {a}{DIM:#}");
            }
            println!();
            println!(
                "  {DIM}Claude Code deletes transcripts after cleanupPeriodDays (30 by{DIM:#}"
            );
            println!(
                "  {DIM}default). tokenstat keeps what it has already read, so scanning{DIM:#}"
            );
            println!("  {DIM}regularly from now on stops the gap from growing.{DIM:#}");
        } else if rec.ahead() > 0 {
            // Normal and healthy: transcripts are current, the rollup is
            // recomputed periodically and lags behind.
            println!();
            let g = good();
            println!(
                "  {g}archive is complete{g:#}, and {} ahead of the rollup",
                ui::tokens(rec.ahead())
            );
            if let Some(d) = &rec.vendor_last_computed {
                println!("  {DIM}the rollup was last recomputed on {d}{DIM:#}");
            }
        } else {
            println!();
            let g = good();
            println!("  {g}archive agrees with the rollup{g:#}");
        }
    }

    println!();
    println!("  {BOLD}Sources{BOLD:#}");
    println!(
        "  {DIM}on disk{DIM:#}   Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI"
    );
    println!("  {DIM}remote{DIM:#}    Cursor  {DIM}(auth + 30m cached fetch){DIM:#}");
    println!("  {DIM}IDE sync{DIM:#}  Antigravity  {DIM}(open app, then tokenstat fetch){DIM:#}");
    if let Ok(rows) = tokenstat_sync::creds::status() {
        for s in rows {
            let state = if s.present {
                "token stored"
            } else {
                "no token"
            };
            println!("  {DIM}auth {}{DIM:#}  {state}", s.vendor);
        }
    }
    if let Some(q) = tokenstat_sync::antigravity::stored_quota(store) {
        println!();
        println!(
            "  {BOLD}Antigravity quota{BOLD:#}  {DIM}plan remaining, separate from token events{DIM:#}"
        );
        println!("  {DIM}status{DIM:#}   {}", q.summary_line());
        for m in q.models.iter().take(8) {
            let pct = match m.remaining_fraction {
                Some(f) => format!("{:>3}% left", (f * 100.0).round() as i64),
                None => "  n/a      ".into(),
            };
            let reset = m.reset_time.as_deref().unwrap_or("-");
            println!("  {DIM}{:<22}{DIM:#} {pct}  reset {reset}", m.display_name);
        }
    }
    let cli_home = directories::BaseDirs::new().map(|b| b.home_dir().to_path_buf());
    if let Some(home) = cli_home {
        let cli = home
            .join(".gemini")
            .join("antigravity-cli")
            .join("conversations");
        let cache = tokenstat_core::sources::antigravity_cache::cache_dir();
        println!();
        println!("  {BOLD}Antigravity coverage{BOLD:#}");
        if cli.is_dir() {
            let n = tokenstat_core::sources::antigravity_cli::shards(&cli).len();
            println!("  {DIM}CLI DBs{DIM:#}   {n} conversation files (offline scan)");
        } else {
            println!("  {DIM}CLI DBs{DIM:#}   not installed");
        }
        match cache {
            Some(dir) if dir.is_dir() => {
                let n = tokenstat_core::sources::antigravity_cache::shards(&dir).len();
                println!("  {DIM}IDE cache{DIM:#} {n} synced sessions");
            }
            _ => println!(
                "  {DIM}IDE cache{DIM:#} empty  {DIM}(open Antigravity, then tokenstat fetch){DIM:#}"
            ),
        }
    }
    println!();
    Ok(())
}

/// Show or refresh the local list-rate price book.
pub fn pricing(refresh: bool, force: bool, json: bool) -> Result<()> {
    if refresh {
        let r = tokenstat_sync::pricing::refresh(force)?;
        if json {
            println!(
                r#"{{"path":"{}","models":{},"effective_from":"{}","large_moves":{}}}"#,
                r.path.display(),
                r.models,
                r.effective_from,
                r.large_moves.len()
            );
            return Ok(());
        }
        println!();
        println!(
            "  Wrote {} models to {}",
            ui::exact(r.models as u64),
            r.path.display()
        );
        println!("  effective from {}", r.effective_from);
        if !r.large_moves.is_empty() {
            let w = warn();
            println!(
                "  {w}accepted {} large rate move(s) with --force{w:#}",
                r.large_moves.len()
            );
        }
        println!();
        return Ok(());
    }

    let path = tokenstat_core::PriceTable::default_path()?;
    let table = tokenstat_core::PriceTable::load();
    if json {
        println!(
            r#"{{"path":"{}","present":{},"models":{},"effective_from":{}}}"#,
            path.display(),
            !table.is_empty(),
            table.len(),
            if table.effective_from.is_empty() {
                "null".into()
            } else {
                format!("\"{}\"", table.effective_from)
            }
        );
        return Ok(());
    }
    println!();
    println!("  {BOLD}Pricing{BOLD:#}");
    println!("  {DIM}path{DIM:#}     {}", path.display());
    if table.is_empty() {
        let a = accent();
        println!("  {DIM}status{DIM:#}   no local snapshot");
        println!();
        println!(
            "  Run {a}tokenstat pricing --refresh{a:#} to fetch the tokenstat.ai list-rate snapshot."
        );
    } else {
        println!(
            "  {DIM}status{DIM:#}   {} models",
            ui::exact(table.len() as u64)
        );
        println!("  {DIM}from{DIM:#}     {}", table.effective_from);
    }
    println!();
    Ok(())
}

/// Show or update soft spend caps (list-rate equivalent, never billed money).
pub fn budget(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    daily: Option<f64>,
    monthly: Option<f64>,
    clear: bool,
    json: bool,
) -> Result<()> {
    use tokenstat_core::BudgetLimits;

    if clear {
        BudgetLimits::default().save(store)?;
    } else if daily.is_some() || monthly.is_some() {
        let mut limits = BudgetLimits::load(store)?;
        if let Some(v) = daily {
            if v < 0.0 {
                anyhow::bail!("--daily must be >= 0");
            }
            limits.daily_usd = if v == 0.0 { None } else { Some(v) };
        }
        if let Some(v) = monthly {
            if v < 0.0 {
                anyhow::bail!("--monthly must be >= 0");
            }
            limits.monthly_usd = if v == 0.0 { None } else { Some(v) };
        }
        limits.save(store)?;
    }

    let prices = PriceTable::load();
    let st = tokenstat_core::budget_status(store, tz, &prices)?;

    if json {
        println!(
            r#"{{"today":"{}","month":"{}","today_usd":{:.6},"month_usd":{:.6},"daily_limit":{},"monthly_limit":{}}}"#,
            st.today_date,
            st.month_key,
            st.today_usd,
            st.month_usd,
            st.limits
                .daily_usd
                .map(|v| format!("{v:.4}"))
                .unwrap_or_else(|| "null".into()),
            st.limits
                .monthly_usd
                .map(|v| format!("{v:.4}"))
                .unwrap_or_else(|| "null".into()),
        );
        return Ok(());
    }

    println!();
    println!("  {BOLD}Budget{BOLD:#}  {DIM}list-rate equivalent, not billed dollars{DIM:#}");
    println!(
        "  {DIM}today{DIM:#}    {}  {}",
        ui::usd(st.today_usd),
        st.today_date
    );
    if let Some(lim) = st.limits.daily_usd {
        let ratio = st.today_ratio().unwrap_or(0.0);
        let style = if st.over_daily() { warn() } else { good() };
        println!(
            "  {DIM}daily{DIM:#}    {style}{:.0}%{style:#} of {}  ({})",
            ratio * 100.0,
            ui::usd(lim),
            if st.over_daily() { "over" } else { "ok" }
        );
    } else {
        println!("  {DIM}daily{DIM:#}    no cap  {DIM}set with tokenstat budget --daily N{DIM:#}");
    }
    println!(
        "  {DIM}month{DIM:#}    {}  {}",
        ui::usd(st.month_usd),
        st.month_key
    );
    if let Some(lim) = st.limits.monthly_usd {
        let ratio = st.month_ratio().unwrap_or(0.0);
        let style = if st.over_monthly() { warn() } else { good() };
        println!(
            "  {DIM}monthly{DIM:#}  {style}{:.0}%{style:#} of {}  ({})",
            ratio * 100.0,
            ui::usd(lim),
            if st.over_monthly() { "over" } else { "ok" }
        );
    } else {
        println!(
            "  {DIM}monthly{DIM:#}  no cap  {DIM}set with tokenstat budget --monthly N{DIM:#}"
        );
    }
    if prices.is_empty() {
        let a = accent();
        println!();
        println!("  Prices missing. Run {a}tokenstat pricing --refresh{a:#} first.");
    }
    println!();
    Ok(())
}

/// Report remote fetch outcomes after scan or `tokenstat fetch`.
pub fn fetch_reports(reports: &[tokenstat_sync::FetchReport], json: bool) -> Result<()> {
    if json {
        print!("[");
        for (i, r) in reports.iter().enumerate() {
            if i > 0 {
                print!(",");
            }
            print!(
                r#"{{"vendor":"{}","events":{},"from_cache":{},"skipped_no_token":{},"message":{}}}"#,
                r.vendor,
                r.events,
                r.from_cache,
                r.skipped_no_token,
                r.message
                    .as_deref()
                    .map(|s| format!("\"{}\"", s.replace('"', "\\\"")))
                    .unwrap_or_else(|| "null".into()),
            );
        }
        println!("]");
        return Ok(());
    }
    for r in reports {
        if r.skipped_no_token {
            println!(
                "  {DIM}{}: {DIM:#}{}",
                r.vendor,
                r.message.as_deref().unwrap_or("no token")
            );
            continue;
        }
        // Antigravity may report quota and/or IDE sync with zero new events.
        if r.events == 0 {
            if let Some(msg) = &r.message {
                if msg.contains("quota") || msg.contains("IDE") {
                    let g = good();
                    println!("  {g}{}{g:#}: {msg}", r.vendor);
                    continue;
                }
                let w = warn();
                println!("  {w}{}: {msg}{w:#}", r.vendor);
                continue;
            }
        }
        let src = if r.from_cache { "cache" } else { "network" };
        let g = good();
        let extra = r
            .message
            .as_deref()
            .map(|m| format!("  {DIM}({m}){DIM:#}"))
            .unwrap_or_default();
        println!(
            "  {g}{}{g:#}: {} events from {src}{extra}",
            r.vendor,
            ui::exact(r.events as u64)
        );
    }
    println!();
    Ok(())
}

/// `tokenstat auth` for Cursor / Antigravity session tokens.
pub fn auth(
    vendor: Option<&str>,
    token: Option<&str>,
    logout: bool,
    status: bool,
    json: bool,
) -> Result<()> {
    if status {
        let rows = tokenstat_sync::creds::status()?;
        if json {
            print!("[");
            for (i, s) in rows.iter().enumerate() {
                if i > 0 {
                    print!(",");
                }
                let source = match s.source {
                    Some(tokenstat_sync::creds::TokenSource::Env) => "\"env\"",
                    Some(tokenstat_sync::creds::TokenSource::Stored) => "\"stored\"",
                    Some(tokenstat_sync::creds::TokenSource::Discovered) => "\"discovered\"",
                    None => "null",
                };
                print!(
                    r#"{{"vendor":"{}","present":{},"source":{}}}"#,
                    s.vendor, s.present, source
                );
            }
            println!("]");
            return Ok(());
        }
        println!();
        println!(
            "  {BOLD}Vendor auth{BOLD:#}  {DIM}(tokenstat.ai login is separate, later){DIM:#}"
        );
        for s in rows {
            let state = match s.source {
                Some(tokenstat_sync::creds::TokenSource::Env) => "env override",
                Some(tokenstat_sync::creds::TokenSource::Stored) => "stored",
                Some(tokenstat_sync::creds::TokenSource::Discovered) => {
                    "discovered from app keychain"
                }
                None => "no token",
            };
            println!("  {DIM}{}{DIM:#}  {state}", s.vendor);
        }
        println!();
        println!("  {DIM}Cursor / Antigravity: sign in to the app, then tokenstat fetch.{DIM:#}");
        println!("  {DIM}Optional paste still works: tokenstat auth cursor --token …{DIM:#}");
        println!();
        return Ok(());
    }

    let vendor_name = vendor.ok_or_else(|| {
        anyhow::anyhow!("vendor required: cursor or antigravity (or pass --status)")
    })?;
    let vendor = match vendor_name.to_ascii_lowercase().as_str() {
        "cursor" => tokenstat_sync::Vendor::Cursor,
        "antigravity" | "anti" => tokenstat_sync::Vendor::Antigravity,
        other => anyhow::bail!("unknown vendor {other:?}, use cursor or antigravity"),
    };

    if logout {
        match vendor {
            tokenstat_sync::Vendor::Cursor => tokenstat_sync::cursor::logout()?,
            tokenstat_sync::Vendor::Antigravity => tokenstat_sync::antigravity::logout()?,
        }
        println!("  cleared {} token", vendor.as_str());
        return Ok(());
    }

    let (path, how) = match token {
        Some(t) if !t.trim().is_empty() => {
            let path = match vendor {
                tokenstat_sync::Vendor::Cursor => tokenstat_sync::cursor::auth(t)?,
                tokenstat_sync::Vendor::Antigravity => tokenstat_sync::antigravity::auth(t)?,
            };
            (path, "stored")
        }
        Some(_) => anyhow::bail!("empty token"),
        None => {
            // Convenience: pull whatever the vendor app already left locally.
            let (path, source) = match vendor {
                tokenstat_sync::Vendor::Cursor => tokenstat_sync::cursor::auth_auto()?,
                tokenstat_sync::Vendor::Antigravity => tokenstat_sync::antigravity::auth_auto()?,
            };
            let how = match source {
                tokenstat_sync::creds::TokenSource::Discovered => "discovered from app keychain",
                tokenstat_sync::creds::TokenSource::Env => "env",
                tokenstat_sync::creds::TokenSource::Stored => "stored",
            };
            (path, how)
        }
    };

    let g = good();
    println!(
        "  {g}{} {g:#}{} token → {}",
        how,
        vendor.as_str(),
        path.display()
    );
    println!("  {DIM}Local only. Never synced to tokenstat.ai.{DIM:#}");
    println!("  {DIM}Run tokenstat fetch  (or scan) to pull usage.{DIM:#}");
    println!();
    Ok(())
}

/// Check or apply a self-update from GitHub Releases.
pub fn self_update(check_only: bool, _yes: bool, json: bool) -> Result<()> {
    if check_only {
        let c = tokenstat_sync::check_latest().map_err(|e| anyhow::anyhow!("{e}"))?;
        if json {
            println!(
                r#"{{"current":"{}","latest":"{}","newer":{},"target":"{}","url":"{}"}}"#,
                c.current,
                c.latest,
                c.newer,
                tokenstat_sync::current_target(),
                c.html_url
            );
            return Ok(());
        }
        println!();
        println!("  {DIM}current{DIM:#}  {}", c.current);
        if c.latest.is_empty() {
            println!("  {DIM}latest{DIM:#}   (no GitHub release yet)");
        } else {
            println!("  {DIM}latest{DIM:#}   {}", c.latest);
        }
        println!(
            "  {DIM}target{DIM:#}   {}",
            tokenstat_sync::current_target()
        );
        if c.newer {
            let a = accent();
            println!();
            println!("  Update available. Run {a}tokenstat update{a:#}");
            println!("  {}", c.html_url);
        } else if !c.latest.is_empty() {
            let g = good();
            println!("  {g}up to date{g:#}");
        }
        println!();
        return Ok(());
    }

    let report = tokenstat_sync::apply_update().map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(
            r#"{{"from":"{}","to":"{}","path":"{}"}}"#,
            report.from,
            report.to,
            report.path.display()
        );
        return Ok(());
    }
    let g = good();
    println!();
    println!(
        "  {g}updated{g:#} {} → {}  {}",
        report.from,
        report.to,
        report.path.display()
    );
    println!("  {DIM}re-run the command in a new shell if this process looks odd{DIM:#}");
    println!();
    Ok(())
}

/// `update` as run by the scheduler.
///
/// Quiet by design, and never a failure the user has to act on: a background job
/// that could not reach GitHub today is not news, and the binary in place still
/// works. Only an error that means "the update was attempted and something is now
/// worth knowing" reaches the exit code.
pub fn self_update_scheduled(json: bool) -> Result<()> {
    match tokenstat_sync::scheduled_update() {
        Ok(tokenstat_sync::ScheduledUpdate::Disabled) => {
            if json {
                println!(r#"{{"skipped":"auto_update_off"}}"#);
            } else {
                println!("automatic updates are off, nothing to do");
            }
            Ok(())
        }
        Ok(tokenstat_sync::ScheduledUpdate::UpToDate(v)) => {
            if json {
                println!(r#"{{"up_to_date":"{v}"}}"#);
            } else {
                println!("up to date ({v})");
            }
            Ok(())
        }
        Ok(tokenstat_sync::ScheduledUpdate::NotOurs { latest, path }) => {
            // Not an error: a package manager owns this install, and saying so
            // once a day in a log is more useful than failing.
            if json {
                println!(
                    r#"{{"skipped":"not_ours","latest":"{latest}","path":"{}"}}"#,
                    path.display()
                );
            } else {
                println!(
                    "{latest} is available, but {} was installed by a package manager; \
                     update it there",
                    path.display()
                );
            }
            Ok(())
        }
        Ok(tokenstat_sync::ScheduledUpdate::Applied(r)) => {
            if json {
                println!(
                    r#"{{"from":"{}","to":"{}","path":"{}"}}"#,
                    r.from,
                    r.to,
                    r.path.display()
                );
            } else {
                println!("updated {} → {}", r.from, r.to);
            }
            Ok(())
        }
        Err(err) => {
            // Printed, not returned: a failed check must not make the scheduler
            // treat the unit as broken, and the previous binary is still in place
            // either way.
            if json {
                let msg = err
                    .to_string()
                    .replace('\\', "\\\\")
                    .replace('"', "\\\"")
                    .replace('\n', " ");
                println!(r#"{{"error":"{msg}"}}"#);
            } else {
                eprintln!("update check failed: {err}");
            }
            Ok(())
        }
    }
}

/// Turn automatic updates on or off, and install or remove the daily entry.
pub fn update_auto(value: &str, json: bool) -> Result<()> {
    let on = match value.trim().to_ascii_lowercase().as_str() {
        "on" | "1" | "true" | "yes" => true,
        "off" | "0" | "false" | "no" => false,
        other => anyhow::bail!("expected --auto on or --auto off, got {other}"),
    };
    tokenstat_sync::config::set_update_auto(on).map_err(|e| anyhow::anyhow!("{e}"))?;

    let home = directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .context("locating your home directory")?;
    let exe = crate::schedule::preferred_executable();
    let schedule_touched = if on {
        crate::schedule::install(
            &home,
            crate::schedule::Unit::Update,
            &exe,
            crate::schedule::Unit::Update.default_interval(),
        )
        .map(|_| true)
        .unwrap_or(false)
    } else {
        crate::schedule::uninstall(&home, crate::schedule::Unit::Update)
            .map(|r| r.removed)
            .unwrap_or(false)
    };

    if json {
        println!(r#"{{"auto_update":{on},"schedule_updated":{schedule_touched}}}"#);
        return Ok(());
    }
    let g = good();
    println!();
    if on {
        println!("  {g}automatic updates on{g:#}");
        println!("  {DIM}A newer release is downloaded, its checksum checked, and the{DIM:#}");
        println!("  {DIM}binary run and version-checked before it replaces this one.{DIM:#}");
        if schedule_touched {
            println!("  {g}installed{g:#} daily update schedule");
        } else {
            println!("  {DIM}Schedule the daily check with: tokenstat schedule --install{DIM:#}");
        }
    } else {
        println!("  {g}automatic updates off{g:#}");
        println!("  {DIM}tokenstat update still works when you run it yourself.{DIM:#}");
        if schedule_touched {
            println!("  {g}removed{g:#} daily update schedule");
        }
    }
    println!();
    Ok(())
}

/// Soft update check used after scan. Never fails the caller.
pub fn maybe_notify_update(json: bool) {
    if json {
        return;
    }
    let auto = tokenstat_sync::auto_apply_enabled();
    match tokenstat_sync::maybe_auto_update(auto) {
        Ok(Some(tokenstat_sync::UpdateOutcome::Available(c))) => {
            let a = accent();
            eprintln!(
                "  {DIM}update{DIM:#}  v{} available  {a}tokenstat update{a:#}  {}",
                c.latest, c.html_url
            );
        }
        Ok(Some(tokenstat_sync::UpdateOutcome::Applied(r))) => {
            let g = good();
            eprintln!("  {g}updated{g:#} {} → {}", r.from, r.to);
        }
        _ => {}
    }
}

/// Device-login against tokenstat.ai (or sandbox).
pub fn profile_login(host: Option<&str>, json: bool) -> Result<()> {
    let result = tokenstat_sync::login(host).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(
            r#"{{"host":"{}","handle":"{}","machine":"{}","schema_min_v":{},"schema_max_v":{}}}"#,
            result.host, result.handle, result.machine, result.schema_min_v, result.schema_max_v
        );
        return Ok(());
    }
    let g = good();
    println!();
    println!("  {g}logged in{g:#} as {BOLD}@{}{BOLD:#}", result.handle);
    println!("  {DIM}host{DIM:#}     {}", result.host);
    println!("  {DIM}machine{DIM:#}  {}", result.machine);
    println!(
        "  {DIM}schema{DIM:#}   [{}, {}]",
        result.schema_min_v, result.schema_max_v
    );
    println!("  {DIM}token stored under credentials/sync/ for this host{DIM:#}");
    println!();
    maybe_install_linked_schedules(host, false);
    let a = accent();
    println!("  Next: {a}tokenstat sync{a:#}");
    println!();
    Ok(())
}

/// Redeem a pairing code from the website. No browser, no polling.
pub fn profile_login_code(host: Option<&str>, code: &str, json: bool) -> Result<()> {
    let result = tokenstat_sync::login_with_code(host, code).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(
            r#"{{"host":"{}","handle":"{}","machine":"{}","schema_min_v":{},"schema_max_v":{}}}"#,
            result.host, result.handle, result.machine, result.schema_min_v, result.schema_max_v
        );
        return Ok(());
    }
    let g = good();
    println!();
    println!("  {g}connected{g:#} as {BOLD}@{}{BOLD:#}", result.handle);
    println!("  {DIM}host{DIM:#}     {}", result.host);
    println!("  {DIM}machine{DIM:#}  {}", result.machine);
    println!("  {DIM}token stored under credentials/sync/ for this host{DIM:#}");
    println!();
    maybe_install_linked_schedules(host, false);
    let a = accent();
    println!("  Next: {a}tokenstat sync{a:#}");
    println!();
    Ok(())
}

/// Best-effort sync (and auto-update) schedule after linking an account.
///
/// Goes through `repair` so a re-login also refreshes the scan entry and drops
/// a stale update unit when auto-apply is off.
fn maybe_install_linked_schedules(host: Option<&str>, quiet: bool) {
    let Some(home) = directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf()) else {
        return;
    };
    let exe = crate::schedule::preferred_executable();
    let info = match tokenstat_sync::scheduling_info(host) {
        Ok(i) if i.logged_in => i,
        _ => return,
    };
    let sync_interval = info
        .min_interval
        .unwrap_or_else(|| crate::schedule::Unit::Sync.default_interval());
    let want_update = tokenstat_sync::auto_apply_enabled();
    match crate::schedule::repair(
        &home,
        &exe,
        crate::schedule::Unit::Scan.default_interval(),
        crate::schedule::SyncAction::Install(sync_interval),
        want_update,
    ) {
        Ok(report) => {
            if quiet {
                return;
            }
            let g = good();
            if let Some(secs) = report.sync_interval_secs {
                println!(
                    "  {g}installed{g:#} sync every {} min {DIM}(+ up to {}s jitter){DIM:#}",
                    secs / 60,
                    tokenstat_sync::JITTER_WINDOW_SECS
                );
            }
            if report.update.is_some() {
                println!("  {g}installed{g:#} daily update check");
            } else if report.update_removed {
                println!("  {g}removed{g:#} stale update schedule");
            }
        }
        Err(e) => {
            if !quiet {
                println!("  {DIM}could not install sync schedule: {e}{DIM:#}");
                println!("  {DIM}run later with: tokenstat schedule --install{DIM:#}");
            }
        }
    }
}

/// Drop the sync token for a host. No server call.
///
/// Leaves the sync schedule in place: `sync --scheduled` exits quietly without
/// a token, and the next `tokenstat login` starts uploading again without
/// another `schedule --install`.
pub fn profile_logout(host: Option<&str>, json: bool) -> Result<()> {
    let host = tokenstat_sync::logout(host).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(r#"{{"host":"{host}","logged_out":true}}"#);
        return Ok(());
    }
    println!();
    println!("  cleared sync token for {host}");
    println!("  {DIM}sync schedule left in place (resumes after login){DIM:#}");
    println!();
    Ok(())
}

/// `GET /api/v1/me`.
pub fn profile_sync_status(host: Option<&str>, json: bool) -> Result<()> {
    let st = tokenstat_sync::sync_status(host).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!("{}", st.raw);
        return Ok(());
    }
    println!();
    println!("  {BOLD}tokenstat.ai{BOLD:#}");
    println!("  {DIM}host{DIM:#}      {}", st.host);
    println!(
        "  {DIM}handle{DIM:#}    {}",
        st.handle.as_deref().unwrap_or("-")
    );
    println!(
        "  {DIM}tier{DIM:#}      {}",
        st.tier.as_deref().unwrap_or("-")
    );
    println!(
        "  {DIM}last sync{DIM:#} {}",
        st.last_sync_at.as_deref().unwrap_or("-")
    );
    if let (Some(min_v), Some(max_v)) = (st.schema_min_v, st.schema_max_v) {
        let current = st
            .schema_current
            .map(|c| c.to_string())
            .unwrap_or_else(|| "-".into());
        println!("  {DIM}schema{DIM:#}   [{min_v}, {max_v}]  current {current}");
    }
    if st.machines.is_empty() {
        println!("  {DIM}machines{DIM:#}  (none yet)");
    } else {
        println!("  {DIM}machines{DIM:#}  {}", st.machines.len());
        for m in &st.machines {
            let id = m.get("id").and_then(|v| v.as_str()).unwrap_or("?");
            let label = m.get("label").and_then(|v| v.as_str()).unwrap_or("");
            let last = m
                .get("last_sync_at")
                .and_then(|v| v.as_str())
                .unwrap_or("-");
            if label.is_empty() {
                println!("    {id}  last {last}");
            } else {
                println!("    {id} ({label})  last {last}");
            }
        }
    }
    println!();
    Ok(())
}

/// Upload (or dry-run) the sealed sync payload.
pub fn profile_sync(
    store: &Store,
    host: Option<&str>,
    prune: bool,
    window: Option<&str>,
    dry_run: bool,
    tz_name: Option<&str>,
    json: bool,
) -> Result<()> {
    let result = tokenstat_sync::sync(
        store,
        tokenstat_sync::SyncOptions {
            host_flag: host,
            prune,
            window,
            dry_run,
            tz_name,
        },
    )
    .map_err(|e| anyhow::anyhow!("{e}"))?;

    if dry_run {
        // Canonical JSON already printed by the sync client.
        return Ok(());
    }

    if json {
        println!(
            r#"{{"host":"{}","from":"{}","to":"{}","rows":{},"idempotency_key":"{}","prune":{}}}"#,
            result.host,
            result.window.from,
            result.window.to,
            result.rows,
            result.idempotency_key,
            prune
        );
        return Ok(());
    }

    let g = good();
    println!();
    println!(
        "  {g}synced{g:#} {} rows  {}..{}",
        ui::exact(result.rows),
        result.window.from,
        result.window.to
    );
    println!("  {DIM}host{DIM:#}  {}", result.host);
    if prune {
        println!("  {DIM}prune{DIM:#} true");
    }
    println!();
    Ok(())
}

/// `sync` as run by the scheduler.
///
/// A background job has no one to read it, so the boring outcomes (no account,
/// not due yet, archive busy, brief network blip) print a single line and exit
/// 0. Only a durable failure is loud, because that is the one worth finding in
/// the log.
pub fn profile_sync_scheduled(
    store: &Store,
    host: Option<&str>,
    window: Option<&str>,
    tz_name: Option<&str>,
    json: bool,
) -> Result<()> {
    let outcome = tokenstat_sync::sync_scheduled(
        store,
        tokenstat_sync::SyncOptions {
            host_flag: host,
            prune: false,
            window,
            dry_run: false,
            tz_name,
        },
    )
    .map_err(|e| anyhow::anyhow!("{e}"))?;

    match outcome {
        tokenstat_sync::ScheduledOutcome::NotLoggedIn => {
            if json {
                println!(r#"{{"skipped":"not_logged_in"}}"#);
            } else {
                println!("no account linked for this host, nothing to sync");
            }
            Ok(())
        }
        tokenstat_sync::ScheduledOutcome::Held { until } => {
            let until = until.unwrap_or_else(|| "later".into());
            if json {
                println!(r#"{{"skipped":"rate_limited","next_allowed_at":"{until}"}}"#);
            } else {
                println!("not due yet, next sync allowed at {until}");
            }
            Ok(())
        }
        tokenstat_sync::ScheduledOutcome::Deferred { reason } => {
            if json {
                let escaped = reason.replace('\\', "\\\\").replace('"', "\\\"");
                println!(r#"{{"skipped":"deferred","reason":"{escaped}"}}"#);
            } else if reason.contains("database is locked")
                || reason.contains("database is busy")
                || reason.contains("database error")
            {
                println!("archive busy, will retry next run");
            } else if reason.contains("schema fetch failed") || reason.contains("error sending") {
                println!("schema unreachable, will retry next run");
            } else {
                println!("sync deferred, will retry next run: {reason}");
            }
            Ok(())
        }
        tokenstat_sync::ScheduledOutcome::Synced(result) => {
            if json {
                println!(
                    r#"{{"host":"{}","from":"{}","to":"{}","rows":{},"idempotency_key":"{}"}}"#,
                    result.host,
                    result.window.from,
                    result.window.to,
                    result.rows,
                    result.idempotency_key
                );
            } else {
                println!(
                    "synced {} rows {}..{}",
                    result.rows, result.window.from, result.window.to
                );
            }
            Ok(())
        }
    }
}

/// Five-hour usage blocks (gap-based, Claude-style rate-limit windows).
pub fn blocks(store: &Store, q: &Query, json: bool) -> Result<()> {
    let now_ms = jiff::Timestamp::now().as_millisecond();
    let rows = store.blocks(q, now_ms)?;
    if rows.is_empty() {
        return empty_range(json);
    }
    if json {
        println!("[");
        for (i, b) in rows.iter().enumerate() {
            let c = &b.counters;
            print!(
                r#"  {{"start_ms":{},"end_ms":{},"active":{},"events":{},"sessions":{},"input_fresh":{},"cache_read":{},"cache_write_5m":{},"cache_write_1h":{},"output":{},"total":{}}}"#,
                b.start_ms,
                b.end_ms,
                b.active,
                b.events,
                b.sessions,
                num(c.input_fresh),
                num(c.cache_read),
                num(c.cache_write_5m),
                num(c.cache_write_1h),
                num(c.output),
                c.total(),
            );
            if i + 1 < rows.len() {
                println!(",");
            } else {
                println!();
            }
        }
        println!("]");
        return Ok(());
    }

    let tz = jiff::tz::TimeZone::system();
    let max = rows
        .iter()
        .map(|b| b.counters.total())
        .max()
        .unwrap_or(1)
        .max(1);

    println!();
    println!(
        "  {DIM}{}  {}  {}  {}  {}{DIM:#}",
        ui::pad_right("Block", 22),
        ui::pad_left("events", 8),
        ui::pad_left("in+out", 8),
        ui::pad_left("total", 9),
        "status",
    );

    // Newest first: the active block should be at the top.
    for b in rows.iter().rev().take(40) {
        let start = format_block_instant(b.start_ms, &tz);
        let c = &b.counters;
        let in_out = c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0);
        let frac = c.total() as f64 / max as f64;
        let status = if b.active {
            let left = ((b.end_ms - now_ms).max(0) / 60_000) as u64;
            format!("active · {left}m left")
        } else {
            "closed".into()
        };
        let a = accent();
        let status_s = if b.active {
            format!("{a}{status}{a:#}")
        } else {
            format!("{DIM}{status}{DIM:#}")
        };
        println!(
            "  {}  {}  {}  {}  {}  {a}{}{a:#}",
            ui::pad_right(&start, 22),
            ui::pad_left(&ui::exact(b.events), 8),
            ui::pad_left(&ui::tokens(in_out), 8),
            ui::pad_left(&total_cell(c), 9),
            status_s,
            ui::bar(frac, 12),
        );
    }
    if rows.len() > 40 {
        println!("  {DIM}… {} older blocks omitted{DIM:#}", rows.len() - 40);
    }
    println!();
    Ok(())
}

fn format_block_instant(ms: i64, tz: &jiff::tz::TimeZone) -> String {
    match jiff::Timestamp::from_millisecond(ms) {
        Ok(ts) => {
            let z = ts.to_zoned(tz.clone());
            format!("{}", z.strftime("%Y-%m-%d %H:%M"))
        }
        Err(_) => ms.to_string(),
    }
}

/// Write archive events as JSON or CSV. Counters and ids only.
pub fn export(
    store: &Store,
    q: &Query,
    format: &str,
    out: Option<&Path>,
    json_flag: bool,
) -> Result<()> {
    let rows = store.events(q)?;
    if rows.is_empty() {
        return empty_range(json_flag || format == "json");
    }

    let format = if json_flag { "json" } else { format };
    let mut sink: Box<dyn Write> = match out {
        Some(path) => Box::new(
            std::fs::File::create(path).with_context(|| format!("create {}", path.display()))?,
        ),
        None => Box::new(std::io::stdout()),
    };

    match format {
        "csv" => {
            writeln!(
                sink,
                "id,source,ts_ms,local_date,model,session,project,input_fresh,cache_read,cache_write_5m,cache_write_1h,output"
            )?;
            for e in &rows {
                let c = &e.counters;
                writeln!(
                    sink,
                    "{},{},{},{},{},{},{},{},{},{},{},{}",
                    csv_escape(&e.id),
                    csv_escape(&e.source),
                    e.ts_ms,
                    csv_escape(&e.local_date),
                    csv_escape(&e.model),
                    csv_escape(&e.session),
                    csv_escape(&e.project),
                    opt_num(c.input_fresh),
                    opt_num(c.cache_read),
                    opt_num(c.cache_write_5m),
                    opt_num(c.cache_write_1h),
                    opt_num(c.output),
                )?;
            }
        }
        "json" => {
            writeln!(sink, "[")?;
            for (i, e) in rows.iter().enumerate() {
                let c = &e.counters;
                write!(
                    sink,
                    r#"  {{"id":{},"source":{},"ts_ms":{},"local_date":{},"model":{},"session":{},"project":{},"input_fresh":{},"cache_read":{},"cache_write_5m":{},"cache_write_1h":{},"output":{}}}"#,
                    json_str(&e.id),
                    json_str(&e.source),
                    e.ts_ms,
                    json_str(&e.local_date),
                    json_str(&e.model),
                    json_str(&e.session),
                    json_str(&e.project),
                    num(c.input_fresh),
                    num(c.cache_read),
                    num(c.cache_write_5m),
                    num(c.cache_write_1h),
                    num(c.output),
                )?;
                if i + 1 < rows.len() {
                    writeln!(sink, ",")?;
                } else {
                    writeln!(sink)?;
                }
            }
            writeln!(sink, "]")?;
        }
        other => anyhow::bail!("unknown export format {other:?}, use csv or json"),
    }

    if let Some(path) = out {
        eprintln!(
            "  wrote {} events to {}",
            ui::exact(rows.len() as u64),
            path.display()
        );
    }
    Ok(())
}

fn csv_escape(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn json_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn opt_num(v: Option<u64>) -> String {
    v.map(|n| n.to_string()).unwrap_or_default()
}

fn format_age(secs: i64) -> String {
    match secs {
        s if s < 60 => format!("{s}s"),
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

fn json_opt(v: Option<&str>) -> String {
    match v {
        Some(s) => format!("\"{}\"", s.replace('"', "\\\"")),
        None => "null".to_string(),
    }
}

fn print_json_buckets(rows: &[Bucket]) -> Result<()> {
    let mut out = std::io::stdout().lock();
    write!(out, "[")?;
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            write!(out, ",")?;
        }
        let c = &r.counters;
        write!(
            out,
            r#"{{"key":"{}","input_fresh":{},"cache_read":{},"cache_write_5m":{},"cache_write_1h":{},"output":{},"total":{},"events":{},"sessions":{}}}"#,
            r.key.replace('"', "\\\""),
            num(c.input_fresh),
            num(c.cache_read),
            num(c.cache_write_5m),
            num(c.cache_write_1h),
            num(c.output),
            c.total(),
            r.events,
            r.sessions,
        )?;
    }
    writeln!(out, "]")?;
    Ok(())
}

/// Unreported stays `null` in JSON, so a consumer can tell it from zero.
fn num(v: Option<u64>) -> String {
    v.map(|n| n.to_string()).unwrap_or_else(|| "null".into())
}

/// One line for a shell prompt.
///
/// Every failure path here is silent. A statusline that prints an error, or
/// worse blocks, on every prompt is worse than one that prints nothing, so the
/// caller ignores the result and this never scans the filesystem.
pub fn statusline(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    format: &str,
    max_age_secs: u64,
) -> Result<()> {
    let today = jiff::Timestamp::now().to_zoned(tz.clone()).date();
    let month_start = today.first_of_month();
    let today_s = today.to_string();
    let month_s = month_start.to_string();
    let (day, month) = store.statusline_snapshot(&today_s, &month_s)?;

    let prices = PriceTable::load();
    // Sum list-rate value per model so a multi-model day is not priced as
    // Sonnet-5. Still an approximation of value, never a charge.
    let value = |since: &str, until: &str| -> String {
        let q = Query {
            since: Some(since.to_string()),
            until: Some(until.to_string()),
            ..Query::default()
        };
        let Ok(rows) = store.report(GroupBy::Model, &q) else {
            return String::new();
        };
        let mut total = 0.0;
        let mut any = false;
        for r in rows {
            if let Some(v) = EquivalentValue::price(&prices, &model_label(&r.key), &r.counters) {
                total += v.dollars();
                any = true;
            }
        }
        if any { ui::usd(total) } else { String::new() }
    };
    let in_out = |c: &Counters| ui::tokens(c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0));

    let stale = match max_age_secs {
        0 => String::new(),
        limit => match store
            .meta("last_scan_ms")
            .ok()
            .flatten()
            .and_then(|s| s.parse::<i64>().ok())
        {
            Some(ms) => {
                let age = (jiff::Timestamp::now().as_millisecond() - ms).max(0) / 1000;
                if age as u64 > limit {
                    // Kick a background scan so the next prompt is fresher.
                    // Never wait here: the statusline must stay archive-only.
                    spawn_background_scan();
                    "*".into()
                } else {
                    String::new()
                }
            }
            None => {
                spawn_background_scan();
                "*".into()
            }
        },
    };

    let line = format
        .replace("{today}", &ui::tokens(day.total()))
        .replace("{month}", &ui::tokens(month.total()))
        .replace("{today_in_out}", &in_out(&day))
        .replace("{month_in_out}", &in_out(&month))
        .replace("{today_value}", &value(&today_s, &today_s))
        .replace("{month_value}", &value(&month_s, &today_s))
        .replace("{stale}", &stale);

    // Plain stdout, not anstream: a prompt supplies its own colour and a
    // stray reset sequence would bleed into the shell.
    println!("{line}");
    Ok(())
}

/// Start `tokenstat scan` in the background if no other refresh holds the lock.
///
/// Failures are silent: a statusline must never print errors or block.
fn spawn_background_scan() {
    let Ok(dirs) = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .ok_or(())
        .map(|d| d.data_dir().to_path_buf())
    else {
        return;
    };
    let lock_path = dirs.join("scan.lock");
    let _ = std::fs::create_dir_all(&dirs);

    // Try to create the lock exclusively. If it already exists and is fresh,
    // another refresh is in flight or finished recently.
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
    {
        Ok(f) => {
            let _ = f.set_len(0);
            drop(f);
        }
        Err(_) => {
            // Stale lock older than 10 minutes: steal it. Fresher: skip.
            if let Ok(meta) = std::fs::metadata(&lock_path) {
                if let Ok(modified) = meta.modified() {
                    if modified
                        .elapsed()
                        .map(|a| a.as_secs() < 600)
                        .unwrap_or(true)
                    {
                        return;
                    }
                }
            }
            let _ = std::fs::remove_file(&lock_path);
            if std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&lock_path)
                .is_err()
            {
                return;
            }
        }
    }

    let Ok(exe) = std::env::current_exe() else {
        let _ = std::fs::remove_file(&lock_path);
        return;
    };

    #[cfg(unix)]
    {
        let mut cmd = std::process::Command::new(exe);
        cmd.arg("scan")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        // Lock file mtime prevents a stampede for up to 10 minutes.
        let _ = cmd.spawn();
    }
    #[cfg(not(unix))]
    {
        let _ = std::process::Command::new(exe)
            .arg("scan")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

pub struct SetupOptions<'a> {
    pub yes: bool,
    pub code: Option<&'a str>,
    pub local_only: bool,
    pub no_schedule: bool,
    pub host: Option<&'a str>,
    pub json: bool,
}

/// Ask a yes/no question, defaulting to yes.
///
/// Running `setup` is itself the request, so the default is yes and a non-tty
/// proceeds rather than skipping: piping this into a shell is how install scripts
/// call it, and a no-op would make the command useless there. The prompt exists to
/// give someone at a keyboard a chance to decline a step, not to re-ask whether
/// they meant to run the command they just ran.
fn confirm(question: &str, assume_yes: bool) -> bool {
    use std::io::{IsTerminal, Write};
    if assume_yes || !std::io::stdin().is_terminal() {
        return true;
    }
    let a = accent();
    print!("  {question} {a}[Y/n]{a:#} ");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line).is_err() {
        return true;
    }
    !matches!(line.trim().to_ascii_lowercase().as_str(), "n" | "no")
}

/// One command that gets someone from "installed" to "it is working".
///
/// The steps already existed as separate commands, which is the problem: nothing
/// told you the order, that scanning early matters, or that syncing is a thing you
/// opt into. Re-runnable, and each step says when it has nothing to do, so this is
/// also a reasonable answer to "is my setup right?".
///
/// One question, at the start, then it gets on with it. Asking before every step
/// turned a setup command into an interrogation where the answer was always going
/// to be yes: running `setup` IS the decision. `--yes` skips even that question.
pub fn setup(db_path: &Path, tz: &jiff::tz::TimeZone, opts: SetupOptions<'_>) -> Result<()> {
    use crate::schedule::Unit;

    let g = good();
    let a = accent();
    if !opts.json {
        println!();
        println!("  {BOLD}Setting up tokenstat{BOLD:#}");
        println!(
            "  {DIM}Three things: read the logs your AI tools already write, install an{DIM:#}"
        );
        println!(
            "  {DIM}hourly scan so log cleanup cannot take your history, and connect a{DIM:#}"
        );
        println!(
            "  {DIM}tokenstat.ai account (a browser opens for that; --local-only skips it).{DIM:#}"
        );
        println!();
    }
    if !confirm("Go ahead?", opts.yes) {
        if !opts.json {
            println!();
            println!("  {DIM}Stopped. Nothing was changed.{DIM:#}");
            println!();
        }
        return Ok(());
    }
    if !opts.json {
        println!();
    }

    // 1. Scan. First because it is the thing with a deadline: Claude Code deletes
    // transcripts after 30 days, so every day spent deciding costs history.
    let mut store = Store::open(db_path)?;
    let report = tokenstat_core::scan(&mut store, tz)?;
    if !opts.json {
        println!("  {g}1{g:#} Read your existing logs");
    }
    scan_report(&report, opts.json)?;

    let totals = store.totals(&Query::default())?;
    if !opts.json {
        if totals.events == 0 {
            println!("  {DIM}No usage found yet. That is normal on a machine that has not{DIM:#}");
            println!("  {DIM}run an AI coding tool. Run this again once it has.{DIM:#}");
        } else {
            println!(
                "  {DIM}{} events across {} active days are now archived{DIM:#}",
                ui::exact(totals.events),
                ui::exact(totals.days)
            );
        }
        println!();
    }

    // 2. Schedule. The whole point of the archive is that it outlives the logs.
    let scheduled = if opts.no_schedule {
        if !opts.json {
            println!("  {g}2{g:#} Keep it current");
            println!("  {DIM}skipped schedule (--no-schedule){DIM:#}");
            println!();
        }
        false
    } else {
        if !opts.json {
            println!("  {g}2{g:#} Keep it current");
            println!(
                "  {DIM}A scheduled scan is what stops the next cleanup losing a month.{DIM:#}"
            );
        }
        // No second question: the one at the top covered it.
        // Scan only here so a failed login still leaves the archive catching up.
        // After the account step we run `repair`, which refreshes every unit and
        // drops a stale sync/update left by an older install.
        let installed = {
            let home = directories::BaseDirs::new()
                .map(|d| d.home_dir().to_path_buf())
                .context("locating your home directory")?;
            let exe = crate::schedule::preferred_executable();
            match crate::schedule::install(&home, Unit::Scan, &exe, Unit::Scan.default_interval()) {
                Ok(_) => {
                    if !opts.json {
                        println!("  {g}installed{g:#} hourly scan");
                    }
                    true
                }
                Err(e) => {
                    if !opts.json {
                        println!("  {DIM}could not install the schedule: {e}{DIM:#}");
                        println!("  {DIM}run later with: tokenstat schedule --install{DIM:#}");
                    }
                    false
                }
            }
        };
        if !opts.json {
            println!();
        }
        installed
    };

    // 3. Account. Connecting one is a large part of why this command exists, so it
    // offers to do it rather than printing two commands and stopping. A pairing
    // code does it without a browser; otherwise the device flow runs here.
    let mut connected = false;
    if !opts.local_only {
        let info = tokenstat_sync::scheduling_info(opts.host).ok();
        let already = info.as_ref().is_some_and(|i| i.logged_in);
        if !opts.json {
            println!("  {g}3{g:#} Connect an account (optional)");
        }
        if already {
            connected = true;
            if !opts.json {
                println!(
                    "  {DIM}already connected for {}{DIM:#}",
                    info.as_ref()
                        .map(|i| i.host.as_str())
                        .unwrap_or("this host")
                );
            }
        } else if let Some(code) = opts.code {
            match tokenstat_sync::login_with_code(opts.host, code) {
                Ok(res) => {
                    connected = true;
                    if !opts.json {
                        println!("  {g}connected{g:#} as {BOLD}@{}{BOLD:#}", res.handle);
                    }
                }
                Err(e) => {
                    if !opts.json {
                        println!("  {DIM}pairing failed: {e}{DIM:#}");
                    }
                }
            }
        } else {
            // The device flow needs a browser and a person, so it is offered only
            // where both can exist. Starting it into a pipe would leave the process
            // waiting fifteen minutes for an approval nobody is there to give.
            let interactive = std::io::IsTerminal::is_terminal(&std::io::stdin());
            if !opts.json {
                println!("  {DIM}Counters only, and nothing is published until you ask.{DIM:#}");
            }
            if interactive {
                match tokenstat_sync::login(opts.host) {
                    Ok(res) => {
                        connected = true;
                        println!("  {g}connected{g:#} as {BOLD}@{}{BOLD:#}", res.handle);
                    }
                    Err(e) => {
                        println!("  {DIM}not connected: {e}{DIM:#}");
                        println!("  {DIM}try again later with: tokenstat login{DIM:#}");
                    }
                }
            } else if !opts.json {
                println!("  {DIM}Two ways in, whenever you want one:{DIM:#}");
                println!(
                    "    {a}tokenstat login{a:#}                    {DIM}opens a browser{DIM:#}"
                );
                println!(
                    "    {a}tokenstat setup --code WXYZ-1234{a:#}   {DIM}code from tokenstat.ai/link{DIM:#}"
                );
            }
        }
        if !opts.json {
            println!();
        }
    }

    // 4. Repair the full schedule layout, then first sync when there is an account.
    // Re-running setup / the website installer refreshes paths and intervals.
    // Sync is only installed when linked; if not linked yet, an existing sync
    // unit is left alone so logout does not undo install-and-forget.
    let mut sync_scheduled = false;
    if !opts.no_schedule {
        let home = directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf());
        let exe = crate::schedule::preferred_executable();
        if let Some(home) = home {
            let sync_interval = tokenstat_sync::scheduling_info(opts.host)
                .ok()
                .and_then(|i| i.min_interval)
                .unwrap_or_else(|| Unit::Sync.default_interval());
            let want_update = tokenstat_sync::auto_apply_enabled();
            let sync_action = if connected {
                crate::schedule::SyncAction::Install(sync_interval)
            } else {
                crate::schedule::SyncAction::Keep
            };
            match crate::schedule::repair(
                &home,
                &exe,
                Unit::Scan.default_interval(),
                sync_action,
                want_update,
            ) {
                Ok(report) => {
                    sync_scheduled = report.sync.is_some();
                    if !opts.json {
                        if let Some(secs) = report.sync_interval_secs {
                            println!(
                                "  {g}installed{g:#} sync every {} min {DIM}(+ up to {}s jitter){DIM:#}",
                                secs / 60,
                                tokenstat_sync::JITTER_WINDOW_SECS
                            );
                        }
                        if report.update.is_some() {
                            println!("  {g}installed{g:#} daily update check");
                        } else if report.update_removed {
                            println!("  {g}removed{g:#} stale update schedule");
                        }
                        if sync_scheduled || report.update_removed {
                            println!();
                        }
                    }
                }
                Err(e) => {
                    if !opts.json {
                        println!("  {DIM}could not repair schedule: {e}{DIM:#}");
                        println!("  {DIM}run later with: tokenstat schedule --install{DIM:#}");
                        println!();
                    }
                }
            }
        }
    }

    if connected && totals.events > 0 {
        match tokenstat_sync::sync(
            &store,
            tokenstat_sync::SyncOptions {
                host_flag: opts.host,
                prune: false,
                window: None,
                dry_run: false,
                tz_name: None,
            },
        ) {
            Ok(res) => {
                if !opts.json {
                    println!("  {g}4{g:#} Sent the first window");
                    println!(
                        "  {DIM}{} rows, {}..{}{DIM:#}",
                        ui::exact(res.rows),
                        res.window.from,
                        res.window.to
                    );
                    println!();
                }
            }
            Err(e) => {
                if !opts.json {
                    println!("  {g}4{g:#} First sync");
                    println!("  {DIM}not sent: {e}{DIM:#}");
                    println!();
                }
            }
        }
    }

    if opts.json {
        println!(
            r#"{{"events":{},"active_days":{},"scheduled":{},"connected":{}}}"#,
            totals.events, totals.days, scheduled, connected
        );
        return Ok(());
    }

    println!("  {BOLD}Done.{BOLD:#} Try {a}tokenstat{a:#} for the full-screen view,");
    println!("  or {a}tokenstat summary{a:#} for one screen of numbers.");
    if connected {
        if sync_scheduled {
            println!("  {DIM}Your account updates on its own from here.{DIM:#}");
        } else {
            println!(
                "  {DIM}To keep the profile current: {DIM:#}{a}tokenstat schedule --install{a:#}"
            );
        }
    }
    println!();
    Ok(())
}

/// Show, or install, the scheduler entry that keeps the archive current.
pub fn schedule(
    install: bool,
    every_mins: u64,
    sync_every_mins: Option<u64>,
    no_sync: bool,
) -> Result<()> {
    use crate::schedule::{self as sched, Platform, Unit};

    let exe = sched::preferred_executable();
    let interval = every_mins.max(1) * 60;
    let platform = Platform::detect();

    // The sync unit is only worth installing for an account, and its cadence is
    // the plan's, not a number the user should have to know. An explicit
    // --sync-every still wins, for testing against a sandbox.
    let info = tokenstat_sync::scheduling_info(None).ok();
    let want_sync = !no_sync && info.as_ref().is_some_and(|i| i.logged_in);
    let sync_interval = match sync_every_mins {
        Some(m) => m.max(1) * 60,
        None => info
            .as_ref()
            .and_then(|i| i.min_interval)
            .unwrap_or_else(|| Unit::Sync.default_interval()),
    };
    // Default on. Opt out with `tokenstat update --auto off` (removes the unit).
    let want_update = tokenstat_sync::auto_apply_enabled();
    let update_interval = Unit::Update.default_interval();

    if install {
        let home = directories::BaseDirs::new()
            .map(|d| d.home_dir().to_path_buf())
            .context("locating your home directory")?;
        let g = good();
        println!();

        if want_update {
            // Scheduler does not inherit TOKENSTAT_AUTO_UPDATE. Persist on so the
            // daily unit matches what we are about to install.
            if tokenstat_sync::config::load()
                .ok()
                .and_then(|c| c.update.auto)
                != Some(true)
            {
                let _ = tokenstat_sync::config::set_update_auto(true);
            }
        }

        let sync_action = if want_sync {
            sched::SyncAction::Install(sync_interval)
        } else if no_sync {
            sched::SyncAction::Remove
        } else {
            // Not linked: leave an existing sync unit alone so logout does not
            // undo install-and-forget. It will no-op until the next login.
            sched::SyncAction::Keep
        };
        let report = sched::repair(&home, &exe, interval, sync_action, want_update)?;

        if let Some(report) = &report.scan {
            println!("  {g}Installed{g:#} scan every {every_mins} min");
            for path in &report.paths {
                println!("  {DIM}{}{DIM:#}", path.display());
            }
            if let Some(hint) = &report.hint {
                println!("  {DIM}{hint}{DIM:#}");
            }
        }

        if let Some(report) = &report.sync {
            println!();
            println!(
                "  {g}Installed{g:#} sync every {} min {DIM}(+ up to {}s jitter){DIM:#}",
                sync_interval / 60,
                tokenstat_sync::JITTER_WINDOW_SECS
            );
            for path in &report.paths {
                println!("  {DIM}{}{DIM:#}", path.display());
            }
            if let Some(hint) = &report.hint {
                println!("  {DIM}{hint}{DIM:#}");
            }
        } else if report.sync_removed {
            println!();
            println!("  {g}Removed{g:#} sync schedule (--no-sync)");
        } else if !no_sync {
            println!();
            println!("  {DIM}No account linked, so nothing is uploaded yet.{DIM:#}");
            println!(
                "  {DIM}An existing sync schedule is left in place. Run: tokenstat login{DIM:#}"
            );
        } else {
            println!();
            println!("  {DIM}Sync schedule skipped (--no-sync).{DIM:#}");
        }

        if let Some(report) = &report.update {
            println!();
            println!("  {g}Installed{g:#} daily update check");
            for path in &report.paths {
                println!("  {DIM}{}{DIM:#}", path.display());
            }
            if let Some(hint) = &report.hint {
                println!("  {DIM}{hint}{DIM:#}");
            }
        } else if report.update_removed {
            println!();
            println!("  {g}Removed{g:#} stale update schedule");
        } else {
            println!();
            println!("  {DIM}Automatic updates are off, so no update entry was installed.{DIM:#}");
            println!("  {DIM}Turn them on with: tokenstat update --auto on{DIM:#}");
        }
        println!();
        return Ok(());
    }

    println!();
    println!("  {BOLD}Keep your history from disappearing{BOLD:#}");
    println!();
    println!("  {DIM}Claude Code deletes its transcripts after 30 days by default.{DIM:#}");
    println!("  {DIM}Anything not scanned before then is gone from this machine.{DIM:#}");
    println!("  {DIM}tokenstat keeps whatever it has already read.{DIM:#}");
    println!();

    print_unit(platform, Unit::Scan, &exe, interval);
    if want_sync {
        println!();
        println!("  {BOLD}Keep the profile current too{BOLD:#}");
        println!();
        println!("  {DIM}A second entry, because syncing is metered by your plan and{DIM:#}");
        println!("  {DIM}scanning is not. It waits its turn and skips a run the server{DIM:#}");
        println!("  {DIM}would refuse, so nothing here has to be tuned.{DIM:#}");
        println!();
        print_unit(platform, Unit::Sync, &exe, sync_interval);
    }
    if want_update {
        println!();
        println!("  {BOLD}And check for a new release once a day{BOLD:#}");
        println!();
        println!("  {DIM}Automatic updates are on. This entry downloads a newer{DIM:#}");
        println!("  {DIM}release, checks its checksum, then runs it and confirms its{DIM:#}");
        println!("  {DIM}version before it replaces this binary. If the new one cannot{DIM:#}");
        println!("  {DIM}run, the old one goes back.{DIM:#}");
        println!();
        print_unit(platform, Unit::Update, &exe, update_interval);
    }
    println!();
    Ok(())
}

/// Print the scheduler entry for one unit, for a user who would rather install
/// it themselves than have a tool write to their machine.
fn print_unit(
    platform: crate::schedule::Platform,
    unit: crate::schedule::Unit,
    exe: &str,
    interval: u64,
) {
    use crate::schedule::{self as sched, Platform};

    let label = unit.label();
    match platform {
        Platform::Launchd => {
            let home = directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf());
            let path = home
                .as_ref()
                .map(|h| sched::launchd_path(h, unit).display().to_string())
                .unwrap_or_else(|| format!("~/Library/LaunchAgents/{label}.plist"));
            let log = home
                .as_ref()
                .map(|h| sched::launchd_log_path(h, unit).display().to_string())
                .unwrap_or_else(|| format!("~/Library/Logs/{label}.log"));
            println!("  Save this as {path}");
            println!("  {DIM}or run: tokenstat schedule --install{DIM:#}");
            println!();
            for line in sched::launchd_plist(unit, exe, interval, &log).lines() {
                println!("  {line}");
            }
            println!();
            println!("  Then: launchctl load -w {path}");
        }
        Platform::SystemdUser => {
            let (service, timer) = sched::systemd_units(unit, exe, interval);
            println!("  ~/.config/systemd/user/{label}.service");
            println!();
            for line in service.lines() {
                println!("  {line}");
            }
            println!("  ~/.config/systemd/user/{label}.timer");
            println!();
            for line in timer.lines() {
                println!("  {line}");
            }
            println!("  Then: systemctl --user enable --now {label}.timer");
            println!("  {DIM}or run: tokenstat schedule --install{DIM:#}");
        }
        Platform::WindowsTaskScheduler => {
            println!("  Run this once, in a terminal:");
            println!();
            println!("  {}", sched::windows_command(unit, exe, interval));
            println!();
            println!("  {DIM}or run: tokenstat schedule --install{DIM:#}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_renders_as_dash_not_zero() {
        assert_eq!(cell(None), "-");
        assert_eq!(cell(Some(0)), "0");
    }

    #[test]
    fn partial_totals_are_marked() {
        let complete = Counters {
            input_fresh: Some(1),
            cache_read: Some(1),
            cache_write_5m: Some(1),
            cache_write_1h: Some(1),
            output: Some(1),
        };
        assert_eq!(total_cell(&complete), "5");
        let partial = Counters {
            input_fresh: Some(1),
            ..Default::default()
        };
        assert_eq!(total_cell(&partial), "1+");
    }

    #[test]
    fn json_distinguishes_null_from_zero() {
        assert_eq!(num(None), "null");
        assert_eq!(num(Some(0)), "0");
    }
}
