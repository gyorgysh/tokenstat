// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#![cfg(feature = "local-host")]

use serde_json::{Value, json};
use std::process::Command;

fn success(method: &str, params: Value) -> Value {
    let response: Value = serde_json::from_str(
        &tokenstat_host::dispatch::call_sessionless(method, &params.to_string())
            .expect("workspace and pull reads are sessionless"),
    )
    .unwrap();
    assert_eq!(response["ok"], true, "{method}: {response}");
    response["result"].clone()
}

/// Opt in with GitHub credentials. Uses a temporary local registry and a public
/// repository, and only reads from GitHub. It does not start the user's host.
#[test]
#[ignore = "requires network access and GitHub credentials"]
fn list_pages_cross_the_host_dispatch() {
    let root = tempfile::tempdir().unwrap();
    tokenstat_paths::configure_mobile(root.path().join("data"), root.path().join("cache")).unwrap();
    let folder = root.path().join("project");
    std::fs::create_dir(&folder).unwrap();
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .current_dir(&folder)
            .status()
            .unwrap()
            .success()
    );
    assert!(
        Command::new("git")
            .args([
                "remote",
                "add",
                "origin",
                "https://github.com/rust-lang/rust.git"
            ])
            .current_dir(&folder)
            .status()
            .unwrap()
            .success()
    );
    let workspace = success("workspace.add", json!({"path": folder}));
    let id = workspace["id"].as_str().unwrap();
    let first = success(
        "pulls.listPage",
        json!({"workspaceId": id, "scope": "all", "state": "open", "limit": 40}),
    );
    let cursor = first["nextCursor"]
        .as_str()
        .expect("the public repository has more than 40 open pulls");
    let second = success(
        "pulls.listPage",
        json!({"workspaceId": id, "scope": "all", "state": "open", "limit": 40, "cursor": cursor}),
    );
    let first_rows = first["rows"].as_array().unwrap();
    let second_rows = second["rows"].as_array().unwrap();
    assert_eq!(first_rows.len(), 40);
    assert_eq!(second_rows.len(), 40);
    assert!(second_rows.iter().any(|row| {
        !first_rows
            .iter()
            .any(|first| first["number"] == row["number"])
    }));
    let legacy = success(
        "pulls.list",
        json!({"workspaceId": id, "scope": "all", "state": "open", "limit": 40}),
    );
    assert_eq!(legacy.as_array().unwrap().len(), 40);
}
