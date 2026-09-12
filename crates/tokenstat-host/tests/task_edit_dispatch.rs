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
}
