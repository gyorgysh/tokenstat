use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use tokenstat_core::{
    Bucket, EquivalentValue, GroupBy, PriceTable, Query, Store, display_usage_model_id,
};

use super::*;
use crate::ui::{self, HeatRender};

pub(super) fn summary_lines(app: &App, width: u16) -> Vec<Line<'static>> {
    let c = &app.totals.counters;
    let in_out = c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0);
    let cache_write = c.cache_write_5m.unwrap_or(0) + c.cache_write_1h.unwrap_or(0);
    let mut lines = Vec::new();

    lines.push(Line::from(vec![
        Span::styled(
            format!("{:<16}", "Sessions"),
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", "Requests"),
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", "Input + output"),
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", "Active days"),
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(vec![
        Span::styled(
            format!("{:<16}", ui::exact(app.totals.sessions)),
            Style::default()
                .fg(intensity_color(0.7))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", ui::exact(app.totals.events)),
            Style::default()
                .fg(intensity_color(0.8))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", ui::tokens(in_out)),
            Style::default()
                .fg(intensity_color(0.95))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", ui::exact(app.totals.days)),
            Style::default()
                .fg(intensity_color(0.6))
                .add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        format!(
            "cache read {}  ·  cache write {}  ·  {} counting cache",
            ui::tokens(c.cache_read.unwrap_or(0)),
            ui::tokens(cache_write),
            ui::tokens(c.total()),
        ),
        Style::default().fg(secondary()),
    )));

    if let (Some(first), Some(last)) = (&app.totals.first_date, &app.totals.last_date) {
        let peak = app
            .peak_hour
            .map(|h| format!("  ·  peak hour {h:02}:00"))
            .unwrap_or_default();
        lines.push(Line::from(Span::styled(
            format!("{first} to {last}{peak}"),
            Style::default().fg(secondary()),
        )));
    }

    if !app.days.is_empty() {
        lines.push(Line::from(""));
        let pairs: Vec<(String, u64)> = app
            .days
            .iter()
            .map(|d| {
                let c = &d.counters;
                (
                    d.key.clone(),
                    c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0),
                )
            })
            .collect();
        // Purple→cyan heat: idle cells stay muted, hot days peak in cyan so
        // the grid sits with the electric purple chrome instead of fighting it.
        let weeks = usize::from(width)
            .saturating_sub(4 + ui::HEAT_GUTTER)
            .div_ceil(ui::HEAT_COL)
            .clamp(8, 53);
        let today = jiff::Timestamp::now().to_zoned(app.tz.clone()).date();
        if let Some(cal) = ui::heat_calendar(&pairs, weeks, today) {
            lines.push(Line::from(Span::styled(
                cal.header(),
                Style::default().fg(secondary()),
            )));
            for (r, row) in cal.rows.iter().enumerate() {
                let mut spans = vec![Span::styled(
                    ui::pad_right(ui::heat_row_label(r), ui::HEAT_GUTTER),
                    Style::default().fg(MUTED),
                )];
                for cell in row {
                    match cell {
                        None => spans.push(Span::raw("  ")),
                        Some(c) => {
                            let (cr, cg, cb) = ui::heat_rgb(c.level);
                            spans.push(Span::styled(
                                ui::heat_cell(),
                                Style::default().fg(brand((cr, cg, cb))),
                            ));
                            spans.push(Span::raw(" "));
                        }
                    }
                }
                lines.push(Line::from(spans));
            }
            if let Some(b) = cal.busiest {
                lines.push(Line::from(Span::styled(
                    format!(
                        "{}busiest {} ({})  ·  streak {} days, best {}",
                        " ".repeat(ui::HEAT_GUTTER),
                        b.date,
                        ui::tokens(b.value),
                        cal.streak_current,
                        cal.streak_best,
                    ),
                    Style::default().fg(secondary()),
                )));
            }
        }
    }

    if !app.models.is_empty() {
        lines.push(Line::from(""));
        let grand: u64 = app
            .models
            .iter()
            .map(|m| m.counters.total())
            .sum::<u64>()
            .max(1);
        let prices = &app.prices;
        let w = app
            .models
            .iter()
            .map(|m| {
                tokenstat_core::display_usage_model_id(&m.key)
                    .chars()
                    .count()
            })
            .max()
            .unwrap_or(10)
            .clamp(8, 53);
        lines.push(Line::from(Span::styled(
            format!(
                "{}  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}",
                ui::pad_right("Model", w),
                "input",
                "output",
                "cache",
                "total",
                "price",
            ),
            Style::default().fg(accent()).add_modifier(Modifier::BOLD),
        )));

        let hidden = app.models.len().saturating_sub(SUMMARY_MODEL_PREVIEW);
        let show_all = app.summary_models_expanded || hidden == 0;
        let visible = if show_all {
            app.models.as_slice()
        } else {
            &app.models[..SUMMARY_MODEL_PREVIEW]
        };
        for m in visible {
            let share = m.counters.total() as f64 / grand as f64;
            let c = &m.counters;
            let lookup = tokenstat_core::display_usage_model_id(&m.key);
            let value = EquivalentValue::price(prices, &lookup, c)
                .map(|v| {
                    let body = ui::usd(v.dollars());
                    if prices.is_estimate(&lookup) && v.dollars() > 0.0 {
                        format!("~{body}")
                    } else {
                        body
                    }
                })
                .unwrap_or_else(|| "-".to_string());
            let total = {
                let t = ui::tokens(c.total());
                if c.has_unknown() { format!("{t}+") } else { t }
            };
            lines.push(Line::from(vec![
                Span::styled(ui::pad_right(&lookup, w), Style::default().fg(accent())),
                Span::raw(format!(
                    "  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}  ",
                    opt_cell(c.input_fresh),
                    opt_cell(c.output),
                    opt_cell(c.cache_read),
                    total,
                    value,
                )),
                Span::styled(
                    format!("{:.1}%", share * 100.0),
                    Style::default().fg(secondary()),
                ),
            ]));
        }
        if !show_all {
            lines.push(Line::from(Span::styled(
                format!("m expands {hidden} more · Models tab for the full list"),
                Style::default().fg(accent()),
            )));
        } else if hidden > 0 {
            lines.push(Line::from(Span::styled(
                "m collapses to the top 10 · Models tab for the same list",
                Style::default().fg(MUTED),
            )));
        }

        // Dollar total always follows the (possibly truncated) list so the
        // headline "how much in total" stays on screen when collapsed.
        let mut any_estimate = false;
        let total_value: EquivalentValue = app
            .models
            .iter()
            .filter_map(|m| {
                let lookup = tokenstat_core::display_usage_model_id(&m.key);
                if prices.is_estimate(&lookup) {
                    any_estimate = true;
                }
                EquivalentValue::price(prices, &lookup, &m.counters)
            })
            .sum();
        lines.push(Line::from(""));
        lines.push(Line::from(vec![
            Span::styled(
                ui::usd(total_value.dollars()),
                Style::default().fg(accent()).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                " if this had been billed per token",
                Style::default().fg(MUTED),
            ),
        ]));
        lines.push(Line::from(Span::styled(
            "List-rate equivalent only. Plan usage is not money charged; metered API usage may have been.",
            Style::default().fg(MUTED),
        )));
        if any_estimate {
            lines.push(Line::from(Span::styled(
                "~ values are estimates (Cursor Auto at Composer 2.5 list rates as a floor).",
                Style::default().fg(MUTED),
            )));
        }
        if prices.is_empty() {
            lines.push(Line::from(Span::styled(
                "No local price book yet. Run: tokenstat pricing --refresh",
                Style::default().fg(MUTED),
            )));
        }
    }

    lines
}
pub(super) fn empty_archive_lines() -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(Span::styled(
            "No usage recorded yet.",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "Type /setup for guided scan + schedule, or /scan to read logs now.",
            Style::default().fg(MUTED),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "On disk: Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI",
            Style::default().fg(MUTED),
        )),
        Line::from(Span::styled(
            "Remote: Cursor (tokenstat auth cursor)",
            Style::default().fg(MUTED),
        )),
        Line::from(Span::styled(
            "IDE sync: Antigravity (open app, then tokenstat fetch)",
            Style::default().fg(MUTED),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "Doctor still works on an empty archive: switch with → or /doctor.",
            Style::default().fg(MUTED),
        )),
    ]
}

