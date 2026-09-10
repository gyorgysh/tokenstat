// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#![cfg(all(feature = "local-host", unix))]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

fn call(method: &str, params: Value) -> Value {
    serde_json::from_str(
        &tokenstat_host::dispatch::call_sessionless(method, &params.to_string()).unwrap(),
    )
    .unwrap()
}

fn success(method: &str, params: Value) -> Value {
    let answer = call(method, params);
    assert_eq!(answer["ok"], true, "{answer}");
    answer["result"].clone()
}

fn send(socket: &Path, request: &Value, read_answer: bool) -> Option<Value> {
    let mut connection = UnixStream::connect(socket).unwrap();
    connection
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    writeln!(connection, "{request}").unwrap();
    if !read_answer {
        return None;
    }
    let mut line = String::new();
    BufReader::new(connection).read_line(&mut line).unwrap();
    Some(serde_json::from_str(&line).unwrap())
}

/// Two real socket clients and the production host/PTY path. The executable
/// called claude here is a private shell fixture, never an installed agent.
#[test]
fn lost_socket_response_and_concurrent_retries_launch_once() {
    let root = tempfile::tempdir().unwrap();
    let data = root.path().join("data");
    tokenstat_paths::configure_mobile(&data, root.path().join("cache")).unwrap();
    let bin = root.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    let executable = bin.join("claude");
    std::fs::write(&executable, b"#!/bin/sh\nprintf 'launched\\n' >> .receipt-launches\nprintf '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"fixture done\",\"is_error\":false}\\n'\n").unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
    // One test in this executable, before dispatch or PTY worker creation.
    unsafe {
        std::env::set_var("PATH", format!("{}:/usr/bin:/bin", bin.display()));
        std::env::set_var("TOKENSTAT_IDENTITY_DIR", root.path().join("identity"));
    }
    let project = root.path().join("project");
    std::fs::create_dir(&project).unwrap();
    let workspace = success("workspace.add", json!({"path":project}));
    let chat = success(
        "chat.create",
        json!({"workspaceId":workspace["id"],"backend":"claude","personaId":"","autonomy":"full","title":"Receipt fixture"}),
    );
    let socket = root.path().join("host.sock");
    let listener = tokenstat_host::server::bind(&socket).unwrap();
    let session = tokenstat_host::Session::open_client(Some("UTC")).unwrap();
    std::thread::spawn(move || tokenstat_host::server::serve(listener, session).unwrap());
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let request = json!({"id":1,"method":"chat.send","params":{"id":chat["id"],"text":"One synthetic turn","clientMessageId":"lost-reply","clientMessageCreatedAtMs":now,"expectedRevision":chat["sendRevision"]}});
    // Close the first client without consuming its response. The request may
    // race the retries, but only one of them may accept the message.
    send(&socket, &request, false);
    let replies = std::thread::scope(|scope| {
        let first = scope.spawn(|| send(&socket, &request, true).unwrap());
        let second = scope.spawn(|| send(&socket, &request, true).unwrap());
        [first.join().unwrap(), second.join().unwrap()]
    });
    for reply in replies {
        assert_eq!(reply["ok"], true, "{reply}");
    }
    let receipt = success(
        "chat.receipt",
        json!({"id":chat["id"],"clientMessageId":"lost-reply"}),
    );
    assert_eq!(receipt["state"], "accepted");
    let deadline = Instant::now() + Duration::from_secs(10);
    let launches = project.join(".receipt-launches");
    loop {
        if launches.exists()
            && success("chat.list", json!({"workspaceId":workspace["id"]}))[0]["running"] == false
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "fixture process did not complete"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(std::fs::read_to_string(launches).unwrap(), "launched\n");
    let events = std::fs::read_to_string(
        data.join("chat")
            .join(chat["id"].as_str().unwrap())
            .join("events.ndjson"),
    )
    .unwrap();
    assert_eq!(
        events
            .lines()
            .filter(|line| serde_json::from_str::<Value>(line).unwrap()["kind"] == "user")
            .count(),
        1
    );
    let mut conflict = request["params"].clone();
    conflict["text"] = json!("Different words");
    assert_eq!(call("chat.send", conflict)["ok"], false);
    let current = success("chat.list", json!({"workspaceId":workspace["id"]}))[0].clone();
    assert_eq!(chat["sendRevision"], 0);
    assert_eq!(current["sendRevision"], 1);
    let mut stale = request["params"].clone();
    stale["clientMessageId"] = json!("stale-revision");
    assert_eq!(
        call("chat.send", stale)["error"]["code"],
        "conversation_changed"
    );
    assert_eq!(
        success("chat.list", json!({"workspaceId":workspace["id"]}))[0]["sendRevision"],
        1
    );
    // An unseen expired id and a client missing the age contract never launch.
    let mut expired = request["params"].clone();
    expired["clientMessageId"] = json!("expired");
    expired["clientMessageCreatedAtMs"] = json!(now - tokenstat_host::chat_receipts::RETENTION_MS);
    assert_eq!(
        call("chat.send", expired)["error"]["code"],
        "delivery_unknown"
    );
    let old_client = json!({"id":chat["id"],"text":"old client","clientMessageId":"missing-time"});
    assert_eq!(
        call("chat.send", old_client)["error"]["code"],
        "send_upgrade_required"
    );
    let no_revision = json!({"id":chat["id"],"text":"missing context","clientMessageId":"missing-revision","clientMessageCreatedAtMs":now});
    assert_eq!(
        call("chat.send", no_revision)["error"]["code"],
        "send_upgrade_required"
    );
    // Force a deterministic storage failure after spawn: the existing turn
    // makes a handover brief necessary, but its destination is a directory.
    // The live fixture must still be drained and must never run again on retry.
    let chat_root = data.join("chat").join(chat["id"].as_str().unwrap());
    std::fs::create_dir(chat_root.join("brain.md")).unwrap();
    let uncertain = json!({"id":chat["id"],"text":"Keep this unresolved turn","clientMessageId":"post-spawn-failure","clientMessageCreatedAtMs":now,"expectedRevision":current["sendRevision"]});
    assert_eq!(
        call("chat.send", uncertain.clone())["error"]["code"],
        "delivery_unknown"
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while success("chat.list", json!({"workspaceId":workspace["id"]}))[0]["running"] != false {
        assert!(
            Instant::now() < deadline,
            "started process was orphaned after a storage failure"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        success(
            "chat.receipt",
            json!({"id":chat["id"],"clientMessageId":"post-spawn-failure"})
        )["state"],
        "needsRecovery"
    );
    assert_eq!(
        call("chat.send", uncertain)["error"]["code"],
        "delivery_unknown"
    );
    assert_eq!(
        std::fs::read_to_string(project.join(".receipt-launches")).unwrap(),
        "launched\nlaunched\n"
    );
}
