// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Disposable host for the native continuity acceptance runner. It uses only
//! synthetic records, a private socket and independently configured roots.
#![cfg(all(feature = "local-host", unix))]
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn call(method: &str, params: Value) -> Value {
    let response: Value = serde_json::from_str(
        &tokenstat_host::dispatch::call_sessionless(method, &params.to_string()).unwrap(),
    )
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn replace_fixture(data: &std::path::Path, path: &std::path::Path, bytes: &[u8]) {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(data.join("transcript.lock"))
        .unwrap();
    // Coordinate this synthetic fixture controller with production readers.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
    let temporary = path.with_extension("fixture-next");
    fs::write(&temporary, bytes).unwrap();
    fs::rename(&temporary, path).unwrap();
}

#[test]
#[ignore = "interactive disposable host for the native acceptance runner"]
fn serve_native_continuity_fixture() {
    let output = PathBuf::from(
        std::env::var_os("TOKENSTAT_NATIVE_QA_OUTPUT").expect("explicit QA output directory"),
    );
    fs::create_dir_all(&output).unwrap();
    let root = tempfile::Builder::new()
        .prefix("tokenstat-native-")
        .tempdir()
        .unwrap();
    let data = root.path().join("data");
    tokenstat_paths::configure_mobile(&data, root.path().join("cache")).unwrap();
    unsafe {
        std::env::set_var("TOKENSTAT_IDENTITY_DIR", root.path().join("identity"));
    }
    let folder = root.path().join("project");
    fs::create_dir(&folder).unwrap();
    let workspace = call("workspace.add", json!({"path":folder}));
    let chat = call(
        "chat.create",
        json!({"workspaceId":workspace["id"],"backend":"codex","personaId":"","title":"Continuity runtime"}),
    );
    let id = chat["id"].as_str().unwrap();
    let directory = data.join("chat").join(id);
    fs::create_dir_all(&directory).unwrap();
    let path = directory.join("events.ndjson");
    let mut bytes = Vec::new();
    for index in 0..700 {
        let row = if index % 20 == 19 {
            json!({"kind":"agent","backend":"codex","at_ms":index,"event":{"kind":"usage","input":100,"output":10,"cache_read":0,"cache_write":0,"cost_usd":0.001}})
        } else {
            json!({"kind":"user","at_ms":index,"text":format!("Note {index}: Keep this reading position when moving between devices. Layout details should stay easy to find.")})
        };
        serde_json::to_writer(&mut bytes, &row).unwrap();
        bytes.push(b'\n');
    }
    fs::write(&path, &bytes).unwrap();
    let socket = root.path().join("host.sock");
    let listener = tokenstat_host::server::bind(&socket).unwrap();
    let session = tokenstat_host::Session::open_client(Some("UTC")).unwrap();
    std::thread::spawn(move || tokenstat_host::server::serve(listener, session).unwrap());
    let manifest = json!({"socket":socket,"workspaceId":workspace["id"],"conversationId":chat["id"],"root":root.path()});
    fs::write(
        output.join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(900);
    let mut stage = 0;
    while !output.join("stop").exists() {
        assert!(
            Instant::now() < deadline,
            "native fixture exceeded its lifetime"
        );
        if stage == 0 && output.join("trim").exists() {
            let next = tokenstat_host::work_transcript_identity::next_sequence(&bytes, 0).unwrap();
            bytes = tokenstat_host::work_transcript_identity::retained(&bytes, 90_000).unwrap();
            // This controller changes synthetic disk state only between native
            // requests. Production append/compaction has separate I/O tests.
            let row = json!({"seq":next,"kind":"agent","backend":"codex","at_ms":701,"event":{"kind":"usage","input":500,"output":50,"cache_read":0,"cache_write":0,"cost_usd":0.005}});
            serde_json::to_writer(&mut bytes, &row).unwrap();
            bytes.push(b'\n');
            replace_fixture(&data, &path, &bytes);
            fs::write(output.join("trim.done"), b"ready").unwrap();
            stage = 1;
        }
        if stage == 1 && output.join("append").exists() {
            let next = tokenstat_host::work_transcript_identity::next_sequence(&bytes, 0).unwrap();
            let row = json!({"seq":next,"kind":"agent","backend":"codex","at_ms":702,"event":{"kind":"usage","input":250,"output":25,"cache_read":0,"cache_write":0,"cost_usd":0.0025}});
            serde_json::to_writer(&mut bytes, &row).unwrap();
            bytes.push(b'\n');
            replace_fixture(&data, &path, &bytes);
            fs::write(output.join("append.done"), b"ready").unwrap();
            stage = 2;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
