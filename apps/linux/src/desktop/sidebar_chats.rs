// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Initial cross-project conversation timeline. Native input, exact locale/date
//! presentation, the filter and section menus remain open parity work.

use super::*;
use crate::{
    chat::{Conversation, history},
    desktop_data::Repository,
    sidebar::{
        ProjectsDisplay, ProjectsSort,
        layout::{self, ChatEntry, Day},
    },
};
use std::collections::HashMap;

type Entry = (Repository, Conversation);
type Groups = Vec<(Day, Vec<Entry>)>;

impl Desktop {
    /// Populate only the host-free interactive shell with clearly synthetic rows.
    pub(super) fn seed_shell_chats(&mut self, now: i64) {
        for (folder, chats) in [
            (
                "/fixture/alpha",
                vec![
                    ("one", "Review the sidebar", "codex", 0_i64, true),
                    ("two", "Prepare Linux build", "claude", 1, false),
                    ("three", "Inspect recent usage", "codex", 4, false),
                ],
            ),
            (
                "/fixture/beta",
                vec![
                    ("four", "Compare desktop layouts", "claude", 0, false),
                    ("five", "Archive notes", "codex", 10, false),
                ],
            ),
        ] {
            let rows = chats
                .into_iter()
                .map(|(id, title, backend, days, running)| Conversation {
                    id: format!("fixture-{id}"),
                    workspace_id: folder.into(),
                    title: title.into(),
                    backend: backend.into(),
                    updated_at_ms: now
                        .saturating_sub(days * 86_400_000 + if id == "one" { 60_000 } else { 0 }),
                    running,
                    ..Conversation::default()
                })
                .collect();
            self.chat_directory.seed(folder, Ok(rows), now);
        }
    }

    fn timeline_entries(&self, cx: &App) -> Vec<Entry> {
        let Some(folders) = self
            .data
            .as_ref()
            .and_then(|data| data.repositories.as_ref().ok())
        else {
            return vec![];
        };
        let selected = self.selected_chat.as_ref().map(|(_, id)| id.as_str());
        let lists: HashMap<&str, Vec<Conversation>> = folders
            .iter()
            .map(|folder| {
                let rows = self
                    .chat_directory
                    .rows(&folder.id)
                    .iter()
                    .filter(|row| {
                        history::shown(row, selected, self.draft_fact(&folder.id, &row.id, cx))
                    })
                    .cloned()
                    .collect();
                (folder.id.as_str(), rows)
            })
            .collect();
        layout::chat_entries(
            folders,
            |folder| {
                lists
                    .get(folder.id.as_str())
                    .map(Vec::as_slice)
                    .unwrap_or_default()
            },
            &self.projects_filter_query,
            ProjectsSort::Recent,
            &self.sidebar_collation,
        )
        .into_iter()
        .map(|entry| (entry.folder.clone(), entry.chat.clone()))
        .collect()
    }

    pub(super) fn timeline_groups(&self, cx: &App) -> (Groups, usize) {
        let rows = self.timeline_entries(cx);
        let total = rows.len();
        let now = if self.fixture.is_some() {
            cx.global::<home_shared::HomeShared>().clock_ms
        } else {
            crate::home::plans::now_ms()
        };
        let entries: Vec<_> = rows
            .iter()
            .take(self.timeline_limit)
            .map(|(folder, chat)| ChatEntry { folder, chat })
            .collect();
        let groups = layout::day_groups(&entries, |ms| {
            crate::sidebar::calendar::local_day(ms, now).unwrap_or((
                0,
                if ms > now {
                    0
                } else {
                    layout::OLDER_AFTER_DAYS
                },
            ))
        })
        .into_iter()
        .map(|(day, entries)| {
            (
                day,
                entries
                    .into_iter()
                    .map(|entry| (entry.folder.clone(), entry.chat.clone()))
                    .collect(),
            )
        })
        .collect();
        (groups, total)
    }

    pub(super) fn timeline_visible_rows(&self, cx: &App) -> Vec<Entry> {
        self.timeline_groups(cx)
            .0
            .into_iter()
            .filter(|(day, _)| !self.collapsed_chat_days.contains(day))
            .flat_map(|(_, entries)| entries)
            .collect()
    }

