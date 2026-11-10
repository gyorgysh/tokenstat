// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::design::{GlobalSection, WorkspaceSection};

fn owner(handle: Option<&str>) -> LoginOwner {
    let mut account = crate::desktop_data::DesktopData::fixture().account.unwrap();
    account.signed_in = handle.is_some();
    account.handle = handle.map(str::to_owned);
    let mut owner = LoginOwner::default();
    owner.update(Some(&account));
    owner
}
fn record(scope: &Scope, name: &str) -> Reference {
    Reference {
        scope: scope.clone(),
        host_identity: "host".into(),
        workspace_id: name.into(),
        kind: super::super::Kind::Workspace,
        item_id: None,
        anchor: None,
    }
}
fn drain(service: &mut Service) {
    for _ in 0..100 {
        let Some(job) = service.next_job() else {
            assert!(service.idle());
            return;
        };
        let result = job.execute();
        service.finish(&job, result);
    }
    panic!("metadata queue did not settle");
}

#[test]
fn bootstrap_waits_for_verified_account_and_signedout_scope_uses_the_persisted_installation() {
    let root = tempfile::tempdir().unwrap();
    let prefs = Preferences::at(root.path().join("work.json"));
    let mut service = Service::new(Some(prefs.clone()));
    drain(&mut service);
    assert!(service.snapshot.is_none() && service.scope().is_none());
    let id = service.installation.clone().unwrap();
    service.set_owner(&owner(None));
    drain(&mut service);
    assert_eq!(service.scope(), Some(Scope::local(id.clone())));
    let reopened = Service::new(Some(prefs));
    let mut reopened = reopened;
    drain(&mut reopened);
    assert_eq!(reopened.installation, Some(id));
    assert!(reopened.scope().is_none());
}

#[test]
fn owner_changes_during_bootstrap_and_retired_reads_never_publish_old_pins() {
    let prefs = Preferences::default();
    let mut service = Service::new(Some(prefs.clone()));
    let first = owner(Some("alice"));
    service.set_owner(&first);
    let boot = service.next_job().unwrap();
    assert!(service.next_job().is_none());
    let mut account = crate::desktop_data::DesktopData::fixture().account.unwrap();
    account.signed_in = true;
    account.handle = Some("bob".into());
    let mut second = first.clone();
    second.update(Some(&account));
    service.set_owner(&second);
    service.finish(&boot, boot.execute());
    drain(&mut service);
    assert_eq!(service.scope().unwrap().identity, "bob");
    let scope = service.scope().unwrap();
    let reference = record(&scope, "bob-folder");
    Pins {
        preferences: prefs.clone(),
    }
    .pin(&reference, "Bob", "folder", Date(1.))
    .unwrap();
    service.refresh();
    let old = service.next_job().unwrap();
    let reading = old.execute();
    account.handle = Some("carol".into());
    second.update(Some(&account));
    service.set_owner(&second);
    assert!(service.snapshot.is_none());
    service.finish(&old, reading);
    assert!(service.snapshot.is_none());
    drain(&mut service);
    assert_eq!(service.snapshot.as_ref().unwrap().scope.identity, "carol");
    assert!(service.snapshot.as_ref().unwrap().pins.is_empty());
}

#[test]
fn concurrent_window_clicks_are_serialized_and_unpin_never_changes_another_account() {
    let prefs = Preferences::default();
    let mut service = Service::new(Some(prefs.clone()));
    service.set_owner(&owner(Some("alice")));
    drain(&mut service);
    let scope = service.scope().unwrap();
    let a = record(&scope, "a");
    let b = record(&scope, "b");
    service.pin(a.clone(), "A".into(), "a".into(), Date(1.));
    let pending = service.next_job().unwrap();
    service.pin(b.clone(), "B".into(), "b".into(), Date(2.));
    service.unpin(a.clone());
    assert!(service.next_job().is_none());
    assert_eq!(service.finish(&pending, pending.execute()), Some(true));
    drain(&mut service);
    let pins = &service.snapshot.as_ref().unwrap().pins;
    assert_eq!(pins.len(), 1);
    assert_eq!(pins[0].reference, b);
    let other = record(
        &Scope::account("https://fixture.invalid", "other").unwrap(),
        "a",
    );
    Pins {
        preferences: prefs.clone(),
    }
    .pin(&other, "Other", "a", Date(3.))
    .unwrap();
    service.unpin(a);
    drain(&mut service);
    assert!(Pins { preferences: prefs }.is_pinned(&other).unwrap());
}

