// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Real encrypted connections and production dispatch, with isolated host data.
use super::*;
use std::collections::HashSet;
use std::io::Write;
use std::process::{Command, Stdio};

#[path = "remote_history_native.rs"]
mod native;

#[test]
fn encrypted_history_readers_keep_independent_cursors_across_reconnect() {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "remote::history_tests::encrypted_history_child",
            "--ignored",
            "--nocapture",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            let output = child.wait_with_output().unwrap();
            panic!(
                "Encrypted history fixture timed out: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    print!("{}", String::from_utf8_lossy(&output.stdout));
}

fn local(method: &str, params: Value) -> Value {
    let response: Value = serde_json::from_str(
        &crate::dispatch::call_sessionless(method, &params.to_string()).unwrap(),
    )
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn rpc(connection: &mut tokenstat_remote::Connection, method: &str, params: Value) -> Value {
    let request = json!({"id": 1, "method": method, "params": params});
    connection.send(request.to_string().as_bytes()).unwrap();
    let bytes = connection
        .receive_within(8 * 1024 * 1024, Duration::from_secs(10))
        .unwrap();
    let response: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn tail_params(id: &Value, page: &Value, stable: bool) -> Value {
    json!({"id": id, "offset": page["nextOffset"], "tailCursor": page["tailCursor"], "stablePositions": stable})
}

#[test]
#[ignore = "isolated process launched by the encrypted history parent"]
fn encrypted_history_child() {
    let root = tempfile::tempdir().unwrap();
    let data = root.path().join("data");
    tokenstat_paths::configure_mobile(&data, root.path().join("cache")).unwrap();
    // The parent starts this child alone, before threads or identity readers exist.
    unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", root.path().join("identity")) };
    // Deterministic keys belong only to this disposable fixture and its relay.
    let identity_directory = tokenstat_identity::identity_dir().unwrap();
    std::fs::write(identity_directory.join("machine.key"), [60u8; 32]).unwrap();
    let host = MachineIdentity::load_or_create().unwrap();
    let phone = MachineIdentity::from_secret([61; 32]);
    let desktop = MachineIdentity::from_secret([62; 32]);
    for peer in [&phone, &desktop] {
        PeerStore::update(|peers| {
            peers.add_approved(
                &peer.public_key(),
                "History fixture",
                None,
                "2026-11-05T00:00:00Z",
            );
            ((), true)
        })
        .unwrap();
        crate::workspace_policy::set_allowed_by_with_label(
            &peer.public_key_hex(),
            true,
            crate::access_audit::Authority::Console,
            None,
        )
        .unwrap();
    }
    local("host.setPolicy", json!({"alwaysOn": true}));
    let folder = root.path().join("workspace");
    std::fs::create_dir(&folder).unwrap();
    let workspace = local("workspace.add", json!({"path": folder}));
    let chat = local(
        "chat.create",
        json!({"workspaceId": workspace["id"], "backend": "codex", "personaId": ""}),
    );
    let id = &chat["id"];
    let path = data
        .join("chat")
        .join(id.as_str().unwrap())
        .join("events.ndjson");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut file = std::fs::File::create(&path).unwrap();
    const ROWS: usize = 2000;
    for index in 0..ROWS {
        writeln!(file, "{}", json!({"seq": index * 1000, "kind": "user", "text": format!("saved-{index} {}", "x".repeat(600)), "at_ms": index + 1})).unwrap();
    }
    file.flush().unwrap();
    assert!(file.metadata().unwrap().len() > 1024 * 1024);
    save_settings(&RemoteSettings {
        tunnel: true,
        ..RemoteSettings::default()
    })
    .unwrap();
    let relay = std::env::var("TOKENSTAT_HISTORY_TEST_RELAY").ok();
    let mut tunnels = Vec::new();
    let (address, worker) = if let Some(endpoint) = relay.as_ref() {
        use tokenstat_remote::tunnel::{ChannelTransport, TunnelSession};
        for (identity, key) in [(&host, "HOST"), (&phone, "PHONE"), (&desktop, "DESKTOP")] {
            let token = std::env::var(format!("TOKENSTAT_HISTORY_TEST_TOKEN_{key}")).unwrap();
            tunnels.push(TunnelSession::spawn(endpoint, identity, &token));
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while !tunnels.iter().all(|session| session.status().connected) {
            assert!(
                Instant::now() < deadline,
                "All three fixture devices must register"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let serving = Arc::clone(&tunnels[0]);
        let inbound = serving.take_inbound().unwrap();
        let worker = std::thread::spawn(move || {
            let identity = MachineIdentity::load_or_create().unwrap();
            let session = Arc::new(Mutex::new(Session::open_client(None).unwrap()));
            let mut readers = Vec::new();
            for _ in 0..4 {
                let state = inbound.recv_timeout(Duration::from_secs(20)).unwrap();
                let transport = ChannelTransport::from_inbound(Arc::clone(&serving), state);
                let connection =
                    tokenstat_remote::handshake_responder(Box::new(transport), &identity).unwrap();
                let session = Arc::clone(&session);
                readers.push(std::thread::spawn(move || {
                    serve_peer(connection, &session, Route::Relay)
                }));
            }
            for reader in readers {
                reader.join().unwrap();
            }
        });
        (String::new(), worker)
    } else {
        let server = tokenstat_remote::Server::bind("127.0.0.1:0", &host).unwrap();
        let address = server.local_address().unwrap();
        let worker = std::thread::spawn(move || {
            let session = Arc::new(Mutex::new(Session::open_client(None).unwrap()));
            let mut readers = Vec::new();
            // Two readers plus a replacement connection for each.
            for _ in 0..4 {
                let connection = server.accept().unwrap().unwrap();
                let session = Arc::clone(&session);
                readers.push(std::thread::spawn(move || {
                    serve_peer(connection, &session, Route::Direct)
                }));
            }
            for reader in readers {
                reader.join().unwrap();
            }
        });
        (address, worker)
    };
    let dial = |identity: &MachineIdentity| {
        if relay.is_some() {
            let index = if identity.public_key() == phone.public_key() {
                1
            } else {
                2
            };
            let channel = tunnels[index]
                .open_channel(host.public_key(), ChannelPurpose::Chat)
                .unwrap();
            tokenstat_remote::handshake_initiator(
                Box::new(channel),
                identity,
                Some(host.public_key()),
                "History host",
            )
            .unwrap()
        } else {
            tokenstat_remote::dial_with_timeout(
                &address,
                identity,
                Some(host.public_key()),
                "History host",
                Duration::from_secs(5),
            )
            .unwrap()
        }
    };
    let mut phone_connection = dial(&phone);
    let mut desktop_connection = dial(&desktop);
    let page_params =
        |stable| json!({"id": id, "limit": 137, "stablePositions": stable, "includeUsage": false});
    let mut phone_page = rpc(&mut phone_connection, "chat.eventPage", page_params(false));
    let mut desktop_page = rpc(&mut desktop_connection, "chat.eventPage", page_params(true));
    assert_eq!(phone_page["events"].as_array().unwrap().len(), 137);
    assert_eq!(desktop_page["events"].as_array().unwrap().len(), 137);
    let phone_start = phone_page.clone();
    let desktop_start = desktop_page.clone();
    for index in 0..24 {
        let event = json!({"seq": (ROWS + index) * 1000, "kind": "agent", "backend": "codex", "at_ms": ROWS + index + 1, "event": {"kind": "text", "delta": format!("live-{index} 🧪")}}).to_string() + "\n";
        let half = event.find("🧪").unwrap() + 1;
        file.write_all(&event.as_bytes()[..half]).unwrap();
        file.flush().unwrap();
        let partial = rpc(
            &mut phone_connection,
            "chat.events",
            tail_params(id, &phone_page, false),
        );
        assert_eq!(partial["reset"], false);
        assert!(partial["events"].as_array().unwrap().is_empty());
        assert_eq!(
            partial["nextOffset"], phone_page["nextOffset"],
            "Do not advance past an incomplete event"
        );
        file.write_all(&event.as_bytes()[half..]).unwrap();
        file.flush().unwrap();
        let (phone_tail, desktop_tail) = std::thread::scope(|scope| {
            let phone = scope.spawn(|| {
                rpc(
                    &mut phone_connection,
                    "chat.events",
                    tail_params(id, &phone_page, false),
                )
            });
            let desktop = scope.spawn(|| {
                rpc(
                    &mut desktop_connection,
                    "chat.events",
                    tail_params(id, &desktop_page, true),
                )
            });
            (phone.join().unwrap(), desktop.join().unwrap())
        });
        for tail in [&phone_tail, &desktop_tail] {
            assert_eq!(
                tail["reset"], false,
                "A second reader must not reset the first"
            );
            let events = tail["events"].as_array().unwrap();
            assert_eq!(events.len(), 1);
            assert_eq!(events[0]["event"]["delta"], format!("live-{index} 🧪"));
        }
        phone_page = phone_tail;
        desktop_page = desktop_tail;
        if index == 16 {
            desktop_connection.close();
            desktop_connection = dial(&desktop);
            let empty = rpc(
                &mut desktop_connection,
                "chat.events",
                tail_params(id, &desktop_page, true),
            );
            assert_eq!(empty["reset"], false);
            assert!(empty["events"].as_array().unwrap().is_empty());
        }
        if index == 10 {
            phone_connection.close();
            phone_connection = dial(&phone);
            let empty = rpc(
                &mut phone_connection,
                "chat.events",
                tail_params(id, &phone_page, false),
            );
            assert_eq!(empty["reset"], false);
            assert!(
                empty["events"].as_array().unwrap().is_empty(),
                "Reconnect must retain the cursor without replay"
            );
        }
    }
    for (connection, stable, start) in [
        (&mut phone_connection, false, phone_start),
        (&mut desktop_connection, true, desktop_start),
    ] {
        let catch_up = rpc(connection, "chat.events", tail_params(id, &start, stable));
        assert_eq!(catch_up["reset"], false);
        assert_eq!(catch_up["events"].as_array().unwrap().len(), 24);
        let mut params = page_params(stable);
        let mut saved = HashSet::new();
        let mut live = HashSet::new();
        loop {
            let page = rpc(connection, "chat.eventPage", params.clone());
            assert_eq!(page["historyTrimmed"], false);
            assert_eq!(page["reset"], false);
            for event in page["events"].as_array().unwrap() {
                if let Some(text) = event["text"].as_str() {
                    assert!(saved.insert(text.to_owned()), "No duplicate saved rows");
                }
                if let Some(delta) = event["event"]["delta"].as_str() {
                    assert!(live.insert(delta.to_owned()), "No duplicate streamed rows");
                }
            }
            if page["cursor"].is_null() {
                break;
            }
            params["cursor"] = page["cursor"].clone();
        }
        assert_eq!(saved.len(), ROWS);
        for index in 0..ROWS {
            assert!(saved.contains(&format!("saved-{index} {}", "x".repeat(600))));
        }
        assert_eq!(live.len(), 24);
    }
    let local_page = local("chat.eventPage", page_params(true));
    assert_eq!(local_page["events"].as_array().unwrap().len(), 137);
    assert_eq!(local_page["historyTrimmed"], false);
    phone_connection.close();
    desktop_connection.close();
    worker.join().unwrap();
    for tunnel in &tunnels {
        tunnel.shutdown();
    }
    println!(
        "History route: {}",
        if relay.is_some() {
            "real relay"
        } else {
            "direct TCP"
        }
    );
    println!(
        "Encrypted history: two pinned peers, legacy/current cursors, 24 split appends, concurrent tails, reconnect and 2024 paged records passed"
    );
}