pub(super) fn filtered_empty_lines() -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(Span::styled(
            "Nothing matches this filter.",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "Type /filter clear, or widen --since / --model / --project.",
            Style::default().fg(MUTED),
        )),
    ]
}

pub(super) fn table_lines(
    rows: &[Bucket],
    label: &str,
    price_as_model: bool,
    prices: &PriceTable,
) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    if rows.is_empty() {
        lines.push(Line::from(Span::styled(
            "Nothing in this range.",
            Style::default().fg(MUTED),
        )));
        lines.push(Line::from(Span::styled(
            "Try another tab, or /scan if the archive looks stale.",
            Style::default().fg(MUTED),
        )));
        return lines;
    }

    let key_w = rows
        .iter()
        .map(|r| {
            if price_as_model {
                tokenstat_core::display_usage_model_id(&r.key)
                    .chars()
                    .count()
            } else {
                r.key.chars().count()
            }
        })
        .max()
        .unwrap_or(8)
        // Dates need the full YYYY-MM-DD width. The old upper clamp alone was
        // fine, but pad used to elide exact-fit strings.
        .clamp(label.len().max(10), 36);
    let max = rows
        .iter()
        .map(|r| r.counters.total())
        .max()
        .unwrap_or(1)
        .max(1);

    lines.push(Line::from(Span::styled(
        format!(
            "{}  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}",
            ui::pad_right(label, key_w),
            "input",
            "output",
            "cache",
            "total",
            "value",
        ),
        Style::default().fg(accent()).add_modifier(Modifier::BOLD),
    )));

    let mut any_estimate = false;
    for r in rows {
        let c = &r.counters;
        let frac = c.total() as f64 / max as f64;
        let total = {
            let t = ui::tokens(c.total());
            if c.has_unknown() { format!("{t}+") } else { t }
        };
        let key_label = if price_as_model {
            tokenstat_core::display_usage_model_id(&r.key)
        } else {
            r.key.clone()
        };
        let value = if price_as_model {
            EquivalentValue::price(prices, &key_label, c)
                .map(|v| {
                    if prices.is_estimate(&key_label) && v.dollars() > 0.0 {
                        any_estimate = true;
                        format!("~{}", ui::usd(v.dollars()))
                    } else {
                        ui::usd(v.dollars())
                    }
                })
                .unwrap_or_else(|| "-".to_string())
        } else {
            "-".to_string()
        };
        let key_style = if price_as_model {
            Style::default().fg(accent())
        } else {
            Style::default()
        };
        let mut row = vec![
            Span::styled(ui::pad_right(&key_label, key_w), key_style),
            Span::raw(format!(
                "  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}  ",
                opt_cell(c.input_fresh),
                opt_cell(c.output),
                opt_cell(c.cache_read),
                total,
                value,
            )),
        ];
        row.extend(faded_bar_spans(frac, 12));
        lines.push(Line::from(row));
    }
    if price_as_model {
        lines.push(Line::from(Span::styled(
            "value = list-rate equivalent, not billed dollars",
            Style::default().fg(MUTED),
        )));
        if any_estimate {
            lines.push(Line::from(Span::styled(
                "~ values are estimates (Cursor Auto floor, or published provider rates).",
                Style::default().fg(MUTED),
            )));
        }
    } else if let Some((spark, first, last)) = trend_spark(rows) {
        // The tab can be sorted newest first, so the sparkline sorts its own
        // copy: a trend that reads right to left is worse than none.
        lines.push(Line::from(vec![
            Span::raw(ui::pad_right("", key_w + 2)),
            Span::styled(spark, Style::default().fg(secondary())),
            Span::styled(format!("  {first} to {last}"), Style::default().fg(MUTED)),
        ]));
    }
    lines
}

