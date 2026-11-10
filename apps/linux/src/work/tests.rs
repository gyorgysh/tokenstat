// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use continuity::{Continuity, Date, Place};
use pins::Pins;
use preferences::Preferences;
use serde_json::json;

fn record(scope: &Scope, workspace: &str) -> Reference {
    Reference {
        scope: scope.clone(),
        host_identity: "host".into(),
        workspace_id: workspace.into(),
        kind: Kind::Conversation,
        item_id: Some("item".into()),
        anchor: None,
    }
}

#[test]
fn independent_disk_handles_preserve_current_shortcuts_unknown_fields_and_private_modes() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("work.json");
    std::fs::write(
        &path,
        json!({"version":1,"values":{},"futureOuter":{"keep":true}}).to_string(),
    )
    .unwrap();
    let first = Preferences::at(path.clone());
    let second = Preferences::at(path.clone());
    let scope = Scope::local("installation");
    let a = record(&scope, "a");
    let b = record(&scope, "b");
    first
        .update(|map| {
            map.insert("future".into(), json!({"nested":[1,2,3]}));
            Ok(())
        })
        .unwrap();
    let pins_a = Pins { preferences: first };
    let pins_b = Pins {
        preferences: second,
    };
    assert!(pins_a.pin(&a, "a", "folder", Date(1.)).unwrap());
    assert!(pins_b.pin(&b, "b", "folder", Date(2.)).unwrap());
    pins_a.unpin(&a).unwrap();
    assert!(
        !pins_b
            .relabel_title_if_pinned(&a, "must not return", Date(3.))
            .unwrap()
    );
    assert!(
        pins_b
            .relabel_title_if_pinned(&b, "renamed chat", Date(3.))
            .unwrap()
    );
    let changed = pins_a.pins(Some(&scope)).unwrap();
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].label, "renamed chat");
    assert_eq!(changed[0].folder_name, "folder");
    let reopened = Preferences::at(path.clone());
    let installation = reopened.installation_id().unwrap();
    assert_eq!(installation.len(), 36);
    assert_eq!(
        Preferences::at(path.clone()).installation_id().unwrap(),
        installation
    );
    assert_eq!(
        Pins {
            preferences: reopened.clone()
        }
        .pins(Some(&scope))
        .unwrap()[0]
            .reference,
        b
    );
    assert_eq!(
        reopened.read(|m| m["future"].clone()).unwrap(),
        json!({"nested":[1,2,3]})
    );
    let outer: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(outer["futureOuter"], json!({"keep":true}));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn simultaneous_file_writers_cannot_overwrite_each_others_updates() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("work.json");
    let start = std::sync::Arc::new(std::sync::Barrier::new(3));
    let threads: Vec<_> = (0..2)
        .map(|writer| {
            let path = path.clone();
            let start = start.clone();
            std::thread::spawn(move || {
                let preferences = Preferences::at(path);
                start.wait();
                for step in 0..20 {
                    preferences
                        .update(|map| {
                            let next = map.get("count").and_then(|v| v.as_u64()).unwrap_or(0) + 1;
                            map.insert("count".into(), json!(next));
                            map.insert(format!("writer{writer}"), json!(step));
                            Ok(())
                        })
                        .unwrap();
                    std::thread::yield_now();
                }
            })
        })
        .collect();
    start.wait();
    for thread in threads {
        thread.join().unwrap();
    }
    Preferences::at(path)
        .read(|map| {
            assert_eq!(map["count"], 40);
            assert_eq!(map["writer0"], 19);
            assert_eq!(map["writer1"], 19);
        })
        .unwrap();
}

