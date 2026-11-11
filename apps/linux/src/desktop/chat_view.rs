// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Initial live conversation reader. Composer and rich event controls remain
//! separate owners; the transcript retains its own follow and scroll state.

use super::{home_shared::HomeShared, *};
use crate::chat::{
    Conversation,
    polling::{Cancellation, WatchCancellation},
    reader::Reader,
    transcript::Kind,
};
use std::{collections::HashSet, sync::Arc};

#[derive(Clone, PartialEq, Eq)]
struct FoldKey {
    id: String,
    events: u64,
    display: u64,
    running: bool,
    detail: ChatDetail,
    toggles: u64,
}
struct ReadingAnchor {
    id: String,
    visual_top: gpui::Pixels,
    gesture: u64,
    ticket: u64,
    target_events: Option<u64>,
    scheduled: bool,
}
#[derive(Default)]
pub(super) struct ChatFold {
    id: Option<String>,
    open: HashSet<String>,
    groups_open: bool,
    toggles: u64,
    ticket: u64,
    requested: Option<FoldKey>,
    published: Option<FoldKey>,
    rows: Option<Arc<Vec<crate::chat::transcript::Row>>>,
    task: Option<gpui::Task<()>>,
    scroll: gpui::ScrollHandle,
    pinned: bool,
    gesture: u64,
    anchor_ticket: u64,
    anchor: Option<ReadingAnchor>,
    earlier_pending: bool,
    earlier_task: Option<gpui::Task<()>>,
    rendered_keys: Vec<Option<String>>,
}

pub(super) struct ChatWatch {
    reader: gpui::EntityId,
    id: String,
    cancellation: WatchCancellation,
    _task: gpui::Task<()>,
}
impl Drop for ChatWatch {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}

fn reading_lane(child: impl IntoElement) -> Div {
    div()
        .w_full()
        .flex()
        .justify_center()
        .child(div().w_full().max_w(px(720.)).child(child))
}

impl Desktop {
    pub(super) fn sync_chat_fold(&mut self, folder: &str, cx: &mut Context<Self>) {
        let Some(reader) = self.chat_readers.get(folder) else {
            return;
        };
        let window = reader.read(cx).window();
        let Some(chat) = window.selected() else {
            return;
        };
        let id = chat.id.clone();
        let events = window.events_revision();
        let display = window.display_revision();
        let running = chat.running;
        let rows = window.shared_rows();
        let reader_id = reader.entity_id();
        let state = self.chat_folds.entry(folder.to_owned()).or_default();
        if !state
            .id
            .as_ref()
            .is_some_and(|old| crate::work::text::equal(old, &id))
        {
            state.id = Some(id.clone());
            state.open.clear();
            state.groups_open = false;
            state.toggles = state.toggles.wrapping_add(1);
            state.rows = None;
            state.requested = None;
            state.published = None;
            state.task = None;
            state.scroll = gpui::ScrollHandle::new();
            state.pinned = true;
            state.gesture = state.gesture.wrapping_add(1);
            state.anchor_ticket = state.anchor_ticket.wrapping_add(1);
            state.anchor = None;
            state.earlier_pending = false;
            state.earlier_task = None;
            state.rendered_keys.clear();
        }
        let key = FoldKey {
            id,
            events,
            display,
            running,
            detail: self.detail,
            toggles: state.toggles,
        };
        if state.requested.as_ref() == Some(&key) {
            return;
        }
        state.requested = Some(key.clone());
        state.ticket = state.ticket.wrapping_add(1);
        let ticket = state.ticket;
        let open = state.open.clone();
        let groups_open = state.groups_open;
        let work_key = key.clone();
        let work = cx.background_executor().spawn(async move {
            crate::chat::transcript::fold::fold(&rows, work_key.detail, work_key.running, |id| {
                groups_open != open.iter().any(|value| crate::work::text::equal(value, id))
            })
        });
        let folder = folder.to_owned();
        let task_folder = folder.clone();
        let task = cx.spawn(async move |view, cx| {
            let rows = work.await;
            let _ = view.update(cx, |view, cx| {
                if !view
                    .chat_readers
                    .get(&task_folder)
                    .is_some_and(|reader| reader.entity_id() == reader_id)
                {
                    return;
                }
                if let Some(state) = view.chat_folds.get_mut(&task_folder)
                    && state.ticket == ticket
                    && state.requested.as_ref() == Some(&key)
                {
                    state.rows = Some(Arc::new(rows));
                    state.published = Some(key);
                    state.task = None;
                    if state.pinned && state.anchor.is_none() {
                        state.scroll.scroll_to_bottom();
                    }
                    cx.notify();
                }
            });
        });
        if let Some(state) = self.chat_folds.get_mut(&folder) {
            state.task = Some(task);
        }
    }

