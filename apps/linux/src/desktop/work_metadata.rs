// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Shared IO outlives individual windows. View-owned loaded models supply the
//! current labels and availability, without metadata initiating peer reads.
//! Startup restoration is intentionally not applied after a visible first paint.

use super::home_shared::HomeShared;
use super::*;
use crate::{
    home::work::HomeWork,
    work::{continuity::Date, preferences::Preferences, service::Service},
};

pub(super) fn preferences_root() -> Option<std::path::PathBuf> {
    let override_path = std::env::var_os("TOKENSTAT_DATA_DIR").map(std::path::PathBuf::from);
    override_path
        .filter(|p| p.is_absolute())
        .map(|p| p.join("desktop-preferences"))
        .or_else(tokenstat_paths::config_dir)
}

pub(super) fn device_preferences(client: Option<&Client>) -> Option<Preferences> {
    client?;
    if cfg!(target_os = "linux") {
        if let Some(path) = preferences_root() {
            return Some(Preferences::at(path.join("desktop-work.json")));
        }
        None
    } else {
        // Connected macOS previews must never load or persist production prefs.
        Some(Preferences::default())
    }
}

pub(super) fn service(client: Option<&Client>) -> Service {
    let mut service = Service::new(device_preferences(client));
    if client.is_some() && cfg!(target_os = "linux") && preferences_root().is_none() {
        service.error = Some("No device-local configuration directory is available".into());
    }
    service
}

pub(super) fn pump(app: &mut App) {
    let Some(job) = app.global_mut::<HomeShared>().metadata.next_job() else {
        return;
    };
    let request = job.clone();
    let worker = app
        .background_executor()
        .spawn(async move { request.execute() });
    app.spawn(async move |cx| {
        let result = worker.await;
        let _ = cx.update(|app| {
            app.global_mut::<HomeShared>().metadata.finish(&job, result);
            pump(app);
        });
    })
    .detach();
}

pub(super) fn request_quit(app: &mut App) {
    if app.global::<HomeShared>().quit_requested {
        return;
    }
    let shared = app.global_mut::<HomeShared>();
    shared.quit_requested = true;
    shared.metadata.start_shutdown();
    shared.sidebar.start_shutdown();
    let preferences_ready =
        shared.metadata.idle() && shared.sidebar.idle() && !shared.preferences_saving;
    app.global_mut::<super::draft_marks::Shared>()
        .service
        .start_shutdown();
    let ready = preferences_ready && app.global::<super::draft_marks::Shared>().service.idle();
    if ready {
        app.quit();
        return;
    }
    pump(app);
    super::sidebar_preferences::pump(app);
    super::draft_marks::pump(app);
    app.spawn(async move |cx| {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let state = cx.update(|app| {
                let shared = app.global::<HomeShared>();
                shared.metadata.idle()
                    && shared.sidebar.idle()
                    && !shared.preferences_saving
                    && app.global::<super::draft_marks::Shared>().service.idle()
            });
            match state {
                Ok(true) => {
                    let _ = cx.update(|app| app.quit());
                    break;
                }
                Err(_) => break,
                _ if std::time::Instant::now() >= deadline
                    && cx
                        .update(|app| app.global::<super::draft_marks::Shared>().service.idle())
                        .unwrap_or(false) =>
                {
                    eprintln!("tokenstat: timed out draining desktop preferences during quit");
                    let _ = cx.update(|app| app.quit());
                    break;
                }
                _ => {
                    cx.background_executor()
                        .timer(std::time::Duration::from_millis(20))
                        .await
                }
            }
        }
    })
    .detach();
}

pub(super) fn identity(client: Client, app: &mut App) {
    if !app.global_mut::<HomeShared>().metadata.begin_identity() {
        return;
    }
    let worker = app
        .background_executor()
        .spawn(async move { client.public_identity().map_err(|e| format!("{e:#}")) });
    app.spawn(async move |cx| {
        let result = worker.await;
        let _ = cx.update(|app| {
            app.global_mut::<HomeShared>()
                .metadata
                .finish_identity(result)
        });
    })
    .detach();
}

impl Desktop {
    pub(super) fn preview_error(&self, app: &App) -> Option<String> {
        let mut errors = self.error.iter().cloned().collect::<Vec<_>>();
        if self.client.is_some() {
            let metadata = &app.global::<HomeShared>().metadata;
            errors.extend(metadata.error.iter().cloned());
            errors.extend(metadata.identity_error.iter().cloned());
            errors.extend(app.global::<HomeShared>().sidebar.error());
            errors.extend(
                app.global::<super::draft_marks::Shared>()
                    .service
                    .error
                    .iter()
                    .cloned(),
            );
        }
        (!errors.is_empty()).then(|| errors.join("\n"))
    }
    pub(super) fn work_reading(&self, app: &App) -> Option<HomeWork> {
        let shared = app.global::<HomeShared>();
        if self.client.is_none() {
            return shared.work.clone();
        }
        let folders = self
            .directory_loaded
            .then(|| {
                self.data
                    .as_ref()
                    .and_then(|data| data.repositories.as_ref().ok())
                    .map(Vec::as_slice)
            })
            .flatten();
        let machines = shared
            .account
            .account
            .as_ref()
            .map(|a| a.machines.as_slice())
            .unwrap_or_default();
        let mut reading = shared.metadata.home_reading(folders, machines)?;
        for folder in &reading.catalog.folders {
            let rows = self
                .chat_directory
                .rows(&folder.id)
                .iter()
                .filter_map(|row| {
                    row.unused(self.draft_fact(&folder.id, &row.id, app))
                        .map(|unused| crate::home::work::Conversation {
                            id: row.id.clone(),
                            title: row.title.clone(),
                            unused,
                        })
                })
                .collect();
            reading
                .catalog
                .conversations
                .insert(folder.id.clone(), rows);
        }
        Some(reading)
    }
    pub(super) fn unpin_home(&mut self, reference: crate::work::Reference, cx: &mut Context<Self>) {
        if self.client.is_none() {
            if let Some(work) = cx.global_mut::<HomeShared>().work.as_mut() {
                work.unpin(&reference);
            }
        } else {
            cx.global_mut::<HomeShared>().metadata.unpin(reference);
            pump(cx);
        }
        cx.notify();
    }
    fn remember_work_route(&mut self, cx: &mut Context<Self>) {
        if self.client.is_none() {
            return;
        }
        cx.global_mut::<HomeShared>().metadata.remember_route(
            &self.navigation.route,
            Date::from_unix_ms(crate::home::plans::now_ms()),
        );
        pump(cx);
    }
    pub(super) fn navigate(&mut self, route: Route, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        self.navigation.navigate(route);
        self.sync_chat_watch(cx);
        self.sync_account_insights(cx);
        self.sync_local_insights(cx);
        self.remember_work_route(cx);
    }
    pub(super) fn open_rail(&mut self, place: RailPlace, cx: &mut Context<Self>) {
        if cx.global::<HomeShared>().quit_requested {
            return;
        }
        self.navigation.open_rail(place);
        self.sync_chat_watch(cx);
        self.sync_account_insights(cx);
        self.sync_local_insights(cx);
        self.remember_work_route(cx);
    }
}
