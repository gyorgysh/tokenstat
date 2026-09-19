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
    auth, device, fetch_reports, profile_login, profile_login_code, profile_logout, profile_sync,
    profile_sync_scheduled, profile_sync_status,
};
pub use reference::{budget, catalog, models_detail, plans, pricing};
pub use setup::{SetupOptions, schedule, setup};
pub use status::{doctor, empty_archive, empty_range, scan_report, statusline};
pub use summary::{heatmap, overview, wrapped};
pub use tables::{blocks, export, grouped, monthly, sessions};
pub use updates::{maybe_notify_update, self_update, self_update_scheduled, update_auto};

use anyhow::Result;
use tokenstat_core::{Bucket, Counters, EquivalentValue, PriceTable, display_usage_model_id};

use crate::ui;

/// Calendar volume includes fresh input, output, cache reads and writes.
pub(super) fn daily_tokens(days: &[Bucket]) -> Vec<(String, u64)> {
    days.iter()
        .map(|d| (d.key.clone(), d.counters.total()))
        .collect()
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

/// Sum model-priced slices, preserving missing prices and estimate markers.
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct RowValue {
    pub micros: i64,
    pub priced: bool,
    pub partial: bool,
    pub estimated: bool,
}

pub(super) type ValueMap = std::collections::BTreeMap<String, RowValue>;

pub(super) fn values_by_key(
    split: &[tokenstat_core::SplitBucket],
    prices: &PriceTable,
) -> ValueMap {
    let mut values = ValueMap::new();
    let mut rates = std::collections::HashMap::new();
    for row in split {
        let value = values.entry(row.key.clone()).or_default();
        let (rates, estimated) = rates.entry(row.split.as_str()).or_insert_with(|| {
            let model = model_label(&row.split);
            (prices.rates_for(&model), prices.is_estimate(&model))
        });
        if let Some(rates) = rates {
            let amount = EquivalentValue::from_rates(*rates, &row.counters);
            value.micros = value.micros.saturating_add(amount.micros());
            value.priced = true;
            value.estimated |= *estimated;
            value.partial |= row.counters.has_unknown();
        } else {
            value.partial = true;
        }
    }
    values
}

impl RowValue {
    pub fn cell(self) -> String {
        if !self.priced {
            return "-".into();
        }
        format!(
            "{}{}{}",
            if self.estimated { "~" } else { "" },
            ui::usd(self.micros as f64 / 1_000_000.0),
            if self.partial { "+" } else { "" }
        )
    }
}

pub(super) fn bucket_value_json(row: &Bucket, values: &ValueMap) -> String {
    let v = values.get(&row.key).copied().unwrap_or_default();
    let amount = if v.priced {
        format!("{:.6}", v.micros as f64 / 1_000_000.0)
    } else {
        "null".into()
    };
    let mut json = bucket_json(row);
    json.pop();
    format!(
        r#"{},"value_usd":{},"value_partial":{},"value_estimated":{}}}"#,
        json, amount, v.partial, v.estimated
    )
}

pub(super) fn today_summary(days: &[Bucket], values: &ValueMap, date: &str) -> String {
    match days.iter().find(|d| d.key == date) {
        Some(day) => format!(
            "Today {date} · {} requests · {} in+out · {} tokens incl. cache · {} API value",
            ui::exact(day.events),
            ui::tokens(day.counters.input_fresh.unwrap_or(0) + day.counters.output.unwrap_or(0)),
            total_cell(&day.counters),
            values.get(date).copied().unwrap_or_default().cell()
        ),
        None => format!("Today {date} · no recorded usage in this range"),
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
    json_string(s)
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
        Some(s) => json_string(s),
        None => "null".to_string(),
    }
}

/// One bucket as a JSON object, without the surrounding array.
pub(super) fn bucket_json(r: &Bucket) -> String {
    let c = &r.counters;
    format!(
        r#"{{"key":{},"input_fresh":{},"cache_read":{},"cache_write_5m":{},"cache_write_1h":{},"output":{},"total":{},"events":{},"sessions":{}}}"#,
        json_string(&r.key),
        num(c.input_fresh),
        num(c.cache_read),
        num(c.cache_write_5m),
        num(c.cache_write_1h),
        num(c.output),
        c.total(),
        r.events,
        r.sessions,
    )
}

/// Bucket array with the list-rate equivalent attached, for model rows.
///
/// The table has always had a value column and `models --detail --json` has
/// always carried `value_usd`; plain `models --json` dropping it meant the
/// cheapest machine-readable path was also the least informative one.
/// `value_usd` is `null` when the model has no list price, never zero.
pub(super) fn print_json_model_buckets(rows: &[Bucket], prices: &PriceTable) -> Result<()> {
    use anstream::println;
    let out: Vec<String> = rows
        .iter()
        .map(|r| {
            let value = EquivalentValue::price(prices, &model_label(&r.key), &r.counters)
                .map(|v| format!("{:.4}", v.dollars()))
                .unwrap_or_else(|| "null".into());
            let mut row = bucket_json(r);
            row.pop();
            format!(r#"{},"value_usd":{}}}"#, row, value)
        })
        .collect();
    println!("[{}]", out.join(","));
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

/// " as @handle" in bold, or nothing. Every login print shares this, so
/// a handleless account reads "logged in" rather than "logged in as @?".
pub(super) fn login_as_suffix(handle: Option<&str>) -> String {
    match handle {
        Some(handle) => format!(" as {BOLD}@{handle}{BOLD:#}", BOLD = crate::ui::BOLD),
        None => String::new(),
    }
}

/// Replace control characters in a log-derived label.
///
/// Keys come from files this tool did not write. A raw `\x1b` in a model id or
/// project path would otherwise reach the terminal as an escape sequence.
pub(super) fn sanitize_label(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_control() { '\u{FFFD}' } else { c })
        .collect()
}

/// Unreported stays `null` in JSON, so a consumer can tell it from zero.
pub(super) fn num(v: Option<u64>) -> String {
    v.map(|n| n.to_string()).unwrap_or_else(|| "null".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grouped_value_prices_each_model_and_preserves_missing_prices() {
        let prices = PriceTable::parse(r#"{"effective_from":"2026-09-19","models":[
            {"match":"model-a","input":2,"output":10,"cache_read":0.5,"cache_write_5m":3,"cache_write_1h":4},
            {"match":"model-b","input":5,"output":20,"cache_read":1,"cache_write_5m":6,"cache_write_1h":8}
        ]}"#).unwrap();
        let counters = Counters {
            input_fresh: Some(1_000_000),
            output: Some(100_000),
            cache_read: Some(2_000_000),
            cache_write_5m: Some(0),
            cache_write_1h: Some(0),
        };
        let row = |key: &str, model: &str| tokenstat_core::SplitBucket {
            key: key.into(),
            split: model.into(),
            counters,
            events: 1,
            sessions: 1,
        };
        let values = values_by_key(
            &[
                row("mixed", "model-a"),
                row("mixed", "model-b"),
                row("partial", "model-a"),
                row("partial", "unknown"),
                row("unknown", "unknown"),
            ],
            &prices,
        );
        assert_eq!(values["mixed"].micros, 13_000_000);
        assert_eq!(values["mixed"].cell(), "$13");
        assert_eq!(values["partial"].cell(), "$4.0+");
        assert_eq!(values["unknown"].cell(), "-");
        let bucket = Bucket {
            key: "unknown".into(),
            counters,
            events: 1,
            sessions: 1,
        };
        let json: serde_json::Value =
            serde_json::from_str(&bucket_value_json(&bucket, &values)).unwrap();
        assert!(json["value_usd"].is_null());
        assert_eq!(json["value_partial"], true);
    }

    #[test]
    fn today_uses_the_requested_calendar_date_not_the_latest_row() {
        let days = vec![Bucket {
            key: "2026-09-18".into(),
            counters: Counters::default(),
            events: 42,
            sessions: 2,
        }];
        let values = ValueMap::new();
        assert!(today_summary(&days, &values, "2026-09-19").contains("no recorded usage"));
        assert!(today_summary(&days, &values, "2026-09-18").contains("42 requests"));
    }

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

    #[test]
    fn json_helpers_escape_backslashes_and_control_characters() {
        let raw = "a\\b\"c\nd\u{1}";
        for encoded in [json_str(raw), json_opt(Some(raw))] {
            let decoded: serde_json::Value = serde_json::from_str(&encoded).unwrap();
            assert_eq!(decoded, raw);
        }
        assert_eq!(json_opt(None), "null");
    }

    #[test]
    fn log_derived_labels_cannot_carry_escape_sequences() {
        assert_eq!(sanitize_label("a\u{1b}[31mb"), "a\u{FFFD}[31mb");
        assert_eq!(sanitize_label("claude-opus-5"), "claude-opus-5");
    }
}