    fn toggle_chat_group(&mut self, folder: &str, id: &str, cx: &mut Context<Self>) {
        if let Some(state) = self.chat_folds.get_mut(folder) {
            if let Some(existing) = state
                .open
                .iter()
                .find(|value| crate::work::text::equal(value, id))
                .cloned()
            {
                state.open.remove(&existing);
            } else {
                state.open.insert(id.to_owned());
            }
            state.toggles = state.toggles.wrapping_add(1);
            self.sync_chat_fold(folder, cx);
        }
    }

    pub(super) fn toggle_chat_groups(&mut self, cx: &mut Context<Self>) {
        let Route::Workspace {
            id,
            section: WorkspaceSection::Chat,
        } = &self.navigation.route
        else {
            return;
        };
        if self.chat_overview
            || !self
                .selected_chat
                .as_ref()
                .is_some_and(|(folder, _)| crate::work::text::equal(folder, id))
        {
            return;
        }
        let folder = id.clone();
        if let Some(state) = self.chat_folds.get_mut(&folder) {
            state.groups_open = !(state.groups_open || !state.open.is_empty());
            state.open.clear();
            state.toggles = state.toggles.wrapping_add(1);
            self.sync_chat_fold(&folder, cx);
        }
    }
    pub(super) fn sync_chat_watch(&mut self, cx: &mut Context<Self>) {
        let candidate =
            if self.active && !self.chat_overview && !cx.global::<HomeShared>().quit_requested {
                match (&self.navigation.route, &self.selected_chat) {
                    (
                        Route::Workspace {
                            id: folder,
                            section: WorkspaceSection::Chat,
                        },
                        Some((selected_folder, id)),
                    ) if crate::work::text::equal(folder, selected_folder) => {
                        self.chat_readers.get(folder).and_then(|reader| {
                            reader
                                .read(cx)
                                .window()
                                .selected()
                                .filter(|chat| crate::work::text::equal(&chat.id, id))
                                .map(|_| (reader.clone(), id.clone()))
                        })
                    }
                    _ => None,
                }
            } else {
                None
            };
        if self.chat_watch.as_ref().is_some_and(|watch| {
            candidate.as_ref().is_some_and(|(reader, id)| {
                watch.reader == reader.entity_id() && crate::work::text::equal(&watch.id, id)
            })
        }) {
            return;
        }
        self.chat_watch = None;
        if let Some((reader, id)) = candidate {
            let weak = cx.weak_entity();
            let app = cx.to_async();
            let entity = reader.entity_id();
            let watched_id = id.clone();
            let watch = reader.update(cx, |reader, cx| {
                reader.watch_events_with_status(cx, move || {
                    let _ = app.update(|app| {
                        let _ = weak.update(app, |view, cx| {
                            if !view.active
                                || view.chat_overview
                                || cx.global::<HomeShared>().quit_requested
                                || !view.chat_watch.as_ref().is_some_and(|watch| {
                                    watch.reader == entity
                                        && crate::work::text::equal(&watch.id, &watched_id)
                                })
                            {
                                return;
                            }
                            let Route::Workspace {
                                id: folder,
                                section: WorkspaceSection::Chat,
                            } = &view.navigation.route
                            else {
                                return;
                            };
                            let folder = folder.clone();
                            if let Some(read) = view.chat_directory.begin(&folder) {
                                view.dispatch_chat_directory(read, cx);
                            }
                        });
                    });
                })
            });
            let Some(watch) = watch else { return };
            let cancellation = watch.cancellation();
            let task = cx.spawn(async move |_, _| watch.await);
            self.chat_watch = Some(ChatWatch {
                reader: reader.entity_id(),
                id,
                cancellation,
                _task: task,
            });
        }
    }

