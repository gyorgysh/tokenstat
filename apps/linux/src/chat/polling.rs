// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Retained reader tasks, following ChatPolling.swift. All ownership is local
//! to the UI executor. Cancelling a waiter never cancels a shared producer.

pub(crate) mod shared;
#[cfg(test)]
mod tests;
mod watcher;
pub use shared::{Cancellation, Joined};
pub use watcher::{Watch, WatchCancellation, Watcher};

use shared::Value;
use std::{
    cell::{Cell, RefCell},
    future::Future,
    pin::Pin,
    rc::{Rc, Weak},
    time::Duration,
};

pub type LocalFuture<T> = Pin<Box<dyn Future<Output = T>>>;
type Spawn = Rc<dyn Fn(LocalFuture<()>)>;
type Sleep = Rc<dyn Fn(Duration) -> LocalFuture<()>>;

/// Scheduling is explicit and injectable; constructors start no timer or IO.
#[derive(Clone)]
pub struct Runtime {
    spawn: Spawn,
    sleep: Sleep,
}
impl Runtime {
    pub fn new(
        spawn: impl Fn(LocalFuture<()>) + 'static,
        sleep: impl Fn(Duration) -> LocalFuture<()> + 'static,
    ) -> Self {
        Self {
            spawn: Rc::new(spawn),
            sleep: Rc::new(sleep),
        }
    }
    #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
    pub fn gpui(app: &gpui::App) -> Self {
        let foreground = app.foreground_executor().clone();
        let background = app.background_executor().clone();
        Self::new(
            move |future| foreground.spawn(future).detach(),
            move |duration| {
                let timer = background.timer(duration);
                Box::pin(timer)
            },
        )
    }
    fn spawn(&self, future: impl Future<Output = ()> + 'static) {
        (self.spawn)(Box::pin(future));
    }
}

struct Flight<O, T: Clone> {
    owner: O,
    revision: Cell<u64>,
    cancel: Cancellation,
    result: Value<T>,
}
struct Slot<O, T: Clone>(Option<Rc<Flight<O, T>>>);
type State<O, T> = Rc<RefCell<Slot<O, T>>>;
fn current<O, T: Clone>(state: &Weak<RefCell<Slot<O, T>>>, flight: &Rc<Flight<O, T>>) -> bool {
    state.upgrade().is_some_and(|state| {
        state
            .borrow()
            .0
            .as_ref()
            .is_some_and(|value| Rc::ptr_eq(value, flight))
    })
}
fn clear<O, T: Clone>(state: &Weak<RefCell<Slot<O, T>>>, flight: &Rc<Flight<O, T>>) {
    if current(state, flight)
        && let Some(state) = state.upgrade()
    {
        state.borrow_mut().0 = None;
    }
}
fn cancel<O, T: Clone>(state: &State<O, T>) {
    let previous = state.borrow_mut().0.take();
    if let Some(previous) = previous {
        previous.cancel.cancel();
    }
}

#[derive(Clone)]
pub struct Opening<O: Clone + Eq> {
    runtime: Runtime,
    state: State<O, bool>,
}
impl<O: Clone + Eq + 'static> Opening<O> {
    pub fn new(runtime: Runtime) -> Self {
        Self {
            runtime,
            state: Rc::new(RefCell::new(Slot(None))),
        }
    }
    /// Like the original async wrapper, no work starts until this is polled.
    /// Caller cancellation at entry is independent of the producer's token.
    pub async fn run(
        &self,
        owner: O,
        caller_cancelled: bool,
        operation: impl FnOnce(Cancellation) -> LocalFuture<bool> + 'static,
    ) -> bool {
        if caller_cancelled {
            return false;
        }
        let existing = self
            .state
            .borrow()
            .0
            .as_ref()
            .filter(|flight| flight.owner == owner)
            .cloned();
        if let Some(existing) = existing {
            return existing.result.join().await;
        }
        self.cancel();
        let made = Rc::new(Flight {
            owner,
            revision: Cell::new(0),
            cancel: Cancellation::default(),
            result: Value::new(),
        });
        self.state.borrow_mut().0 = Some(made.clone());
        let joined = made.result.join();
        let state = Rc::downgrade(&self.state);
        self.runtime.spawn(async move {
            let result = operation(made.cancel.clone()).await;
            clear(&state, &made);
            made.result.resolve(result);
        });
        joined.await
    }
    /// Cooperative producer cancellation: its own async cleanup still runs.
    pub fn cancel(&self) {
        cancel(&self.state);
    }
}

