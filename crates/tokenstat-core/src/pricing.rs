//! Model prices and the money types.
//!
//! Two product rules are enforced here by construction rather than by care:
//!
//! 1. **Plan usage is never money.** [`Charged`] can only be built from an event
//!    billed per token. Subscription usage becomes an [`EquivalentValue`], which
//!    always renders with a qualifier and cannot be added to a [`Charged`]. There
//!    is no conversion between them, so a report cannot accidentally present a
//!    subscription as a bill.
//! 2. **Prices are local data, not hosted in the repo.** The CLI (via
//!    `tokenstat-sync`) refreshes a snapshot into the user's data directory.
//!    Core only reads that file. No network, and we do not ship a price book.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::CoreError;
use crate::model::{BillingMode, Counters};

/// Rates for one model, in US dollars per million tokens.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
pub struct Rates {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write_5m: f64,
    pub cache_write_1h: f64,
}

#[derive(Debug, Deserialize)]
struct RawModel {
    #[serde(rename = "match")]
    pattern: String,
    #[serde(flatten)]
    rates: Rates,
}

#[derive(Debug, Deserialize)]
struct RawSnapshot {
    effective_from: String,
    models: Vec<RawModel>,
}

/// A dated set of model prices.
#[derive(Debug, Clone, Default)]
pub struct PriceTable {
    pub effective_from: String,
    by_pattern: BTreeMap<String, Rates>,
}

impl PriceTable {
    /// Default on-disk location under the tokenstat data directory.
    pub fn default_path() -> Result<PathBuf, CoreError> {
        let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .ok_or(CoreError::NoDataDir)?;
        Ok(dirs.data_dir().join("pricing").join("current.json"))
    }

    /// Load the local snapshot. Missing or unreadable becomes an empty table
    /// (every model prices as unknown) rather than an error, so reports still
    /// render counts when the user has not refreshed prices yet.
    pub fn load() -> PriceTable {
        match Self::default_path() {
            Ok(path) => Self::load_from(&path).unwrap_or_default(),
            Err(_) => PriceTable::default(),
        }
    }

    pub fn load_from(path: &Path) -> Option<PriceTable> {
        let contents = std::fs::read_to_string(path).ok()?;
        Self::parse(&contents)
    }

    pub fn parse(contents: &str) -> Option<PriceTable> {
        let raw: RawSnapshot = serde_json::from_str(contents).ok()?;
        Some(PriceTable {
            effective_from: raw.effective_from,
            by_pattern: raw
                .models
                .into_iter()
                .map(|m| (m.pattern, m.rates))
                .collect(),
        })
    }

    pub fn is_empty(&self) -> bool {
        self.by_pattern.is_empty()
    }

    pub fn len(&self) -> usize {
        self.by_pattern.len()
    }

    /// Exact pattern match against the snapshot keys (no fuzzy expansion).
    pub fn get_exact(&self, pattern: &str) -> Option<Rates> {
        self.by_pattern.get(pattern).copied()
    }

    /// Look up a model, tolerating vendor prefixes and capability suffixes.
    ///
    /// Logs say things like `claude-haiku-4-5-20251001`,
    /// `cursor-grok-4.5-high-fast`, or `xai/grok-4.5`. The table may store any
    /// of those shapes. We expand both sides and keep the longest match.
    pub fn rates_for(&self, model: &str) -> Option<Rates> {
        let model_keys = lookup_keys(model);
        let mut best: Option<(usize, Rates)> = None;
        for (pattern, rates) in &self.by_pattern {
            for pk in lookup_keys(pattern) {
                // Skip tiny stems that would false-match too widely (`gpt`, `o1`).
                if pk.len() < 4 {
                    continue;
                }
                for mk in &model_keys {
                    if mk.starts_with(pk.as_str()) {
                        let score = pk.len();
                        if best.map(|(s, _)| score > s).unwrap_or(true) {
                            best = Some((score, *rates));
                        }
                    }
                }
            }
        }
        best.map(|(_, r)| r)
    }

    pub fn is_known(&self, model: &str) -> bool {
        self.rates_for(model).is_some()
    }

    /// Value of these counters at list rates, in micros of a dollar.
    fn value_micros(&self, model: &str, c: &Counters) -> Option<i64> {
        let r = self.rates_for(model)?;
        let per = |tokens: Option<u64>, rate: f64| -> f64 {
            tokens.unwrap_or(0) as f64 * rate / 1_000_000.0
        };
        let dollars = per(c.input_fresh, r.input)
            + per(c.output, r.output)
            + per(c.cache_read, r.cache_read)
            + per(c.cache_write_5m, r.cache_write_5m)
            + per(c.cache_write_1h, r.cache_write_1h);
        Some((dollars * 1_000_000.0).round() as i64)
    }
}

