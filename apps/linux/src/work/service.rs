// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One serialized metadata IO lane, independent of the window that requested it.
//! Jobs capture ownership; old completions cannot restore a retired account.

use super::{
    Reference, Scope,
    continuity::{Continuity, Date, Place},
    pins::{Pin, Pins},
    preferences::Preferences,
};
use crate::{account_state::LoginOwner, navigation::Route};
use std::collections::VecDeque;
#[cfg(test)]
mod tests;

/// Only local metadata is shared. Directory/chat/access facts remain view-owned.
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub scope: Scope,
    pub pins: Vec<Pin>,
    pub recent: Vec<Reference>,
}

#[derive(Clone)]
enum Operation {
    Bootstrap,
    Read,
    Unpin(Reference),
    Pin(Reference, String, String, Date),
    Relabel(Reference, String, String, Date),
    RelabelTitle(Reference, String, Date),
    Place(Option<Place>),
}

/// An owned worker request performs no UI or host operation.
#[derive(Clone)]
pub struct Job {
    id: u64,
    epoch: u64,
    scope: Option<Scope>,
    operation: Operation,
    preferences: Preferences,
}
/// Worker data is published only through its matching service ticket.
pub enum Output {
    Bootstrap {
        installation: String,
        place: Option<Place>,
        restores_location: bool,
    },
    Reading {
        snapshot: Option<Snapshot>,
        pin_accepted: Option<bool>,
    },
}
impl Job {
    /// Run on a worker. Mutations and their following read share one IO lane.
    pub fn execute(&self) -> Result<Output, String> {
        self.execute_inner().map_err(|e| format!("{e:#}"))
    }
    fn execute_inner(&self) -> anyhow::Result<Output> {
        let continuity = Continuity {
            preferences: self.preferences.clone(),
        };
        let pins = Pins {
            preferences: self.preferences.clone(),
        };
        let mut accepted = None;
        match &self.operation {
            Operation::Bootstrap => {
                return Ok(Output::Bootstrap {
                    installation: self.preferences.installation_id()?,
                    place: continuity.place()?,
                    restores_location: self.preferences.read(|m| {
                        m.get("navigation.reopenLastLocation")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false)
                    })?,
                });
            }
            Operation::Read => {}
            Operation::Unpin(reference) => pins.unpin(reference)?,
            Operation::Pin(reference, label, folder, at) => {
                accepted = Some(pins.pin(reference, label, folder, *at)?)
            }
            Operation::Relabel(reference, label, folder, at) => {
                pins.relabel_if_pinned(reference, label, folder, *at)?;
            }
            Operation::RelabelTitle(reference, label, at) => {
                pins.relabel_title_if_pinned(reference, label, *at)?;
            }
            Operation::Place(Some(place)) => continuity.remember_place(place)?,
            Operation::Place(None) => continuity.forget_place()?,
        }
        let snapshot = self
            .scope
            .as_ref()
            .map(|scope| {
                Ok::<_, anyhow::Error>(Snapshot {
                    scope: scope.clone(),
                    pins: pins.pins(Some(scope))?,
                    recent: continuity.recent(scope, 4)?,
                })
            })
            .transpose()?;
        Ok(Output::Reading {
            snapshot,
            pin_accepted: accepted,
        })
    }
}

