//! Refresh list-rate prices from a public model-price feed into the local
//! data directory. Core only reads the resulting file; it never fetches.

use std::collections::BTreeMap;
use std::fs;

use serde::Serialize;
use serde_json::Value;
use tokenstat_core::PriceTable;

/// Community model-price feed (USD per token). Converted to our per-million
/// snapshot shape on disk. Not hosted by tokenstat.ai.
const FEED_URL: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

#[derive(Debug, Clone, Serialize)]
struct OutModel {
    #[serde(rename = "match")]
    pattern: String,
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write_5m: f64,
    cache_write_1h: f64,
}

#[derive(Debug, Serialize)]
struct OutSnapshot {
    effective_from: String,
    note: String,
    models: Vec<OutModel>,
}

#[derive(Debug)]
pub struct PricingRefresh {
    pub path: std::path::PathBuf,
    pub models: usize,
    pub effective_from: String,
    /// Patterns whose input or output rate moved more than 50% vs the prior
    /// local snapshot. Empty on a first fetch.
    pub large_moves: Vec<String>,
}

/// Download the public feed, convert, and write `pricing/current.json`.
///
/// When an existing snapshot is present, rates that jump more than 50% are
/// rejected unless `force` is true, so a bad feed entry cannot silently rewrite
/// every dollar column.
pub fn refresh(force: bool) -> anyhow::Result<PricingRefresh> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .build()?;
    let resp = client.get(FEED_URL).send()?;
    if !resp.status().is_success() {
        anyhow::bail!("price feed returned {}", resp.status());
    }
    let body = resp.text()?;
    let snapshot = convert_feed(&body)?;
    let path = PriceTable::default_path().map_err(|e| anyhow::anyhow!("{e}"))?;
    let large_moves = detect_large_moves(&path, &snapshot);
    if !large_moves.is_empty() && !force {
        anyhow::bail!(
            "price feed moved >50% for {} model(s), e.g. {}. Re-run with --force to accept.",
            large_moves.len(),
            large_moves
                .iter()
                .take(5)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(&snapshot)?;
    fs::write(&path, &json)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }
    Ok(PricingRefresh {
        path,
        models: snapshot.models.len(),
        effective_from: snapshot.effective_from,
        large_moves,
    })
}

fn detect_large_moves(path: &std::path::Path, next: &OutSnapshot) -> Vec<String> {
    let Some(prev) = PriceTable::load_from(path) else {
        return Vec::new();
    };
    if prev.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for m in &next.models {
        let Some(old) = prev.get_exact(&m.pattern) else {
            continue;
        };
        if moved_over_half(old.input, m.input)
            || moved_over_half(old.output, m.output)
            || moved_over_half(old.cache_read, m.cache_read)
            || moved_over_half(old.cache_write_5m, m.cache_write_5m)
            || moved_over_half(old.cache_write_1h, m.cache_write_1h)
        {
            out.push(m.pattern.clone());
        }
    }
    out.sort();
    out
}

fn moved_over_half(old: f64, new: f64) -> bool {
    if old <= 0.0 {
        return new > 0.0;
    }
    ((new - old).abs() / old) > 0.5
}

fn convert_feed(body: &str) -> anyhow::Result<OutSnapshot> {
    let root: BTreeMap<String, Value> = serde_json::from_str(body)?;
    let today = jiff::Timestamp::now()
        .to_zoned(jiff::tz::TimeZone::UTC)
        .date()
        .to_string();

    // Full feed names first, then bare aliases (`xai/grok-4.5` → also `grok-4.5`)
    // so local log ids match without provider prefixes. Prefer canonical
    // providers when two sources claim the same bare name.
    let mut by_pattern: BTreeMap<String, (i32, OutModel)> = BTreeMap::new();
    for (name, meta) in root {
        if name.starts_with("sample_") || name == "error" {
            continue;
        }
        let Some(obj) = meta.as_object() else {
            continue;
        };
        let input_per = obj
            .get("input_cost_per_token")
            .and_then(Value::as_f64)
            .or_else(|| {
                obj.get("input_cost_per_token_batches")
                    .and_then(Value::as_f64)
            });
        let output_per = obj
            .get("output_cost_per_token")
            .and_then(Value::as_f64)
            .or_else(|| {
                obj.get("output_cost_per_token_batches")
                    .and_then(Value::as_f64)
            });
        let (Some(input_per), Some(output_per)) = (input_per, output_per) else {
            continue;
        };

        let cache_read_per = obj
            .get("cache_read_input_token_cost")
            .and_then(Value::as_f64)
            .unwrap_or(input_per * 0.1);
        let cache_write_5m_per = obj
            .get("cache_creation_input_token_cost")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        let cache_write_1h_per = obj
            .get("cache_creation_input_token_cost_above_1hr")
            .and_then(Value::as_f64)
            .unwrap_or(cache_write_5m_per);

        let model = OutModel {
            pattern: name.clone(),
            input: input_per * 1_000_000.0,
            output: output_per * 1_000_000.0,
            cache_read: cache_read_per * 1_000_000.0,
            cache_write_5m: cache_write_5m_per * 1_000_000.0,
            cache_write_1h: cache_write_1h_per * 1_000_000.0,
        };
        let rank = provider_rank(&name);
        insert_rate(&mut by_pattern, name, rank, model.clone());
        for alias in bare_aliases(&model.pattern) {
            let mut aliased = model.clone();
            aliased.pattern = alias.clone();
            // Aliases are slightly less preferred than a native bare entry.
            insert_rate(&mut by_pattern, alias, rank + 10, aliased);
        }
    }

    if by_pattern.is_empty() {
        anyhow::bail!("price feed contained no usable model rates");
    }

    let mut models: Vec<OutModel> = by_pattern.into_values().map(|(_, m)| m).collect();
    models.sort_by(|a, b| a.pattern.cmp(&b.pattern));

    Ok(OutSnapshot {
        effective_from: today,
        note: "Fetched at runtime from a public model-price feed. Not hosted by tokenstat.ai."
            .into(),
        models,
    })
}

