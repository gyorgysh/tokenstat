// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::work::{Kind, Scope, continuity::Date};
fn reference(id: &str) -> Reference {
    Reference {
        scope: Scope::local("fixture"),
        host_identity: "host".into(),
        workspace_id: "folder".into(),
        kind: Kind::Conversation,
        item_id: Some(id.into()),
        anchor: None,
    }
}
fn drain(service: &mut service::Service) {
    while let Some(job) = service.next_job() {
        let result = job.execute();
        service.finish(&job, result);
    }
    assert!(service.idle());
}
#[test]
fn words_identity_and_conditional_clearing_survive_reopen() {
    let root = tempfile::tempdir().unwrap();
    let storage = storage::Storage::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let mut service = service::Service::new(Some(storage.clone()));
    drain(&mut service);
    let reference = reference("one");
    service
        .save(
            reference.clone(),
            "half a thought".into(),
            vec![],
            Date(1.),
            false,
        )
        .unwrap();
    let first = service.model.draft(&reference).unwrap().clone();
    service
        .save(reference.clone(), "edited".into(), vec![], Date(2.), false)
        .unwrap();
    assert_eq!(
        service.model.draft(&reference).unwrap().message_id,
        first.message_id
    );
    service.clear_expected(&first);
    assert!(service.model.has_draft(&reference));
    drain(&mut service);
    let mut reopened = service::Service::new(Some(storage));
    drain(&mut reopened);
    assert_eq!(reopened.model.draft(&reference).unwrap().text, "edited");
}