    pub(super) fn sync_selected_chat_reader(&mut self, cx: &mut Context<Self>) {
        let Some((folder, id)) = self.selected_chat.clone() else {
            return;
        };
        let chat = self
            .chat_directory
            .rows(&folder)
            .iter()
            .find(|chat| crate::work::text::equal(&chat.id, &id))
            .cloned();
        if let Some(chat) = chat {
            if let Some(reader) = self.chat_readers.get(&folder).cloned()
                && reader
                    .read(cx)
                    .window()
                    .selected()
                    .is_some_and(|selected| crate::work::text::equal(&selected.id, &id))
            {
                if reader.read(cx).window().selected() != Some(&chat)
                    && let Some(owner) = self.chat_directory.owner().cloned()
                {
                    reader.update(cx, |reader, cx| {
                        reader.update_metadata(&owner, &folder, chat, cx);
                    });
                }
            } else {
                self.open_chat_reader(&folder, chat, cx);
            }
        }
    }

    pub(super) fn open_chat_reader(
        &mut self,
        folder: &str,
        conversation: Conversation,
        cx: &mut Context<Self>,
    ) {
        let (Some(client), Some(owner)) =
            (self.client.clone(), self.chat_directory.owner().cloned())
        else {
            return;
        };
        let reader = if let Some(reader) = self.chat_readers.get(folder) {
            reader.clone()
        } else {
            let epoch = cx.global::<HomeShared>().transport_epoch.clone();
            let reader = cx.new(|cx| {
                Reader::new(
                    client,
                    epoch,
                    |scope, app| {
                        app.global::<HomeShared>().metadata.scope().as_ref() == Some(scope)
                    },
                    cx,
                )
            });
            let observed_folder = folder.to_owned();
            cx.observe(&reader, move |view, _, cx| {
                view.sync_chat_fold(&observed_folder, cx);
                cx.notify();
            })
            .detach();
            self.chat_readers.insert(folder.to_owned(), reader.clone());
            reader
        };
        reader.update(cx, |reader, cx| {
            let changed = reader.set_selection(owner, folder, Some(conversation), false, cx);
            if changed || !reader.window().live_loaded() {
                reader.open(false, Cancellation::default(), cx).detach();
            }
        });
        self.sync_chat_fold(folder, cx);
    }

    pub(super) fn chat_retry(&mut self, folder: &str, cx: &mut Context<Self>) {
        if let Some(reader) = self.chat_readers.get(folder) {
            reader.update(cx, |reader, cx| {
                reader.open(false, Cancellation::default(), cx).detach();
            });
        }
    }

    pub(super) fn chat_refresh(&mut self, folder: &str, cx: &mut Context<Self>) {
        let Some(reader) = self.chat_readers.get(folder).cloned() else {
            return;
        };
        let Some(id) = reader
            .read(cx)
            .window()
            .selected()
            .map(|chat| chat.id.clone())
        else {
            return;
        };
        let folder = folder.to_owned();
        cx.spawn(async move |_, cx| {
            loop {
                let joined = reader.update(cx, |reader, cx| {
                    let window = reader.window();
                    if !window
                        .folder()
                        .is_some_and(|value| crate::work::text::equal(value, &folder))
                        || !window
                            .selected()
                            .is_some_and(|chat| crate::work::text::equal(&chat.id, &id))
                    {
                        return None;
                    }
                    Some(reader.tail(false, Cancellation::default(), cx))
                });
                let Ok(Some(joined)) = joined else { break };
                if !joined.await.more_tail {
                    break;
                }
            }
        })
        .detach();
    }

