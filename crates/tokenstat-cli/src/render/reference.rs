use anstream::println;
use anyhow::Result;
use tokenstat_core::{Catalog, EquivalentValue, GroupBy, Plans, PriceTable, Query, Store};

use super::summary::today;
use super::*;
use crate::ui::{self, BOLD, DIM, accent, good, warn};

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
            if r.accepted_stale {
                println!(
                    "  {w}accepted {} large rate move(s); local book was older than a day{w:#}",
                    r.large_moves.len()
                );
            } else {
                println!(
                    "  {w}accepted {} large rate move(s) with --force{w:#}",
                    r.large_moves.len()
                );
            }
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

/// Show or refresh the local model catalog and plans snapshots.
pub fn catalog(refresh: bool, json: bool) -> Result<()> {
    if refresh {
        let r = tokenstat_sync::catalog::refresh()?;
        if json {
            println!(
                r#"{{"catalog_path":"{}","plans_path":"{}","models":{},"priced_models":{},"plans":{},"effective_from":"{}"}}"#,
                r.catalog_path.display(),
                r.plans_path.display(),
                r.models,
                r.priced_models,
                r.plans,
                r.effective_from
            );
            return Ok(());
        }
        println!();
        println!(
            "  Wrote {} models ({} with rates) to {}",
            ui::exact(r.models as u64),
            ui::exact(r.priced_models as u64),
            r.catalog_path.display()
        );
        println!(
            "  Wrote {} plans to {}",
            ui::exact(r.plans as u64),
            r.plans_path.display()
        );
        println!(
            "  {DIM}effective from {} (plans {}){DIM:#}",
            r.effective_from, r.plans_effective_from
        );
        println!();
        return Ok(());
    }

    let path = Catalog::default_path()?;
    let catalog = Catalog::load();
    let plans = Plans::load();
    if json {
        println!(
            r#"{{"path":"{}","present":{},"models":{},"plans":{},"effective_from":{}}}"#,
            path.display(),
            !catalog.is_empty(),
            catalog.len(),
            plans.len(),
            if catalog.effective_from.is_empty() {
                "null".into()
            } else {
                format!("\"{}\"", catalog.effective_from)
            }
        );
        return Ok(());
    }
    println!();
    println!("  {BOLD}Catalog{BOLD:#}");
    println!("  {DIM}path{DIM:#}     {}", path.display());
    if catalog.is_empty() {
        let a = accent();
        println!("  {DIM}status{DIM:#}   no local snapshot");
        println!();
        println!("  Run {a}tokenstat catalog --refresh{a:#} to fetch model metadata and plans.");
    } else {
        println!(
            "  {DIM}status{DIM:#}   {} models, {} plans",
            ui::exact(catalog.len() as u64),
            ui::exact(plans.len() as u64)
        );
        println!("  {DIM}from{DIM:#}     {}", catalog.effective_from);
        println!();
        println!("  {DIM}See it applied with {DIM:#}tokenstat models --detail{DIM}.{DIM:#}");
    }
    println!();
    Ok(())
}

