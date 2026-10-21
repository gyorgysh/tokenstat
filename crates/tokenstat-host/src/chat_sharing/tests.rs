// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn fixture() -> (tempfile::TempDir, Store, Conversation) {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir_all(root.path().join("chat")).unwrap();
    let store = Store::load_at(root.path().join("chat"));
    let chat: Conversation = serde_json::from_value(
        json!({"id":"chat_fixture","workspaceId":"workspace_fixture",
        "backend":"codex","title":"Shared review","createdAtMs":1,"updatedAtMs":1}),
    )
    .unwrap();
    fs::write(
        store.root.join("conversations.json"),
        serde_json::to_vec(&Index {
            conversations: vec![chat.clone()],
        })
        .unwrap(),
    )
    .unwrap();
    store.conversations.lock().unwrap().push(chat.clone());
    (root, store, chat)
}
#[test]
fn previews_never_serialize_resume_tokens_private_setup_or_untrusted_actor_fields() {
    let (_root, _store, mut chat) = fixture();
    chat.resume_token = Some("PRIVATE_CONTINUATION".into());
    chat.resume_tokens
        .insert("codex".into(), "PRIVATE_CONTINUATION_MAP".into());
    chat.system_prompt = "PRIVATE_SYSTEM_SETUP".into();
    chat.allowed_shell_prefixes = vec!["PRIVATE_GRANT".into()];
    let records = [
        json!({"kind":"user","text":"Visible history","at_ms":1,"author":{"id":"forged-person"},"private":"PRIVATE_RAW"}),
        json!({"kind":"agent","at_ms":2,"backend":"codex","event":{"kind":"session","id":"PRIVATE_VENDOR_SESSION"}}),
        json!({"kind":"agent","at_ms":3,"backend":"codex","event":{"kind":"text","delta":"Visible reply","raw":"PRIVATE_RAW"}}),
        json!({"kind":"handoff","at_ms":4,"to":"claude","brief":"Native session references: PRIVATE_OLD_CONTINUATION /private/host/history.md"}),
    ];
    let bytes = records
        .iter()
        .map(|row| row.to_string() + "\n")
        .collect::<String>();
    let history = project(&chat, bytes.as_bytes()).unwrap();
    assert_eq!(history.events.len(), 3);
    assert_eq!(history.events[0]["author"]["kind"], "localBeforeTeams");
    let encoded = serde_json::to_string(&history).unwrap();
    for private in [
        "PRIVATE_",
        "forged-person",
        "workspace_fixture",
        "fingerprint",
        "resumeToken",
        "systemPrompt",
        "allowedShell",
    ] {
        assert!(
            !encoded.contains(private),
            "Unexpected private field: {private}"
        );
    }
    assert!(encoded.contains("Visible history"));
    assert!(encoded.contains("Visible reply"));
}
#[test]
fn previews_preserve_visible_charts_tools_attachments_and_legacy_timestamps() {
    let (_root, _store, chat) = fixture();
    let chart = "```tokenstat-chart\n{\"version\":1,\"type\":\"bar\"}\n```";
    let rows = [
        json!({"kind":"user","text":chart,"atMs":5}),
        json!({"kind":"agent","at_ms":6,"backend":"codex","event":{"kind":"toolStart","call_id":"tool_fixture","verb":"Read","target":"example.rs","input":{"path":"example.rs"}}}),
        json!({"kind":"agent","at_ms":7,"backend":"codex","event":{"kind":"attachment","id":"file_fixture","name":"Chart.png","media_type":"image/png","size":23}}),
    ];
    let history = project(
        &chat,
        rows.iter()
            .map(|row| row.to_string() + "\n")
            .collect::<String>()
            .as_bytes(),
    )
    .unwrap();
    assert_eq!(history.events[0]["text"], chart);
    assert_eq!(history.events[0]["atMs"], 5);
    assert_eq!(history.events[1]["event"]["callId"], "tool_fixture");
    assert_eq!(history.events[2]["event"]["id"], "file_fixture");
}
#[test]
fn history_review_is_workspace_bound_and_detects_source_changes() {
    let (_root, store, chat) = fixture();
    assert!(store.sharing_history("other_workspace", &chat.id).is_err());
    let first = store.sharing_history(&chat.workspace_id, &chat.id).unwrap();
    assert!(first.events.is_empty());
    store
        .append(
            &chat.id,
            &StoredEvent::User {
                text: "New visible message".into(),
                at_ms: 1,
                steer: false,
            },
        )
        .unwrap();
    let second = store.sharing_history(&chat.workspace_id, &chat.id).unwrap();
    assert_ne!(first.fingerprint, second.fingerprint);
    assert_eq!(second.events.len(), 1);
    let third = store.sharing_history(&chat.workspace_id, &chat.id).unwrap();
    assert_eq!(second.fingerprint, third.fingerprint);
    let lease = crate::chat_receipts::RunnerLease::try_acquire(&store.root, &chat.id)
        .unwrap()
        .unwrap();
    assert_eq!(
        store
            .sharing_history(&chat.workspace_id, &chat.id)
            .err()
            .unwrap()
            .code,
        "chat_running"
    );
    drop(lease);
}
#[test]
fn malformed_or_unknown_visible_records_cannot_be_silently_omitted() {
    let (_root, _store, chat) = fixture();
    for bytes in [
        b"invalid\n".as_slice(),
        br#"{"kind":"futureVisibleEvent","text":"not reviewed"}"#,
    ] {
        assert!(project(&chat, bytes).is_err());
    }
}

