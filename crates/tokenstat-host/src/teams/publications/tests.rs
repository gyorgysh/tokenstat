// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;
fn owner() -> Owner {
    Owner {
        issuer: "https://accounts.example.test".into(),
        publisher_id: "fixture-owner".into(),
        host_key: "bb".repeat(32),
    }
}
fn setup() -> (tempfile::TempDir, Store, Folder) {
    let root = tempfile::tempdir().unwrap();
    let checkout = root.path().join("Example checkout ü");
    fs::create_dir(&checkout).unwrap();
    let folder = Folder::capture(&checkout).unwrap();
    let store = Store {
        root: root.path().join("sharing"),
    };
    (root, store, folder)
}
fn prepare(store: &Store, folder: &Folder, request: &str) -> Checkout {
    store
        .prepare(
            &owner(),
            "org_fixture",
            "repo_fixture",
            "private-workspace",
            folder,
            request,
        )
        .unwrap()
}
fn active(store: &Store, folder: &Folder) -> Checkout {
    let pending = prepare(store, folder, "request-one");
    store
        .activate(&owner(), &pending.id, pending.revision, 1)
        .unwrap()
}
#[test]
fn independent_publication_readers_validate_authority_without_allowing_mutation() {
    let (_root, store, folder) = setup();
    let active = active(&store, &folder);
    // A second guardian can be checking this same publication. Its read lock
    // must not make a still-authorized run permanently retire its SDK.
    let reader = OpenOptions::new()
        .read(true)
        .write(true)
        .open(store.root.join("index.lock"))
        .unwrap();
    reader.lock_shared().unwrap();
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &active.id)
            .unwrap()
            == active
    );
    let foreign = Owner {
        publisher_id: "another-person".into(),
        ..owner()
    };
    assert!(
        store
            .resolve(&foreign, "org_fixture", "repo_fixture", &active.id)
            .is_err()
    );
    assert!(
        matches!(store.withdraw(&owner(), &active.id, active.revision), Err(error) if error.code == "sharing_busy")
    );
    drop(reader);
    store
        .withdraw(&owner(), &active.id, active.revision)
        .unwrap();
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &active.id)
            .is_err()
    );
}

#[test]
fn publication_validation_waits_for_a_writer_then_observes_its_revocation() {
    let (_root, store, folder) = setup();
    let active = active(&store, &folder);
    let mut next = store.read(|index| Ok(index.clone())).unwrap();
    let row = next
        .checkouts
        .iter_mut()
        .find(|row| row.id == active.id)
        .unwrap();
    row.phase = Phase::Withdrawn;
    row.revision += 1;
    let writer = OwnerLease::try_acquire(&store.root.join("index.lock"))
        .unwrap()
        .unwrap();
    let root = store.root.clone();
    let thread = std::thread::spawn(move || {
        let _writer = writer;
        std::thread::sleep(Duration::from_millis(25));
        save(&root, &root.join("index.json"), &next).unwrap();
    });
    let result = store.resolve(&owner(), "org_fixture", "repo_fixture", &active.id);
    thread.join().unwrap();
    assert!(matches!(result, Err(error) if error.code == "checkout_not_shared"));
}

#[test]
fn an_unavailable_publication_lock_never_falls_back_to_cached_authority() {
    let (_root, store, folder) = setup();
    let active = active(&store, &folder);
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &active.id)
            .is_ok()
    );
    let _writer = OwnerLease::try_acquire(&store.root.join("index.lock"))
        .unwrap()
        .unwrap();
    assert!(
        matches!(store.resolve(&owner(), "org_fixture", "repo_fixture", &active.id), Err(error) if error.code == "sharing_busy")
    );
}

