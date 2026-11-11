// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::work::Kind;

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
fn message(id: &str, revision: Option<u64>) -> Message {
    Message {
        id: id.into(),
        text: format!("message {id}"),
        attachments: vec![],
        delivery: Delivery::Waiting,
        first_attempt_at: None,
        attempted_at: None,
        expected_revision: revision,
        when_connected: false,
        source_draft_text: None,
        sign_in_backend: None,
    }
}
#[test]
fn acceptance_only_advances_waiting_successors_of_exact_context() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::at(root.path().join("outbox"), storage::MAX_FILE_BYTES);
    let owner = reference("one");
    let first = message("first", Some(8));
    let mut held = message("held", Some(8));
    held.delivery = Delivery::DeliveryUnknown;
    let later = message("later", Some(9));
    store
        .update(&owner, |items| {
            items.extend([
                first.clone(),
                message("next", Some(8)),
                held.clone(),
                later.clone(),
            ]);
            Ok(())
        })
        .unwrap();
    let remaining = store.accept(&owner, &first, Some(9)).unwrap();
    assert_eq!(remaining[0].expected_revision, Some(9));
    assert_eq!(remaining[1], held);
    assert_eq!(remaining[2], later);
    let next = remaining[0].clone();
    assert_eq!(
        store.accept(&owner, &next, Some(11)).unwrap()[0].expected_revision,
        Some(8)
    );
    assert_eq!(
        Store::at(root.path().join("outbox"), storage::MAX_FILE_BYTES)
            .items(&owner)
            .unwrap()
            .len(),
        2
    );
}
#[test]
fn maximum_revision_and_missing_reply_cannot_advance_a_successor() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::at(root.path().into(), storage::MAX_FILE_BYTES);
    let owner = reference("overflow");
    let sent = message("sent", Some(u64::MAX));
    store
        .update(&owner, |items| {
            items.extend([sent.clone(), message("waiting", Some(u64::MAX))]);
            Ok(())
        })
        .unwrap();
    assert_eq!(
        store.accept(&owner, &sent, None).unwrap()[0].expected_revision,
        Some(u64::MAX)
    );
}

#[test]
fn prepared_or_reordered_rows_cannot_overwrite_newer_or_held_writing() {
    let root = tempfile::tempdir().unwrap();
    let a = Store::at(root.path().into(), storage::MAX_FILE_BYTES);
    let b = Store::at(root.path().into(), storage::MAX_FILE_BYTES);
    let owner = reference("one");
    let old = message("a", Some(1));
    a.update(&owner, |items| {
        items.extend([old.clone(), message("b", Some(1)), message("c", Some(1))]);
        Ok(())
    })
    .unwrap();
    b.update(&owner, |items| {
        items[0].text = "newer".into();
        items[1].delivery = Delivery::Sending;
        Ok(())
    })
    .unwrap();
    assert!(a.prepare(&owner, &old, 3).is_err());
    assert!(a.prepare(&owner, &message("b", Some(1)), 3).is_err());
    let reordered = a
        .reorder(
            &owner,
            &["a".into(), "b".into(), "c".into()],
            &["c".into(), "a".into()],
        )
        .unwrap();
    assert_eq!(
        reordered.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
        ["c", "b", "a"]
    );
    assert_eq!(reordered[2].text, "newer");
    assert_eq!(reordered[1].delivery, Delivery::Sending);
    assert!(
        a.reorder(&owner, &["a".into(), "b".into(), "c".into()], &["a".into()])
            .is_err()
    );
}
#[test]
fn capacity_corruption_and_duplicate_identity_never_overwrite_existing_bytes() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::at(root.path().into(), storage::MAX_FILE_BYTES);
    let owner = reference("one");
    store
        .update(&owner, |items| {
            items.push(message("é", None));
            Ok(())
        })
        .unwrap();
    let file = root.path().join("outbox.v1.json");
    let before = std::fs::read(&file).unwrap();
    assert!(
        store
            .update(&owner, |items| {
                items.push(message("e\u{301}", None));
                Ok(())
            })
            .is_err()
    );
    assert!(
        store
            .update(&owner, |items| {
                items.extend((0..20).map(|i| message(&format!("{i}"), None)));
                Ok(())
            })
            .is_err()
    );
    assert_eq!(std::fs::read(&file).unwrap(), before);
    std::fs::write(&file, b"{broken").unwrap();
    assert!(
        store
            .update(&owner, |items| {
                items.push(message("new", None));
                Ok(())
            })
            .is_err()
    );
    assert_eq!(std::fs::read(&file).unwrap(), b"{broken");
}
#[test]
fn concurrent_stores_merge_latest_queues_and_exclude_duplicate_delivery() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::at(root.path().into(), storage::MAX_FILE_BYTES);
    let owner = reference("one");
    let lease = store.begin_delivery(&owner).unwrap().unwrap();
    assert!(store.clone().begin_delivery(&owner).unwrap().is_none());
    assert!(store.begin_delivery(&reference("two")).unwrap().is_some());
    drop(lease);
    assert!(store.begin_delivery(&owner).unwrap().is_some());
    let mut threads = Vec::new();
    for index in 0..12 {
        let store = store.clone();
        threads.push(std::thread::spawn(move || {
            store
                .update(&reference(&format!("{index}")), |items| {
                    items.push(message("one", None));
                    Ok(())
                })
                .unwrap()
        }));
    }
    for thread in threads {
        thread.join().unwrap();
    }
    assert_eq!(store.queues(&Scope::local("fixture")).unwrap().len(), 12);
}
