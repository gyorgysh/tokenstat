// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;
use crate::work::{Kind, Scope};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixListener,
    path::PathBuf,
    thread,
};

fn reference() -> Reference {
    Reference {
        scope: Scope::local("fixture"),
        host_identity: "host".into(),
        workspace_id: "/fixture".into(),
        kind: Kind::Conversation,
        item_id: Some("chat".into()),
        anchor: None,
    }
}
fn message() -> Message {
    Message {
        id: "message-one".into(),
        text: "Synthetic words".into(),
        attachments: vec![],
        delivery: Delivery::Waiting,
        first_attempt_at: None,
        attempted_at: None,
        expected_revision: Some(9),
        when_connected: false,
        source_draft_text: None,
        sign_in_backend: None,
    }
}
/// Each expected request gets one synthetic response. `None` deliberately
/// closes after reading the complete send, as if its acknowledgment was lost.
fn host(
    socket: PathBuf,
    responses: Vec<(&'static str, Option<Value>)>,
) -> thread::JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    thread::spawn(move || {
        let mut requests = Vec::new();
        for (method, answer) in responses {
            loop {
                let (mut stream, _) = listener.accept().unwrap();
                let mut line = String::new();
                BufReader::new(stream.try_clone().unwrap())
                    .read_line(&mut line)
                    .unwrap();
                if line.is_empty() {
                    continue;
                }
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                requests.push(request);
                if let Some(answer) = &answer {
                    writeln!(stream, "{answer}").unwrap();
                }
                break;
            }
        }
        requests
    })
}
fn ok(value: Value) -> Option<Value> {
    Some(json!({"id":1,"ok":true,"result":value}))
}
fn protocol() -> (&'static str, Option<Value>) {
    ("protocol", ok(json!({"protocolVersion":"53"})))
}
fn client(socket: PathBuf) -> Client {
    Client {
        socket,
        allow_spawn: false,
    }
}
fn queued(store: &Store, item: &Message) {
    store
        .update(&reference(), |items| {
            items.push(item.clone());
            Ok(())
        })
        .unwrap();
}
#[test]
fn lost_acknowledgment_requires_receipt_and_never_sends_twice() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let server = host(
        socket.clone(),
        vec![
            protocol(),
            ("chat.send", None),
            protocol(),
            ("chat.receipt", ok(json!({"state":"accepted"}))),
        ],
    );
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let item = message();
    queued(&store, &item);
    let client = client(socket);
    let Outcome::Unconfirmed {
        message: pending, ..
    } = deliver(
        &store,
        &client,
        &reference(),
        "/fixture",
        &item,
        1_000_000,
        || true,
    )
    .unwrap()
    else {
        panic!("expected unknown delivery")
    };
    assert_eq!(pending.delivery, Delivery::DeliveryUnknown);
    assert_eq!(store.items(&reference()).unwrap()[0], pending);
    assert!(matches!(
        deliver(
            &store,
            &client,
            &reference(),
            "/fixture",
            &pending,
            1_000_001,
            || true
        )
        .unwrap(),
        Outcome::ReceiptAccepted { .. }
    ));
    assert!(store.items(&reference()).unwrap().is_empty());
    let requests = server.join().unwrap();
    assert_eq!(requests[1]["params"]["clientMessageId"], "message-one");
    assert_eq!(requests[1]["params"]["expectedRevision"], 9);
    assert_eq!(requests[1]["params"]["clientMessageCreatedAtMs"], 1_000_000);
    assert_eq!(requests[3]["params"]["clientMessageId"], "message-one");
}
#[test]
fn accepted_send_advances_only_matching_waiting_context() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let server = host(
        socket.clone(),
        vec![
            protocol(),
            (
                "chat.send",
                ok(
                    json!({"id":"chat","workspaceId":"/fixture","title":"Fixture","backend":"codex","sendRevision":10}),
                ),
            ),
        ],
    );
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let item = message();
    queued(&store, &item);
    let mut successor = message();
    successor.id = "next".into();
    queued(&store, &successor);
    assert!(matches!(
        deliver(
            &store,
            &client(socket),
            &reference(),
            "/fixture",
            &item,
            1_000_000,
            || true
        )
        .unwrap(),
        Outcome::Accepted { .. }
    ));
    assert_eq!(
        store.items(&reference()).unwrap()[0].expected_revision,
        Some(10)
    );
    server.join().unwrap();
}
#[test]
fn changed_context_and_unknown_receipt_remain_durable_without_resending() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let server = host(
        socket.clone(),
        vec![
            protocol(),
            (
                "chat.send",
                Some(
                    json!({"id":1,"ok":false,"error":{"code":"conversation_changed","message":"Changed"}}),
                ),
            ),
            protocol(),
            ("chat.receipt", ok(json!({"state":"unknown"}))),
        ],
    );
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let item = message();
    queued(&store, &item);
    let client = client(socket);
    let Outcome::NeedsReview {
        message: review, ..
    } = deliver(
        &store,
        &client,
        &reference(),
        "/fixture",
        &item,
        1_000_000,
        || true,
    )
    .unwrap()
    else {
        panic!("expected review")
    };
    assert_eq!(review.delivery, Delivery::NeedsReview);
    store
        .update(&reference(), |items| {
            items[0].delivery = Delivery::Sending;
            Ok(())
        })
        .unwrap();
    let pending = store.items(&reference()).unwrap().remove(0);
    assert!(matches!(
        deliver(
            &store,
            &client,
            &reference(),
            "/fixture",
            &pending,
            1_000_001,
            || true
        )
        .unwrap(),
        Outcome::Unconfirmed { .. }
    ));
    assert_eq!(
        store.items(&reference()).unwrap()[0].delivery,
        Delivery::DeliveryUnknown
    );
    server.join().unwrap();
}
#[test]
fn retired_owner_or_changed_payload_never_reaches_host() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let item = message();
    queued(&store, &item);
    let client = client(root.path().join("absent.sock"));
    assert!(
        deliver(&store, &client, &reference(), "/fixture", &item, 1, || {
            false
        })
        .is_err()
    );
    let mut stale = item.clone();
    stale.text = "old".into();
    assert!(
        deliver(&store, &client, &reference(), "/fixture", &stale, 1, || {
            true
        })
        .is_err()
    );
    assert_eq!(store.items(&reference()).unwrap()[0], item);
}

