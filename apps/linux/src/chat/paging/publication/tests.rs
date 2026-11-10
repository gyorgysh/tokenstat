// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::chat::projector::{Finished, Lane, Pending};
use serde_json::json;
use std::{
    collections::VecDeque,
    future::Future,
    pin::Pin,
    sync::Mutex,
    task::{Context, Poll, Waker},
};
type Task = Box<dyn FnOnce() + Send>;
#[derive(Default, Clone)]
struct Executor(Arc<Mutex<VecDeque<Task>>>);
impl Executor {
    fn lane(&self) -> Lane {
        let queue = self.0.clone();
        Lane::new(move |task| queue.lock().unwrap().push_back(task))
    }
    fn run(&self) {
        let task = self.0.lock().unwrap().pop_front().expect("scheduled task");
        std::thread::spawn(task).join().unwrap();
    }
    fn queued(&self) -> usize {
        self.0.lock().unwrap().len()
    }
}
fn ready(pending: &mut Pending) -> Finished {
    let Poll::Ready(finished) = Pin::new(pending).poll(&mut Context::from_waker(Waker::noop()))
    else {
        panic!("not ready")
    };
    finished
}
fn owner() -> Owner {
    Owner {
        scope: crate::work::Scope::local("fixture"),
        generation: 1,
        local_host_identity: "host".into(),
    }
}
fn chat() -> Conversation {
    serde_json::from_value(json!({"id":"chat","workspaceId":"folder","title":"Synthetic","backend":"codex","sendRevision":3})).unwrap()
}
fn event(seq: u64) -> TimelineEvent {
    serde_json::from_value(
        json!({"kind":"agent","seq":seq,"event":{"kind":"text","delta":format!("Text {seq}. ")}}),
    )
    .unwrap()
}
fn page(seqs: &[u64]) -> EventPage {
    EventPage {
        events: seqs.iter().copied().map(event).collect(),
        next_offset: 50,
        tail_cursor: Some("tail".into()),
        cursor: Some("older".into()),
        has_earlier: true,
        ..EventPage::default()
    }
}
fn project(step: Step) -> Work {
    match step {
        Step::Project(work) => work,
        Step::Complete(_) => panic!("expected projection"),
    }
}
fn done(step: Step) -> Completion {
    match step {
        Step::Complete(done) => done,
        Step::Project(_) => panic!("expected completion"),
    }
}
fn seed() -> (Window, Executor, Lane) {
    let executor = Executor::default();
    let lane = executor.lane();
    let mut window = Window::default();
    window.select(owner(), "folder", Some(chat()), false);
    let read = window.begin_open(false).unwrap();
    let mut pending = lane.submit(project(window.receive_page(&read, Ok(page(&[50, 51])))));
    executor.run();
    assert!(done(window.finish_projection(ready(&mut pending))).accepted);
    (window, executor, lane)
}
#[test]
fn raw_records_rows_and_cursors_publish_together_after_a_real_worker_finishes() {
    let (mut window, executor, lane) = seed();
    let held = window.events.clone();
    let rows = window.rows.clone();
    let revision = window.events_revision;
    let read = window.begin_tail(false).unwrap();
    let work = project(window.receive_chunk(
        &read,
        Ok(EventChunk {
            events: vec![event(52)],
            next_offset: 80,
            ..EventChunk::default()
        }),
    ));
    let mut pending = lane.submit(work);
    assert_eq!(executor.queued(), 1);
    assert!(Arc::ptr_eq(&held, &window.events));
    assert!(Arc::ptr_eq(&rows, &window.rows));
    executor.run();
    assert!(Arc::ptr_eq(&held, &window.events));
    assert_eq!(window.offset, 50);
    assert!(done(window.finish_projection(ready(&mut pending))).accepted);
    assert_eq!(window.events_revision, revision + 1);
    assert_eq!(window.offset, 80);
    assert_eq!(window.events.len(), 3);
    assert!(
        matches!(&window.rows[0].kind,transcript::Kind::Assistant{text,..} if text.contains("Text 52."))
    );
}
#[test]
fn a_tail_reprojects_after_prepend_instead_of_losing_the_older_records() {
    let (mut window, executor, lane) = seed();
    let tail = window.begin_tail(false).unwrap();
    let older = window.begin_earlier(false).unwrap();
    let mut a = lane.submit(project(window.receive_chunk(
        &tail,
        Ok(EventChunk {
            events: vec![event(52)],
            next_offset: 80,
            ..EventChunk::default()
        }),
    )));
    let mut b = lane.submit(project(window.receive_page(&older, Ok(page(&[10, 20])))));
    assert_eq!(executor.queued(), 1);
    executor.run();
    assert_eq!(executor.queued(), 1);
    executor.run();
    assert!(done(window.finish_projection(ready(&mut b))).accepted);
    let retry = project(window.finish_projection(ready(&mut a)));
    let mut retry = lane.submit(retry);
    executor.run();
    assert!(done(window.finish_projection(ready(&mut retry))).accepted);
    assert_eq!(
        window
            .events
            .iter()
            .filter_map(|e| e.seq)
            .collect::<Vec<_>>(),
        [10, 20, 50, 51, 52]
    );
}
#[test]
fn replacement_never_rebases_over_an_event_window_changed_during_cpu_work() {
    let (mut window, executor, lane) = seed();
    let open = window.begin_open(false).unwrap();
    let mut a = lane.submit(project(window.receive_page(&open, Ok(page(&[90])))));
    let earlier = window.begin_earlier(false).unwrap();
    let mut b = lane.submit(project(window.receive_page(&earlier, Ok(page(&[10])))));
    executor.run();
    executor.run();
    done(window.finish_projection(ready(&mut b)));
    assert!(!done(window.finish_projection(ready(&mut a))).accepted);
    assert_eq!(window.events[0].seq, Some(10));
    assert!(!window.opening());
}
#[test]
fn metadata_changes_retry_page_projection_and_do_not_publish_rows_from_the_old_provider() {
    let (mut window, executor, lane) = seed();
    let read = window.begin_tail(false).unwrap();
    let mut pending = lane.submit(project(window.receive_chunk(
        &read,
        Ok(EventChunk {
            events: vec![event(52)],
            next_offset: 80,
            ..EventChunk::default()
        }),
    )));
    executor.run();
    let mut updated = chat();
    updated.backend = "muse".into();
    updated.running = true;
    window.update_metadata(&owner(), "folder", updated);
    let retry = project(window.finish_projection(ready(&mut pending)));
    assert_eq!(window.events.len(), 2);
    let mut pending = lane.submit(retry);
    executor.run();
    assert!(done(window.finish_projection(ready(&mut pending))).accepted);
    assert!(
        matches!(&window.rows[0].kind,transcript::Kind::Assistant{backend:Some(b),..} if b=="muse")
    );
}
#[test]
fn metadata_publication_never_assigns_events_and_canonical_equal_rows_keep_their_storage() {
    let (mut window, executor, lane) = seed();
    let events = window.events.clone();
    let rows = window.rows.clone();
    let revision = window.events_revision;
    let display = window.display_revision;
    let mut pending = lane.submit(window.prepare_metadata().unwrap());
    executor.run();
    done(window.finish_projection(ready(&mut pending)));
    assert_eq!(window.events_revision, revision);
    assert_eq!(window.display_revision, display);
    assert!(Arc::ptr_eq(&events, &window.events));
    assert!(Arc::ptr_eq(&rows, &window.rows));
}

