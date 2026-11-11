// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Source-shaped desktop shell preview. Unported contents remain explicit gaps.

mod chat_composer;
mod chat_mutations;
mod chat_rows;
mod chat_status;
mod chat_view;
mod composer_input;
mod confirmation_view;
mod day_view;
mod draft_marks;
mod fixtures;
mod home_devices;
mod home_editor;
mod home_fixtures;
mod home_getting_started;
mod home_panels;
mod home_shared;
mod home_view;
mod home_work;
mod insights_account;
mod insights_inspector;
mod insights_local;
mod project_dialogs;
mod project_fixtures;
mod project_rows;
mod sidebar_chats;
mod sidebar_preferences;
mod work_metadata;

use crate::{
    client::Client,
    commands::{self, AccountMenuState, ChatDetail, Command, EntryKind},
    design::{FontToken, GlobalSection, RailPlace, WorkspaceSection, fonts, palette, shell},
    desktop_data::{Account, DesktopData},
    layout::{DisplayFit, ShellLayout},
    localization,
    menus::{self, PopupMenu},
    navigation::{Navigation, Route},
    presentation::{self, text},
};
use gpui::{
    App, Application, Bounds, Context, Div, FocusHandle, FontWeight, IntoElement, KeyBinding,
    KeyDownEvent, Menu, MenuItem, MouseButton, Render, SharedString, Window, WindowAppearance,
    WindowBounds, WindowOptions, div, point, prelude::*, px, rgb, size, svg,
};

#[derive(Clone, PartialEq, gpui::Action)]
#[action(namespace = tokenstat, no_json)]
struct ExecuteCommand {
    command: Command,
}

struct Tooltip(String);
impl Render for Tooltip {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        text(
            self.0.clone(),
            FontToken {
                points: 12.,
                weight: 400,
            },
        )
        .px(px(8.))
        .py(px(5.))
        .rounded(px(6.))
        .bg(rgb(0x27252c))
        .text_color(rgb(0xffffff))
    }
}

struct OpenMenu {
    model: PopupMenu,
    left: f32,
    top: Option<f32>,
    restore_focus: Option<FocusHandle>,
    application_group: Option<usize>,
    project: Option<project_rows::Target>,
    chat: Option<chat_rows::Target>,
}

struct Desktop {
    client: Option<Client>,
    account_snapshot: Option<Account>,
    owner_generation: u64,
    machines_selection: crate::devices::Selection,
    requested_work: Option<crate::work::Reference>,
    plan_reader: crate::home::plans::Reader,
    active: bool,
    home_editor: Option<crate::home::layout::Editor>,
    home_editor_focus: FocusHandle,
    home_editor_target: home_editor::Target,
    home_editor_drag_target: Option<crate::home::layout::Section>,
    fixture: Option<fixtures::Fixture>,
    data: Option<DesktopData>,
    directory_loaded: bool,
    error: Option<String>,
    busy: bool,
    home: crate::home::HomeState,
    scanner: crate::home::scan::State,
    remote_fetch: crate::insights::fetch::State,
    insights: crate::insights::State,
    local_insights_active: bool,
    local_insights_visible: usize,
    account_insights: Option<insights_account::Screen>,
    account_insights_epoch: u64,
    archive_revision: u64,
    hover_anchor: Option<crate::home::day::HoverAnchor>,
    navigation: Navigation,
    layout: ShellLayout,
    project_directory: crate::project_edit::Directory,
    sidebar_scroll: gpui::ScrollHandle,
    chat_directory: crate::chat::directory::Model,
    chat_readers: std::collections::HashMap<String, gpui::Entity<crate::chat::reader::Reader>>,
    chat_folds: std::collections::HashMap<String, chat_view::ChatFold>,
    chat_watch: Option<chat_view::ChatWatch>,
    composer: Option<chat_composer::Composer>,
    held_composers: std::collections::HashMap<String, chat_composer::Composer>,
    chat_actions: crate::chat::actions::Model,
    fork_alert: Option<chat_mutations::OpenAlert>,
    fork_alert_ticket: u64,
    chat_history: crate::chat::history::State,
    projects_display: crate::sidebar::ProjectsDisplay,
    projects_display_initialized: bool,
    projects_sort: crate::sidebar::ProjectsSort,
    projects_sort_initialized: bool,
    projects_filter: Option<gpui::Entity<crate::input_field::Field>>,
    projects_filter_query: String,
    sidebar_collation: crate::sidebar::collation::SidebarCollation,
    timeline_warm: crate::sidebar::timeline::WarmTask,
    timeline_limit: usize,
    collapsed_chat_days: std::collections::HashSet<crate::sidebar::layout::Day>,
    hovered_chat_day: Option<crate::sidebar::layout::Day>,
    hovered_chat: Option<(String, String)>,
    selected_chat: Option<(String, String)>,
    chat_overview: bool,
    draft_marks: std::collections::HashMap<String, gpui::Entity<draft_marks::Mark>>,
    chat_statuses: std::collections::HashMap<(String, String), gpui::Entity<chat_status::Status>>,
    hovered_project: Option<String>,
    shift_held: bool,
    rename_dialog: Option<project_dialogs::RenameDialog>,
    rename_ticket: u64,
    project_dialog_focus: FocusHandle,
    confirmation: Option<project_dialogs::OpenConfirmation>,
    confirmation_ticket: u64,
    confirmation_restore_focus: Option<FocusHandle>,
    project_documents: Vec<crate::project_edit::Document>,
    detail: ChatDetail,
    root_focus: FocusHandle,
    menu_focus: FocusHandle,
    menu: Option<OpenMenu>,
    gap: Option<String>,
}

fn l(key: &str) -> String {
    localization::text(key, &[])
}
fn primary(dark: bool) -> gpui::Hsla {
    let mut c = rgb(if dark { 0xffffff } else { 0x000000 });
    c.a = 0.85;
    c.into()
}
fn secondary(dark: bool) -> gpui::Hsla {
    let mut c = rgb(if dark { 0xffffff } else { 0x000000 });
    c.a = if dark { 0.55 } else { 0.5 };
    c.into()
}
fn icon(name: &'static str, points: f32, color: gpui::Hsla) -> impl IntoElement {
    svg()
        .path(format!("symbols/{name}"))
        .size(px(points))
        .flex_none()
        .text_color(color)
}