#[test]
fn queue_captures_stable_identity_and_never_replaces_uncertain_writing() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::at(root.path().into(), storage::MAX_FILE_BYTES);
    let draft = crate::drafts::Draft {
        reference: reference(),
        text: "  keep these words\n".into(),
        attachments: vec![],
        updated_at: Date(1.),
        message_id: Some("stable".into()),
    };
    let item = queue_draft(&store, &draft, Some(9)).unwrap();
    assert_eq!(item.text, "keep these words");
    assert_eq!(
        item.source_draft_text.as_deref(),
        Some("  keep these words\n")
    );
    assert_eq!(
        queue_draft(&store, &draft, Some(99))
            .unwrap()
            .expected_revision,
        Some(9)
    );
    store
        .update(&reference(), |items| {
            items[0].delivery = Delivery::DeliveryUnknown;
            Ok(())
        })
        .unwrap();
    assert!(
        queue_draft(&store, &draft, Some(9))
            .unwrap()
            .needs_receipt()
    );
    let mut changed = draft.clone();
    changed.text = "different words".into();
    assert!(queue_draft(&store, &changed, Some(9)).is_err());
    assert_eq!(
        store.items(&reference()).unwrap()[0].text,
        "keep these words"
    );
}

#[test]
fn remote_send_checks_protocol_and_workspace_access_before_dispatch() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("remote.sock");
    let server = host(
        socket.clone(),
        vec![
            protocol(),
            ("remote.call", ok(json!({"protocolVersion":"14"}))),
            ("remote.call", ok(json!({"allowed":true}))),
            (
                "remote.call",
                ok(
                    json!({"id":"chat","workspaceId":"/fixture","title":"Fixture","backend":"codex","sendRevision":10}),
                ),
            ),
        ],
    );
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let mut owner = reference();
    owner.host_identity = "peer".into();
    let item = message();
    store
        .update(&owner, |items| {
            items.push(item.clone());
            Ok(())
        })
        .unwrap();
    assert!(matches!(
        deliver(
            &store,
            &client(socket),
            &owner,
            "remote:peer:/fixture",
            &item,
            1_000_000,
            || true
        )
        .unwrap(),
        Outcome::Accepted { .. }
    ));
    let requests = server.join().unwrap();
    assert_eq!(requests[1]["params"]["method"], "protocol");
    assert_eq!(requests[2]["params"]["method"], "workspace.access.check");
    assert_eq!(requests[3]["params"]["method"], "chat.send");
    assert_eq!(requests[3]["params"]["peer"], "peer");
}
#[test]
fn remote_refusal_keeps_the_queue_without_sending() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("remote.sock");
    let server = host(
        socket.clone(),
        vec![
            protocol(),
            ("remote.call", ok(json!({"protocolVersion":"14"}))),
            ("remote.call", ok(json!({"allowed":false}))),
        ],
    );
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let mut owner = reference();
    owner.host_identity = "peer".into();
    let item = message();
    store
        .update(&owner, |items| {
            items.push(item.clone());
            Ok(())
        })
        .unwrap();
    assert!(
        deliver(
            &store,
            &client(socket),
            &owner,
            "remote:peer:/fixture",
            &item,
            1_000_000,
            || true
        )
        .is_err()
    );
    assert_eq!(store.items(&owner).unwrap()[0], item);
    assert_eq!(server.join().unwrap().len(), 3);
}

