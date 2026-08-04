//! Output formatting for every command.
//!
//! Two rules shape what appears here. Plan usage is never printed as money,
//! because it was not charged. And an unreported counter renders as `-` rather
//! than `0`, with totals marked `+` when they are a lower bound, so a partial
//! figure never masquerades as a complete one.
//!
//! Split by what the reader is looking at, not by widget type: [`tables`] for
//! the per-bucket breakdowns, [`summary`] for the headline and the activity
//! calendar, [`reference`] for prices and the model catalog, [`account`] and
//! [`updates`] for the networked commands, [`status`] for health output, and
//! [`setup`] for the first-run walkthrough. This module holds only what all of
//! them share: cell formatting and JSON escaping.

mod account;
mod reference;
mod setup;
mod status;
mod summary;
mod tables;
mod updates;

pub use account::{
    auth, fetch_reports, profile_login, profile_login_code, profile_logout, profile_sync,
    profile_sync_scheduled, profile_sync_status,
};
pub use reference::{budget, catalog, models_detail, plans, pricing};
pub use setup::{SetupOptions, schedule, setup};
pub use status::{doctor, empty_archive, empty_range, scan_report, statusline};
pub use summary::{heatmap, overview, wrapped};
pub use tables::{blocks, export, grouped, monthly, sessions};
pub use updates::{maybe_notify_update, self_update, self_update_scheduled, update_auto};

use std::io::Write;

use anyhow::Result;
use tokenstat_core::{
    Bucket, Counters, EquivalentValue, GroupBy, PriceTable, Query, Store, display_usage_model_id,
};

use crate::ui;

/// `(YYYY-MM-DD, microdollars)` pairs for the activity heatmap.
///
/// The grid ramps on spend, so the busiest day is the most expensive one, not
/// the one that happened to move the most cache tokens.
pub(super) fn daily_cost(
    store: &Store,
    q: &Query,
    prices: &PriceTable,
) -> Result<Vec<(String, u64)>> {
    let split = store.report_by_model(GroupBy::Day, q)?;
    Ok(tokenstat_core::activity::cost_by_day(&split, prices))
}

/// Microdollars as money, for heatmap headlines.
pub(super) fn micros_usd(micros: u64) -> String {
    ui::usd(micros as f64 / 1_000_000.0)
}

/// Render `Some(n)` compactly, `None` as a dash.
pub(super) fn cell(v: Option<u64>) -> String {
    match v {
        Some(n) => ui::tokens(n),
        None => "-".to_string(),
    }
}

/// Total with a `+` suffix when some contributing field was never reported.
pub(super) fn total_cell(c: &Counters) -> String {
    let t = ui::tokens(c.total());
    if c.has_unknown() { format!("{t}+") } else { t }
}

/// List-rate equivalent for a row, or `-` when the model is unknown / unpriced.
/// Never a cash charge: subscription usage is valued the same way.
/// Estimates (e.g. Cursor Auto → Composer floor) get a `~` prefix, same idea
/// as tokenstat.ai and the upcoming CLI 0.1.2 note on opaque routers.
pub(super) fn price_cell(prices: &PriceTable, model: &str, c: &Counters) -> String {
    let lookup = display_usage_model_id(model);
    match EquivalentValue::price(prices, &lookup, c) {
        Some(v) if prices.is_estimate(&lookup) && v.dollars() > 0.0 => {
            format!("~{}", ui::usd(v.dollars()))
        }
        Some(v) => ui::usd(v.dollars()),
        None => "-".to_string(),
    }
}

pub(super) fn model_label(model: &str) -> String {
    display_usage_model_id(model)
}

/// Price only when `key` looks like a model id. Day/project buckets would
/// otherwise look up a date or path as a model and almost always show `-`.
pub(super) fn price_cell_for_group(
    prices: &PriceTable,
    group: GroupBy,
    key: &str,
    c: &Counters,
) -> String {
    match group {
        GroupBy::Model => price_cell(prices, key, c),
        _ => "-".to_string(),
    }
}

/// Cache read tokens only. Writes stay in `total` / the priced figure.
pub(super) fn cache_cell(c: &Counters) -> String {
    cell(c.cache_read)
}

pub(super) fn csv_escape(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

pub(super) fn json_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

pub(super) fn opt_num(v: Option<u64>) -> String {
    v.map(|n| n.to_string()).unwrap_or_default()
}

pub(super) fn format_age(secs: i64) -> String {
    match secs {
        s if s < 60 => format!("{s}s"),
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

pub(super) fn json_opt(v: Option<&str>) -> String {
    match v {
        Some(s) => format!("\"{}\"", s.replace('"', "\\\"")),
        None => "null".to_string(),
    }
}

pub(super) fn print_json_buckets(rows: &[Bucket]) -> Result<()> {
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

/// A correctly escaped JSON string, quotes included.
///
/// Model ids and plan names come from vendor feeds, so they are not ours to
/// assume anything about. Escaping by hand here would be one backslash away
/// from emitting a document no parser accepts.
pub(super) fn json_string(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

pub(super) fn json_string_array(items: &[String]) -> String {
    let parts: Vec<String> = items.iter().map(|s| json_string(s)).collect();
    format!("[{}]", parts.join(","))
}

/// Unreported stays `null` in JSON, so a consumer can tell it from zero.
pub(super) fn num(v: Option<u64>) -> String {
    v.map(|n| n.to_string()).unwrap_or_else(|| "null".into())
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