/// Global service state is mutated only on the UI executor; blocking IO is
/// represented by owned jobs so it cannot hold a view borrow or lifetime.
pub struct Service {
    preferences: Preferences,
    enabled: bool,
    owner: LoginOwner,
    epoch: u64,
    next: u64,
    queue: VecDeque<Job>,
    active: Option<u64>,
    closing: bool,
    pub installation: Option<String>,
    pub local_host_identity: Option<String>,
    pub identity_loading: bool,
    pub identity_error: Option<String>,
    pub snapshot: Option<Snapshot>,
    pub error: Option<String>,
    pub launch_place: Option<Place>,
    pub restores_location: bool,
}
impl Service {
    /// Project shared metadata against this window's authoritative local
    /// directory. Unknown/unported peer/chat/cache feeds are never fetched here.
    pub fn home_reading(
        &self,
        folders: Option<&[crate::desktop_data::Repository]>,
        machines: &[crate::devices::Machine],
    ) -> Option<crate::home::work::HomeWork> {
        use crate::home::work::{Catalog, Folder, HomeWork};
        let snapshot = self.snapshot.as_ref()?;
        let identity = self.local_host_identity.as_ref()?;
        let folders = folders?;
        if self.scope().as_ref() != Some(&snapshot.scope) {
            return None;
        }
        Some(HomeWork {
            catalog: Catalog {
                scope: Some(snapshot.scope.clone()),
                local_host_identity: Some(identity.clone()),
                folders: folders
                    .iter()
                    .filter(|f| {
                        f.machine_id.is_none()
                            && super::destination::route(&f.id, None).peer.is_none()
                    })
                    .map(|f| Folder {
                        id: f.id.clone(),
                        name: f.name.clone(),
                        machine_label: f.machine_label.clone(),
                    })
                    .collect(),
                machines: machines.to_vec(),
                ..Catalog::default()
            },
            recent: snapshot.recent.clone(),
            pins: snapshot
                .pins
                .iter()
                .map(|p| crate::home::work::Pin {
                    reference: p.reference.clone(),
                    label: p.label.clone(),
                    folder_name: p.folder_name.clone(),
                })
                .collect(),
        })
    }
    /// A missing store disables IO entirely for synthetic component fixtures.
    pub fn new(preferences: Option<Preferences>) -> Self {
        let enabled = preferences.is_some();
        let mut service = Self {
            preferences: preferences.unwrap_or_default(),
            enabled,
            owner: LoginOwner::default(),
            epoch: 0,
            next: 0,
            queue: VecDeque::new(),
            active: None,
            closing: false,
            installation: None,
            local_host_identity: None,
            identity_loading: false,
            identity_error: None,
            snapshot: None,
            error: None,
            launch_place: None,
            restores_location: false,
        };
        if enabled {
            service.enqueue(Operation::Bootstrap);
        }
        service
    }
    /// Unknown account state remains unknown even after local UUID loading.
    pub fn scope(&self) -> Option<Scope> {
        self.installation
            .as_ref()
            .and_then(|id| self.owner.work_scope(id))
    }
    /// Retire deliveries immediately, while authorized writes already in the
    /// queue retain their captured scope and original ordering.
    pub fn set_owner(&mut self, owner: &LoginOwner) {
        if owner.generation() == self.owner.generation() {
            return;
        }
        let previous_scope = self.scope();
        self.owner = owner.clone();
        self.epoch = self.epoch.wrapping_add(1);
        if previous_scope != self.scope() {
            self.snapshot = None;
            self.error = None;
        }
        self.queue
            .retain(|job| !matches!(job.operation, Operation::Read));
        self.refresh();
    }
    /// Coalesce redundant reads, preserving every queued mutation.
    pub fn refresh(&mut self) {
        if !self.enabled || self.closing {
            return;
        }
        if self.installation.is_none() {
            if self.active.is_none()
                && !self
                    .queue
                    .iter()
                    .any(|j| matches!(j.operation, Operation::Bootstrap))
            {
                self.enqueue(Operation::Bootstrap);
            }
            return;
        }
        self.queue
            .retain(|j| !matches!(j.operation, Operation::Read));
        if self.scope().is_some() {
            self.enqueue(Operation::Read);
        }
    }
    /// A closed window cannot cancel another window's pending metadata write.
    pub fn unpin(&mut self, reference: Reference) {
        if self.enabled && !self.closing {
            self.enqueue(Operation::Unpin(reference));
        }
    }
    /// The worker returns the original capacity decision; SidebarPinAction
    /// deliberately ignores it and presents capacity in the next menu snapshot.
    pub fn pin(&mut self, reference: Reference, label: String, folder: String, at: Date) {
        if self.enabled && !self.closing {
            self.enqueue(Operation::Pin(reference, label, folder, at));
        }
    }
    /// The rename callback refreshes an existing pin only; it never inserts.
    pub fn relabel_if_pinned(
        &mut self,
        reference: Reference,
        label: String,
        folder: String,
        at: Date,
    ) {
        if self.enabled && !self.closing {
            self.enqueue(Operation::Relabel(reference, label, folder, at));
        }
    }
    /// Preserve the current folder label and never resurrect a removed chat pin.
    pub fn relabel_title_if_pinned(&mut self, reference: Reference, label: String, at: Date) {
        if self.enabled && !self.closing {
            self.enqueue(Operation::RelabelTitle(reference, label, at));
        }
    }
    /// Match RootView.rememberPlace. Unknown workspace ownership skips the
    /// write, while non-restorable routes explicitly clear the place record.
    pub fn remember_route(&mut self, route: &Route, at: Date) {
        if !self.enabled || self.closing {
            return;
        }
        let place = match route {
            Route::Global { section } => Some(Place::global(section.id(), at)),
            Route::Workspace { id, section } => {
                let Some(scope) = self.scope() else {
                    return;
                };
                let resolved = super::destination::route(id, None);
                let Some(host) = resolved.peer.or_else(|| self.local_host_identity.clone()) else {
                    return;
                };
                let reference = Reference {
                    scope,
                    host_identity: host,
                    workspace_id: resolved.workspace_id,
                    kind: super::Kind::Workspace,
                    item_id: None,
                    anchor: None,
                };
                let Some(place) = Place::workspace(reference, section.id().into(), at) else {
                    return;
                };
                Some(place)
            }
            Route::WorkspacesOverview | Route::Ssh { .. } | Route::SshTerminals { .. } => None,
        };
        self.enqueue(Operation::Place(place));
    }
    /// Source resolves the public key once, never from a hostname or address.
    pub fn begin_identity(&mut self) -> bool {
        if !self.enabled
            || self.closing
            || self.local_host_identity.is_some()
            || self.identity_loading
        {
            return false;
        }
        self.identity_loading = true;
        true
    }
    /// A verified key belongs to the local daemon, not to an account response.
    pub fn finish_identity(&mut self, result: Result<String, String>) {
        self.identity_loading = false;
        match result {
            Ok(key) if !key.is_empty() => {
                self.local_host_identity = Some(key);
                self.identity_error = None;
            }
            Ok(_) => {
                self.identity_error = Some("The host returned an empty public identity".into())
            }
            Err(error) => self.identity_error = Some(error),
        }
    }
    /// At most one job is handed to the worker, preserving click order.
    pub fn next_job(&mut self) -> Option<Job> {
        if self.active.is_some() {
            return None;
        }
        let job = self.queue.pop_front()?;
        self.active = Some(job.id);
        Some(job)
    }
    /// Ordinary app quit drains captured writes while discarding obsolete
    /// queued reads. Platform session termination is a separate native gate.
    pub fn start_shutdown(&mut self) {
        self.closing = true;
        self.queue
            .retain(|j| !matches!(j.operation, Operation::Read));
    }
    /// Quit waits for the active operation as well as the queued mutations.
    pub fn idle(&self) -> bool {
        self.active.is_none() && self.queue.is_empty()
    }
    /// Return a pin decision only for the still-current owner. Physical writes
    /// may finish after retirement, but their old data never publishes.
    pub fn finish(&mut self, job: &Job, result: Result<Output, String>) -> Option<bool> {
        if self.active != Some(job.id) {
            return None;
        }
        self.active = None;
        if matches!(job.operation, Operation::Bootstrap)
            && let Err(error) = &result
        {
            self.error = Some(error.clone());
            return None;
        }
        match result {
            Ok(Output::Bootstrap {
                installation,
                place,
                restores_location,
            }) if matches!(job.operation, Operation::Bootstrap) => {
                self.installation = Some(installation);
                self.launch_place = place;
                self.restores_location = restores_location;
                self.error = None;
                self.refresh();
                None
            }
            result if job.epoch == self.epoch && job.scope == self.scope() => match result {
                Ok(Output::Reading {
                    snapshot,
                    pin_accepted,
                }) => {
                    self.snapshot = snapshot;
                    self.error = None;
                    if self.installation.is_none() {
                        self.refresh();
                    }
                    pin_accepted
                }
                Err(error) => {
                    self.error = Some(error);
                    None
                }
                _ => None,
            },
            _ => None,
        }
    }
    fn enqueue(&mut self, operation: Operation) {
        self.next = self.next.wrapping_add(1);
        self.queue.push_back(Job {
            id: self.next,
            epoch: self.epoch,
            scope: self.scope(),
            operation,
            preferences: self.preferences.clone(),
        });
    }
}
