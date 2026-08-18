//! Model catalog and subscription plans, read from local snapshots.
//!
//! The price book ([`crate::pricing::PriceTable`]) answers one question: what
//! does a token cost. The catalog answers everything else a report wants to say
//! about a model, which the logs never carry: a human name, who publishes it,
//! how big its context is, what it can do, and how it scores on public
//! benchmarks. It also carries per-provider offers, which is what lets a model
//! the list-rate book has never heard of still get a marked estimate instead of
//! a dash.
//!
//! Same rule as pricing: this crate only ever **reads** these files.
//! `tokenstat-sync` fetches and trims them from tokenstat.ai. Two separate
//! snapshots on purpose. Marketplace and aggregator rates must not leak into
//! the list-rate book, because a reseller's price is not the vendor's price, so
//! anything sourced here is surfaced as an estimate and never as a list rate.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::CoreError;
use crate::pricing::{Rates, lookup_keys};

/// Where the trimmed catalog snapshot lives inside the data directory.
const CATALOG_FILE: &str = "current.json";
/// Where the curated subscription plans snapshot lives.
const PLANS_FILE: &str = "plans.json";

/// Rates for one provider's offer of a model, in USD per million tokens.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
pub struct OfferRates {
    pub input: f64,
    pub output: f64,
    #[serde(default)]
    pub cache_read: f64,
    #[serde(rename = "cw5", default)]
    pub cache_write_5m: f64,
    #[serde(rename = "cw1h", default)]
    pub cache_write_1h: f64,
}

impl From<OfferRates> for Rates {
    fn from(o: OfferRates) -> Rates {
        Rates {
            input: o.input,
            output: o.output,
            cache_read: o.cache_read,
            cache_write_5m: o.cache_write_5m,
            cache_write_1h: o.cache_write_1h,
        }
    }
}

/// The offer we price against: first party where we can tell, not the cheapest.
///
/// `cheapest` in the hosted catalog can be any reseller on the marketplace. A
/// usage row belongs to whoever actually served it, so pricing it at a discount
/// gateway's rate would understate the value. The sync client picks the
/// canonical offer (LiteLLM, then the vendor's own, then OpenRouter) and only
/// that one reaches this file.
#[derive(Debug, Clone, Deserialize)]
pub struct CanonicalOffer {
    /// Feed the offer came from: `litellm`, `modelsdev`, or `openrouter`.
    #[serde(rename = "src")]
    pub source: String,
    /// Provider slug when the feed named one.
    #[serde(rename = "prov", default)]
    pub provider: Option<String>,
    #[serde(flatten)]
    pub rates: OfferRates,
}

/// Cheapest offer across every provider, for "you could pay less" context.
#[derive(Debug, Clone, Deserialize)]
pub struct CheapestOffer {
    #[serde(rename = "prov", default)]
    pub provider: Option<String>,
    pub input: f64,
    pub output: f64,
}

/// Public benchmark scores, sparse by nature.
///
/// Coverage is a few hundred models against thousands of catalog entries, so
/// every field is optional and a missing score means "not scored", never zero.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Scores {
    /// Artificial Analysis intelligence index.
    #[serde(rename = "ai", default)]
    pub intelligence: Option<f64>,
    /// Artificial Analysis coding index.
    #[serde(rename = "ac", default)]
    pub coding: Option<f64>,
    /// Artificial Analysis agentic index.
    #[serde(rename = "ag", default)]
    pub agentic: Option<f64>,
    /// Arena Elo, text leaderboard.
    #[serde(rename = "at", default)]
    pub arena_text: Option<f64>,
    /// Arena Elo, code leaderboard.
    #[serde(rename = "acd", default)]
    pub arena_code: Option<f64>,
}

impl Scores {
    pub fn is_empty(&self) -> bool {
        self.intelligence.is_none()
            && self.coding.is_none()
            && self.agentic.is_none()
            && self.arena_text.is_none()
            && self.arena_code.is_none()
    }
}

