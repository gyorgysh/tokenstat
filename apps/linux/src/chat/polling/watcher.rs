// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{Cancellation, Joined, LocalFuture, Runtime, shared::Value};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    future::Future,
    pin::Pin,
    rc::Rc,
    task::{Context, Poll},
    time::Duration,
};

struct Loop<O> {
    owner: O,
    cancel: Cancellation,
    stop: Rc<dyn Fn()>,
}
struct State<O> {
    active: Option<Rc<Loop<O>>>,
    waiters: HashMap<u64, Value<()>>,
    next: u64,
}
impl<O> Drop for State<O> {
    fn drop(&mut self) {
        if let Some(active) = self.active.take() {
            active.cancel.cancel();
            (active.stop)();
        }
        for (_, waiter) in self.waiters.drain() {
            waiter.resolve(());
        }
    }
}
fn cancel<O>(state: &Rc<RefCell<State<O>>>) {
    let (previous, waiters) = {
        let mut state = state.borrow_mut();
        (state.active.take(), std::mem::take(&mut state.waiters))
    };
    if let Some(previous) = previous {
        previous.cancel.cancel();
        (previous.stop)();
    }
    for (_, waiter) in waiters {
        waiter.resolve(());
    }
}
fn release<O>(state: &Rc<RefCell<State<O>>>, lease: u64) {
    let waiter = state.borrow_mut().waiters.remove(&lease);
    if let Some(waiter) = waiter {
        waiter.resolve(());
        if state.borrow().waiters.is_empty() {
            cancel(state);
        }
    }
}

#[derive(Clone)]
pub struct Watcher<O: Clone + Eq> {
    runtime: Runtime,
    state: Rc<RefCell<State<O>>>,
}
impl<O: Clone + Eq + 'static> Watcher<O> {
    pub fn new(runtime: Runtime) -> Self {
        Self {
            runtime,
            state: Rc::new(RefCell::new(State {
                active: None,
                waiters: HashMap::new(),
                next: 0,
            })),
        }
    }
    /// Enrollment is lazy. Dropping before first poll starts no loop.
    pub fn watch(
        &self,
        owner: O,
        cycle: impl Fn() -> LocalFuture<()> + 'static,
        interval: impl Fn() -> Duration + 'static,
        stop: impl Fn() + 'static,
    ) -> Watch {
        let watcher = self.clone();
        let weak = Rc::downgrade(&self.state);
        let runtime = self.runtime.clone();
        let cancellation = WatchCancellation(Rc::new(Lease {
            cancelled: Cell::new(false),
            scheduled: Cell::new(false),
            lease: Cell::new(None),
            release: Box::new(move |lease| {
                // Preserve the original awaiting method's self lifetime until
                // the queued MainActor-equivalent release has actually run.
                let state = weak.upgrade();
                runtime.spawn(async move {
                    if let Some(state) = state {
                        release(&state, lease);
                    }
                });
            }),
        }));
        Watch {
            start: Some(Box::new(move || {
                if watcher
                    .state
                    .borrow()
                    .active
                    .as_ref()
                    .is_some_and(|active| active.owner != owner)
                {
                    watcher.cancel();
                }
                let value = Value::new();
                let result = value.join();
                let (lease, start) = {
                    let mut state = watcher.state.borrow_mut();
                    state.next = state.next.wrapping_add(1);
                    let lease = state.next;
                    state.waiters.insert(lease, value);
                    (lease, state.active.is_none())
                };
                if start {
                    let made = Rc::new(Loop {
                        owner,
                        cancel: Cancellation::default(),
                        stop: Rc::new(stop),
                    });
                    watcher.state.borrow_mut().active = Some(made.clone());
                    let weak = Rc::downgrade(&watcher.state);
                    let sleep = watcher.runtime.sleep.clone();
                    watcher.runtime.spawn(async move {
                        while !made.cancel.is_cancelled() {
                            let current = weak.upgrade().is_some_and(|state| {
                                state
                                    .borrow()
                                    .active
                                    .as_ref()
                                    .is_some_and(|active| Rc::ptr_eq(active, &made))
                            });
                            if !current {
                                return;
                            }
                            cycle().await;
                            let mut timer = sleep(interval());
                            let mut cancelled = Box::pin(made.cancel.cancelled());
                            let elapsed = std::future::poll_fn(|cx| {
                                if cancelled.as_mut().poll(cx).is_ready() {
                                    Poll::Ready(false)
                                } else if timer.as_mut().poll(cx).is_ready() {
                                    Poll::Ready(true)
                                } else {
                                    Poll::Pending
                                }
                            })
                            .await;
                            if !elapsed {
                                break;
                            }
                        }
                        if let Some(state) = weak.upgrade() {
                            let current = state
                                .borrow()
                                .active
                                .as_ref()
                                .is_some_and(|active| Rc::ptr_eq(active, &made));
                            if current {
                                cancel(&state);
                            }
                        }
                    });
                }
                (lease, result)
            })),
            result: None,
            cancellation,
            _owner: self.state.clone(),
        }
    }
    pub fn cancel(&self) {
        cancel(&self.state);
    }
}

struct Lease {
    cancelled: Cell<bool>,
    scheduled: Cell<bool>,
    lease: Cell<Option<u64>>,
    release: Box<dyn Fn(u64)>,
}
#[derive(Clone)]
pub struct WatchCancellation(Rc<Lease>);
impl WatchCancellation {
    /// Like the original onCancel MainActor task, release is queued and exact.
    pub fn cancel(&self) {
        self.0.cancelled.set(true);
        if let Some(lease) = self.0.lease.get()
            && !self.0.scheduled.replace(true)
        {
            (self.0.release)(lease);
        }
    }
}
type Enrollment = Box<dyn FnOnce() -> (u64, Joined<()>)>;
pub struct Watch {
    start: Option<Enrollment>,
    result: Option<Joined<()>>,
    cancellation: WatchCancellation,
    _owner: Rc<dyn std::any::Any>,
}
impl Watch {
    pub fn cancellation(&self) -> WatchCancellation {
        self.cancellation.clone()
    }
}
impl Future for Watch {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if let Some(start) = self.start.take() {
            if self.cancellation.0.cancelled.get() {
                return Poll::Ready(());
            }
            let (lease, result) = start();
            self.cancellation.0.lease.set(Some(lease));
            self.result = Some(result);
        }
        Pin::new(self.result.as_mut().expect("watch polled after completion")).poll(cx)
    }
}
impl Drop for Watch {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}