#[test]
fn two_open_pin_menus_cannot_overfill_the_shelf_or_retarget_after_an_owner_change() {
    let prefs = Preferences::default();
    let mut service = Service::new(Some(prefs.clone()));
    let mut alice = owner(Some("alice"));
    service.set_owner(&alice);
    drain(&mut service);
    let scope = service.scope().unwrap();
    let store = Pins {
        preferences: prefs.clone(),
    };
    for index in 0..7 {
        store
            .pin(
                &record(&scope, &format!("seed-{index}")),
                "Seed",
                "Folder",
                Date(index as f64),
            )
            .unwrap();
    }
    service.refresh();
    drain(&mut service);
    assert_eq!(service.snapshot.as_ref().unwrap().pins.len(), 7);
    let first = record(&scope, "first-window");
    let second = record(&scope, "second-window");
    service.pin(
        first.clone(),
        "Captured title".into(),
        "Captured folder".into(),
        Date(8.),
    );
    service.pin(second.clone(), "Ninth".into(), "Folder".into(), Date(9.));
    let mut changed = crate::desktop_data::DesktopData::fixture().account.unwrap();
    changed.signed_in = true;
    changed.handle = Some("bob".into());
    alice.update(Some(&changed));
    service.set_owner(&alice);
    drain(&mut service);
    let pins = store.pins(Some(&scope)).unwrap();
    assert_eq!(pins.len(), 8);
    assert!(store.is_pinned(&first).unwrap());
    assert!(!store.is_pinned(&second).unwrap());
    assert_eq!(pins[0].label, "Captured title");
    assert_eq!(pins[0].folder_name, "Captured folder");
    let current = service.snapshot.unwrap();
    assert_eq!(current.scope.identity, "bob");
    assert!(current.pins.is_empty());
}

#[test]
fn failed_reads_retain_same_owner_snapshot_and_bootstrap_errors_survive_owner_changes() {
    let mut service = Service::new(Some(Preferences::default()));
    service.set_owner(&owner(Some("alice")));
    drain(&mut service);
    let scope = service.scope();
    service.refresh();
    let job = service.next_job().unwrap();
    service.finish(&job, Err("fixture read failure".into()));
    assert_eq!(service.snapshot.as_ref().map(|s| s.scope.clone()), scope);
    assert!(service.error.is_some());
    let mut boot = Service::new(Some(Preferences::default()));
    let job = boot.next_job().unwrap();
    boot.set_owner(&owner(Some("alice")));
    boot.finish(&job, Err("fixture bootstrap failure".into()));
    assert!(boot.error.is_some());
    assert!(boot.installation.is_none());
    boot.refresh();
    drain(&mut boot);
    assert_eq!(boot.scope().unwrap().identity, "alice");
    assert!(boot.error.is_none());
}

#[test]
fn navigation_captures_ownership_at_click_time_and_nonrestorable_routes_clear_the_record() {
    let prefs = Preferences::default();
    let mut service = Service::new(Some(prefs.clone()));
    service.set_owner(&owner(Some("alice")));
    drain(&mut service);
    service.finish_identity(Ok("host".into()));
    service.remember_route(
        &Route::Workspace {
            id: "a".into(),
            section: WorkspaceSection::Chat,
        },
        Date(1.),
    );
    let mut account = crate::desktop_data::DesktopData::fixture().account.unwrap();
    account.signed_in = true;
    account.handle = Some("bob".into());
    let mut next = service.owner.clone();
    next.update(Some(&account));
    service.set_owner(&next);
    drain(&mut service);
    let continuity = Continuity { preferences: prefs };
    assert_eq!(
        continuity
            .place()
            .unwrap()
            .unwrap()
            .folder
            .unwrap()
            .scope
            .identity,
        "alice"
    );
    service.remember_route(
        &Route::Global {
            section: GlobalSection::Account,
        },
        Date(2.),
    );
    drain(&mut service);
    assert_eq!(
        continuity
            .place()
            .unwrap()
            .unwrap()
            .global_section
            .as_deref(),
        Some("account")
    );
    service.remember_route(&Route::WorkspacesOverview, Date(3.));
    drain(&mut service);
    assert!(continuity.place().unwrap().is_none());
}

