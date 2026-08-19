//! Shared front-end facade over the local archive.
//!
//! CLI, MCP, and (later) GUI should open an [`Engine`] rather than constructing
//! a [`Store`] and timezone by hand. Keeps path and zone resolution in one place.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::error::CoreError;
use crate::model::{Counters, SourceId};
use crate::pricing::{EquivalentValue, PriceTable, display_usage_model_id};
use crate::store::{Bucket, GroupBy, Query, SplitBucket, Store, Totals, UsageBlock};
use crate::{ScanReport, timezone};

/// A report row with its list-rate value attached.
///
/// The value is always an [`EquivalentValue`], never a charge. Subscription
/// usage is valued the same way as metered usage, so this figure answers "what
/// was this worth at list rates" and never "what were you billed".
#[derive(Debug, Clone)]
pub struct PricedBucket {
    pub key: String,
    pub counters: Counters,
    pub events: u64,
    pub sessions: u64,
    /// List-rate value of the priceable share of this bucket.
    pub value: EquivalentValue,
    /// True when any model in the bucket was valued from an estimate rather
    /// than a published rate. Callers must mark these, the CLI uses `~`.
    pub estimated: bool,
    /// Models in this bucket the price book and catalog both had nothing for.
    ///
    /// Their tokens are counted in `counters` but contribute nothing to
    /// `value`, so a non-empty list means `value` is a floor, not a total.
    /// Reporting it as a total would be the "never report zero for a tool that
    /// does not expose counts" mistake in a different coat.
    pub unpriced_models: Vec<String>,
}

impl PricedBucket {
    /// Whether `value` accounts for every token in the bucket.
    pub fn is_complete(&self) -> bool {
        self.unpriced_models.is_empty()
    }
}

/// Open handle to the local archive plus the timezone used for bucketing.
pub struct Engine {
    store: Store,
    tz: jiff::tz::TimeZone,
    db_path: PathBuf,
}

