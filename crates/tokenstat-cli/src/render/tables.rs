use std::io::Write;
use std::path::Path;

use anstream::println;
use anyhow::{Context, Result};
use tokenstat_core::{Bucket, GroupBy, PriceTable, Query, Store};

use super::*;
use crate::ui::{self, BOLD, DIM, accent};

pub fn grouped(store: &Store, group: GroupBy, q: &Query, label: &str, json: bool) -> Result<()> {
    let rows = store.report(group, q)?;
    if rows.is_empty() {
        return empty_range(json);
    }
    if json {
        return print_json_buckets(&rows);
    }
    print_table(&rows, label, group);
    note_unmeasured_days(store, q);
    Ok(())
}

/// Name the days in range that were worked and have no measurement.
///
/// A note rather than rows in the table. A row of zeros would say the day
/// happened and cost nothing, which is the false statement this whole thing
/// exists to stop, and a row of dashes would have to be excluded from every
/// total and from the trend line anyway. The days are named so they can be
/// recognised, and the totals above are honestly a floor.
pub(super) fn note_unmeasured_days(store: &Store, q: &Query) {
    let days = store
        .days_active_without_usage("claude_code")
        .unwrap_or_default();
    let in_range: Vec<&String> = days
        .iter()
        .filter(|d| {
            q.since.as_deref().is_none_or(|s| d.as_str() >= s)
                && q.until.as_deref().is_none_or(|u| d.as_str() <= u)
        })
        .collect();
    if in_range.is_empty() {
        return;
    }
    let shown: Vec<&str> = in_range.iter().take(6).map(|d| d.as_str()).collect();
    let more = in_range.len() - shown.len();
    println!();
    println!(
        "  {DIM}{} day{} in this range were worked with no usage on record: {}{}{DIM:#}",
        in_range.len(),
        if in_range.len() == 1 { "" } else { "s" },
        shown.join(", "),
        if more > 0 {
            format!(" and {more} more")
        } else {
            String::new()
        },
    );
    println!(
        "  {DIM}Claude Code recorded work, no token counts survive. Totals are a floor.{DIM:#}"
    );
}

/// Sparkline and endpoints for a time-bucketed table, oldest point first.
///
/// Only day and week buckets have an order that means anything (months come
/// through `monthly`, which builds its own table). Sorting by key is safe for
/// both because their keys (`2026-08-03`, `2026-W31`) are fixed-width and
/// already sort chronologically, so the trend reads left to right regardless of
/// how the caller ordered the rows.
fn trend_line(rows: &[Bucket], group: GroupBy) -> Option<(String, String, String)> {
    if !matches!(group, GroupBy::Day | GroupBy::Week) || rows.len() < 2 {
        return None;
    }
    let mut ordered: Vec<&Bucket> = rows.iter().collect();
    ordered.sort_by(|a, b| a.key.cmp(&b.key));
    let series: Vec<u64> = ordered.iter().map(|r| r.counters.total()).collect();
    let spark = ui::sparkline(&series);
    if spark.is_empty() {
        return None;
    }
    Some((
        spark,
        ordered[0].key.clone(),
        ordered[ordered.len() - 1].key.clone(),
    ))
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
    let prices = PriceTable::load_with_catalog();

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

    // A time series has a shape, and a column of magnitudes hides it. One line
    // under the table shows the trend without spending a row per point.
    if let Some((spark, first, last)) = trend_line(rows, group) {
        let s = ui::secondary();
        println!(
            "  {DIM}{}{DIM:#}  {s}{spark}{s:#}  {DIM}{first} to {last}{DIM:#}",
            ui::pad_right("", key_w),
        );
    }
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
    note_unmeasured_days(store, q);
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
            format!("active {} {left}m left", ui::separator())
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