#[test]
fn failed_deletions_stay_pending_and_an_unrelated_save_cannot_resurrect_old_snapshot_words() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("drafts");
    let storage = storage::Storage::at(directory.clone(), 4096);
    let mut first = service::Service::new(Some(storage.clone()));
    drain(&mut first);
    let a = reference("a");
    let b = reference("b");
    first
        .save(a.clone(), "one".into(), vec![], Date(1.), false)
        .unwrap();
    drain(&mut first);
    let mut second = service::Service::new(Some(storage.clone()));
    drain(&mut second);
    second.clear(&a);
    drain(&mut second);
    first
        .save(b.clone(), "two".into(), vec![], Date(2.), false)
        .unwrap();
    drain(&mut first);
    assert!(
        !storage
            .read()
            .unwrap()
            .contains_key(&a.conversation_key().unwrap())
    );
    let file = directory.join("drafts.v1.json");
    std::fs::write(&file, b"damaged").unwrap();
    first.clear(&b);
    drain(&mut first);
    assert!(first.save_failed && !first.model.has_draft(&b));
    assert_eq!(std::fs::read(&file).unwrap(), b"damaged");
    std::fs::write(&file, b"{}").unwrap();
    first.retry_failed_save();
    drain(&mut first);
    assert!(!first.save_failed);
    assert!(!file.exists());
}
#[test]
fn expected_clear_rechecks_disk_and_never_deletes_another_windows_newer_record() {
    let root = tempfile::tempdir().unwrap();
    let storage = storage::Storage::at(root.path().join("drafts"), 4096);
    let mut first = service::Service::new(Some(storage.clone()));
    drain(&mut first);
    let reference = reference("one");
    first
        .save(reference.clone(), "old".into(), vec![], Date(1.), false)
        .unwrap();
    drain(&mut first);
    let expected = first.model.draft(&reference).unwrap().clone();
    let mut other = service::Service::new(Some(storage.clone()));
    drain(&mut other);
    other
        .save(reference.clone(), "newer".into(), vec![], Date(2.), false)
        .unwrap();
    drain(&mut other);
    first.clear_expected(&expected);
    drain(&mut first);
    assert!(!first.model.has_draft(&reference));
    assert_eq!(
        storage.read().unwrap()[&reference.conversation_key().unwrap()].text,
        "newer"
    );
}
#[test]
fn registration_recovery_preserves_the_order_of_later_saves_and_clears() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("blocked");
    std::fs::write(&directory, b"not a directory").unwrap();
    let storage = storage::Storage::at(directory.clone(), 4096);
    let mut service = service::Service::new(Some(storage.clone()));
    drain(&mut service);
    assert!(service.initialized && service.save_failed);
    std::fs::remove_file(&directory).unwrap();
    let reference = reference("one");
    service
        .save(reference.clone(), "first".into(), vec![], Date(1.), false)
        .unwrap();
    service
        .save(reference.clone(), "second".into(), vec![], Date(2.), true)
        .unwrap();
    let first = service.next_job().unwrap();
    service.finish(&first, first.execute());
    service
        .save(reference.clone(), "third".into(), vec![], Date(3.), false)
        .unwrap();
    service.clear(&reference);
    drain(&mut service);
    assert!(!service.model.has_draft(&reference));
    assert!(storage.read().unwrap().is_empty());
    assert!(!service.save_failed);
}
#[test]
fn stable_ids_unchanged_edits_and_occupancy_follow_source_string_equality() {
    let mut service = service::Service::new(None);
    let reference = reference("one");
    service
        .save(reference.clone(), "café".into(), vec![], Date(1.), false)
        .unwrap();
    let first = service.model.draft(&reference).unwrap().clone();
    service
        .save(
            reference.clone(),
            "cafe\u{301}".into(),
            vec![],
            Date(99.),
            false,
        )
        .unwrap();
    assert_eq!(service.model.draft(&reference), Some(&first));
    assert_eq!(service.occupied().len(), 1);
    service
        .save(reference.clone(), "café".into(), vec![], Date(2.), true)
        .unwrap();
    assert_ne!(
        service.model.draft(&reference).unwrap().message_id,
        first.message_id
    );
    service
        .save(reference.clone(), " \n\t".into(), vec![], Date(3.), false)
        .unwrap();
    assert!(service.occupied().is_empty());
    assert!(service.idle());
}
#[test]
fn quota_and_bad_files_fail_without_eviction_or_overwriting_and_retry_keeps_words() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("drafts");
    let storage = storage::Storage::at(directory.clone(), 700);
    let mut service = service::Service::new(Some(storage.clone()));
    drain(&mut service);
    let reference = reference("one");
    service
        .save(reference.clone(), "x".repeat(2000), vec![], Date(1.), false)
        .unwrap();
    drain(&mut service);
    assert!(service.save_failed && service.model.has_draft(&reference));
    assert!(!directory.join("drafts.v1.json").exists());
    service
        .save(reference.clone(), "smaller".into(), vec![], Date(2.), false)
        .unwrap();
    drain(&mut service);
    assert!(!service.save_failed);
    let before = std::fs::read(directory.join("drafts.v1.json")).unwrap();
    service
        .save(
            reference.clone(),
            "not finite".into(),
            vec![],
            Date(f64::NAN),
            false,
        )
        .unwrap();
    drain(&mut service);
    assert!(service.save_failed);
    assert_eq!(
        std::fs::read(directory.join("drafts.v1.json")).unwrap(),
        before
    );
    assert_eq!(service.model.draft(&reference).unwrap().text, "not finite");
}
#[test]
fn attachment_protection_includes_unsaved_memory_and_the_latest_stored_copy() {
    let reference = reference("one");
    let mut model = Model::default();
    let old = Attachment {
        id: "old".into(),
        name: "words.txt".into(),
        media_type: None,
        size: Some(5),
        tool_call_id: None,
    };
    model
        .save(reference.clone(), "".into(), vec![old], Date(1.), false)
        .unwrap();
    let stored = model.records().clone();
    model
        .save(reference.clone(), "new".into(), vec![], Date(2.), false)
        .unwrap();
    assert_eq!(
        model.referenced_attachments(&stored, &reference),
        ["old".into()].into_iter().collect()
    );
    assert_eq!(
        model.protected_attachments(&stored, &reference.scope)
            [&reference.conversation_key().unwrap()]
            .len(),
        1
    );
    let ids: AttachmentIds = ["café".into(), "cafe\u{301}".into()].into_iter().collect();
    assert_eq!(ids.len(), 1);
    assert!(ids.contains("café"));
    assert!(ids.contains("cafe\u{301}"));
    assert!(!ids.contains("other"));
}
#[test]
fn ordinary_shutdown_waits_for_queued_word_writes_and_refuses_new_input() {
    let root = tempfile::tempdir().unwrap();
    let storage = storage::Storage::at(root.path().join("drafts"), 4096);
    let mut service = service::Service::new(Some(storage.clone()));
    drain(&mut service);
    service
        .save(reference("one"), "one".into(), vec![], Date(1.), false)
        .unwrap();
    let active = service.next_job().unwrap();
    service
        .save(reference("two"), "two".into(), vec![], Date(2.), false)
        .unwrap();
    service.start_shutdown();
    assert!(!service.idle());
    assert!(
        service
            .save(reference("three"), "no".into(), vec![], Date(3.), false)
            .is_err()
    );
    service.finish(&active, active.execute());
    drain(&mut service);
    assert_eq!(storage.read().unwrap().len(), 2);
}
#[test]
fn private_modes_special_files_and_stable_lock_inodes_protect_existing_data() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("drafts");
    let storage = storage::Storage::at(directory.clone(), 4096);
    storage.prepare().unwrap();
    assert_eq!(
        std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
        0o700
    );
    let mut service = service::Service::new(Some(storage.clone()));
    drain(&mut service);
    service
        .save(reference("one"), "one".into(), vec![], Date(1.), false)
        .unwrap();
    drain(&mut service);
    let lock = directory.join("drafts.lock");
    let inode = std::fs::metadata(&lock).unwrap().ino();
    let file = directory.join("drafts.v1.json");
    assert_eq!(
        std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    service.clear(&reference("one"));
    drain(&mut service);
    assert_eq!(std::fs::metadata(&lock).unwrap().ino(), inode);
    let target = root.path().join("outside");
    std::fs::write(&target, b"private original").unwrap();
    symlink(&target, &file).unwrap();
    assert!(storage.read().is_err());
    service
        .save(reference("two"), "two".into(), vec![], Date(2.), false)
        .unwrap();
    drain(&mut service);
    assert!(service.save_failed);
    assert_eq!(std::fs::read(&target).unwrap(), b"private original");
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    assert!(storage.read().is_err());
}
#[test]
fn participants_share_in_process_and_nested_gates_and_live_uses_remain_protected() {
    let root = tempfile::tempdir().unwrap();
    let first = coordination::join(root.path()).unwrap();
    let second = coordination::join(&root.path().join(".")).unwrap();
    assert!(std::sync::Arc::ptr_eq(&first, &second));
    let file = root.path().join("original");
    std::fs::write(&file, b"original").unwrap();
    let activity = coordination::use_file(&first, &file).unwrap();
    assert!(coordination::while_sole(&first, &file, || Ok(())).is_err());
    drop(activity);
    coordination::while_sole(&first, &file, || {
        let nested = coordination::join(root.path())?;
        assert!(std::sync::Arc::ptr_eq(&first, &nested));
        coordination::while_sole(&nested, &file, || Ok(()))
    })
    .unwrap();
}