#[test]
fn damaged_containers_and_failed_transactions_do_not_replace_saved_bytes() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("work.json");
    for bytes in [
        b"{".as_slice(),
        br#"{"version":2,"values":{}}"#,
        br#"{"version":1,"values":[]}"#,
    ] {
        std::fs::write(&path, bytes).unwrap();
        let preferences = Preferences::at(path.clone());
        assert!(
            preferences
                .update(|m| {
                    m.insert("bad".into(), json!(1));
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    std::fs::remove_file(&path).unwrap();
    let preferences = Preferences::at(path.clone());
    preferences
        .update(|m| {
            m.insert("before".into(), json!(1));
            Ok(())
        })
        .unwrap();
    let before = std::fs::read(&path).unwrap();
    assert!(
        preferences
            .update::<()>(|m| {
                m.insert("bad".into(), json!(2));
                anyhow::bail!("fixture failure")
            })
            .is_err()
    );
    assert_eq!(std::fs::read(&path).unwrap(), before);
}

#[cfg(unix)]
#[test]
fn metadata_and_lock_symlinks_are_rejected_without_touching_the_target() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("other.json");
    let path = root.path().join("work.json");
    let before = br#"{"version":1,"values":{"untouched":true}}"#;
    std::fs::write(&target, before).unwrap();
    symlink(&target, &path).unwrap();
    let preferences = Preferences::at(path.clone());
    assert!(preferences.read(|_| ()).is_err());
    assert!(preferences.update(|_| Ok(())).is_err());
    assert_eq!(std::fs::read(&target).unwrap(), before);
    std::fs::remove_file(&path).unwrap();
    std::fs::remove_file(path.with_file_name("work.json.lock")).unwrap();
    symlink(&target, path.with_file_name("work.json.lock")).unwrap();
    assert!(
        preferences
            .update(|m| {
                m.insert("new".into(), json!(1));
                Ok(())
            })
            .is_err()
    );
    assert!(!path.exists());
    assert_eq!(std::fs::read(&target).unwrap(), before);
}

#[test]
fn continuity_keeps_the_source_byte_boundaries_and_global_visit_capacity() {
    let preferences = Preferences::default();
    let store = Continuity {
        preferences: preferences.clone(),
    };
    let scope = Scope::local("installation");
    let visit =
        json!({"version":1,"visits":[{"reference":record(&scope,"a"),"openedAt":1}]}).to_string();
    let exact = format!("{visit}{}", " ".repeat(256 * 1024 - visit.len()));
    preferences
        .update(|m| {
            m.insert("work.continuity.v1".into(), json!(exact));
            Ok(())
        })
        .unwrap();
    assert_eq!(store.recent(&scope, 1000).unwrap().len(), 1);
    preferences
        .update(|m| {
            m.insert("work.continuity.v1".into(), json!(format!("{exact} ")));
            Ok(())
        })
        .unwrap();
    assert!(store.recent(&scope, 1000).unwrap().is_empty());
    for i in 0..105 {
        store
            .remember(&record(&scope, &format!("f{i}")), Date(i as f64))
            .unwrap();
    }
    let recent = store.recent(&scope, 1000).unwrap();
    assert_eq!(recent.len(), 100);
    assert_eq!(recent[0].workspace_id, "f104");
    assert_eq!(recent[99].workspace_id, "f5");
    assert!(store.recent(&scope, -1).unwrap().is_empty());
}

#[test]
fn local_launch_restoration_does_not_grant_remote_work_to_another_account() {
    let a = Scope::local("a");
    let b = Scope::local("b");
    let mut reference = record(&a, "a");
    reference.kind = Kind::Workspace;
    reference.item_id = None;
    let local = Place::workspace(reference.clone(), "chat".into(), Date(1.)).unwrap();
    let ids = vec!["a".into(), "remote:peer:a".into()];
    assert!(continuity::restore(Some(&local), &ids, None, Some("host")).is_some());
    reference.host_identity = "peer".into();
    let remote = Place::workspace(reference, "chat".into(), Date(1.)).unwrap();
    assert!(continuity::restore(Some(&remote), &ids, None, Some("host")).is_none());
    assert!(continuity::restore(Some(&remote), &ids, Some(&b), Some("host")).is_none());
    assert!(continuity::restore(Some(&remote), &ids, Some(&a), Some("host")).is_some());
}

#[test]
fn canonical_equivalence_preserves_keys_hashing_and_one_visit_per_folder() {
    use std::collections::HashSet;
    let a = Scope::local("é");
    let b = Scope::local("e\u{301}");
    assert_eq!(a, b);
    let mut set = HashSet::new();
    set.insert(a.clone());
    assert!(set.contains(&b));
    let first = record(&a, "é");
    let second = record(&b, "e\u{301}");
    assert_eq!(first, second);
    let mut set = HashSet::new();
    set.insert(first.clone());
    assert!(set.contains(&second));
    let store = Continuity::default();
    store.remember(&first, Date(1.)).unwrap();
    store.remember(&second, Date(2.)).unwrap();
    assert_eq!(store.recent(&a, 4).unwrap().len(), 1);
    assert_eq!(
        pins::safe_label(&"e\u{301}".repeat(81)),
        "e\u{301}".repeat(80)
    );
}