    /// The source filters folders against their own name, machine and visible
    /// conversations, then sorts the surviving folders by the chosen mode.
    pub(super) fn visible_project_folders<'a>(&'a self, cx: &App) -> Vec<&'a Repository> {
        let Some(folders) = self
            .data
            .as_ref()
            .and_then(|data| data.repositories.as_ref().ok())
        else {
            return vec![];
        };
        let selected = self.selected_chat.as_ref().map(|(_, id)| id.as_str());
        let needle = crate::work::text::trim(&self.projects_filter_query);
        let filtered = folders.iter().filter(|folder| {
            needle.is_empty()
                || layout::folder_matches(folder, needle, &self.sidebar_collation)
                || self.chat_directory.rows(&folder.id).iter().any(|row| {
                    history::shown(row, selected, self.draft_fact(&folder.id, &row.id, cx))
                        && layout::conversation_matches(row, needle, &self.sidebar_collation)
                })
        });
        layout::ordered_folders(
            filtered,
            self.projects_sort,
            |folder| {
                self.chat_directory
                    .rows(&folder.id)
                    .iter()
                    .map(|row| row.last_message_at_ms.unwrap_or(row.updated_at_ms))
                    .max()
                    .unwrap_or(0)
            },
            &self.sidebar_collation,
        )
    }

    pub(super) fn toggle_projects_filter(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.projects_filter.is_some() {
            self.close_projects_filter(window, cx);
            return;
        }
        let prompt = l(if self.projects_display == ProjectsDisplay::ByChat {
            "common.sidebar.filter_chats"
        } else {
            "common.sidebar.filter_repositories"
        });
        let field = cx.new(|cx| {
            let mut field = crate::input_field::Field::new(String::new(), prompt, cx);
            field.plain = true;
            field.dark = matches!(
                window.appearance(),
                WindowAppearance::Dark | WindowAppearance::VibrantDark
            );
            field
        });
        cx.observe(&field, |view, field, cx| {
            if view
                .projects_filter
                .as_ref()
                .is_none_or(|current| current.entity_id() != field.entity_id())
            {
                return;
            }
            let next = field.read(cx).input.text().to_owned();
            if view.projects_filter_query != next {
                view.projects_filter_query = next;
                if view.projects_display == ProjectsDisplay::ByChat {
                    view.timeline_limit = layout::CHAT_PAGE_SIZE;
                }
                cx.notify();
            }
        })
        .detach();
        field.read(cx).focus.focus(window);
        self.projects_filter = Some(field);
        if !self.project_directory.projects_expanded() {
            self.set_projects_expanded(true, cx);
        } else {
            self.sync_chat_directories(cx);
        }
        cx.notify();
    }
    pub(super) fn close_projects_filter(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.projects_filter = None;
        self.projects_filter_query.clear();
        if self.projects_display == ProjectsDisplay::ByChat {
            self.timeline_limit = layout::CHAT_PAGE_SIZE;
        }
        self.root_focus.focus(window);
        self.sync_chat_directories(cx);
        cx.notify();
    }

    pub(super) fn projects_filter_field(&self, dark: bool, cx: &Context<Self>) -> Div {
        let mut field = div().w_full().px(px(12.)).pb(px(4.));
        if let Some(input) = &self.projects_filter {
            field = field.child(
                div()
                    .w_full()
                    .h(px(self.layout.fit.scale(30.)))
                    .pl(px(8.))
                    .pr(px(2.))
                    .rounded(px(9.))
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .bg(palette::ROW_HIGHLIGHT.opacity(0.5).resolve(dark))
                    .child(icon("line.3.horizontal.decrease", 12., secondary(dark)))
                    .child(div().flex_1().min_w_0().child(input.clone()))
                    .child(
                        div()
                            .id("sidebar-filter-close")
                            .size(px(20.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .on_click(cx.listener(|view, _, window, cx| {
                                view.close_projects_filter(window, cx)
                            }))
                            .child(icon("xmark.circle", 13., secondary(dark))),
                    ),
            );
        }
        field
    }

    pub(super) fn open_projects_options(
        &mut self,
        position: gpui::Point<gpui::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut entries = Vec::new();
        if self.projects_display == ProjectsDisplay::ByRepository {
            for (sort, key) in [
                (ProjectsSort::Manual, "common.sidebar.sort_manual"),
                (ProjectsSort::Name, "common.sidebar.sort_name"),
                (ProjectsSort::Recent, "common.sidebar.sort_recent"),
            ] {
                let mut item = commands::MenuEntry::action(key, Command::SetProjectsSort(sort));
                item.selected = sort == self.projects_sort;
                entries.push(item);
            }
            entries.push(commands::MenuEntry::separator());
        }
        let servers_first = cx
            .global::<home_shared::HomeShared>()
            .sidebar
            .reading()
            .is_none_or(|snapshot| {
                snapshot
                    .section_order()
                    .first()
                    .is_none_or(|s| s == "projects")
            });
        entries.push(commands::MenuEntry::action(
            if servers_first {
                "common.sidebar.move_servers_above_projects"
            } else {
                "common.sidebar.move_projects_above_servers"
            },
            Command::MoveSidebarSection(servers_first),
        ));
        self.open_menu(
            entries,
            position.x.into(),
            Some(position.y.into()),
            false,
            window,
            cx,
        );
    }

    pub(super) fn projects_display_switch(
        &self,
        dark: bool,
        cx: &Context<Self>,
    ) -> impl IntoElement {
        let mut segments = div()
            .flex()
            .gap(px(2.))
            .p(px(2.))
            .rounded(px(9.))
            .bg(palette::ROW_HIGHLIGHT.opacity(0.5).resolve(dark));
        for (display, symbol, label) in [
            (
                ProjectsDisplay::ByRepository,
                "folder",
                "common.sidebar.view_by_repository",
            ),
            (
                ProjectsDisplay::ByChat,
                "bubble.left",
                "common.sidebar.view_by_chat",
            ),
        ] {
            let selected = self.projects_display == display;
            let help = l(label);
            segments = segments.child(
                div()
                    .id(SharedString::from(format!(
                        "projects-display-{}",
                        display.as_str()
                    )))
                    .w(px(24.))
                    .h(px(18.))
                    .rounded(px(6.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .when(selected, |d| {
                        d.bg(palette::ROW_SELECTED_NESTED.resolve(dark))
                    })
                    .cursor_pointer()
                    .tooltip(move |_, cx| cx.new(|_| Tooltip(help.clone())).into())
                    .on_click(
                        cx.listener(move |view, _, _, cx| view.set_projects_display(display, cx)),
                    )
                    .child(icon(
                        symbol,
                        12.,
                        if selected {
                            primary(dark)
                        } else {
                            secondary(dark)
                        },
                    )),
            );
        }
        segments
    }

    pub(super) fn projects_chat_timeline(&self, dark: bool, cx: &Context<Self>) -> Div {
        let (groups, total) = self.timeline_groups(cx);
        let mut content = div().w_full().flex().flex_col();
        if total == 0 {
            let label = if self.projects_filter_query.is_empty() {
                l("apple.rootview.no_chats_yet.269208e4")
            } else {
                l("common.sidebar.no_matching_chats")
            };
            return content.child(
                text(
                    label,
                    FontToken {
                        points: self.layout.fit.text(12.),
                        weight: 400,
                    },
                )
                .px(px(12.))
                .py(px(6.))
                .text_color(secondary(dark)),
            );
        }
        for (day, entries) in groups {
            let collapsed = self.collapsed_chat_days.contains(&day);
            let title = match day {
                Day::Working => l("common.working"),
                Day::Today => l("common.today"),
                Day::Yesterday => l("common.yesterday"),
                Day::Older => l("common.sidebar.older"),
                Day::Day(start) => crate::display::local_month_day(start).unwrap_or_default(),
            };
            let hovered = self.hovered_chat_day == Some(day);
            let help = localization::text(
                if collapsed {
                    "apple.rootview.expand_0.e1580a27"
                } else {
                    "apple.rootview.collapse_0.61eb8723"
                },
                &[&title],
            );
            let color = if day == Day::Working {
                palette::ACCENT.resolve(dark)
            } else {
                secondary(dark)
            };
            content = content.child(
                div()
                    .id(SharedString::from(format!("sidebar-chat-day-{day:?}")))
                    .w_full()
                    .min_h(px(self.layout.fit.scale(24.)))
                    .pt(px(8.))
                    .pl(px(13.))
                    .pr(px(12.))
                    .flex()
                    .items_end()
                    .gap(px(5.))
                    .cursor_pointer()
                    .tooltip(move |_, cx| cx.new(|_| Tooltip(help.clone())).into())
                    .on_hover(cx.listener(move |view, inside, _, cx| {
                        if *inside {
                            view.hovered_chat_day = Some(day);
                        } else if view.hovered_chat_day == Some(day) {
                            view.hovered_chat_day = None;
                        }
                        cx.notify();
                    }))
                    .on_click(cx.listener(move |view, _, _, cx| {
                        if !view.collapsed_chat_days.remove(&day) {
                            view.collapsed_chat_days.insert(day);
                        }
                        cx.notify();
                    }))
                    .when(day == Day::Working, |d| {
                        d.child(
                            div()
                                .size(px(5.))
                                .rounded_full()
                                .bg(palette::ACCENT.resolve(dark)),
                        )
                    })
                    .child(
                        text(
                            title,
                            FontToken {
                                points: self.layout.fit.text(12.),
                                weight: 500,
                            },
                        )
                        .text_color(color),
                    )
                    .when(collapsed || hovered, |d| {
                        d.child(icon(
                            if collapsed {
                                "chevron.right"
                            } else {
                                "chevron.down"
                            },
                            9.,
                            secondary(dark),
                        ))
                    }),
            );
            if !collapsed {
                for (folder, conversation) in entries {
                    content = content.child(self.conversation_row(
                        &folder,
                        &conversation,
                        true,
                        dark,
                        cx,
                    ));
                }
            }
        }
        if total > self.timeline_limit {
            let count = (total - self.timeline_limit)
                .min(layout::CHAT_PAGE_SIZE)
                .to_string();
            let title = localization::text("apple.rootview.show_0_more.b91c3640", &[&count]);
            content = content.child(
                div()
                    .id("sidebar-chat-show-more")
                    .w_full()
                    .h(px(self.layout.fit.scale(30.)))
                    .pl(px(13.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .cursor_pointer()
                    .text_color(secondary(dark))
                    .on_click(cx.listener(|view, _, _, cx| {
                        view.timeline_limit =
                            view.timeline_limit.saturating_add(layout::CHAT_PAGE_SIZE);
                        cx.notify();
                    }))
                    .child(icon("ellipsis", 11., secondary(dark)))
                    .child(text(
                        title,
                        FontToken {
                            points: self.layout.fit.text(13.),
                            weight: 500,
                        },
                    )),
            );
        }
        content
    }
}
