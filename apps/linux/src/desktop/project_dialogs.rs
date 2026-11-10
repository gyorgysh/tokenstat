// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! SidebarRenameSheet and RemoveWorkspaceConfirm adapters. The native prompt
//! and sheet chrome require source-matched Linux pixel/input acceptance.

use super::{home_shared::HomeShared, project_rows::Target, *};
use crate::confirmation::{Choice, Content};
use crate::{
    design::{control, modal},
    input_field::Field,
    project_edit::{self, RemovalRoute, Rename},
    work::{Scope, continuity::Date},
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Focus {
    Close,
    Name,
    Cancel,
    Save,
}
pub(super) struct RenameDialog {
    pub state: Rename,
    pub field: gpui::Entity<Field>,
    target: RenameTarget,
    title: String,
    pub ticket: u64,
    focus: Focus,
    restore_focus: Option<FocusHandle>,
}
#[derive(Clone)]
enum RenameTarget {
    Project(Box<Target>),
    Chat(Box<super::chat_rows::Target>),
}
pub(super) struct OpenConfirmation {
    pub view: gpui::Entity<super::confirmation_view::ConfirmationView>,
    ticket: u64,
    target: Target,
    restore_focus: Option<FocusHandle>,
}
impl Desktop {
    pub(super) fn retire_chat_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let retired = self
            .rename_dialog
            .as_ref()
            .is_some_and(|dialog| match &dialog.target {
                RenameTarget::Chat(target) => target.reference.as_ref().is_some_and(|reference| {
                    self.project_scope(cx).as_ref() != Some(&reference.scope)
                }),
                RenameTarget::Project(_) => false,
            });
        if retired {
            self.dismiss_project_rename(window, cx);
        }
    }
    fn project_scope(&self, app: &App) -> Option<Scope> {
        if self.client.is_none() {
            app.global::<HomeShared>()
                .work
                .as_ref()
                .and_then(|work| work.catalog.scope.clone())
        } else {
            app.global::<HomeShared>().metadata.scope()
        }
    }
    pub(super) fn open_project_rename(
        &mut self,
        target: Target,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_rename(
            RenameTarget::Project(Box::new(target.clone())),
            target.folder.name,
            l("apple.rootview.rename_project.2a0478ee"),
            window,
            cx,
        );
    }
    pub(super) fn open_chat_rename(
        &mut self,
        target: super::chat_rows::Target,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if target.conversation.team_share.is_some() {
            return;
        }
        let name = target.conversation.title.clone();
        self.open_rename(
            RenameTarget::Chat(Box::new(target)),
            name,
            l("apple.rootview.rename_chat.26076241"),
            window,
            cx,
        );
    }
    fn open_rename(
        &mut self,
        target: RenameTarget,
        name: String,
        title: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let field = cx.new(|cx| Field::new(name, l("apple.sidebarrowactions.name.dcd1d522"), cx));
        cx.observe(&field, |_, _, cx| cx.notify()).detach();
        let restore_focus = window.focused(cx);
        field.read(cx).focus.focus(window);
        self.rename_ticket = self.rename_ticket.wrapping_add(1);
        self.rename_dialog = Some(RenameDialog {
            state: Rename::default(),
            field,
            target,
            title,
            ticket: self.rename_ticket,
            focus: Focus::Name,
            restore_focus,
        });
        cx.notify();
    }
    pub(super) fn cancel_project_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .rename_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.state.saving)
        {
            return;
        }
        self.dismiss_project_rename(window, cx);
    }
    pub(super) fn dismiss_project_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(dialog) = self.rename_dialog.take() {
            dialog
                .restore_focus
                .unwrap_or_else(|| self.root_focus.clone())
                .focus(window);
        }
        cx.notify();
    }
    fn submit_project_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        let Some(dialog) = self.rename_dialog.as_mut() else {
            return;
        };
        let name = dialog.field.read(cx).input.text().to_owned();
        let Some(name) = dialog.state.begin(&name) else {
            return;
        };
        dialog.field.update(cx, |field, cx| {
            field.input.unmark();
            field.enabled = false;
            cx.notify();
        });
        let target = dialog.target.clone();
        let ticket = dialog.ticket;
        let target = match target {
            RenameTarget::Chat(target) => {
                self.submit_chat_rename(*target, name, ticket, window, cx);
                return;
            }
            RenameTarget::Project(target) => *target,
        };
        if target.folder.machine_id.is_some() {
            dialog.state.finish(Err(
                "Remote project directory ownership has not been ported yet.".into(),
            ));
            dialog.field.update(cx, |field, cx| {
                field.enabled = true;
                cx.notify();
            });
            cx.notify();
            return;
        }
        // The source captures scope/reference when Save begins, rather than
        // when the menu or sheet opened. Host mutation is not rolled back if
        // that scope retires; only its following model/pin effects are skipped.
        let scope = self.project_scope(cx);
        let reference = self.project_target(&target.folder, cx).reference;
        let client = self.client.clone();
        if client.is_none() {
            if let Some(Ok(folders)) = self.data.as_mut().map(|data| &mut data.repositories)
                && let Some(folder) = folders
                    .iter_mut()
                    .find(|folder| folder.id == target.folder.id)
            {
                folder.name = name.clone();
            }
            let shared = cx.global_mut::<HomeShared>();
            if let Some(work) = shared.work.as_mut() {
                for folder in &mut work.catalog.folders {
                    if folder.id == target.folder.id {
                        folder.name = name.clone();
                    }
                }
                if let Some(reference) = reference
                    && work
                        .pins
                        .iter()
                        .any(|pin| pin.reference.same_pin(&reference))
                    && let Err(error) = work.pin_ephemeral(reference, &name, &name)
                {
                    self.error = Some(format!("{error:#}"));
                }
            }
            self.dismiss_project_rename(window, cx);
            return;
        }
        let Some(client) = client else {
            return;
        };
        let id = target.folder.id.clone();
        let saving_client = client.clone();
        let saving_name = name.clone();
        let worker = cx.background_executor().spawn(async move {
            saving_client
                .rename_repository(&id, &saving_name)
                .map_err(|e| format!("{e:#}"))
        });
        let handle = window.window_handle();
        cx.spawn(async move |view, cx| {
            let result = worker.await;
            let current = result.is_ok()
                && cx
                    .update(|app| app.global::<HomeShared>().metadata.scope() == scope)
                    .unwrap_or(false);
            let folders = if current {
                Some(
                    cx.background_executor()
                        .spawn(async move { client.repositories().map_err(|e| format!("{e:#}")) })
                        .await,
                )
            } else {
                None
            };
            let apply_folders = current
                && cx
                    .update(|app| app.global::<HomeShared>().metadata.scope() == scope)
                    .unwrap_or(false);
            // These local metadata effects outlive a closed initiating window.
            if current && let Some(reference) = reference {
                let _ = cx.update(|app| {
                    app.global_mut::<HomeShared>().metadata.relabel_if_pinned(
                        reference,
                        name.clone(),
                        name,
                        Date::from_unix_ms(crate::home::plans::now_ms()),
                    );
                    work_metadata::pump(app);
                });
            }
            let _ = handle.update(cx, |_, window, cx| {
                let _ = view.update(cx, |view, cx| {
                    if let Some(folders) = folders.filter(|_| apply_folders) {
                        match folders {
                            Ok(folders) => view.accept_project_directory(folders, cx),
                            Err(error) => view.error = Some(error),
                        }
                    }
                    if let Some(dialog) = view.rename_dialog.as_mut().filter(|d| d.ticket == ticket)
                    {
                        if dialog.state.finish(result) {
                            view.dismiss_project_rename(window, cx);
                        } else {
                            dialog.field.update(cx, |field, cx| {
                                field.enabled = true;
                                cx.notify();
                            });
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn rename_command(
        &mut self,
        command: Command,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match command {
            Command::CloseWindow => self.cancel_project_rename(window, cx),
            Command::Quit => work_metadata::request_quit(cx),
            Command::Minimize => window.minimize_window(),
            Command::Zoom => window.zoom_window(),
            Command::Cut
            | Command::Copy
            | Command::Paste
            | Command::SelectAll
            | Command::Undo
            | Command::Redo => {
                if let Some(dialog) = &self.rename_dialog
                    && dialog.field.read(cx).focus.is_focused(window)
                {
                    dialog
                        .field
                        .update(cx, |field, cx| field.command(command, cx));
                }
            }
            _ => {}
        }
    }
    pub(super) fn rename_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(dialog) = self.rename_dialog.as_ref() else {
            return;
        };
        if dialog.field.read(cx).input.marked.is_some() {
            return;
        }
        match event.keystroke.key.as_str() {
            "escape" => self.cancel_project_rename(window, cx),
            "enter" => self.submit_project_rename(window, cx),
            "space" if dialog.focus != Focus::Name => {
                if dialog.focus == Focus::Save {
                    self.submit_project_rename(window, cx);
                } else {
                    self.cancel_project_rename(window, cx);
                }
            }
            "tab" => {
                let Some(dialog) = self.rename_dialog.as_mut() else {
                    return;
                };
                if dialog.state.saving {
                    cx.stop_propagation();
                    return;
                }
                let mut targets = vec![Focus::Close, Focus::Name, Focus::Cancel];
                if dialog.state.can_save(dialog.field.read(cx).input.text()) {
                    targets.push(Focus::Save);
                }
                let current = if dialog.field.read(cx).focus.is_focused(window) {
                    Focus::Name
                } else {
                    dialog.focus
                };
                let index = targets.iter().position(|t| *t == current).unwrap_or(0);
                dialog.focus = targets[if event.keystroke.modifiers.shift {
                    (index + targets.len() - 1) % targets.len()
                } else {
                    (index + 1) % targets.len()
                }];
                if dialog.focus == Focus::Name {
                    dialog.field.read(cx).focus.focus(window);
                } else {
                    self.project_dialog_focus.focus(window);
                }
                cx.notify();
            }
            _ => return,
        }
        cx.stop_propagation();
    }
    pub(super) fn request_project_remove(
        &mut self,
        target: Target,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.confirmation.is_some() {
            return;
        }
        self.confirmation_ticket = self.confirmation_ticket.wrapping_add(1);
        let ticket = self.confirmation_ticket;
        let view = cx.new(|cx| {
            super::confirmation_view::ConfirmationView::new(
                Content::remove_project(Some(&target.folder.name)),
                cx,
            )
        });
        cx.subscribe(&view, move |desktop, _, choice: &Choice, cx| {
            if desktop
                .confirmation
                .as_ref()
                .is_none_or(|open| open.ticket != ticket)
            {
                return;
            }
            let Some(open) = desktop.confirmation.take() else {
                return;
            };
            let focus = open
                .restore_focus
                .unwrap_or_else(|| desktop.root_focus.clone());
            desktop.confirmation_restore_focus = Some(focus);
            if *choice == Choice::Remove {
                desktop.remove_project(open.target, cx);
            }
            cx.notify();
        })
        .detach();
        let restore_focus = window.focused(cx);
        view.read(cx).focus.focus(window);
        self.confirmation = Some(OpenConfirmation {
            view,
            ticket,
            target,
            restore_focus,
        });
        cx.notify();
    }
    fn remove_project(&mut self, target: Target, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        if let Some(path) =
            project_edit::blocking_document(&target.folder.id, &self.project_documents)
        {
            self.gap = Some(format!(
                "The unsaved document at {path} must be closed before removing this project. The document close flow has not been ported yet."
            ));
            return;
        }
        let route =
            project_edit::removal_route(&target.folder.id, target.folder.machine_id.as_deref());
        if matches!(route, RemovalRoute::Remote { .. }) {
            self.gap = Some("Remote project directory ownership has not been ported yet.".into());
            return;
        }
        if self.client.is_none() || matches!(route, RemovalRoute::ForgetRemote { .. }) {
            if let Some(Ok(folders)) = self.data.as_mut().map(|data| &mut data.repositories) {
                folders.retain(|folder| folder.id != target.folder.id);
                let folders = folders.clone();
                self.accept_project_directory(folders, cx);
            }
            if self.client.is_none()
                && let Some(work) = cx.global_mut::<HomeShared>().work.as_mut()
            {
                work.catalog
                    .folders
                    .retain(|folder| folder.id != target.folder.id);
            }
            self.forget_project(&target.folder.id);
            return;
        }
        let Some(client) = self.client.clone() else {
            return;
        };
        let worker = cx.background_executor().spawn(async move {
            client.remove_repository(&route)?;
            anyhow::Ok(client.repositories().map_err(|e| format!("{e:#}")))
        });
        cx.spawn(async move |view, cx| {
            let result = worker.await;
            let _ = view.update(cx, |view, cx| {
                match result {
                    Ok(folders) => {
                        view.forget_project(&target.folder.id);
                        match folders {
                            Ok(folders) => view.accept_project_directory(folders, cx),
                            Err(error) => view.error = Some(error),
                        }
                    }
                    Err(error) => view.error = Some(format!("{error:#}")),
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn forget_project(&mut self, id: &str) {
        // RootView retires disclosure/section state only after the directory
        // actually changes. A failed reload must not collapse the old row.
        self.project_documents.retain(|doc| doc.workspace != id);
        // Tabs, browser buffers and editor owners do not exist in this preview
        // yet. Their actual forgetTabs cleanup must join this owner on porting.
    }
    pub(super) fn accept_project_directory(
        &mut self,
        folders: Vec<crate::desktop_data::Repository>,
        cx: &mut Context<Self>,
    ) {
        let ids = folders
            .iter()
            .map(|folder| folder.id.clone())
            .collect::<Vec<_>>();
        let next = self.project_directory.reconcile_with_preferences(
            Some(&ids),
            &mut self.navigation,
            cx.global::<home_shared::HomeShared>()
                .sidebar
                .reading()
                .as_ref(),
        );
        if let Some(data) = self.data.as_mut() {
            data.repositories = Ok(folders);
            self.directory_loaded = true;
        }
        if let Some(next) = next {
            self.navigate(next, cx);
        }
        self.sync_chat_directories(cx);
    }
    pub(super) fn rename_sheet(&self, dark: bool, cx: &Context<Self>) -> gpui::Stateful<Div> {
        let Some(dialog) = &self.rename_dialog else {
            return div().id("rename-project-absent");
        };
        let title = dialog.title.clone();
        let disabled = dialog.state.saving;
        let can_save = dialog.state.can_save(dialog.field.read(cx).input.text());
        let mut content = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(dialog.field.clone());
        if let Some(error) = &dialog.state.error {
            content = content.child(
                text(
                    error.clone(),
                    FontToken {
                        points: self.layout.fit.text(10.),
                        weight: 400,
                    },
                )
                .text_color(palette::DIFF_REMOVED.resolve(dark)),
            );
        }
        let rule = || {
            div()
                .h(px(1.))
                .w_full()
                .flex_none()
                .bg(palette::BORDER.resolve(dark))
        };
        div().id("rename-project-sheet").occlude().track_focus(&self.project_dialog_focus).w(px(460.)).h(px(dialog.state.height())).flex().flex_col().bg(palette::BACKGROUND.resolve(dark))
            .child(div().w_full().min_h(px(modal::HEADER_MIN_HEIGHT)).flex_none().flex().items_center().gap(px(12.)).px(px(20.)).py(px(12.)).bg(palette::SIDEBAR.resolve(dark))
                .child(div().size(px(modal::ICON_SEAT)).flex_none().rounded(px(modal::ICON_SEAT*0.28)).bg(palette::ACCENT.opacity(0.12).resolve(dark)).flex().items_center().justify_center().child(icon("pencil",modal::ICON_SEAT*0.44,palette::ACCENT.resolve(dark))))
                .child(div().flex_1().min_w_0().flex().flex_col().gap(px(4.)).child(text(title.clone(),FontToken {points:self.layout.fit.text(15.),weight:600})).child(text(l("apple.sidebarrowactions.choose_the_name_shown_in_the_sidebar.e7682b18"),FontToken {points:self.layout.fit.text(10.),weight:400}).text_color(palette::CONTROL_GLYPH.resolve(dark))))
                .child(div().id("rename-close").size(px(control::HEIGHT)).flex_none().flex().items_center().justify_center().cursor_pointer()
                    .tooltip(move |_,cx|cx.new(|_|Tooltip(localization::text("apple.themedsheet.close_0.59546c79",&[&title]))).into())
                    .child(div().size(px(22.)).rounded_full().bg(palette::CONTROL_SEAT.resolve(dark)).border_1().border_color(palette::BORDER.opacity(0.55).resolve(dark)).flex().items_center().justify_center().child(icon("xmark",10.,palette::CONTROL_GLYPH.resolve(dark)))).on_click(cx.listener(|view,_,window,cx|view.cancel_project_rename(window,cx)))))
            .child(rule()).child(div().flex_1().w_full().p(px(modal::BODY_PADDING)).flex().flex_col().justify_center().child(content)).child(rule())
            .child(div().h(px(modal::FOOTER_HEIGHT)).w_full().flex_none().flex().items_center().justify_center().gap(px(8.)).px(px(20.)).bg(palette::SIDEBAR.resolve(dark))
                // Cancel is a native default Button in SidebarRenameSheet,
                // not SecondaryButtonStyle. Its final bezel needs native QA.
                .child(div().id("rename-cancel").w(px(89.)).h(px(24.)).rounded(px(6.)).bg(palette::CONTROL_SEAT.resolve(dark)).flex().items_center().justify_center().gap(px(8.)).cursor_pointer().when(disabled,|d|d.opacity(0.42))
                    .child(icon("xmark",11.,primary(dark))).child(presentation::system_text(l("common.cancel"),13.,400,cx))
                    .on_click(cx.listener(|view,_,window,cx|view.cancel_project_rename(window,cx))))
                .child(div().id("rename-save").h(px(control::HEIGHT)).px(px(13.)).rounded(px(8.)).border_1().border_color(palette::ACCENT.opacity(0.35).resolve(dark)).bg(palette::ACCENT_SOFT.resolve(dark)).flex().items_center().gap(px(6.)).cursor_pointer().when(!can_save,|d|d.opacity(0.42))
                    .child(icon("checkmark",12.,palette::ACCENT.resolve(dark))).child(presentation::system_text(l("common.save"),13.,500,cx).text_color(palette::ACCENT.resolve(dark)))
                    .on_click(cx.listener(|view,_,window,cx|view.submit_project_rename(window,cx)))))
    }
    pub(super) fn render_project_rename(&self, dark: bool, cx: &Context<Self>) -> Div {
        div()
            .absolute()
            .inset_0()
            .occlude()
            .bg(gpui::black().opacity(0.25))
            .flex()
            .items_center()
            .justify_center()
            .child(
                self.rename_sheet(dark, cx)
                    .rounded(px(12.))
                    .overflow_hidden()
                    .shadow_lg(),
            )
    }
}
