// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn fixture() -> (tempfile::TempDir, Store, Owner, Checkout) {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("checkout");
    fs::create_dir(&directory).unwrap();
    let folder = Folder::capture(&directory).unwrap();
    let store = Store {
        root: root.path().join("sharing"),
    };
    let owner = Owner {
        issuer: "https://accounts.example.test".into(),
        publisher_id: "fixture-owner".into(),
        host_key: "aa".repeat(32),
    };
    let prepared = store
        .prepare(
            &owner,
            "org_fixture",
            "repo_fixture",
            "workspace_fixture",
            &folder,
            "checkout-request",
        )
        .unwrap();
    let checkout = store
        .activate(&owner, &prepared.id, prepared.revision, 1)
        .unwrap();
    (root, store, owner, checkout)
}
fn target<'a>(owner: &'a Owner, checkout: &'a Checkout) -> ChatTarget<'a> {
    ChatTarget {
        owner,
        organization: &checkout.organization_id,
        repository: &checkout.repository_id,
        checkout: &checkout.id,
    }
}
#[test]
fn prepared_chat_references_authorize_nothing_and_cannot_cross_resources() {
    let (_root, store, owner, checkout) = fixture();
    let target = target(&owner, &checkout);
    let pending = store
        .prepare_chat(&target, "chat_fixture", "share-request", &"ab".repeat(32))
        .unwrap();
    assert!(store.resolve_chat(&target, &pending.id).is_err());
    let active = store
        .activate_chat(&target, &pending.id, pending.revision, 1)
        .unwrap();
    assert_eq!(
        store
            .resolve_chat(&target, &active.id)
            .unwrap()
            .conversation_id,
        "chat_fixture"
    );
    let other_owner = Owner {
        publisher_id: "other-owner".into(),
        ..owner.clone()
    };
    for changed in [
        ChatTarget {
            owner: &other_owner,
            ..target
        },
        ChatTarget {
            organization: "org_other",
            ..target
        },
        ChatTarget {
            repository: "repo_other",
            ..target
        },
        ChatTarget {
            checkout: "checkout_other",
            ..target
        },
    ] {
        assert!(store.resolve_chat(&changed, &active.id).is_err());
    }
    let other_key = Owner {
        host_key: "bb".repeat(32),
        ..owner.clone()
    };
    assert!(
        store
            .resolve_chat(
                &ChatTarget {
                    owner: &other_key,
                    ..target
                },
                &active.id
            )
            .is_err()
    );
}
#[test]
fn retries_require_the_original_source_and_withdrawn_references_never_revive() {
    let (_root, store, owner, checkout) = fixture();
    let target = target(&owner, &checkout);
    let preview = "ab".repeat(32);
    let prepared = store
        .prepare_chat(&target, "chat_fixture", "share-request", &preview)
        .unwrap();
    assert_eq!(
        store
            .prepare_chat(&target, "chat_fixture", "share-request", &preview)
            .unwrap()
            .id,
        prepared.id
    );
    assert!(
        store
            .prepare_chat(&target, "another_chat", "share-request", &preview)
            .is_err()
    );
    assert!(
        store
            .prepare_chat(&target, "chat_fixture", "another-request", &preview)
            .is_err()
    );
    assert!(
        store
            .prepare_chat(&target, "chat_fixture", "share-request", &"cd".repeat(32))
            .is_err()
    );
    let active = store
        .activate_chat(&target, &prepared.id, prepared.revision, 1)
        .unwrap();
    let withdrawn = store
        .withdraw_chat(&target, &active.id, active.revision)
        .unwrap();
    assert_eq!(
        store
            .withdraw_chat(&target, &active.id, active.revision)
            .unwrap()
            .revision,
        withdrawn.revision
    );
    assert!(store.resolve_chat(&target, &active.id).is_err());
    store.confirm_chat_withdrawal(&target, &active.id).unwrap();
    assert!(
        store
            .withdraw_chat(&target, &active.id, active.revision)
            .unwrap()
            .cloud_withdrawn
    );
    assert!(
        store
            .activate_chat(&target, &active.id, withdrawn.revision, 2)
            .is_err()
    );
    assert!(
        store
            .prepare_chat(&target, "chat_fixture", "share-request", &preview)
            .is_err()
    );
    let next = store
        .prepare_chat(&target, "chat_fixture", "new-request", &preview)
        .unwrap();
    assert_ne!(next.id, withdrawn.id);
    assert!(store.resolve_chat(&target, &next.id).is_err());
}
#[test]
fn withdrawing_the_checkout_stops_child_access_before_cloud_cleanup() {
    let (_root, store, owner, checkout) = fixture();
    let target = target(&owner, &checkout);
    let prepared = store
        .prepare_chat(&target, "chat_fixture", "share-request", &"ab".repeat(32))
        .unwrap();
    let active = store
        .activate_chat(&target, &prepared.id, prepared.revision, 1)
        .unwrap();
    store
        .withdraw(&owner, &checkout.id, checkout.revision)
        .unwrap();
    assert!(store.resolve_chat(&target, &active.id).is_err());
    assert!(
        store
            .withdraw_chat(&target, &active.id, active.revision)
            .is_ok()
    );
}
#[test]
fn missing_parent_records_fail_closed_after_a_disk_replacement() {
    let (_root, store, owner, checkout) = fixture();
    let target = target(&owner, &checkout);
    let prepared = store
        .prepare_chat(&target, "chat_fixture", "share-request", &"ab".repeat(32))
        .unwrap();
    store
        .activate_chat(&target, &prepared.id, prepared.revision, 1)
        .unwrap();
    let path = store.root.join("index.json");
    let mut index: Index = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    index.checkouts.clear();
    fs::write(&path, serde_json::to_vec(&index).unwrap()).unwrap();
    assert!(store.resolve_chat(&target, &prepared.id).is_err());
    assert!(path.is_file());
}