#[test]
fn sharing_setup_cannot_create_a_new_project_for_an_already_published_folder() {
    let (_root, store, folder) = setup();
    let active = active(&store, &folder);
    assert!(
        store
            .ensure_setup_target(&owner(), &folder, "org_fixture", Some("repo_fixture"))
            .is_ok()
    );
    for (organization, repository) in [
        ("org_fixture", None),
        ("org_fixture", Some("another_repo")),
        ("another_org", Some("repo_fixture")),
    ] {
        assert_eq!(
            store
                .ensure_setup_target(&owner(), &folder, organization, repository)
                .unwrap_err()
                .code,
            "checkout_already_shared"
        );
    }
    store
        .withdraw(&owner(), &active.id, active.revision)
        .unwrap();
    assert!(
        store
            .ensure_setup_target(&owner(), &folder, "another_org", None)
            .is_ok()
    );
}
#[test]
fn only_an_active_publication_for_the_same_owner_and_key_can_restore_reach() {
    let (_root, store, folder) = setup();
    assert!(!store.has_active_key(&owner().host_key).unwrap());
    assert!(
        !store.root.exists(),
        "An unused Team feature must not create sharing files."
    );
    let pending = prepare(&store, &folder, "request-one");
    assert!(!store.has_active(&owner()).unwrap());
    let active = store
        .activate(&owner(), &pending.id, pending.revision, 1)
        .unwrap();
    assert!(store.has_active(&owner()).unwrap());
    assert!(store.has_active_key(&owner().host_key).unwrap());
    for other in [
        Owner {
            publisher_id: "another-account".into(),
            ..owner()
        },
        Owner {
            issuer: "https://another.example.test".into(),
            ..owner()
        },
        Owner {
            host_key: "aa".repeat(32),
            ..owner()
        },
    ] {
        assert!(!store.has_active(&other).unwrap());
    }
    store
        .withdraw(&owner(), &active.id, active.revision)
        .unwrap();
    assert!(!store.has_active(&owner()).unwrap());
    assert!(!store.has_active_key(&owner().host_key).unwrap());
}
#[test]
fn a_pending_or_withdrawn_publication_cannot_read_even_after_retries() {
    let (_root, store, folder) = setup();
    let pending = prepare(&store, &folder, "request-one");
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &pending.id)
            .is_err()
    );
    assert_eq!(prepare(&store, &folder, "request-one").id, pending.id);
    let current = store
        .activate(&owner(), &pending.id, pending.revision, 1)
        .unwrap();
    assert_eq!(
        store
            .activate(&owner(), &pending.id, pending.revision, 1)
            .unwrap()
            .id,
        current.id
    );
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &current.id)
            .is_ok()
    );
    let retired = store
        .withdraw(&owner(), &current.id, current.revision)
        .unwrap();
    assert!(!retired.cloud_withdrawn);
    store
        .confirm_cloud_withdrawal(&owner(), &retired.id)
        .unwrap();
    let cleaned = store
        .list(&owner())
        .unwrap()
        .into_iter()
        .find(|row| row.id == retired.id)
        .unwrap();
    assert!(cleaned.cloud_withdrawn);
    let cleanup_revision = cleaned.revision;
    store
        .confirm_cloud_withdrawal(&owner(), &retired.id)
        .unwrap();
    assert_eq!(store.list(&owner()).unwrap()[0].revision, cleanup_revision);
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &current.id)
            .is_err()
    );
    assert!(
        store
            .activate(&owner(), &retired.id, retired.revision, 1)
            .is_err()
    );
    assert!(
        store
            .prepare(
                &owner(),
                "org_fixture",
                "repo_fixture",
                "private-workspace",
                &folder,
                "request-one"
            )
            .is_err()
    );
    let next = prepare(&store, &folder, "request-two");
    assert_ne!(next.id, current.id);
}
#[test]
fn publication_identity_never_crosses_accounts_repositories_or_hosts() {
    let (_root, store, folder) = setup();
    let row = active(&store, &folder);
    for foreign in [
        Owner {
            issuer: "https://another.example.test".into(),
            ..owner()
        },
        Owner {
            publisher_id: "another-owner".into(),
            ..owner()
        },
        Owner {
            host_key: "cc".repeat(32),
            ..owner()
        },
    ] {
        assert!(store.list(&foreign).unwrap().is_empty());
        assert!(
            store
                .resolve(&foreign, "org_fixture", "repo_fixture", &row.id)
                .is_err()
        );
        assert!(store.withdraw(&foreign, &row.id, row.revision).is_err());
    }
    assert!(
        store
            .resolve(&owner(), "another-org", "repo_fixture", &row.id)
            .is_err()
    );
    assert!(
        store
            .resolve(&owner(), "org_fixture", "another-repo", &row.id)
            .is_err()
    );
    assert!(
        store
            .prepare(
                &owner(),
                "another-org",
                "another-repo",
                "other-workspace",
                &folder,
                "request-two"
            )
            .is_err()
    );
}
#[test]
fn a_replacement_folder_at_the_same_path_cannot_inherit_read_access() {
    let (root, store, folder) = setup();
    let row = active(&store, &folder);
    fs::rename(&folder.canonical, root.path().join("Former checkout")).unwrap();
    fs::create_dir(&folder.canonical).unwrap();
    fs::write(folder.canonical.join("private.txt"), b"new folder content").unwrap();
    assert_eq!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &row.id)
            .err()
            .unwrap()
            .code,
        "checkout_changed"
    );
    let replacement = Folder::capture(&folder.canonical).unwrap();
    let next = prepare(&store, &replacement, "request-two");
    assert_ne!(next.id, row.id);
}
#[test]
fn separate_clones_remain_distinct_and_aliases_do_not_duplicate_one_folder() {
    let (root, store, folder) = setup();
    let first = active(&store, &folder);
    let clone = root.path().join("Independent checkout");
    fs::create_dir(&clone).unwrap();
    let second = prepare(&store, &Folder::capture(&clone).unwrap(), "request-two");
    assert_ne!(first.id, second.id);
    let retried = prepare(&store, &folder, "request-three");
    assert_eq!(retried.id, first.id);
    #[cfg(unix)]
    {
        let alias = root.path().join("Alias");
        std::os::unix::fs::symlink(&folder.canonical, &alias).unwrap();
        let alias = Folder::capture(&alias).unwrap();
        assert!(
            store
                .prepare(
                    &owner(),
                    "org_other",
                    "repo_other",
                    "other-workspace",
                    &alias,
                    "request-four"
                )
                .is_err()
        );
    }
}
#[test]
fn corrupt_or_missing_records_fail_closed_and_are_never_overwritten() {
    let (_root, store, folder) = setup();
    let row = active(&store, &folder);
    let path = store.root.join("index.json");
    fs::write(&path, b"broken index").unwrap();
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &row.id)
            .is_err()
    );
    assert!(
        store
            .prepare(
                &owner(),
                "org_fixture",
                "repo_fixture",
                "private-workspace",
                &folder,
                "request-two"
            )
            .is_err()
    );
    assert_eq!(fs::read(&path).unwrap(), b"broken index");
    fs::remove_file(&path).unwrap();
    assert!(store.list(&owner()).is_err());
}
#[test]
fn atomic_external_withdrawal_invalidates_cached_bindings_with_an_unchanged_timestamp() {
    let (_root, store, folder) = setup();
    let row = active(&store, &folder);
    store
        .resolve(&owner(), "org_fixture", "repo_fixture", &row.id)
        .unwrap();
    let path = store.root.join("index.json");
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    let mut index = load(&path).unwrap();
    index.checkouts[0].phase = Phase::Withdrawn;
    index.checkouts[0].revision += 1;
    save(&store.root, &path, &index).unwrap();
    fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(modified))
        .unwrap();
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &row.id)
            .is_err()
    );
}
#[cfg(unix)]
#[test]
fn private_records_refuse_symlinked_indexes_and_use_owner_only_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let (root, store, folder) = setup();
    let row = active(&store, &folder);
    assert_eq!(
        fs::metadata(&store.root).unwrap().permissions().mode() & 0o077,
        0
    );
    assert_eq!(
        fs::metadata(store.root.join("index.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o077,
        0
    );
    let kept = root.path().join("kept-index.json");
    fs::rename(store.root.join("index.json"), &kept).unwrap();
    std::os::unix::fs::symlink(&kept, store.root.join("index.json")).unwrap();
    assert!(
        store
            .resolve(&owner(), "org_fixture", "repo_fixture", &row.id)
            .is_err()
    );
}
