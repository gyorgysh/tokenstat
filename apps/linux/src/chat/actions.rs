// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The row's copying/error state has a mounted-view lifetime, independently
//! of an already dispatched host copy and the window's current destination.

use super::directory::Owner;
use crate::work::Scope;
use std::collections::{HashMap, HashSet};
use unicode_normalization::UnicodeNormalization;

/// One source ForEach row under its account, machine and project.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Key {
    scope: Scope,
    host: String,
    folder: String,
    id: String,
}
impl Key {
    /// Swift row identity uses canonical String equality, not display labels.
    pub fn new(owner: &Owner, folder: &str, id: &str) -> Self {
        Self {
            scope: owner.scope.clone(),
            host: owner.local_host_identity.nfc().collect(),
            folder: folder.nfc().collect(),
            id: id.nfc().collect(),
        }
    }
}
/// A later mount/copy of the same ID cannot be completed by an older task.
#[derive(Clone, Debug)]
pub struct Ticket {
    pub key: Key,
    sequence: u64,
}
#[derive(Default)]
struct State {
    copying: Option<u64>,
    error: Option<(u64, String)>,
}
/// Native sheets serialize presentation; errors remain attached to their rows.
#[derive(Default)]
pub struct Model {
    next: u64,
    rows: HashMap<Key, State>,
}
impl Model {
    /// The task starts once, even if a menu built before it is activated again.
    pub fn begin(&mut self, key: Key) -> Option<Ticket> {
        let row = self.rows.entry(key.clone()).or_default();
        if row.copying.is_some() {
            return None;
        }
        self.next = self.next.wrapping_add(1);
        row.copying = Some(self.next);
        Some(Ticket {
            key,
            sequence: self.next,
        })
    }
    /// Completion changes only the still-mounted original row's state.
    pub fn finish(&mut self, ticket: &Ticket, result: Result<(), String>) -> bool {
        let Some(row) = self
            .rows
            .get_mut(&ticket.key)
            .filter(|row| row.copying == Some(ticket.sequence))
        else {
            return false;
        };
        row.copying = None;
        if let Err(error) = result {
            self.next = self.next.wrapping_add(1);
            row.error = Some((self.next, error));
        }
        true
    }
    /// Menu and Shift controls ask this same fact without any transport work.
    pub fn copying(&self, key: &Key) -> bool {
        self.rows.get(key).is_some_and(|s| s.copying.is_some())
    }
    /// A presented error also disables the row's information control in SwiftUI.
    pub fn error(&self, key: &Key) -> Option<&str> {
        self.rows
            .get(key)
            .and_then(|s| s.error.as_ref().map(|(_, e)| e.as_str()))
    }
    /// Keep queued errors until their own OK response or source row disappearance.
    pub fn next_error(&self) -> Option<(Key, String)> {
        self.rows
            .iter()
            .filter_map(|(key, state)| state.error.as_ref().map(|(order, e)| (*order, key, e)))
            .min_by_key(|(order, _, _)| *order)
            .map(|(_, key, error)| (key.clone(), error.clone()))
    }
    /// OK clears this row's error, never another row's pending alert.
    pub fn dismiss_error(&mut self, key: &Key) {
        if let Some(row) = self.rows.get_mut(key) {
            row.error = None;
        }
    }
    /// Scrolling/collapsing/navigation retires state but never cancels host IO.
    pub fn retain(&mut self, keys: &HashSet<Key>) {
        self.rows.retain(|key, _| keys.contains(key));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn owner(account: &str, host: &str) -> Owner {
        Owner {
            scope: Scope::local(account),
            generation: 1,
            local_host_identity: host.into(),
        }
    }
    #[test]
    fn late_completion_cannot_modify_a_recreated_row_or_cancel_its_new_copy() {
        let key = Key::new(&owner("account", "host"), "folder", "chat");
        let mut model = Model::default();
        let old = model.begin(key.clone()).unwrap();
        assert!(model.begin(key.clone()).is_none());
        model.retain(&HashSet::new());
        let new = model.begin(key.clone()).unwrap();
        assert!(!model.finish(&old, Err("late failure".into())));
        assert!(model.copying(&key));
        assert!(model.error(&key).is_none());
        assert!(model.finish(&new, Err("new failure".into())));
        assert!(!model.copying(&key));
        assert_eq!(model.error(&key), Some("new failure"));
        assert!(!model.finish(&new, Ok(())));
        assert_eq!(
            model.next_error(),
            Some((key.clone(), "new failure".into()))
        );
        model.dismiss_error(&key);
        assert!(model.next_error().is_none());
    }
    #[test]
    fn canonical_row_identity_is_independent_of_other_accounts_hosts_and_pending_errors() {
        let a = Key::new(&owner("café", "host"), "folder", "café");
        let canonical = Key::new(&owner("cafe\u{301}", "host"), "folder", "cafe\u{301}");
        let b = Key::new(&owner("other", "host"), "folder", "café");
        let c = Key::new(&owner("café", "other-host"), "folder", "café");
        let mut model = Model::default();
        let first = model.begin(a.clone()).unwrap();
        assert!(model.begin(canonical).is_none());
        let second = model.begin(b.clone()).unwrap();
        let third = model.begin(c.clone()).unwrap();
        model.finish(&first, Err("a".into()));
        model.finish(&second, Err("b".into()));
        model.finish(&third, Err("c".into()));
        assert_eq!(model.next_error(), Some((a.clone(), "a".into())));
        model.dismiss_error(&a);
        assert_eq!(model.next_error(), Some((b.clone(), "b".into())));
        model.retain(&HashSet::from([c.clone()]));
        assert_eq!(model.next_error(), Some((c, "c".into())));
    }
}