impl Engine {
    /// Open the archive at `db`, or the platform default under the tokenstat
    /// data directory when `db` is `None`.
    pub fn open(db: Option<&Path>, tz_name: Option<&str>) -> Result<Self, CoreError> {
        let db_path = match db {
            Some(p) => p.to_path_buf(),
            None => Store::default_path()?,
        };
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| CoreError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let store = Store::open(&db_path)?;
        let tz = timezone(tz_name)?;
        Ok(Self { store, tz, db_path })
    }

    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    pub fn timezone(&self) -> &jiff::tz::TimeZone {
        &self.tz
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut Store {
        &mut self.store
    }

    pub fn totals(&self, q: &Query) -> Result<Totals, CoreError> {
        self.store.totals(q)
    }

    pub fn report(&self, group: GroupBy, q: &Query) -> Result<Vec<Bucket>, CoreError> {
        let rows = self.store.report(group, q)?;
        Ok(match group {
            GroupBy::Source => fold_source_buckets(rows),
            _ => rows,
        })
    }

    /// [`Engine::report`] with a list-rate value on every row.
    ///
    /// Counters, events and sessions come from the plain report so the numbers
    /// match every other surface exactly. Only the money comes from the
    /// model-split query: session counts cannot be summed across models,
    /// because one session that used two models would count twice.
    pub fn priced_report(
        &self,
        group: GroupBy,
        q: &Query,
        prices: &PriceTable,
    ) -> Result<Vec<PricedBucket>, CoreError> {
        let buckets = self.store.report(group, q)?;
        let split = self.store.report_by_model(group, q)?;

        let mut value_by_key: HashMap<&str, (i64, bool, Vec<String>)> = HashMap::new();
        for row in &split {
            let lookup = display_usage_model_id(&row.split);
            let entry = value_by_key.entry(row.key.as_str()).or_default();
            match EquivalentValue::price(prices, &lookup, &row.counters) {
                Some(v) => {
                    entry.0 += v.micros();
                    entry.1 |= prices.is_estimate(&lookup);
                }
                None => {
                    if !entry.2.contains(&lookup) {
                        entry.2.push(lookup);
                    }
                }
            }
        }

        let priced: Vec<PricedBucket> = buckets
            .into_iter()
            .map(|b| {
                let (micros, estimated, unpriced) =
                    value_by_key.remove(b.key.as_str()).unwrap_or_default();
                PricedBucket {
                    key: b.key,
                    counters: b.counters,
                    events: b.events,
                    sessions: b.sessions,
                    value: EquivalentValue::from_micros(micros),
                    estimated,
                    unpriced_models: unpriced,
                }
            })
            .collect();
        Ok(match group {
            GroupBy::Source => fold_priced_source_buckets(priced),
            _ => priced,
        })
    }

    /// [`Store::report_split`] with recovery rows folded when a side is source.
    pub fn report_split(
        &self,
        group: GroupBy,
        split: GroupBy,
        q: &Query,
    ) -> Result<Vec<SplitBucket>, CoreError> {
        let rows = self.store.report_split(group, split, q)?;
        Ok(fold_split_source_keys(rows, group, split))
    }

    pub fn blocks(&self, q: &Query) -> Result<Vec<UsageBlock>, CoreError> {
        let now_ms = jiff::Timestamp::now().as_millisecond();
        self.store.blocks(q, now_ms)
    }

    pub fn active_block(&self, q: &Query) -> Result<Option<UsageBlock>, CoreError> {
        let now_ms = jiff::Timestamp::now().as_millisecond();
        self.store.active_block(q, now_ms)
    }

    pub fn scan(&mut self) -> Result<ScanReport, CoreError> {
        crate::scan(&mut self.store, &self.tz)
    }
}

/// Fold estimate and rollup rows into Claude Code. Disk ids stay as they are.
fn fold_source_buckets(rows: Vec<Bucket>) -> Vec<Bucket> {
    let mut merged: Vec<Bucket> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for row in rows {
        let key = SourceId::tool_id(&row.key).to_string();
        if let Some(&i) = index.get(&key) {
            merged[i].counters.accumulate(&row.counters);
            merged[i].events += row.events;
            merged[i].sessions += row.sessions;
        } else {
            index.insert(key.clone(), merged.len());
            merged.push(Bucket {
                key,
                counters: row.counters,
                events: row.events,
                sessions: row.sessions,
            });
        }
    }
    merged.sort_by_key(|b| std::cmp::Reverse(b.counters.total()));
    merged
}

fn fold_priced_source_buckets(rows: Vec<PricedBucket>) -> Vec<PricedBucket> {
    let mut merged: Vec<PricedBucket> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for row in rows {
        let key = SourceId::tool_id(&row.key).to_string();
        if let Some(&i) = index.get(&key) {
            merged[i].counters.accumulate(&row.counters);
            merged[i].events += row.events;
            merged[i].sessions += row.sessions;
            let micros = merged[i].value.micros() + row.value.micros();
            merged[i].value = EquivalentValue::from_micros(micros);
            merged[i].estimated |= row.estimated;
            for model in row.unpriced_models {
                if !merged[i].unpriced_models.contains(&model) {
                    merged[i].unpriced_models.push(model);
                }
            }
        } else {
            index.insert(key.clone(), merged.len());
            merged.push(PricedBucket { key, ..row });
        }
    }
    merged.sort_by_key(|b| std::cmp::Reverse(b.counters.total()));
    merged
}

fn fold_split_source_keys(
    rows: Vec<SplitBucket>,
    group: GroupBy,
    split: GroupBy,
) -> Vec<SplitBucket> {
    let fold_key = matches!(group, GroupBy::Source);
    let fold_split = matches!(split, GroupBy::Source);
    if !fold_key && !fold_split {
        return rows;
    }
    let mut merged: Vec<SplitBucket> = Vec::new();
    let mut index: HashMap<(String, String), usize> = HashMap::new();
    for row in rows {
        let key = if fold_key {
            SourceId::tool_id(&row.key).to_string()
        } else {
            row.key
        };
        let split_key = if fold_split {
            SourceId::tool_id(&row.split).to_string()
        } else {
            row.split
        };
        let pair = (key.clone(), split_key.clone());
        if let Some(&i) = index.get(&pair) {
            merged[i].counters.accumulate(&row.counters);
            merged[i].events += row.events;
            merged[i].sessions += row.sessions;
        } else {
            index.insert(pair, merged.len());
            merged.push(SplitBucket {
                key,
                split: split_key,
                counters: row.counters,
                events: row.events,
                sessions: row.sessions,
            });
        }
    }
    let chronological = matches!(group, GroupBy::Day | GroupBy::Week);
    merged.sort_by(|a, b| {
        let keys = if chronological {
            a.key.cmp(&b.key)
        } else {
            b.key.cmp(&a.key)
        };
        keys.then_with(|| b.counters.total().cmp(&a.counters.total()))
    });
    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{BillingMode, Confidence, EventId, Extras, SourceId, Timestamp, UsageEvent};

    const PRICES: &str = r#"{
      "effective_from": "2026-07-29",
      "models": [
        {"match":"claude-opus-4-5","input":5.0,"output":25.0,"cache_read":0.5,"cache_write_5m":6.25,"cache_write_1h":10.0}
      ]
    }"#;