/// One model in the catalog.
#[derive(Debug, Clone, Deserialize)]
pub struct CatalogModel {
    /// Canonical `vendor/model` id.
    pub id: String,
    /// Human display name when a feed supplied one.
    #[serde(default)]
    pub name: Option<String>,
    /// Other ids that resolve to this model, without gateway prefixes.
    #[serde(default)]
    pub aliases: Vec<String>,
    /// Context window in tokens.
    #[serde(rename = "ctx", default)]
    pub context_length: Option<u64>,
    #[serde(default)]
    pub family: Option<String>,
    #[serde(rename = "released", default)]
    pub release_date: Option<String>,
    /// Capability tags: `reasoning`, `tools`, `open`.
    #[serde(rename = "caps", default)]
    pub capabilities: Vec<String>,
    /// Accepted input modalities: `text`, `image`, `pdf`, …
    #[serde(rename = "inp", default)]
    pub input_modalities: Vec<String>,
    #[serde(rename = "bench", default)]
    pub scores: Scores,
    /// Canonical offer, absent when no feed published rates.
    #[serde(rename = "rates", default)]
    pub offer: Option<CanonicalOffer>,
    /// How many provider offers the hosted catalog merged for this model.
    #[serde(rename = "offers", default)]
    pub offer_count: u32,
    #[serde(default)]
    pub cheapest: Option<CheapestOffer>,
}

impl CatalogModel {
    /// Namespace the catalog filed this model under, e.g. `anthropic` from
    /// `anthropic/claude-opus-5`.
    ///
    /// **Not reliably the publisher.** Where the upstream feeds only saw a
    /// model through a gateway, the namespace is that gateway: Claude Fable 5
    /// is filed under `abacus`, Claude Haiku 4.5 under `302ai`. Use it to
    /// disambiguate ids, not to tell a reader who made the model. [`family`]
    /// is the honest field for display.
    ///
    /// [`family`]: CatalogModel::family
    pub fn namespace(&self) -> &str {
        self.id.split('/').next().unwrap_or(&self.id)
    }

    /// Display name, falling back to the id when no feed named the model.
    pub fn label(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.id)
    }

    /// Context window, treating a zero from a feed as "not published".
    pub fn context_window(&self) -> Option<u64> {
        self.context_length.filter(|n| *n > 0)
    }

    pub fn has_capability(&self, cap: &str) -> bool {
        self.capabilities.iter().any(|c| c == cap)
    }
}

#[derive(Debug, Deserialize)]
struct RawCatalog {
    effective_from: String,
    #[serde(default)]
    models: Vec<CatalogModel>,
}

/// A key resolves to exactly one model, or to several and is therefore useless.
///
/// Ambiguity is real here: thousands of gateway entries reuse bare leaf names.
/// Silently picking one would attach the wrong context window or the wrong
/// price to a row, so an ambiguous key resolves to nothing at all.
#[derive(Debug, Clone, Copy)]
enum Resolved {
    One(usize),
    Ambiguous,
}

/// Local model catalog. Empty when no snapshot has been fetched.
#[derive(Debug, Clone, Default)]
pub struct Catalog {
    pub effective_from: String,
    models: Vec<CatalogModel>,
    by_key: HashMap<String, Resolved>,
    /// Every published window, against the folded ids that carry it, with the
    /// model each entry came from so aliases cannot vote twice.
    ///
    /// Built once at load because `sibling_context_window` runs on the live
    /// meter's poll path, where folding three thousand ids and their aliases
    /// on every call was thousands of throwaway allocations a second.
    windows_by_key: Vec<(String, u64, usize)>,
}

impl Catalog {
    /// Default on-disk location under the tokenstat data directory.
    pub fn default_path() -> Result<PathBuf, CoreError> {
        Ok(data_dir()?.join("catalog").join(CATALOG_FILE))
    }

    /// Load the local snapshot, or an empty catalog when there is none.
    ///
    /// Missing is the normal state for a fresh install, so it is never an
    /// error: reports simply say less about each model.
    pub fn load() -> Catalog {
        match Self::default_path() {
            Ok(path) => Self::load_from(&path).unwrap_or_default(),
            Err(_) => Catalog::default(),
        }
    }

    pub fn load_from(path: &Path) -> Option<Catalog> {
        Self::parse(&std::fs::read_to_string(path).ok()?)
    }

