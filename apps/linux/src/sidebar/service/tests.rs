// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use serde_json::json;

fn drain(service: &mut Service) {
    while let Some(job) = service.next_job() {
        let result = job.execute();
        service.finish(&job, result);
    }
    assert!(service.idle());
}
fn collapse(key: &str) -> Mutation {
    Mutation::Expansion {
        key: key.into(),
        expanded: false,
    }
}

#[test]
fn stores_reopen_and_merge_independent_keys_without_losing_future_values() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("preferences.json");
    let first = Store {
        preferences: Preferences::at(path.clone()),
    };
    let second = Store {
        preferences: Preferences::at(path.clone()),
    };
    first
        .preferences
        .update(|values| {
            values.insert(
                "shell.sidebar.sectionOrder".into(),
                json!(["future", {"layout":{"version":8}}, "servers", "servers", "projects", 7]),
            );
            values.insert("shell.sidebarWidth".into(), json!(350));
            values.insert(
                "shell.sidebar.expanded.future:row".into(),
                json!({"layout":{"version":8}}),
            );
            values.insert("shell.sidebar.expanded.project:number".into(), json!(1));
            Ok(())
        })
        .unwrap();
    first.mutate(&collapse("project:a")).unwrap();
    second.mutate(&collapse("section:projects")).unwrap();
    first
        .mutate(&Mutation::Move {
            section: "projects".into(),
            before: "servers".into(),
        })
        .unwrap();
    let reopened = Store {
        preferences: Preferences::at(path),
    };
    let snapshot = reopened.read().unwrap();
    assert!(!snapshot.is_expanded("project:a", true));
    assert!(!snapshot.is_expanded("section:projects", true));
    assert!(snapshot.is_expanded("project:new", true));
    assert!(!snapshot.is_expanded("project:number", false));
    assert_eq!(snapshot.section_order(), ["projects", "servers"]);
    reopened
        .preferences
        .read(|values| {
            assert_eq!(values["shell.sidebarWidth"], 350);
            assert_eq!(
                values["shell.sidebar.expanded.future:row"],
                json!({"layout":{"version":8}})
            );
            assert_eq!(
                values["shell.sidebar.sectionOrder"],
                json!(["future", {"layout":{"version":8}}, "projects", "servers", "servers", 7])
            );
        })
        .unwrap();
}

#[test]
fn late_read_and_older_write_cannot_reverse_a_later_click_or_complete_twice() {
    let preferences = Preferences::default();
    let mut service = Service::new(Some(preferences.clone()));
    let read = service.next_job().unwrap();
    let before = read.execute();
    service.remember_expansion("project:a".into(), false);
    assert!(service.reading().is_none());
    assert!(service.finish(&read, before));
    assert!(!service.reading().unwrap().is_expanded("project:a", true));
    let write = service.next_job().unwrap();
    let result = write.execute();
    service.remember_expansion("project:a".into(), true);
    assert!(service.finish(&write, result));
    assert!(!service.finish(&write, Err("duplicate".into())));
    assert!(service.reading().unwrap().is_expanded("project:a", false));
    drain(&mut service);
    assert!(
        Store { preferences }
            .read()
            .unwrap()
            .is_expanded("project:a", false)
    );
    assert!(service.error().is_none());
}

#[test]
fn failed_intent_and_its_error_survive_unrelated_success_until_same_key_retry() {
    let preferences = Preferences::default();
    let mut service = Service::new(Some(preferences));
    drain(&mut service);
    service.remember_expansion("project:a".into(), false);
    let failed = service.next_job().unwrap();
    service.finish(&failed, Err("disk unavailable".into()));
    service.remember_expansion("project:b".into(), false);
    drain(&mut service);
    assert!(!service.reading().unwrap().is_expanded("project:a", true));
    assert!(!service.reading().unwrap().is_expanded("project:b", true));
    assert_eq!(service.error().as_deref(), Some("disk unavailable"));
    service.refresh();
    drain(&mut service);
    assert_eq!(service.error().as_deref(), Some("disk unavailable"));
    service.remember_expansion("project:a".into(), false);
    drain(&mut service);
    assert!(service.error().is_none());
    assert!(!service.reading().unwrap().is_expanded("project:a", true));
}

#[test]
fn shutdown_drains_every_captured_mutation_and_drops_only_queued_reads() {
    let preferences = Preferences::default();
    let mut service = Service::new(Some(preferences.clone()));
    let read = service.next_job().unwrap();
    service.remember_expansion("project:a".into(), false);
    service.refresh();
    service.remember_expansion("project:b".into(), false);
    service.start_shutdown();
    service.remember_expansion("project:ignored".into(), false);
    assert!(!service.idle());
    service.finish(&read, read.execute());
    drain(&mut service);
    let saved = Store { preferences }.read().unwrap();
    assert!(!saved.is_expanded("project:a", true));
    assert!(!saved.is_expanded("project:b", true));
    assert!(saved.is_expanded("project:ignored", true));
    let mut fixture = Service::new(None);
    fixture.remember_expansion("project:a".into(), false);
    fixture.move_section("servers".into(), "projects".into());
    assert!(fixture.next_job().is_none() && fixture.idle());
    assert!(!fixture.reading().unwrap().is_expanded("project:a", true));
    assert_eq!(
        fixture.reading().unwrap().section_order(),
        ["servers", "projects"]
    );
}

#[test]
fn damaged_file_is_retained_and_read_failure_does_not_claim_an_empty_loaded_store() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("preferences.json");
    std::fs::write(&path, b"broken").unwrap();
    let mut service = Service::new(Some(Preferences::at(path.clone())));
    drain(&mut service);
    assert!(service.reading().is_none() && service.error().is_some());
    service.remember_expansion("project:a".into(), false);
    drain(&mut service);
    assert_eq!(std::fs::read(path).unwrap(), b"broken");
    assert!(service.reading().is_none() && service.error().is_some());
}