    /// A clock alone is not unique enough. `SystemTime::now()` does not
    /// advance every nanosecond, so two tests entering together built the same
    /// path, shared one SQLite file, and saw each other's events. That failed
    /// as a wrong row count in whichever test lost the race, which reads as a
    /// query bug and is not one.
    static ENGINE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    fn engine() -> Engine {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-engine-{}-{}",
            std::process::id(),
            ENGINE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Engine::open(Some(&dir.join("tokenstat.db")), Some("UTC")).unwrap()
    }

    fn ev(id: &str, model: &str, session: &str) -> UsageEvent {
        UsageEvent {
            id: EventId::derive(&[id]),
            source: SourceId::ClaudeCode,
            ts: Timestamp::from_ms(1_700_000_000_000),
            model: model.into(),
            session: session.into(),
            project: "p".into(),
            counters: Counters {
                input_fresh: Some(1_000_000),
                cache_read: None,
                cache_write_5m: None,
                cache_write_1h: None,
                output: Some(1_000_000),
            },
            extras: Extras::default(),
            billing: BillingMode::Plan,
            confidence: Confidence::Exact,
        }
    }

    #[test]
    fn a_day_bucket_is_valued_from_its_models() {
        let mut e = engine();
        let tz = jiff::tz::TimeZone::UTC;
        e.store_mut()
            .insert_events(&[ev("a", "claude-opus-4-5", "s1")], &tz)
            .unwrap();

        let prices = PriceTable::parse(PRICES).unwrap();
        let rows = e
            .priced_report(GroupBy::Day, &Query::default(), &prices)
            .unwrap();

        // A day key cannot be looked up as a model, so this figure can only
        // come from splitting the bucket by model first.
        assert_eq!(rows.len(), 1);
        assert!((rows[0].value.dollars() - 30.0).abs() < 0.001);
        assert!(rows[0].is_complete());
        assert!(!rows[0].estimated);
    }

    #[test]
    fn a_project_can_be_split_by_the_harness_that_ran_in_it() {
        let mut e = engine();
        let tz = jiff::tz::TimeZone::UTC;
        let mut a = ev("a", "claude-opus-4-5", "s1");
        let mut b = ev("b", "some-model", "s2");
        b.source = SourceId::OpenCode;
        a.project = "/work/alpha".into();
        b.project = "/work/alpha".into();
        let mut c = ev("c", "claude-opus-4-5", "s3");
        c.project = "/work/beta".into();
        e.store_mut().insert_events(&[a, b, c], &tz).unwrap();

        let rows = e
            .store()
            .report_split(GroupBy::Project, GroupBy::Source, &Query::default())
            .unwrap();

        // Two harnesses in alpha, one in beta. This is the shape the sidebar
        // tree is built from, and it must come from one query rather than a
        // filtered query per project.
        let alpha: Vec<_> = rows.iter().filter(|r| r.key == "/work/alpha").collect();
        let beta: Vec<_> = rows.iter().filter(|r| r.key == "/work/beta").collect();
        assert_eq!(alpha.len(), 2);
        assert_eq!(beta.len(), 1);
        assert!(alpha.iter().any(|r| r.split == "opencode"));
        assert!(alpha.iter().any(|r| r.split == "claude_code"));
    }

