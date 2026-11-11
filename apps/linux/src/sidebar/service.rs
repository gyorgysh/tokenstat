// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! App-owned sidebar IO is independent of account epochs and window lifetime.
//! Optimistic intents survive a late read and a failed, unrelated key write.

use super::{Mutation, ProjectsDisplay, ProjectsSort, Snapshot, Store};
use crate::work::preferences::Preferences;
use std::collections::{BTreeMap, VecDeque};

/// A captured request can outlive its initiating window without using the host.
#[derive(Clone)]
pub struct Job {
    id: u64,
    mutation: Option<Mutation>,
    store: Store,
}
impl Job {
    /// Execute blocking preference IO away from the UI executor.
    pub fn execute(&self) -> Result<Snapshot, String> {
        match &self.mutation {
            Some(mutation) => self.store.mutate(mutation),
            None => self.store.read(),
        }
        .map_err(|e| format!("{e:#}"))
    }
}

/// UI-executor owner for a serialized device-local preference lane.
pub struct Service {
    store: Option<Store>,
    base: Option<Snapshot>,
    intents: BTreeMap<String, (u64, Mutation)>,
    errors: BTreeMap<String, String>,
    queue: VecDeque<Job>,
    active: Option<u64>,
    next: u64,
    closing: bool,
}
impl Service {
    /// None means an ephemeral fixture. It never creates a worker request.
    pub fn new(preferences: Option<Preferences>) -> Self {
        let fixture = preferences.is_none();
        let mut service = Self {
            store: preferences.map(|preferences| Store { preferences }),
            base: fixture.then(Snapshot::default),
            intents: BTreeMap::new(),
            errors: BTreeMap::new(),
            queue: VecDeque::new(),
            active: None,
            next: 0,
            closing: false,
        };
        service.refresh();
        service
    }
    /// Untouched rows wait for a successful read; pending user intents overlay it.
    pub fn reading(&self) -> Option<Snapshot> {
        let mut reading = self.base.clone()?;
        let mut intents = self.intents.values().collect::<Vec<_>>();
        intents.sort_by_key(|(id, _)| *id);
        for (_, mutation) in intents {
            reading.apply(mutation);
        }
        Some(reading)
    }
    /// Keep each failed key visible until a successful save of that key.
    pub fn error(&self) -> Option<String> {
        (!self.errors.is_empty())
            .then(|| self.errors.values().cloned().collect::<Vec<_>>().join("\n"))
    }
    /// Refresh storage without dropping or reordering captured writes.
    pub fn refresh(&mut self) {
        if self.closing || self.store.is_none() {
            return;
        }
        self.queue.retain(|job| job.mutation.is_some());
        self.enqueue(None);
    }
    /// Store the explicit choice so a delayed completion cannot invert it.
    pub fn remember_expansion(&mut self, key: String, expanded: bool) {
        self.mutate(Mutation::Expansion { key, expanded });
    }
    /// Preserve future values by applying the move to current worker storage.
    pub fn move_section(&mut self, section: String, before: String) {
        self.mutate(Mutation::Move { section, before });
    }
    pub fn set_projects_display(&mut self, display: ProjectsDisplay) {
        self.mutate(Mutation::Display(display));
    }
    pub fn set_projects_sort(&mut self, sort: ProjectsSort) {
        self.mutate(Mutation::Sort(sort));
    }
    pub fn set_chat_detail(&mut self, detail: crate::commands::ChatDetail) {
        self.mutate(Mutation::ChatDetail(detail));
    }
    fn mutate(&mut self, mutation: Mutation) {
        if self.closing || !mutation.valid() {
            return;
        }
        if self.store.is_none() {
            if let Some(base) = self.base.as_mut() {
                base.apply(&mutation);
            }
            return;
        }
        let id = self.enqueue(Some(mutation.clone()));
        self.intents.insert(mutation.property(), (id, mutation));
    }
    fn enqueue(&mut self, mutation: Option<Mutation>) -> u64 {
        self.next = self.next.wrapping_add(1);
        if let Some(store) = &self.store {
            self.queue.push_back(Job {
                id: self.next,
                mutation,
                store: store.clone(),
            });
        }
        self.next
    }
    /// Only one worker may own a request at a time, including initial reads.
    pub fn next_job(&mut self) -> Option<Job> {
        if self.active.is_some() {
            return None;
        }
        let job = self.queue.pop_front()?;
        self.active = Some(job.id);
        Some(job)
    }
    /// Only this service's active ticket can publish. A newer pending click on
    /// the same row always overlays the completing write.
    pub fn finish(&mut self, job: &Job, result: Result<Snapshot, String>) -> bool {
        if self.active != Some(job.id) {
            return false;
        }
        self.active = None;
        let property = job.mutation.as_ref().map(Mutation::property);
        match result {
            Ok(snapshot) => {
                self.base = Some(snapshot);
                self.errors.remove("read");
                if let Some(property) = property {
                    self.errors.remove(&property);
                    if self
                        .intents
                        .get(&property)
                        .is_some_and(|(id, _)| *id == job.id)
                    {
                        self.intents.remove(&property);
                    }
                }
            }
            Err(error) => {
                self.errors
                    .insert(property.unwrap_or_else(|| "read".into()), error);
            }
        }
        true
    }
    /// Ordinary quit drains existing writes while refusing later mutations.
    pub fn start_shutdown(&mut self) {
        self.closing = true;
        self.queue.retain(|job| job.mutation.is_some());
    }
    /// Quit must wait for both queued writes and an already active request.
    pub fn idle(&self) -> bool {
        self.active.is_none() && self.queue.is_empty()
    }
}

#[cfg(test)]
mod tests;
