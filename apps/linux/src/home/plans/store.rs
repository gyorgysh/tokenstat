// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Shared vendor cache/flight state. Mirrors PlanLimitsStore.swift; the runtime
//! owns IO and waiters, while this type owns freshness, identity and settings.

use super::{LimitsSync, Provider, source_order};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Flight {
    owner: u64,
    id: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refresh {
    Start(Flight),
    Join(Flight),
    Ready,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RefreshError {
    Failed(String),
    Retired,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SettingsRead {
    owner: u64,
    revision: u64,
}
#[derive(Clone, Debug)]
struct Pending {
    ticket: Flight,
    disabled: Vec<Provider>,
}
#[derive(Clone, Debug, Default)]
pub struct Store {
    state: LimitsSync,
    owner: Option<u64>,
    flight: Option<Pending>,
    next_id: u64,
    last_attempt_ms: Option<i64>,
    settings_revision: u64,
}
impl Store {
    /// Read access fences old owners immediately, before a refresh is started.
    pub fn state(&self, owner: u64) -> Option<&LimitsSync> {
        (self.owner == Some(owner)).then_some(&self.state)
    }
    pub fn providers(&self, owner: u64) -> Vec<&Provider> {
        let mut providers: Vec<_> = self
            .state(owner)
            .into_iter()
            .flat_map(|s| &s.providers)
            .collect();
        providers.sort_by(|a, b| source_order(&a.source).cmp(&source_order(&b.source)));
        providers
    }
    pub fn visible(&self, owner: u64) -> Vec<&Provider> {
        let skip = self
            .state(owner)
            .map(|s| s.skip.as_slice())
            .unwrap_or_default();
        self.providers(owner)
            .into_iter()
            .filter(|p| p.visible() && !skip.contains(&p.source))
            .collect()
    }
    pub fn is_refreshing(&self, owner: u64) -> bool {
        self.owner == Some(owner) && self.flight.is_some()
    }
    pub fn begin(&mut self, owner: u64, force: bool, now_ms: i64) -> Refresh {
        if self.owner != Some(owner) {
            self.state = LimitsSync::default();
            self.owner = Some(owner);
            self.flight = None;
            self.last_attempt_ms = None;
        }
        if let Some(pending) = &self.flight {
            return Refresh::Join(pending.ticket);
        }
        if !force
            && self.last_attempt_ms.is_some_and(|last| {
                let age = now_ms.saturating_sub(last);
                (0..30_000).contains(&age)
            })
        {
            return Refresh::Ready;
        }
        self.last_attempt_ms = Some(now_ms);
        self.next_id = self.next_id.wrapping_add(1);
        let ticket = Flight {
            owner,
            id: self.next_id,
        };
        self.flight = Some(Pending {
            ticket,
            disabled: vec![],
        });
        Refresh::Start(ticket)
    }
    pub fn current(&self, flight: Flight, owner: u64) -> bool {
        flight.owner == owner
            && self.owner == Some(owner)
            && self.flight.as_ref().is_some_and(|f| f.ticket == flight)
    }
    pub fn accept_cache(&mut self, flight: Flight, owner: u64, cache: LimitsSync) -> bool {
        if !self.current(flight, owner) {
            return false;
        }
        self.flight.as_mut().unwrap().disabled = cache
            .providers
            .iter()
            .filter(|p| cache.skip.contains(&p.source))
            .cloned()
            .collect();
        self.merge_cached(cache.providers);
        self.state.enabled = cache.enabled;
        self.state.skip = cache.skip;
        true
    }
    pub fn finish(
        &mut self,
        flight: Flight,
        owner: u64,
        result: Result<Vec<Provider>, RefreshError>,
    ) -> Result<(), RefreshError> {
        if !self.current(flight, owner) {
            if self.flight.as_ref().is_some_and(|f| f.ticket == flight) {
                self.flight = None;
            }
            return Err(RefreshError::Retired);
        }
        let pending = self.flight.take().unwrap();
        match result {
            Ok(mut providers) => {
                let disabled: Vec<_> = pending
                    .disabled
                    .into_iter()
                    .filter(|p| !providers.iter().any(|v| v.source == p.source))
                    .collect();
                providers.extend(disabled);
                self.state.providers = providers;
                Ok(())
            }
            Err(error) => {
                if matches!(error, RefreshError::Failed(_)) {
                    for provider in &mut self.state.providers {
                        provider.stale = Some(true);
                    }
                }
                Err(error)
            }
        }
    }
    pub fn settings_changed(&mut self, owner: u64, settings: LimitsSync) {
        self.settings_revision = self.settings_revision.wrapping_add(1);
        if self.owner != Some(owner) {
            self.state = LimitsSync::default();
        }
        self.owner = Some(owner);
        self.state.enabled = settings.enabled;
        self.state.skip = settings.skip;
        self.merge_cached(settings.providers);
        self.flight = None;
        self.last_attempt_ms = None;
    }
    pub fn settings_read(&self, owner: u64) -> SettingsRead {
        SettingsRead {
            owner,
            revision: self.settings_revision,
        }
    }
    pub fn accept_cached_settings(
        &mut self,
        owner: u64,
        requested: SettingsRead,
        settings: LimitsSync,
    ) -> bool {
        if requested.owner != owner || requested.revision != self.settings_revision {
            return false;
        }
        if self.owner != Some(owner) {
            self.settings_changed(owner, settings);
        } else {
            self.state.enabled = settings.enabled;
            self.state.skip = settings.skip;
            self.merge_cached(settings.providers);
        }
        true
    }
    fn merge_cached(&mut self, providers: Vec<Provider>) {
        for provider in providers {
            if let Some(existing) = self
                .state
                .providers
                .iter_mut()
                .find(|p| p.source == provider.source)
            {
                if provider.observed_at_ms > existing.observed_at_ms {
                    *existing = provider;
                }
            } else {
                self.state.providers.push(provider);
            }
        }
    }
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
