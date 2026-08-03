//! Refresh the tokenstat.ai model catalog and subscription plans.
//!
//! The hosted catalog is a merge of several upstream feeds and is roughly 4 MB,
//! most of it gateway aliases, prose descriptions, and one offer row per
//! reseller. None of that helps a local report, so this module **trims on the
//! way in** and writes about a quarter of the bytes. Core reads the trimmed
//! file and never sees the rest.
//!
//! The trim also makes one product decision explicit. The hosted catalog
//! publishes every provider's offer plus a `cheapest` convenience field, but a
//! usage row belongs to whoever actually served it, so pricing it at some
//! discount gateway's rate would understate the value. We keep the **canonical**
//! offer, preferring the same LiteLLM feed the list-rate book comes from, then
//! the model's own vendor, then OpenRouter. `cheapest` is kept only as context
//! to display, never as the rate anything is priced at.
//!
//! There is no separate benchmarks fetch. The hosted catalog already attaches
//! matching scores to each model, and joining a second feed by name on this side
//! would only reproduce that work less accurately.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokenstat_core::{Catalog, Plans};

use crate::snapshot::{self, Fetched, validate_effective_from};

/// Feeds ranked by how much we trust them to state the first-party rate.
const OFFER_PREFERENCE: [&str; 3] = ["litellm", "modelsdev", "openrouter"];

#[derive(Debug)]
pub struct CatalogRefresh {
    pub catalog_path: PathBuf,
    pub plans_path: PathBuf,
    pub models: usize,
    pub priced_models: usize,
    pub plans: usize,
    pub effective_from: String,
    pub plans_effective_from: String,
}

/// Download the catalog and plans snapshots into the local data directory.
pub fn refresh() -> anyhow::Result<CatalogRefresh> {
    let catalog_path = Catalog::default_path().map_err(|e| anyhow::anyhow!("{e}"))?;
    let plans_path = Plans::default_path().map_err(|e| anyhow::anyhow!("{e}"))?;
    refresh_at(
        &snapshot::api_url("/api/v1/catalog/current")?,
        &catalog_path,
        &snapshot::api_url("/api/v1/plans/current")?,
        &plans_path,
    )
}

fn refresh_at(
    catalog_url: &str,
    catalog_path: &Path,
    plans_url: &str,
    plans_path: &Path,
) -> anyhow::Result<CatalogRefresh> {
    let catalog = refresh_catalog_at(catalog_url, catalog_path)?;
    let plans = refresh_plans_at(plans_url, plans_path)?;
    Ok(CatalogRefresh {
        catalog_path: catalog_path.into(),
        plans_path: plans_path.into(),
        models: catalog.models.len(),
        priced_models: catalog.models.iter().filter(|m| m.rates.is_some()).count(),
        plans: plans.plans.len(),
        effective_from: catalog.effective_from,
        plans_effective_from: plans.effective_from,
    })
}

fn refresh_catalog_at(url: &str, path: &Path) -> anyhow::Result<TrimmedCatalog> {
    // 120s rather than the pricing feed's 60s: this response is several
    // megabytes before it reaches us.
    match snapshot::fetch_conditional(url, path, 120)? {
        Fetched::NotModified => load_trimmed(path).ok_or_else(|| {
            anyhow::anyhow!("catalog API returned 304 but no local snapshot exists")
        }),
        Fetched::Body { text, etag } => {
            let trimmed = trim_catalog(&text)?;
            let json = serde_json::to_string(&trimmed)?;
            snapshot::store(path, &json, etag)?;
            Ok(trimmed)
        }
    }
}

fn refresh_plans_at(url: &str, path: &Path) -> anyhow::Result<RawPlans> {
    match snapshot::fetch_conditional(url, path, 60)? {
        Fetched::NotModified => {
            let text = std::fs::read_to_string(path)
                .map_err(|_| anyhow::anyhow!("plans API returned 304 but no snapshot exists"))?;
            parse_plans(&text)
        }
        Fetched::Body { text, etag } => {
            let plans = parse_plans(&text)?;
            let json = serde_json::to_string(&plans)?;
            snapshot::store(path, &json, etag)?;
            Ok(plans)
        }
    }
}

