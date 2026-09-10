// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#![cfg(feature = "local-host")]
use serde_json::{Value, json};
fn call(method: &str, params: Value) -> Value {
    serde_json::from_str(
        &tokenstat_host::dispatch::call_sessionless(method, &params.to_string())
            .expect("sessionless work method"),
    )
    .unwrap()
}
fn success(method: &str, params: Value) -> Value {
    let response = call(method, params);
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}
#[test]
fn search_reads_real_store_and_refuses_stale_continuations_after_deletion() {
    let root = tempfile::tempdir().unwrap();
    let data = root.path().join("data");
    tokenstat_paths::configure_mobile(&data, root.path().join("cache")).unwrap();
    unsafe {
        std::env::set_var("TOKENSTAT_IDENTITY_DIR", root.path().join("identity"));
    }
    let folder = root.path().join("project");
    std::fs::create_dir(&folder).unwrap();
    let workspace = success("workspace.add", json!({"path":folder}));
    let workspace_id = workspace["id"].as_str().unwrap();
    let mut ids = vec![];
    for title in ["Layout one", "Layout two"] {
        let chat = success(
            "chat.create",
            json!({"workspaceId":workspace_id,"backend":"codex","personaId":"","title":title}),
        );
        let id = chat["id"].as_str().unwrap().to_owned();
        let directory = data.join("chat").join(&id);
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(
            directory.join("events.ndjson"),
            "{\"kind\":\"user\",\"text\":\"A café layout\",\"at_ms\":1}\n",
        )
        .unwrap();
        ids.push(id);
    }
    let page = success("chat.eventPage", json!({"id":ids[0]}));
    let idle = success(
        "chat.events",
        json!({"id":ids[0],"offset":page["nextOffset"],"tailCursor":page["tailCursor"]}),
    );
    assert_eq!(idle["reset"], false);
    assert_eq!(idle["events"], json!([]));
    let stale = success(
        "chat.events",
        json!({"id":ids[0],"offset":page["nextOffset"],"tailCursor":"invalid"}),
    );
    assert_eq!(stale["reset"], true);
    assert_eq!(stale["events"], json!([]));
    assert!(stale["tailCursor"].is_string());
    let legacy = success("chat.events", json!({"id":ids[0],"offset":0}));
    assert_eq!(legacy["events"][0]["text"], "A café layout");
    let first = success("work.search", json!({"query":"CAFÉ layout","limit":1}));
    assert_eq!(first["hits"].as_array().unwrap().len(), 1);
    assert_eq!(first["hits"][0]["source"], "live");
    assert_eq!(first["hits"][0]["folderName"], "project");
    assert_eq!(first["hits"][0]["reference"]["anchor"], "user-s0");
    let identity = success("machine.identity", json!({}));
    assert_eq!(
        first["hits"][0]["reference"]["hostIdentity"],
        identity["key"]
    );
    assert_eq!(first["hits"][0]["reference"]["scope"]["kind"], "local");
    let cursor = first["nextCursor"].as_str().unwrap();
    let second = success(
        "work.search",
        json!({"query":"CAFÉ layout","limit":1,"cursor":cursor}),
    );
    assert_ne!(
        first["hits"][0]["reference"]["itemId"],
        second["hits"][0]["reference"]["itemId"]
    );
    std::fs::write(
        data.join("chat").join(&ids[0]).join("events.ndjson"),
        "{\"seq\":9000,\"kind\":\"user\",\"text\":\"Retained café layout\",\"at_ms\":1}\n",
    )
    .unwrap();
    let stable = success(
        "chat.eventPage",
        json!({"id":ids[0],"stablePositions":true}),
    );
    let compatible = success("chat.eventPage", json!({"id":ids[0]}));
    assert_eq!(stable["events"][0]["seq"], 9000);
    assert_eq!(compatible["events"][0]["seq"], 0);
    let live = success(
        "chat.events",
        json!({"id":ids[0],"offset":0,"stablePositions":true}),
    );
    assert_eq!(live["events"][0]["seq"], 9000);
    success("chat.remove", json!({"id":ids[0]}));
    assert_eq!(
        call(
            "work.search",
            json!({"query":"CAFÉ layout","limit":1,"cursor":cursor})
        )["ok"],
        false
    );
    let fresh = success("work.search", json!({"query":"CAFÉ layout"}));
    assert_eq!(fresh["hits"].as_array().unwrap().len(), 1);
    assert_eq!(fresh["hits"][0]["reference"]["itemId"], ids[1]);
    assert_eq!(
        call("work.search", json!({"query":"layout","scope":"forged"}))["ok"],
        false
    );
}