    pub fn parse(contents: &str) -> Option<Catalog> {
        let raw: RawCatalog = serde_json::from_str(contents).ok()?;
        let mut by_key: HashMap<String, Resolved> = HashMap::with_capacity(raw.models.len() * 3);
        for (index, model) in raw.models.iter().enumerate() {
            let mut register = |key: &str| {
                let folded = fold(key);
                if folded.is_empty() {
                    return;
                }
                by_key
                    .entry(folded)
                    .and_modify(|existing| {
                        // The same model registering two keys that fold together
                        // is not ambiguity, it is the same answer twice.
                        if !matches!(existing, Resolved::One(i) if *i == index) {
                            *existing = Resolved::Ambiguous;
                        }
                    })
                    .or_insert(Resolved::One(index));
            };
            register(&model.id);
            if let Some((_, leaf)) = model.id.rsplit_once('/') {
                register(leaf);
            }
            for alias in &model.aliases {
                register(alias);
            }
        }
        let mut windows_by_key: Vec<(String, u64, usize)> = Vec::new();
        for (index, model) in raw.models.iter().enumerate() {
            let Some(window) = model.context_window() else {
                continue;
            };
            let leaf = model.id.rsplit('/').next().unwrap_or(&model.id);
            for key in std::iter::once(leaf).chain(model.aliases.iter().map(String::as_str)) {
                let folded = fold(key.rsplit('/').next().unwrap_or(key));
                if !folded.is_empty() {
                    windows_by_key.push((folded, window, index));
                }
            }
        }
        Some(Catalog {
            effective_from: raw.effective_from,
            models: raw.models,
            by_key,
            windows_by_key,
        })
    }

    pub fn is_empty(&self) -> bool {
        self.models.is_empty()
    }

    pub fn len(&self) -> usize {
        self.models.len()
    }

    pub fn models(&self) -> &[CatalogModel] {
        &self.models
    }

    /// Resolve a model id seen in a log to a catalog entry.
    ///
    /// Tries the id as written first, then the same peeled forms the price book
    /// uses (vendor prefixes, `-thinking` / `-fast` / date suffixes), so
    /// `cursor-grok-4.5-high-fast` and `claude-haiku-4-5-20251001` both land.
    /// The most specific candidate wins, and an ambiguous fold is skipped
    /// rather than guessed.
    pub fn get(&self, model: &str) -> Option<&CatalogModel> {
        for key in lookup_keys(model) {
            match self.by_key.get(&fold(&key)) {
                Some(Resolved::One(index)) => return self.models.get(*index),
                Some(Resolved::Ambiguous) | None => continue,
            }
        }
        None
    }

    /// A context window for a model the snapshot has never heard of, taken
    /// from the models it has that share the id's stem.
    ///
    /// A new model ships before any feed lists it, and today that costs the
    /// live session meter its context bar entirely: `grok-4.6` was priced
    /// correctly by the price book while the catalog had no row for it, so the
    /// window was unknown and the bar disappeared. Siblings are a better answer
    /// than nothing, and a far better one than a constant compiled in here that
    /// nobody would revisit.
    ///
    /// The mode, not the maximum: one sibling with an unusual window should not
    /// decide the answer for the family. Ties go to the larger window, which
    /// under-reports the percentage rather than over-reporting it.
    ///
    /// **Always an estimate.** The caller must mark it, never present it as the
    /// model's published window.
    pub fn sibling_context_window(&self, model: &str) -> Option<u64> {
        let stem = fold(&id_stem(model));
        if stem.len() < 4 {
            return None;
        }
        let mut counts: HashMap<u64, usize> = HashMap::new();
        // A model's own entries are consecutive, so remembering the last one
        // counted is enough to stop three aliases casting three votes.
        let mut last_counted: Option<usize> = None;
        for (key, window, model) in &self.windows_by_key {
            if !key.starts_with(&stem) || last_counted == Some(*model) {
                continue;
            }
            last_counted = Some(*model);
            *counts.entry(*window).or_default() += 1;
        }
        counts
            .into_iter()
            .max_by_key(|&(window, count)| (count, window))
            .map(|(window, _)| window)
    }

    /// Canonical offer rates for a model, for use as a marked estimate.
    ///
    /// Never a list rate. The caller must render these with the same `~`
    /// qualifier as any other estimate.
    pub fn estimate_rates(&self, model: &str) -> Option<Rates> {
        let offer = self.get(model)?.offer.as_ref()?;
        let rates: Rates = offer.rates.into();
        // A feed that publishes an all-zero offer is telling us it does not
        // know the price, not that the model is free.
        (rates.input > 0.0 || rates.output > 0.0).then_some(rates)
    }
}