/// Sparkline over time-bucketed rows, oldest first, or `None` when the keys are
/// not a date-like series.
pub(super) fn trend_spark(rows: &[Bucket]) -> Option<(String, String, String)> {
    if rows.len() < 2 || !rows.iter().all(|r| looks_like_a_period(&r.key)) {
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

/// `2026-08-03`, `2026-W31`, or `2026-08`: keys that sort chronologically.
///
/// Projects and sessions come through the same renderer, and a sparkline over
/// them would imply an order they do not have.
pub(super) fn looks_like_a_period(key: &str) -> bool {
    let bytes = key.as_bytes();
    matches!(bytes.len(), 7 | 8 | 10)
        && bytes[..4].iter().all(u8::is_ascii_digit)
        && bytes[4] == b'-'
}

/// A horizontal bar that fades along its length and scales with `fraction`.
///
/// Quiet rows stay deep violet. Strong rows run purple into cyan at the tip,
/// so rank is visible without reading the number.
pub(super) fn faded_bar_spans(fraction: f64, width: usize) -> Vec<Span<'static>> {
    let filled = ui::bar(fraction, width);
    let n = filled.chars().count();
    let mut spans = Vec::with_capacity(width);
    if n == 0 {
        spans.push(Span::styled(" ".repeat(width), Style::default().fg(MUTED)));
        return spans;
    }
    for (i, ch) in filled.chars().enumerate() {
        // Blend overall magnitude with position along the bar so the tip is
        // always the brightest part of that row.
        let along = (i as f64 + 1.0) / n as f64;
        let t = (fraction.powf(0.55) * 0.4 + along * 0.6).clamp(0.0, 1.0);
        let (r, g, b) = ui::intensity_rgb(t);
        spans.push(Span::styled(
            ch.to_string(),
            Style::default().fg(brand((r, g, b))),
        ));
    }
    let pad = width.saturating_sub(n);
    if pad > 0 {
        spans.push(Span::styled(" ".repeat(pad), Style::default().fg(MUTED)));
    }
    spans
}

pub(super) fn intensity_color(t: f64) -> Color {
    let (r, g, b) = ui::intensity_rgb(t.clamp(0.0, 1.0));
    brand((r, g, b))
}

/// Offline sync line for the status bar: host, plan interval, next allowed time.
pub(super) fn format_sync_hint(info: &tokenstat_sync::SchedulingInfo) -> String {
    let mut parts = vec![format!("linked · {}", info.host)];
    if let Some(until) = &info.next_allowed_at {
        if let Ok(until_ts) = until.parse::<jiff::Timestamp>() {
            let now = jiff::Timestamp::now();
            if until_ts > now {
                let secs = (until_ts - now).get_seconds().max(0);
                let mins = (secs + 59) / 60;
                parts.push(format!("next sync in ~{mins} min"));
            } else {
                parts.push("sync ready".into());
            }
        } else {
            parts.push(format!("next sync after {until}"));
        }
    } else if let Some(interval) = info.min_interval {
        parts.push(format!("every {} min", interval / 60));
    }
    parts.join(" · ")
}

pub(super) fn block_lines(app: &App) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    if app.blocks.is_empty() {
        lines.push(Line::from(Span::styled(
            "No 5 hour blocks yet.",
            Style::default().fg(MUTED),
        )));
        return lines;
    }

    let now_ms = jiff::Timestamp::now().as_millisecond();
    let max = app
        .blocks
        .iter()
        .map(|b| b.counters.total())
        .max()
        .unwrap_or(1)
        .max(1);

    lines.push(Line::from(Span::styled(
        format!(
            "{:<22}  {:>8}  {:>8}  {:>9}  {}",
            "Block", "events", "in+out", "total", "status"
        ),
        Style::default().fg(MUTED),
    )));

    for b in app.blocks.iter().rev().take(40) {
        let start = match jiff::Timestamp::from_millisecond(b.start_ms) {
            Ok(ts) => format!("{}", ts.to_zoned(app.tz.clone()).strftime("%Y-%m-%d %H:%M")),
            Err(_) => b.start_ms.to_string(),
        };
        let c = &b.counters;
        let in_out = c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0);
        let total = {
            let t = ui::tokens(c.total());
            if c.has_unknown() { format!("{t}+") } else { t }
        };
        let status = if b.active {
            let left = ((b.end_ms - now_ms).max(0) / 60_000) as u64;
            format!("active · {left}m left")
        } else {
            "closed".into()
        };
        let frac = c.total() as f64 / max as f64;
        let mut row = vec![Span::styled(
            format!(
                "{:<22}  {:>8}  {:>8}  {:>9}  {:<18}  ",
                start,
                ui::exact(b.events),
                ui::tokens(in_out),
                total,
                status,
            ),
            if b.active {
                Style::default().fg(accent())
            } else {
                Style::default()
            },
        )];
        row.extend(faded_bar_spans(frac, 12));
        lines.push(Line::from(row));
    }
    lines
}

