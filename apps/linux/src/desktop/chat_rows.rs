// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Initial conversation children and title-only directory reads. Full transcript,
//! composer, terminal/job children and remaining mutation/detail/hover owners remain open.

use super::{home_shared::HomeShared, *};
use crate::{
    chat::{
        Conversation,
        directory::{Owner, Presentation, Read},
        history,
        menu::{self, Action},
    },
    desktop_data::Repository,
    work::{Kind, Reference, continuity::Date},
};

#[derive(Clone)]
pub(super) struct Target {
    pub folder: Repository,
    pub conversation: Conversation,
    pub reference: Option<Reference>,
}
pub(super) fn invalidate(owner: &Owner, folder: &str, app: &mut App) {
    crate::chat::transport::invalidate(owner, folder, app);
}

pub(super) fn release_window(id: gpui::EntityId, app: &mut App) {
    crate::chat::transport::release_entity(id, app);
}

fn tertiary(dark: bool) -> gpui::Hsla {
    let mut color = primary(dark);
    color.a = 0.25;
    color
}

impl Desktop {
    pub(super) fn sync_chat_directories(&mut self, cx: &mut Context<Self>) {
        let shared = cx.global::<HomeShared>();
        let owner = if self.client.is_some() {
            shared
                .metadata
                .scope()
                .filter(|_| shared.metadata.local_host_identity.is_some())
                .map(|scope| Owner {
                    scope,
                    generation: shared.account.owner.generation(),
                    local_host_identity: shared
                        .metadata
                        .local_host_identity
                        .clone()
                        .unwrap_or_default(),
                })
        } else {
            shared
                .work
                .as_ref()
                .and_then(|work| work.catalog.scope.clone())
                .map(|scope| Owner {
                    scope,
                    generation: shared.account.owner.generation(),
                    local_host_identity: shared
                        .work
                        .as_ref()
                        .and_then(|w| w.catalog.local_host_identity.clone())
                        .unwrap_or_default(),
                })
        };
        if self.chat_directory.set_owner(owner) {
            self.chat_actions.retain(&Default::default());
            self.selected_chat = None;
            self.chat_overview = false;
            self.chat_history.release_all();
        }
        let folders = self
            .data
            .as_ref()
            .and_then(|data| data.repositories.as_ref().ok())
            .into_iter()
            .flatten()
            .filter(|folder| {
                self.project_directory.projects_expanded()
                    && self.project_directory.expanded(&folder.id)
            })
            .map(|folder| folder.id.clone())
            .collect::<Vec<_>>();
        self.chat_directory.retain_mounts(&folders);
        let with_rows = folders
            .iter()
            .filter(|folder| {
                self.chat_directory.rows(folder).iter().any(|row| {
                    history::shown(
                        row,
                        self.selected_chat.as_ref().map(|(_, id)| id.as_str()),
                        self.draft_fact(folder, &row.id, cx),
                    )
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        self.chat_history.retain_holds(&with_rows);
        for folder in &folders {
            if let Some(read) = self.chat_directory.mount(folder)
                && self.client.is_some()
            {
                self.dispatch_chat_directory(read, cx);
            }
        }
        // Held order is unobserved state, released when its list disappears.
        if let Some((folder, _)) = &self.hovered_chat
            && !folders.iter().any(|id| id == folder)
        {
            self.chat_history.release(folder);
            self.hovered_chat = None;
        }
    }
    fn dispatch_chat_directory(&mut self, read: Read, cx: &mut Context<Self>) {
        let Some(client) = self.client.clone() else {
            return;
        };
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        let weak = cx.weak_entity();
        let current_view = weak.clone();
        let current_read = read.clone();
        let request = crate::chat::transport::Request {
            client,
            owner: read.owner.clone(),
            folder: read.folder.clone(),
            query: crate::chat::query::Query::directory(&read.folder),
            epoch: cx.global::<HomeShared>().transport_epoch.clone(),
        };
        let consumer = crate::chat::transport::Consumer::new(
            cx.entity_id(),
            move |app| {
                !app.global::<HomeShared>().quit_requested
                    && current_view
                        .upgrade()
                        .is_some_and(|view| view.read(app).chat_directory.is_current(&current_read))
            },
            move |result, app| {
                let result = match result {
                    Ok(crate::chat::query::Reply::Directory(rows)) => Ok(rows.as_ref().clone()),
                    Ok(_) => unreachable!("directory query returned another result type"),
                    Err(error) => Err(format!("{error:#}")),
                };
                let _ = weak.update(app, |view, cx| {
                    if view
                        .chat_directory
                        .finish(&read, result, crate::home::plans::now_ms())
                    {
                        view.sync_chat_directories(cx);
                        cx.notify();
                    }
                });
            },
        );
        crate::chat::transport::read(request, consumer, cx);
    }

    fn retry_chat_directory(&mut self, folder: &str, cx: &mut Context<Self>) {
        if let Some(read) = self.chat_directory.begin(folder) {
            self.dispatch_chat_directory(read, cx);
        }
    }
    pub(super) fn set_history_expanded(
        &mut self,
        folder: &str,
        expanded: bool,
        cx: &mut Context<Self>,
    ) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        self.chat_history.set_expanded(folder, expanded);
        cx.global_mut::<HomeShared>()
            .sidebar
            .remember_expansion(format!("history:{folder}"), expanded);
        sidebar_preferences::pump(cx);
        cx.notify();
    }
    fn chat_target(&self, folder: &Repository, conversation: &Conversation, cx: &App) -> Target {
        let reference = self
            .project_target(folder, cx)
            .reference
            .map(|mut reference| {
                reference.kind = Kind::Conversation;
                reference.item_id = Some(conversation.id.clone());
                reference
            });
        Target {
            folder: folder.clone(),
            conversation: conversation.clone(),
            reference,
        }
    }
    fn open_chat_menu(
        &mut self,
        target: Target,
        position: gpui::Point<gpui::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let work = self.work_reading(cx);
        let pins = work
            .as_ref()
            .map(|work| {
                work.pins
                    .iter()
                    .filter(|pin| work.catalog.scope.as_ref() == Some(&pin.reference.scope))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let pinned = target
            .reference
            .as_ref()
            .is_some_and(|reference| pins.iter().any(|pin| pin.reference.same_pin(reference)));
        let entries = menu::items(&menu::State {
            shared: target.conversation.team_share.is_some(),
            running: target.conversation.running,
            reference: target.reference.is_some(),
            pinned,
            pin_count: pins.len(),
            copying: self
                .chat_action_key(&target.folder.id, &target.conversation.id)
                .is_some_and(|key| self.chat_actions.copying(&key)),
        });
        self.open_menu(
            entries,
            position.x.into(),
            Some(position.y.into()),
            false,
            window,
            cx,
        );
        if let Some(menu) = self.menu.as_mut() {
            menu.chat = Some(target);
        }
    }
    pub(super) fn chat_command(
        &mut self,
        action: Action,
        target: Option<Target>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(target) = target else {
            return;
        };
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        match action {
            Action::Fork => self.fork_sidebar_chat(target, window, cx),
            Action::Rename => self.open_chat_rename(target, window, cx),
            Action::Pin => {
                let Some(reference) = target.reference else {
                    return;
                };
                if self.client.is_none() {
                    if let Some(work) = cx.global_mut::<HomeShared>().work.as_mut()
                        && let Err(error) = work.pin_ephemeral(
                            reference,
                            &target.conversation.title,
                            &target.folder.name,
                        )
                    {
                        self.error = Some(format!("{error:#}"));
                    }
                } else {
                    cx.global_mut::<HomeShared>().metadata.pin(
                        reference,
                        target.conversation.title,
                        target.folder.name,
                        Date::from_unix_ms(crate::home::plans::now_ms()),
                    );
                    work_metadata::pump(cx);
                }
            }
            Action::Unpin => {
                if let Some(reference) = target.reference {
                    self.unpin_home(reference, cx);
                }
            }
            other => {
                self.gap = Some(format!(
                    "Desktop preview: {other:?} for {} is still being ported.",
                    target.conversation.label()
                ))
            }
        }
        cx.notify();
    }
    pub(super) fn select_sidebar_chat(&mut self, target: Target, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        self.selected_chat = Some((target.folder.id.clone(), target.conversation.id.clone()));
        self.chat_overview = false;
        self.requested_work = target.reference;
        self.set_project_expanded(&target.folder.id, true, cx);
        let rows = self
            .chat_directory
            .rows(&target.folder.id)
            .iter()
            .filter(|row| {
                history::shown(
                    row,
                    Some(&target.conversation.id),
                    self.draft_fact(&target.folder.id, &row.id, cx),
                )
            })
            .cloned()
            .collect::<Vec<_>>();
        let ordered = history::holding_order(&rows, self.chat_history.held(&target.folder.id));
        if ordered
            .iter()
            .position(|row| crate::work::text::equal(&row.id, &target.conversation.id))
            .is_some_and(|index| index >= history::COLLAPSED_LIMIT)
        {
            self.set_history_expanded(&target.folder.id, true, cx);
        }
        self.navigate(
            Route::Workspace {
                id: target.folder.id,
                section: WorkspaceSection::Chat,
            },
            cx,
        );
        cx.notify();
    }
    pub(super) fn step_sidebar_chat(&mut self, step: i32, cx: &mut Context<Self>) {
        let Route::Workspace {
            id,
            section: WorkspaceSection::Chat,
        } = &self.navigation.route
        else {
            return;
        };
        let Some(folder) = self
            .data
            .as_ref()
            .and_then(|data| data.repositories.as_ref().ok())
            .and_then(|folders| folders.iter().find(|folder| &folder.id == id))
            .cloned()
        else {
            return;
        };
        let rows = self
            .chat_directory
            .rows(id)
            .iter()
            .filter(|row| {
                history::shown(
                    row,
                    self.selected_chat.as_ref().map(|(_, id)| id.as_str()),
                    None,
                )
            })
            .cloned()
            .collect::<Vec<_>>();
        // ChatModel.adjacentConversation uses live chat order. Pointer-held
        // order stabilizes the drawn list only.
        let ordered = rows.iter().collect::<Vec<_>>();
        let current = self.selected_chat.as_ref().and_then(|(_, id)| {
            ordered
                .iter()
                .position(|row| crate::work::text::equal(id, &row.id))
        });
        if let Some(next) = history::looped(ordered.len(), current, step) {
            let target = self.chat_target(&folder, ordered[next], cx);
            self.select_sidebar_chat(target, cx);
        }
    }
    pub(super) fn project_children(
        &self,
        folder: &Repository,
        dark: bool,
        cx: &Context<Self>,
    ) -> gpui::Stateful<Div> {
        let raw = self.chat_directory.rows(&folder.id);
        let selected = self.selected_chat.as_ref().map(|(_, id)| id.as_str());
        // An initial draft read remains unknown until its restored snapshot is ready.
        let rows = raw
            .iter()
            .filter(|row| history::shown(row, selected, self.draft_fact(&folder.id, &row.id, cx)))
            .cloned()
            .collect::<Vec<_>>();
        let ordered = history::holding_order(&rows, self.chat_history.held(&folder.id));
        let selected_index = selected.and_then(|id| {
            ordered
                .iter()
                .position(|row| crate::work::text::equal(id, &row.id))
        });
        let range = history::visible(
            ordered.len(),
            selected_index,
            self.chat_history.expanded(&folder.id),
        );
        let mut content = div()
            .id(SharedString::from(format!(
                "project-children-{}",
                folder.id
            )))
            .w_full()
            .flex()
            .flex_col()
            .gap_0();
        let held_ids = ordered.iter().map(|row| row.id.clone()).collect::<Vec<_>>();
        let held_folder = folder.id.clone();
        content = content.on_hover(cx.listener(move |view, inside, _, _| {
            if *inside {
                view.chat_history.hold(&held_folder, &held_ids);
            } else {
                view.chat_history.release(&held_folder);
            }
        }));
        for conversation in &ordered[range.clone()] {
            content = content.child(self.conversation_row(folder, conversation, dark, cx));
        }
        if ordered.len() > history::COLLAPSED_LIMIT {
            let expanded = self.chat_history.expanded(&folder.id);
            let title = if expanded {
                l("apple.rootview.show_less.94ea9b1d")
            } else {
                localization::text(
                    "apple.rootview.show_0_more.b91c3640",
                    &[&(ordered.len().min(history::INLINE_LIMIT) - range.len()).to_string()],
                )
            };
            let expand_folder = folder.id.clone();
            let all_folder = folder.id.clone();
            let mut footer = div()
                .w_full()
                .flex()
                .items_center()
                .pl(px(13. + self.layout.fit.scale(16.) + 8.))
                .pr(px(12.))
                .py(px(4.))
                .gap(px(8.))
                .child(
                    div()
                        .id(SharedString::from(format!(
                            "history-expander-{}",
                            folder.id
                        )))
                        .cursor_pointer()
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.set_history_expanded(&expand_folder, !expanded, cx)
                        }))
                        .child(
                            text(
                                title,
                                FontToken {
                                    points: self.layout.fit.text(11.),
                                    weight: 500,
                                },
                            )
                            .text_color(secondary(dark)),
                        ),
                )
                .child(div().flex_1());
            if ordered.len() > history::INLINE_LIMIT {
                footer = footer.child(
                    div()
                        .id(SharedString::from(format!("history-archive-{}", folder.id)))
                        .flex()
                        .items_center()
                        .gap(px(4.))
                        .cursor_pointer()
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.set_project_expanded(&all_folder, true, cx);
                            view.navigate(
                                Route::Workspace {
                                    id: all_folder.clone(),
                                    section: WorkspaceSection::Chat,
                                },
                                cx,
                            );
                            view.chat_overview = true;
                            view.gap = Some(
                                "Desktop preview: the conversation overview is still being ported."
                                    .into(),
                            );
                            cx.notify();
                        }))
                        .child(icon(
                            crate::design::ActionIcon::Search.symbol(),
                            11.,
                            secondary(dark),
                        ))
                        .child(
                            text(
                                l("apple.rootview.see_all_chats.e705024a"),
                                FontToken {
                                    points: self.layout.fit.text(11.),
                                    weight: 500,
                                },
                            )
                            .text_color(secondary(dark)),
                        ),
                );
            }
            content = content.child(footer);
        }
        if raw.is_empty() {
            let mut hint = div().w_full().pl(px(40.)).pr(px(12.)).py(px(5.));
            hint = match self.chat_directory.presentation(&folder.id) {
                Presentation::Loading => hint.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .child(
                            div()
                                .w(px(128.))
                                .h(px(12.))
                                .rounded(px(4.))
                                .bg(palette::BORDER.resolve(dark)),
                        )
                        .child(
                            div()
                                .w(px(96.))
                                .h(px(12.))
                                .rounded(px(4.))
                                .bg(palette::BORDER.resolve(dark)),
                        ),
                ),
                Presentation::Failed => {
                    let retry = folder.id.clone();
                    hint.child(
                        div()
                            .id(SharedString::from(format!("history-retry-{}", folder.id)))
                            .flex()
                            .items_center()
                            .gap(px(4.))
                            .cursor_pointer()
                            .on_click(cx.listener(move |view, _, _, cx| {
                                view.retry_chat_directory(&retry, cx)
                            }))
                            .child(icon(
                                crate::design::ActionIcon::Refresh.symbol(),
                                12.,
                                secondary(dark),
                            ))
                            .child(text(
                                l("common.retry"),
                                FontToken {
                                    points: self.layout.fit.text(12.),
                                    weight: 400,
                                },
                            )),
                    )
                }
                Presentation::Empty => hint.child(
                    text(
                        l("apple.rootview.no_chats_yet.269208e4"),
                        FontToken {
                            points: self.layout.fit.text(12.),
                            weight: 400,
                        },
                    )
                    .text_color(tertiary(dark)),
                ),
                Presentation::Content => hint,
            };
            content = content.child(hint);
        }
        content
    }
    fn conversation_row(
        &self,
        folder: &Repository,
        conversation: &Conversation,
        dark: bool,
        cx: &Context<Self>,
    ) -> gpui::Stateful<Div> {
        let target = self.chat_target(folder, conversation, cx);
        let select = target.clone();
        let right_click = target.clone();
        let actions = target.clone();
        let hovered = self
            .hovered_chat
            .as_ref()
            .is_some_and(|(f, id)| f == &folder.id && id == &conversation.id);
        let selected = self
            .selected_chat
            .as_ref()
            .is_some_and(|(_, id)| crate::work::text::equal(id, &conversation.id))
            && !self.chat_overview
            && self.navigation.route
                == Route::Workspace {
                    id: folder.id.clone(),
                    section: WorkspaceSection::Chat,
                };
        let hover_key = (folder.id.clone(), conversation.id.clone());
        let mut title = div()
            .flex_1()
            .min_w_0()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(day_view::harness_mark(
                &conversation.backend,
                self.layout.fit.scale(16.),
                dark,
            ))
            .child(
                text(
                    conversation.label(),
                    FontToken {
                        points: self.layout.fit.text(13.),
                        weight: if selected { 500 } else { 400 },
                    },
                )
                .min_w_0()
                .truncate()
                .text_color(if selected {
                    primary(dark)
                } else {
                    palette::CONTROL_GLYPH.resolve(dark)
                }),
            );
        if let Some(pull) = &conversation.pull {
            let color = if pull.draft && pull.state == "open" {
                palette::STATE_IDLE
            } else {
                match pull.state.as_str() {
                    "merged" => palette::SECONDARY,
                    "closed" => palette::DANGER,
                    _ => palette::ACCENT,
                }
            };
            title = title.child(icon(
                pull.symbol(),
                self.layout.fit.text(11.),
                color.resolve(dark),
            ));
        }
        title = title.child(div().flex_1());
        if let Some(key) = target
            .reference
            .as_ref()
            .and_then(Reference::conversation_key)
            && let Some(mark) = self.draft_marks.get(&key)
        {
            title = title.child(mark.clone());
        }
        let mut trailing = div()
            .min_w(px(26.))
            .flex_none()
            .flex()
            .items_center()
            .justify_end()
            .gap(px(4.))
            .opacity(if hovered { 0. } else { 1. })
            .text_color(if conversation.running {
                palette::ACCENT.resolve(dark)
            } else {
                tertiary(dark)
            });
        if let Some(status) = self
            .chat_statuses
            .get(&(folder.id.clone(), conversation.id.clone()))
        {
            trailing = trailing.child(status.clone());
        }
        let action_key = self.chat_action_key(&folder.id, &conversation.id);
        let copying = action_key
            .as_ref()
            .is_some_and(|key| self.chat_actions.copying(key));
        let action_error = action_key
            .as_ref()
            .is_some_and(|key| self.chat_actions.error(key).is_some());
        let can_delete = conversation.team_share.is_none() && !conversation.running && !copying;
        let shows_delete = hovered && can_delete && self.shift_held;
        let action_help = if shows_delete {
            l("apple.rootview.delete_chat.93291d9c")
        } else {
            localization::text(
                "apple.sidebarrowactions.actions_for_0_hold_shift_for_1.34c1216b",
                &[
                    &conversation.title,
                    &l("apple.rootview.delete_chat.93291d9c").to_lowercase(),
                ],
            )
        };
        let detail_title = conversation.label();
        let details_help = format!(
            "{}: {detail_title}",
            l("apple.clientstates.details.45989de4")
        );
        let actions_button = div()
            .id(SharedString::from(format!(
                "chat-actions-{}-{}",
                folder.id, conversation.id
            )))
            .size(px(24.))
            .rounded(px(5.))
            .flex()
            .items_center()
            .justify_center()
            .when(!hovered, |d| d.invisible())
            .text_color(secondary(dark))
            .hover(|d| {
                d.bg(palette::ACCENT_SOFT.resolve(dark))
                    .text_color(palette::ACCENT.resolve(dark))
            })
            .cursor_default()
            .tooltip(move |_, cx| cx.new(|_| Tooltip(action_help.clone())).into())
            .on_click(
                cx.listener(move |view, event: &gpui::ClickEvent, window, cx| {
                    cx.stop_propagation();
                    if window.modifiers().shift && can_delete {
                        view.chat_command(Action::Remove, Some(actions.clone()), window, cx);
                    } else {
                        view.open_chat_menu(actions.clone(), event.position(), window, cx);
                    }
                }),
            )
            .child(
                svg()
                    .path(if shows_delete {
                        "symbols/trash"
                    } else {
                        "symbols/ellipsis"
                    })
                    .size(px(self.layout.fit.text(11.))),
            );
        let details_button = div()
            .id(SharedString::from(format!(
                "chat-details-{}-{}",
                folder.id, conversation.id
            )))
            .size(px(24.))
            .when(copying || action_error, |button| button.opacity(0.42))
            .rounded(px(5.))
            .flex()
            .items_center()
            .justify_center()
            .text_color(secondary(dark))
            .hover(|d| {
                d.bg(palette::ACCENT_SOFT.resolve(dark))
                    .text_color(palette::ACCENT.resolve(dark))
            })
            .cursor_default()
            .tooltip(move |_, cx| cx.new(|_| Tooltip(details_help.clone())).into())
            .on_click(cx.listener(move |view, _, _, cx| {
                if copying || action_error {
                    return;
                }
                view.gap = Some(format!(
                    "Desktop preview: details for {detail_title} are still being ported."
                ));
                cx.notify();
            }))
            .child(
                svg()
                    .path("symbols/info.circle")
                    .size(px(self.layout.fit.text(12.))),
            );
        let controls = div()
            .absolute()
            .right(px(10.))
            .top_0()
            .h_full()
            .flex()
            .items_center()
            .gap(px(4.))
            .child(actions_button)
            .child(details_button);
        let background = div()
            .absolute()
            .inset_0()
            .mx(px(4.))
            .rounded(px(8.))
            .when(selected, |d| {
                d.bg(palette::ROW_SELECTED_NESTED.resolve(dark))
            })
            .when(!selected && hovered, |d| {
                d.bg(palette::ROW_HIGHLIGHT.opacity(0.45).resolve(dark))
            });
        let label = div()
            .id(SharedString::from(format!(
                "sidebar-chat-select-{}-{}",
                folder.id, conversation.id
            )))
            .relative()
            .w_full()
            .h_full()
            .pl(px(13.))
            .pr(px(38.))
            .flex()
            .items_center()
            .gap(px(4.))
            .cursor_default()
            .on_click(
                cx.listener(move |view, _, _, cx| view.select_sidebar_chat(select.clone(), cx)),
            )
            .child(title)
            .child(trailing);
        div()
            .id(SharedString::from(format!(
                "sidebar-chat-{}-{}",
                folder.id, conversation.id
            )))
            .relative()
            .w_full()
            .h(px(self.layout.fit.scale(30.)))
            .on_hover(cx.listener(move |view, inside, _, cx| {
                if *inside {
                    view.hovered_chat = Some(hover_key.clone());
                } else if view.hovered_chat.as_ref() == Some(&hover_key) {
                    view.hovered_chat = None;
                }
                cx.notify();
            }))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |view, event: &gpui::MouseDownEvent, window, cx| {
                    view.open_chat_menu(right_click.clone(), event.position, window, cx);
                    cx.stop_propagation();
                }),
            )
            .child(background)
            .child(label)
            .child(controls)
    }
}
