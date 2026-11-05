// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Disposable producer for native desktop/phone history verification.

use super::*;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

fn private_directory(path: &Path) {
    std::fs::DirBuilder::new().mode(0o700).create(path).unwrap();
}

fn private_file(path: &Path, bytes: &[u8]) {
    use std::fs::OpenOptions;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .unwrap();
    file.write_all(bytes).unwrap();
}

#[test]
#[ignore = "owned producer started by scripts/tests/chat-history-native.py"]
fn serve_fixture() {
    let root = std::path::PathBuf::from(
        std::env::var_os("TOKENSTAT_NATIVE_HISTORY_ROOT").expect("native fixture root"),
    );
    assert!(root.is_absolute() && root.is_dir());
    assert!(
        !root.join("fixture.json").exists(),
        "use a fresh fixture root"
    );
    let addresses: Value = serde_json::from_str(
        &std::env::var("TOKENSTAT_NATIVE_HISTORY_CLIENTS").expect("client proxy addresses"),
    )
    .unwrap();
    let listen = std::env::var("TOKENSTAT_NATIVE_HISTORY_LISTEN").expect("local listen address");
    let python = std::env::var("TOKENSTAT_NATIVE_HISTORY_PYTHON").expect("fixture Python path");
    for name in [
        "host-data",
        "host-cache",
        "host-identity",
        "workspace",
        "bin",
        "home",
    ] {
        private_directory(&root.join(name));
    }
    private_file(&root.join("provider.ndjson"), b"");
    let provider = format!(
        "#!{python}\n{}",
        include_str!("../../../scripts/qa/chat-history/provider.py")
    );
    private_file(&root.join("bin/grok"), provider.as_bytes());
    std::fs::set_permissions(
        root.join("bin/grok"),
        std::fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    let path = format!(
        "{}:/usr/bin:/bin:/usr/sbin:/sbin",
        root.join("bin").display()
    );
    for name in [".zshenv", ".zprofile", ".zshrc"] {
        private_file(
            &root.join("home").join(name),
            format!(
                "export PATH={}\nHISTFILE=/dev/null\nSAVEHIST=0\n",
                crate::chat_gate::shell_quote(&path)
            )
            .as_bytes(),
        );
    }
    // The controller configures the child before launch. Refuse to use a
    // normal identity or shell environment if started by hand incorrectly.
    assert_eq!(
        std::env::var_os("TOKENSTAT_IDENTITY_DIR"),
        Some(root.join("host-identity").into_os_string())
    );
    assert_eq!(
        std::env::var_os("ZDOTDIR"),
        Some(root.join("home").into_os_string())
    );
    assert_eq!(
        std::env::var_os("HOME"),
        Some(root.join("home").into_os_string())
    );
    tokenstat_paths::configure_mobile(root.join("host-data"), root.join("host-cache")).unwrap();
    let relay: Option<Value> = if std::env::var_os("TOKENSTAT_NATIVE_HISTORY_RELAY").is_some() {
        Some(serde_json::from_slice(&std::fs::read(root.join("relay.json")).unwrap()).unwrap())
    } else {
        None
    };
    if let Some(relay) = &relay {
        let login =
            tokenstat_sync::device_start(Some(relay["accountOrigin"].as_str().unwrap())).unwrap();
        assert!(matches!(
            tokenstat_sync::device_poll(&login).unwrap(),
            tokenstat_sync::DeviceStatus::Confirmed(_)
        ));
    }
    let host = MachineIdentity::load_or_create().unwrap();
    for role in ["desktop", "phone"] {
        let client = root.join(role);
        private_directory(&client);
        for name in ["data", "cache", "identity", "home"] {
            private_directory(&client.join(name));
        }
        let secret: [u8; 32] = rand::random();
        let identity = MachineIdentity::from_secret(secret);
        private_file(&client.join("identity/machine.key"), &secret);
        let mut peers = PeerStore::default();
        peers.add_approved(
            &host.public_key(),
            "Native history fixture",
            if relay.is_some() {
                None
            } else {
                addresses[role].as_str()
            },
            "2026-11-05T00:00:00Z",
        );
        private_file(
            &client.join("identity/peers.json"),
            &serde_json::to_vec(&peers).unwrap(),
        );
        // Only relay runs may use the owned loopback account service.
        // Direct runs have no fallback, and relay peers have no direct address.
        private_file(
            &client.join("identity/remote.json"),
            &serde_json::to_vec(&RemoteSettings {
                tunnel: relay.is_some(),
                relay_fallback: relay.is_some(),
                tunnel_endpoint: if relay.is_some() {
                    format!("ws://{}", addresses[role].as_str().unwrap())
                } else {
                    RemoteSettings::default().tunnel_endpoint
                },
                ..RemoteSettings::default()
            })
            .unwrap(),
        );
        PeerStore::update(|peers| {
            peers.add_approved(&identity.public_key(), role, None, "2026-11-05T00:00:00Z");
            ((), true)
        })
        .unwrap();
        crate::workspace_policy::set_allowed_by_with_label(
            &identity.public_key_hex(),
            true,
            crate::access_audit::Authority::Console,
            None,
        )
        .unwrap();
    }
    local("host.setPolicy", json!({"alwaysOn":true}));
    let workspace = local("workspace.add", json!({"path":root.join("workspace")}));
    let chat = local(
        "chat.create",
        json!({"workspaceId":workspace["id"], "backend":"grok",
        "title":"Native encrypted history", "autonomy":"bypass", "personaId":""}),
    );
    let id = chat["id"].as_str().unwrap();
    let transcript = root.join("host-data/chat").join(id).join("events.ndjson");
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    let mut file = std::fs::File::create(&transcript).unwrap();
    for index in 0..2000 {
        writeln!(
            file,
            "{}",
            json!({"seq":index*1000,"kind":"user",
            "text":format!("archive-{index:04} {}", "saved ".repeat(100)),"at_ms":index+1})
        )
        .unwrap();
    }
    file.flush().unwrap();
    assert!(file.metadata().unwrap().len() > 1024 * 1024);
    drop(file);
    save_settings(&RemoteSettings {
        tunnel: true,
        relay_fallback: relay.is_some(),
        tunnel_endpoint: relay
            .as_ref()
            .and_then(|r| r["relayEndpoint"].as_str())
            .map(str::to_owned)
            .unwrap_or_else(|| RemoteSettings::default().tunnel_endpoint),
        ..RemoteSettings::default()
    })
    .unwrap();
    let server = tokenstat_remote::Server::bind(&listen, &host).unwrap();
    let address = server.local_address().unwrap();
    let session = Arc::new(Mutex::new(Session::open_client(None).unwrap()));
    if relay.is_some() {
        start_tunnel_if_enabled(Arc::clone(&session), &load_settings());
        let deadline = Instant::now() + Duration::from_secs(15);
        while !tunnel_is_connected() {
            assert!(
                Instant::now() < deadline,
                "Fixture host did not connect to relay"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    let local_directory = tempfile::tempdir().unwrap();
    let socket = local_directory.path().join("history.sock");
    let listener = crate::server::bind(&socket).unwrap();
    let local_session = Arc::clone(&session);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let session = Arc::clone(&local_session);
            std::thread::spawn(move || {
                let Ok(input) = stream.try_clone() else {
                    return;
                };
                let mut output = stream;
                // Same production responder; no runtime startup, discovery or
                // additional listeners are needed for this private fixture.
                for line in BufReader::new(input).lines() {
                    let Ok(line) = line else { break };
                    let response = crate::server::respond(&line, &session);
                    if writeln!(output, "{response}").is_err() {
                        break;
                    }
                }
            });
        }
    });
    std::thread::spawn(move || loop {
        match server.accept() {
            Ok(Ok(connection)) => {
                let session = Arc::clone(&session);
                std::thread::spawn(move || serve_peer(connection, &session, Route::Direct));
            }
            Ok(Err(_)) => {}
            Err(_) => std::thread::sleep(Duration::from_millis(20)),
        }
    });
    let attempted = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    local(
        "chat.send",
        json!({"id":id,"text":"Native history verification",
        "clientMessageId":"native-history-start", "clientMessageCreatedAtMs":attempted,
        "expectedRevision":chat["sendRevision"]}),
    );
    let ready = json!({"root":root,"workspaceId":workspace["id"],"conversationId":id,
        "hostKey":host.public_key_hex(),"address":address,"transcript":transcript,"socket":socket});
    private_file(
        &root.join("fixture.json"),
        &serde_json::to_vec_pretty(&ready).unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(900);
    while !root.join("stop").exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = crate::chat::shared().stop(id);
    if relay.is_some() {
        stop_tunnel();
    }
    assert!(
        root.join("stop").exists(),
        "native fixture deadline expired"
    );
}

#[test]
#[ignore = "owned desktop daemon started by scripts/tests/chat-history-native.py"]
fn serve_reader() {
    let root = std::path::PathBuf::from(
        std::env::var_os("TOKENSTAT_NATIVE_HISTORY_ROOT").expect("native fixture root"),
    );
    assert!(root.is_absolute() && root.join("fixture.json").is_file());
    let client = root.join("desktop");
    for (name, path) in [
        ("HOME", client.join("home")),
        ("ZDOTDIR", client.join("home")),
        ("TOKENSTAT_IDENTITY_DIR", client.join("identity")),
    ] {
        assert_eq!(std::env::var_os(name), Some(path.into_os_string()));
    }
    tokenstat_paths::configure_mobile(client.join("data"), client.join("cache")).unwrap();
    let relay: Value =
        serde_json::from_slice(&std::fs::read(root.join("relay.json")).unwrap()).unwrap();
    let login =
        tokenstat_sync::device_start(Some(relay["accountOrigin"].as_str().unwrap())).unwrap();
    assert!(matches!(
        tokenstat_sync::device_poll(&login).unwrap(),
        tokenstat_sync::DeviceStatus::Confirmed(_)
    ));
    let session = Arc::new(Mutex::new(Session::open_client(None).unwrap()));
    register_session(Arc::clone(&session));
    start_tunnel_if_enabled(Arc::clone(&session), &load_settings());
    let deadline = Instant::now() + Duration::from_secs(15);
    while !tunnel_is_connected() {
        assert!(
            Instant::now() < deadline,
            "Desktop reader did not connect to relay"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("reader.sock");
    let listener = crate::server::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    private_file(
        &root.join("reader.json"),
        &serde_json::to_vec(&json!({"socket":socket})).unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(900);
    while !root.join("stop").exists() && Instant::now() < deadline {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).unwrap();
                let session = Arc::clone(&session);
                std::thread::spawn(move || {
                    let input = stream.try_clone().unwrap();
                    let mut output = stream;
                    for line in BufReader::new(input).lines() {
                        let Ok(line) = line else { break };
                        let response = crate::server::respond(&line, &session);
                        if writeln!(output, "{response}").is_err() {
                            break;
                        }
                    }
                });
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => panic!("Desktop reader socket failed: {error}"),
        }
    }
    stop_tunnel();
    assert!(
        root.join("stop").exists(),
        "Desktop reader deadline expired"
    );
}