    #[test]
    fn sessions_are_not_double_counted_across_models() {
        let mut e = engine();
        let tz = jiff::tz::TimeZone::UTC;
        // One session, two models. Summing the model split would report two.
        e.store_mut()
            .insert_events(
                &[
                    ev("a", "claude-opus-4-5", "s1"),
                    ev("b", "some-other-model", "s1"),
                ],
                &tz,
            )
            .unwrap();

        let prices = PriceTable::parse(PRICES).unwrap();
        let rows = e
            .priced_report(GroupBy::Day, &Query::default(), &prices)
            .unwrap();

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].sessions, 1);
        assert_eq!(rows[0].events, 2);
    }

    #[test]
    fn an_unpriced_model_is_named_rather_than_counted_as_zero() {
        let mut e = engine();
        let tz = jiff::tz::TimeZone::UTC;
        e.store_mut()
            .insert_events(
                &[
                    ev("a", "claude-opus-4-5", "s1"),
                    ev("b", "totally-unknown-model", "s2"),
                ],
                &tz,
            )
            .unwrap();

        let prices = PriceTable::parse(PRICES).unwrap();
        let rows = e
            .priced_report(GroupBy::Day, &Query::default(), &prices)
            .unwrap();

        // The value covers only the model that could be priced, and the bucket
        // says so instead of presenting a short figure as a total.
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].is_complete());
        assert_eq!(rows[0].unpriced_models, vec!["totally-unknown-model"]);
        assert!((rows[0].value.dollars() - 30.0).abs() < 0.001);
        // Tokens are still fully counted, only the money is partial.
        assert_eq!(rows[0].counters.output, Some(2_000_000));
    }

    #[test]
    fn recovered_claude_code_folds_into_the_live_tool() {
        let mut e = engine();
        let tz = jiff::tz::TimeZone::UTC;
        let live = ev("a", "claude-opus-4-5", "s1");
        let mut rollup = ev("b", "claude-opus-4-5", "s2");
        rollup.source = SourceId::ClaudeCodeRollup;
        e.store_mut().insert_events(&[live, rollup], &tz).unwrap();

        // Old builds wrote the same shortfall as claude_code_estimate.
        {
            let conn = rusqlite::Connection::open(e.db_path()).unwrap();
            conn.execute(
                "INSERT INTO event (id, source, ts_ms, local_date, local_hour, model,
                                    session, project, input_fresh, output, billing, confidence)
                 VALUES (X'03', 'claude_code_estimate', 1700000000000, '2023-11-14', 22,
                         'claude-opus-4-5', 's3', 'p', 1000000, 1000000, 'plan', 'derived')",
                [],
            )
            .unwrap();
        }

        let prices = PriceTable::parse(PRICES).unwrap();
        let rows = e
            .priced_report(GroupBy::Source, &Query::default(), &prices)
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].key, "claude_code");
        assert_eq!(rows[0].events, 3);
        assert_eq!(rows[0].sessions, 3);
        assert_eq!(rows[0].counters.output, Some(3_000_000));
        assert!((rows[0].value.dollars() - 90.0).abs() < 0.001);

        let split = e
            .report_split(GroupBy::Project, GroupBy::Source, &Query::default())
            .unwrap();
        assert_eq!(split.len(), 1);
        assert_eq!(split[0].split, "claude_code");
        assert_eq!(split[0].events, 3);
    }
}