/// Lower is better. Prefer first-party provider rows when filling bare aliases.
fn provider_rank(name: &str) -> i32 {
    if !name.contains('/') && !name.contains('.') {
        return 0;
    }
    const FIRST: &[&str] = &[
        "xai/",
        "openai/",
        "gemini/",
        "anthropic.",
        "vertex_ai/",
        "amazon.nova",
    ];
    for (i, p) in FIRST.iter().enumerate() {
        if name.starts_with(p) {
            return 1 + i as i32;
        }
    }
    50
}

fn insert_rate(
    map: &mut BTreeMap<String, (i32, OutModel)>,
    key: String,
    rank: i32,
    model: OutModel,
) {
    match map.get(&key) {
        Some((existing, _)) if *existing <= rank => {}
        _ => {
            map.insert(key, (rank, model));
        }
    }
}

fn bare_aliases(name: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut push = |s: String| {
        if s.len() >= 4 && s != name && !out.iter().any(|x| x == &s) {
            out.push(s);
        }
    };
    if let Some((_, rest)) = name.split_once('/') {
        push(rest.to_string());
        if let Some((_, leaf)) = rest.rsplit_once('/') {
            push(leaf.to_string());
        }
    }
    if let Some((head, rest)) = name.split_once('.') {
        if head.chars().all(|c| c.is_ascii_alphabetic()) && rest.contains('-') {
            push(rest.to_string());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_per_token_feed_into_per_million() {
        let feed = r#"{
          "claude-opus-4-8": {
            "input_cost_per_token": 0.000015,
            "output_cost_per_token": 0.000075,
            "cache_read_input_token_cost": 0.0000015,
            "cache_creation_input_token_cost": 0.00001875
          },
          "sample_skip": {"input_cost_per_token": 1.0, "output_cost_per_token": 1.0}
        }"#;
        let snap = convert_feed(feed).unwrap();
        assert_eq!(snap.models.len(), 1);
        let m = &snap.models[0];
        assert_eq!(m.pattern, "claude-opus-4-8");
        assert!((m.input - 15.0).abs() < 1e-9);
        assert!((m.output - 75.0).abs() < 1e-9);
        assert!((m.cache_read - 1.5).abs() < 1e-9);
        assert!((m.cache_write_5m - 18.75).abs() < 1e-9);
        // No separate 1h field: fall back to the 5m write rate.
        assert!((m.cache_write_1h - 18.75).abs() < 1e-9);
    }

    #[test]
    fn emits_bare_aliases_for_provider_paths() {
        let feed = r#"{
          "xai/grok-4.5": {
            "input_cost_per_token": 0.000002,
            "output_cost_per_token": 0.000006,
            "cache_read_input_token_cost": 0.0000003
          },
          "azure_ai/grok-4.5": {
            "input_cost_per_token": 0.000009,
            "output_cost_per_token": 0.000009
          }
        }"#;
        let snap = convert_feed(feed).unwrap();
        let bare = snap
            .models
            .iter()
            .find(|m| m.pattern == "grok-4.5")
            .expect("bare alias");
        // Prefer xai/ over azure_ai/ for the bare name.
        assert!((bare.input - 2.0).abs() < 1e-9);
        assert!((bare.output - 6.0).abs() < 1e-9);
    }

    #[test]
    fn uses_separate_1h_cache_write_when_present() {
        let feed = r#"{
          "claude-fable-5": {
            "input_cost_per_token": 0.00001,
            "output_cost_per_token": 0.00005,
            "cache_read_input_token_cost": 0.000001,
            "cache_creation_input_token_cost": 0.0000125,
            "cache_creation_input_token_cost_above_1hr": 0.00002
          }
        }"#;
        let snap = convert_feed(feed).unwrap();
        let m = &snap.models[0];
        assert_eq!(m.pattern, "claude-fable-5");
        assert!((m.input - 10.0).abs() < 1e-9);
        assert!((m.output - 50.0).abs() < 1e-9);
        assert!((m.cache_read - 1.0).abs() < 1e-9);
        assert!((m.cache_write_5m - 12.5).abs() < 1e-9);
        assert!((m.cache_write_1h - 20.0).abs() < 1e-9);
    }

    #[test]
    fn flags_rates_that_move_over_half() {
        assert!(!moved_over_half(10.0, 14.0));
        assert!(moved_over_half(10.0, 16.0));
        assert!(moved_over_half(10.0, 4.0));
    }
}
