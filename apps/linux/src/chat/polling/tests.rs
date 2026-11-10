// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex},
    task::{Context, Poll, Wake, Waker},
};

#[derive(Default)]
struct GateState {
    ready: bool,
    waker: Option<Waker>,
}
#[derive(Clone, Default)]
struct Gate(Rc<RefCell<GateState>>);
impl Gate {
    fn finish(&self) {
        let waker = {
            let mut state = self.0.borrow_mut();
            state.ready = true;
            state.waker.take()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}
impl Future for Gate {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut state = self.0.borrow_mut();
        if state.ready {
            Poll::Ready(())
        } else {
            state.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}
struct Timer {
    gate: Gate,
    active: Rc<Cell<bool>>,
}
impl Future for Timer {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        Pin::new(&mut self.gate).poll(cx)
    }
}
impl Drop for Timer {
    fn drop(&mut self) {
        self.active.set(false);
    }
}
struct Ready {
    id: u64,
    queue: Arc<Mutex<VecDeque<u64>>>,
}
impl Wake for Ready {
    fn wake(self: Arc<Self>) {
        self.queue.lock().unwrap().push_back(self.id);
    }
}
#[derive(Default)]
struct Executor {
    next: Cell<u64>,
    futures: RefCell<HashMap<u64, LocalFuture<()>>>,
    ready: Arc<Mutex<VecDeque<u64>>>,
    timers: RefCell<Vec<ScheduledTimer>>,
}
struct ScheduledTimer {
    duration: Duration,
    gate: Gate,
    active: Rc<Cell<bool>>,
}
impl Executor {
    fn spawn(&self, future: LocalFuture<()>) {
        let id = self.next.get() + 1;
        self.next.set(id);
        self.futures.borrow_mut().insert(id, future);
        self.ready.lock().unwrap().push_back(id);
    }
    fn runtime(self: &Rc<Self>) -> Runtime {
        let spawn = self.clone();
        let sleep = self.clone();
        Runtime::new(
            move |future| spawn.spawn(future),
            move |duration| {
                let gate = Gate::default();
                let active = Rc::new(Cell::new(true));
                sleep.timers.borrow_mut().push(ScheduledTimer {
                    duration,
                    gate: gate.clone(),
                    active: active.clone(),
                });
                Box::pin(Timer { gate, active })
            },
        )
    }
    fn pump(&self) {
        for _ in 0..10000 {
            let Some(id) = self.ready.lock().unwrap().pop_front() else {
                return;
            };
            let future = self.futures.borrow_mut().remove(&id);
            if let Some(mut future) = future {
                let waker = Waker::from(Arc::new(Ready {
                    id,
                    queue: self.ready.clone(),
                }));
                if future
                    .as_mut()
                    .poll(&mut Context::from_waker(&waker))
                    .is_pending()
                {
                    self.futures.borrow_mut().insert(id, future);
                }
            }
        }
        panic!("fixture task loop did not become idle");
    }
    fn tasks(&self) -> usize {
        self.futures.borrow().len()
    }
    fn timers(&self) -> usize {
        self.timers
            .borrow()
            .iter()
            .filter(|timer| timer.active.get())
            .count()
    }
}
#[derive(Clone, Default)]
struct Wire(Rc<RefCell<Vec<Gate>>>);
impl Wire {
    fn read(&self) -> LocalFuture<()> {
        let gate = Gate::default();
        self.0.borrow_mut().push(gate.clone());
        Box::pin(gate)
    }
    fn calls(&self) -> usize {
        self.0.borrow().len()
    }
    fn finish(&self, index: usize) {
        self.0.borrow()[index].finish();
    }
}
fn opening_call(open: Opening<String>, owner: &str, wire: Wire) -> LocalFuture<bool> {
    let owner = owner.to_owned();
    Box::pin(async move {
        open.run(owner, false, move |cancel| {
            Box::pin(async move {
                wire.read().await;
                !cancel.is_cancelled()
            })
        })
        .await
    })
}
fn poll_operation(wire: Wire, published: Rc<Cell<usize>>) -> impl Fn(Permit) -> LocalFuture<()> {
    move |permit| {
        let wire = wire.clone();
        let published = published.clone();
        Box::pin(async move {
            wire.read().await;
            if permit.allows() {
                published.set(published.get() + 1);
            }
        })
    }
}
fn watch(watcher: &Watcher<String>, owner: &str, wire: Wire, stops: Rc<Cell<usize>>) -> Watch {
    watcher.watch(
        owner.into(),
        move || wire.read(),
        || Duration::from_secs(100),
        move || stops.set(stops.get() + 1),
    )
}

#[test]
fn opening_waiter_drop_preserves_shared_producer_and_already_cancelled_call_is_inert() {
    let executor = Rc::new(Executor::default());
    let open = Opening::new(executor.runtime());
    let wire = Wire::default();
    let mut cancelled = opening_call(open.clone(), "A", wire.clone());
    let waker = Waker::noop();
    assert!(
        cancelled
            .as_mut()
            .poll(&mut Context::from_waker(waker))
            .is_pending()
    );
    drop(cancelled);
    let results = Rc::new(Cell::new(0));
    for _ in 0..30 {
        let call = opening_call(open.clone(), "A", wire.clone());
        let results = results.clone();
        executor.spawn(Box::pin(async move {
            assert!(call.await);
            results.set(results.get() + 1);
        }));
    }
    executor.pump();
    assert_eq!(wire.calls(), 1);
    wire.finish(0);
    executor.pump();
    assert_eq!(results.get(), 30);
    assert_eq!(executor.tasks(), 0);
    let call = open.clone();
    executor.spawn(Box::pin(async move {
        assert!(
            !call
                .run("B".into(), true, |_| panic!("cancelled caller started IO"))
                .await
        );
    }));
    executor.pump();
    assert_eq!(executor.tasks(), 0);
    assert_eq!(wire.calls(), 1);
}

#[test]
fn opening_owner_change_cancels_cooperatively_and_old_teardown_cannot_clear_successor() {
    let executor = Rc::new(Executor::default());
    let open = Opening::new(executor.runtime());
    let wire = Wire::default();
    let old = opening_call(open.clone(), "A", wire.clone());
    executor.spawn(Box::pin(async move {
        assert!(!old.await);
    }));
    executor.pump();
    let next = opening_call(open.clone(), "B", wire.clone());
    executor.spawn(Box::pin(async move {
        assert!(next.await);
    }));
    executor.pump();
    assert_eq!(wire.calls(), 2);
    wire.finish(0);
    executor.pump();
    let joined = opening_call(open.clone(), "B", wire.clone());
    executor.spawn(Box::pin(async move {
        assert!(joined.await);
    }));
    executor.pump();
    assert_eq!(wire.calls(), 2);
    wire.finish(1);
    executor.pump();
    assert_eq!(executor.tasks(), 0);
}

#[test]
fn refresh_bursts_retire_publication_without_parallel_io_or_replacing_the_first_operation() {
    let executor = Rc::new(Executor::default());
    let lane = Lane::new(executor.runtime());
    let wire = Wire::default();
    let published = Rc::new(Cell::new(0));
    let mut joined = Vec::new();
    for _ in 0..30 {
        joined.push(
            lane.start(
                "A",
                false,
                false,
                poll_operation(wire.clone(), published.clone()),
            )
            .unwrap(),
        );
    }
    executor.pump();
    assert_eq!(wire.calls(), 1);
    for _ in 0..30 {
        lane.start("A", true, false, |_| {
            panic!("refresh replaced original operation")
        });
    }
    wire.finish(0);
    executor.pump();
    assert_eq!(wire.calls(), 2);
    assert_eq!(published.get(), 0);
    wire.finish(1);
    executor.pump();
    assert_eq!(published.get(), 1);
    for mut joined in joined {
        assert!(
            Pin::new(&mut joined)
                .poll(&mut Context::from_waker(Waker::noop()))
                .is_ready()
        );
    }
    assert_eq!(executor.tasks(), 0);
    lane.start(
        "A",
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    for _ in 0..30 {
        lane.start("A", true, false, |_| {
            panic!("pre-start refresh replaced operation")
        });
    }
    executor.pump();
    wire.finish(2);
    executor.pump();
    assert_eq!(wire.calls(), 3);
    assert_eq!(published.get(), 2);
    assert_eq!(executor.tasks(), 0);
}

#[test]
fn poll_owner_and_exact_lane_identity_fence_late_replies_and_wrong_owner_cancellation() {
    let executor = Rc::new(Executor::default());
    let lane = Lane::new(executor.runtime());
    let wire = Wire::default();
    let published = Rc::new(Cell::new(0));
    lane.start(
        "A",
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    executor.pump();
    lane.start(
        "B",
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    executor.pump();
    wire.finish(0);
    executor.pump();
    assert_eq!(published.get(), 0);
    lane.start("B", false, false, |_| {
        panic!("old teardown cleared successor")
    });
    lane.cancel(Some(&"A"));
    wire.finish(1);
    executor.pump();
    assert_eq!(published.get(), 1);
    lane.start(
        "B",
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    executor.pump();
    lane.cancel(None);
    wire.finish(2);
    executor.pump();
    assert_eq!(published.get(), 1);
    assert_eq!(executor.tasks(), 0);
    assert!(
        lane.start("C", false, true, |_| panic!(
            "cancelled caller started poll"
        ))
        .is_none()
    );
}

#[test]
fn watcher_exact_view_leases_share_a_loop_and_cancellation_interrupts_its_timer() {
    let executor = Rc::new(Executor::default());
    let watcher = Watcher::new(executor.runtime());
    let wire = Wire::default();
    let stops = Rc::new(Cell::new(0));
    let mut one = Box::pin(watch(&watcher, "A", wire.clone(), stops.clone()));
    assert!(
        one.as_mut()
            .poll(&mut Context::from_waker(Waker::noop()))
            .is_pending()
    );
    let two = watch(&watcher, "A", wire.clone(), stops.clone());
    let last = two.cancellation();
    executor.spawn(Box::pin(two));
    executor.pump();
    assert_eq!(wire.calls(), 1);
    drop(one);
    executor.pump();
    assert_eq!(stops.get(), 0);
    wire.finish(0);
    executor.pump();
    assert_eq!(executor.timers(), 1);
    assert_eq!(
        executor.timers.borrow()[0].duration,
        Duration::from_secs(100)
    );
    executor.timers.borrow()[0].gate.finish();
    executor.pump();
    assert_eq!(wire.calls(), 2);
    wire.finish(1);
    executor.pump();
    assert_eq!(executor.timers(), 1);
    last.cancel();
    executor.pump();
    assert_eq!(stops.get(), 1);
    assert_eq!(executor.timers(), 0);
    assert_eq!(executor.tasks(), 0);
}

#[test]
fn displaced_watchers_and_late_old_cycles_cannot_stop_same_reader_successors() {
    let executor = Rc::new(Executor::default());
    let watcher = Watcher::new(executor.runtime());
    let wire = Wire::default();
    let stops = Rc::new(Cell::new(0));
    let old = watch(&watcher, "A", wire.clone(), stops.clone());
    let old_cancel = old.cancellation();
    executor.spawn(Box::pin(old));
    executor.pump();
    let next = watch(&watcher, "B", wire.clone(), stops.clone());
    let cancel = next.cancellation();
    executor.spawn(Box::pin(next));
    executor.pump();
    assert_eq!(wire.calls(), 2);
    assert_eq!(stops.get(), 1);
    old_cancel.cancel();
    wire.finish(0);
    executor.pump();
    assert_eq!(stops.get(), 1);
    cancel.cancel();
    executor.pump();
    assert_eq!(stops.get(), 2);
    wire.finish(1);
    executor.pump();
    assert_eq!(executor.tasks(), 0);
    assert_eq!(executor.timers(), 0);
    let inert = watch(&watcher, "C", wire.clone(), stops.clone());
    drop(inert);
    let pre_cancelled = watch(&watcher, "C", wire.clone(), stops.clone());
    pre_cancelled.cancellation().cancel();
    executor.spawn(Box::pin(pre_cancelled));
    executor.pump();
    assert_eq!(wire.calls(), 2);
    assert_eq!(executor.tasks(), 0);
}

#[test]
fn event_status_and_approval_producers_are_independent_while_event_io_is_held() {
    let executor = Rc::new(Executor::default());
    let events = Lane::new(executor.runtime());
    let status = Lane::new(executor.runtime());
    let approvals = Lane::new(executor.runtime());
    let wire = Wire::default();
    let published = Rc::new(Cell::new(0));
    events.start(
        1,
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    executor.pump();
    status.start(
        1,
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    approvals.start(
        1,
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    executor.pump();
    assert_eq!(wire.calls(), 3);
    wire.finish(1);
    wire.finish(2);
    executor.pump();
    assert_eq!(published.get(), 2);
    assert_eq!(executor.tasks(), 1);
    wire.finish(0);
    executor.pump();
    assert_eq!(published.get(), 3);
    assert_eq!(executor.tasks(), 0);
}

#[test]
fn cadence_retains_source_quiet_failure_progress_and_independent_claim_boundaries() {
    let mut cadence = Cadence::default();
    assert_eq!(cadence.interval(false, false, 0.), Duration::from_secs(2));
    for expected in [120, 180, 260, 400, 400] {
        assert_eq!(
            cadence.interval(true, false, 0.),
            Duration::from_millis(expected)
        );
        cadence.note(true, false, 0.);
    }
    cadence.note(true, true, 10.);
    assert_eq!(
        cadence.interval(false, false, 10.5),
        Duration::from_millis(120)
    );
    assert_eq!(cadence.interval(false, false, 12.), Duration::from_secs(2));
    assert_eq!(
        cadence.interval(false, true, 12.),
        Duration::from_millis(120)
    );
    for expected in [400, 800, 1600, 2000, 2000] {
        cadence.note(false, true, 12.);
        assert_eq!(
            cadence.interval(true, true, 12.),
            Duration::from_millis(expected)
        );
    }
    cadence.note(true, false, 13.);
    assert_eq!(
        cadence.interval(true, false, 13.),
        Duration::from_millis(180)
    );
    assert!(cadence.claim_status(0., false));
    assert!(!cadence.claim_status(0.99, false));
    assert!(cadence.claim_status(1., false));
    assert!(cadence.claim_status(1.01, true));
    assert!(cadence.claim_approvals(0., false));
    assert!(!cadence.claim_approvals(0.99, false));
    assert!(cadence.claim_approvals(0.99, true));
    assert!(!cadence.claim_status(f64::NAN, false));
    assert!(!cadence.claim_approvals(f64::NAN, false));
}

#[test]
fn started_lane_and_awaited_watcher_keep_their_original_self_lifetimes() {
    let executor = Rc::new(Executor::default());
    let wire = Wire::default();
    let published = Rc::new(Cell::new(0));
    let lane = Lane::new(executor.runtime());
    lane.start(
        "A",
        false,
        false,
        poll_operation(wire.clone(), published.clone()),
    );
    executor.pump();
    drop(lane);
    wire.finish(0);
    executor.pump();
    assert_eq!(published.get(), 1);
    assert_eq!(executor.tasks(), 0);
    let stops = Rc::new(Cell::new(0));
    let watcher = Watcher::new(executor.runtime());
    let future = watch(&watcher, "A", wire.clone(), stops.clone());
    let cancellation = future.cancellation();
    executor.spawn(Box::pin(future));
    executor.pump();
    drop(watcher);
    assert_eq!(stops.get(), 0);
    cancellation.cancel();
    executor.pump();
    assert_eq!(stops.get(), 1);
    wire.finish(1);
    executor.pump();
    assert_eq!(executor.tasks(), 0);
    assert_eq!(executor.timers(), 0);
}

#[test]
fn dropping_all_opening_waiters_and_handles_still_cannot_cancel_its_producer() {
    let executor = Rc::new(Executor::default());
    let open = Opening::new(executor.runtime());
    let wire = Wire::default();
    let completed = Rc::new(Cell::new(false));
    let finish = completed.clone();
    let read = wire.clone();
    let mut future = Box::pin(async move {
        open.run("A", false, move |cancel| {
            Box::pin(async move {
                read.read().await;
                assert!(!cancel.is_cancelled());
                finish.set(true);
                true
            })
        })
        .await
    });
    assert!(
        future
            .as_mut()
            .poll(&mut Context::from_waker(Waker::noop()))
            .is_pending()
    );
    drop(future);
    executor.pump();
    assert_eq!(wire.calls(), 1);
    wire.finish(0);
    executor.pump();
    assert!(completed.get());
    assert_eq!(executor.tasks(), 0);
}

#[test]
fn a_refresh_withdraws_publication_but_only_cancellation_retires_the_rpc_waiter() {
    let executor = Rc::new(Executor::default());
    let lane = Lane::new(executor.runtime());
    let wire = Wire::default();
    let permits = Rc::new(RefCell::new(Vec::new()));
    let captured = permits.clone();
    let reads = wire.clone();
    lane.start("A", false, false, move |permit| {
        captured.borrow_mut().push(permit);
        reads.read()
    });
    executor.pump();
    assert!(permits.borrow()[0].allows());
    lane.start("A", true, false, |_| panic!("refresh replaced operation"));
    assert!(!permits.borrow()[0].allows());
    assert!(!permits.borrow()[0].cancellation().is_cancelled());
    wire.finish(0);
    executor.pump();
    assert_eq!(wire.calls(), 2);
    assert!(permits.borrow()[1].allows());
    lane.cancel(None);
    assert!(!permits.borrow()[1].allows());
    assert!(permits.borrow()[1].cancellation().is_cancelled());
    wire.finish(1);
    executor.pump();
    assert_eq!(executor.tasks(), 0);
}