#[test]
fn physical_owner_recovery_is_revision_checked_and_cannot_revive_or_retire_a_replacement() {
    let (_root, store, owner, checkout) = fixture();
    let target = target(&owner, &checkout);
    let pending = store
        .prepare_chat(
            &target,
            "chat_fixture",
            "first-publication",
            &"ab".repeat(32),
        )
        .unwrap();
    let active = store
        .activate_chat(&target, &pending.id, pending.revision, 1)
        .unwrap();
    assert!(
        store
            .retire_source(
                "wrong-workspace",
                "chat_fixture",
                &active.id,
                active.revision
            )
            .is_err()
    );
    assert!(
        store
            .retire_source(
                &checkout.workspace_id,
                "wrong-conversation",
                &active.id,
                active.revision
            )
            .is_err()
    );
    assert!(
        store
            .retire_source(
                &checkout.workspace_id,
                "chat_fixture",
                &active.id,
                active.revision + 1
            )
            .is_err()
    );
    assert!(store.resolve_chat(&target, &active.id).is_ok());
    let (_, retired) = store
        .retire_source(
            &checkout.workspace_id,
            "chat_fixture",
            &active.id,
            active.revision,
        )
        .unwrap();
    assert!(retired.phase == Phase::Withdrawn);
    assert!(!retired.cloud_withdrawn);
    assert!(store.resolve_chat(&target, &active.id).is_err());
    let next = store
        .prepare_chat(
            &target,
            "chat_fixture",
            "replacement-publication",
            &"cd".repeat(32),
        )
        .unwrap();
    let replacement = store
        .activate_chat(&target, &next.id, next.revision, 1)
        .unwrap();
    store
        .retire_source(
            &checkout.workspace_id,
            "chat_fixture",
            &active.id,
            active.revision,
        )
        .unwrap();
    assert!(store.resolve_chat(&target, &replacement.id).is_ok());
    assert_eq!(
        store
            .source_record(&checkout.workspace_id, "chat_fixture", None)
            .unwrap()
            .unwrap()
            .1
            .id,
        replacement.id
    );
    store
        .withdraw(&owner, &checkout.id, checkout.revision)
        .unwrap();
    // Revocation is still local and available after losing the parent or the
    // account that originally published it. There is no activation operation.
    assert!(
        store
            .retire_source(
                &checkout.workspace_id,
                "chat_fixture",
                &replacement.id,
                replacement.revision
            )
            .is_ok()
    );
}

#[test]
fn identical_new_chat_requests_are_serialized_without_blocking_every_other_request() {
    let (root, store, owner, checkout) = fixture();
    let target = target(&owner, &checkout);
    let first = store.new_chat_lease(&target, "same-request").unwrap();
    let reopened = Store::test_store(root.path().join("sharing"));
    assert_eq!(
        reopened
            .new_chat_lease(&target, "same-request")
            .err()
            .unwrap()
            .code,
        "chat_creation_busy"
    );
    let other = (0..256)
        .find_map(|index| {
            reopened
                .new_chat_lease(&target, &format!("other-request-{index}"))
                .ok()
        })
        .expect("unrelated requests in another stripe can run concurrently");
    drop(first);
    assert!(reopened.new_chat_lease(&target, "same-request").is_ok());
    drop(other);
    assert!(store.new_chat_lease(&target, "../untrusted").is_err());
}

#[test]
fn arbitrary_new_chat_requests_use_a_bounded_set_of_lock_files() {
    let (_root, store, owner, checkout) = fixture();
    let target = target(&owner, &checkout);
    for index in 0..1000 {
        drop(
            store
                .new_chat_lease(&target, &format!("request-{index}"))
                .unwrap(),
        );
    }
    let locks = fs::read_dir(&store.root)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            name.starts_with("new-chat-") && name.ends_with(".lock")
        })
        .count();
    assert!(locks > 1 && locks <= 256, "found {locks} lock files");
}
