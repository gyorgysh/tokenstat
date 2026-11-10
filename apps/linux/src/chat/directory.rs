// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Per-window metadata cache and mount/read ownership. Collapsing a project
//! retires its waiter, while another window may still own the shared producer.

use super::{Conversation, list_mutations, steer_overlay};
use crate::work::{Kind, Reference, Scope, destination, text};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use unicode_normalization::UnicodeNormalization;

/// The source retains small title directories for at most thirty projects.
pub const CACHE_CAP: usize = 30;

/// A helper lifetime can retire in-flight reads without changing account scope.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Owner {
    pub scope: Scope,
    pub generation: u64,
    pub local_host_identity: String,
}
/// The source distinguishes never-loaded from an authoritative empty directory.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Presentation {
    Loading,
    Failed,
    Empty,
    Content,
}
impl Presentation {
    pub fn resolve(content: bool, loaded: bool, loading: bool, error: bool) -> Self {
        if content {
            Self::Content
        } else if loading {
            Self::Loading
        } else if error {
            Self::Failed
        } else if loaded {
            Self::Empty
        } else {
            Self::Loading
        }
    }
}
/// A waiter captures account, folder and a monotonically increasing request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    pub owner: Owner,
    pub folder: String,
    sequence: u64,
    mutations: list_mutations::Read,
    steer: steer_overlay::Read,
}

