// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

#[test]
fn fixture_pinning_uses_source_validation_capacity_and_captured_scope_without_disk_io() {
    let mut work = HomeWork::fixture();
    work.pins.clear();
    let mut reference = work.recent[0].clone();
    reference.kind = Kind::Workspace;
    reference.item_id = None;
    for index in 0..8 {
        reference.workspace_id = format!("fixture-{index}");
        assert!(
            work.pin_ephemeral(reference.clone(), " Name\n", "Folder")
                .unwrap()
        );
    }
    assert_eq!(work.pins.len(), 8);
    assert_eq!(work.pins[0].label, "Name");
    let first = work.pins[0].reference.clone();
    reference.workspace_id = "ninth".into();
    assert!(
        !work
            .pin_ephemeral(reference.clone(), "Ninth", "Folder")
            .unwrap()
    );
    assert!(
        work.pin_ephemeral(first.clone(), "Renamed", "Folder")
            .unwrap()
    );
    assert_eq!(work.pins[0].label, "Renamed");
    work.unpin(&first);
    assert!(
        work.pin_ephemeral(reference.clone(), "Ninth", "Folder")
            .unwrap()
    );
    assert_eq!(work.pins.len(), 8);
    reference.scope = Scope::local("retired-scope");
    assert!(
        work.pin_ephemeral(reference.clone(), "Old scope", "Folder")
            .unwrap()
    );
    assert!(
        work.pins
            .iter()
            .all(|pin| pin.reference.scope != reference.scope)
    );
}

#[test]
fn recent_work_filters_before_projection_without_backfilling_or_peer_io() {
    let mut work = HomeWork::fixture();
    let fifth = work.recent[0].clone();
    work.recent.push(fifth);
    work.catalog.conversations.get_mut("alpha").unwrap()[0].unused = true;
    work.catalog.machines.clear();
    let rows = work.recent_rows();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].reference.workspace_id, "previous");
    assert!(rows[0].unavailable.is_some());
    work.catalog.scope = None;
    assert!(work.recent_rows().is_empty() && work.pin_rows().is_empty());
}

#[test]
fn revocation_beats_saved_copies_and_open_requests_recheck_current_facts() {
    let mut work = HomeWork::fixture();
    let saved = work.recent[2].clone();
    assert!(matches!(
        work.catalog.open_recent(&saved),
        Some(OpenTarget::SavedCopy { .. })
    ));
    work.catalog.access.insert("peer-fixture".into(), false);
    assert!(work.catalog.open_recent(&saved).is_none());
    assert!(work.catalog.open_pin(&work.pins[1]).is_none());
    work.catalog.access.insert("peer-fixture".into(), true);
    work.catalog.machines.clear();
    assert!(work.catalog.open_recent(&saved).is_none());
}

#[test]
fn unpin_keeps_the_same_item_on_other_hosts_workspaces_and_accounts() {
    let mut work = HomeWork::fixture();
    let reference = work.pins[1].reference.clone();
    let mut other = work.pins[1].clone();
    other.reference.host_identity = "other-peer".into();
    work.pins.push(other);
    let mut anchored = reference.clone();
    anchored.anchor = Some("reading-position".into());
    work.unpin(&anchored);
    assert_eq!(work.pins.len(), 3);
    assert_eq!(work.pins[2].reference.host_identity, "other-peer");
}

#[test]
fn a_live_host_does_not_restore_an_ended_terminal() {
    let mut work = HomeWork::fixture();
    work.catalog.machines[0].online = Some(true);
    let pin = &work.pins[2];
    assert_eq!(
        work.catalog.availability(&pin.reference),
        Availability::Live
    );
    assert!(work.catalog.open_pin(pin).is_none());
    work.catalog
        .terminals
        .insert("remote:peer-fixture:beta".into(), vec!["ended".into()]);
    assert!(matches!(
        work.catalog.open_pin(pin),
        Some(OpenTarget::Terminal { .. })
    ));
    work.catalog.scope.as_mut().unwrap().identity = "another-account".into();
    assert!(work.catalog.open_pin(pin).is_none());
}