#[test]
fn metadata_survives_a_paging_epoch_and_rebases_if_the_newest_page_commits_first() {
    for metadata_first in [true, false] {
        let (mut window, executor, lane) = seed();
        let mut updated = chat();
        updated.backend = "muse".into();
        window.update_metadata(&owner(), "folder", updated);
        let mut a = lane.submit(window.prepare_metadata().unwrap());
        let read = window.begin_open(false).unwrap();
        let mut b = lane.submit(project(window.receive_page(&read, Ok(page(&[90])))));
        executor.run();
        executor.run();
        if metadata_first {
            assert!(done(window.finish_projection(ready(&mut a))).accepted);
        }
        assert!(done(window.finish_projection(ready(&mut b))).accepted);
        if !metadata_first {
            let retry = project(window.finish_projection(ready(&mut a)));
            let mut retry = lane.submit(retry);
            executor.run();
            assert!(done(window.finish_projection(ready(&mut retry))).accepted);
        }
        assert_eq!(window.events[0].seq, Some(90));
        assert!(
            matches!(&window.rows[0].kind,transcript::Kind::Assistant{backend:Some(b),..} if b=="muse")
        );
    }
}
#[test]
fn cancelling_after_cpu_releases_only_the_matching_spinner_and_cannot_publish() {
    let (mut window, executor, lane) = seed();
    let read = window.begin_open(false).unwrap();
    let pending = lane.submit(project(window.receive_page(&read, Ok(page(&[90])))));
    executor.run();
    assert!(window.opening());
    assert!(!done(window.finish_projection(pending.cancel())).accepted);
    assert!(!window.opening());
    assert_eq!(window.events[0].seq, Some(50));
}
#[test]
fn dropped_or_cancelled_queue_waiters_do_not_stop_a_successors_serial_worker() {
    let (mut window, executor, lane) = seed();
    let a = lane.submit(window.prepare_metadata().unwrap());
    let b = lane.submit(window.prepare_metadata().unwrap());
    let mut c = lane.submit(window.prepare_metadata().unwrap());
    assert_eq!(executor.queued(), 1);
    drop(a);
    done(window.finish_projection(b.cancel()));
    assert_eq!(executor.queued(), 1);
    executor.run();
    executor.run();
    executor.run();
    assert!(done(window.finish_projection(ready(&mut c))).accepted);
    assert_eq!(executor.queued(), 0);
}
#[test]
fn a_result_cannot_cross_models_even_when_scope_ids_generations_and_request_numbers_match() {
    let (mut a, executor, lane) = seed();
    let (mut b, _, _) = seed();
    let read = a.begin_tail(false).unwrap();
    let read_b = b.begin_tail(false).unwrap();
    let mut pending = lane.submit(project(a.receive_chunk(
        &read,
        Ok(EventChunk {
            events: vec![event(52)],
            next_offset: 80,
            ..EventChunk::default()
        }),
    )));
    executor.run();
    assert!(!done(b.finish_projection(ready(&mut pending))).accepted);
    assert!(b.current(&read_b));
    assert_eq!(b.events.len(), 2);
    assert!(!b.current(&read));
    assert!(
        !done(b.receive_chunk(
            &read,
            Err(Failure {
                message: "foreign failure".into(),
                unknown_method: false
            })
        ))
        .accepted
    );
    assert!(b.current(&read_b));
}
#[test]
fn a_retired_metadata_ticket_stays_retired_after_the_provider_changes_away_and_back() {
    let (mut window, executor, lane) = seed();
    let mut pending = lane.submit(window.prepare_metadata().unwrap());
    executor.run();
    let mut updated = chat();
    updated.backend = "muse".into();
    window.update_metadata(&owner(), "folder", updated);
    window.update_metadata(&owner(), "folder", chat());
    assert!(!done(window.finish_projection(ready(&mut pending))).accepted);
}