pub(super) fn doctor_lines(app: &App) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    lines.push(Line::from(vec![
        Span::styled("Database  ", Style::default().fg(MUTED)),
        Span::raw(app.db_path.display().to_string()),
    ]));
    lines.push(Line::from(vec![
        Span::styled("Events    ", Style::default().fg(MUTED)),
        Span::raw(ui::exact(app.totals.events)),
    ]));
    if let Some(ms) = &app.last_scan {
        let shown = ms
            .parse::<i64>()
            .map(|ts| {
                let age = (jiff::Timestamp::now().as_millisecond() - ts).max(0) / 1000;
                format!("{} ago", format_age_secs(age))
            })
            .unwrap_or_else(|_| ms.clone());
        lines.push(Line::from(vec![
            Span::styled("Last scan ", Style::default().fg(MUTED)),
            Span::raw(shown),
        ]));
    }
    if filter_active(&app.filter) {
        lines.push(Line::from(vec![
            Span::styled("Filter    ", Style::default().fg(MUTED)),
            Span::raw(describe_filter(&app.filter)),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "Confidence",
        Style::default().add_modifier(Modifier::BOLD),
    )));
    if app.confidence.is_empty() {
        lines.push(Line::from(Span::styled(
            "No confidence breakdown yet.",
            Style::default().fg(MUTED),
        )));
    } else {
        for (level, count) in &app.confidence {
            lines.push(Line::from(format!("  {:<16} {}", level, ui::exact(*count))));
        }
    }
    if let Some(rec) = &app.reconciliation {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "Against Claude Code's own rollup",
            Style::default().add_modifier(Modifier::BOLD),
        )));
        lines.push(Line::from(format!(
            "  vendor    {} in+out · {} sessions",
            ui::tokens(rec.vendor_in_out),
            ui::exact(rec.vendor_sessions)
        )));
        lines.push(Line::from(format!(
            "  archive   {} in+out · {} sessions",
            ui::tokens(rec.archive_in_out),
            ui::exact(rec.archive_sessions)
        )));
        if rec.is_significant() {
            lines.push(Line::from(Span::styled(
                format!(
                    "  {} ({:.0}%) missing from surviving transcripts",
                    ui::tokens(rec.missing()),
                    rec.missing_ratio() * 100.0
                ),
                Style::default().fg(Color::Yellow),
            )));
        } else if rec.ahead() > 0 {
            lines.push(Line::from(Span::styled(
                format!(
                    "  archive complete, {} ahead of the rollup",
                    ui::tokens(rec.ahead())
                ),
                Style::default().fg(Color::Green),
            )));
        } else {
            lines.push(Line::from(Span::styled(
                "  archive agrees with the rollup",
                Style::default().fg(Color::Green),
            )));
        }
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "Sources",
        Style::default().add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::from(vec![
        Span::styled("on disk     ", Style::default().fg(MUTED)),
        Span::raw(
            "Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI",
        ),
    ]));
    lines.push(Line::from(vec![
        Span::styled("not local   ", Style::default().fg(MUTED)),
        Span::raw("Cursor (auth) · Antigravity IDE (open app + fetch)"),
    ]));
    lines.push(Line::from(Span::styled(
        "Type /setup to scan, schedule, and link · /sync uploads aggregates",
        Style::default().fg(secondary()),
    )));
    if app.empty && !filter_active(&app.filter) {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "Archive is empty. Type /setup or /scan to populate it.",
            Style::default().fg(secondary()),
        )));
    }
    lines
}