#[test]
fn conversion_freezes_personal_sends_and_stale_instances_without_rewriting_history() {
    let (_root, store, chat) = fixture();
    let stale = Arc::new(Store::load_at(store.root.clone()));
    let before = store.sharing_history(&chat.workspace_id, &chat.id).unwrap();
    let share = format!("share_{}", "a".repeat(32));
    assert!(
        store
            .freeze_sharing(&chat.workspace_id, &chat.id, &share, &"00".repeat(32))
            .is_err()
    );
    assert!(store.require_private_chat(&chat.id).is_ok());
    store
        .freeze_sharing(&chat.workspace_id, &chat.id, &share, &before.fingerprint)
        .unwrap();
    store
        .freeze_sharing(&chat.workspace_id, &chat.id, &share, &before.fingerprint)
        .unwrap();
    assert_eq!(
        store
            .sharing_history(&chat.workspace_id, &chat.id)
            .unwrap()
            .fingerprint,
        before.fingerprint
    );
    assert_eq!(
        stale.require_private_chat(&chat.id).unwrap_err().code,
        "shared_chat_requires_team"
    );
    let send = stale.send(
        &chat.id,
        "A private draft must stay private",
        &[],
        Some("fixture-message"),
        Some(now_ms()),
        Some(chat.send_revision),
    );
    assert_eq!(send.unwrap_err().code, "shared_chat_requires_team");
    assert!(
        stale
            .update(
                &chat.id,
                Update {
                    title: Some("Unexpected title".into()),
                    ..Update::default()
                }
            )
            .is_err()
    );
    assert!(stale.remove(&chat.id).is_err());
    assert_eq!(store.remove_all(&chat.workspace_id).unwrap(), 0);
    assert!(
        store
            .clear_sharing(
                &chat.workspace_id,
                &chat.id,
                &format!("share_{}", "b".repeat(32))
            )
            .is_err()
    );
    store
        .clear_sharing(&chat.workspace_id, &chat.id, &share)
        .unwrap();
    assert!(stale.require_private_chat(&chat.id).is_ok());
    assert_eq!(
        store
            .sharing_history(&chat.workspace_id, &chat.id)
            .unwrap()
            .fingerprint,
        before.fingerprint
    );
}