/// One curated subscription plan.
#[derive(Debug, Clone, Deserialize)]
pub struct Plan {
    pub id: String,
    pub vendor: String,
    pub name: String,
    #[serde(default)]
    pub price_usd_month: Option<f64>,
    #[serde(default)]
    pub price_usd_year: Option<f64>,
    /// Where the plan applies: `coding`, `chat`, …
    #[serde(default)]
    pub surfaces: Vec<String>,
    #[serde(default)]
    pub models: Vec<PlanModel>,
    #[serde(default)]
    pub limits: Vec<PlanLimit>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub source_url: Option<String>,
    #[serde(default)]
    pub checked_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlanModel {
    pub id: String,
    #[serde(default)]
    pub tier: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlanLimit {
    pub kind: String,
    #[serde(default)]
    pub value: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct RawPlans {
    effective_from: String,
    #[serde(default)]
    plans: Vec<Plan>,
}

/// Curated subscription plans. Product prices, not API list rates.
#[derive(Debug, Clone, Default)]
pub struct Plans {
    pub effective_from: String,
    plans: Vec<Plan>,
}

impl Plans {
    pub fn default_path() -> Result<PathBuf, CoreError> {
        Ok(data_dir()?.join("catalog").join(PLANS_FILE))
    }

    pub fn load() -> Plans {
        match Self::default_path() {
            Ok(path) => Self::load_from(&path).unwrap_or_default(),
            Err(_) => Plans::default(),
        }
    }

    pub fn load_from(path: &Path) -> Option<Plans> {
        Self::parse(&std::fs::read_to_string(path).ok()?)
    }

    pub fn parse(contents: &str) -> Option<Plans> {
        let raw: RawPlans = serde_json::from_str(contents).ok()?;
        Some(Plans {
            effective_from: raw.effective_from,
            plans: raw.plans,
        })
    }

    pub fn is_empty(&self) -> bool {
        self.plans.is_empty()
    }

    pub fn len(&self) -> usize {
        self.plans.len()
    }

    pub fn all(&self) -> &[Plan] {
        &self.plans
    }

    /// Plans for one vendor slug, case insensitive.
    pub fn for_vendor(&self, vendor: &str) -> Vec<&Plan> {
        let want = vendor.trim().to_ascii_lowercase();
        self.plans
            .iter()
            .filter(|p| p.vendor.to_ascii_lowercase() == want)
            .collect()
    }
}

fn data_dir() -> Result<PathBuf, CoreError> {
    let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .ok_or(CoreError::NoDataDir)?;
    Ok(dirs.data_dir().to_path_buf())
}

/// The family stem of a model id: the leaf, minus its last version step.
///
/// `xai/grok-4.6` → `grok-4`, `claude-opus-4-6` → `claude-opus-4`. Enough to
/// find siblings, short enough that a point release lands among them.
fn id_stem(model: &str) -> String {
    let leaf = model.rsplit('/').next().unwrap_or(model);
    let cut = leaf
        .char_indices()
        .rfind(|(i, c)| {
            (*c == '.' || *c == '-')
                && *i > 0
                && leaf[i + 1..].starts_with(|c: char| c.is_ascii_digit())
        })
        .map(|(i, _)| i);
    match cut {
        Some(i) => leaf[..i].to_string(),
        None => leaf.to_string(),
    }
}

/// Fold a model id to a match key: lowercase, separators removed.
///
/// The hosted catalog folds `.` and `-` when it joins feeds, so we fold the
/// same way. `claude-opus-5`, `claude.opus.5`, and `Claude_Opus_5` are one key.
fn fold(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const CATALOG: &str = r#"{
      "effective_from": "2026-08-03",
      "models": [
        {
          "id": "anthropic/claude-opus-5",
          "name": "Anthropic: Claude Opus 5",
          "aliases": ["claude-opus-5", "us.anthropic.claude-opus-5"],
          "ctx": 1000000,
          "family": "claude-opus",
          "caps": ["reasoning", "tools"],
          "inp": ["text", "image"],
          "bench": { "ai": 60.7, "ac": 78 },
          "rates": { "src": "litellm", "prov": null, "input": 5, "output": 25,
                     "cache_read": 0.5, "cw5": 6.25, "cw1h": 10 },
          "offers": 28,
          "cheapest": { "prov": "anthropic", "input": 5, "output": 25 }
        },
        {
          "id": "cursor/composer-2.5-fast",
          "name": "Composer 2.5 Fast",
          "aliases": ["composer-2.5-fast"],
          "rates": { "src": "modelsdev", "prov": "cursor", "input": 3, "output": 12 },
          "offers": 2
        },
        {
          "id": "vendor-a/shared-name",
          "aliases": ["shared-name"],
          "rates": { "src": "openrouter", "input": 1, "output": 2 }
        },
        {
          "id": "vendor-b/shared-name",
          "aliases": ["shared-name"],
          "rates": { "src": "openrouter", "input": 9, "output": 9 }
        },
        {
          "id": "someone/unpriced",
          "aliases": ["unpriced"],
          "rates": { "src": "modelsdev", "input": 0, "output": 0 }
        }
      ]
    }"#;

    fn catalog() -> Catalog {
        Catalog::parse(CATALOG).expect("catalog parses")
    }

    #[test]
    fn resolves_a_bare_leaf_to_its_vendor_qualified_model() {
        let c = catalog();
        assert_eq!(
            c.get("claude-opus-5").unwrap().id,
            "anthropic/claude-opus-5"
        );
        assert_eq!(
            c.get("anthropic/claude-opus-5").unwrap().namespace(),
            "anthropic"
        );
    }

    #[test]
    fn a_zero_context_window_reads_as_unpublished_not_as_zero() {
        let c = Catalog::parse(
            r#"{"effective_from":"2026-08-03","models":[
                 {"id":"a/zero","aliases":["zero"],"ctx":0},
                 {"id":"a/known","aliases":["known"],"ctx":200000}]}"#,
        )
        .unwrap();
        assert_eq!(c.get("zero").unwrap().context_window(), None);
        assert_eq!(c.get("known").unwrap().context_window(), Some(200_000));
    }