/// Keys to try when resolving a log model id against the price book.
fn lookup_keys(model: &str) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    let push = |keys: &mut Vec<String>, s: String| {
        let t = s.trim().to_ascii_lowercase();
        if !t.is_empty() && !keys.iter().any(|k| k == &t) {
            keys.push(t);
        }
    };

    push(&mut keys, model.to_string());

    // Provider path: `xai/grok-4.5`, `openai/gpt-oss-20b`, `zai-org/glm-4.6v-flash`.
    if let Some((_, rest)) = model.split_once('/') {
        push(&mut keys, rest.to_string());
        if let Some((_, leaf)) = rest.rsplit_once('/') {
            push(&mut keys, leaf.to_string());
        }
    }
    // Anthropic-style dotted ids: `anthropic.claude-fable-5`.
    if let Some((head, rest)) = model.split_once('.') {
        if head.chars().all(|c| c.is_ascii_alphabetic()) && rest.contains('-') {
            push(&mut keys, rest.to_string());
        }
    }
    // Cursor wraps underlying models: `cursor-grok-4.5-high-fast`.
    if let Some(rest) = model.strip_prefix("cursor-") {
        push(&mut keys, rest.to_string());
    }

    // Peel agent/speed/thinking suffixes until nothing more matches.
    const SUFFIXES: &[&str] = &[
        "-high-fast",
        "-medium-fast",
        "-low-fast",
        "-extra-high",
        "-thinking-high",
        "-thinking-medium",
        "-thinking-low",
        "-thinking",
        "-fast",
        "-high",
        "-medium",
        "-low",
        "-max",
    ];
    let mut i = 0;
    while i < keys.len() {
        let cur = keys[i].clone();
        for suf in SUFFIXES {
            if let Some(base) = cur.strip_suffix(suf) {
                push(&mut keys, base.to_string());
            }
        }
        // Date suffixes like `-20251001`.
        if let Some((base, tail)) = cur.rsplit_once('-') {
            if tail.len() == 8 && tail.chars().all(|c| c.is_ascii_digit()) {
                push(&mut keys, base.to_string());
            }
        }
        i += 1;
    }

    keys
}

/// Money actually billed. Only constructible from metered usage.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct Charged(i64);

/// What usage would have cost at list rates, when it was not billed that way.
///
/// Always renders with a qualifier, and has no arithmetic with [`Charged`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct EquivalentValue(i64);

impl Charged {
    /// Price metered usage. Returns `None` for anything else, which is the
    /// mechanism preventing plan usage from ever becoming a charge.
    pub fn price(
        table: &PriceTable,
        model: &str,
        counters: &Counters,
        billing: BillingMode,
    ) -> Option<Charged> {
        if billing != BillingMode::Metered {
            return None;
        }
        table.value_micros(model, counters).map(Charged)
    }

    pub fn micros(self) -> i64 {
        self.0
    }
    pub fn dollars(self) -> f64 {
        self.0 as f64 / 1_000_000.0
    }
}

impl EquivalentValue {
    /// What this usage would have cost if it had been billed per token.
    pub fn price(table: &PriceTable, model: &str, counters: &Counters) -> Option<EquivalentValue> {
        table.value_micros(model, counters).map(EquivalentValue)
    }

    pub fn micros(self) -> i64 {
        self.0
    }
    pub fn dollars(self) -> f64 {
        self.0 as f64 / 1_000_000.0
    }
}

impl std::ops::Add for Charged {
    type Output = Charged;
    fn add(self, rhs: Charged) -> Charged {
        Charged(self.0 + rhs.0)
    }
}

impl std::iter::Sum for Charged {
    fn sum<I: Iterator<Item = Charged>>(iter: I) -> Charged {
        Charged(iter.map(|c| c.0).sum())
    }
}

impl std::ops::Add for EquivalentValue {
    type Output = EquivalentValue;
    fn add(self, rhs: EquivalentValue) -> EquivalentValue {
        EquivalentValue(self.0 + rhs.0)
    }
}

impl std::iter::Sum for EquivalentValue {
    fn sum<I: Iterator<Item = EquivalentValue>>(iter: I) -> EquivalentValue {
        EquivalentValue(iter.map(|c| c.0).sum())
    }
}

impl fmt::Display for Charged {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "${:.2}", self.dollars())
    }
}

