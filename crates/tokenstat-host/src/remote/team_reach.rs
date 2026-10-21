// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::tunnel_runtime::Scope;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

const MAX_SCOPES: usize = 32;
const MAX_DEMANDS: usize = 64;
#[derive(Default)]
struct Entry {
    hosting: bool,
    restoring: bool,
    demands: usize,
    lifetime: Arc<()>,
}
#[derive(Default)]
struct Registry {
    entries: HashMap<Scope, Entry>,
}
impl Registry {
    #[cfg(any(feature = "local-host", test))]
    fn hosting(&mut self, scope: &Scope, enabled: bool) -> bool {
        if !enabled && !self.entries.contains_key(scope) {
            return true;
        }
        if enabled && !self.entries.contains_key(scope) && self.entries.len() >= MAX_SCOPES {
            return false;
        }
        self.entries.entry(scope.clone()).or_default().hosting = enabled;
        self.prune(scope);
        true
    }
    fn active(&self, scope: &Scope) -> bool {
        self.entries
            .get(scope)
            .is_some_and(|entry| entry.hosting || entry.demands > 0)
    }
    fn wanted(&self, scope: &Scope) -> bool {
        self.active(scope) || self.entries.get(scope).is_some_and(|entry| entry.restoring)
    }
    #[cfg(any(feature = "local-host", test))]
    fn restoring(&mut self, scope: &Scope, enabled: bool) {
        if !enabled && !self.entries.contains_key(scope) {
            return;
        }
        if enabled && !self.entries.contains_key(scope) && self.entries.len() >= MAX_SCOPES {
            return;
        }
        self.entries.entry(scope.clone()).or_default().restoring = enabled;
        self.prune(scope);
    }
    fn acquire(&mut self, scope: &Scope) -> Option<Arc<()>> {
        if !self.entries.contains_key(scope) && self.entries.len() >= MAX_SCOPES {
            return None;
        }
        let entry = self.entries.entry(scope.clone()).or_default();
        if entry.demands >= MAX_DEMANDS {
            return None;
        }
        entry.demands += 1;
        Some(entry.lifetime.clone())
    }
    fn release(&mut self, scope: &Scope, lifetime: &Arc<()>) {
        if let Some(entry) = self.entries.get_mut(scope)
            && Arc::ptr_eq(&entry.lifetime, lifetime)
        {
            entry.demands = entry.demands.saturating_sub(1);
        }
        self.prune(scope);
    }
    fn prune(&mut self, scope: &Scope) {
        if self
            .entries
            .get(scope)
            .is_some_and(|entry| !entry.hosting && !entry.restoring && entry.demands == 0)
        {
            self.entries.remove(scope);
        }
    }
}
fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}
pub(super) fn active(scope: &Scope) -> bool {
    registry().lock().is_ok_and(|held| held.active(scope))
}
#[cfg(feature = "local-host")]
pub(super) fn hosting(scope: &Scope, enabled: bool) -> Result<(), String> {
    if registry()
        .lock()
        .map_err(|_| "Team availability is unavailable.")?
        .hosting(scope, enabled)
    {
        Ok(())
    } else {
        Err("Too many Team connections are changing. Try again shortly.".into())
    }
}
#[cfg(feature = "local-host")]
pub(super) fn restoring(scope: &Scope, enabled: bool) {
    if let Ok(mut held) = registry().lock() {
        held.restoring(scope, enabled);
    }
}
pub(super) fn wanted(scope: &Scope) -> bool {
    registry().lock().is_ok_and(|held| held.wanted(scope))
}
pub(super) fn clear() {
    if let Ok(mut held) = registry().lock() {
        held.entries.clear();
    }
}

pub(super) struct Demand {
    scope: Scope,
    lifetime: Arc<()>,
}
impl Drop for Demand {
    fn drop(&mut self) {
        if let Ok(mut held) = registry().lock() {
            held.release(&self.scope, &self.lifetime);
        }
        super::tunnel_lifecycle::retire_if_unused(&self.scope);
    }
}
pub(super) fn acquire(scope: Scope) -> Result<Demand, String> {
    let lifetime = registry()
        .lock()
        .map_err(|_| "Team availability is unavailable.")?
        .acquire(&scope)
        .ok_or("Too many Team connections are active. Close an unused connection and try again.")?;
    Ok(Demand { scope, lifetime })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn scope(owner: usize) -> Scope {
        Scope {
            owner: format!("owner-{owner}"),
            key: [1; 32],
            endpoint: "ws://127.0.0.1:1".into(),
        }
    }
    #[test]
    fn hosting_and_scoped_demand_are_independent_reasons_to_keep_team_reach() {
        let mut registry = Registry::default();
        let scope = scope(0);
        let demand = registry.acquire(&scope).unwrap();
        assert!(registry.hosting(&scope, true));
        registry.release(&scope, &demand);
        assert!(registry.active(&scope));
        let demand = registry.acquire(&scope).unwrap();
        assert!(registry.hosting(&scope, false));
        assert!(registry.active(&scope));
        registry.release(&scope, &demand);
        assert!(!registry.active(&scope));
        assert!(registry.entries.is_empty());
    }
    #[test]
    fn restoration_can_retry_without_authorizing_a_socket() {
        let mut registry = Registry::default();
        let scope = scope(0);
        registry.restoring(&scope, true);
        assert!(registry.wanted(&scope));
        assert!(!registry.active(&scope));
        registry.restoring(&scope, false);
        assert!(!registry.wanted(&scope));
        assert!(registry.entries.is_empty());
    }
    #[test]
    fn a_late_drop_cannot_release_a_replacement_after_pause_or_account_change() {
        let mut registry = Registry::default();
        let scope = scope(0);
        let old = registry.acquire(&scope).unwrap();
        registry.entries.clear();
        let current = registry.acquire(&scope).unwrap();
        registry.release(&scope, &old);
        assert!(registry.active(&scope));
        registry.release(&scope, &current);
        assert!(!registry.active(&scope));
    }
    #[test]
    fn availability_is_exactly_bound_and_resource_counts_are_bounded() {
        let mut registry = Registry::default();
        let first = scope(0);
        registry.hosting(&first, true);
        for changed in [
            scope(1),
            Scope {
                key: [2; 32],
                ..first.clone()
            },
            Scope {
                endpoint: "ws://127.0.0.1:2".into(),
                ..first.clone()
            },
        ] {
            assert!(!registry.active(&changed));
        }
        for n in 1..MAX_SCOPES {
            assert!(registry.hosting(&scope(n), true));
        }
        assert!(!registry.hosting(&scope(MAX_SCOPES), true));
        let mut demands = Vec::new();
        for _ in 0..MAX_DEMANDS {
            demands.push(registry.acquire(&first).unwrap());
        }
        assert!(registry.acquire(&first).is_none());
        for demand in demands {
            registry.release(&first, &demand);
        }
        registry.hosting(&first, false);
        assert!(registry.hosting(&scope(MAX_SCOPES), true));
    }
}
