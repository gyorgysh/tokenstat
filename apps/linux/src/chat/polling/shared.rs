// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    future::Future,
    pin::Pin,
    rc::Rc,
    task::{Context, Poll, Waker},
};

struct State<T> {
    result: Option<T>,
    next: u64,
    waiters: HashMap<u64, Waker>,
}
#[derive(Clone)]
pub(crate) struct Value<T: Clone>(Rc<RefCell<State<T>>>);
impl<T: Clone> Value<T> {
    pub(crate) fn new() -> Self {
        Self(Rc::new(RefCell::new(State {
            result: None,
            next: 0,
            waiters: HashMap::new(),
        })))
    }
    pub(crate) fn join(&self) -> Joined<T> {
        let mut state = self.0.borrow_mut();
        state.next = state.next.wrapping_add(1);
        Joined {
            value: self.clone(),
            lease: state.next,
        }
    }
    pub(crate) fn resolve(&self, result: T) {
        let waiters = {
            let mut state = self.0.borrow_mut();
            if state.result.is_some() {
                return;
            }
            state.result = Some(result);
            std::mem::take(&mut state.waiters)
        };
        for (_, waiter) in waiters {
            waiter.wake();
        }
    }
}

/// A waiter owns only its waker. Drop cannot cancel another waiter or producer.
pub struct Joined<T: Clone> {
    value: Value<T>,
    lease: u64,
}
impl<T: Clone> Future for Joined<T> {
    type Output = T;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<T> {
        let mut state = self.value.0.borrow_mut();
        if let Some(result) = state.result.clone() {
            state.waiters.remove(&self.lease);
            Poll::Ready(result)
        } else {
            state.waiters.insert(self.lease, cx.waker().clone());
            Poll::Pending
        }
    }
}
impl<T: Clone> Drop for Joined<T> {
    fn drop(&mut self) {
        self.value.0.borrow_mut().waiters.remove(&self.lease);
    }
}

struct Cancelled {
    cancelled: Cell<bool>,
    signal: Value<()>,
}
#[derive(Clone)]
pub struct Cancellation(Rc<Cancelled>);
impl Default for Cancellation {
    fn default() -> Self {
        Self(Rc::new(Cancelled {
            cancelled: Cell::new(false),
            signal: Value::new(),
        }))
    }
}
impl Cancellation {
    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.get()
    }
    pub fn cancel(&self) {
        if !self.0.cancelled.replace(true) {
            self.0.signal.resolve(());
        }
    }
    pub async fn cancelled(&self) {
        self.0.signal.join().await
    }
}