#[test]
fn ready_projection_wakes_a_registered_waiter_and_cancellation_before_cpu_retains_the_current_window()
 {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::task::Wake;
    struct WakeCount(AtomicUsize);
    impl Wake for WakeCount {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    let (mut window, executor, lane) = seed();
    let count = Arc::new(WakeCount(AtomicUsize::new(0)));
    let waker = Waker::from(count.clone());
    let mut pending = lane.submit(window.prepare_metadata().unwrap());
    assert!(matches!(
        Pin::new(&mut pending).poll(&mut Context::from_waker(&waker)),
        Poll::Pending
    ));
    executor.run();
    assert_eq!(count.0.load(Ordering::SeqCst), 1);
    done(window.finish_projection(ready(&mut pending)));
    let read = window.begin_open(false).unwrap();
    let pending = lane.submit(project(window.receive_page(&read, Ok(page(&[90])))));
    let original = window.events.clone();
    assert!(!done(window.finish_projection(pending.cancel())).accepted);
    executor.run();
    assert!(Arc::ptr_eq(&original, &window.events));
    assert!(!window.opening());
}

#[test]
fn opening_defer_still_finishes_when_a_trim_response_supersedes_its_replacement_ticket() {
    for opening_first in [false, true] {
        let (mut window, executor, lane) = seed();
        let open = window.begin_open(false).unwrap();
        let mut a = lane.submit(project(window.receive_page(&open, Ok(page(&[90])))));
        let earlier = window.begin_earlier(false).unwrap();
        let mut reset = page(&[100]);
        reset.reset = true;
        let mut b = lane.submit(project(window.receive_page(&earlier, Ok(reset))));
        executor.run();
        executor.run();
        if opening_first {
            assert!(!done(window.finish_projection(ready(&mut a))).accepted);
            assert!(!window.opening());
        }
        assert!(done(window.finish_projection(ready(&mut b))).accepted);
        if !opening_first {
            assert!(window.opening());
            assert!(!done(window.finish_projection(ready(&mut a))).accepted);
        }
        assert!(!window.opening());
        assert!(!window.loading_earlier());
        assert_eq!(window.events[0].seq, Some(100));
    }
}
