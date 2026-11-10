// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One app-owned boundary for mounted directory and timeline reads. Only
//! simultaneous identical requests share IO; each consumer retains its own
//! model/selection guards and can retire without cancelling the producer.

use super::{
    directory::Owner,
    flights::{Flight, Flights},
    query::{Query, Reply},
};
use crate::client::Client;
use gpui::{App, AsyncApp, EntityId, Global};
use std::{
    cell::Cell,
    collections::HashMap,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

pub type Result = std::result::Result<Reply, Arc<anyhow::Error>>;
type Current = Box<dyn Fn(&App) -> bool>;
type Finish = Box<dyn FnOnce(Result, &mut App)>;
type Retired = Box<dyn FnOnce(ReadError, &mut App)>;

/// Cancellation is not a host failure and must not trigger a page fallback.
#[derive(Clone, Debug)]
pub enum ReadError {
    Cancelled,
    /// A changed bridge owner is separate from caller Task cancellation.
    /// Same-scope helper adoption needs the original model's recovery policy.
    OwnerChanged,
    Failed(Arc<anyhow::Error>),
}
pub type Awaited = std::result::Result<Reply, ReadError>;

/// A lease identifies one exact waiter, including a predecessor on the same
/// retained entity. Releasing it cannot retire a successor or another window.
#[derive(Clone, Debug)]
pub struct Lease {
    id: u64,
    active: Rc<Cell<bool>>,
}

/// `current` follows the waiting operation's lifetime. Page-specific epoch and
/// cursor guards belong in Window::receive_shared_page/chunk: a still-owned
/// obsolete reply must reach its defer/progress cleanup even if it cannot
/// publish records. Retiring a consumer is the caller's cleanup boundary.
pub struct Consumer {
    entity: EntityId,
    current: Current,
    finish: Finish,
    retired: Option<Retired>,
}
impl Consumer {
    pub fn new(
        entity: EntityId,
        current: impl Fn(&App) -> bool + 'static,
        finish: impl FnOnce(Result, &mut App) + 'static,
    ) -> Self {
        Self {
            entity,
            current: Box::new(current),
            finish: Box::new(finish),
            retired: None,
        }
    }
}

struct Abandon(Lease);
impl Drop for Abandon {
    fn drop(&mut self) {
        self.0.active.set(false);
    }
}

/// Lazy awaited read, with the original ChatReadFlights cancellation boundary.
/// `current` follows the operation's lifetime/cancellation, not a poll revision
/// or page cursor. A cancelled waiter still awaits its OWN producer, then stops
/// before invalidation retry. Dropping this future retires only this waiter.
pub async fn read_async(
    request: Request,
    entity: EntityId,
    current: impl Fn(&App) -> bool + 'static,
    cx: &AsyncApp,
) -> Awaited {
    let value = super::polling::shared::Value::new();
    let pending = value.join();
    let answer = value.clone();
    let mut consumer = Consumer::new(entity, current, move |result, _| {
        answer.resolve(result.map_err(ReadError::Failed));
    });
    consumer.retired = Some(Box::new(move |reason, _| value.resolve(Err(reason))));
    let lease = match cx.update(|app| {
        if !(consumer.current)(app) {
            return Err(ReadError::Cancelled);
        }
        if request.epoch.load(Ordering::Acquire) != request.owner.generation {
            return Err(ReadError::OwnerChanged);
        }
        read(request, consumer, app).ok_or(ReadError::Cancelled)
    }) {
        Ok(Ok(lease)) => lease,
        Ok(Err(error)) => return Err(error),
        Err(_) => return Err(ReadError::Cancelled),
    };
    let _abandon = Abandon(lease);
    pending.await
}

/// The epoch is the existing shared host/account fence, checked on the worker
/// before protocol/feature IO and again before decoding and delivery.
pub struct Request {
    pub client: Client,
    pub owner: Owner,
    pub folder: String,
    pub query: Query,
    pub epoch: Arc<AtomicU64>,
}
struct Waiting {
    lease: Lease,
    epoch: Arc<AtomicU64>,
    generation: u64,
    consumer: Consumer,
}
impl Waiting {
    fn current(&self, app: &App) -> bool {
        self.retirement(app).is_none()
    }
    fn retirement(&self, app: &App) -> Option<ReadError> {
        if !self.lease.active.get() || !(self.consumer.current)(app) {
            Some(ReadError::Cancelled)
        } else if self.epoch.load(Ordering::Acquire) != self.generation {
            Some(ReadError::OwnerChanged)
        } else {
            None
        }
    }
}
#[derive(Default)]
struct Shared {
    flights: Flights<Waiting>,
    next: u64,
    leases: HashMap<u64, (EntityId, Rc<Cell<bool>>)>,
}
impl Global for Shared {}

/// Called only at a mounted consumer's read boundary. Constructing a reader or
/// initializing an offline fixture never connects a socket.
pub fn read(request: Request, consumer: Consumer, app: &mut App) -> Option<Lease> {
    if request.epoch.load(Ordering::Acquire) != request.owner.generation || !(consumer.current)(app)
    {
        return None;
    }
    if !app.has_global::<Shared>() {
        app.set_global(Shared::default());
    }
    let shared = app.global_mut::<Shared>();
    shared.next = shared.next.wrapping_add(1);
    let lease = Lease {
        id: shared.next,
        active: Rc::new(Cell::new(true)),
    };
    shared
        .leases
        .insert(lease.id, (consumer.entity, lease.active.clone()));
    let (flight, start) = shared.flights.join_query(
        &request.owner,
        &request.folder,
        request.query.clone(),
        Waiting {
            lease: lease.clone(),
            epoch: request.epoch.clone(),
            generation: request.owner.generation,
            consumer,
        },
    );
    if start {
        dispatch(request, flight, app);
    }
    Some(lease)
}

fn dispatch(request: Request, flight: Flight, app: &mut App) {
    let client = request.client.clone();
    let epoch = request.epoch.clone();
    let generation = request.owner.generation;
    let worker = app.background_executor().spawn(async move {
        client
            .chat_read_if_current(&request.folder, &request.query, || {
                epoch.load(Ordering::Acquire) == generation
            })
            .map_err(Arc::new)
    });
    app.spawn(async move |cx| {
        let result = worker.await;
        let _ = cx.update(|app| {
            let mut flights = std::mem::take(&mut app.global_mut::<Shared>().flights);
            flights.retain_waiters(|waiter| {
                let reason = waiter.retirement(app);
                let current = reason.is_none();
                if matches!(reason, Some(ReadError::Cancelled))
                    || !current && waiter.consumer.retired.is_none()
                {
                    waiter.lease.active.set(false);
                }
                current || waiter.consumer.retired.is_some()
            });
            let retired = flights.take_waiters(flight, |waiter| !waiter.current(app));
            let completion = flights.complete(flight);
            let shared = app.global_mut::<Shared>();
            shared.flights = flights;
            shared.leases.retain(|_, (_, active)| active.get());
            for waiter in retired {
                let reason = waiter.retirement(app).unwrap_or(ReadError::Cancelled);
                waiter.lease.active.set(false);
                app.global_mut::<Shared>().leases.remove(&waiter.lease.id);
                if let Some(retired) = waiter.consumer.retired {
                    retired(reason, app);
                }
            }
            for retry in completion.restart {
                dispatch(
                    Request {
                        client: request.client.clone(),
                        owner: retry.owner,
                        folder: retry.folder,
                        query: retry.query,
                        epoch: request.epoch.clone(),
                    },
                    retry.flight,
                    app,
                );
            }
            for waiter in completion.deliver {
                // An earlier consumer may have changed ownership, quit or
                // retired another consumer during this delivery batch.
                let reason = waiter.retirement(app);
                let current = reason.is_none();
                waiter.lease.active.set(false);
                app.global_mut::<Shared>().leases.remove(&waiter.lease.id);
                if current {
                    (waiter.consumer.finish)(result.clone(), app);
                } else if let Some(retired) = waiter.consumer.retired {
                    retired(reason.unwrap_or(ReadError::Cancelled), app);
                }
            }
        });
    })
    .detach();
}

pub fn cancel(lease: Lease, app: &mut App) {
    lease.active.set(false);
    if app.has_global::<Shared>() {
        let shared = app.global_mut::<Shared>();
        shared.leases.remove(&lease.id);
        shared.flights.retain_waiters(|waiter| {
            waiter.lease.id != lease.id || waiter.consumer.retired.is_some()
        });
    }
}
pub fn release_entity(entity: EntityId, app: &mut App) {
    if app.has_global::<Shared>() {
        let shared = app.global_mut::<Shared>();
        shared.leases.retain(|_, (owner, active)| {
            if *owner == entity {
                active.set(false);
                false
            } else {
                true
            }
        });
        shared.flights.retain_waiters(|waiter| {
            waiter.consumer.entity != entity || waiter.consumer.retired.is_some()
        });
    }
}
/// All mounted read types use this same domain before/after a mutation.
pub fn invalidate(owner: &Owner, folder: &str, app: &mut App) {
    if app.has_global::<Shared>() {
        let route = crate::work::destination::route(folder, None);
        app.global_mut::<Shared>()
            .flights
            .invalidate(owner, route.peer.as_deref());
    }
}
