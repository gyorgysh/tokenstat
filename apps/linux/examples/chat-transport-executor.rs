// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Actual GPUI foreground/background transport with an owned fake Unix host.
//! No product window, archive, account, owner lease or store is opened.

use gpui::{App, AppContext, AsyncApp, EntityId};
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    future::Future,
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::{UnixListener, UnixStream},
    pin::Pin,
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, Sender},
    },
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};
use tokenstat_linux::{
    chat::{
        Conversation,
        directory::Owner,
        paging::{Failure, Window, publication::Step},
        polling::Cancellation,
        projector::Lane,
        query::{Query, Reply},
        reader::Reader,
        transport::{self, Consumer, Lease, Request},
    },
    client::Client,
    work::Scope,
};

type Inbox<T> = Arc<Mutex<Receiver<T>>>;
struct Pending {
    stream: UnixStream,
    request: Value,
}
struct Host {
    _root: tempfile::TempDir,
    client: Client,
    pending: Inbox<Pending>,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Host {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let (send, receive) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let worker = std::thread::spawn(move || {
            while !stopping.load(Ordering::Acquire) {
                let stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("owned socket accept failed: {error}"),
                };
                stream.set_nonblocking(false).unwrap();
                if let Err(error) = stream.set_read_timeout(Some(Duration::from_secs(5))) {
                    // Darwin can reject setsockopt on an already-closed
                    // connection-only probe. Verify EOF without blocking.
                    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
                    stream.set_nonblocking(true).unwrap();
                    let mut probe = &stream;
                    assert_eq!(probe.read(&mut [0]).unwrap(), 0);
                    continue;
                }
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap() == 0 {
                    continue; // Existing ensure_host's connection-only probe.
                }
                reader
                    .get_ref()
                    .set_write_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                if request["method"] == "protocol" {
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        json!({"id":1,"ok":true,"result":{"protocolVersion":"53"}})
                    )
                    .unwrap();
                } else {
                    send.send(Pending {
                        stream: reader.into_inner(),
                        request,
                    })
                    .unwrap();
                }
            }
        });
        Self {
            _root: root,
            client: Client {
                socket,
                allow_spawn: false,
            },
            pending: Arc::new(Mutex::new(receive)),
            stop,
            worker: Some(worker),
        }
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.worker.take().unwrap().join().unwrap();
    }
}