#[test]
fn shared_reads_require_the_exact_marker_and_reject_late_private_writes() {
    let (_root, store, chat) = fixture();
    store
        .append(
            &chat.id,
            &StoredEvent::User {
                text: "Approved message".into(),
                at_ms: 1,
                steer: false,
            },
        )
        .unwrap();
    let history = store.sharing_history(&chat.workspace_id, &chat.id).unwrap();
    let share = format!("share_{}", "a".repeat(32));
    assert!(
        store
            .shared_history(&chat.workspace_id, &chat.id, &share, &history.fingerprint)
            .is_err()
    );
    store
        .freeze_sharing(&chat.workspace_id, &chat.id, &share, &history.fingerprint)
        .unwrap();
    assert_eq!(
        store
            .shared_history(&chat.workspace_id, &chat.id, &share, &history.fingerprint)
            .unwrap()
            .events
            .len(),
        1
    );
    assert!(
        store
            .shared_history(
                &chat.workspace_id,
                &chat.id,
                &format!("share_{}", "b".repeat(32)),
                &history.fingerprint
            )
            .is_err()
    );
    assert!(
        store
            .shared_history(&chat.workspace_id, &chat.id, &share, &"ab".repeat(32))
            .is_err()
    );
    // Model a legacy binary that has no Team mutation guard. The reader must
    // refuse the whole response, not label this new private note historical.
    store
        .append(
            &chat.id,
            &StoredEvent::User {
                text: "PRIVATE_LATE_NOTE".into(),
                at_ms: 2,
                steer: false,
            },
        )
        .unwrap();
    let error = store
        .shared_history(&chat.workspace_id, &chat.id, &share, &history.fingerprint)
        .err()
        .unwrap();
    assert_eq!(error.code, "chat_sharing_paused");
    assert!(!error.message.contains("PRIVATE_LATE_NOTE"));
}

#[test]
fn reordered_or_rewritten_approved_records_fail_closed() {
    let (_root, store, chat) = fixture();
    let directory = store.root.join(&chat.id);
    fs::create_dir_all(&directory).unwrap();
    let path = directory.join("events.ndjson");
    let first = b"{\"seq\":1,\"kind\":\"user\",\"text\":\"Approved\",\"at_ms\":1}\n";
    fs::write(&path, first).unwrap();
    let history = store.sharing_history(&chat.workspace_id, &chat.id).unwrap();
    let share = format!("share_{}", "a".repeat(32));
    store
        .freeze_sharing(&chat.workspace_id, &chat.id, &share, &history.fingerprint)
        .unwrap();
    fs::write(
        &path,
        String::from_utf8_lossy(first).replace("Approved", "Replaced"),
    )
    .unwrap();
    assert_eq!(
        store
            .shared_history(&chat.workspace_id, &chat.id, &share, &history.fingerprint)
            .err()
            .unwrap()
            .code,
        "chat_sharing_paused"
    );
    let unordered=b"{\"seq\":2,\"kind\":\"user\",\"text\":\"a\",\"at_ms\":1}\n{\"seq\":1,\"kind\":\"user\",\"text\":\"b\",\"at_ms\":2}\n";
    assert!(project(&chat, unordered).is_err());
}

#[cfg(unix)]
#[test]
fn history_review_refuses_linked_source_files_and_non_regular_inputs() {
    let (root, store, chat) = fixture();
    let directory = store.root.join(&chat.id);
    fs::create_dir_all(&directory).unwrap();
    let outside = root.path().join("other-private-chat.ndjson");
    fs::write(
        &outside,
        b"{\"kind\":\"user\",\"text\":\"unrelated private message\",\"at_ms\":1}\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(&outside, directory.join("events.ndjson")).unwrap();
    let error = store
        .sharing_history(&chat.workspace_id, &chat.id)
        .err()
        .unwrap();
    assert_eq!(error.code, "chat_history_unavailable");
    assert!(!error.message.contains("unrelated private message"));
    assert!(read_private(&directory, HISTORY_LIMIT, false).is_err());
}
