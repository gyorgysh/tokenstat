// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Typed adapter for ChatReadFlights: share simultaneous reads, invalidate
//! by exact account/helper and peer, and retry both obsolete result branches.
//! Unmounted chat read methods must join this boundary when ported.

use super::directory::Owner;
use super::query::Query;
use crate::work::{ScopeKind, destination};
use std::collections::HashMap;
use unicode_normalization::UnicodeNormalization;

/// The original bridge only shares these read methods; receipts are not reads.
pub const READ_METHODS: &[&str] = &[
    "chat.list",
    "chat.recent",
    "chat.events",
    "chat.eventPage",
    "chat.approvals",
    "chat.instructions",
    "chat.inspection",
    "chat.personas",
];
/// Invalidate before dispatch and after either result branch of these mutations.
pub const MUTATION_METHODS: &[&str] = &[
    "chat.create",
    "chat.fork",
    "chat.update",
    "chat.remove",
    "chat.removeAll",
    "chat.send",
    "chat.compact",
    "chat.steerSend",
    "chat.stop",
    "chat.recover",
    "chat.routing",
    "chat.routeAction",
    "chat.answerQuestion",
    "chat.steer",
    "chat.steerClear",
    "chat.steerDeliver",
    "chat.resolveApproval",
    "chat.personaSave",
    "chat.personaDefault",
    "chat.personaRemove",
];

// Swift encodes its owner to Data: canonical-equivalent but differently spelled
// scope strings remain distinct bytes. Peer is a Swift String and uses NFC Eq.
#[derive(Clone, PartialEq, Eq, Hash)]
struct Domain {
    kind: ScopeKind,
    origin: String,
    identity: String,
    generation: u64,
    peer: Option<String>,
}
impl Domain {
    fn new(owner: &Owner, peer: Option<&str>) -> Self {
        Self {
            kind: owner.scope.kind,
            origin: owner.scope.origin.clone(),
            identity: owner.scope.identity.clone(),
            generation: owner.generation,
            peer: peer.map(|s| s.nfc().collect()),
        }
    }
}
#[derive(Clone, PartialEq, Eq, Hash)]
struct Request {
    domain: Domain,
    query: Query,
}
impl Request {
    fn new(owner: &Owner, folder: &str, query: Query) -> Self {
        let route = destination::route(folder, None);
        Self {
            domain: Domain::new(owner, route.peer.as_deref()),
            query,
        }
    }
}
/// Producer identity outlives each individual window's waiter.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Flight(pub u64);
struct Entry<W> {
    owner: Owner,
    folder: String,
    request: Request,
    revision: u64,
    waiters: Vec<W>,
}
/// Only a newly allocated retry owns dispatch; joins need no additional IO.
pub struct Restart {
    pub flight: Flight,
    pub owner: Owner,
    pub folder: String,
    pub query: Query,
}
/// Obsolete values/errors are never delivered as a transport failure.
pub struct Completion<W> {
    pub deliver: Vec<W>,
    pub restart: Vec<Restart>,
}
/// App-owned read transport; values and per-window cache stay elsewhere.
pub struct Flights<W> {
    next: u64,
    entries: HashMap<Flight, Entry<W>>,
    slots: HashMap<Request, Flight>,
    revisions: HashMap<Domain, u64>,
}
impl<W> Default for Flights<W> {
    fn default() -> Self {
        Self {
            next: 0,
            entries: HashMap::new(),
            slots: HashMap::new(),
            revisions: HashMap::new(),
        }
    }
}
impl<W> Flights<W> {
    /// Convenience for the directory's fixed method/result type/patience.
    /// Keys use raw parameters and normalized peer, as the source.
    pub fn join(&mut self, owner: &Owner, folder: &str, waiter: W) -> (Flight, bool) {
        self.join_query(owner, folder, Query::directory(folder), waiter)
    }
    pub fn join_query(
        &mut self,
        owner: &Owner,
        folder: &str,
        query: Query,
        waiter: W,
    ) -> (Flight, bool) {
        let request = Request::new(owner, folder, query);
        if let Some(flight) = self.slots.get(&request).copied()
            && let Some(entry) = self.entries.get_mut(&flight)
        {
            entry.waiters.push(waiter);
            return (flight, false);
        }
        self.next = self.next.wrapping_add(1);
        let flight = Flight(self.next);
        let revision = self.revisions.get(&request.domain).copied().unwrap_or(0);
        self.slots.insert(request.clone(), flight);
        self.entries.insert(
            flight,
            Entry {
                owner: owner.clone(),
                folder: folder.into(),
                request,
                revision,
                waiters: vec![waiter],
            },
        );
        (flight, true)
    }
    /// Remove sharing slots but never cancel already dispatched producers.
    pub fn invalidate(&mut self, owner: &Owner, peer: Option<&str>) {
        let domain = Domain::new(owner, peer);
        let revision = self.revisions.entry(domain.clone()).or_default();
        *revision = revision.wrapping_add(1);
        self.slots.retain(|request, _| request.domain != domain);
    }
    /// Both result branches obey revisions. Old teardown cannot erase a newer slot.
    pub fn complete(&mut self, flight: Flight) -> Completion<W> {
        let Some(entry) = self.entries.remove(&flight) else {
            return Completion {
                deliver: vec![],
                restart: vec![],
            };
        };
        if self.slots.get(&entry.request) == Some(&flight) {
            self.slots.remove(&entry.request);
        }
        if self
            .revisions
            .get(&entry.request.domain)
            .copied()
            .unwrap_or(0)
            == entry.revision
        {
            return Completion {
                deliver: entry.waiters,
                restart: vec![],
            };
        }
        let mut restart = Vec::new();
        for waiter in entry.waiters {
            let query = entry.request.query.clone();
            let (flight, start) =
                self.join_query(&entry.owner, &entry.folder, query.clone(), waiter);
            if start {
                restart.push(Restart {
                    flight,
                    owner: entry.owner.clone(),
                    folder: entry.folder.clone(),
                    query,
                });
            }
        }
        Completion {
            deliver: vec![],
            restart,
        }
    }
    /// Cancel the waiter before completion/retry, without canceling its producer.
    /// Extract from only this producer, so retirement can finish at its own
    /// response boundary rather than an unrelated read's completion.
    pub fn take_waiters(&mut self, flight: Flight, mut take: impl FnMut(&W) -> bool) -> Vec<W> {
        self.entries
            .get_mut(&flight)
            .map_or_else(Vec::new, |entry| {
                entry
                    .waiters
                    .extract_if(.., |waiter| take(waiter))
                    .collect()
            })
    }
    /// Remove callback-only waiters without canceling their producers.
    pub fn retain_waiters(&mut self, mut keep: impl FnMut(&W) -> bool) {
        for entry in self.entries.values_mut() {
            entry.waiters.retain(|waiter| keep(waiter));
        }
    }
}
