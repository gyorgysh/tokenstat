// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Actual GPUI foreground/background wakeup, without a window, client or store.

use serde_json::json;
use std::{
    future::Future,
    sync::{Arc, Condvar, Mutex},
};
use tokenstat_linux::{
    chat::{
        Conversation,
        directory::Owner,
        paging::{Window, publication::Step},
        projector::Lane,
    },
    work::Scope,
};

async fn registered_wake(window: &mut Window, executor: gpui::BackgroundExecutor) {
    // This test-only gate keeps the worker behind registration of the actual
    // GPUI foreground waker. The production Lane::background is tested below.
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let worker_gate = gate.clone();
    let lane = Lane::new(move |task| {
        let gate = worker_gate.clone();
        let check = executor.clone();
        executor
            .spawn(async move {
                assert!(!check.is_main_thread());
                let mut released = gate.0.lock().unwrap();
                while !*released {
                    released = gate.1.wait(released).unwrap();
                }
                drop(released);
                task();
            })
            .detach();
    });
    let mut pending = Box::pin(lane.submit(window.prepare_metadata().unwrap()));
    let mut observed_pending = false;
    let result = std::future::poll_fn(|cx| {
        let result = pending.as_mut().poll(cx);
        if result.is_pending() {
            observed_pending = true;
            *gate.0.lock().unwrap() = true;
            gate.1.notify_all();
        }
        result
    })
    .await;
    assert!(observed_pending);
    assert!(matches!(window.finish_projection(result), Step::Complete(done) if done.accepted));
}

fn main() {
    gpui::Application::new().run(|app| {
        let foreground = std::thread::current().id();
        let executor = app.background_executor().clone();
        let lane = Lane::background(executor.clone());
        let mut window = Window::default();
        let owner = Owner { scope: Scope::local("fixture"), generation: 1, local_host_identity: "fixture-host".into() };
        let chat: Conversation = serde_json::from_value(json!({"id":"chat","workspaceId":"folder","title":"Synthetic","backend":"codex"})).unwrap();
        window.select(owner, "folder", Some(chat), false);
        let read = window.begin_open(false).unwrap();
        let Step::Project(work) = window.receive_page(&read, Ok(serde_json::from_value(json!({
            "events":[{"kind":"agent","seq":1,"event":{"kind":"text","delta":"A synthetic reply"}}],"nextOffset":50
        })).unwrap())) else { panic!("missing work") };
        let pending = lane.submit(work);
        assert!(window.events().is_empty() && window.rows().is_empty());
        app.spawn(async move |cx| {
            let result = pending.await;
            assert_eq!(std::thread::current().id(), foreground);
            let Step::Complete(done) = window.finish_projection(result) else { panic!("unexpected retry") };
            assert!(done.accepted);
            assert_eq!(window.rows().len(), 1);
            assert_eq!(window.events().len(), 1);
            registered_wake(&mut window, executor).await;
            assert_eq!(std::thread::current().id(), foreground);
            let a = lane.submit(window.prepare_metadata().unwrap());
            let b = lane.submit(window.prepare_metadata().unwrap());
            assert!(matches!(window.finish_projection(a.await), Step::Complete(done) if !done.accepted));
            assert!(matches!(window.finish_projection(b.await), Step::Complete(done) if done.accepted));
            let cancelled = lane.submit(window.prepare_metadata().unwrap());
            assert!(matches!(window.finish_projection(cancelled.cancel()), Step::Complete(done) if !done.accepted));
            assert_eq!(std::thread::current().id(), foreground);
            println!("{}", json!({"accepted":true,"foregroundResume":true,"registeredWake":true,"backgroundGuard":cfg!(debug_assertions),"rawRowsAtomic":true,"metadataTickets":true,"cancelled":true,"windowsOpened":0,"hostOrStoreOpened":false}));
            cx.update(|app| app.quit()).unwrap();
        }).detach();
    });
}