/// Cache ownership belongs to one window, while transport may have other waiters.
#[derive(Default)]
pub struct Model {
    owner: Option<Owner>,
    rows: HashMap<String, Vec<Conversation>>,
    errors: HashMap<String, String>,
    mounted: HashSet<String>,
    pending: HashMap<String, Read>,
    next: u64,
    stamps: HashMap<String, i64>,
    mutations: list_mutations::Model,
    steer: steer_overlay::Model,
}
fn key(value: &str) -> String {
    value.nfc().collect()
}
impl Model {
    /// Mutation callbacks capture this owner rather than consulting selection.
    pub fn owner(&self) -> Option<&Owner> {
        self.owner.as_ref()
    }
    /// Same-scope verified cache survives helper replacement; all deliveries retire.
    pub fn set_owner(&mut self, owner: Option<Owner>) -> bool {
        if self.owner == owner {
            return false;
        }
        let scope_changed =
            self.owner.as_ref().map(|o| &o.scope) != owner.as_ref().map(|o| &o.scope);
        if scope_changed {
            self.rows.clear();
            self.errors.clear();
            self.stamps.clear();
            self.mutations.remove_all();
            self.steer.remove_all();
        }
        self.owner = owner;
        self.pending.clear();
        self.mounted.clear();
        scope_changed
    }
    /// Begin the source's on-mount warm read only for an empty raw cache.
    pub fn mount(&mut self, folder: &str) -> Option<Read> {
        if !self.mounted.insert(key(folder)) || !self.rows(folder).is_empty() {
            return None;
        }
        self.begin(folder)
    }
    /// Removing/collapsing a row cancels its waiter, not the shared IO producer.
    pub fn retain_mounts(&mut self, folders: &[String]) {
        let visible = folders.iter().map(|id| key(id)).collect::<HashSet<_>>();
        self.mounted.retain(|id| visible.contains(id));
        self.pending.retain(|id, _| visible.contains(id));
    }
    /// Explicit Retry joins an already-dispatched read instead of duplicating it.
    pub fn begin(&mut self, folder: &str) -> Option<Read> {
        let owner = self.owner.clone()?;
        let id = key(folder);
        if self.pending.contains_key(&id) {
            return None;
        }
        self.next = self.next.wrapping_add(1);
        let project = project_key(&owner, folder);
        let read = Read {
            owner,
            folder: folder.into(),
            sequence: self.next,
            mutations: self.mutations.begin_read(&project),
            steer: self.steer.begin_read(&project),
        };
        self.pending.insert(id, read.clone());
        Some(read)
    }
    /// Canceled/collapsed/retired waiters must not dispatch an invalidation retry.
    pub fn is_current(&self, read: &Read) -> bool {
        self.owner.as_ref() == Some(&read.owner)
            && self.pending.get(&key(&read.folder)) == Some(read)
    }
    /// Errors cannot erase a verified list or become a false empty result.
    pub fn finish(
        &mut self,
        read: &Read,
        result: Result<Vec<Conversation>, String>,
        now: i64,
    ) -> bool {
        let id = key(&read.folder);
        if self.owner.as_ref() != Some(&read.owner) || self.pending.get(&id) != Some(read) {
            return false;
        }
        self.pending.remove(&id);
        match result {
            Ok(rows) => {
                let mut seen = HashSet::new();
                let rows = rows
                    .into_iter()
                    .filter(|row| !row.id.is_empty() && seen.insert(key(&row.id)))
                    .collect();
                let current = self.rows(&read.folder).to_vec();
                let rows = self.mutations.apply(rows, &read.mutations, &current);
                let rows = self.steer.apply(rows, &read.steer, &current);
                self.rows.insert(id.clone(), rows);
                self.errors.remove(&id);
                self.trim_cache(&id);
                self.reconcile_stamps(now);
            }
            Err(error) if !self.rows.contains_key(&id) => {
                self.errors.insert(id.clone(), error);
                if self.errors.len() > CACHE_CAP
                    && let Some(drop) = self.errors.keys().find(|other| **other != id).cloned()
                {
                    self.errors.remove(&drop);
                }
            }
            Err(_) => {}
        }
        true
    }
    /// Only verified directory data is exposed; absence is separately presented.
    pub fn rows(&self, folder: &str) -> &[Conversation] {
        self.rows
            .get(&key(folder))
            .map(Vec::as_slice)
            .unwrap_or_default()
    }
    /// An initial scoped error may enable Retry without fabricating an empty list.
    pub fn error(&self, folder: &str) -> Option<&str> {
        self.errors.get(&key(folder)).map(String::as_str)
    }
    /// Warm reads do not set the active transcript's isLoading flag in SwiftUI.
    pub fn presentation(&self, folder: &str) -> Presentation {
        let id = key(folder);
        Presentation::resolve(
            !self.rows(folder).is_empty(),
            self.rows.contains_key(&id),
            false,
            self.errors.contains_key(&id),
        )
    }
    /// First-observed stamps are shared by every cached row naming the same turn.
    pub fn running_since(&self, id: &str) -> Option<i64> {
        self.stamps.get(&key(id)).copied()
    }
    fn reconcile_stamps(&mut self, now: i64) {
        let running = self
            .rows
            .values()
            .flatten()
            .filter(|row| row.running)
            .map(|row| key(&row.id))
            .collect::<HashSet<_>>();
        self.stamps.retain(|id, _| running.contains(id));
        for id in running {
            self.stamps.entry(id).or_insert(now);
        }
    }
    /// Fixtures share the same acceptance path without scheduling a host read.
    pub fn seed(&mut self, folder: &str, result: Result<Vec<Conversation>, String>, now: i64) {
        if let Some(read) = self.begin(folder) {
            self.finish(&read, result, now);
        }
    }
    /// Selection is compared with Swift String identity throughout the sidebar.
    pub fn contains(&self, folder: &str, id: &str) -> bool {
        self.rows(folder).iter().any(|row| text::equal(&row.id, id))
    }
    /// Metadata acknowledgments preserve the existing ephemeral pending note.
    pub fn publish(&mut self, owner: &Owner, folder: &str, record: Conversation, now: i64) -> bool {
        if self.owner.as_ref() != Some(owner) {
            return false;
        }
        self.mutations
            .replace(record.clone(), &project_key(owner, folder));
        let mut rows = self.rows(folder).to_vec();
        let index = rows.iter().position(|row| text::equal(&row.id, &record.id));
        let record = steer_overlay::Model::preserving_note(record, index.map(|i| &rows[i]));
        if let Some(index) = index {
            rows[index] = record;
        } else {
            rows.insert(0, record);
        }
        self.rows.insert(key(folder), rows);
        self.trim_cache(&key(folder));
        self.errors.remove(&key(folder));
        self.reconcile_stamps(now);
        true
    }
    fn trim_cache(&mut self, id: &str) {
        if self.rows.len() > CACHE_CAP
            && let Some(drop) = self.rows.keys().find(|other| other.as_str() != id).cloned()
        {
            self.rows.remove(&drop);
        }
    }
    /// Acknowledged deletion overlays every older captured list for this project.
    pub fn remove(&mut self, owner: &Owner, folder: &str, id: &str, now: i64) -> bool {
        if self.owner.as_ref() != Some(owner) {
            return false;
        }
        self.mutations.remove(id, &project_key(owner, folder));
        if let Some(rows) = self.rows.get_mut(&key(folder)) {
            rows.retain(|r| !text::equal(&r.id, id));
        }
        self.reconcile_stamps(now);
        true
    }
}
fn project_key(owner: &Owner, folder: &str) -> String {
    let route = destination::route(folder, None);
    Reference {
        scope: owner.scope.clone(),
        host_identity: route
            .peer
            .unwrap_or_else(|| owner.local_host_identity.clone()),
        workspace_id: route.workspace_id,
        kind: Kind::Workspace,
        item_id: None,
        anchor: None,
    }
    .folder_key()
}
