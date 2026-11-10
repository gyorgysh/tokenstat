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
            self.project_directory.apply_preferences(&preferences);
            self.chat_history.initialize(&preferences);
        }
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