/// Body of the `/heatmap` window: the same grid as the Summary tab but with
/// the legend, streak, and busiest day the compact body leaves out.
pub(super) fn heatmap_detail_lines(app: &App, width: u16) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    if app.days.is_empty() {
        lines.push(Line::from(Span::styled(
            "No activity in the archive.",
            Style::default().fg(MUTED),
        )));
        return lines;
    }
    let pairs: Vec<(String, u64)> = app
        .days
        .iter()
        .map(|d| {
            let c = &d.counters;
            (
                d.key.clone(),
                c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0),
            )
        })
        .collect();
    let weeks = usize::from(width)
        .saturating_sub(2 + ui::HEAT_GUTTER)
        .div_ceil(ui::HEAT_COL)
        .clamp(8, 53);
    let today = jiff::Timestamp::now().to_zoned(app.tz.clone()).date();
    let Some(cal) = ui::heat_calendar(&pairs, weeks, today) else {
        return lines;
    };

    lines.push(Line::from(vec![
        Span::styled(
            format!(
                "{} tokens over {} active days",
                ui::tokens(cal.total),
                ui::exact(cal.active_days as u64)
            ),
            Style::default().fg(SELECTED).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  ·  {} to {}", cal.first, cal.last),
            Style::default().fg(MUTED),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        format!(
            "busiest {} ({})  ·  streak {} days, best {}",
            cal.busiest.map(|b| b.date.to_string()).unwrap_or_default(),
            cal.busiest.map(|b| ui::tokens(b.value)).unwrap_or_default(),
            cal.streak_current,
            cal.streak_best,
        ),
        Style::default().fg(MUTED),
    )));
    lines.push(Line::from(""));

    lines.push(Line::from(Span::styled(
        cal.header(),
        Style::default().fg(MUTED),
    )));
    for (r, row) in cal.rows.iter().enumerate() {
        let mut spans = vec![Span::styled(
            ui::pad_right(ui::heat_row_label(r), ui::HEAT_GUTTER),
            Style::default().fg(MUTED),
        )];
        for cell in row {
            match cell {
                None => spans.push(Span::raw("  ")),
                Some(c) => {
                    let (cr, cg, cb) = ui::heat_rgb(c.level);
                    spans.push(Span::styled(
                        ui::heat_cell(),
                        Style::default().fg(brand((cr, cg, cb))),
                    ));
                    spans.push(Span::raw(" "));
                }
            }
        }
        lines.push(Line::from(spans));
    }
    let mut legend = vec![Span::raw(" ".repeat(ui::HEAT_GUTTER))];
    legend.push(Span::styled("less ", Style::default().fg(MUTED)));
    for level in 0..5u8 {
        let (cr, cg, cb) = ui::heat_rgb(level);
        legend.push(Span::styled(
            ui::heat_cell(),
            Style::default().fg(brand((cr, cg, cb))),
        ));
        legend.push(Span::raw(" "));
    }
    legend.push(Span::styled("more", Style::default().fg(MUTED)));
    lines.push(Line::from(legend));
    lines
}