#[derive(Clone)]
pub struct Permit {
    allows: Rc<dyn Fn() -> bool>,
    cancellation: Cancellation,
}
impl Permit {
    pub fn allows(&self) -> bool {
        (self.allows)()
    }
    /// A refresh retires publication without cancelling the awaiting RPC.
    /// Transport uses this token, while publication uses allows().
    pub fn cancellation(&self) -> Cancellation {
        self.cancellation.clone()
    }
}
#[derive(Clone)]
pub struct Lane<O: Clone + Eq> {
    runtime: Runtime,
    state: State<O, ()>,
}
impl<O: Clone + Eq + 'static> Lane<O> {
    pub fn new(runtime: Runtime) -> Self {
        Self {
            runtime,
            state: Rc::new(RefCell::new(Slot(None))),
        }
    }
    /// A same-owner refresh keeps the first operation and retires only its
    /// current pass. No parallel read is started, even during a refresh burst.
    pub fn start(
        &self,
        owner: O,
        refresh: bool,
        caller_cancelled: bool,
        operation: impl Fn(Permit) -> LocalFuture<()> + 'static,
    ) -> Option<Joined<()>> {
        if caller_cancelled {
            return None;
        }
        if let Some(flight) = self
            .state
            .borrow()
            .0
            .as_ref()
            .filter(|flight| flight.owner == owner)
        {
            if refresh {
                flight.revision.set(flight.revision.get().wrapping_add(1));
            }
            return Some(flight.result.join());
        }
        self.cancel(None);
        let made = Rc::new(Flight {
            owner,
            revision: Cell::new(0),
            cancel: Cancellation::default(),
            result: Value::new(),
        });
        self.state.borrow_mut().0 = Some(made.clone());
        let joined = made.result.join();
        let state = Rc::downgrade(&self.state);
        self.runtime.spawn(async move {
            // The original weak-self Task promotes self once at entry and
            // holds that lane through its suspended operation and cleanup.
            let Some(_held) = state.upgrade() else {
                made.result.resolve(());
                return;
            };
            while !made.cancel.is_cancelled() && current(&state, &made) {
                // Capture at the actual start, not when start() enqueues it.
                let revision = made.revision.get();
                let weak = Rc::downgrade(&made);
                let state = state.clone();
                let permits = Permit {
                    cancellation: made.cancel.clone(),
                    allows: Rc::new(move || {
                        weak.upgrade().is_some_and(|flight| {
                            !flight.cancel.is_cancelled()
                                && current(&state, &flight)
                                && flight.revision.get() == revision
                        })
                    }),
                };
                operation(permits).await;
                if made.revision.get() == revision {
                    break;
                }
            }
            clear(&state, &made);
            made.result.resolve(());
        });
        Some(joined)
    }
    pub fn cancel(&self, owner: Option<&O>) {
        if owner.is_none()
            || self
                .state
                .borrow()
                .0
                .as_ref()
                .is_some_and(|flight| Some(&flight.owner) == owner)
        {
            cancel(&self.state);
        }
    }
}

/// This is solely the original monotonic-clock policy, not a timer or IO owner.
pub struct Cadence {
    quiet_reads: usize,
    failures: usize,
    progress_at: Option<f64>,
    status_at: f64,
    approvals_at: f64,
}
impl Default for Cadence {
    fn default() -> Self {
        Self {
            quiet_reads: 0,
            failures: 0,
            progress_at: None,
            status_at: f64::NEG_INFINITY,
            approvals_at: f64::NEG_INFINITY,
        }
    }
}
impl Cadence {
    pub fn note(&mut self, success: bool, changed: bool, now: f64) {
        if !success {
            self.failures = (self.failures + 1).min(4);
            return;
        }
        self.failures = 0;
        if changed {
            self.quiet_reads = 0;
            self.progress_at = Some(now);
        } else {
            self.quiet_reads = (self.quiet_reads + 1).min(3);
        }
    }
    pub fn interval(&self, busy: bool, attachments: bool, now: f64) -> Duration {
        if self.failures > 0 {
            return Duration::from_millis([400, 800, 1600, 2000][self.failures - 1]);
        }
        let recent = self.progress_at.is_some_and(|last| now - last < 1.2);
        if !busy && !attachments && !recent {
            return Duration::from_secs(2);
        }
        Duration::from_millis([120, 180, 260, 400][self.quiet_reads])
    }
    pub fn claim_status(&mut self, now: f64, force: bool) -> bool {
        if force || now - self.status_at >= 1. {
            self.status_at = now;
            true
        } else {
            false
        }
    }
    pub fn claim_approvals(&mut self, now: f64, force: bool) -> bool {
        if force || now - self.approvals_at >= 1. {
            self.approvals_at = now;
            true
        } else {
            false
        }
    }
}