impl fmt::Display for EquivalentValue {
    /// Never renders as a bare amount. A figure that was not charged must not be
    /// mistakable for one that was.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "${:.2} at list rates", self.dollars())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = r#"{
      "effective_from": "2026-07-29",
      "models": [
        {"match":"claude-opus-4-8","input":15.0,"output":75.0,"cache_read":1.5,"cache_write_5m":18.75,"cache_write_1h":30.0},
        {"match":"claude-opus-4-5","input":5.0,"output":25.0,"cache_read":0.5,"cache_write_5m":6.25,"cache_write_1h":10.0},
        {"match":"claude-haiku-4-5","input":1.0,"output":5.0,"cache_read":0.1,"cache_write_5m":1.25,"cache_write_1h":2.0},
        {"match":"grok-4.5","input":2.0,"output":6.0,"cache_read":0.3,"cache_write_5m":0.0,"cache_write_1h":0.0},
        {"match":"gpt-5.5","input":5.0,"output":30.0,"cache_read":0.5,"cache_write_5m":0.0,"cache_write_1h":0.0}
      ]
    }"#;

    fn table() -> PriceTable {
        PriceTable::parse(FIXTURE).expect("fixture parses")
    }

    fn counters(input: u64, output: u64) -> Counters {
        Counters {
            input_fresh: Some(input),
            output: Some(output),
            cache_read: None,
            cache_write_5m: None,
            cache_write_1h: None,
        }
    }

    #[test]
    fn the_fixture_table_parses() {
        let t = table();
        assert!(!t.effective_from.is_empty());
        assert!(t.is_known("claude-opus-4-8"));
        assert!(t.is_known("grok-4.5"));
        assert_eq!(t.rates_for("grok-4.5").unwrap().input, 2.0);
        assert_eq!(t.rates_for("gpt-5.5").unwrap().output, 30.0);
    }

    #[test]
    fn dated_model_suffixes_still_match() {
        let t = table();
        assert!(t.is_known("claude-haiku-4-5-20251001"));
        assert_eq!(
            t.rates_for("claude-haiku-4-5-20251001"),
            t.rates_for("claude-haiku-4-5")
        );
    }

    #[test]
    fn cursor_and_provider_prefixes_still_match() {
        let t = table();
        assert_eq!(
            t.rates_for("cursor-grok-4.5-high-fast"),
            t.rates_for("grok-4.5")
        );
        assert_eq!(t.rates_for("xai/grok-4.5").unwrap().input, 2.0);
        assert_eq!(
            t.rates_for("claude-opus-4-8-thinking-high"),
            t.rates_for("claude-opus-4-8")
        );
    }

    #[test]
    fn the_longest_matching_pattern_wins() {
        let t = table();
        let cheap = t.rates_for("claude-opus-4-5-20251101").unwrap();
        let dear = t.rates_for("claude-opus-4-8").unwrap();
        assert_ne!(cheap.input, dear.input);
        assert_eq!(cheap.input, 5.0);
        assert_eq!(dear.input, 15.0);
    }

    #[test]
    fn unknown_models_are_not_priced() {
        let t = table();
        assert!(!t.is_known("some-model-we-have-never-seen"));
        assert_eq!(
            Charged::price(
                &t,
                "some-model-we-have-never-seen",
                &counters(1000, 1000),
                BillingMode::Metered
            ),
            None
        );
    }

    #[test]
    fn plan_usage_can_never_become_a_charge() {
        let t = table();
        let c = counters(1_000_000, 1_000_000);
        assert_eq!(
            Charged::price(&t, "claude-opus-4-8", &c, BillingMode::Plan),
            None
        );
        assert_eq!(
            Charged::price(&t, "claude-opus-4-8", &c, BillingMode::Unknown),
            None
        );
        assert!(Charged::price(&t, "claude-opus-4-8", &c, BillingMode::Metered).is_some());
    }

    #[test]
    fn metered_usage_prices_at_the_stated_rate() {
        let t = table();
        let c = counters(1_000_000, 1_000_000);
        let charged = Charged::price(&t, "claude-opus-4-8", &c, BillingMode::Metered).unwrap();
        assert!((charged.dollars() - 90.0).abs() < 0.001);
    }

    #[test]
    fn cache_reads_are_far_cheaper_than_fresh_input() {
        let t = table();
        let fresh = Counters {
            input_fresh: Some(1_000_000),
            ..Default::default()
        };
        let cached = Counters {
            cache_read: Some(1_000_000),
            ..Default::default()
        };
        let a = EquivalentValue::price(&t, "claude-opus-4-8", &fresh).unwrap();
        let b = EquivalentValue::price(&t, "claude-opus-4-8", &cached).unwrap();
        assert!(a.dollars() > b.dollars() * 5.0);
    }

    #[test]
    fn equivalent_value_always_says_it_was_not_charged() {
        let v = EquivalentValue(1_500_000);
        let rendered = v.to_string();
        assert!(rendered.contains("list rates"));
        assert_ne!(rendered, "$1.50");
    }

    #[test]
    fn charged_renders_as_plain_money() {
        assert_eq!(Charged(1_500_000).to_string(), "$1.50");
    }

    #[test]
    fn charged_values_sum() {
        let total: Charged = [Charged(1_000_000), Charged(500_000)].into_iter().sum();
        assert_eq!(total.dollars(), 1.5);
    }

    #[test]
    fn missing_file_loads_as_empty() {
        let t = PriceTable::load_from(Path::new("/no/such/pricing.json"));
        assert!(t.is_none());
        assert!(PriceTable::default().is_empty());
    }
}