#[test]
fn shutdown_drains_writes_and_disabled_fixtures_never_start_io() {
    let mut fixture = Service::new(None);
    fixture.refresh();
    fixture.remember_route(&Route::default(), Date(1.));
    assert!(fixture.next_job().is_none());
    assert!(!fixture.begin_identity());
    let mut service = Service::new(Some(Preferences::default()));
    service.set_owner(&owner(Some("alice")));
    drain(&mut service);
    let reference = record(&service.scope().unwrap(), "a");
    service.pin(reference, "A".into(), "a".into(), Date(1.));
    service.refresh();
    service.start_shutdown();
    assert!(!service.idle());
    drain(&mut service);
    assert_eq!(service.snapshot.unwrap().pins.len(), 1);
}

#[test]
fn windows_share_metadata_but_resolve_their_own_directory_labels_and_readiness() {
    let prefs = Preferences::default();
    let mut service = Service::new(Some(prefs.clone()));
    service.set_owner(&owner(Some("alice")));
    drain(&mut service);
    let mut reference = record(&service.scope().unwrap(), "a");
    reference.kind = crate::work::Kind::Conversation;
    reference.item_id = Some("item".into());
    Continuity { preferences: prefs }
        .remember(&reference, Date(1.))
        .unwrap();
    service.refresh();
    drain(&mut service);
    assert!(service.home_reading(Some(&[]), &[]).is_none());
    service.finish_identity(Ok("host".into()));
    assert!(service.home_reading(None, &[]).is_none());
    let folder = crate::desktop_data::Repository {
        id: "a".into(),
        name: "left-window-name".into(),
        path: "/fixture/a".into(),
        exists: true,
        git_status_pending: None,
        machine_id: None,
        machine_label: None,
    };
    let mut renamed = folder.clone();
    renamed.name = "right-window-name".into();
    let left = service.home_reading(Some(&[folder]), &[]).unwrap();
    let right = service.home_reading(Some(&[renamed]), &[]).unwrap();
    assert!(left.recent_rows()[0].title.contains("left-window-name"));
    assert!(right.recent_rows()[0].title.contains("right-window-name"));
    assert!(
        service.home_reading(Some(&[]), &[]).unwrap().recent_rows()[0]
            .unavailable
            .is_some()
    );
}

#[test]
fn helper_restart_keeps_scope_owned_metadata_but_fences_pending_deliveries() {
    let mut service = Service::new(Some(Preferences::default()));
    service.set_owner(&owner(Some("alice")));
    drain(&mut service);
    let reference = record(&service.scope().unwrap(), "a");
    service.pin(reference, "A".into(), "a".into(), Date(1.));
    drain(&mut service);
    service.refresh();
    let pending = service.next_job().unwrap();
    let result = pending.execute();
    let mut account = crate::desktop_data::DesktopData::fixture().account.unwrap();
    account.signed_in = true;
    account.handle = Some("alice".into());
    account.account_session = Some("restarted-helper".into());
    let mut next = service.owner.clone();
    next.update(Some(&account));
    service.set_owner(&next);
    assert_eq!(service.snapshot.as_ref().unwrap().pins.len(), 1);
    service.finish(&pending, result);
    assert_eq!(service.snapshot.as_ref().unwrap().pins.len(), 1);
    drain(&mut service);
}
