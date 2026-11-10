// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Actual GPUI retained async ownership and timers, with suspended fixture IO.
//! This opens no window, host, account, archive, owner lease or store.

use gpui::AsyncApp;
use serde_json::json;
use std::{
    cell::{Cell, RefCell},
    future::Future,
    pin::Pin,
    rc::Rc,
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};
use tokenstat_linux::chat::polling::{
    Lane, LocalFuture, Opening, Permit, Runtime, WatchCancellation, Watcher,
};

#[derive(Default)]
struct Gate {
    ready: bool,
    waker: Option<Waker>,
}
#[derive(Clone, Default)]
struct Held(Rc<RefCell<Gate>>);
impl Future for Held {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut held = self.0.borrow_mut();
        if held.ready {
            Poll::Ready(())
        } else {
            held.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}
#[derive(Clone, Default)]
struct Wire(Rc<RefCell<Vec<Held>>>);
impl Wire {
    fn read(&self) -> LocalFuture<()> {
        let held = Held::default();
        self.0.borrow_mut().push(held.clone());
        Box::pin(held)
    }
    fn calls(&self) -> usize {
        self.0.borrow().len()
    }
    fn finish(&self, index: usize) {
        let waker = {
            let pending = self.0.borrow();
            let mut held = pending[index].0.borrow_mut();
            held.ready = true;
            held.waker.take()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}
async fn until(condition: impl Fn() -> bool, cx: &AsyncApp) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "owned foreground checkpoint did not arrive"
        );
        cx.background_executor()
            .timer(Duration::from_millis(1))
            .await;
    }
}
fn opening(
    cx: &AsyncApp,
    open: Opening<String>,
    owner: &str,
    wire: Wire,
    started: Rc<Cell<usize>>,
) -> gpui::Task<bool> {
    let owner = owner.to_owned();
    cx.spawn(async move |_| {
        started.set(started.get() + 1);
        open.run(owner, false, move |cancel| {
            Box::pin(async move {
                wire.read().await;
                !cancel.is_cancelled()
            })
        })
        .await
    })
}
fn operation(wire: Wire, published: Rc<Cell<usize>>) -> impl Fn(Permit) -> LocalFuture<()> {
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
fn watch(
    cx: &AsyncApp,
    watcher: &Watcher<String>,
    owner: &str,
    wire: Wire,
    stops: Rc<Cell<usize>>,
    started: Rc<Cell<usize>>,
    intervals: Rc<Cell<usize>>,
) -> (gpui::Task<()>, WatchCancellation) {
    let watching = watcher.watch(
        owner.into(),
        move || wire.read(),
        move || {
            intervals.set(intervals.get() + 1);
            Duration::from_secs(100)
        },
        move || stops.set(stops.get() + 1),
    );
    let cancellation = watching.cancellation();
    (
        cx.spawn(async move |_| {
            started.set(started.get() + 1);
            watching.await
        }),
        cancellation,
    )
}

fn main() {
    gpui::Application::new().run(|app| {
        let foreground=std::thread::current().id();
        let runtime=Runtime::gpui(app);
        app.spawn(async move |cx| {
            let open=Opening::new(runtime.clone());let pages=Wire::default();let started=Rc::new(Cell::new(0));
            let mut waiters=Vec::new();
            for _ in 0..30 {waiters.push(opening(cx,open.clone(),"A",pages.clone(),started.clone()));}
            until(||started.get()==30 && pages.calls()==1,cx).await;
            drop(waiters.remove(0));pages.finish(0);
            for waiter in waiters {assert!(waiter.await);}
            assert!(!open.run("A".into(),true,|_|panic!("cancelled entry started opening IO")).await);
            let old=opening(cx,open.clone(),"A",pages.clone(),started.clone());until(||pages.calls()==2,cx).await;
            let next=opening(cx,open.clone(),"B",pages.clone(),started.clone());until(||pages.calls()==3,cx).await;
            pages.finish(1);assert!(!old.await);
            let join=opening(cx,open.clone(),"B",pages.clone(),started.clone());until(||started.get()==33,cx).await;
            assert_eq!(pages.calls(),3);pages.finish(2);assert!(next.await);assert!(join.await);

            let lane=Lane::new(runtime.clone());let wire=Wire::default();let published=Rc::new(Cell::new(0));let mut joins=Vec::new();
            for _ in 0..30 {joins.push(lane.start("A",false,false,operation(wire.clone(),published.clone())).unwrap());}
            until(||wire.calls()==1,cx).await;
            for _ in 0..30 {lane.start("A",true,false,|_|panic!("refresh replaced original operation"));}
            wire.finish(0);until(||wire.calls()==2,cx).await;assert_eq!(published.get(),0);wire.finish(1);
            for join in joins {join.await;}
            assert_eq!(published.get(),1);
            let old=lane.start("A",false,false,operation(wire.clone(),published.clone())).unwrap();until(||wire.calls()==3,cx).await;
            let next=lane.start("B",false,false,operation(wire.clone(),published.clone())).unwrap();until(||wire.calls()==4,cx).await;
            wire.finish(2);old.await;
            lane.start("B",false,false,|_|panic!("old teardown erased successor"));lane.cancel(Some(&"A"));wire.finish(3);next.await;assert_eq!(published.get(),2);
            let cancelled=lane.start("B",false,false,operation(wire.clone(),published.clone())).unwrap();until(||wire.calls()==5,cx).await;
            lane.cancel(None);wire.finish(4);cancelled.await;assert_eq!(published.get(),2);
            assert!(lane.start("C",false,true,|_|panic!("cancelled entry started poll IO")).is_none());

            let held_lane=Lane::new(runtime.clone());let held_wire=Wire::default();let held_published=Rc::new(Cell::new(0));
            let held=held_lane.start("A",false,false,operation(held_wire.clone(),held_published.clone())).unwrap();
            until(||held_wire.calls()==1,cx).await;drop(held_lane);held_wire.finish(0);held.await;assert_eq!(held_published.get(),1);

            let watcher=Watcher::new(runtime.clone());let cycles=Wire::default();let stops=Rc::new(Cell::new(0));let started=Rc::new(Cell::new(0));let intervals=Rc::new(Cell::new(0));
            let (one,_first)=watch(cx,&watcher,"A",cycles.clone(),stops.clone(),started.clone(),intervals.clone());
            let (two,last)=watch(cx,&watcher,"A",cycles.clone(),stops.clone(),started.clone(),intervals.clone());
            until(||started.get()==2 && cycles.calls()==1,cx).await;
            drop(one);assert_eq!(stops.get(),0);last.cancel();two.await;assert_eq!(stops.get(),1);
            let (successor,cancel)=watch(cx,&watcher,"B",cycles.clone(),stops.clone(),started.clone(),intervals.clone());until(||cycles.calls()==2,cx).await;
            cycles.finish(0);until(||intervals.get()==1,cx).await;assert_eq!(stops.get(),1);
            cycles.finish(1);until(||intervals.get()==2,cx).await;cancel.cancel();successor.await;assert_eq!(stops.get(),2);
            let (displaced,old)=watch(cx,&watcher,"A",cycles.clone(),stops.clone(),started.clone(),intervals.clone());until(||cycles.calls()==3,cx).await;
            let (replacement,last)=watch(cx,&watcher,"B",cycles.clone(),stops.clone(),started.clone(),intervals.clone());until(||cycles.calls()==4,cx).await;displaced.await;
            old.cancel();assert_eq!(stops.get(),3);last.cancel();replacement.await;assert_eq!(stops.get(),4);
            cycles.finish(2);cycles.finish(3);until(||intervals.get()==4,cx).await;
            let ticks=Rc::new(Cell::new(0));let tick=ticks.clone();let stop=stops.clone();
            let ticking=watcher.watch("C".into(),move || {tick.set(tick.get()+1);Box::pin(async {})},||Duration::from_millis(1),move ||stop.set(stop.get()+1));
            let cancel=ticking.cancellation();let ticking=cx.spawn(async move |_|ticking.await);
            until(||ticks.get()>=2,cx).await;cancel.cancel();ticking.await;assert_eq!(stops.get(),5);
            let inert=watcher.watch("D".into(),||panic!("cancelled watch started a cycle"),||panic!("cancelled watch started a timer"),||panic!("cancelled watch stopped a nonexistent loop"));
            inert.cancellation().cancel();inert.await;
            let held_watcher=Watcher::new(runtime.clone());let held_cycles=Wire::default();let held_stops=Rc::new(Cell::new(0));let held_intervals=Rc::new(Cell::new(0));
            let (held,cancel)=watch(cx,&held_watcher,"held",held_cycles.clone(),held_stops.clone(),Rc::default(),held_intervals.clone());
            until(||held_cycles.calls()==1,cx).await;drop(held_watcher);assert_eq!(held_stops.get(),0);
            cancel.cancel();held.await;assert_eq!(held_stops.get(),1);held_cycles.finish(0);until(||held_intervals.get()==1,cx).await;
            assert_eq!(std::thread::current().id(),foreground);
            println!("{}",json!({"openingShared":true,"openingWaiterDrop":true,"openingOwnerCancellation":true,"openingSuccessor":true,"boundedRefresh":true,"pollOwnerCancellation":true,"pollSuccessor":true,"exactWatchLeases":true,"watchSuccessor":true,"actualTimerCycle":true,"cancelledEntry":true,"ownerLifetimes":true,"foregroundResume":true,"windowsOpened":0,"hostOrStoreOpened":false}));
            cx.update(|app|app.quit()).unwrap();
        }).detach();
    });
}
