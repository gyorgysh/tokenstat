// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Draft words stay outside preferences and out of view invalidation. Only
//! membership changes notify the small mark which owns that conversation key.

use super::{home_shared::HomeShared, *};
use crate::{
    drafts::{service::Service, storage::Storage},
    work::{Kind, Reference},
};
use std::collections::BTreeSet;

pub(super) struct Shared {
    pub service: Service,
    presence: gpui::Entity<Presence>,
}
impl gpui::Global for Shared {}
pub(super) struct Presence {
    initialized: bool,
    occupied: BTreeSet<String>,
    warning: Option<String>,
}
pub(super) struct Change {
    pub readiness: bool,
    pub warning: bool,
    keys: BTreeSet<String>,
}
impl gpui::EventEmitter<Change> for Presence {}
pub(super) fn initialize(client: Option<&Client>, app: &mut App) {
    let storage = if client.is_none() {
        None
    } else if cfg!(target_os = "linux") {
        Some(
            tokenstat_paths::data_dir()
                .filter(|p| p.is_absolute())
                .map(|root| {
                    Storage::at(
                        root.join("desktop-drafts"),
                        crate::drafts::storage::MAX_FILE_BYTES,
                    )
                })
                .unwrap_or_else(|| {
                    Storage::unavailable(
                        "No device-local user-data directory is available for drafts".into(),
                    )
                }),
        )
    } else {
        Some(Storage::default())
    };
    let service = Service::new(storage);
    let initialized = service.initialized;
    let presence = app.new(|_| Presence {
        initialized,
        occupied: BTreeSet::new(),
        warning: None,
    });
    app.set_global(Shared { service, presence });
    pump(app);
}
fn publish(app: &mut App) {
    let shared = app.global::<Shared>();
    let initialized = shared.service.initialized;
    let occupied = shared.service.occupied().clone();
    let warning = shared.service.error.clone();
    let presence = shared.presence.clone();
    presence.update(app, |presence, cx| {
        let keys = presence
            .occupied
            .symmetric_difference(&occupied)
            .cloned()
            .collect::<BTreeSet<_>>();
        let readiness = presence.initialized != initialized;
        let changed_warning = presence.warning != warning;
        presence.initialized = initialized;
        presence.occupied = occupied;
        presence.warning = warning;
        if readiness || changed_warning || !keys.is_empty() {
            cx.emit(Change {
                readiness,
                warning: changed_warning,
                keys,
            });
        }
    });
}
pub(super) fn update<T>(app: &mut App, work: impl FnOnce(&mut Service) -> T) -> T {
    let result = work(&mut app.global_mut::<Shared>().service);
    publish(app);
    pump(app);
    result
}
pub(super) fn pump(app: &mut App) {
    let Some(job) = app.global_mut::<Shared>().service.next_job() else {
        return;
    };
    let request = job.clone();
    let worker = app
        .background_executor()
        .spawn(async move { request.execute() });
    app.spawn(async move |cx| {
        let result = worker.await;
        let _ = cx.update(|app| {
            app.global_mut::<Shared>().service.finish(&job, result);
            publish(app);
            pump(app);
        });
    })
    .detach();
}
pub(super) fn watch(view: &mut Desktop, cx: &mut Context<Desktop>) {
    let presence = cx.global::<Shared>().presence.clone();
    cx.subscribe(&presence, |view, _, change, cx| {
        if change.readiness || change.warning {
            view.sync_chat_directories(cx);
            cx.notify();
        }
    })
    .detach();
    let _ = view;
}
pub(super) struct Mark {
    key: String,
    presence: gpui::Entity<Presence>,
    points: f32,
    dark: bool,
}
impl Mark {
    fn new(
        key: String,
        points: f32,
        dark: bool,
        presence: gpui::Entity<Presence>,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.subscribe(&presence, |view, _, change, cx| {
            if change.readiness || change.keys.contains(&view.key) {
                cx.notify();
            }
        })
        .detach();
        Self {
            key,
            presence,
            points,
            dark,
        }
    }
}
impl Render for Mark {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let occupied = self.presence.read(cx).occupied.contains(&self.key);
        div()
            .when(!occupied, |row| row.hidden())
            .when(occupied, |row| {
                row.child(icon(
                    "pencil",
                    self.points,
                    palette::ACCENT.resolve(self.dark),
                ))
            })
    }
}
impl Desktop {
    pub(super) fn draft_reference(&self, folder: &str, id: &str, cx: &App) -> Option<Reference> {
        let shared = cx.global::<HomeShared>();
        let reference = if self.client.is_some() {
            crate::project_menu::reference(
                shared.metadata.scope().as_ref(),
                shared.metadata.local_host_identity.as_deref(),
                folder,
            )
        } else {
            shared.work.as_ref().and_then(|work| {
                crate::project_menu::reference(
                    work.catalog.scope.as_ref(),
                    work.catalog.local_host_identity.as_deref(),
                    folder,
                )
            })
        };
        reference.map(|mut reference| {
            reference.kind = Kind::Conversation;
            reference.item_id = Some(id.into());
            reference
        })
    }
    pub(super) fn draft_fact(&self, folder: &str, id: &str, cx: &App) -> Option<bool> {
        let reference = self.draft_reference(folder, id, cx)?;
        cx.global::<Shared>().service.presence(&reference)
    }
    pub(super) fn prepare_draft_mark(
        &mut self,
        folder: &str,
        id: &str,
        dark: bool,
        cx: &mut Context<Self>,
    ) -> Option<String> {
        let reference = self.draft_reference(folder, id, cx)?;
        let key = reference.conversation_key()?;
        let points = self.layout.fit.text(9.);
        if let Some(mark) = self.draft_marks.get(&key) {
            mark.update(cx, |mark, cx| {
                if mark.points != points || mark.dark != dark {
                    mark.points = points;
                    mark.dark = dark;
                    cx.notify();
                }
            });
        } else {
            let presence = cx.global::<Shared>().presence.clone();
            let mark = cx.new(|cx| Mark::new(key.clone(), points, dark, presence, cx));
            self.draft_marks.insert(key.clone(), mark);
        }
        Some(key)
    }
}
