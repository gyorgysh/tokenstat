// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#![cfg(feature = "local-host")]

use serde_json::{Value, json};

fn call(session: &mut tokenstat_host::Session, method: &str, params: Value) -> Value {
    serde_json::from_str(&tokenstat_host::dispatch::call(
        session,
        method,
        &params.to_string(),
    ))
    .unwrap()
}

fn job(name: &str, prompt: &str) -> Value {
    json!({
        "id": "",
        "name": name,
        "backend": "claude",
        "workspaceId": "folder",
        "prompt": prompt,
        "schedule": {"kind": "once"},
        "budgetSeconds": 60,
        "enabled": true
    })
}

#[test]
fn automation_edits_and_receipts_over_the_shared_dispatch() {
    let root = tempfile::tempdir().unwrap();
    tokenstat_paths::configure_mobile(root.path().join("data"), root.path().join("cache")).unwrap();
    let mut session = tokenstat_host::Session::open_client(Some("UTC")).unwrap();

    let created = call(
        &mut session,
        "automation.create",
        json!({"job": job("Nightly", "Original prompt")}),
    );
    assert_eq!(created["ok"], true, "{created}");
    let id = created["result"]["id"].clone();
    let revision = created["result"]["revision"].as_u64().unwrap();
    assert_eq!(revision, 1);

    let missing_revision = call(
        &mut session,
        "automation.edit",
        json!({"job": job("Nightly", "Must not save")}),
    );
    assert_eq!(missing_revision["ok"], false);

    let mut edited_job = job("Nightly", "Edited prompt");
    edited_job["id"] = id.clone();
    let edited = call(
        &mut session,
        "automation.edit",
        json!({"job": edited_job, "expectedRevision": revision}),
    );
    assert_eq!(edited["ok"], true, "{edited}");
    assert_eq!(edited["result"]["prompt"], "Edited prompt");
    assert_eq!(edited["result"]["revision"], 2);

    let mut stale_job = job("Nightly", "Stale prompt");
    stale_job["id"] = id.clone();
    let stale = call(
        &mut session,
        "automation.edit",
        json!({"job": stale_job, "expectedRevision": revision}),
    );
    assert_eq!(stale["ok"], false);

    let listed = call(&mut session, "automation.list", json!({}));
    assert_eq!(listed["result"][0]["prompt"], "Edited prompt");

    let draft = json!({
        "operationId": "fixture-create-dispatch",
        "job": job("Once", "Full instructions")
    });
    let once = call(&mut session, "automation.createOnce", draft.clone());
    assert_eq!(once["ok"], true, "{once}");
    let repeated = call(&mut session, "automation.createOnce", draft.clone());
    assert_eq!(once["result"], repeated["result"]);
    let created_id = once["result"]["jobId"].clone();
    assert_eq!(once["result"]["job"]["revision"], 1);

    assert_eq!(
        call(&mut session, "automation.remove", json!({"id": created_id}))["ok"],
        true
    );
    let receipt = call(
        &mut session,
        "automation.creationReceipt",
        json!({"operationId": "fixture-create-dispatch"}),
    );
    assert_eq!(receipt["result"]["jobId"], once["result"]["jobId"]);
    assert!(receipt["result"]["job"].is_null());
    assert!(call(&mut session, "automation.createOnce", draft.clone())["result"]["job"].is_null());

    let mut changed = draft.clone();
    changed["job"]["prompt"] = json!("Another request");
    assert_eq!(
        call(&mut session, "automation.createOnce", changed)["ok"],
        false
    );

    let workspace = root.path().join("automation-run-workspace");
    std::fs::create_dir(&workspace).unwrap();
    let added = call(
        &mut session,
        "workspace.add",
        json!({"path": workspace.display().to_string()}),
    );
    assert_eq!(added["ok"], true, "{added}");
    let runnable = call(
        &mut session,
        "automation.create",
        json!({
            "job": {
                "id": "",
                "name": "Durable run",
                "backend": "sh",
                "workspaceId": added["result"]["id"],
                "prompt": if cfg!(windows) { "exit 0" } else { "true" },
                "schedule": {"kind": "once"},
                "budgetSeconds": 15,
                "enabled": false
            }
        }),
    );
    assert_eq!(runnable["ok"], true, "{runnable}");
    let operation = "fixture-durable-job-run";
    let started = call(
        &mut session,
        "automation.runOnce",
        json!({"id": runnable["result"]["id"], "operationId": operation}),
    );
    assert_eq!(started["ok"], true, "{started}");
    assert_eq!(started["result"]["operationId"], operation);
    let repeated = call(
        &mut session,
        "automation.runOnce",
        json!({"id": runnable["result"]["id"], "operationId": operation}),
    );
    assert_eq!(repeated["result"]["runId"], started["result"]["runId"]);
    let receipt = call(
        &mut session,
        "automation.runReceipt",
        json!({"operationId": operation}),
    );
    assert_eq!(receipt["result"]["runId"], started["result"]["runId"]);
}
