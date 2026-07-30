//! Local spend budgets against list-rate equivalent value.
//!
//! Budgets are advisory. They compare the list-rate value of usage in the
//! archive to limits the user set. Plan-covered usage still shows as equivalent
//! value, never as money charged.

use crate::error::CoreError;
use crate::pricing::{EquivalentValue, PriceTable};
use crate::store::{GroupBy, Query, Store};

const META_DAILY: &str = "budget.daily_usd";
const META_MONTHLY: &str = "budget.monthly_usd";

/// Soft caps the user configured, in USD list-rate equivalent.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct BudgetLimits {
    pub daily_usd: Option<f64>,
    pub monthly_usd: Option<f64>,
}

/// How today and this calendar month sit against the configured caps.
#[derive(Debug, Clone)]
pub struct BudgetStatus {
    pub limits: BudgetLimits,
    pub today_usd: f64,
    pub month_usd: f64,
    pub today_date: String,
    pub month_key: String,
}

impl BudgetStatus {
    pub fn today_ratio(&self) -> Option<f64> {
        self.limits
            .daily_usd
            .filter(|l| *l > 0.0)
            .map(|l| self.today_usd / l)
    }

    pub fn month_ratio(&self) -> Option<f64> {
        self.limits
            .monthly_usd
            .filter(|l| *l > 0.0)
            .map(|l| self.month_usd / l)
    }

    pub fn over_daily(&self) -> bool {
        self.today_ratio().is_some_and(|r| r >= 1.0)
    }

    pub fn over_monthly(&self) -> bool {
        self.month_ratio().is_some_and(|r| r >= 1.0)
    }
}

impl BudgetLimits {
    pub fn load(store: &Store) -> Result<Self, CoreError> {
        Ok(Self {
            daily_usd: parse_usd(store.meta(META_DAILY)?)?,
            monthly_usd: parse_usd(store.meta(META_MONTHLY)?)?,
        })
    }

    pub fn save(&self, store: &Store) -> Result<(), CoreError> {
        match self.daily_usd {
            Some(v) => store.set_meta(META_DAILY, &format!("{v:.4}"))?,
            None => store.delete_meta(META_DAILY)?,
        }
        match self.monthly_usd {
            Some(v) => store.set_meta(META_MONTHLY, &format!("{v:.4}"))?,
            None => store.delete_meta(META_MONTHLY)?,
        }
        Ok(())
    }

    pub fn is_empty(&self) -> bool {
        self.daily_usd.is_none() && self.monthly_usd.is_none()
    }
}

/// List-rate value of every model bucket matching `q`.
pub fn list_value(store: &Store, q: &Query, prices: &PriceTable) -> Result<f64, CoreError> {
    let buckets = store.report(GroupBy::Model, q)?;
    let total: EquivalentValue = buckets
        .iter()
        .filter_map(|b| EquivalentValue::price(prices, &b.key, &b.counters))
        .sum();
    Ok(total.dollars())
}

/// Evaluate today's and this month's list-rate spend against stored limits.
pub fn status(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    prices: &PriceTable,
) -> Result<BudgetStatus, CoreError> {
    let limits = BudgetLimits::load(store)?;
    let today = jiff::Timestamp::now().to_zoned(tz.clone()).date();
    let today_date = today.to_string();
    let month_key = today_date.get(..7).unwrap_or(&today_date).to_string();
    let month_start = format!("{month_key}-01");

    let today_usd = list_value(
        store,
        &Query {
            since: Some(today_date.clone()),
            until: Some(today_date.clone()),
            ..Query::default()
        },
        prices,
    )?;
    let month_usd = list_value(
        store,
        &Query {
            since: Some(month_start),
            until: Some(today_date.clone()),
            ..Query::default()
        },
        prices,
    )?;

    Ok(BudgetStatus {
        limits,
        today_usd,
        month_usd,
        today_date,
        month_key,
    })
}

fn parse_usd(raw: Option<String>) -> Result<Option<f64>, CoreError> {
    match raw {
        None => Ok(None),
        Some(s) => {
            let v: f64 = s
                .parse()
                .map_err(|_| CoreError::InvalidBudget(format!("not a number: {s}")))?;
            if !v.is_finite() || v < 0.0 {
                return Err(CoreError::InvalidBudget(format!("invalid amount: {s}")));
            }
            Ok(Some(v))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        BillingMode, Confidence, Counters, EventId, SourceId, Timestamp, UsageEvent,
    };
    use crate::pricing::PriceTable;

    fn prices() -> PriceTable {
        let json = r#"{
          "effective_from": "2026-01-01",
          "models": [{
            "match": "test-model",
            "input": 10.0,
            "output": 20.0,
            "cache_read": 1.0,
            "cache_write_5m": 2.0,
            "cache_write_1h": 3.0
          }]
        }"#;
        PriceTable::parse(json).unwrap()
    }

    #[test]
    fn round_trips_limits_through_meta() {
        let store = Store::open_in_memory().unwrap();
        let limits = BudgetLimits {
            daily_usd: Some(5.0),
            monthly_usd: Some(40.0),
        };
        limits.save(&store).unwrap();
        assert_eq!(BudgetLimits::load(&store).unwrap(), limits);
        BudgetLimits::default().save(&store).unwrap();
        assert!(BudgetLimits::load(&store).unwrap().is_empty());
    }

    #[test]
    fn status_sums_list_rate_for_today() {
        let mut store = Store::open_in_memory().unwrap();
        let tz = jiff::tz::TimeZone::UTC;
        let today = jiff::Timestamp::now()
            .to_zoned(tz.clone())
            .date()
            .to_string();
        // 1M input @ $10/M = $10
        let _ = today;
        let ev = UsageEvent {
            id: EventId::derive(&["budget-test"]),
            source: SourceId::ClaudeCode,
            ts: Timestamp::from_ms(jiff::Timestamp::now().as_millisecond()),
            model: "test-model".into(),
            session: "s".into(),
            project: "p".into(),
            counters: Counters {
                input_fresh: Some(1_000_000),
                output: Some(0),
                cache_read: None,
                cache_write_5m: None,
                cache_write_1h: None,
            },
            extras: crate::model::Extras::default(),
            billing: BillingMode::Plan,
            confidence: Confidence::Exact,
        };
        store.insert_events(&[ev], &tz).unwrap();
        BudgetLimits {
            daily_usd: Some(5.0),
            monthly_usd: None,
        }
        .save(&store)
        .unwrap();
        let st = status(&store, &tz, &prices()).unwrap();
        assert!((st.today_usd - 10.0).abs() < 1e-6);
        assert!(st.over_daily());
    }
}