#[test]
fn acknowledgement_never_claims_a_newer_or_different_draft() {
    let draft = crate::drafts::Draft {
        reference: reference(),
        text: "  original  ".into(),
        attachments: vec![],
        updated_at: Date(1.),
        message_id: Some("stable".into()),
    };
    let mut submitted = message();
    submitted.id = "stable".into();
    submitted.text = "original".into();
    submitted.source_draft_text = Some(draft.text.clone());
    assert!(acknowledged_draft(&reference(), &draft, &submitted));
    let mut other = reference();
    other.host_identity = "other-host".into();
    assert!(!acknowledged_draft(&other, &draft, &submitted));
    let mut edited = draft.clone();
    edited.text = "new words".into();
    assert!(!acknowledged_draft(&reference(), &edited, &submitted));
    edited = draft.clone();
    edited.message_id = Some("new-id".into());
    assert!(!acknowledged_draft(&reference(), &edited, &submitted));
    edited = draft.clone();
    edited.attachments.push(crate::drafts::Attachment {
        id: "new".into(),
        name: "file".into(),
        media_type: None,
        size: None,
        tool_call_id: None,
    });
    assert!(!acknowledged_draft(&reference(), &edited, &submitted));
}

#[test]
fn retired_owner_after_reservation_restores_unsent_record() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let server = host(socket.clone(), vec![protocol()]);
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let item = message();
    queued(&store, &item);
    let calls = AtomicUsize::new(0);
    assert!(
        deliver(
            &store,
            &client(socket),
            &reference(),
            "/fixture",
            &item,
            1_000_000,
            || calls.fetch_add(1, Ordering::Relaxed) < 2
        )
        .is_err()
    );
    assert_eq!(store.items(&reference()).unwrap()[0], item);
    assert_eq!(server.join().unwrap().len(), 1);
}
#[test]
fn old_peer_is_rejected_without_changing_queue_or_sending() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("remote.sock");
    let server = host(
        socket.clone(),
        vec![
            protocol(),
            ("remote.call", ok(json!({"protocolVersion":"13"}))),
        ],
    );
    let store = Store::at(root.path().join("drafts"), storage::MAX_FILE_BYTES);
    let mut owner = reference();
    owner.host_identity = "peer".into();
    let item = message();
    store
        .update(&owner, |items| {
            items.push(item.clone());
            Ok(())
        })
        .unwrap();
    assert!(
        deliver(
            &store,
            &client(socket),
            &owner,
            "remote:peer:/fixture",
            &item,
            1_000_000,
            || true
        )
        .is_err()
    );
    assert_eq!(store.items(&owner).unwrap()[0], item);
    assert_eq!(server.join().unwrap().len(), 2);
}
