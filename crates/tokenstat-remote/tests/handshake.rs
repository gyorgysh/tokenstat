// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Two machines, one process, a real socket.
//!
//! Everything here runs in one test function on purpose. The peer store is
//! selected by a process-wide environment variable, so two tests with two
//! stores running at once would read each other's approvals, and the failure
//! would look like a refusal bug rather than a test harness bug.

use std::io::Write;
use std::net::TcpStream;

use tokenstat_identity::{MachineIdentity, PeerStore};
use tokenstat_remote::{Refused, Server, dial};

/// Give both ends a store of their own by pointing the variable at a temp
/// directory. Returns a guard that puts it back.
struct Sandbox {
    dir: std::path::PathBuf,
}

impl Sandbox {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("tokenstat-remote-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        // SAFETY: this test binary runs this once, before any thread that
        // reads the variable exists.
        unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", &dir) };
        Self { dir }
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        unsafe { std::env::remove_var("TOKENSTAT_IDENTITY_DIR") };
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn approve(key: &[u8; 32], label: &str) {
    let mut store = PeerStore::load().expect("load");
    store.add_approved(key, label, None, "2026-08-04T10:00:00Z");
    store.save().expect("save");
}

fn revoke(key: &[u8; 32]) {
    let mut store = PeerStore::load().expect("load");
    assert!(store.revoke(key), "peer must exist to be revoked");
    store.save().expect("save");
}

fn forget(key: &[u8; 32]) {
    let mut store = PeerStore::load().expect("load");
    store.forget(key);
    store.save().expect("save");
}

#[test]
fn two_machines_authenticate_each_other_and_nobody_else() {
    let _sandbox = Sandbox::new();

    // Two distinct machines. Neither reads the identity file: these are what a
    // second computer would have.
    let server_identity = MachineIdentity::from_secret([11u8; 32]);
    let client_identity = MachineIdentity::from_secret([22u8; 32]);
    let server_key = server_identity.public_key();
    let client_key = client_identity.public_key();
    assert_ne!(server_key, client_key);

    let server = Server::bind("127.0.0.1:0", &server_identity).expect("bind");
    let address = server.local_address().expect("address");

    // ---- 1. An unknown client is refused, and recorded so somebody can be asked.

    let dialling = {
        let address = address.clone();
        let identity = MachineIdentity::from_secret([22u8; 32]);
        std::thread::spawn(move || dial(&address, &identity, Some(server_key), "server"))
    };
    let refused = server.accept().expect("accept").expect_err("must refuse");
    match refused {
        Refused::Unknown { fingerprint, .. } => {
            assert!(fingerprint.contains('-'), "readable: {fingerprint}");
        }
        other => panic!("expected Unknown, got {other:?}"),
    }
    // The client's handshake completed, so it believes it is connected. That is
    // correct and worth stating: Noise authenticates, the peer store authorizes,
    // and the refusal is the server declining to answer rather than a failed
    // handshake. The client learns when its first request gets nothing back.
    drop(dialling.join().expect("thread"));

    let listed = PeerStore::load().expect("load").list();
    assert_eq!(listed.len(), 1, "an unknown peer is written down");
    assert_eq!(listed[0].key, tokenstat_identity::hex(&client_key));
    assert!(!PeerStore::load().expect("load").is_approved(&client_key));

    // ---- 2. Approved, and the connection carries a message both ways.

    approve(&client_key, "the client");

    let dialling = {
        let address = address.clone();
        std::thread::spawn(move || {
            let identity = MachineIdentity::from_secret([22u8; 32]);
            let mut connection =
                dial(&address, &identity, Some(server_key), "server").expect("dial");
            connection.send(b"{\"method\":\"info\"}").expect("send");
            let reply = connection.receive(1 << 20).expect("receive");
            String::from_utf8(reply).expect("utf8")
        })
    };

    let mut served = server
        .accept()
        .expect("accept")
        .expect("an approved peer is served");
    assert_eq!(served.peer_key(), client_key, "the server knows who it is");
    let request = served.receive(1 << 20).expect("receive");
    assert_eq!(request, b"{\"method\":\"info\"}");
    served.send(b"{\"ok\":true}").expect("send");

    assert_eq!(dialling.join().expect("thread"), "{\"ok\":true}");

    // ---- 3. A payload larger than one Noise message survives the split.

    // Noise caps a message at 65535 bytes. A file diff exceeds that routinely,
    // so this is the ordinary case and not an edge one.
    let big: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    let expected = big.clone();
    let dialling = {
        let address = address.clone();
        std::thread::spawn(move || {
            let identity = MachineIdentity::from_secret([22u8; 32]);
            let mut connection =
                dial(&address, &identity, Some(server_key), "server").expect("dial");
            connection.send(&big).expect("send");
            connection.receive(1 << 20).expect("receive")
        })
    };
    let mut served = server.accept().expect("accept").expect("served");
    let received = served.receive(1 << 20).expect("receive");
    assert_eq!(received, expected, "every byte, in order");
    served.send(b"ok").expect("send");
    assert_eq!(dialling.join().expect("thread"), b"ok");

    // ---- 4. A frame larger than the caller allows is refused, not allocated.

    let dialling = {
        let address = address.clone();
        std::thread::spawn(move || {
            let identity = MachineIdentity::from_secret([22u8; 32]);
            let mut connection =
                dial(&address, &identity, Some(server_key), "server").expect("dial");
            let _ = connection.send(&vec![0u8; 100_000]);
        })
    };
    let mut served = server.accept().expect("accept").expect("served");
    let too_big = served.receive(1024).expect_err("must refuse");
    assert!(too_big.to_string().contains("limit is 1024"), "{too_big}");
    let _ = dialling.join();

    // ---- 5. Revoked stays revoked, however many times it reconnects.

    revoke(&client_key);
    for attempt in 0..3 {
        let address = address.clone();
        let dialling = std::thread::spawn(move || {
            let identity = MachineIdentity::from_secret([22u8; 32]);
            dial(&address, &identity, Some(server_key), "server").map(|mut c| c.close())
        });
        match server.accept().expect("accept") {
            Err(Refused::NotApproved { .. }) => {}
            Err(other) => panic!("attempt {attempt}: expected NotApproved, got {other:?}"),
            Ok(_) => panic!("attempt {attempt}: a revoked peer was served"),
        }
        let _ = dialling.join();
    }

    // ---- 6. A client that pinned a different key refuses the server.

    forget(&client_key);
    approve(&client_key, "the client");
    let wrong = MachineIdentity::from_secret([99u8; 32]).public_key();
    let address_for_client = address.clone();
    let dialling = std::thread::spawn(move || {
        let identity = MachineIdentity::from_secret([22u8; 32]);
        dial(&address_for_client, &identity, Some(wrong), "laptop")
            .map(|mut c| c.close())
            .expect_err("must refuse a server whose key is not the pinned one")
            .to_string()
    });
    let _ = server.accept();
    let message = dialling.join().expect("thread");
    // The message is the product here. It has to say which of the two
    // explanations to go and check, because "reinstalled" and "somebody is in
    // the middle" look identical from this end.
    assert!(message.contains("laptop"), "{message}");
    assert!(message.contains("reinstalled"), "{message}");
    assert!(message.contains("in its place"), "{message}");

    // ---- 7. Rubbish on the port is a refusal, not a panic or a hang.

    let address_for_junk = address.clone();
    let junk = std::thread::spawn(move || {
        let mut stream = TcpStream::connect(&address_for_junk).expect("connect");
        let _ = stream.write_all(b"GET / HTTP/1.1\r\n\r\n");
        let _ = stream.flush();
    });
    match server.accept().expect("accept") {
        Err(Refused::Handshake(_)) => {}
        other => panic!("expected a handshake refusal, got {other:?}"),
    }
    let _ = junk.join();
}
