// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Per-window disclosures use the shared app-owned preference worker.

use super::{home_shared::HomeShared, *};
use crate::sidebar::service::Service;

pub(super) fn service(client: Option<&Client>) -> Service {
    Service::new(super::work_metadata::device_preferences(client))
}
pub(super) fn pump(app: &mut App) {
    let Some(job) = app.global_mut::<HomeShared>().sidebar.next_job() else {
        return;
    };
    let request = job.clone();
    let worker = app
        .background_executor()
        .spawn(async move { request.execute() });
    app.spawn(async move |cx| {
        let result = worker.await;
        let _ = cx.update(|app| {
            app.global_mut::<HomeShared>().sidebar.finish(&job, result);
            pump(app);
        });
    })
    .detach();
}
impl Desktop {
    pub(super) fn sync_sidebar_preferences(&mut self, cx: &mut Context<Self>) {
        if let Some(preferences) = cx.global::<HomeShared>().sidebar.reading() {
            let detail = preferences.chat_detail();
            let migrate_detail = preferences.needs_chat_detail_migration();
            self.project_directory.apply_preferences(&preferences);
            self.chat_history.initialize(&preferences);
            if !self.projects_display_initialized {
                self.projects_display = preferences.projects_display();
                self.projects_display_initialized = true;
            }
            if !self.projects_sort_initialized {
                self.projects_sort = preferences.projects_sort();
                self.projects_sort_initialized = true;
            }
            self.apply_chat_detail(detail, cx);
            if migrate_detail {
                cx.global_mut::<HomeShared>()
                    .sidebar
                    .set_chat_detail(detail);
                pump(cx);
            }
        }
    }
    pub(super) fn apply_chat_detail(&mut self, detail: ChatDetail, cx: &mut Context<Self>) {
        if self.detail == detail {
            return;
        }
        self.detail = detail;
        install_native_menus(detail, cx);
        let folders = self.chat_readers.keys().cloned().collect::<Vec<_>>();
        for folder in folders {
            self.sync_chat_fold(&folder, cx);
        }
        cx.notify();
    }
    pub(super) fn set_projects_display(
        &mut self,
        display: crate::sidebar::ProjectsDisplay,
        cx: &mut Context<Self>,
    ) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        self.projects_display = display;
        self.projects_display_initialized = true;
        if let Some(field) = &self.projects_filter {
            let prompt = l(if display == crate::sidebar::ProjectsDisplay::ByChat {
                "common.sidebar.filter_chats"
            } else {
                "common.sidebar.filter_repositories"
            });
            field.update(cx, |field, cx| {
                field.set_placeholder(prompt);
                cx.notify();
            });
        }
        cx.global_mut::<HomeShared>()
            .sidebar
            .set_projects_display(display);
        self.sync_chat_directories(cx);
        pump(cx);
        cx.notify();
    }
    pub(super) fn set_projects_sort(
        &mut self,
        sort: crate::sidebar::ProjectsSort,
        cx: &mut Context<Self>,
    ) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        self.projects_sort = sort;
        self.projects_sort_initialized = true;
        cx.global_mut::<HomeShared>()
            .sidebar
            .set_projects_sort(sort);
        self.sync_chat_directories(cx);
        pump(cx);
        cx.notify();
    }
    pub(super) fn set_projects_expanded(&mut self, expanded: bool, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        self.project_directory.set_projects_expanded(expanded);
        self.sync_chat_directories(cx);
        cx.global_mut::<HomeShared>()
            .sidebar
            .remember_expansion("section:projects".into(), expanded);
        pump(cx);
        cx.notify();
    }
    pub(super) fn set_project_expanded(
        &mut self,
        id: &str,
        expanded: bool,
        cx: &mut Context<Self>,
    ) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        let expand_section = expanded && self.project_directory.needs_projects_expansion();
        self.project_directory.set_expanded(id, expanded);
        self.sync_chat_directories(cx);
        let sidebar = &mut cx.global_mut::<HomeShared>().sidebar;
        if expand_section {
            sidebar.remember_expansion("section:projects".into(), true);
        }
        sidebar.remember_expansion(format!("project:{id}"), expanded);
        pump(cx);
        cx.notify();
    }
}