async fn take<T: Send + 'static>(inbox: &Inbox<T>, cx: &AsyncApp) -> T {
    let inbox = inbox.clone();
    cx.background_executor()
        .spawn(async move {
            inbox
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(5))
                .expect("owned async fixture did not arrive")
        })
        .await
}
async fn answer(mut pending: Pending, envelope: Value, cx: &AsyncApp) {
    cx.background_executor()
        .spawn(async move {
            writeln!(pending.stream, "{envelope}").unwrap();
        })
        .await;
}
async fn until(mut condition: impl FnMut() -> bool, cx: &AsyncApp) {
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

struct Fixture {
    host: Host,
    owner: Owner,
    epoch: Arc<AtomicU64>,
    delivered: Sender<(&'static str, transport::Result)>,
}
impl Fixture {
    fn read(
        &self,
        entity: EntityId,
        label: &'static str,
        query: Query,
        visits: Rc<Cell<usize>>,
        app: &mut App,
    ) -> Lease {
        let delivered = self.delivered.clone();
        self.read_with(
            entity,
            query,
            visits,
            move |result, _| {
                delivered.send((label, result)).unwrap();
            },
            app,
        )
    }
    fn read_with(
        &self,
        entity: EntityId,
        query: Query,
        visits: Rc<Cell<usize>>,
        finish: impl FnOnce(transport::Result, &mut App) + 'static,
        app: &mut App,
    ) -> Lease {
        transport::read(
            self.request(query),
            Consumer::new(
                entity,
                move |_| {
                    visits.set(visits.get() + 1);
                    true
                },
                finish,
            ),
            app,
        )
        .unwrap()
    }
    fn request(&self, query: Query) -> Request {
        Request {
            client: self.host.client.clone(),
            owner: self.owner.clone(),
            folder: "remote:peer:folder".into(),
            query,
            epoch: self.epoch.clone(),
        }
    }
}
fn page() -> Query {
    Query::Page {
        id: "chat".into(),
        cursor: None,
        limit: 1500,
        include_usage: true,
    }
}
fn chunk() -> Query {
    Query::Events {
        id: "chat".into(),
        offset: 50,
        tail_cursor: Some("opaque".into()),
    }
}
fn assert_request(pending: &Pending, query: &Query) {
    assert_eq!(pending.request["method"], "remote.call");
    assert_eq!(
        pending.request["params"],
        json!({"peer":"peer","method":query.method(),"params":query.parameters()})
    );
}
fn success(result: Value) -> Value {
    json!({"id":1,"ok":true,"result":result})
}
fn assert_pending(future: Pin<&mut impl Future>) {
    assert!(matches!(
        future.poll(&mut Context::from_waker(Waker::noop())),
        Poll::Pending
    ));
}

fn main() {
    gpui::Application::new().run(|app| {
        let foreground = std::thread::current().id();
        let first = app.new(|_| ());
        let second = app.new(|_| ());
        let (send, receive) = mpsc::channel();
        let inbox = Arc::new(Mutex::new(receive));
        let fixture = Fixture {host:Host::new(),owner:Owner {scope:Scope::local("synthetic"),generation:1,local_host_identity:"fixture-host".into()},epoch:Arc::new(AtomicU64::new(1)),delivered:send};
        let chat: Conversation = serde_json::from_value(json!({"id":"chat","workspaceId":"folder","title":"Synthetic","backend":"codex"})).unwrap();
        let mut first_window = Window::default();
        let mut second_window = Window::default();
        first_window.select(fixture.owner.clone(),"remote:peer:folder",Some(chat.clone()),false);
        second_window.select(fixture.owner.clone(),"remote:peer:folder",Some(chat),false);
        let first_read = first_window.begin_open(false).unwrap();
        let second_read = second_window.begin_open(false).unwrap();
        assert_eq!(first_read.query(),page());
        assert_eq!(second_read.query(),page());
        let first_lane = Lane::background(app.background_executor().clone());
        let second_lane = Lane::background(app.background_executor().clone());
        let visits = Rc::new(Cell::new(0));
        let old = fixture.read(first.entity_id(),"cancelled",page(),Rc::default(),app);
        fixture.read(second.entity_id(),"survivor",page(),visits.clone(),app);
        app.spawn(async move |cx| {
            let old_request = take(&fixture.host.pending,cx).await;
            assert_request(&old_request,&page());
            cx.update(|app| {
                transport::invalidate(&fixture.owner,"remote:peer:folder",app);
                fixture.read(first.entity_id(),"successor",page(),Rc::default(),app);
                transport::cancel(old,app);
            }).unwrap();
            let next = take(&fixture.host.pending,cx).await;
            answer(old_request,json!({"id":1,"ok":false,"error":{"code":"unknown_method","message":"discarded refusal"}}),cx).await;
            until(||visits.get()>=2,cx).await;
            assert!(inbox.lock().unwrap().try_recv().is_err());
            answer(next,success(json!({"events":[{"kind":"agent","seq":1,"event":{"kind":"text","delta":"Synthetic reply"}}],"nextOffset":50})),cx).await;
            let (a,one) = take(&inbox,cx).await;
            let (b,two) = take(&inbox,cx).await;
            assert_eq!([a,b],["successor","survivor"]);
            let (Reply::Page(one),Reply::Page(two)) = (one.unwrap(),two.unwrap()) else {panic!("typed page changed")};
            assert!(Arc::ptr_eq(&one,&two));

            // Fixture-owned Window adapters consume the shared receipt and
            // production CPU lanes. They are not the full retained ChatModel
            // selection/load/poll controller or the mounted ChatView.
            let Step::Project(a) = first_window.receive_shared_page(&first_read,Ok(one)) else {panic!("missing first projection")};
            let Step::Project(b) = second_window.receive_shared_page(&second_read,Ok(two)) else {panic!("missing second projection")};
            let a = first_lane.submit(a);
            let b = second_lane.submit(b);
            assert!(first_window.events().is_empty() && first_window.rows().is_empty());
            assert!(second_window.events().is_empty() && second_window.rows().is_empty());
            first_window.select(fixture.owner.clone(),"remote:peer:folder",None,false);
            assert!(matches!(first_window.finish_projection(a.await),Step::Complete(done) if !done.accepted));
            assert!(matches!(second_window.finish_projection(b.await),Step::Complete(done) if done.accepted));
            assert!(first_window.events().is_empty() && first_window.rows().is_empty());
            assert_eq!(second_window.events().len(),1);
            assert_eq!(second_window.rows().len(),1);

            // Completed values are not cached. A real coded refusal is kept.
            cx.update(|app| {fixture.read(first.entity_id(),"coded",page(),Rc::default(),app);}).unwrap();
            let request = take(&fixture.host.pending,cx).await;
            assert_request(&request,&page());
            answer(request,json!({"id":1,"ok":false,"error":{"code":"unknown_method","message":"Unsupported"}}),cx).await;
            let (label,result) = take(&inbox,cx).await;
            assert_eq!(label,"coded");
            let failure = Failure::from_error(result.as_ref().err().unwrap());
            assert!(failure.unknown_method);
            assert_eq!(failure.message,"Unsupported");

            // Directory and tail reads invalidate in the same peer domain.
            for query in [Query::directory("remote:peer:folder"),chunk()] {
                let visits = Rc::new(Cell::new(0));
                cx.update(|app| {fixture.read(first.entity_id(),"retry",query.clone(),visits.clone(),app);}).unwrap();
                let old = take(&fixture.host.pending,cx).await;
                assert_request(&old,&query);
                cx.update(|app| transport::invalidate(&fixture.owner,"remote:peer:other",app)).unwrap();
                let old_result = if matches!(query,Query::Directory{..}) {success(json!([]))} else {json!({"ok":false,"error":"unknown chat.events"})};
                answer(old,old_result,cx).await;
                let retry = take(&fixture.host.pending,cx).await;
                assert_request(&retry,&query);
                assert!(inbox.lock().unwrap().try_recv().is_err());
                let value = if matches!(query,Query::Directory{..}) {json!([])} else {json!({"events":[],"nextOffset":50})};
                answer(retry,success(value),cx).await;
                let (label,result) = take(&inbox,cx).await;
                assert_eq!(label,"retry");
                assert!(matches!((query,result.unwrap()),(Query::Directory{..},Reply::Directory(_))|(Query::Events{..},Reply::Events(_))));
            }

            // A first callback can cancel the next lease in this same batch.
            // The producer has completed and is already outside the pool.
            let cancelled = Rc::new(RefCell::new(None::<Lease>));
            let to_cancel = cancelled.clone();
            cx.update(|app| {
                let send = fixture.delivered.clone();
                fixture.read_with(first.entity_id(),chunk(),Rc::default(),move |result,app| {
                    transport::cancel(to_cancel.borrow_mut().take().unwrap(),app);
                    send.send(("batch",result)).unwrap();
                },app);
                *cancelled.borrow_mut() = Some(fixture.read(second.entity_id(),"batch-cancelled",chunk(),Rc::default(),app));
            }).unwrap();
            let pending = take(&fixture.host.pending,cx).await;
            answer(pending,success(json!({"events":[],"nextOffset":50})),cx).await;
            assert_eq!(take(&inbox,cx).await.0,"batch");

            // Releasing a retained entity also retires batched successors.
            let second_id = second.entity_id();
            cx.update(|app| {
                let send = fixture.delivered.clone();
                fixture.read_with(first.entity_id(),page(),Rc::default(),move |result,app| {
                    transport::release_entity(second_id,app);
                    send.send(("release",result)).unwrap();
                },app);
                fixture.read(second_id,"released",page(),Rc::default(),app);
            }).unwrap();
            let pending = take(&fixture.host.pending,cx).await;
            answer(pending,success(json!({"events":[],"nextOffset":50})),cx).await;
            assert_eq!(take(&inbox,cx).await.0,"release");
            assert!(inbox.lock().unwrap().try_recv().is_err());
            assert!(fixture.host.pending.lock().unwrap().try_recv().is_err());
            // A mounted view begins its directory read while GPUI holds the
            // view's update lease. Its current predicate reads that same view:
            // admission must wait until the update has ended.
            let directory_query = Query::directory("folder");
            let check_query = directory_query.clone();
            let deferred_view = cx.update(|app| {
                let view = app.new(|_| true);
                let weak = view.downgrade();
                let entity = view.entity_id();
                let request = fixture.request(directory_query);
                let delivered = fixture.delivered.clone();
                view.update(app, |_, cx| {
                    transport::read_deferred(request, Consumer::new(entity,
                        move |app| weak.upgrade().is_some_and(|view| *view.read(app)),
                        move |result, _| delivered.send(("deferred-mounted", result)).unwrap()), cx);
                });
                view
            }).unwrap();
            let pending = take(&fixture.host.pending,cx).await;
            assert_request(&pending,&check_query);
            answer(pending,success(json!([])),cx).await;
            let (label, result) = take(&inbox,cx).await;
            assert_eq!(label,"deferred-mounted");
            assert!(matches!(result.unwrap(), Reply::Directory(_)));
            drop(deferred_view);
            // The same deferred admission must not start a producer if its
            // mounted operation was retired before its entity update returned.
            let retired_view = cx.update(|app| {
                let view = app.new(|_| true);
                let weak = view.downgrade();
                let entity = view.entity_id();
                let request = fixture.request(Query::directory("retired"));
                let delivered = fixture.delivered.clone();
                view.update(app, |current, cx| {
                    transport::read_deferred(request, Consumer::new(entity,
                        move |app| weak.upgrade().is_some_and(|view| *view.read(app)),
                        move |result, _| delivered.send(("retired-before-admission", result)).unwrap()), cx);
                    *current = false;
                });
                view
            }).unwrap();
            cx.spawn(async |_| {}).await;
            assert!(fixture.host.pending.lock().unwrap().try_recv().is_err());
            assert!(inbox.lock().unwrap().try_recv().is_err());
            drop(retired_view);

            // Actual retained controller entities, not the earlier direct
            // Window adapters. Selection/construction alone starts no IO.
            let (reader_a,reader_b)=cx.update(|app| {
                let a=app.new(|cx|Reader::new(fixture.host.client.clone(),fixture.epoch.clone(),|scope,_|scope==&Scope::local("synthetic"),cx));
                let b=app.new(|cx|Reader::new(fixture.host.client.clone(),fixture.epoch.clone(),|scope,_|scope==&Scope::local("synthetic"),cx));
                for reader in [&a,&b] {
                    reader.update(app,|reader,cx|reader.set_selection(fixture.owner.clone(),"remote:peer:folder",Some(serde_json::from_value(json!({"id":"chat","workspaceId":"folder","title":"Synthetic","backend":"codex"})).unwrap()),false,cx));
                }
                (a,b)
            }).unwrap();
            assert!(fixture.host.pending.lock().unwrap().try_recv().is_err());
            let (a,joined,b)=cx.update(|app| (
                reader_a.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx)),
                reader_a.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx)),
                reader_b.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx)),
            )).unwrap();
            let request=take(&fixture.host.pending,cx).await;assert_request(&request,&page());
            cx.update(|app|for reader in [&reader_a,&reader_b] {let window=reader.read(app).window();assert!(window.opening() && window.events().is_empty() && window.rows().is_empty());}).unwrap();
            answer(request,success(json!({"events":[{"kind":"agent","seq":1,"event":{"kind":"text","delta":"First"}}],"nextOffset":50,"tailCursor":"opaque","cursor":"older","hasEarlier":true})),cx).await;
            assert!(a.await && joined.await && b.await);
            let notifications=Rc::new(Cell::new(0));let notified=notifications.clone();
            let _observed=cx.update(|app|app.observe(&reader_b,move |_,_|notified.set(notified.get()+1))).unwrap();
            let (earlier,tail)=cx.update(|app| (
                reader_a.update(app,|reader,cx|reader.earlier(false,Cancellation::default(),cx)),
                reader_a.update(app,|reader,cx|reader.tail(true,Cancellation::default(),cx)),
            )).unwrap();
            let one=take(&fixture.host.pending,cx).await;let two=take(&fixture.host.pending,cx).await;
            let (earlier_request,tail_request)=if one.request["params"]["method"]=="chat.eventPage" {(one,two)} else {(two,one)};
            assert_request(&earlier_request,&Query::Page {id:"chat".into(),cursor:Some("older".into()),limit:1200,include_usage:true});assert_request(&tail_request,&chunk());
            answer(tail_request,success(json!({"events":[{"kind":"agent","seq":2,"event":{"kind":"text","delta":" second"}}],"nextOffset":51,"tailCursor":"tail51"})),cx).await;assert!(tail.await.accepted);
            answer(earlier_request,success(json!({"events":[{"kind":"agent","seq":0,"event":{"kind":"text","delta":"Older "}}],"nextOffset":50,"hasEarlier":false})),cx).await;assert!(earlier.await.accepted);
            let (revision,display)=cx.update(|app| {
                let window=reader_a.read(app).window();assert_eq!(window.events().iter().filter_map(|event|event.seq).collect::<Vec<_>>(),[0,1,2]);assert_eq!(window.offset(),51);assert_eq!(window.tail_cursor(),Some("tail51"));assert!(!window.loading_earlier());assert!(window.reached_start());
                (window.events_revision(),window.display_revision())
            }).unwrap();
            cx.update(|app|reader_a.update(app,|reader,cx| {
                let mut metadata=reader.window().selected().unwrap().clone();metadata.backend="muse".into();metadata.running=true;metadata.send_revision=Some(999);
                assert!(reader.update_metadata(&fixture.owner,"remote:peer:folder",metadata,cx));
            })).unwrap();
            until(||cx.update(|app|reader_a.read(app).window().display_revision()>display).unwrap(),cx).await;
            cx.update(|app| {let window=reader_a.read(app).window();assert_eq!(window.events_revision(),revision);assert_eq!(window.context_revision(),None);}).unwrap();
            let display=cx.update(|app|reader_a.read(app).window().display_revision()).unwrap();
            cx.update(|app|reader_a.update(app,|reader,cx| {
                for backend in ["codex","muse","codex"] {
                    let mut metadata=reader.window().selected().unwrap().clone();metadata.backend=backend.into();metadata.running=false;
                    assert!(reader.update_metadata(&fixture.owner,"remote:peer:folder",metadata,cx));
                }
            })).unwrap();
            until(||cx.update(|app|reader_a.read(app).window().display_revision()>display).unwrap(),cx).await;
            cx.update(|app| {let window=reader_a.read(app).window();assert_eq!(window.events_revision(),revision);assert_eq!(window.display_revision(),display+1);}).unwrap();
            assert!(fixture.host.pending.lock().unwrap().try_recv().is_err());

            // The mounted reader watcher starts the event lane, drains a
            // multi-page tail, and retires a held response when its view goes
            // inactive. A successor watch can safely share that held producer.
            let watch=cx.update(|app|reader_a.update(app,|reader,cx|reader.watch_events(cx).unwrap())).unwrap();
            let stop=watch.cancellation();let watched=cx.spawn(async move |_|watch.await);
            let first_poll=take(&fixture.host.pending,cx).await;
            assert_eq!(first_poll.request["params"]["method"],"chat.events");
            answer(first_poll,success(json!({"events":[{"kind":"agent","seq":3,"event":{"kind":"text","delta":" live"}}],"nextOffset":52,"tailCursor":"tail52","hasMore":true})),cx).await;
            let second_poll=take(&fixture.host.pending,cx).await;
            assert_eq!(second_poll.request["params"]["params"]["offset"],52);
            answer(second_poll,success(json!({"events":[{"kind":"agent","seq":4,"event":{"kind":"text","delta":" more"}}],"nextOffset":53,"tailCursor":"tail53"})),cx).await;
            until(||cx.update(|app|reader_a.read(app).window().offset()==53).unwrap(),cx).await;
            let held=take(&fixture.host.pending,cx).await;
            assert_eq!(held.request["params"]["params"]["offset"],53);
            stop.cancel();watched.await;
            let successor=cx.update(|app|reader_a.update(app,|reader,cx|reader.watch_events(cx).unwrap())).unwrap();
            let successor_stop=successor.cancellation();let successor_task=cx.spawn(async move |_|successor.await);
            // Allow the successor to enroll in the suspended flight.
            cx.background_executor().timer(Duration::from_millis(30)).await;
            answer(held,success(json!({"events":[{"kind":"agent","seq":5,"event":{"kind":"text","delta":" resumed"}}],"nextOffset":54,"tailCursor":"tail54"})),cx).await;
            until(||cx.update(|app|reader_a.read(app).window().offset()==54).unwrap(),cx).await;
            successor_stop.cancel();successor_task.await;
            cx.update(|app| {let events=reader_a.read(app).window().events();assert_eq!(events.iter().filter_map(|event|event.seq).collect::<Vec<_>>(),[0,1,2,3,4,5]);}).unwrap();

            let reset=cx.update(|app|reader_a.update(app,|reader,cx|reader.tail(true,Cancellation::default(),cx))).unwrap();
            let request=take(&fixture.host.pending,cx).await;answer(request,success(json!({"events":[],"nextOffset":0,"reset":true})),cx).await;
            let request=take(&fixture.host.pending,cx).await;assert_request(&request,&page());
            let joined=cx.update(|app|reader_a.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();
            // A FIFO foreground barrier lets this same-owner waiter enroll
            // while the already-started reset page remains suspended.
            cx.spawn(async |_|{}).await;
            answer(request,success(json!({"events":[{"kind":"agent","seq":3,"event":{"kind":"text","delta":"Replacement"}}],"nextOffset":80,"tailCursor":"tail80","cursor":"older2","hasEarlier":true})),cx).await;
            let reset=reset.await;assert!(reset.accepted && reset.restore_reading);assert!(joined.await);
            let cancelled=Cancellation::default();
            let earlier=cx.update(|app|reader_a.update(app,|reader,cx|reader.earlier(false,cancelled.clone(),cx))).unwrap();
            let request=take(&fixture.host.pending,cx).await;cancelled.cancel();
            let revision_b=cx.update(|app|reader_b.read(app).window().events_revision()).unwrap();
            let noop=cx.update(|app|reader_b.update(app,|reader,cx|reader.tail(true,Cancellation::default(),cx))).unwrap();
            let other=take(&fixture.host.pending,cx).await;answer(other,success(json!({"events":[],"nextOffset":50,"tailCursor":"rotated"})),cx).await;assert!(noop.await.accepted);
            cx.update(|app| {assert!(reader_a.read(app).window().loading_earlier());assert_eq!(reader_b.read(app).window().events_revision(),revision_b);assert_eq!(reader_b.read(app).window().tail_cursor(),Some("rotated"));assert_eq!(notifications.get(),0);}).unwrap();
            answer(request,json!({"ok":false,"error":{"code":"unknown_method","message":"cancelled earlier failure"}}),cx).await;
            assert!(!earlier.await.accepted);
            cx.update(|app| {let window=reader_a.read(app).window();assert!(!window.loading_earlier());assert!(!window.paging_unavailable());assert_eq!(window.events()[0].seq,Some(3));}).unwrap();

            let old=cx.update(|app|reader_a.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();let old_request=take(&fixture.host.pending,cx).await;
            let new=cx.update(|app|reader_a.update(app,|reader,cx| {
                let mut chat=reader.window().selected().unwrap().clone();chat.id="chat-two".into();reader.set_selection(fixture.owner.clone(),"remote:peer:folder",Some(chat),false,cx);reader.open(false,Cancellation::default(),cx)
            })).unwrap();
            let new_request=take(&fixture.host.pending,cx).await;
            answer(old_request,success(json!({"events":[],"nextOffset":0})),cx).await;assert!(!old.await);
            cx.update(|app|assert!(reader_a.read(app).window().opening())).unwrap();
            answer(new_request,success(json!({"events":[{"kind":"agent","seq":4,"event":{"kind":"text","delta":"New selection"}}],"nextOffset":1})),cx).await;assert!(new.await);
            let (a,b)=cx.update(|app| {
                reader_b.update(app,|reader,cx| {let mut chat=reader.window().selected().unwrap().clone();chat.id="chat-two".into();reader.set_selection(fixture.owner.clone(),"remote:peer:folder",Some(chat),false,cx);});
                (reader_a.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx)),reader_b.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx)))
            }).unwrap();
            let request=take(&fixture.host.pending,cx).await;let weak=reader_a.downgrade();drop(reader_a);
            assert!(weak.upgrade().is_some(),"started reader lost the original retained self");
            answer(request,success(json!({"events":[],"nextOffset":0})),cx).await;assert!(a.await && b.await);
            until(||weak.upgrade().is_none(),cx).await;

            let legacy=cx.update(|app| {
                let reader=app.new(|cx|Reader::new(fixture.host.client.clone(),fixture.epoch.clone(),|scope,_|scope==&Scope::local("synthetic"),cx));
                reader.update(app,|reader,cx|reader.set_selection(fixture.owner.clone(),"remote:peer:folder",Some(serde_json::from_value(json!({"id":"legacy","workspaceId":"folder","title":"Legacy","backend":"codex"})).unwrap()),false,cx));reader
            }).unwrap();
            let opened=cx.update(|app|legacy.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();
            let request=take(&fixture.host.pending,cx).await;answer(request,json!({"ok":false,"error":{"code":"unknown_method","message":"unknown chat.eventPage"}}),cx).await;
            let request=take(&fixture.host.pending,cx).await;assert_eq!(request.request["params"]["method"],"chat.events");assert_eq!(request.request["params"]["params"]["offset"],0);
            answer(request,success(json!({"events":[],"nextOffset":0,"reset":true})),cx).await;assert!(!opened.await);
            let recovered=cx.update(|app|legacy.update(app,|reader,cx|reader.tail(true,Cancellation::default(),cx))).unwrap();
            let request=take(&fixture.host.pending,cx).await;assert_eq!(request.request["params"]["method"],"chat.events");
            answer(request,success(json!({"events":[{"kind":"agent","seq":9,"event":{"kind":"text","delta":"Recovered"}}],"nextOffset":1})),cx).await;assert!(recovered.await.accepted);
            cx.update(|app| {let window=legacy.read(app).window();assert!(window.live_loaded() && window.paging_unavailable() && !window.opening());assert_eq!(window.events()[0].seq,Some(9));}).unwrap();
            drop(legacy);drop(reader_b);

            let allowed=Rc::new(Cell::new(true));let reading=allowed.clone();
            let scoped=cx.update(|app| {
                let reader=app.new(|cx|Reader::new(fixture.host.client.clone(),fixture.epoch.clone(),move |scope,_|reading.get() && scope==&Scope::local("synthetic"),cx));
                reader.update(app,|reader,cx|reader.set_selection(fixture.owner.clone(),"remote:peer:folder",Some(serde_json::from_value(json!({"id":"scoped","workspaceId":"folder","title":"Scoped","backend":"codex"})).unwrap()),false,cx));reader
            }).unwrap();
            let opened=cx.update(|app|scoped.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();
            let request=take(&fixture.host.pending,cx).await;allowed.set(false);
            answer(request,success(json!({"events":[{"kind":"agent","seq":1,"event":{"kind":"text","delta":"Retired private fixture"}}],"nextOffset":1})),cx).await;
            assert!(!opened.await);
            cx.update(|app| {let window=scoped.read(app).window();assert!(window.events().is_empty() && window.rows().is_empty() && window.error().is_none() && !window.opening());}).unwrap();drop(scoped);

            // Awaited cancellation finishes at its own producer, not at the
            // next unrelated callback, and precedes mutation retry/failure.
            let active=Rc::new(Cell::new(true));let current=active.clone();
            let mut cancelled=Box::pin(transport::read_async(fixture.request(page()),first.entity_id(),move |_|current.get(),cx));
            let mut live=Box::pin(transport::read_async(fixture.request(page()),second.entity_id(),|_|true,cx));
            assert_pending(cancelled.as_mut());assert_pending(live.as_mut());
            let old=take(&fixture.host.pending,cx).await;assert_request(&old,&page());
            let mut deferred=Window::default();
            deferred.select(fixture.owner.clone(),"remote:peer:folder",Some(serde_json::from_value(json!({"id":"chat","workspaceId":"folder","title":"Synthetic","backend":"codex"})).unwrap()),false);
            let deferred_read=deferred.begin_open(false).unwrap();
            active.set(false);
            let directory=Query::directory("remote:peer:folder");
            let mut other=Box::pin(transport::read_async(fixture.request(directory.clone()),second.entity_id(),|_|true,cx));
            assert_pending(other.as_mut());let request=take(&fixture.host.pending,cx).await;assert_request(&request,&directory);
            answer(request,success(json!([])),cx).await;assert!(matches!(other.await,Ok(Reply::Directory(_))));
            assert_pending(cancelled.as_mut());assert!(deferred.opening());
            cx.update(|app|transport::invalidate(&fixture.owner,"remote:peer:folder",app)).unwrap();
            let mut successor=Box::pin(transport::read_async(fixture.request(page()),first.entity_id(),|_|true,cx));
            assert_pending(successor.as_mut());let next=take(&fixture.host.pending,cx).await;
            answer(old,json!({"ok":false,"error":{"code":"unknown_method","message":"discarded cancelled refusal"}}),cx).await;
            assert!(matches!(cancelled.await,Err(transport::ReadError::Cancelled)));
            deferred.cancel_read(&deferred_read);assert!(!deferred.opening());assert!(!deferred.paging_unavailable());
            assert_pending(live.as_mut());assert_pending(successor.as_mut());
            answer(next,success(json!({"events":[],"nextOffset":50})),cx).await;
            let (Ok(Reply::Page(a)),Ok(Reply::Page(b)))=(live.await,successor.await) else {panic!("async shared retry changed type")};
            assert!(Arc::ptr_eq(&a,&b));

            // Releasing a view retires its async lease while a same-entity
            // successor and the other window still share the original IO.
            let mut retired=Box::pin(transport::read_async(fixture.request(page()),first.entity_id(),|_|true,cx));
            let mut live=Box::pin(transport::read_async(fixture.request(page()),second.entity_id(),|_|true,cx));
            assert_pending(retired.as_mut());assert_pending(live.as_mut());let request=take(&fixture.host.pending,cx).await;
            cx.update(|app|transport::release_entity(first.entity_id(),app)).unwrap();
            assert_pending(retired.as_mut());
            let mut successor=Box::pin(transport::read_async(fixture.request(page()),first.entity_id(),|_|true,cx));assert_pending(successor.as_mut());
            answer(request,success(json!({"events":[],"nextOffset":50})),cx).await;
            assert!(matches!(retired.await,Err(transport::ReadError::Cancelled)));
            let (Ok(Reply::Page(a)),Ok(Reply::Page(b)))=(live.await,successor.await) else {panic!("view release cancelled successor")};
            assert!(Arc::ptr_eq(&a,&b));

            // Account/helper retirement also waits for its own response;
            // unrelated reads belonging to the new owner cannot finish it.
            let mut retired=Box::pin(transport::read_async(fixture.request(page()),first.entity_id(),|_|true,cx));assert_pending(retired.as_mut());
            let active=Rc::new(Cell::new(true));let current=active.clone();
            let mut cancelled_scope=Box::pin(transport::read_async(fixture.request(page()),second.entity_id(),move |_|current.get(),cx));assert_pending(cancelled_scope.as_mut());
            let old=take(&fixture.host.pending,cx).await;fixture.epoch.store(2,Ordering::Release);active.set(false);
            let mut fresh=fixture.request(directory);fresh.owner.generation=2;
            let mut fresh=Box::pin(transport::read_async(fresh,second.entity_id(),|_|true,cx));assert_pending(fresh.as_mut());
            let request=take(&fixture.host.pending,cx).await;answer(request,success(json!([])),cx).await;assert!(fresh.await.is_ok());assert_pending(retired.as_mut());assert_pending(cancelled_scope.as_mut());
            answer(old,success(json!({"events":[],"nextOffset":50})),cx).await;
            assert!(matches!(retired.await,Err(transport::ReadError::OwnerChanged)));
            assert!(matches!(cancelled_scope.await,Err(transport::ReadError::Cancelled)));
            assert!(matches!(transport::read_async(fixture.request(page()),first.entity_id(),|_|true,cx).await,Err(transport::ReadError::OwnerChanged)));
            cx.update(|app| {
                assert!(transport::read(fixture.request(page()),Consumer::new(first.entity_id(),|_|true,|_,_|panic!("retired owner delivered")),app).is_none());
            }).unwrap();
            // Same reading scope, new helper generation: keep verified rows,
            // let the old opening reach its own producer, and use the new
            // bridge owner for the original whole-history fallback.
            let mut owner=fixture.owner.clone();owner.generation=2;
            let reader=cx.update(|app| {
                let reader=app.new(|cx|Reader::new(fixture.host.client.clone(),fixture.epoch.clone(),|scope,_|scope==&Scope::local("synthetic"),cx));
                reader.update(app,|reader,cx|reader.set_selection(owner.clone(),"remote:peer:folder",Some(serde_json::from_value(json!({"id":"helper","workspaceId":"folder","title":"Before restart","backend":"codex"})).unwrap()),false,cx));reader
            }).unwrap();
            let initial=cx.update(|app|reader.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();
            let request=take(&fixture.host.pending,cx).await;
            answer(request,success(json!({"events":[{"kind":"agent","seq":10,"event":{"kind":"text","delta":"Verified"}}],"nextOffset":10})),cx).await;assert!(initial.await);
            let reopening=cx.update(|app|reader.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();
            let old=take(&fixture.host.pending,cx).await;fixture.epoch.store(3,Ordering::Release);owner.generation=3;
            answer(old,success(json!({"events":[],"nextOffset":0})),cx).await;
            let fallback=take(&fixture.host.pending,cx).await;
            assert_eq!(fallback.request["params"]["method"],"chat.events");assert_eq!(fallback.request["params"]["params"]["offset"],0);
            cx.update(|app|reader.update(app,|reader,cx| {
                assert!(reader.adopt_helper(&owner,cx));assert_eq!(reader.window().events()[0].seq,Some(10));assert!(reader.window().opening());
                let mut metadata=reader.window().selected().unwrap().clone();metadata.title="After restart".into();
                let mut other_local_identity=owner.clone();other_local_identity.local_host_identity="replacement-local-host".into();
                assert!(reader.adopt_helper(&other_local_identity,cx));
                assert!(reader.update_metadata(&other_local_identity,"remote:peer:folder",metadata.clone(),cx));
                assert!(!reader.update_metadata(&other_local_identity,"remote:other-peer:folder",metadata.clone(),cx));
                let mut stale=other_local_identity.clone();stale.generation=2;
                assert!(!reader.adopt_helper(&stale,cx));assert!(!reader.update_metadata(&stale,"remote:peer:folder",metadata,cx));
                let mut wrong=owner.clone();wrong.scope=Scope::local("other");assert!(!reader.adopt_helper(&wrong,cx));
            })).unwrap();
            // A local conversation still requires its captured local host:
            // same account alone cannot establish that it is the same work.
            let local=cx.update(|app| {
                let local=app.new(|cx|Reader::new(fixture.host.client.clone(),fixture.epoch.clone(),|scope,_|scope==&Scope::local("synthetic"),cx));
                local.update(app,|reader,cx| {
                    reader.set_selection(owner.clone(),"local-folder",Some(serde_json::from_value(json!({"id":"local","workspaceId":"local-folder","title":"Local","backend":"codex"})).unwrap()),false,cx);
                    assert!(reader.adopt_helper(&owner,cx));
                    let mut other=owner.clone();other.local_host_identity="replacement-local-host".into();
                    assert!(!reader.adopt_helper(&other,cx));
                    let mut metadata=reader.window().selected().unwrap().clone();metadata.title="Wrong host".into();
                    assert!(!reader.update_metadata(&other,"local-folder",metadata,cx));
                    assert_eq!(reader.window().selected().unwrap().title,"Local");
                });local
            }).unwrap();drop(local);
            answer(fallback,success(json!({"events":[{"kind":"agent","seq":11,"event":{"kind":"text","delta":"Recovered"}}],"nextOffset":11})),cx).await;
            assert!(reopening.await);cx.update(|app| {let window=reader.read(app).window();assert_eq!(window.events()[0].seq,Some(11));assert_eq!(window.selected().unwrap().title,"After restart");assert!(!window.opening());}).unwrap();
            // A second generation change during a quiet whole fallback must
            // finish without a banner, preserve rows and allow the next tail.
            let repeated=cx.update(|app|reader.update(app,|reader,cx|reader.open(true,Cancellation::default(),cx))).unwrap();
            let old=take(&fixture.host.pending,cx).await;fixture.epoch.store(4,Ordering::Release);
            answer(old,success(json!({"events":[],"nextOffset":0})),cx).await;
            let fallback=take(&fixture.host.pending,cx).await;assert_eq!(fallback.request["params"]["method"],"chat.events");
            fixture.epoch.store(5,Ordering::Release);answer(fallback,success(json!({"events":[],"nextOffset":0})),cx).await;assert!(!repeated.await);
            owner.generation=5;cx.update(|app|reader.update(app,|reader,cx| {assert!(reader.adopt_helper(&owner,cx));let window=reader.window();assert_eq!(window.events()[0].seq,Some(11));assert!(window.error().is_none() && !window.opening());})).unwrap();
            let tail=cx.update(|app|reader.update(app,|reader,cx|reader.tail(true,Cancellation::default(),cx))).unwrap();
            let next=take(&fixture.host.pending,cx).await;answer(next,success(json!({"events":[{"kind":"agent","seq":12,"event":{"kind":"text","delta":"Tail"}}],"nextOffset":12})),cx).await;assert!(tail.await.accepted);
            let opening=cx.update(|app|reader.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();
            let next=take(&fixture.host.pending,cx).await;answer(next,success(json!({"events":[{"kind":"agent","seq":12,"event":{"kind":"text","delta":"Tail"}}],"nextOffset":12,"cursor":"before","hasEarlier":true})),cx).await;assert!(opening.await);
            let earlier=cx.update(|app|reader.update(app,|reader,cx|reader.earlier(false,Cancellation::default(),cx))).unwrap();
            let old=take(&fixture.host.pending,cx).await;fixture.epoch.store(6,Ordering::Release);answer(old,success(json!({"events":[],"nextOffset":0})),cx).await;assert!(!earlier.await.accepted);
            owner.generation=6;cx.update(|app|reader.update(app,|reader,cx| {assert!(reader.adopt_helper(&owner,cx));let window=reader.window();assert!(!window.loading_earlier() && !window.paging_unavailable());assert_eq!(window.events()[0].seq,Some(12));})).unwrap();
            let earlier=cx.update(|app|reader.update(app,|reader,cx|reader.earlier(false,Cancellation::default(),cx))).unwrap();
            let next=take(&fixture.host.pending,cx).await;answer(next,success(json!({"events":[{"kind":"agent","seq":11,"event":{"kind":"text","delta":"Older"}}],"nextOffset":11,"hasEarlier":false})),cx).await;assert!(earlier.await.accepted);
            let cancelled=cx.update(|app|reader.update(app,|reader,cx|reader.open(false,Cancellation::default(),cx))).unwrap();
            let old=take(&fixture.host.pending,cx).await;fixture.epoch.store(7,Ordering::Release);
            cx.update(|app|reader.update(app,|reader,_|reader.cancel_opening())).unwrap();
            answer(old,success(json!({"events":[],"nextOffset":0})),cx).await;assert!(!cancelled.await);
            cx.update(|app| {let window=reader.read(app).window();assert_eq!(window.events().iter().filter_map(|event|event.seq).collect::<Vec<_>>(),[11,12]);assert!(!window.opening());}).unwrap();
            assert!(fixture.host.pending.lock().unwrap().try_recv().is_err());drop(reader);
            assert_eq!(std::thread::current().id(),foreground);
            println!("{}",json!({"deferredMountedRead":true,"deferredRetiredBeforeAdmission":true,"sharedPages":true,"immutableReplies":true,"windowIsolation":true,"rawRowsAtomic":true,"codedRefusal":true,"bothInvalidationBranches":true,"sameDomainReadTypes":3,"cancelledWaiter":true,"successorSlot":true,"batchedLeaseCancellation":true,"batchedEntityRelease":true,"noCompletedCache":true,"retiredBeforeIo":true,"deferredRetirement":true,"ownProducerBoundary":true,"cancelBeforeRetry":true,"scopeRetirement":true,"asyncSharedReplies":true,"asyncViewRelease":true,"retainedReaders":true,"readerMetadataObserver":true,"readerReadOverlap":true,"readerResetOpeningShare":true,"readerDeferredCleanup":true,"readerSelectionFence":true,"readerOwnerLifetime":true,"readerNoopInvalidation":true,"readerLegacyFallback":true,"readerReadingScope":true,"readerHelperFallback":true,"readerHostIdentity":true,"foregroundResume":true,"windowsOpened":0,"productionHostOrStoreOpened":false}));
            drop(fixture);
            cx.update(|app| app.quit()).unwrap();
        }).detach();
    });
}
