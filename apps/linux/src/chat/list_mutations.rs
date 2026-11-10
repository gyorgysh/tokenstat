// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The source ChatListMutations boundary: pre-mutation reads cannot undo local
//! acknowledgments, while reads begun later remain authoritative host state.

use super::Conversation;
use std::collections::{HashMap, HashSet};
use unicode_normalization::UnicodeNormalization;

pub(super) fn key(value: &str) -> String {
    value.nfc().collect()
}
/// Capture both mutation revision and list request order for one project owner.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    owner: String,
    revision: u64,
    order: u64,
}
struct Change {
    revision: u64,
    item: Option<Conversation>,
}
/// This is per-window list state, separate from shared transport invalidation.
#[derive(Default)]
pub struct Model {
    revision: u64,
    changes: HashMap<String, HashMap<String, Change>>,
    read_order: u64,
    accepted: HashMap<String, u64>,
}
impl Model {
    /// Begin before dispatch so every completed edit has a precise boundary.
    pub fn begin_read(&mut self, owner: &str) -> Read {
        self.read_order = self.read_order.wrapping_add(1);
        Read {
            owner: key(owner),
            revision: self.revision,
            order: self.read_order,
        }
    }
    /// Capture a complete acknowledged record, including an inserted fork.
    pub fn replace(&mut self, item: Conversation, owner: &str) {
        self.revision = self.revision.wrapping_add(1);
        self.changes.entry(key(owner)).or_default().insert(
            key(&item.id),
            Change {
                revision: self.revision,
                item: Some(item),
            },
        );
    }
    /// Keep an acknowledged removal from returning through an earlier read.
    pub fn remove(&mut self, id: &str, owner: &str) {
        self.revision = self.revision.wrapping_add(1);
        self.changes.entry(key(owner)).or_default().insert(
            key(id),
            Change {
                revision: self.revision,
                item: None,
            },
        );
    }
    /// Preserve newer edits only for older reads; newer host reads supersede them.
    pub fn apply(
        &mut self,
        incoming: Vec<Conversation>,
        read: &Read,
        current: &[Conversation],
    ) -> Vec<Conversation> {
        if read.order < self.accepted.get(&read.owner).copied().unwrap_or(0) {
            return current.to_vec();
        }
        self.accepted.insert(read.owner.clone(), read.order);
        let Some(changes) = self.changes.get(&read.owner) else {
            return incoming;
        };
        let mut newer = changes
            .iter()
            .filter(|(_, change)| change.revision > read.revision)
            .collect::<Vec<_>>();
        if newer.is_empty() {
            return incoming;
        }
        let mut seen = HashSet::new();
        let mut rows = incoming
            .into_iter()
            .filter_map(|row| {
                let id = key(&row.id);
                if !seen.insert(id.clone()) {
                    return None;
                }
                match changes
                    .get(&id)
                    .filter(|change| change.revision > read.revision)
                {
                    Some(change) => change.item.clone(),
                    None => Some(row),
                }
            })
            .collect::<Vec<_>>();
        newer.sort_by_key(|(_, change)| change.revision);
        for (id, change) in newer {
            if !seen.contains(id)
                && let Some(item) = &change.item
            {
                rows.push(item.clone());
            }
        }
        rows
    }
    /// Scope changes retire overlays without reusing old accepted read orders.
    pub fn remove_all(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.changes.clear();
        self.accepted.clear();
    }
}
