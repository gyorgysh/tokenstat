// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#![cfg(feature = "local-host")]

use serde_json::{Value, json};

fn call(method: &str, params: Value) -> Value {
    serde_json::from_str(
        &tokenstat_host::dispatch::call_sessionless(method, &params.to_string()).unwrap(),
    )
    .unwrap()
}

#[test]
fn task_edits_require_the_reviewed_revision_over_the_shared_dispatch() {
    let root = tempfile::tempdir().unwrap();
    tokenstat_paths::configure_mobile(root.path().join("data"), root.path().join("cache")).unwrap();
    let created = call(
        "todo.create",
        json!({"title":"Fixture task","workspaceId":"","backend":"","notes":"Original prompt"}),
    );
    assert_eq!(created["ok"], true, "{created}");
    let id = &created["result"]["id"];
    let revision = &created["result"]["revision"];
    assert!(revision.as_u64().is_some());
    let missing_revision = call("todo.edit", json!({"id":id,"title":"Must not save"}));
    assert_eq!(missing_revision["ok"], false);
    let edited = call(
        "todo.edit",
        json!({"id":id,"expectedRevision":revision,"title":"Edited task","notes":"Full prompt","budgetSeconds":121,"priority":"high"}),
    );
    assert_eq!(edited["ok"], true, "{edited}");
    let stale = call(
        "todo.edit",
        json!({"id":id,"expectedRevision":revision,"notes":"Stale prompt"}),
    );
    assert_eq!(stale["ok"], false);
    let read = call("todo.get", json!({"id":id}));
    assert_eq!(read["result"]["title"], "Edited task");
    assert_eq!(read["result"]["notes"], "Full prompt");
    assert_eq!(read["result"]["budgetSeconds"], 121);
    assert_eq!(read["result"]["priority"], "high");
    assert_eq!(read["result"]["revision"], edited["result"]["revision"]);
    assert_eq!(
        call("todo.delete", json!({"id":id,"expectedRevision":revision}))["ok"],
        false
    );
    assert_eq!(
        call(
            "todo.delete",
            json!({"id":id,"expectedRevision":edited["result"]["revision"]})
        )["ok"],
        true
    );
    assert_eq!(call("todo.get", json!({"id":id}))["result"], Value::Null);
    let draft = json!({"operationId":"fixture-create-dispatch", "title":"Created once", "notes":"Full instructions",
                       "workspaceId":"", "backend":"", "budgetSeconds":121, "priority":"high"});
    let once = call("todo.createOnce", draft.clone());
    assert_eq!(once["ok"], true, "{once}");
    let repeated = call("todo.createOnce", draft.clone());
    assert_eq!(once["result"], repeated["result"]);
    let created_id = &once["result"]["cardId"];
    assert_eq!(once["result"]["card"]["budgetSeconds"], 121);
    assert_eq!(
        call("todo.delete", json!({"id":created_id,"expectedRevision":1}))["ok"],
        true
    );
    let receipt = call(
        "todo.creationReceipt",
        json!({"operationId":"fixture-create-dispatch"}),
    );
    assert_eq!(receipt["result"]["cardId"], *created_id);
    assert!(receipt["result"]["card"].is_null());
    assert!(call("todo.createOnce", draft.clone())["result"]["card"].is_null());
    let mut changed = draft.clone();
    changed["notes"] = json!("Another request");
    assert_eq!(call("todo.createOnce", changed)["ok"], false);
    let mut missing_budget = draft;
    missing_budget
        .as_object_mut()
        .unwrap()
        .remove("budgetSeconds");
    assert_eq!(call("todo.createOnce", missing_budget)["ok"], false);

    let workspace = root.path().join("task-run-workspace");
    std::fs::create_dir(&workspace).unwrap();
    let added = call(
        "workspace.add",
        json!({"path": workspace.display().to_string()}),
    );
    assert_eq!(added["ok"], true, "{added}");
    let runnable = call(
        "todo.create",
        json!({
            "title":"Durable run",
            "workspaceId":added["result"]["id"],
            "backend":"sh",
            "notes":"sleep 5",
            "budgetSeconds":30
        }),
    );
    let operation = "fixture-durable-task-run";
    let started = call(
        "todo.runTask",
        json!({
            "id":runnable["result"]["id"],
            "expectedRevision":runnable["result"]["revision"],
            "operationId":operation,
            "placement":"background"
        }),
    );
    assert_eq!(started["ok"], true, "{started}");
    assert_eq!(started["result"]["operationId"], operation);
    assert_eq!(started["result"]["card"]["column"], "doing");
    let repeated = call(
        "todo.runTask",
        json!({
            "id":runnable["result"]["id"],
            "expectedRevision":runnable["result"]["revision"],
            "operationId":operation,
            "placement":"background"
        }),
    );
    assert_eq!(repeated["result"]["runId"], started["result"]["runId"]);
    let receipt = call("todo.runReceipt", json!({"operationId":operation}));
    assert_eq!(receipt["result"]["runId"], started["result"]["runId"]);
    let wrong_stop = call(
        "todo.stopTask",
        json!({
            "id":runnable["result"]["id"],
            "expectedRevision":started["result"]["card"]["revision"],
            "runId":"another-run"
        }),
    );
    assert_eq!(wrong_stop["ok"], false);
    let stopped = call(
        "todo.stopTask",
        json!({
            "id":runnable["result"]["id"],
            "expectedRevision":started["result"]["card"]["revision"],
            "runId":started["result"]["runId"]
        }),
    );
    assert_eq!(stopped["ok"], true, "{stopped}");
    assert_eq!(
        stopped["result"]["delegate"]["runId"],
        started["result"]["runId"]
    );
}
