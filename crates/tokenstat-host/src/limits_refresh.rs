// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Share simultaneous quota reads and bound automatic vendor traffic.

use serde_json::Value;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub(crate) struct LimitsRefresh(Mutex<Option<Entry>>);
struct Entry {
    key: String,
    completed: Instant,
    value: Value,
}

impl LimitsRefresh {
    pub(crate) const fn new() -> Self {
        Self(Mutex::new(None))
    }

    pub(crate) fn run(&self, key: String, force: bool, fetch: impl FnOnce() -> Value) -> Value {
        self.run_at(key, force, Instant::now(), fetch)
    }

    fn run_at(
        &self,
        key: String,
        force: bool,
        requested: Instant,
        fetch: impl FnOnce() -> Value,
    ) -> Value {
        let mut cached = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(entry) = cached.as_ref().filter(|e| e.key == key)
            && (entry.completed >= requested
                || (!force && entry.completed.elapsed() < Duration::from_secs(60)))
        {
            return entry.value.clone();
        }
        let value = fetch();
        *cached = Some(Entry {
            key,
            completed: Instant::now(),
            value: value.clone(),
        });
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_manual_reads_share_but_a_later_manual_refresh_reads_again() {
        let cache = LimitsRefresh::new();
        let overlapping = Instant::now();
        assert_eq!(
            cache.run("owner".into(), true, || Value::from(1)),
            Value::from(1)
        );
        assert_eq!(
            cache.run_at("owner".into(), true, overlapping, || panic!(
                "duplicate vendor pass"
            )),
            Value::from(1)
        );
        assert_eq!(
            cache.run("owner".into(), false, || panic!(
                "automatic pass inside TTL"
            )),
            Value::from(1)
        );
        assert_eq!(
            cache.run("owner".into(), true, || Value::from(2)),
            Value::from(2)
        );
        assert_eq!(
            cache.run("other owner or settings".into(), false, || Value::from(3)),
            Value::from(3)
        );
    }

    #[test]
    fn an_expired_automatic_read_reaches_the_vendor_again() {
        let cache = LimitsRefresh(Mutex::new(Some(Entry {
            key: "owner".into(),
            completed: Instant::now() - Duration::from_secs(61),
            value: Value::from(1),
        })));
        assert_eq!(
            cache.run("owner".into(), false, || Value::from(2)),
            Value::from(2)
        );
    }
}