/// Body of the `/wrapped [year]` window: the year-in-review stats plus the
/// Jan-to-Dec grid, same numbers as `tokenstat wrapped`.
pub(super) fn wrapped_detail_lines(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    prices: &PriceTable,
    year: i32,
    width: u16,
) -> anyhow::Result<Vec<Line<'static>>> {
    let q = Query {
        since: Some(format!("{year:04}-01-01")),
        until: Some(format!("{year:04}-12-31")),
        ..Query::default()
    };
    let totals = store.totals(&q)?;
    let mut lines = Vec::new();
    lines.push(Line::from(Span::styled(
        format!("Wrapped {year}  ·  local archive only"),
        Style::default().fg(SELECTED).add_modifier(Modifier::BOLD),
    )));
    if totals.events == 0 {
        lines.push(Line::from(Span::styled(
            "No usage in the archive for this year.",
            Style::default().fg(MUTED),
        )));
        return Ok(lines);
    }

    let models = store.report(GroupBy::Model, &q)?;
    let projects = store.report(GroupBy::Project, &q)?;
    let days = store.report(GroupBy::Day, &q)?;
    let peak = store.peak_hour()?;
    let in_out = totals.counters.input_fresh.unwrap_or(0) + totals.counters.output.unwrap_or(0);
    let value: EquivalentValue = models
        .iter()
        .filter_map(|m| {
            EquivalentValue::price(prices, &display_usage_model_id(&m.key), &m.counters)
        })
        .sum();
    let top_model = models.first().map(|m| display_usage_model_id(&m.key));
    let top_project = projects.first().map(|p| p.key.clone());
    let busiest = days
        .iter()
        .max_by_key(|d| d.counters.input_fresh.unwrap_or(0) + d.counters.output.unwrap_or(0));

    let rows = [
        ("requests", ui::exact(totals.events)),
        ("sessions", ui::exact(totals.sessions)),
        ("active days", ui::exact(totals.days)),
        ("input+output", ui::tokens(in_out)),
        (
            "list value",
            format!("{}  (not billed)", ui::usd(value.dollars())),
        ),
        ("top model", top_model.unwrap_or_else(|| "-".into())),
        ("top project", top_project.unwrap_or_else(|| "-".into())),
        (
            "busiest day",
            busiest
                .map(|d| {
                    let io = d.counters.input_fresh.unwrap_or(0) + d.counters.output.unwrap_or(0);
                    format!("{}  ({})", d.key, ui::tokens(io))
                })
                .unwrap_or_else(|| "-".into()),
        ),
        (
            "peak hour",
            peak.map(|h| format!("{h:02}:00"))
                .unwrap_or_else(|| "-".into()),
        ),
    ];
    lines.push(Line::from(""));
    for (label, value) in rows {
        lines.push(Line::from(vec![
            Span::styled(format!("{:<14}", label), Style::default().fg(MUTED)),
            Span::raw(value),
        ]));
    }

    if !days.is_empty() {
        lines.push(Line::from(""));
        let pairs: Vec<(String, u64)> = days
            .iter()
            .map(|d| {
                (
                    d.key.clone(),
                    d.counters.input_fresh.unwrap_or(0) + d.counters.output.unwrap_or(0),
                )
            })
            .collect();
        let year_end = jiff::civil::date(year as i16, 12, 31);
        let now = jiff::Timestamp::now().to_zoned(tz.clone()).date();
        let anchor = if now < year_end { now } else { year_end };
        let weeks = (anchor.day_of_year() as usize).div_ceil(7) + 1;
        // The popup is narrower than a terminal, so a full year has to trim to
        // what fits. A partial year usually does not need trimming at all.
        let fit = usize::from(width)
            .saturating_sub(2 + ui::HEAT_GUTTER)
            .div_ceil(ui::HEAT_COL)
            .clamp(8, 53);
        if let Some(cal) = ui::heat_calendar(&pairs, weeks.min(fit), anchor) {
            lines.push(Line::from(Span::styled(
                cal.header(),
                Style::default().fg(MUTED),
            )));
            for (r, row) in cal.rows.iter().enumerate() {
                let mut spans = vec![Span::styled(
                    ui::pad_right(ui::heat_row_label(r), ui::HEAT_GUTTER),
                    Style::default().fg(MUTED),
                )];
                for cell in row {
                    match cell {
                        None => spans.push(Span::raw("  ")),
                        Some(c) => {
                            let (cr, cg, cb) = ui::heat_rgb(c.level);
                            spans.push(Span::styled(
                                ui::heat_cell(),
                                Style::default().fg(brand((cr, cg, cb))),
                            ));
                            spans.push(Span::raw(" "));
                        }
                    }
                }
                lines.push(Line::from(spans));
            }
        }
    }
    Ok(lines)
}

