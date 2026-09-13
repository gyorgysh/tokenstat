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

fn graph(name: &str) -> Value {
    json!({
        "id": "",
        "name": name,
        "nodes": [{"id": "in", "kind": "input", "title": "Start"}],
        "edges": []
    })
}

#[test]
fn workflow_edits_over_the_shared_dispatch() {
    let root = tempfile::tempdir().unwrap();
    tokenstat_paths::configure_mobile(root.path().join("data"), root.path().join("cache")).unwrap();
    let mut session = tokenstat_host::Session::open_client(Some("UTC")).unwrap();

    let created = call(
        &mut session,
        "workflow.create",
        json!({"workflow": graph("Evening review")}),
    );
    assert_eq!(created["ok"], true, "{created}");
    let id = created["result"]["id"].clone();
    let revision = created["result"]["revision"].as_u64().unwrap();
    assert_eq!(revision, 1);

    let missing_revision = call(
        &mut session,
        "workflow.edit",
        json!({"workflow": graph("Must not save")}),
    );
    assert_eq!(missing_revision["ok"], false);

    let mut edited_graph = graph("Evening review");
    edited_graph["id"] = id.clone();
    let edited = call(
        &mut session,
        "workflow.edit",
        json!({"workflow": edited_graph, "expectedRevision": revision}),
    );
    assert_eq!(edited["ok"], true, "{edited}");
    assert_eq!(edited["result"]["revision"], 2);

    let mut stale_graph = graph("Stale review");
    stale_graph["id"] = id.clone();
    let stale = call(
        &mut session,
        "workflow.edit",
        json!({"workflow": stale_graph, "expectedRevision": revision}),
    );
    assert_eq!(stale["ok"], false);

    let listed = call(&mut session, "workflow.list", json!({}));
    assert_eq!(listed["result"][0]["name"], "Evening review");
}