    #[test]
    fn peels_the_same_suffixes_the_price_book_peels() {
        let c = catalog();
        // Date suffix, vendor prefix, and a capability suffix all resolve.
        assert_eq!(
            c.get("claude-opus-5-20260723").unwrap().id,
            "anthropic/claude-opus-5"
        );
        assert_eq!(
            c.get("claude-opus-5-thinking").unwrap().id,
            "anthropic/claude-opus-5"
        );
        assert_eq!(
            c.get("us.anthropic.claude-opus-5").unwrap().id,
            "anthropic/claude-opus-5"
        );
    }

    #[test]
    fn an_ambiguous_leaf_resolves_to_nothing_rather_than_a_guess() {
        // Two vendors publish `shared-name`. Picking either would attach one
        // vendor's price to the other's usage.
        assert!(catalog().get("shared-name").is_none());
        assert!(catalog().get("vendor-a/shared-name").is_some());
    }

    #[test]
    fn offers_supply_an_estimate_when_the_price_book_has_no_row() {
        let c = catalog();
        let r = c.estimate_rates("composer-2.5-fast").expect("has an offer");
        assert_eq!(r.input, 3.0);
        assert_eq!(r.output, 12.0);
        // Absent cache fields default to zero rather than failing the parse.
        assert_eq!(r.cache_read, 0.0);
    }

    #[test]
    fn an_all_zero_offer_is_unknown_not_free() {
        assert!(catalog().estimate_rates("unpriced").is_none());
    }

    #[test]
    fn capabilities_and_scores_survive_the_round_trip() {
        let c = catalog();
        let m = c.get("claude-opus-5").unwrap();
        assert!(m.has_capability("reasoning"));
        assert!(!m.has_capability("open"));
        assert_eq!(m.context_length, Some(1_000_000));
        assert_eq!(m.scores.coding, Some(78.0));
        assert!(m.scores.agentic.is_none());
        assert!(!m.scores.is_empty());
    }

    #[test]
    fn a_missing_or_invalid_snapshot_is_an_empty_catalog() {
        assert!(Catalog::parse("not json").is_none());
        assert!(Catalog::default().is_empty());
        assert!(Catalog::default().get("anything").is_none());
    }

    #[test]
    fn plans_parse_and_filter_by_vendor() {
        let plans = Plans::parse(
            r#"{"effective_from":"2026-08-03","plans":[
                 {"id":"anthropic/pro","vendor":"anthropic","name":"Claude Pro",
                  "price_usd_month":20,"surfaces":["coding"],
                  "limits":[{"kind":"messages-5h","value":45}]},
                 {"id":"cursor/pro","vendor":"cursor","name":"Cursor Pro","price_usd_month":20}
               ]}"#,
        )
        .expect("plans parse");
        assert_eq!(plans.len(), 2);
        assert_eq!(plans.for_vendor("Anthropic").len(), 1);
        assert_eq!(plans.for_vendor("nobody").len(), 0);
        assert_eq!(plans.all()[0].limits[0].kind, "messages-5h");
    }
}