    fn chat_earlier(&mut self, folder: &str, force: bool, cx: &mut Context<Self>) {
        if let Some(reader) = self.chat_readers.get(folder).cloned() {
            if !reader.read(cx).window().has_earlier() || reader.read(cx).window().loading_earlier()
            {
                return;
            }
            let ticket = self.chat_folds.get_mut(folder).and_then(|state| {
                if state.earlier_pending {
                    return None;
                }
                let first = state.scroll.top_item();
                let offset = state.scroll.offset();
                let viewport_top = state.scroll.bounds().top();
                let index = (first..state.rendered_keys.len()).find(|index| {
                    state.rendered_keys[*index].is_some()
                        && state
                            .scroll
                            .bounds_for_item(*index)
                            .is_some_and(|bounds| bounds.top() + offset.y >= viewport_top - px(1.))
                });
                if index.is_none() && !force {
                    return None;
                }
                state.earlier_pending = true;
                state.earlier_task = None;
                state.pinned = false;
                state.anchor_ticket = state.anchor_ticket.wrapping_add(1);
                state.anchor = None;
                let ticket = state.anchor_ticket;
                if let Some(index) = index
                    && let (Some(id), Some(bounds)) = (
                        state.rendered_keys[index].clone(),
                        state.scroll.bounds_for_item(index),
                    )
                {
                    state.anchor = Some(ReadingAnchor {
                        id,
                        visual_top: bounds.top() + offset.y,
                        gesture: state.gesture,
                        ticket,
                        target_events: None,
                        scheduled: false,
                    });
                }
                Some(ticket)
            });
            let Some(ticket) = ticket else { return };
            let joined = reader.update(cx, |reader, cx| {
                reader.earlier(false, Cancellation::default(), cx)
            });
            let folder = folder.to_owned();
            cx.spawn(async move |view, cx| {
                let completion = joined.await;
                let _ = view.update(cx, |view, cx| {
                    if !view
                        .chat_readers
                        .get(&folder)
                        .is_some_and(|current| current.entity_id() == reader.entity_id())
                    {
                        return;
                    }
                    let revision = reader.read(cx).window().events_revision();
                    if let Some(state) = view.chat_folds.get_mut(&folder)
                        && state.anchor_ticket == ticket
                    {
                        state.earlier_pending = false;
                        if completion.accepted
                            && let Some(anchor) = state.anchor.as_mut()
                        {
                            anchor.target_events = Some(revision);
                        } else if !completion.accepted {
                            state.anchor = None;
                        }
                        cx.notify();
                    }
                });
            })
            .detach();
        }
    }

    fn note_chat_scroll(&mut self, folder: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(reader_id) = self
            .chat_readers
            .get(folder)
            .map(|reader| reader.entity_id())
        else {
            return;
        };
        let Some(state) = self.chat_folds.get_mut(folder) else {
            return;
        };
        state.gesture = state.gesture.wrapping_add(1);
        state.anchor = None;
        state.earlier_task = None;
        let gesture = state.gesture;
        let folder = folder.to_owned();
        cx.on_next_frame(window, move |view, _, cx| {
            if !view.chat_readers.get(&folder).is_some_and(|reader| reader.entity_id() == reader_id) { return; }
            let Some(state) = view.chat_folds.get_mut(&folder) else {
                return;
            };
            if state.gesture != gesture {
                return;
            }
            let max = f32::from(state.scroll.max_offset().height).max(0.);
            let offset = state.scroll.offset();
            let clamped = f32::from(offset.y).clamp(-max, 0.);
            if clamped != f32::from(offset.y) {
                state.scroll.set_offset(point(offset.x, px(clamped)));
            }
            let distance = (max + clamped).clamp(0., max);
            let pinned = if distance <= 10. {
                true
            } else if distance > 56. {
                false
            } else {
                state.pinned
            };
            if state.pinned != pinned {
                state.pinned = pinned;
                cx.notify();
            }
            let near_top = !state.pinned && !state.earlier_pending
                && -clamped < f32::from(state.scroll.bounds().size.height) * 2.5;
            if near_top {
                let task_folder = folder.clone();
                let task = cx.spawn(async move |view, cx| {
                    cx.background_executor().timer(std::time::Duration::from_millis(180)).await;
                    let _ = view.update(cx, |view, cx| {
                        if view.active && !cx.global::<HomeShared>().quit_requested
                            && view.chat_readers.get(&task_folder).is_some_and(|reader| reader.entity_id() == reader_id)
                            && view.chat_folds.get(&task_folder).is_some_and(|state| state.gesture == gesture && !state.pinned && !state.earlier_pending)
                            && matches!(&view.navigation.route, Route::Workspace { id, section: WorkspaceSection::Chat } if crate::work::text::equal(id, &task_folder))
                            && !view.chat_overview
                        {
                            view.chat_earlier(&task_folder, false, cx);
                        }
                    });
                });
                if let Some(state) = view.chat_folds.get_mut(&folder) {
                    state.earlier_task = Some(task);
                }
            }
        });
    }

