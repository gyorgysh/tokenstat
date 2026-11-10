// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Retained GPUI live-timeline transactions: shared opening, awaited transport,
//! serial CPU projection and selected-metadata observation. The complete
//! ChatModel load/reveal/cache/composer/status/approval/view owners remain above
//! this layer; constructing it or replacing selection starts no IO or polling.
//! Full ChatModel helper adoption and its secondary owners remain above this
//! layer. A same-scope opening can fall back under the current bridge owner.

use super::{
    Conversation,
    directory::Owner,
    paging::{
        Completion, Read, ReadKind, Window,
        publication::{Step, Ticket},
    },
    polling::{Cancellation, Joined, LocalFuture, Opening, Runtime},
    projector::Lane,
    query::Reply,
    transport::{self, ReadError, Request},
};
use crate::{
    client::Client,
    work::{Scope, destination, text},
};
use gpui::{App, AsyncApp, Context, Task, WeakEntity};
use std::{
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
type ReadingScope = Rc<dyn Fn(&Scope, &App) -> bool>;

#[derive(Clone)]
struct Session {
    owner: Owner,
    folder: String,
    id: String,
    generation: u64,
}
impl Session {
    fn capture(window: &Window) -> Option<Self> {
        Some(Self {
            owner: window.owner()?.clone(),
            folder: window.folder()?.into(),
            id: window.selected()?.id.clone(),
            generation: window.selection_generation(),
        })
    }
    fn matches(&self, window: &Window) -> bool {
        window.owner() == Some(&self.owner)
            && window.selection_generation() == self.generation
            && window
                .folder()
                .is_some_and(|folder| text::equal(folder, &self.folder))
            && window
                .selected()
                .is_some_and(|chat| text::equal(&chat.id, &self.id))
    }
}
#[derive(Clone)]
struct Services {
    client: Client,
    epoch: Arc<AtomicU64>,
    lane: Lane,
    opening: Opening<u64>,
    reading_scope: ReadingScope,
}
struct Metadata {
    id: u64,
    ticket: Option<Ticket>,
    _task: Task<()>,
}

/// Progress and display invalidation only. A rotating no-op tail cursor does
/// not notify the view or rebuild its transcript, as in the original model.
#[derive(PartialEq)]
struct Stamp {
    events: u64,
    display: u64,
    opening: bool,
    earlier: bool,
    context: Option<u64>,
    error: Option<String>,
}
impl Stamp {
    fn read(window: &Window) -> Self {
        Self {
            events: window.events_revision(),
            display: window.display_revision(),
            opening: window.opening(),
            earlier: window.loading_earlier(),
            context: window.context_revision(),
            error: window.error().map(str::to_owned),
        }
    }
}
fn change<T>(
    reader: &mut Reader,
    cx: &mut Context<Reader>,
    operation: impl FnOnce(&mut Window) -> T,
) -> T {
    let before = Stamp::read(&reader.window);
    let result = operation(&mut reader.window);
    if before != Stamp::read(&reader.window) {
        cx.notify();
    }
    result
}

pub struct Reader {
    window: Window,
    services: Services,
    metadata: Option<Metadata>,
    next_metadata: u64,
}
impl Reader {
    /// The reading-scope provider is the original global continuity-scope
    /// guard, independent of transport/helper generation. It must read only
    /// global ownership, not borrow this same reader entity.
    pub fn new(
        client: Client,
        epoch: Arc<AtomicU64>,
        reading_scope: impl Fn(&Scope, &App) -> bool + 'static,
        cx: &mut Context<Self>,
    ) -> Self {
        let entity = cx.entity_id();
        cx.on_release(move |reader: &mut Self, app| {
            reader.services.opening.cancel();
            reader.cancel_metadata();
            transport::release_entity(entity, app);
        })
        .detach();
        Self {
            window: Window::default(),
            services: Services {
                client,
                epoch,
                lane: Lane::background(cx.background_executor().clone()),
                opening: Opening::new(Runtime::gpui(cx)),
                reading_scope: Rc::new(reading_scope),
            },
            metadata: None,
            next_metadata: 0,
        }
    }
    pub fn window(&self) -> &Window {
        &self.window
    }
    /// Transport generations do not own the selected conversation or its
    /// verified rows. A remote folder is owned by its peer, not the identity
    /// of the local helper used to reach it. The full model still owns
    /// load/reveal/secondary cleanup.
    pub fn adopt_helper(&self, owner: &Owner, app: &App) -> bool {
        self.window.owner().is_some_and(|current| {
            current.scope == owner.scope
                && self.window.folder().is_some_and(|folder| {
                    destination::route(folder, None).peer.is_some()
                        || text::equal(&current.local_host_identity, &owner.local_host_identity)
                })
                && self.services.epoch.load(Ordering::Acquire) == owner.generation
                && (self.services.reading_scope)(&owner.scope, app)
        })
    }
    fn session_current(&self, session: &Session, app: &App) -> bool {
        session.matches(&self.window) && (self.services.reading_scope)(&session.owner.scope, app)
    }
    /// Only a real selection replacement belongs here. Same-folder helper
    /// adoption/load/reveal and warm-row restoration need their full model
    /// owner; calling this with a new helper is not that adoption operation.
    pub fn set_selection(
        &mut self,
        owner: Owner,
        folder: &str,
        chat: Option<Conversation>,
        fresh: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        if !(self.services.reading_scope)(&owner.scope, cx) {
            return false;
        }
        let changed = change(self, cx, |window| window.select(owner, folder, chat, fresh));
        if changed {
            self.services.opening.cancel();
            self.cancel_metadata();
            transport::release_entity(cx.entity_id(), cx);
        }
        changed
    }
    pub fn retire(&mut self, cx: &mut Context<Self>) {
        self.services.opening.cancel();
        self.cancel_metadata();
        transport::release_entity(cx.entity_id(), cx);
        change(self, cx, Window::retire);
    }
    pub fn cancel_opening(&self) {
        self.services.opening.cancel();
    }
    pub fn open(&self, quiet: bool, caller: Cancellation, cx: &mut Context<Self>) -> Task<bool> {
        let Some(session) = Session::capture(&self.window) else {
            return Task::ready(false);
        };
        let services = self.services.clone();
        cx.spawn(async move |reader, cx| {
            open_shared(
                reader,
                session,
                services,
                quiet,
                caller.is_cancelled(),
                cx.clone(),
            )
            .await
        })
    }
    pub fn earlier(
        &self,
        quiet: bool,
        caller: Cancellation,
        cx: &mut Context<Self>,
    ) -> Joined<Completion> {
        let value = super::polling::shared::Value::new();
        let joined = value.join();
        let Some(session) = Session::capture(&self.window) else {
            value.resolve(Completion::default());
            return joined;
        };
        let services = self.services.clone();
        cx.spawn(async move |reader, cx| {
            let result = async {
                let Some(_held) = reader.upgrade() else {
                    return Completion::default();
                };
                if caller.is_cancelled() {
                    return Completion::default();
                }
                let read = reader
                    .update(cx, |reader, cx| {
                        if !reader.session_current(&session, cx) {
                            return None;
                        }
                        change(reader, cx, |window| window.begin_earlier(quiet))
                    })
                    .ok()
                    .flatten();
                match read {
                    Some(read) => {
                        transaction(reader, session, services, read, caller, cx.clone()).await
                    }
                    None => Completion::default(),
                }
            }
            .await;
            value.resolve(result);
        })
        .detach();
        joined
    }
    pub fn tail(
        &self,
        quiet: bool,
        caller: Cancellation,
        cx: &mut Context<Self>,
    ) -> Joined<Completion> {
        let value = super::polling::shared::Value::new();
        let joined = value.join();
        let Some(session) = Session::capture(&self.window) else {
            value.resolve(Completion::default());
            return joined;
        };
        let services = self.services.clone();
        cx.spawn(async move |reader, cx| {
            let result = async {
                let Some(_held) = reader.upgrade() else {
                    return Completion::default();
                };
                if caller.is_cancelled() {
                    return Completion::default();
                }
                let loaded = reader
                    .update(cx, |reader, cx| {
                        reader
                            .session_current(&session, cx)
                            .then(|| reader.window.live_loaded())
                    })
                    .ok()
                    .flatten();
                let Some(loaded) = loaded else {
                    return Completion::default();
                };
                if !loaded {
                    return Completion {
                        accepted: open_shared(
                            reader,
                            session,
                            services,
                            quiet,
                            caller.is_cancelled(),
                            cx.clone(),
                        )
                        .await,
                        ..Completion::default()
                    };
                }
                let read = reader
                    .update(cx, |reader, cx| {
                        change(reader, cx, |window| window.begin_tail(quiet))
                    })
                    .ok()
                    .flatten();
                match read {
                    Some(read) => {
                        transaction(reader, session, services, read, caller, cx.clone()).await
                    }
                    None => Completion::default(),
                }
            }
            .await;
            value.resolve(result);
        })
        .detach();
        joined
    }
    /// The source selected observer reacts only to backend/running changes;
    /// title/setup metadata alone cannot acknowledge displayed send context.
    pub fn update_metadata(
        &mut self,
        owner: &Owner,
        folder: &str,
        chat: Conversation,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.adopt_helper(owner, cx) {
            return false;
        }
        let model_owner = self.window.owner().cloned().expect("validated model owner");
        let display = self.window.selected().is_some_and(|old| {
            !text::equal(&old.backend, &chat.backend) || old.running != chat.running
        });
        if !self.window.update_metadata(&model_owner, folder, chat) {
            return false;
        }
        cx.notify();
        if display {
            self.refresh_metadata(cx);
        }
        true
    }
    fn cancel_metadata(&mut self) {
        if let Some(previous) = self.metadata.take()
            && let Some(ticket) = previous.ticket
        {
            self.window.cancel_projection(ticket);
        }
    }
    fn refresh_metadata(&mut self, cx: &mut Context<Self>) {
        self.cancel_metadata();
        if self.window.events().is_empty() {
            return;
        }
        let Some(session) = Session::capture(&self.window) else {
            return;
        };
        self.next_metadata = self.next_metadata.wrapping_add(1);
        let id = self.next_metadata;
        let lane = self.services.lane.clone();
        let task = cx.spawn(async move |reader, cx| {
            let Some(_held) = reader.upgrade() else {
                return;
            };
            let work = reader
                .update(cx, |reader, cx| {
                    if !reader.session_current(&session, cx)
                        || reader.metadata.as_ref().is_none_or(|value| value.id != id)
                    {
                        return None;
                    }
                    let work = reader.window.prepare_metadata_task()?;
                    reader.metadata.as_mut()?.ticket = Some(work.ticket());
                    Some(work)
                })
                .ok()
                .flatten();
            let Some(work) = work else { return };
            publish(
                &reader,
                &session,
                &lane,
                Step::Project(work),
                &Cancellation::default(),
                cx,
            )
            .await;
            let _ = reader.update(cx, |reader, _| {
                if reader.metadata.as_ref().is_some_and(|value| value.id == id) {
                    reader.metadata = None;
                }
            });
        });
        self.metadata = Some(Metadata {
            id,
            ticket: None,
            _task: task,
        });
    }
}

fn current(
    reader: &WeakEntity<Reader>,
    session: &Session,
    cancel: &Cancellation,
    app: &App,
) -> bool {
    !cancel.is_cancelled()
        && reader
            .upgrade()
            .is_some_and(|reader| reader.read(app).session_current(session, app))
}
fn open_shared(
    reader: WeakEntity<Reader>,
    session: Session,
    services: Services,
    quiet: bool,
    caller_cancelled: bool,
    mut cx: AsyncApp,
) -> LocalFuture<bool> {
    Box::pin(async move {
        let opening = services.opening.clone();
        opening
            .run(session.generation, caller_cancelled, move |cancel| {
                Box::pin(async move {
                    let Some(_held) = reader.upgrade() else {
                        return false;
                    };
                    let read = reader
                        .update(&mut cx, |reader, cx| {
                            if cancel.is_cancelled() || !reader.session_current(&session, cx) {
                                return None;
                            }
                            change(reader, cx, |window| window.begin_open(quiet))
                        })
                        .ok()
                        .flatten();
                    match read {
                        Some(read) => {
                            transaction(reader, session, services, read, cancel, cx)
                                .await
                                .accepted
                        }
                        None => false,
                    }
                })
            })
            .await
    })
}

async fn transaction(
    reader: WeakEntity<Reader>,
    session: Session,
    services: Services,
    mut read: Read,
    cancel: Cancellation,
    mut cx: AsyncApp,
) -> Completion {
    loop {
        let target = reader.clone();
        let captured = session.clone();
        let cancelled = cancel.clone();
        let mut bridge_owner = read.owner.clone();
        bridge_owner.generation = services.epoch.load(Ordering::Acquire);
        let result = transport::read_async(
            Request {
                client: services.client.clone(),
                owner: bridge_owner,
                folder: read.folder.clone(),
                query: read.query(),
                epoch: services.epoch.clone(),
            },
            reader.entity_id(),
            move |app| current(&target, &captured, &cancelled, app),
            &cx,
        )
        .await;
        // Tail reset must enter the shared opening wrapper before allocating a
        // replacement. Otherwise another opening caller cannot join it.
        let reset =
            matches!(&result,Ok(Reply::Events(chunk)) if read.kind==ReadKind::Tail && chunk.reset);
        if reset {
            let valid = reader
                .update(&mut cx, |reader, cx| {
                    if cancel.is_cancelled()
                        || !reader.session_current(&session, cx)
                        || !reader.window.current(&read)
                    {
                        change(reader, cx, |window| window.cancel_read(&read));
                        false
                    } else {
                        true
                    }
                })
                .unwrap_or(false);
            if !valid {
                return Completion::default();
            }
            let accepted = open_shared(
                reader,
                session,
                services,
                read.quiet,
                cancel.is_cancelled(),
                cx,
            )
            .await;
            return Completion {
                accepted,
                restore_reading: accepted,
                ..Completion::default()
            };
        }
        let step = reader
            .update(&mut cx, |reader, cx| {
                if cancel.is_cancelled()
                    || !reader.session_current(&session, cx)
                    || matches!(result, Err(ReadError::Cancelled))
                {
                    change(reader, cx, |window| window.cancel_read(&read));
                    return Step::Complete(Completion::default());
                }
                change(reader, cx, |window| match result {
                    Ok(Reply::Page(page)) => window.receive_shared_page(&read, Ok(page)),
                    Ok(Reply::Events(chunk)) => window.receive_shared_chunk(&read, Ok(chunk)),
                    Ok(Reply::Directory(_)) => unreachable!("timeline query returned directory"),
                    Err(ReadError::Failed(error)) => {
                        let failure = super::paging::Failure::from_error(&error);
                        match read.kind {
                            ReadKind::Newest | ReadKind::Earlier => {
                                window.receive_shared_page(&read, Err(failure))
                            }
                            _ => window.receive_shared_chunk(&read, Err(failure)),
                        }
                    }
                    Err(ReadError::OwnerChanged) if read.kind == ReadKind::Newest => window
                        .receive_shared_page(
                            &read,
                            Err(super::paging::Failure {
                                message: String::new(),
                                unknown_method: false,
                            }),
                        ),
                    Err(ReadError::OwnerChanged) => {
                        window.cancel_read(&read);
                        Step::Complete(Completion::default())
                    }
                    Err(ReadError::Cancelled) => {
                        unreachable!("retired read passed its guard")
                    }
                })
            })
            .unwrap_or_else(|_| Step::Complete(Completion::default()));
        let mut done = publish(&reader, &session, &services.lane, step, &cancel, &mut cx).await;
        if let Some(next) = done.reopen.take() {
            read = next;
        } else {
            return done;
        }
    }
}

async fn publish(
    reader: &WeakEntity<Reader>,
    session: &Session,
    lane: &Lane,
    mut step: Step,
    cancel: &Cancellation,
    cx: &mut AsyncApp,
) -> Completion {
    loop {
        match step {
            Step::Complete(done) => return done,
            Step::Project(work) => {
                let ticket = work.ticket();
                let allowed = cx
                    .update(|app| current(reader, session, cancel, app))
                    .unwrap_or(false);
                if !allowed {
                    let _ = reader.update(cx, |reader, cx| {
                        change(reader, cx, |window| window.cancel_projection(ticket))
                    });
                    return Completion::default();
                }
                let result = lane.submit(work).await;
                step = reader
                    .update(cx, |reader, cx| {
                        if cancel.is_cancelled() || !reader.session_current(session, cx) {
                            change(reader, cx, |window| window.cancel_projection(ticket));
                            Step::Complete(Completion::default())
                        } else {
                            change(reader, cx, |window| window.finish_projection(result))
                        }
                    })
                    .unwrap_or_else(|_| Step::Complete(Completion::default()));
            }
        }
    }
}
