// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run by ../www/scripts/free-remote-e2e.js against its disposable relay.
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};
use tokenstat_identity::MachineIdentity;
use tokenstat_remote::tunnel::{ChannelPurpose, ChannelTransport, TunnelSession};
use tokenstat_remote::{handshake_initiator, handshake_responder};

#[test]
#[ignore = "requires the disposable website relay fixture"]
fn free_devices_exchange_encrypted_messages_through_the_real_relay() {
    let endpoint = std::env::var("TOKENSTAT_FREE_TEST_RELAY").expect("fixture relay");
    let token_a = std::env::var("TOKENSTAT_FREE_TEST_TOKEN_A").expect("fixture token A");
    let token_b = std::env::var("TOKENSTAT_FREE_TEST_TOKEN_B").expect("fixture token B");
    let a = MachineIdentity::from_secret([31; 32]);
    let b = MachineIdentity::from_secret([32; 32]);
    let key_b = b.public_key();
    let session_a = TunnelSession::spawn(&endpoint, &a, &token_a);
    let session_b = TunnelSession::spawn(&endpoint, &b, &token_b);
    let inbound = session_b.take_inbound().expect("inbound receiver");
    let responder = Arc::clone(&session_b);
    let (tx, rx) = mpsc::channel();
    let thread = std::thread::spawn(move || {
        let state = inbound
            .recv_timeout(Duration::from_secs(10))
            .expect("inbound channel");
        let transport = ChannelTransport::from_inbound(responder, state);
        let mut connection =
            handshake_responder(Box::new(transport), &b).expect("responder handshake");
        let request = connection.receive(1 << 20).expect("request");
        connection.send(b"pong").expect("reply");
        tx.send(request).expect("report request");
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while !(session_a.status().connected && session_b.status().connected) {
        assert!(Instant::now() < deadline, "both devices must register");
        std::thread::sleep(Duration::from_millis(10));
    }
    let channel = session_a
        .open_channel(key_b, ChannelPurpose::Chat)
        .expect("chat channel");
    let mut connection = handshake_initiator(Box::new(channel), &a, Some(key_b), "fixture host")
        .expect("initiator handshake");
    connection.send(b"ping").expect("send");
    assert_eq!(connection.receive(1 << 20).expect("reply"), b"pong");
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).expect("request"),
        b"ping"
    );
    thread.join().expect("responder");
    session_a.shutdown();
    session_b.shutdown();
}