fn load_trimmed(path: &Path) -> Option<TrimmedCatalog> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

// ---------------------------------------------------------------- wire types

/// The hosted catalog, as far as we care about it. Unknown fields are dropped
/// on purpose: the contract says new ones may appear and clients must ignore them.
#[derive(Debug, Deserialize)]
struct WireCatalog {
    effective_from: String,
    #[serde(default)]
    models: Vec<WireModel>,
}

#[derive(Debug, Deserialize)]
struct WireModel {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    aliases: Vec<String>,
    #[serde(default)]
    context_length: Option<u64>,
    #[serde(default)]
    family: Option<String>,
    #[serde(default)]
    release_date: Option<String>,
    #[serde(default)]
    capabilities: WireCapabilities,
    #[serde(default)]
    benchmarks: WireBenchmarks,
    #[serde(default)]
    offers: Vec<WireOffer>,
    #[serde(default)]
    offer_count: u32,
    #[serde(default)]
    cheapest: Option<WireCheapest>,
}

#[derive(Debug, Default, Deserialize)]
struct WireCapabilities {
    #[serde(default)]
    reasoning: bool,
    #[serde(default)]
    tool_call: bool,
    #[serde(default)]
    open_weights: bool,
    #[serde(default)]
    input_modalities: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct WireBenchmarks {
    #[serde(default)]
    scores: WireScores,
}

#[derive(Debug, Default, Deserialize)]
struct WireScores {
    #[serde(default)]
    aa_intelligence_index: Option<f64>,
    #[serde(default)]
    aa_coding_index: Option<f64>,
    #[serde(default)]
    aa_agentic_index: Option<f64>,
    #[serde(default)]
    arena_text: Option<f64>,
    #[serde(default)]
    arena_code: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct WireOffer {
    source: String,
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    input: Option<f64>,
    #[serde(default)]
    output: Option<f64>,
    #[serde(default)]
    cache_read: Option<f64>,
    #[serde(default)]
    cache_write: Option<f64>,
    #[serde(default)]
    cache_write_5m: Option<f64>,
    #[serde(default)]
    cache_write_1h: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct WireCheapest {
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    input: Option<f64>,
    #[serde(default)]
    output: Option<f64>,
}

// ------------------------------------------------------------- trimmed types

/// What actually lands on disk. Field names are short because this file has one
/// row per model and there are thousands of them.
#[derive(Debug, Serialize, Deserialize)]
struct TrimmedCatalog {
    effective_from: String,
    models: Vec<TrimmedModel>,
}

#[derive(Debug, Serialize, Deserialize)]
struct TrimmedModel {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    aliases: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ctx: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    family: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    released: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    caps: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    inp: Vec<String>,
    #[serde(default, skip_serializing_if = "TrimmedScores::is_empty")]
    bench: TrimmedScores,
    #[serde(skip_serializing_if = "Option::is_none")]
    rates: Option<TrimmedOffer>,
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    offers: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    cheapest: Option<TrimmedCheapest>,
}

fn is_zero_u32(n: &u32) -> bool {
    *n == 0
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct TrimmedScores {
    #[serde(skip_serializing_if = "Option::is_none")]
    ai: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ac: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ag: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    acd: Option<f64>,
}

impl TrimmedScores {
    fn is_empty(&self) -> bool {
        self.ai.is_none()
            && self.ac.is_none()
            && self.ag.is_none()
            && self.at.is_none()
            && self.acd.is_none()
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct TrimmedOffer {
    src: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    prov: Option<String>,
    input: f64,
    output: f64,
    #[serde(default)]
    cache_read: f64,
    #[serde(default)]
    cw5: f64,
    #[serde(default)]
    cw1h: f64,
}

#[derive(Debug, Serialize, Deserialize)]
struct TrimmedCheapest {
    #[serde(skip_serializing_if = "Option::is_none")]
    prov: Option<String>,
    input: f64,
    output: f64,
}

// ------------------------------------------------------------------ trimming

fn trim_catalog(body: &str) -> anyhow::Result<TrimmedCatalog> {
    let wire: WireCatalog =
        serde_json::from_str(body).map_err(|e| anyhow::anyhow!("invalid catalog snapshot: {e}"))?;
    validate_effective_from(&wire.effective_from, "catalog")?;
    if wire.models.is_empty() {
        anyhow::bail!("invalid catalog snapshot: models must not be empty");
    }
    let models: Vec<TrimmedModel> = wire.models.into_iter().map(trim_model).collect();
    Ok(TrimmedCatalog {
        effective_from: wire.effective_from,
        models,
    })
}

fn trim_model(m: WireModel) -> TrimmedModel {
    let vendor = m.id.split('/').next().unwrap_or("").to_ascii_lowercase();
    let rates = canonical_offer(&m.offers, &vendor).map(trim_offer);
    let mut caps = Vec::new();
    if m.capabilities.reasoning {
        caps.push("reasoning".to_string());
    }
    if m.capabilities.tool_call {
        caps.push("tools".to_string());
    }
    if m.capabilities.open_weights {
        caps.push("open".to_string());
    }
    TrimmedModel {
        aliases: trim_aliases(&m.id, m.aliases),
        id: m.id,
        name: m.name,
        ctx: m.context_length,
        family: m.family,
        released: m.release_date,
        caps,
        inp: m.capabilities.input_modalities,
        bench: TrimmedScores {
            ai: m.benchmarks.scores.aa_intelligence_index,
            ac: m.benchmarks.scores.aa_coding_index,
            ag: m.benchmarks.scores.aa_agentic_index,
            at: m.benchmarks.scores.arena_text,
            acd: m.benchmarks.scores.arena_code,
        },
        rates,
        offers: m.offer_count,
        cheapest: m.cheapest.and_then(|c| {
            Some(TrimmedCheapest {
                prov: c.provider,
                input: c.input?,
                output: c.output?,
            })
        }),
    }
}

/// Keep aliases that could plausibly appear in a log, drop gateway routes.
///
/// A local tool logs `claude-opus-5` or `us.anthropic.claude-opus-5`, never
/// `merge-gateway/anthropic/claude-opus-5`. Core peels vendor prefixes before it
/// looks anything up, so the slash forms would not add a single resolution, and
/// they are most of the file's weight.
fn trim_aliases(id: &str, aliases: Vec<String>) -> Vec<String> {
    let mut kept: Vec<String> = aliases
        .into_iter()
        .filter(|a| !a.contains('/') && a != id && !a.trim().is_empty())
        .collect();
    kept.sort();
    kept.dedup();
    kept
}

/// The offer we treat as first party, by feed preference then vendor match.
fn canonical_offer<'a>(offers: &'a [WireOffer], vendor: &str) -> Option<&'a WireOffer> {
    let priced = |o: &&WireOffer| o.input.is_some() || o.output.is_some();
    for source in OFFER_PREFERENCE {
        // Within a feed, the model's own vendor beats a reseller on it.
        let mut same_source = offers.iter().filter(|o| o.source == source).filter(priced);
        let from_vendor = same_source.clone().find(|o| {
            o.provider
                .as_deref()
                .is_some_and(|p| p.eq_ignore_ascii_case(vendor))
        });
        if let Some(offer) = from_vendor.or_else(|| same_source.next()) {
            return Some(offer);
        }
    }
    offers.iter().find(priced)
}

fn trim_offer(o: &WireOffer) -> TrimmedOffer {
    let write_5m = o.cache_write_5m.or(o.cache_write).unwrap_or(0.0);
    TrimmedOffer {
        src: o.source.clone(),
        prov: o.provider.clone(),
        input: o.input.unwrap_or(0.0),
        output: o.output.unwrap_or(0.0),
        cache_read: o.cache_read.unwrap_or(0.0),
        cw5: write_5m,
        // Feeds that do not distinguish TTLs quote one cache-write rate. Reusing
        // it for the 1h tier is closer than pricing that tier at zero.
        cw1h: o.cache_write_1h.unwrap_or(write_5m),
    }
}

// --------------------------------------------------------------------- plans

/// Plans are already small and already the shape core wants, so this is a
/// validate-and-reserialize rather than a trim.
#[derive(Debug, Serialize, Deserialize)]
struct RawPlans {
    effective_from: String,
    #[serde(default)]
    note: Option<String>,
    #[serde(default)]
    plans: Vec<serde_json::Value>,
}

fn parse_plans(body: &str) -> anyhow::Result<RawPlans> {
    let plans: RawPlans =
        serde_json::from_str(body).map_err(|e| anyhow::anyhow!("invalid plans snapshot: {e}"))?;
    validate_effective_from(&plans.effective_from, "plans")?;
    if plans.plans.is_empty() {
        anyhow::bail!("invalid plans snapshot: plans must not be empty");
    }
    Ok(plans)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CATALOG: &str = r#"{
      "effective_from": "2026-08-03",
      "note": "Merged model catalog generated by tokenstat.ai.",
      "sources": { "litellm": { "modelCount": 1 } },
      "models": [
        {
          "id": "anthropic/claude-opus-5",
          "name": "Anthropic: Claude Opus 5",
          "aliases": ["claude-opus-5", "openrouter/anthropic/claude-opus-5",
                      "us.anthropic.claude-opus-5", "anthropic/claude-opus-5"],
          "context_length": 1000000,
          "description": "a long description we do not keep",
          "family": "claude-opus",
          "release_date": "2026-07-24",
          "capabilities": { "reasoning": true, "tool_call": true,
                            "open_weights": false, "input_modalities": ["text", "image"],
                            "some_future_field": 1 },
          "benchmarks": { "scores": { "aa_intelligence_index": 60.7, "aa_coding_index": 78,
                                      "arena_agent_rank": 3 } },
          "offers": [
            { "source": "openrouter", "id": "x", "input": 4.0, "output": 20.0,
              "cache_read": 0.4, "cache_write": 5.0 },
            { "source": "modelsdev", "provider": "reseller", "input": 1.0, "output": 2.0 },
            { "source": "modelsdev", "provider": "anthropic", "input": 5.0, "output": 25.0 },
            { "source": "litellm", "match": "anthropic/claude-opus-5", "input": 5.0,
              "output": 25.0, "cache_read": 0.5, "cache_write_5m": 6.25, "cache_write_1h": 10.0 }
          ],
          "offer_count": 4,
          "cheapest": { "source": "modelsdev", "provider": "reseller", "input": 1.0, "output": 2.0 }
        },
        {
          "id": "cursor/composer-2.5-fast",
          "aliases": ["composer-2.5-fast"],
          "offers": [
            { "source": "openrouter", "input": 3.0, "output": 12.0, "cache_write": 3.5 }
          ],
          "offer_count": 1
        },
        {
          "id": "someone/no-offers",
          "aliases": [],
          "offers": [],
          "offer_count": 0
        }
      ]
    }"#;

    fn trimmed() -> TrimmedCatalog {
        trim_catalog(CATALOG).expect("catalog trims")
    }

    #[test]
    fn prefers_the_list_rate_feed_over_a_cheaper_marketplace_offer() {
        let t = trimmed();
        let rates = t.models[0].rates.as_ref().expect("has canonical rates");
        assert_eq!(rates.src, "litellm");
        assert_eq!(rates.input, 5.0);
        assert_eq!(rates.cw1h, 10.0);
        // The cheapest offer is a $1 reseller. It is kept as context only, and
        // must not be what the model prices at.
        assert_eq!(t.models[0].cheapest.as_ref().unwrap().input, 1.0);
    }

    #[test]
    fn prefers_the_vendors_own_offer_within_a_feed() {
        // modelsdev lists both a reseller and Anthropic. Drop litellm and the
        // vendor row must win, not the first row or the cheapest one.
        let wire: WireCatalog = serde_json::from_str(CATALOG).unwrap();
        let offers: Vec<WireOffer> = wire
            .models
            .into_iter()
            .next()
            .unwrap()
            .offers
            .into_iter()
            .filter(|o| o.source != "litellm")
            .collect();
        let chosen = canonical_offer(&offers, "anthropic").unwrap();
        assert_eq!(chosen.source, "modelsdev");
        assert_eq!(chosen.provider.as_deref(), Some("anthropic"));
    }

    #[test]
    fn falls_back_to_a_single_marketplace_offer_when_that_is_all_there_is() {
        let t = trimmed();
        let rates = t.models[1].rates.as_ref().expect("has rates");
        assert_eq!(rates.src, "openrouter");
        // One quoted cache-write rate covers both TTL tiers.
        assert_eq!(rates.cw5, 3.5);
        assert_eq!(rates.cw1h, 3.5);
    }

    #[test]
    fn a_model_with_no_offers_keeps_its_metadata_and_no_rates() {
        let t = trimmed();
        assert_eq!(t.models[2].id, "someone/no-offers");
        assert!(t.models[2].rates.is_none());
    }

    #[test]
    fn drops_gateway_aliases_and_the_id_itself() {
        let aliases = &trimmed().models[0].aliases;
        assert_eq!(aliases, &["claude-opus-5", "us.anthropic.claude-opus-5"]);
    }

    #[test]
    fn keeps_only_the_scores_and_capabilities_reports_use() {
        let t = trimmed();
        let m = &t.models[0];
        assert_eq!(m.caps, ["reasoning", "tools"]);
        assert_eq!(m.bench.ai, Some(60.7));
        assert!(m.bench.ag.is_none());
    }

    #[test]
    fn the_trimmed_file_is_what_core_parses() {
        let json = serde_json::to_string(&trimmed()).unwrap();
        let catalog = Catalog::parse(&json).expect("core parses the trimmed catalog");
        assert_eq!(catalog.len(), 3);
        let m = catalog.get("claude-opus-5").expect("resolves by alias");
        assert_eq!(m.id, "anthropic/claude-opus-5");
        assert_eq!(m.context_length, Some(1_000_000));
        assert!(m.has_capability("reasoning"));
        let rates = catalog.estimate_rates("composer-2.5-fast").unwrap();
        assert_eq!(rates.output, 12.0);
    }

    #[test]
    fn trimming_drops_most_of_the_payload() {
        let trimmed_bytes = serde_json::to_string(&trimmed()).unwrap().len();
        assert!(
            trimmed_bytes < CATALOG.len(),
            "trimmed {trimmed_bytes} should be smaller than {}",
            CATALOG.len()
        );
    }

    #[test]
    fn an_invalid_snapshot_is_rejected_rather_than_stored() {
        assert!(trim_catalog("not json").is_err());
        assert!(trim_catalog(r#"{"effective_from":"2026-08-03","models":[]}"#).is_err());
        assert!(trim_catalog(r#"{"effective_from":"whenever","models":[{"id":"a/b"}]}"#).is_err());
    }

    #[test]
    fn plans_validate_before_they_are_stored() {
        let good = r#"{"effective_from":"2026-08-03","note":"n",
                       "plans":[{"id":"anthropic/pro","vendor":"anthropic",
                                 "name":"Claude Pro","price_usd_month":20}]}"#;
        assert_eq!(parse_plans(good).unwrap().plans.len(), 1);
        assert!(parse_plans(r#"{"effective_from":"2026-08-03","plans":[]}"#).is_err());
        assert!(parse_plans("[]").is_err());
        // Whatever we accept must round-trip into the type core reads.
        let stored = serde_json::to_string(&parse_plans(good).unwrap()).unwrap();
        assert_eq!(Plans::parse(&stored).unwrap().len(), 1);
    }
}