/// Subscription plans, with the reader's own usage as the yardstick.
///
/// A price list on its own says nothing. What makes it useful is the comparison:
/// a month of your real usage, valued at list rates, next to what a plan costs.
/// Both sides are labelled, because one is a bill and the other never was.
pub fn plans(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    vendor: Option<&str>,
    json: bool,
) -> Result<()> {
    let plans = Plans::load();
    if plans.is_empty() {
        if json {
            println!(r#"{{"present":false,"plans":[]}}"#);
            return Ok(());
        }
        let a = accent();
        println!();
        println!("  {DIM}No local plans snapshot.{DIM:#}");
        println!("  Run {a}tokenstat catalog --refresh{a:#} to fetch it.");
        println!();
        return Ok(());
    }

    let selected: Vec<&tokenstat_core::Plan> = match vendor {
        Some(v) => plans.for_vendor(v),
        None => plans.all().iter().collect(),
    };
    if selected.is_empty() {
        println!();
        println!("  {DIM}No plans for that vendor.{DIM:#}");
        println!();
        return Ok(());
    }

    if json {
        let rows: Vec<String> = selected
            .iter()
            .map(|p| {
                format!(
                    r#"{{"id":{},"vendor":{},"name":{},"price_usd_month":{},"surfaces":{}}}"#,
                    json_string(&p.id),
                    json_string(&p.vendor),
                    json_string(&p.name),
                    p.price_usd_month
                        .map(|v| v.to_string())
                        .unwrap_or_else(|| "null".into()),
                    json_string_array(&p.surfaces),
                )
            })
            .collect();
        println!(
            r#"{{"present":true,"effective_from":{},"plans":[{}]}}"#,
            json_string(&plans.effective_from),
            rows.join(",")
        );
        return Ok(());
    }

    println!();
    println!("  {BOLD}Subscription plans{BOLD:#}");
    println!(
        "  {DIM}Product prices as published, checked {}. Not API list rates.{DIM:#}",
        plans.effective_from
    );
    println!();

    let name_w = selected
        .iter()
        .map(|p| p.name.chars().count())
        .max()
        .unwrap_or(10)
        .clamp(10, 34);
    println!(
        "  {DIM}{}  {}  {}  {}{DIM:#}",
        ui::pad_right("Plan", name_w),
        ui::pad_left("month", 8),
        ui::pad_left("year", 8),
        "surfaces",
    );
    for p in &selected {
        println!(
            "  {}  {}  {}  {DIM}{}{DIM:#}",
            ui::pad_right(&p.name, name_w),
            ui::pad_left(&price_or_dash(p.price_usd_month), 8),
            ui::pad_left(&price_or_dash(p.price_usd_year), 8),
            p.surfaces.join(", "),
        );
    }

    // The comparison. A trailing 30 days is the closest thing to "a month of
    // how I actually work" that the archive can answer without guessing.
    let query = Query {
        since: last_30_days(tz),
        ..Query::default()
    };
    let prices = PriceTable::load_with_catalog();
    let month_value: EquivalentValue = store
        .report(GroupBy::Model, &query)?
        .iter()
        .filter_map(|m| EquivalentValue::price(&prices, &model_label(&m.key), &m.counters))
        .sum();
    if month_value.dollars() > 0.0 {
        println!();
        println!(
            "  {BOLD}{}{BOLD:#} {DIM}your last 30 days at list rates{DIM:#}",
            ui::usd(month_value.dollars())
        );
        println!(
            "  {DIM}Compare against a plan price above. Plan usage was never billed per token,{DIM:#}"
        );
        println!("  {DIM}so this is what the same work would have cost metered.{DIM:#}");
    }
    println!();
    Ok(())
}

/// Per-model usage with what the catalog knows about each model attached.
pub fn models_detail(store: &Store, q: &Query, json: bool) -> Result<()> {
    let rows = store.report(GroupBy::Model, q)?;
    if rows.is_empty() {
        return empty_range(json);
    }
    let catalog = std::sync::Arc::new(Catalog::load());
    let prices = PriceTable::load().with_catalog(catalog.clone());

    if json {
        let out: Vec<String> = rows
            .iter()
            .map(|r| {
                let label = model_label(&r.key);
                let m = catalog.get(&label);
                format!(
                    r#"{{"model":{},"total":{},"value_usd":{},"name":{},"family":{},"context_length":{},"capabilities":{},"scores":{}}}"#,
                    json_string(&label),
                    r.counters.total(),
                    EquivalentValue::price(&prices, &label, &r.counters)
                        .map(|v| format!("{:.4}", v.dollars()))
                        .unwrap_or_else(|| "null".into()),
                    m.and_then(|m| m.name.as_deref())
                        .map(json_string)
                        .unwrap_or_else(|| "null".into()),
                    m.and_then(|m| m.family.as_deref())
                        .map(json_string)
                        .unwrap_or_else(|| "null".into()),
                    m.and_then(|m| m.context_window())
                        .map(|c| c.to_string())
                        .unwrap_or_else(|| "null".into()),
                    m.map(|m| json_string_array(&m.capabilities))
                        .unwrap_or_else(|| "[]".into()),
                    m.map(|m| scores_json(&m.scores))
                        .unwrap_or_else(|| "{}".into()),
                )
            })
            .collect();
        println!("[{}]", out.join(","));
        return Ok(());
    }

    if catalog.is_empty() {
        let a = accent();
        println!();
        println!("  {DIM}No local catalog snapshot, so only usage is shown.{DIM:#}");
        println!("  Run {a}tokenstat catalog --refresh{a:#} to fill in the rest.");
    }

    let label_w = rows
        .iter()
        .map(|r| model_label(&r.key).chars().count())
        .max()
        .unwrap_or(10)
        .clamp(10, 30);
    println!();
    println!(
        "  {DIM}{}  {}  {}  {}  {}  {}{DIM:#}",
        ui::pad_right("Model", label_w),
        ui::pad_left("total", 9),
        ui::pad_left("value", 8),
        ui::pad_left("context", 8),
        ui::pad_right("family", 14),
        "capabilities / scores",
    );
    for r in &rows {
        let label = model_label(&r.key);
        let m = catalog.get(&label);
        let mut tail: Vec<String> = Vec::new();
        if let Some(m) = m {
            tail.extend(m.capabilities.iter().cloned());
            if let Some(score) = m.scores.coding {
                tail.push(format!("coding {score:.0}"));
            } else if let Some(score) = m.scores.intelligence {
                tail.push(format!("intel {score:.0}"));
            }
        }
        println!(
            "  {}  {}  {}  {}  {DIM}{}{DIM:#}  {DIM}{}{DIM:#}",
            ui::pad_right(&label, label_w),
            ui::pad_left(&total_cell(&r.counters), 9),
            ui::pad_left(&price_cell(&prices, &r.key, &r.counters), 8),
            ui::pad_left(
                &m.and_then(|m| m.context_window())
                    .map(ui::tokens)
                    .unwrap_or_else(|| "-".into()),
                8
            ),
            ui::pad_right(m.and_then(|m| m.family.as_deref()).unwrap_or("-"), 14),
            tail.join(", "),
        );
    }
    println!();
    Ok(())
}

/// Fetch the list-rate book and the model catalog, reporting but not failing.
///
/// Called from `setup`, where the run must finish on a machine with no network.
/// A missing snapshot degrades reports to counts without dollars, which is a
/// documented state, not an error.
pub(super) fn fetch_reference_data(json: bool) {
    match tokenstat_sync::pricing::refresh(false) {
        Ok(r) if !json => println!(
            "  {DIM}list rates for {} models, effective {}{DIM:#}",
            ui::exact(r.models as u64),
            r.effective_from
        ),
        Ok(_) => {}
        Err(e) if !json => println!("  {DIM}could not fetch list rates ({e}){DIM:#}"),
        Err(_) => {}
    }
    match tokenstat_sync::catalog::refresh() {
        Ok(r) if !json => println!(
            "  {DIM}catalog for {} models and {} subscription plans{DIM:#}",
            ui::exact(r.models as u64),
            ui::exact(r.plans as u64)
        ),
        Ok(_) => {}
        Err(e) if !json => println!("  {DIM}could not fetch the model catalog ({e}){DIM:#}"),
        Err(_) => {}
    }
}

fn price_or_dash(v: Option<f64>) -> String {
    v.map(ui::usd).unwrap_or_else(|| "-".into())
}

/// Start date of a trailing 30 day window, inclusive of today.
fn last_30_days(tz: &jiff::tz::TimeZone) -> Option<String> {
    today(tz)
        .checked_sub(jiff::Span::new().days(29))
        .ok()
        .map(|d| d.to_string())
}

fn scores_json(s: &tokenstat_core::Scores) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut push = |name: &str, value: Option<f64>| {
        if let Some(v) = value {
            parts.push(format!("\"{name}\":{v}"));
        }
    };
    push("intelligence", s.intelligence);
    push("coding", s.coding);
    push("agentic", s.agentic);
    push("arena_text", s.arena_text);
    push("arena_code", s.arena_code);
    format!("{{{}}}", parts.join(","))
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

    let prices = PriceTable::load_with_catalog();
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
