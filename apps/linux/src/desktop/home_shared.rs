// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Shared account ownership, device arrangement and vendor quota flights.

use super::*;
use crate::home::{
    layout::{Arrangement, Storage},
    plans::{
        self, Reads,
        store::{Refresh, RefreshError},
    },
};
use std::cell::Cell;
use std::time::Duration;

pub(super) struct HomeShared {
    pub account: crate::account_state::AccountState,
    pub transport_epoch: std::sync::Arc<std::sync::atomic::AtomicU64>,
    pub work: Option<crate::home::work::HomeWork>,
    pub metadata: crate::work::service::Service,
    pub sidebar: crate::sidebar::service::Service,
    pub quit_requested: bool,
    pub archive_revision: u64,
    pub layout: Arrangement,
    pub storage: Storage,
    pub preferences_error: Option<String>,
    pub preferences_saving: bool,
    pub reads: Reads,
    pub clock_ms: i64,
    pub clock_read: Cell<bool>,
}
impl gpui::Global for HomeShared {}
pub(super) fn initialize(client: Option<&Client>, app: &mut App) {
    let path = if cfg!(target_os = "linux") && client.is_some() {
        super::work_metadata::preferences_root().map(|p| p.join("desktop-home.json"))
    } else {
        None
    };
    let storage = Storage { path };
    let (layout, preferences_error) = match storage.load() {
        Ok(layout) => (layout, None),
        Err(e) => (Arrangement::default(), Some(format!("{e:#}"))),
    };
    let now = plans::now_ms();
    let account = if client.is_none() {
        crate::account_state::AccountState::fixture()
    } else {
        crate::account_state::AccountState::default()
    };
    let owner = account.owner.generation();
    app.set_global(HomeShared {
        transport_epoch: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(owner)),
        account,
        metadata: super::work_metadata::service(client),
        sidebar: super::sidebar_preferences::service(client),
        quit_requested: false,
        archive_revision: 0,
        work: client.is_none().then(|| {
            use crate::home::work::{Catalog, Folder, HomeWork};
            HomeWork {
                catalog: Catalog {
                    scope: Some(crate::work::Scope::local("fixture-installation")),
                    local_host_identity: Some("fixture-host".into()),
                    folders: DesktopData::fixture()
                        .repositories
                        .unwrap_or_default()
                        .into_iter()
                        .map(|folder| Folder {
                            id: folder.id,
                            name: folder.name,
                            machine_label: folder.machine_label,
                        })
                        .collect(),
                    ..Default::default()
                },
                ..Default::default()
            }
        }),
        layout,
        storage,
        preferences_error,
        preferences_saving: false,
        reads: if client.is_none() {
            Reads::fixture_for_owner(now, owner)
        } else {
            Reads::default()
        },
        clock_ms: now,
        clock_read: Cell::new(false),
    });
    super::work_metadata::pump(app);
    super::sidebar_preferences::pump(app);
    if let Some(client) = client {
        super::work_metadata::identity(client.clone(), app);
    }
    // One coarse clock. Reading rows mark interest without notifying observers
    // during rendering; a window with no relative text causes no redraw.
    app.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(Duration::from_secs(15))
                .await;
            if cx
                .update(|app| {
                    if app.global::<HomeShared>().clock_read.replace(false) {
                        app.global_mut::<HomeShared>().clock_ms = plans::now_ms();
                    }
                })
                .is_err()
            {
                break;
            }
        }
    })
    .detach();
}
impl HomeShared {
    pub fn accept_account(
        &mut self,
        ticket: crate::account_state::ReadTicket,
        account: Result<Account, String>,
    ) {
        let previous_owner = self.account.owner.generation();
        if self.account.accept(ticket, account) {
            self.transport_epoch.store(
                self.account.owner.generation(),
                std::sync::atomic::Ordering::Release,
            );
            self.metadata.set_owner(&self.account.owner);
            self.metadata.refresh();
            self.reads.set_owner(self.account.owner.generation());
            if previous_owner != self.account.owner.generation() {
                self.work = None;
            }
        }
    }
}
impl Desktop {
    pub(super) fn load_home_plans(&mut self, force: bool, cx: &mut Context<Self>) {
        let visible = self.navigation.route == Route::default()
            && !cx
                .global::<HomeShared>()
                .layout
                .hidden
                .contains(&crate::home::layout::Section::Limits);
        if !visible {
            return;
        }
        let Some(client) = self.client.clone() else {
            return;
        };
        let Some(load) = cx.global_mut::<HomeShared>().reads.begin_home(
            self.plan_reader,
            force,
            plans::now_ms(),
            visible,
        ) else {
            return;
        };
        let usage_client = client.clone();
        let usage = cx
            .background_executor()
            .spawn(async move { usage_client.plan_usage().map_err(|e| format!("{e:#}")) });
        cx.spawn(async move |_, cx| {
            let result = usage.await;
            let _ = cx.update(|cx| {
                cx.global_mut::<HomeShared>()
                    .reads
                    .finish_usage(load.request, result);
            });
        })
        .detach();
        let Refresh::Start(flight) = load.refresh else {
            return;
        };
        let cache_client = client.clone();
        let cache = cx
            .background_executor()
            .spawn(async move { cache_client.plan_cache().map_err(|e| format!("{e:#}")) });
        cx.spawn(async move |_, cx| {
            let result = cache.await;
            let proceed = cx
                .update(|cx| {
                    let reads = &mut cx.global_mut::<HomeShared>().reads;
                    match result {
                        Ok(cache) => {
                            if reads.accept_cache(flight, cache) {
                                true
                            } else {
                                reads.finish_limits(
                                    flight,
                                    Err(RefreshError::Retired),
                                    plans::now_ms(),
                                );
                                false
                            }
                        }
                        Err(e) => {
                            reads.finish_limits(
                                flight,
                                Err(RefreshError::Failed(e)),
                                plans::now_ms(),
                            );
                            false
                        }
                    }
                })
                .unwrap_or(false);
            if !proceed {
                return;
            }
            let live = cx
                .background_executor()
                .spawn(async move { client.plan_limits(force).map_err(|e| format!("{e:#}")) });
            let result = live.await;
            let _ = cx.update(|cx| {
                cx.global_mut::<HomeShared>().reads.finish_limits(
                    flight,
                    result.map_err(RefreshError::Failed),
                    plans::now_ms(),
                );
            });
        })
        .detach();
    }
    pub(super) fn watch_home_plans(&mut self, cx: &mut Context<Self>) {
        cx.spawn(async move |view, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            loop {
                if view
                    .update(cx, |view, cx| {
                        if view.active {
                            view.load_home_plans(false, cx)
                        }
                    })
                    .is_err()
                {
                    break;
                }
                cx.background_executor()
                    .timer(Duration::from_secs(30))
                    .await;
            }
        })
        .detach();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_state::AccountState;
    use serde_json::json;
    #[test]
    fn accepted_login_updates_the_global_read_owner_and_late_status_cannot_reverse_it() {
        let account = AccountState::fixture();
        let mut shared = HomeShared {
            transport_epoch: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(
                account.owner.generation(),
            )),
            metadata: crate::work::service::Service::new(None),
            sidebar: crate::sidebar::service::Service::new(None),
            quit_requested: false,
            archive_revision: 0,
            work: Some(crate::home::work::HomeWork::fixture()),
            reads: Reads::fixture_for_owner(1_000_000, account.owner.generation()),
            account,
            layout: Arrangement::default(),
            storage: Storage { path: None },
            preferences_error: None,
            preferences_saving: false,
            clock_ms: 1_000_000,
            clock_read: Cell::new(false),
        };
        let reader = shared.reads.register();
        let old_load = shared
            .reads
            .begin_home(reader, true, 1_000_000, true)
            .unwrap();
        let Refresh::Start(old_flight) = old_load.refresh else {
            panic!("expected flight")
        };
        let old_read = shared.account.begin();
        let new_read = shared.account.begin();
        let signed_in:Account=serde_json::from_value(json!({"machines":[],"signedIn":true,"host":"https://fixture.invalid","handle":"alice","accountSession":"helper:login-two"})).unwrap();
        shared.accept_account(new_read, Ok(signed_in));
        assert!(shared.work.is_none());
        assert_eq!(shared.reads.owner(), shared.account.owner.generation());
        assert!(
            shared.reads.visible().is_empty() && shared.reads.home(reader).by_source.is_empty()
        );
        assert!(!shared.reads.finish_usage(old_load.request, Ok(vec![])));
        shared.reads.finish_limits(
            old_flight,
            Ok(plans::fixture_cache(1_000_001).providers),
            1_000_001,
        );
        assert!(!shared.reads.home(reader).has_loaded);
        shared.accept_account(
            old_read,
            crate::desktop_data::DesktopData::fixture().account,
        );
        assert_eq!(
            shared.account.owner.account_session(),
            Some("helper:login-two")
        );
        assert!(shared.reads.visible().is_empty());
    }
}