/// Body of the `/budget` window: list-rate spend today and this month against
/// any caps, same numbers the one-shot `tokenstat budget` prints.
pub(super) fn budget_detail_lines(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    prices: &PriceTable,
) -> anyhow::Result<Vec<Line<'static>>> {
    let st = tokenstat_core::budget_status(store, tz, prices)?;
    let mut lines = Vec::new();
    lines.push(Line::from(Span::styled(
        "Budget  ·  list-rate equivalent, not billed",
        Style::default().fg(SELECTED).add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::from(""));
    lines.push(Line::from(vec![
        Span::styled(format!("{:<14}", "today"), Style::default().fg(MUTED)),
        Span::raw(ui::usd(st.today_usd)),
    ]));
    match st.limits.daily_usd {
        Some(lim) => {
            let pct = st.today_ratio().unwrap_or(0.0) * 100.0;
            let over = st.over_daily();
            lines.push(Line::from(vec![
                Span::styled(format!("{:<14}", "daily cap"), Style::default().fg(MUTED)),
                Span::styled(
                    format!(
                        "{pct:.0}% of {} {}",
                        ui::usd(lim),
                        if over { "· EXCEEDED" } else { "" }
                    ),
                    if over {
                        Style::default().fg(Color::Yellow)
                    } else {
                        Style::default()
                    },
                ),
            ]));
        }
        None => lines.push(Line::from(Span::styled(
            "daily cap: none set (tokenstat budget --daily N)",
            Style::default().fg(MUTED),
        ))),
    }
    lines.push(Line::from(vec![
        Span::styled(format!("{:<14}", "month"), Style::default().fg(MUTED)),
        Span::raw(ui::usd(st.month_usd)),
    ]));
    match st.limits.monthly_usd {
        Some(lim) => {
            let pct = st.month_ratio().unwrap_or(0.0) * 100.0;
            let over = st.over_monthly();
            lines.push(Line::from(vec![
                Span::styled(format!("{:<14}", "monthly cap"), Style::default().fg(MUTED)),
                Span::styled(
                    format!(
                        "{pct:.0}% of {} {}",
                        ui::usd(lim),
                        if over { "· EXCEEDED" } else { "" }
                    ),
                    if over {
                        Style::default().fg(Color::Yellow)
                    } else {
                        Style::default()
                    },
                ),
            ]));
        }
        None => lines.push(Line::from(Span::styled(
            "monthly cap: none set (tokenstat budget --monthly N)",
            Style::default().fg(MUTED),
        ))),
    }
    Ok(lines)
}