    fn chat_jump_to_latest(&mut self, folder: &str, cx: &mut Context<Self>) {
        if let Some(state) = self.chat_folds.get_mut(folder) {
            state.gesture = state.gesture.wrapping_add(1);
            state.anchor = None;
            state.earlier_task = None;
            state.pinned = true;
            state.scroll.scroll_to_bottom();
            cx.notify();
        }
    }

    pub(super) fn chat_content(
        &mut self,
        folder: &str,
        dark: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Div {
        let Some(reader) = self.chat_readers.get(folder).cloned() else {
            return div().p(px(24.)).child(text(
                "Conversation is unavailable.",
                FontToken {
                    points: 13.,
                    weight: 400,
                },
            ));
        };
        let reader_window = reader.read(cx).window();
        if !self.selected_chat.as_ref().is_some_and(|(_, id)| {
            reader_window
                .selected()
                .is_some_and(|chat| crate::work::text::equal(&chat.id, id))
        }) {
            return div();
        }
        let selected = reader_window.selected().unwrap();
        let chat_id = selected.id.clone();
        let shared = selected.team_share.is_some();
        let running = selected.running;
        let state = self.chat_folds.entry(folder.to_owned()).or_default();
        let scroll = state.scroll.clone();
        let pinned = state.pinned;
        let scroll_folder = folder.to_owned();
        let mut keys = vec![None];
        let mut lane = div()
            .id("chat-transcript-scroll")
            .w_full()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .gap(px(16.))
            .px(px(24.))
            .py(px(28.))
            .overflow_y_scroll()
            .track_scroll(&scroll)
            .on_scroll_wheel(cx.listener(
                move |view, event: &gpui::ScrollWheelEvent, window, cx| {
                    let delta = event.delta.pixel_delta(window.line_height()).y;
                    if delta == px(0.) {
                        return;
                    }
                    if delta > px(0.)
                        && let Some(state) = view.chat_folds.get_mut(&scroll_folder)
                    {
                        state.pinned = false;
                    }
                    view.note_chat_scroll(&scroll_folder, window, cx);
                },
            ))
            .child(div());
        if let Some(error) = reader_window.error() {
            let folder = folder.to_owned();
            keys.push(None);
            lane = lane.child(reading_lane(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(
                        text(
                            error.to_owned(),
                            FontToken {
                                points: 13.,
                                weight: 400,
                            },
                        )
                        .text_color(secondary(dark)),
                    )
                    .child(
                        div()
                            .id("chat-retry")
                            .cursor_pointer()
                            .on_click(
                                cx.listener(move |view, _, _, cx| view.chat_retry(&folder, cx)),
                            )
                            .child(
                                text(
                                    "Retry",
                                    FontToken {
                                        points: 13.,
                                        weight: 600,
                                    },
                                )
                                .text_color(palette::ACCENT.resolve(dark)),
                            ),
                    ),
            ));
        } else if reader_window.opening() && reader_window.rows().is_empty() {
            keys.push(None);
            lane = lane.child(reading_lane(
                text(
                    "Loading conversation…",
                    FontToken {
                        points: 13.,
                        weight: 400,
                    },
                )
                .text_color(secondary(dark)),
            ));
        } else if reader_window.live_loaded() && reader_window.rows().is_empty() {
            keys.push(None);
            lane = lane.child(reading_lane(
                text(
                    "No messages yet.",
                    FontToken {
                        points: 13.,
                        weight: 400,
                    },
                )
                .text_color(secondary(dark)),
            ));
        }
        if reader_window.has_earlier() {
            let folder = folder.to_owned();
            let loading = reader_window.loading_earlier();
            keys.push(None);
            lane = lane.child(reading_lane(
                div()
                    .min_h(px(30.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        div()
                            .id("chat-earlier")
                            .cursor_pointer()
                            .px(px(10.))
                            .py(px(5.))
                            .rounded(px(7.))
                            .bg(palette::PANEL.resolve(dark))
                            .on_click(cx.listener(move |view, _, _, cx| {
                                if !loading {
                                    view.chat_earlier(&folder, true, cx);
                                }
                            }))
                            .child(
                                text(
                                    l(if loading {
                                        "apple.transcriptfollow.loading_earlier_messages.41311657"
                                    } else {
                                        "apple.transcriptfollow.earlier_messages.561a197a"
                                    }),
                                    FontToken {
                                        points: 13.,
                                        weight: 500,
                                    },
                                )
                                .text_color(secondary(dark)),
                            ),
                    ),
            ));
        } else if reader_window.reached_start() {
            keys.push(None);
            let label = l(if reader_window.history_trimmed() {
                "apple.transcriptfollow.earlier_messages_are_no_longer_available.aae6a081"
            } else {
                "apple.transcriptfollow.start_of_chat.a7e744bb"
            });
            lane = lane.child(reading_lane(
                div()
                    .min_h(px(30.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(div().flex_1().h(px(1.)).bg(palette::BORDER.resolve(dark)))
                    .child(
                        text(
                            label,
                            FontToken {
                                points: 12.,
                                weight: 400,
                            },
                        )
                        .text_color(secondary(dark)),
                    )
                    .child(div().flex_1().h(px(1.)).bg(palette::BORDER.resolve(dark))),
            ));
        }
        let folded = self.chat_folds.get(folder).and_then(|state| {
            state
                .id
                .as_ref()
                .filter(|id| {
                    reader_window
                        .selected()
                        .is_some_and(|chat| crate::work::text::equal(id, &chat.id))
                })
                .and(state.rows.clone())
        });
        for row in folded
            .as_deref()
            .map_or_else(|| reader_window.rows(), Vec::as_slice)
        {
            keys.push(Some(row.id.clone()));
            let (label, body, user) = match &row.kind {
                Kind::User { text } => ("You".to_owned(), text.clone(), true),
                Kind::Assistant { text, backend } => (
                    backend.clone().unwrap_or_else(|| "Assistant".into()),
                    text.clone(),
                    false,
                ),
                Kind::Thinking { text } => ("Thinking".into(), text.clone(), false),
                Kind::Failed { text } => ("Error".into(), text.clone(), false),
                Kind::TurnSeparator { backend } => (backend.clone(), String::new(), false),
                Kind::Handoff { to, brief } => (format!("Handoff to {to}"), brief.clone(), false),
                Kind::Tool { state } => (state.verb.clone(), state.target.clone(), false),
                Kind::Edit { state } => ("Edited".into(), state.path.clone(), false),
                Kind::Attachment { file } => ("Attachment".into(), file.name.clone(), false),
                Kind::Approval { approval } => {
                    (approval.verb.clone(), approval.preview.clone(), false)
                }
                Kind::Usage { input, output, .. } => (
                    "Usage".into(),
                    format!("{input} input · {output} output"),
                    false,
                ),
                Kind::Group { group } => (
                    "Activity".into(),
                    group
                        .preview
                        .clone()
                        .unwrap_or_else(|| format!("{} steps", group.steps)),
                    false,
                ),
                Kind::Question { question } => {
                    ("Question".into(), question.question.clone(), false)
                }
                Kind::Changes { changes } => (
                    "Changes".into(),
                    format!("{} files", changes.files.len()),
                    false,
                ),
            };
            let mut card = div()
                .id(SharedString::from(format!("transcript-row-{}", row.id)))
                .w_full()
                .flex()
                .flex_col()
                .gap(px(5.))
                .when(user, |d| {
                    d.p(px(14.))
                        .rounded(px(12.))
                        .bg(palette::PANEL.resolve(dark))
                })
                .child(
                    text(
                        label,
                        FontToken {
                            points: 12.,
                            weight: 600,
                        },
                    )
                    .text_color(secondary(dark)),
                )
                .when(!body.is_empty(), |d| {
                    d.child(
                        text(
                            body,
                            FontToken {
                                points: 14.,
                                weight: 400,
                            },
                        )
                        .text_color(primary(dark)),
                    )
                });
            if let Kind::Group { group } = &row.kind {
                let folder = folder.to_owned();
                let id = row.id.clone();
                card = card
                    .cursor_pointer()
                    .on_click(
                        cx.listener(move |view, _, _, cx| view.toggle_chat_group(&folder, &id, cx)),
                    )
                    .child(
                        text(
                            if group.open {
                                "Hide details"
                            } else {
                                "Show details"
                            },
                            FontToken {
                                points: 12.,
                                weight: 500,
                            },
                        )
                        .text_color(palette::ACCENT.resolve(dark)),
                    );
            }
            lane = lane.child(reading_lane(card));
        }
        if let Some(state) = self.chat_folds.get_mut(folder) {
            state.rendered_keys = keys;
            let ready = state.anchor.as_ref().is_some_and(|anchor| {
                !anchor.scheduled
                    && anchor.target_events.is_some_and(|target| {
                        state
                            .published
                            .as_ref()
                            .is_some_and(|key| key.events >= target)
                    })
            });
            if ready {
                let anchor = state.anchor.as_mut().unwrap();
                anchor.scheduled = true;
                let ticket = anchor.ticket;
                let folder = folder.to_owned();
                let reader_id = reader.entity_id();
                cx.on_next_frame(window, move |view, _, cx| {
                    if !view
                        .chat_readers
                        .get(&folder)
                        .is_some_and(|reader| reader.entity_id() == reader_id)
                    {
                        return;
                    }
                    let Some(state) = view.chat_folds.get_mut(&folder) else {
                        return;
                    };
                    if !state.anchor.as_ref().is_some_and(|anchor| {
                        anchor.ticket == ticket && anchor.gesture == state.gesture
                    }) {
                        return;
                    }
                    let anchor = state.anchor.take().unwrap();
                    let Some(index) = state.rendered_keys.iter().position(|key| {
                        key.as_ref()
                            .is_some_and(|id| crate::work::text::equal(id, &anchor.id))
                    }) else {
                        return;
                    };
                    let Some(bounds) = state.scroll.bounds_for_item(index) else {
                        return;
                    };
                    let old = state.scroll.offset();
                    state
                        .scroll
                        .set_offset(point(old.x, anchor.visual_top - bounds.top()));
                    cx.notify();
                });
            }
        }
        let mut content = div()
            .relative()
            .w_full()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(lane);
        if !pinned {
            let folder = folder.to_owned();
            content = content.child(
                div()
                    .id("chat-jump-latest")
                    .absolute()
                    .bottom(px(18.))
                    .right(px(28.))
                    .px(px(12.))
                    .py(px(7.))
                    .rounded(px(9.))
                    .bg(palette::PANEL.resolve(dark))
                    .cursor_pointer()
                    .on_click(
                        cx.listener(move |view, _, _, cx| view.chat_jump_to_latest(&folder, cx)),
                    )
                    .child(
                        text(
                            l("apple.transcriptfollow.jump_to_latest.86752458"),
                            FontToken {
                                points: 12.,
                                weight: 600,
                            },
                        )
                        .text_color(primary(dark)),
                    ),
            );
        }
        let composer = if shared {
            self.retire_composer(cx);
            div().p(px(16.)).child(
                text(
                    "Shared conversation",
                    FontToken {
                        points: 12.,
                        weight: 400,
                    },
                )
                .text_color(secondary(dark)),
            )
        } else {
            self.composer_content(folder, &chat_id, running, dark, cx)
        };
        div()
            .w_full()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(content)
            .child(composer)
    }
}