impl Desktop {
    fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(client) = self.client.clone() else {
            return;
        };
        work_metadata::identity(client.clone(), cx);
        cx.global_mut::<home_shared::HomeShared>().sidebar.refresh();
        sidebar_preferences::pump(cx);
        self.busy = true;
        let account_read = cx.global_mut::<home_shared::HomeShared>().account.begin();
        let task = cx
            .background_executor()
            .spawn(async move { client.desktop_data() });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = cx.update(|cx| {
                let account = match &result {
                    Ok(data) => data.account.clone(),
                    Err(e) => Err(format!("{e:#}")),
                };
                cx.global_mut::<home_shared::HomeShared>()
                    .accept_account(account_read, account);
                work_metadata::pump(cx);
            });
            let _ = view.update(cx, |view, cx| {
                view.busy = false;
                match result {
                    Ok(mut data) => {
                        let folders = data.repositories.as_ref().ok().cloned();
                        view.directory_loaded |= data.repositories.is_ok();
                        let errors = data.preserve_previous(view.data.as_ref());
                        view.data = Some(data);
                        if let Some(folders) = folders {
                            view.accept_project_directory(folders, cx);
                        }
                        view.error = (!errors.is_empty()).then(|| errors.join("\n"));
                    }
                    Err(error) => view.error = Some(format!("{error:#}")),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn account(&self) -> Option<&Account> {
        self.account_snapshot.as_ref()
    }

    fn close_menu(&mut self, window: &mut Window) {
        if let Some(menu) = self.menu.take() {
            menu.restore_focus
                .unwrap_or_else(|| self.root_focus.clone())
                .focus(window);
        }
    }

    fn open_menu(
        &mut self,
        entries: Vec<commands::MenuEntry>,
        left: f32,
        top: Option<f32>,
        keyboard: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let restore_focus = self
            .menu
            .as_ref()
            .and_then(|m| m.restore_focus.clone())
            .or_else(|| window.focused(cx));
        self.menu = Some(OpenMenu {
            model: PopupMenu::new(entries, keyboard),
            left,
            top,
            restore_focus,
            application_group: None,
            project: None,
            chat: None,
        });
        self.menu_focus.focus(window);
        cx.notify();
    }

    fn open_application_menu(
        &mut self,
        index: usize,
        keyboard: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(menu) = menus::application_menus(self.detail).into_iter().nth(index) {
            let width = f32::from(window.viewport_size().width);
            let left = self.layout.rail_extent()
                + if self.layout.shows_sidebar(width, None) {
                    self.layout.sidebar_width
                } else {
                    0.
                }
                + index as f32 * 66.;
            self.open_menu(menu.entries, left, Some(28.), keyboard, window, cx);
            if let Some(menu) = self.menu.as_mut() {
                menu.application_group = Some(index);
            }
        }
    }

    fn open_account(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(account) = self.account() else {
            self.gap = Some(
                self.data
                    .as_ref()
                    .and_then(|d| d.account.as_ref().err())
                    .cloned()
                    .unwrap_or_else(|| "Account status is still loading.".into()),
            );
            cx.notify();
            return;
        };
        self.open_menu(
            commands::account_menu(AccountMenuState {
                signed_in: account.signed_in,
                ..Default::default()
            }),
            self.layout.panel_inset() + 12.,
            None,
            false,
            window,
            cx,
        );
    }

    fn command(&mut self, command: Command, window: &mut Window, cx: &mut Context<Self>) {
        if command == Command::Quit {
            self.save_composer(cx);
        }
        if self.rename_dialog.is_some() {
            self.rename_command(command, window, cx);
            return;
        }
        if self.confirmation.is_some() || self.fork_alert.is_some() {
            if command == Command::Quit {
                work_metadata::request_quit(cx);
            }
            return;
        }
        if self.home_editor.is_some() {
            match command {
                Command::CloseWindow => self.cancel_home_editor(window, cx),
                Command::Quit => work_metadata::request_quit(cx),
                Command::Minimize => window.minimize_window(),
                Command::Zoom => window.zoom_window(),
                _ => {}
            }
            return;
        }
        if self.composer_visible()
            && let Some(composer) = &self.composer
            && composer.field.read(cx).focus.is_focused(window)
            && matches!(
                command,
                Command::Undo
                    | Command::Redo
                    | Command::Cut
                    | Command::Copy
                    | Command::Paste
                    | Command::SelectAll
            )
        {
            composer
                .field
                .update(cx, |field, cx| field.command(command, cx));
            return;
        }
        if let Some(field) = &self.projects_filter
            && field.read(cx).focus.is_focused(window)
            && matches!(
                command,
                Command::Undo
                    | Command::Redo
                    | Command::Cut
                    | Command::Copy
                    | Command::Paste
                    | Command::SelectAll
            )
        {
            field.update(cx, |field, cx| field.command(command, cx));
            return;
        }
        if let Some(screen) = &self.account_insights
            && screen.field.read(cx).focus.is_focused(window)
            && matches!(
                command,
                Command::Undo
                    | Command::Redo
                    | Command::Cut
                    | Command::Copy
                    | Command::Paste
                    | Command::SelectAll
            )
        {
            screen
                .field
                .update(cx, |field, cx| field.command(command, cx));
            return;
        }
        let project = self.menu.as_ref().and_then(|menu| menu.project.clone());
        let chat = self.menu.as_ref().and_then(|menu| menu.chat.clone());
        self.close_menu(window);
        match command {
            Command::Project(action) => self.project_command(action, project, window, cx),
            Command::Chat(action) => self.chat_command(action, chat, window, cx),
            Command::SetProjectsSort(sort) => self.set_projects_sort(sort, cx),
            Command::MoveSidebarSection(servers_first) => {
                let (section, before) = if servers_first {
                    ("servers", "projects")
                } else {
                    ("projects", "servers")
                };
                cx.global_mut::<home_shared::HomeShared>()
                    .sidebar
                    .move_section(section.into(), before.into());
                sidebar_preferences::pump(cx);
                cx.notify();
            }
            Command::PreviousConversation => self.step_sidebar_chat(-1, cx),
            Command::NextConversation => self.step_sidebar_chat(1, cx),
            Command::ToggleSteps => self.toggle_chat_groups(cx),
            Command::ToggleSidebar => self
                .layout
                .toggle_sidebar(f32::from(window.viewport_size().width), None),
            Command::ToggleInspector => self.layout.toggle_inspector(
                &self.navigation.route,
                f32::from(window.viewport_size().width),
            ),
            Command::OpenAccount => self.navigate(
                Route::Global {
                    section: GlobalSection::Account,
                },
                cx,
            ),
            Command::OpenTeams => self.open_rail(RailPlace::Team, cx),
            Command::CustomizeHome => {
                self.home_editor = Some(crate::home::layout::Editor::new(
                    cx.global::<home_shared::HomeShared>().layout.clone(),
                ));
                self.home_editor_focus.focus(window);
                self.home_editor_target =
                    home_editor::Target::Preset(crate::home::layout::Preset::Balanced);
            }
            Command::OpenSelectedDayInInsights => {
                if let Some(day) = &self.home.selected {
                    let date = day.date.clone();
                    if self.insights.focus_day(&date) {
                        self.load_local_insights(cx);
                    }
                    self.navigate(
                        Route::Global {
                            section: GlobalSection::Insights,
                        },
                        cx,
                    );
                }
            }
            Command::SetChatDetail(detail) => {
                self.apply_chat_detail(detail, cx);
                cx.global_mut::<home_shared::HomeShared>()
                    .sidebar
                    .set_chat_detail(detail);
                sidebar_preferences::pump(cx);
            }
            Command::OpenApplicationMenu(index) => {
                self.open_application_menu(index, true, window, cx);
            }
            Command::Minimize => window.minimize_window(),
            Command::Zoom => window.zoom_window(),
            Command::CloseWindow => window.remove_window(),
            Command::CloseAllWindows => {
                for handle in cx.windows() {
                    let _ = handle.update(cx, |_, window, _| window.remove_window());
                }
            }
            Command::NewWindow => open_window(self.client.clone(), self.fixture, cx),
            Command::Quit => work_metadata::request_quit(cx),
            Command::AddRepository => self.choose_repository(window, cx),
            // This preview intentionally reports missing implementations instead
            // of pretending a mutation succeeded or silently doing nothing.
            other => {
                self.gap = Some(format!(
                    "Desktop preview: {other:?} has not been ported yet."
                ))
            }
        }
        cx.notify();
    }

    fn choose_repository(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(client) = self.client.clone() else {
            self.gap = Some("The shell fixture does not change repositories.".into());
            return;
        };
        if self.busy {
            return;
        }
        self.busy = true;
        let paths = cx.prompt_for_paths(gpui::PathPromptOptions {
            files: false,
            directories: true,
            multiple: true,
            prompt: Some(l("apple.tokenstatapp.add_project.94d63fa2").into()),
        });
        cx.spawn(async move |view, cx| {
            let result = match paths.await {
                Ok(Ok(Some(paths))) => {
                    let task = cx.background_executor().spawn(async move {
                        for path in paths {
                            client.add_repository(&path)?;
                        }
                        anyhow::Ok(())
                    });
                    Some(task.await)
                }
                Ok(Ok(None)) => None,
                Ok(Err(e)) => Some(Err(e)),
                Err(e) => Some(Err(e.into())),
            };
            let _ = view.update(cx, |view, cx| {
                view.busy = false;
                match result {
                    Some(Ok(())) => view.refresh(cx),
                    Some(Err(error)) => view.error = Some(format!("{error:#}")),
                    None => {}
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.fork_alert.is_some() {
            return;
        }
        if self.rename_dialog.is_some() {
            self.rename_key(event, window, cx);
            return;
        }
        if self.home_editor.is_some() {
            self.home_editor_key(event, window, cx);
            cx.stop_propagation();
            return;
        }
        if event.keystroke.key == "escape"
            && self.menu.is_none()
            && self
                .projects_filter
                .as_ref()
                .is_some_and(|field| field.read(cx).focus.is_focused(window))
        {
            self.close_projects_filter(window, cx);
            cx.stop_propagation();
            return;
        }
        if self.gap.is_some() && event.keystroke.key == "escape" {
            self.gap = None;
            cx.stop_propagation();
            cx.notify();
            return;
        }
        let Some(menu) = self.menu.as_mut() else {
            return;
        };
        let mut action = None;
        let mut close = false;
        let mut switch_group = None;
        match event.keystroke.key.as_str() {
            "up" => menu.model.step(false),
            "down" => menu.model.step(true),
            "enter" => action = menu.model.activate(),
            "right" => {
                if !menu.model.open_submenu() && menu.model.path.len() == 1 {
                    switch_group = menu
                        .application_group
                        .map(|i| (i + 1) % menus::application_menus(self.detail).len());
                }
            }
            "left" => {
                if !menu.model.close_submenu() {
                    let count = menus::application_menus(self.detail).len();
                    switch_group = menu.application_group.map(|i| (i + count - 1) % count);
                }
            }
            "escape" => {
                close = !menu.model.close_submenu();
            }
            "tab" => close = true,
            _ if !event.keystroke.modifiers.control
                && !event.keystroke.modifiers.platform
                && !event.keystroke.modifiers.alt =>
            {
                if let Some(input) = &event.keystroke.key_char {
                    menu.model.type_character(input, std::time::Instant::now());
                }
            }
            _ => {}
        }
        if close {
            self.close_menu(window);
        }
        if let Some(index) = switch_group {
            self.open_application_menu(index, true, window, cx);
        }
        if let Some(command) = action {
            self.command(command, window, cx);
        }
        cx.stop_propagation();
        cx.notify();
    }

    fn rail(&self, height: f32, dark: bool, cx: &Context<Self>) -> Div {
        div()
            .flex_none()
            .w(px(shell::RAIL_WIDTH))
            .h(px(height.max(0.)))
            .flex()
            .flex_col()
            .items_center()
            .pt(px(24.))
            .pb(px(12.))
            .gap(px(4.))
            .children(RailPlace::ALL.iter().copied().map(|place| {
                let selected = self.navigation.route.rail_place() == Some(place);
                let label = l(place.label_key());
                div()
                    .id(SharedString::from(format!("rail-{}", place.id())))
                    .w(px(40.))
                    .h(px(36.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(10.))
                    .when(selected, |d| d.bg(palette::ROW_SELECTED.resolve(dark)))
                    .hover(|s| s.bg(palette::ROW_HIGHLIGHT.opacity(0.7).resolve(dark)))
                    .cursor_pointer()
                    .tooltip(move |_, cx| cx.new(|_| Tooltip(label.clone())).into())
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.close_menu(window);
                        view.open_rail(place, cx);
                        if place == RailPlace::Home {
                            if view.home.calendar.is_none() && !view.home.loading {
                                view.refresh_home(view.home.requested_scope, false, cx);
                            }
                            view.load_home_plans(false, cx);
                        }
                        cx.notify();
                    }))
                    .child(icon(
                        place.symbol(),
                        16.,
                        if selected {
                            palette::ACCENT.resolve(dark)
                        } else {
                            palette::CONTROL_GLYPH.resolve(dark)
                        },
                    ))
            }))
            .child(div().flex_1())
            .child(
                div()
                    .id("rail-account")
                    .size(px(40.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .on_click(cx.listener(|view, _, window, cx| view.open_account(window, cx)))
                    .child(self.avatar(28., dark)),
            )
    }

    fn avatar(&self, points: f32, dark: bool) -> Div {
        let initial = self
            .account()
            .and_then(Account::title)
            .and_then(|s| s.chars().next())
            .map(|c| c.to_uppercase().to_string());
        div()
            .size(px(points))
            .flex_none()
            .rounded_full()
            .bg(palette::ACCENT_SOFT.resolve(dark))
            .flex()
            .items_center()
            .justify_center()
            .when_some(initial.clone(), |d, initial| {
                d.child(
                    text(
                        initial,
                        FontToken {
                            points: points * 0.4,
                            weight: 600,
                        },
                    )
                    .text_color(palette::ACCENT.resolve(dark)),
                )
            })
            .when(initial.is_none(), |d| {
                d.child(icon(
                    "person.crop.circle",
                    points * 0.64,
                    palette::ACCENT.resolve(dark),
                ))
            })
    }

    fn wordmark(dark: bool) -> Div {
        // TokenstatLogoGeometry.swift: its original 42-point ink box.
        let side = 17.;
        let mark = div().relative().size(px(side)).children(
            [
                (0., 24., 12., 18., 0xC3B0FF),
                (15., 12., 12., 30., 0x8B5CF6),
                (30., 0., 12., 42., 0xE879F9),
            ]
            .map(|(x, y, w, h, color)| {
                div()
                    .absolute()
                    .left(px(x * side / 42.))
                    .top(px(y * side / 42.))
                    .w(px(w * side / 42.))
                    .h(px(h * side / 42.))
                    .rounded(px(3.5 * side / 42.))
                    .bg(rgb(color))
            }),
        );
        div()
            .flex()
            .items_center()
            .gap(px(side * 0.75))
            .child(mark)
            .child(
                text(
                    "token",
                    FontToken {
                        points: side * 0.88,
                        weight: 700,
                    },
                )
                .text_color(primary(dark))
                .flex()
                .child(
                    text(
                        "stat",
                        FontToken {
                            points: side * 0.88,
                            weight: 700,
                        },
                    )
                    .text_color(palette::ACCENT.resolve(dark)),
                ),
            )
    }

    fn sidebar_row(
        &self,
        id: impl Into<SharedString>,
        label: String,
        symbol: &'static str,
        trailing: &str,
        selected: bool,
        dark: bool,
    ) -> gpui::Stateful<Div> {
        div()
            .id(id.into())
            .relative()
            .mx(px(4.))
            .px(px(8.))
            .py(px(7.))
            .flex()
            .items_center()
            .gap(px(8.))
            .rounded(px(6.))
            .cursor_pointer()
            .when(selected, |d| d.bg(palette::ROW_SELECTED.resolve(dark)))
            .hover(|s| s.bg(palette::ROW_HIGHLIGHT.opacity(0.6).resolve(dark)))
            .when(selected, |d| {
                d.child(
                    div()
                        .absolute()
                        .left_0()
                        .top(px(3.))
                        .bottom(px(3.))
                        .w(px(3.))
                        .rounded(px(1.5))
                        .bg(palette::ACCENT.resolve(dark)),
                )
            })
            .child(
                div()
                    .w(px(18.))
                    .flex_none()
                    .flex()
                    .justify_center()
                    .child(icon(
                        symbol,
                        13.,
                        if selected {
                            palette::ACCENT.resolve(dark)
                        } else {
                            secondary(dark)
                        },
                    )),
            )
            .child(
                text(
                    label,
                    FontToken {
                        points: self.layout.fit.text(14.),
                        weight: if selected { 500 } else { 400 },
                    },
                )
                .flex_1()
                .min_w_0()
                .truncate(),
            )
            .when(!trailing.is_empty() && trailing != "0", |d| {
                d.child(
                    presentation::monospaced(
                        trailing.to_owned(),
                        FontToken {
                            points: 11.,
                            weight: 400,
                        },
                    )
                    .text_color(secondary(dark)),
                )
            })
    }

    fn sidebar(&self, dark: bool, cx: &Context<Self>) -> Div {
        let mut list = div()
            .id("repositories-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .track_scroll(&self.sidebar_scroll);
        let repository_count = self
            .data
            .as_ref()
            .and_then(|d| d.repositories.as_ref().ok())
            .map(Vec::len);
        let count = repository_count.map(|_| self.visible_project_folders(cx).len());
        list = list.child(
            div()
                .flex()
                .items_center()
                .px(px(12.))
                .pt(px(16.))
                .pb(px(6.))
                .gap(px(6.))
                .child(
                    div()
                        .id("repositories-disclosure")
                        .flex_1()
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .cursor_pointer()
                        .on_click(cx.listener(|view, _, _, cx| {
                            view.set_projects_expanded(
                                !view.project_directory.projects_expanded(),
                                cx,
                            );
                        }))
                        .child(icon(
                            if self.project_directory.projects_expanded() {
                                "chevron.down"
                            } else {
                                "chevron.right"
                            },
                            9.,
                            secondary(dark),
                        ))
                        .child(
                            text(
                                if self.projects_display == crate::sidebar::ProjectsDisplay::ByChat
                                {
                                    l("common.chats")
                                } else {
                                    l("common.projects")
                                },
                                FontToken {
                                    points: 12.,
                                    weight: 600,
                                },
                            )
                            .text_color(secondary(dark)),
                        )
                        .when_some(
                            count.filter(|&n| {
                                n > 0
                                    && self.projects_display
                                        == crate::sidebar::ProjectsDisplay::ByRepository
                            }),
                            |d, n| {
                                d.child(
                                    text(
                                        n.to_string(),
                                        FontToken {
                                            points: 10.,
                                            weight: 400,
                                        },
                                    )
                                    .text_color(secondary(dark)),
                                )
                            },
                        ),
                )
                .when(repository_count.is_some_and(|n| n > 0), |d| {
                    d.child(self.projects_display_switch(dark, cx)).child(
                        div()
                            .id("sidebar-filter-toggle")
                            .size(px(20.))
                            .rounded(px(6.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .when(self.projects_filter.is_some(), |button| {
                                button.bg(palette::ROW_SELECTED_NESTED.resolve(dark))
                            })
                            .tooltip(|_, cx| {
                                cx.new(|_| Tooltip(l("common.sidebar.filter_repositories")))
                                    .into()
                            })
                            .on_click(cx.listener(|view, _, window, cx| {
                                view.toggle_projects_filter(window, cx)
                            }))
                            .child(icon("line.3.horizontal.decrease", 12., secondary(dark))),
                    )
                })
                .child(
                    div()
                        .id("sidebar-projects-options")
                        .size(px(20.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .when(self.menu.is_none(), |d| {
                            d.tooltip(|_, cx| {
                                cx.new(|_| Tooltip(l("common.sidebar.section_options")))
                                    .into()
                            })
                        })
                        .on_click(cx.listener(|view, event: &gpui::ClickEvent, window, cx| {
                            view.open_projects_options(event.position(), window, cx)
                        }))
                        .child(icon("ellipsis", 12., secondary(dark))),
                )
                .child(
                    div()
                        .id("add-repository-header")
                        .size(px(20.))
                        .cursor_pointer()
                        .flex()
                        .items_center()
                        .justify_center()
                        .on_click(cx.listener(|view, _, window, cx| {
                            view.command(Command::AddRepository, window, cx)
                        }))
                        .child(icon("plus", 9., secondary(dark))),
                ),
        );
        if self.project_directory.projects_expanded() {
            if self.projects_filter.is_some() && repository_count.is_some_and(|n| n > 0) {
                list = list.child(self.projects_filter_field(dark, cx));
            }
            match self.data.as_ref().map(|d| &d.repositories) {
                Some(Ok(repositories)) => {
                    if self.projects_display == crate::sidebar::ProjectsDisplay::ByChat
                        && !repositories.is_empty()
                    {
                        list = list.child(self.projects_chat_timeline(dark, cx));
                    } else {
                        for repo in self.visible_project_folders(cx) {
                            list = list.child(self.project_row(repo, dark, cx));
                            if self.project_directory.expanded(&repo.id) {
                                list = list.child(self.project_children(repo, dark, cx));
                            }
                        }
                    }
                }
                Some(Err(error)) => {
                    list = list.child(
                        text(
                            error.clone(),
                            FontToken {
                                points: 12.,
                                weight: 400,
                            },
                        )
                        .p(px(12.))
                        .text_color(secondary(dark)),
                    )
                }
                None => {
                    list = list.child(
                        text(
                            "Loading…",
                            FontToken {
                                points: 12.,
                                weight: 400,
                            },
                        )
                        .p(px(12.))
                        .text_color(secondary(dark)),
                    )
                }
            }
            list = list.child(
                self.sidebar_row(
                    "add-repository",
                    l("apple.rootview.add_project.43079d4a"),
                    "plus.circle",
                    "",
                    false,
                    dark,
                )
                .on_click(cx.listener(|view, _, window, cx| {
                    view.command(Command::AddRepository, window, cx)
                })),
            );
        }
        let account_name = self
            .account()
            .map(|a| {
                if a.signed_in {
                    a.title()
                        .map(str::to_owned)
                        .unwrap_or_else(|| l("common.account"))
                } else {
                    l("common.sign_in")
                }
            })
            .unwrap_or_else(|| l("common.account"));
        div()
            .w(px(self.layout.sidebar_width))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .child(
                div()
                    .pt(px(22.))
                    .pb(px(4.))
                    .child(
                        div()
                            .h(px(52.))
                            .pb(px(3.))
                            .px(px(12.))
                            .flex()
                            .items_center()
                            .child(Self::wordmark(dark)),
                    )
                    .child(
                        self.sidebar_row(
                            "new-chat",
                            l("apple.rootview.new_chat.db18382a"),
                            "square.and.pencil",
                            "",
                            matches!(
                                self.navigation.route,
                                Route::Global {
                                    section: GlobalSection::NewChat
                                }
                            ),
                            dark,
                        )
                        .on_click(cx.listener(|view, _, _, cx| {
                            view.navigate(
                                Route::Global {
                                    section: GlobalSection::NewChat,
                                },
                                cx,
                            );
                            cx.notify();
                        })),
                    )
                    .child(
                        self.sidebar_row(
                            "search-work",
                            l("common.search"),
                            "magnifyingglass",
                            if cfg!(target_os = "macos") {
                                "⌘K"
                            } else {
                                "Ctrl+K"
                            },
                            false,
                            dark,
                        )
                        .on_click(cx.listener(|view, _, window, cx| {
                            view.command(Command::SearchWork, window, cx)
                        })),
                    ),
            )
            .child(list)
            .child(
                div()
                    .h(px(52.))
                    .pb(px(12.))
                    .px(px(8.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        div()
                            .id("sidebar-account")
                            .flex_1()
                            .cursor_pointer()
                            .on_click(
                                cx.listener(|view, _, window, cx| view.open_account(window, cx)),
                            )
                            .child(text(
                                account_name,
                                FontToken {
                                    points: 12.,
                                    weight: 600,
                                },
                            )),
                    )
                    .child(
                        div()
                            .id("settings")
                            .size(px(32.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .on_click(cx.listener(|view, _, window, cx| {
                                view.command(Command::OpenAccount, window, cx)
                            }))
                            .child(icon("gearshape", 14., secondary(dark))),
                    ),
            )
    }

    fn toolbar_button(
        &self,
        id: &'static str,
        symbol: &'static str,
        command: Command,
        selected: bool,
        dark: bool,
        cx: &Context<Self>,
    ) -> gpui::Stateful<Div> {
        div()
            .id(id)
            .size(px(44.))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .on_click(cx.listener(move |view, _, window, cx| view.command(command, window, cx)))
            .child(
                div()
                    .size(px(30.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(8.))
                    .when(selected, |d| {
                        d.bg(palette::ACCENT_SOFT.opacity(0.8).resolve(dark))
                    })
                    .hover(|s| s.bg(palette::ROW_HIGHLIGHT.resolve(dark)))
                    .child(icon(symbol, 14., palette::CONTROL_GLYPH.resolve(dark))),
            )
    }

    fn route_title(&self) -> String {
        match &self.navigation.route {
            Route::Global { section } => l(section.label_key()),
            Route::WorkspacesOverview => l("apple.rootview.all_projects.4b87271b"),
            Route::Workspace { id, .. } => self
                .data
                .as_ref()
                .and_then(|d| d.repositories.as_ref().ok())
                .and_then(|r| r.iter().find(|r| &r.id == id))
                .map(|r| r.name.clone())
                .unwrap_or_else(|| id.clone()),
            Route::Ssh { section } => l(section.label_key()),
            Route::SshTerminals { .. } => l("apple.shellchrome.ssh.01c4d3c2"),
        }
    }

    fn content(
        &mut self,
        width: f32,
        dark: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Div {
        if self.navigation.route == Route::default() {
            return self.home_content(width, dark, cx);
        }
        if matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) && self.home.requested_scope == crate::home::ActivityScope::AllMachines
        {
            return self.account_insights_content(dark, cx);
        }
        if matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) {
            return self.local_insights_content(width, dark, cx);
        }
        if let Route::Workspace {
            id,
            section: WorkspaceSection::Chat,
        } = &self.navigation.route
            && !self.chat_overview
            && self
                .selected_chat
                .as_ref()
                .is_some_and(|(folder, _)| folder == id)
        {
            let id = id.clone();
            return self.chat_content(&id, dark, window, cx);
        }
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .p(px(8.))
            .when_some(self.preview_error(cx), |d, error| {
                d.child(
                    text(
                        error,
                        FontToken {
                            points: 12.,
                            weight: 400,
                        },
                    )
                    .p(px(12.))
                    .text_color(secondary(dark)),
                )
            })
            .child(
                text(
                    format!(
                        "Desktop preview: {} content is still being ported from SwiftUI.",
                        self.route_title()
                    ),
                    FontToken {
                        points: 12.,
                        weight: 400,
                    },
                )
                .p(px(16.))
                .text_color(secondary(dark)),
            )
    }

    fn render_popup(&self, dark: bool, width: f32, window: &Window, cx: &Context<Self>) -> Div {
        let Some(open) = &self.menu else {
            return div();
        };
        let widths = (0..open.model.path.len())
            .map(|depth| {
                open.model
                    .level(depth)
                    .iter()
                    .map(|entry| {
                        let run = gpui::TextRun {
                            len: entry.title.len(),
                            font: presentation::system_font(400),
                            color: primary(dark),
                            background_color: None,
                            underline: None,
                            strikethrough: None,
                        };
                        let title = window.text_system().shape_line(
                            entry.title.clone().into(),
                            px(13.),
                            &[run],
                            None,
                        );
                        // Reserve check, image, row padding and the shortcut/submenu
                        // seats. Native NSMenu's exact insets remain a visual gate.
                        f32::from(title.width).ceil() + 88.
                    })
                    .fold(272., f32::max)
                    .min((width - 12.).max(1.))
            })
            .collect::<Vec<_>>();
        let max_left = (width - widths.iter().sum::<f32>() - 6.).max(6.);
        let menu_height = (0..open.model.path.len())
            .map(|depth| {
                12. + open
                    .model
                    .level(depth)
                    .iter()
                    .map(|entry| {
                        if entry.kind == EntryKind::Separator {
                            9.
                        } else {
                            26.
                        }
                    })
                    .sum::<f32>()
            })
            .fold(0., f32::max);
        let viewport_height = f32::from(window.viewport_size().height);
        let mut group = div()
            .absolute()
            .left(px(open.left.min(max_left)))
            .flex()
            .items_start()
            .gap(px(2.))
            .occlude()
            .on_mouse_down_out(cx.listener(|view, _, window, cx| {
                view.close_menu(window);
                cx.stop_propagation();
                cx.notify();
            }));
        group = if let Some(top) = open.top {
            group.top(px(top
                .min((viewport_height - menu_height - 6.).max(6.))
                .max(6.)))
        } else {
            group.bottom(px(56.))
        };
        for (depth, menu_width) in widths.iter().enumerate() {
            let mut column = div()
                .w(px(*menu_width))
                .py(px(5.))
                .rounded(px(8.))
                .bg(palette::PANEL.resolve(dark))
                .border_1()
                .border_color(palette::BORDER.resolve(dark))
                .shadow_lg();
            for (index, entry) in open.model.level(depth).iter().enumerate() {
                if entry.kind == EntryKind::Separator {
                    column = column.child(
                        div()
                            .h(px(1.))
                            .my(px(4.))
                            .mx(px(7.))
                            .bg(palette::BORDER.resolve(dark)),
                    );
                    continue;
                }
                let selected = open.model.path[depth] == Some(index);
                let color = if selected {
                    rgb(0xffffff).into()
                } else {
                    primary(dark)
                };
                let mut row = div()
                    .id(SharedString::from(format!("menu-{depth}-{index}")))
                    .h(px(26.))
                    .mx(px(4.))
                    .px(px(8.))
                    .rounded(px(4.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_color(color)
                    .when(selected, |d| {
                        d.bg(palette::ACCENT.resolve(dark))
                            .text_color(rgb(0xffffff))
                    })
                    .when(!entry.enabled, |d| d.opacity(0.4))
                    .child(
                        presentation::system_text(
                            if entry.selected { "✓" } else { "" },
                            12.,
                            400,
                            cx,
                        )
                        .w(px(12.)),
                    );
                if open
                    .model
                    .level(depth)
                    .iter()
                    .any(|entry| entry.icon.is_some())
                {
                    row = row.child(
                        div()
                            .size(px(16.))
                            .flex_none()
                            .when_some(entry.icon, |seat, glyph| {
                                seat.child(icon(glyph.symbol(), 16., color))
                            }),
                    );
                }
                row = row.child(
                    presentation::system_text(entry.title.clone(), 13., 400, cx)
                        .whitespace_nowrap()
                        .flex_1(),
                );
                if let Some(shortcut) = entry.shortcut {
                    row = row.child(presentation::system_text(
                        format!(
                            "{}{shortcut}",
                            if cfg!(target_os = "macos") {
                                "⌘"
                            } else {
                                "Ctrl+"
                            }
                        ),
                        11.,
                        400,
                        cx,
                    ));
                }
                if !entry.children.is_empty() {
                    row = row.child(icon(
                        "chevron.right",
                        9.,
                        if selected {
                            rgb(0xffffff).into()
                        } else {
                            primary(dark)
                        },
                    ));
                }
                column = column.child(
                    row.on_mouse_move(cx.listener(move |view, _, _, cx| {
                        if let Some(menu) = view.menu.as_mut() {
                            menu.model.hover(depth, index);
                        }
                        cx.notify();
                    }))
                    .on_click(cx.listener(move |view, _, window, cx| {
                        let action = view
                            .menu
                            .as_mut()
                            .and_then(|menu| menu.model.click(depth, index));
                        if let Some(command) = action {
                            view.command(command, window, cx);
                        }
                        cx.notify();
                    })),
                );
            }
            group = group.child(column);
        }
        group
    }
}

impl Desktop {
    fn preview_gap(&self, width: f32, dark: bool, cx: &Context<Self>) -> Option<Div> {
        self.gap.clone().map(|gap| {
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .occlude()
                .bg(gpui::black().opacity(0.25))
                .child(
                    presentation::card_surface(dark)
                        .w(px((width - 32.).clamp(0., 440.)))
                        .flex()
                        .flex_col()
                        .gap(px(16.))
                        .child(text(
                            gap,
                            FontToken {
                                points: 13.,
                                weight: 400,
                            },
                        ))
                        .child(
                            div()
                                .id("dismiss-preview-gap")
                                .cursor_pointer()
                                .on_click(cx.listener(|view, _, _, cx| {
                                    view.gap = None;
                                    cx.notify();
                                }))
                                .child(l("common.close")),
                        ),
                )
        })
    }
}

impl Render for Desktop {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.retire_chat_rename(window, cx);
        if let Some(focus) = self.confirmation_restore_focus.take() {
            focus.focus(window);
        }
        if let Some(dialog) = &self.rename_dialog {
            let dark = if let Some(fixtures::Fixture::Project(f)) = self.fixture {
                f.dark
            } else {
                matches!(
                    window.appearance(),
                    WindowAppearance::Dark | WindowAppearance::VibrantDark
                )
            };
            if dialog.field.read(cx).dark != dark {
                dialog.field.update(cx, |field, _| field.dark = dark);
            }
        }
        if let Some(field) = &self.projects_filter {
            let dark = matches!(
                window.appearance(),
                WindowAppearance::Dark | WindowAppearance::VibrantDark
            );
            if field.read(cx).dark != dark {
                field.update(cx, |field, _| field.dark = dark);
            }
        }
        if let Some(fixture) = self.fixture {
            if matches!(fixture,fixtures::Fixture::Project(f) if f.is_fork_error()) {
                return fixture.render(self, window, cx).into_any_element();
            }
            if let Some(display) = window.display(cx) {
                let bounds = display.bounds();
                self.layout.fit =
                    DisplayFit::for_screen(bounds.size.width.into(), bounds.size.height.into());
            }
            let fixture_dark = match fixture {
                fixtures::Fixture::Project(f) => f.dark,
                _ => false,
            };
            self.prepare_chat_statuses(true, fixture_dark, cx);
            self.sync_fork_alert(window, cx);
            return fixture.render(self, window, cx).into_any_element();
        }
        if self.navigation.route != Route::default() {
            self.home.hovered = None;
            self.home.days.clear_hover();
            self.hover_anchor = None;
        }
        let dark = matches!(
            window.appearance(),
            WindowAppearance::Dark | WindowAppearance::VibrantDark
        );
        if let Some(display) = window.display(cx) {
            let bounds = display.bounds();
            self.layout.fit =
                DisplayFit::for_screen(bounds.size.width.into(), bounds.size.height.into());
        }
        let width = f32::from(window.viewport_size().width);
        self.layout.apply_width(width, None);
        let sidebar = self.layout.shows_sidebar(width, None);
        self.prepare_chat_statuses(sidebar, dark, cx);
        self.sync_fork_alert(window, cx);
        let inspector = self
            .layout
            .shows_inspector(&self.navigation.route, width, None);
        let inset = self.layout.panel_inset();
        let mut chrome = div()
            .flex()
            .h_full()
            .flex_none()
            .p(px(inset))
            .pr(px(inset))
            .child(
                div()
                    .h_full()
                    .flex()
                    .rounded(px(16.))
                    .bg(palette::SIDEBAR.resolve(dark))
                    // Its available height is already known at the root. Avoid
                    // a nested percentage-height cycle on the opening frame.
                    .child(self.rail(
                        f32::from(window.viewport_size().height) - inset * 2.,
                        dark,
                        cx,
                    ))
                    .when(sidebar, |d| d.child(self.sidebar(dark, cx))),
            );
        // The trailing gutter is part of rail_extent, not another content inset.
        chrome = chrome.w(px(self.layout.rail_extent()
            + if sidebar {
                self.layout.sidebar_width
            } else {
                0.
            }));
        let content_width = (width
            - self.layout.rail_extent()
            - if sidebar {
                self.layout.sidebar_width
            } else {
                0.
            }
            - if inspector {
                self.layout.inspector_width
            } else {
                0.
            })
        .max(0.);
        let title = self.route_title();
        let mut bar = presentation::chrome_bar(dark)
            .child(self.toolbar_button(
                "toggle-sidebar",
                "sidebar.left",
                Command::ToggleSidebar,
                self.layout.sidebar_chosen,
                dark,
                cx,
            ))
            .when(
                matches!(
                    self.navigation.route,
                    Route::Global {
                        section: GlobalSection::Insights
                    }
                ) && self.home.requested_scope == crate::home::ActivityScope::ThisMachine
                    && self.insights.focused_day.is_some(),
                |d| {
                    d.child(
                        div()
                            .id("insights-back-home")
                            .size(px(44.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .child(icon("chevron.left", 14., secondary(dark)))
                            .on_click(cx.listener(|view, _, _, cx| {
                                if view.insights.clear_focused_day() {
                                    view.load_local_insights(cx);
                                }
                                view.navigate(Route::default(), cx);
                            })),
                    )
                },
            )
            .when(
                self.navigation.route != Route::default()
                    && !matches!(
                        self.navigation.route,
                        Route::Global {
                            section: GlobalSection::Insights
                        }
                    ),
                |d| {
                    d.child(text(
                        title.clone(),
                        FontToken {
                            points: 14.,
                            weight: 600,
                        },
                    ))
                },
            )
            .when(
                self.navigation.route == Route::default()
                    || matches!(
                        self.navigation.route,
                        Route::Global {
                            section: GlobalSection::Insights
                        }
                    ),
                |d| d.child(self.home_scope_picker(dark, cx)),
            )
            .child(div().flex_1());
        if matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) && self.home.requested_scope == crate::home::ActivityScope::ThisMachine
        {
            bar = bar.child(self.local_insights_toolbar(dark, cx));
        }
        if self.navigation.route == Route::default() {
            bar = bar.child(self.toolbar_button(
                "customize-home",
                crate::design::ActionIcon::Layout.symbol(),
                Command::CustomizeHome,
                false,
                dark,
                cx,
            ));
        }
        if !matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) {
            bar = bar.child(
                div()
                    .id("refresh-desktop")
                    .size(px(44.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .when(self.home.loading || self.home.refreshing, |d| {
                        d.opacity(0.4)
                    })
                    .on_click(cx.listener(|view, _, _, cx| {
                        if let Route::Workspace {
                            id,
                            section: WorkspaceSection::Chat,
                        } = &view.navigation.route
                            && !view.chat_overview
                        {
                            let id = id.clone();
                            view.chat_refresh(&id, cx);
                            return;
                        }
                        if !view.home.loading && !view.home.refreshing {
                            view.refresh(cx);
                            view.refresh_home(view.home.requested_scope, true, cx);
                        }
                    }))
                    .child(icon("arrow.clockwise", 14., secondary(dark))),
            );
        }
        if self.navigation.route.has_inspector() {
            bar = bar.child(self.toolbar_button(
                "toggle-inspector",
                "sidebar.right",
                Command::ToggleInspector,
                self.layout.inspector_chosen,
                dark,
                cx,
            ));
        }
        let mut detail = div()
            .relative()
            .flex_1()
            .min_w_0()
            .h_full()
            .flex()
            .flex_col();
        let mut band = div().h(px(28.)).w_full().flex_none().flex().items_center();
        if cfg!(target_os = "linux") || self.client.is_none() {
            for (index, menu) in menus::application_menus(self.detail)
                .into_iter()
                .enumerate()
            {
                band = band.child(
                    div()
                        .id(SharedString::from(format!("application-menu-{index}")))
                        .h_full()
                        .w(px(66.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .hover(|s| s.bg(palette::ROW_HIGHLIGHT.resolve(dark)))
                        .on_click(cx.listener(move |view, _, window, cx| {
                            view.open_application_menu(index, false, window, cx)
                        }))
                        .child(text(
                            menu.title,
                            FontToken {
                                points: 12.,
                                weight: 400,
                            },
                        )),
                );
            }
        }
        band = band.child(
            div()
                .flex_1()
                .h_full()
                .on_mouse_down(MouseButton::Left, |_, window, _| window.start_window_move()),
        );
        let chat_scrolls_itself = matches!(&self.navigation.route, Route::Workspace { id, section: WorkspaceSection::Chat }
            if !self.chat_overview && self.selected_chat.as_ref().is_some_and(|(folder, _)| folder == id));
        detail = detail.child(band).child(bar).child(
            div()
                .id("desktop-content")
                .flex_1()
                .min_h_0()
                .when(!chat_scrolls_itself, |d| d.overflow_y_scroll())
                .when(chat_scrolls_itself, |d| d.flex().flex_col())
                .child(self.content(content_width, dark, window, cx)),
        );
        if matches!(
            self.navigation.route,
            Route::Global {
                section: GlobalSection::Insights
            }
        ) {
            detail = detail.when_some(self.insights_toast(dark, cx), |d, toast| d.child(toast));
        }
        let mut root = div()
            .id("tokenstat-shell")
            .key_context("Tokenstat")
            .track_focus(&self.root_focus)
            .on_action(cx.listener(|view, action: &ExecuteCommand, window, cx| {
                view.command(action.command, window, cx)
            }))
            .capture_key_down(cx.listener(Self::key_down))
            .relative()
            .size_full()
            .flex()
            .font_family(fonts::INTERFACE)
            .font_weight(FontWeight::NORMAL)
            .text_color(primary(dark))
            .bg(palette::BACKGROUND.resolve(dark))
            .child(chrome)
            .child(detail);
        if inspector {
            root = root.child(
                div()
                    .w(px(self.layout.inspector_width))
                    .h_full()
                    .flex_none()
                    .bg(palette::PANEL.resolve(dark))
                    .border_l_1()
                    .border_color(palette::BORDER.resolve(dark))
                    .child(self.inspector_body(28., dark, cx)),
            );
        }
        if !sidebar && self.layout.sidebar_overlay {
            root = root.child(
                div()
                    .absolute()
                    .top(px(inset))
                    .bottom(px(inset))
                    .left(px(self.layout.rail_extent()))
                    .occlude()
                    .rounded(px(16.))
                    .shadow_lg()
                    .bg(palette::SIDEBAR.resolve(dark))
                    .child(self.sidebar(dark, cx)),
            );
        }
        if !inspector && self.layout.inspector_overlay && self.navigation.route.has_inspector() {
            root = root.child(
                div()
                    .absolute()
                    .top(px(28.))
                    .bottom_0()
                    .right_0()
                    .w(px(self.layout.inspector_width))
                    .occlude()
                    .shadow_lg()
                    .bg(palette::PANEL.resolve(dark))
                    .child(self.inspector_body(0., dark, cx)),
            );
        }
        if self.navigation.route == Route::default() {
            root = root.child(self.day_popover(window.viewport_size(), dark));
        }
        if self.menu.is_some() {
            root = root.child(
                div()
                    .id("menu-dismiss")
                    .absolute()
                    .inset_0()
                    .occlude()
                    .track_focus(&self.menu_focus)
                    .child(self.render_popup(dark, width, window, cx)),
            );
        }
        if self.home_editor.is_some() {
            root = root.child(self.render_home_editor(window.viewport_size(), dark, cx));
        }
        if self.rename_dialog.is_some() {
            root = root.child(self.render_project_rename(dark, cx));
        }
        if let Some(open) = &self.confirmation {
            root = root.child(open.view.clone());
        }
        if let Some(open) = &self.fork_alert {
            root = root.child(open.view.clone());
        }
        if let Some(gap) = self.preview_gap(width, dark, cx) {
            root = root.child(gap);
        }
        root.into_any_element()
    }
}

fn install_native_menus(detail: ChatDetail, cx: &mut App) {
    fn items(entries: Vec<commands::MenuEntry>) -> Vec<MenuItem> {
        entries
            .into_iter()
            .filter_map(|entry| {
                if entry.kind == EntryKind::Separator {
                    Some(MenuItem::separator())
                } else if !entry.children.is_empty() {
                    Some(MenuItem::submenu(Menu {
                        name: entry.title.into(),
                        items: items(entry.children),
                    }))
                } else {
                    entry
                        .command
                        .map(|command| MenuItem::action(entry.title, ExecuteCommand { command }))
                }
            })
            .collect()
    }
    cx.set_menus(
        menus::application_menus(detail)
            .into_iter()
            .map(|menu| Menu {
                name: menu.title.into(),
                items: items(menu.entries),
            })
            .collect(),
    );
}

fn open_window(client: Option<Client>, fixture: Option<fixtures::Fixture>, cx: &mut App) {
    let size = fixture
        .map(|f| f.size())
        .unwrap_or_else(|| size(px(1260.), px(825.)));
    let bounds = Bounds::centered(None, size, cx);
    let opened = cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            window_min_size: Some(if fixture.is_some() {
                size
            } else {
                gpui::size(px(480.), px(620.))
            }),
            app_id: Some("ai.tokenstat.tokenstat".into()),
            titlebar: fixture.is_none().then(|| gpui::TitlebarOptions {
                title: Some("tokenstat — desktop preview".into()),
                appears_transparent: true,
                traffic_light_position: Some(point(px(15.), px(12.))),
            }),
            ..Default::default()
        },
        |window, cx| {
            if fixture.is_some() {
                window.set_window_title("tokenstat — parity fixture");
            }
            cx.new(|cx| {
                let root_focus = cx.focus_handle();
                root_focus.focus(window);
                cx.observe_window_activation(window, |view: &mut Desktop, window, cx| {
                    view.active = window.is_window_active();
                    view.sync_chat_watch(cx);
                    if !window.is_window_active() {
                        view.close_menu(window);
                        cx.notify();
                    }
                })
                .detach();
                cx.observe_global::<home_shared::HomeShared>(|view: &mut Desktop, cx| {
                    let shared = cx.global::<home_shared::HomeShared>();
                    view.account_snapshot = shared.account.account.clone();
                    let owner = shared.account.owner.generation();
                    let archive_revision = shared.archive_revision;
                    view.sync_sidebar_preferences(cx);
                    view.sync_chat_directories(cx);
                    view.sync_account_insights(cx);
                    if view.owner_generation != owner {
                        view.owner_generation = owner;
                        view.home.reset_owner();
                        view.hover_anchor = None;
                        view.machines_selection = crate::devices::Selection::default();
                        view.requested_work = None;
                        if view.navigation.route == Route::default() {
                            view.refresh_home(view.home.requested_scope, false, cx);
                            view.load_home_plans(false, cx);
                        }
                    }
                    if view.archive_revision != archive_revision {
                        view.archive_revision = archive_revision;
                        view.home.days.invalidate(false);
                        view.refresh_home(view.home.requested_scope, true, cx);
                        view.load_home_plans(false, cx);
                    }
                    cx.notify();
                })
                .detach();
                cx.observe_window_bounds(window, |view: &mut Desktop, window, cx| {
                    view.close_menu(window);
                    cx.notify();
                })
                .detach();
                let synthetic = client.is_none();
                let plan_reader = cx.global_mut::<home_shared::HomeShared>().reads.register();
                let view_id = cx.entity_id();
                cx.on_release(move |view: &mut Desktop, cx| {
                    chat_rows::release_window(view_id, cx);
                    if cx.has_global::<home_shared::HomeShared>() {
                        cx.global_mut::<home_shared::HomeShared>()
                            .reads
                            .release(view.plan_reader);
                    }
                })
                .detach();
                let mut view = Desktop {
                    plan_reader,
                    client,
                    account_snapshot: cx
                        .global::<home_shared::HomeShared>()
                        .account
                        .account
                        .clone(),
                    owner_generation: cx
                        .global::<home_shared::HomeShared>()
                        .account
                        .owner
                        .generation(),
                    machines_selection: crate::devices::Selection::default(),
                    requested_work: None,
                    active: window.is_window_active(),
                    home_editor: None,
                    home_editor_focus: cx.focus_handle(),
                    home_editor_target: home_editor::Target::Preset(
                        crate::home::layout::Preset::Balanced,
                    ),
                    home_editor_drag_target: None,
                    fixture,
                    data: synthetic.then(DesktopData::fixture),
                    directory_loaded: synthetic,
                    error: None,
                    busy: false,
                    home: crate::home::HomeState::default(),
                    scanner: crate::home::scan::State::default(),
                    remote_fetch: crate::insights::fetch::State::default(),
                    insights: crate::insights::State::default(),
                    local_insights_active: false,
                    local_insights_visible: 50,
                    account_insights: None,
                    account_insights_epoch: 0,
                    archive_revision: cx.global::<home_shared::HomeShared>().archive_revision,
                    hover_anchor: None,
                    navigation: Navigation::default(),
                    layout: ShellLayout::default(),
                    project_directory: Default::default(),
                    sidebar_scroll: gpui::ScrollHandle::new(),
                    chat_directory: Default::default(),
                    chat_readers: Default::default(),
                    chat_folds: Default::default(),
                    chat_watch: None,
                    composer: None,
                    held_composers: Default::default(),
                    chat_actions: Default::default(),
                    fork_alert: None,
                    fork_alert_ticket: 0,
                    chat_history: Default::default(),
                    projects_display: Default::default(),
                    projects_display_initialized: false,
                    projects_sort: Default::default(),
                    projects_sort_initialized: false,
                    projects_filter: None,
                    projects_filter_query: String::new(),
                    sidebar_collation: crate::sidebar::collation::SidebarCollation::current(),
                    timeline_warm: Default::default(),
                    timeline_limit: crate::sidebar::layout::CHAT_PAGE_SIZE,
                    collapsed_chat_days: Default::default(),
                    hovered_chat_day: None,
                    hovered_chat: None,
                    selected_chat: None,
                    chat_overview: false,
                    draft_marks: Default::default(),
                    chat_statuses: Default::default(),
                    hovered_project: None,
                    shift_held: false,
                    rename_dialog: None,
                    rename_ticket: 0,
                    project_dialog_focus: cx.focus_handle(),
                    confirmation: None,
                    confirmation_ticket: 0,
                    confirmation_restore_focus: None,
                    project_documents: Vec::new(),
                    detail: ChatDetail::default(),
                    root_focus,
                    menu_focus: cx.focus_handle(),
                    menu: None,
                    gap: None,
                };
                draft_marks::watch(&mut view, cx);
                view.sync_sidebar_preferences(cx);
                if synthetic
                    && let Some(Ok(folders)) = view.data.as_ref().map(|data| &data.repositories)
                {
                    let folders = folders.clone();
                    view.accept_project_directory(folders, cx);
                    if fixture.is_none() {
                        view.seed_shell_chats(cx.global::<home_shared::HomeShared>().clock_ms);
                    }
                }
                view.refresh(cx);
                view.refresh_home(view.home.requested_scope, false, cx);
                view.watch_home_plans(cx);
                if let Some(fixture) = fixture {
                    fixture.prepare(&mut view, window, cx);
                }
                view
            })
        },
    );
    if let Err(error) = opened {
        eprintln!("tokenstat desktop: {error}");
    }
    cx.activate(true);
}

/// `None` is the shell fixture, which must never read the user's host/archive.
pub fn run(client: Option<Client>) {
    run_with_fixture(client, None);
}

/// An offline visual fixture: parsing and dispatch happen before host setup.
pub fn run_day_fixture(name: &str) -> anyhow::Result<()> {
    let fixture = fixtures::DayFixture::parse(name)?;
    run_with_fixture(None, Some(fixtures::Fixture::Day(fixture)));
    Ok(())
}

pub fn run_home_fixture(name: &str) -> anyhow::Result<()> {
    let fixture = home_fixtures::HomeFixture::parse(name)?;
    run_with_fixture(None, Some(fixtures::Fixture::Home(fixture)));
    Ok(())
}

/// An offline name-field/sheet fixture using the same production view.
pub fn run_project_fixture(name: &str) -> anyhow::Result<()> {
    let fixture = project_fixtures::ProjectFixture::parse(name)?;
    run_with_fixture(None, Some(fixtures::Fixture::Project(fixture)));
    Ok(())
}

fn run_with_fixture(client: Option<Client>, fixture: Option<fixtures::Fixture>) {
    Application::new()
        .with_assets(crate::symbols::Symbols)
        .run(move |cx| {
            home_shared::initialize(client.as_ref(), cx);
            draft_marks::initialize(client.as_ref(), cx);
            if let Some(fixture) = fixture {
                fixture.initialize(cx);
            }
            if let Err(error) = presentation::register_fonts(cx) {
                eprintln!("tokenstat desktop fonts: {error}");
                cx.quit();
                return;
            }
            let modifier = if cfg!(target_os = "macos") {
                "cmd"
            } else {
                "ctrl"
            };
            let mut bindings = Vec::new();
            fn collect(
                entries: &[commands::MenuEntry],
                modifier: &str,
                bindings: &mut Vec<KeyBinding>,
            ) {
                for entry in entries {
                    if let (Some(shortcut), Some(command)) = (entry.shortcut, entry.command) {
                        bindings.push(KeyBinding::new(
                            &format!("{modifier}-{shortcut}"),
                            ExecuteCommand { command },
                            Some("Tokenstat"),
                        ));
                    }
                    collect(&entry.children, modifier, bindings);
                }
            }
            for menu in menus::application_menus(ChatDetail::default()) {
                collect(&menu.entries, modifier, &mut bindings);
            }
            cx.bind_keys(bindings);
            if cfg!(target_os = "linux") || client.is_none() {
                cx.bind_keys(
                    [("alt-f", 1), ("alt-e", 2), ("alt-v", 3), ("alt-w", 4)].map(|(key, index)| {
                        KeyBinding::new(
                            key,
                            ExecuteCommand {
                                command: Command::OpenApplicationMenu(index),
                            },
                            Some("Tokenstat"),
                        )
                    }),
                );
            }
            install_native_menus(ChatDetail::default(), cx);
            cx.on_window_closed(|cx| {
                if cx.windows().is_empty() {
                    work_metadata::request_quit(cx);
                }
            })
            .detach();
            open_window(client, fixture, cx);
        });
}

/// Test-only entry point used by the hidden-window confirmation contract.
/// It renders the real component without any client, owner lease or archive.
#[doc(hidden)]
pub fn measure_confirmation_geometry(cases: Vec<(String, String, bool)>) -> anyhow::Result<()> {
    measure_dialog_geometry(
        cases
            .into_iter()
            .map(|(name, folder, dark)| {
                (
                    name,
                    crate::confirmation::Content::remove_project(Some(&folder)),
                    dark,
                )
            })
            .collect(),
    )
}
/// Test-only measurement of the actual GPUI single-button fork alert.
#[doc(hidden)]
pub fn measure_fork_alert_geometry(cases: Vec<(String, String, bool)>) -> anyhow::Result<()> {
    measure_dialog_geometry(
        cases
            .into_iter()
            .map(|(name, message, dark)| {
                (
                    name,
                    crate::confirmation::Content::fork_error(message),
                    dark,
                )
            })
            .collect(),
    )
}
fn measure_dialog_geometry(
    cases: Vec<(String, crate::confirmation::Content, bool)>,
) -> anyhow::Result<()> {
    Application::new()
        .with_assets(crate::symbols::Symbols)
        .run(move |app| {
            let result = (|| -> anyhow::Result<serde_json::Value> {
                presentation::register_fonts(app)?;
                let measurements = confirmation_view::Measurements::default();
                let root = app.new(|cx| {
                    confirmation_view::ConfirmationView::new(
                        crate::confirmation::Content::remove_project(Some("alpha")),
                        cx,
                    )
                });
                let root_view = root.clone();
                let handle: gpui::AnyWindowHandle = app
                    .open_window(
                        WindowOptions {
                            show: false,
                            focus: false,
                            app_id: Some("com.example.tokenstat.confirmation-layout".into()),
                            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                                point(px(0.), px(0.)),
                                size(px(260.), px(400.)),
                            ))),
                            ..Default::default()
                        },
                        move |_, _| root_view,
                    )?
                    .into();
                let mut rows = Vec::new();
                for (name, content, dark) in cases {
                    measurements
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Measurement lock failed"))?
                        .clear();
                    root.update(app, |view, cx| {
                        view.content = content;
                        view.interaction=crate::confirmation::Interaction::for_content(&view.content);
                        view.forced_dark = Some(dark);
                        view.panel_only = true;
                        view.measurements = Some(measurements.clone());
                        cx.notify();
                    });
                    handle.update(app, |_, window, app| {
                        window.refresh();
                        let _ = window.draw(app);
                    })?;
                    let rects = measurements
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Measurement lock failed"))?
                        .clone();
                    let fixture_size=if root.read(app).content.buttons.len()==1 {crate::chat::fixtures::ErrorCase::parse(&name).map(|case|[260.,case.height()])} else {None};
                    rows.push(serde_json::json!({"name":name,"dark":dark,"rects":rects,"content":root.read(app).content,"fixtureSize":fixture_size}));
                }
                Ok(serde_json::json!({"cases":rows,"pixelParityVerified":false}))
            })()
            .map_err(|error| format!("{error:#}"));
            match result
                .and_then(|value| serde_json::to_string(&value).map_err(|error| error.to_string()))
            {
                Ok(value) => println!("{value}"),
                Err(error) => {
                    eprintln!("{error}");
                    std::process::exit(1);
                }
            }
            app.quit();
        });
    Ok(())
}
