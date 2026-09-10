// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#![cfg(feature = "local-host")]

use serde_json::{Value, json};

fn call(method: &str, params: Value) -> Value {
    serde_json::from_str(
        &tokenstat_host::dispatch::call_sessionless(method, &params.to_string())
            .expect("handoff and workspace methods do not need an archive session"),
    )
    .unwrap()
}

fn success(method: &str, params: Value) -> Value {
    let response = call(method, params);
    assert_eq!(response["ok"], true, "{method}: {response}");
    response["result"].clone()
}

/// This is its own test executable: configure process-global roots before any
/// host singleton exists. No developer registry, identity, chat or account is
/// touched. Calls exercise production dispatch and persistent Store together.
#[test]
fn explicit_handoff_round_trip_through_production_dispatch() {
    let root = tempfile::tempdir().unwrap();
    let data = root.path().join("data");
    tokenstat_paths::configure_mobile(&data, root.path().join("cache")).unwrap();
    // Set before host dispatch can start workers; this executable has one test.
    unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", root.path().join("identity")) };
    let folder = root.path().join("project");
    std::fs::create_dir(&folder).unwrap();
    let workspace = success("workspace.add", json!({"path": folder}));
    let workspace_id = workspace["id"].as_str().unwrap();
    let chat = success(
        "chat.create",
        json!({
            "workspaceId": workspace_id, "backend": "codex", "personaId": "",
            "title": "Handoff integration"
        }),
    );
    let chat_id = chat["id"].as_str().unwrap();
    let reference = json!({"workspaceId": workspace_id, "conversationId": chat_id});
    assert!(success("work.continuity.get", reference.clone())["handoff"].is_null());
    let attachment = success(
        "chat.attach",
        json!({
            "id": chat_id, "name": "notes.txt", "data": "c2hhcmVkIG5vdGVz"
        }),
    );
    let attachment_id = attachment["id"].as_str().unwrap();
    let mut request = reference.clone();
    request["handoff"] = json!({
        "requestId": "share-first", "expectedRevision": 0, "deviceName": "Studio",
        "draft": {"text": "Keep the first version", "attachmentIds": [attachment_id]},
        "anchor": {"eventId": "user-s1", "fraction": 2500, "followsLatest": false}
    });
    let saved = success("work.continuity.put", request.clone());
    assert_eq!(saved["status"], "saved");
    assert_eq!(saved["handoff"]["revision"], 1);
    let identity = success("machine.identity", json!({}));
    assert_eq!(saved["handoff"]["deviceId"], identity["key"]);
    // Simulate a lost acknowledgement: exact replay returns the same record,
    // including its timestamp and revision, rather than another write.
    assert_eq!(success("work.continuity.put", request.clone()), saved);
    assert_eq!(
        success("work.continuity.get", reference.clone())["handoff"],
        saved["handoff"]
    );

    let mut competing = request.clone();
    competing["handoff"]["requestId"] = json!("share-competing");
    competing["handoff"]["draft"]["text"] = json!("Keep this version too");
    let conflict = success("work.continuity.put", competing.clone());
    assert_eq!(conflict["status"], "conflict");
    assert_eq!(conflict["current"], saved["handoff"]);
    competing["handoff"]["expectedRevision"] = json!(1);
    assert_eq!(
        success("work.continuity.put", competing)["handoff"]["revision"],
        2
    );

    let mut metadata = reference.clone();
    metadata["attachmentIds"] = json!([attachment_id]);
    let files = success("work.continuity.attachments", metadata.clone());
    assert_eq!(files[0]["id"], attachment_id);
    assert_eq!(files[0]["name"], "notes.txt");
    assert_eq!(files[0]["size"], 12);
    assert!(files[0].get("data").is_none());
    metadata["attachmentIds"] = json!([]);
    assert_eq!(
        success("work.continuity.attachments", metadata.clone()),
        json!([])
    );

    let mut forged = request.clone();
    forged["handoff"]["deviceId"] = json!("claimed-author");
    assert_eq!(call("work.continuity.put", forged)["ok"], false);
    let mut wrong_workspace = reference.clone();
    wrong_workspace["workspaceId"] = json!("unregistered-folder");
    assert_eq!(call("work.continuity.get", wrong_workspace)["ok"], false);

    success("chat.remove", json!({"id": chat_id}));
    assert_eq!(call("work.continuity.get", reference)["ok"], false);
    assert_eq!(call("work.continuity.put", request)["ok"], false);
    assert_eq!(call("work.continuity.attachments", metadata)["ok"], false);
    assert!(!data.join("chat").join(chat_id).exists());
}
