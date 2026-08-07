// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The multiplexed tunnel path, end to end, against a minimal in-test relay.
//!
//! This is the wire contract the real `tunnel/server.js` implements: HELLO →
//! READY, then channel frames. Two sessions pair over it, run the Noise
//! handshake over a channel, and exchange a message. If this passes, the
//! transport works and a "no folders" report is an app-side or approval issue,
//! not the tunnel.

use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use tokenstat_identity::MachineIdentity;
use tokenstat_remote::tunnel::{ChannelTransport, TunnelSession};
use tokenstat_remote::{handshake_initiator, handshake_responder};
use tungstenite::{Message, accept};

const CH_OPEN: u8 = 1;
const CH_OPENED: u8 = 2;
const CH_CLOSE: u8 = 4;

fn frame(op: u8, ch: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(op);
    out.extend_from_slice(&ch.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// A two-socket relay: registers both keys, pairs channels between them, and
/// forwards bytes. Exactly the routing the real relay does, minus auth. One
/// thread polls both sockets and routes whichever is readable, so an idle
/// socket can never stall the other.
fn relay() -> (u16, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("address").port();
    let handle = std::thread::spawn(move || {
        let (a_stream, _) = listener.accept().expect("first socket");
        let (b_stream, _) = listener.accept().expect("second socket");
        let mut a = accept(a_stream).expect("websocket a");
        let mut b = accept(b_stream).expect("websocket b");
        assert!(
            read_hello(&mut a).starts_with("HELLO"),
            "first socket registers"
        );
        assert!(
            read_hello(&mut b).starts_with("HELLO"),
            "second socket registers"
        );
        a.send(Message::Text("READY".into())).expect("ready a");
        b.send(Message::Text("READY".into())).expect("ready b");
        let routing = Arc::new(Mutex::new(Routing::default()));
        let a = Arc::new(Mutex::new(a));
        let b = Arc::new(Mutex::new(b));
        let pump_a = {
            let a = Arc::clone(&a);
            let b = Arc::clone(&b);
            let routing = Arc::clone(&routing);
            std::thread::spawn(move || pump(&a, &b, &routing, true))
        };
        let pump_b = {
            let a = Arc::clone(&a);
            let b = Arc::clone(&b);
            let routing = Arc::clone(&routing);
            std::thread::spawn(move || pump(&b, &a, &routing, false))
        };
        let _ = pump_a.join();
        let _ = pump_b.join();
    });
    (port, handle)
}

#[derive(Default)]
struct Routing {
    /// A's local channel id -> B's local channel id.
    to_b: std::collections::HashMap<u32, u32>,
    /// B's local channel id -> A's local channel id.
    to_a: std::collections::HashMap<u32, u32>,
    next: u32,
}

/// Pump one socket: blocking reads with a 10ms timeout (so the mutex is never
/// held long), routing frames to the other socket.
fn route(
    from: &Mutex<tungstenite::WebSocket<TcpStream>>,
    to: &Mutex<tungstenite::WebSocket<TcpStream>>,
    routing: &Mutex<Routing>,
    is_a: bool,
) -> bool {
    let raw = {
        let Ok(mut socket) = from.lock() else {
            return false;
        };
        match socket.read() {
            Ok(Message::Binary(bytes)) => Some(bytes.to_vec()),
            Ok(Message::Close(_)) => None,
            Ok(_) => return true,
            Err(tungstenite::Error::Io(error))
                if error.kind() == std::io::ErrorKind::TimedOut
                    || error.kind() == std::io::ErrorKind::WouldBlock =>
            {
                None
            }
            Err(_) => None,
        }
    };
    let Some(raw) = raw else { return true };
    let op = raw[0];
    let ch = u32::from_be_bytes([raw[1], raw[2], raw[3], raw[4]]);
    let payload = raw[5..].to_vec();
    if op == CH_OPEN && is_a {
        let mut r = routing.lock().expect("routing");
        r.next += 1;
        let target = r.next;
        r.to_b.insert(ch, target);
        r.to_a.insert(target, ch);
        let mut f = from.lock().expect("from");
        f.send(Message::Binary(frame(CH_OPENED, ch, &[]).into()))
            .expect("opened to opener");
        let mut t = to.lock().expect("to");
        t.send(Message::Binary(frame(CH_OPENED, target, &[]).into()))
            .expect("opened to target");
        return true;
    }
    let peer_ch = {
        let r = routing.lock().expect("routing");
        if is_a {
            r.to_b.get(&ch).copied()
        } else {
            r.to_a.get(&ch).copied()
        }
    };
    let Some(peer_ch) = peer_ch else { return true };
    let mut t = to.lock().expect("to");
    t.send(Message::Binary(frame(op, peer_ch, &payload).into()))
        .expect("forward");
    if op == CH_CLOSE {
        let mut r = routing.lock().expect("routing");
        if is_a {
            r.to_b.remove(&ch);
            r.to_a.remove(&peer_ch);
        } else {
            r.to_a.remove(&ch);
            r.to_b.remove(&peer_ch);
        }
    }
    true
}

fn pump(
    from: &Mutex<tungstenite::WebSocket<TcpStream>>,
    to: &Mutex<tungstenite::WebSocket<TcpStream>>,
    routing: &Mutex<Routing>,
    is_a: bool,
) {
    if let Ok(mut socket) = from.lock() {
        let _ = socket
            .get_mut()
            .set_read_timeout(Some(std::time::Duration::from_millis(10)));
    }
    loop {
        if !route(from, to, routing, is_a) {
            break;
        }
    }
}

fn read_hello(socket: &mut tungstenite::WebSocket<TcpStream>) -> String {
    match socket.read().expect("read") {
        Message::Text(text) => text.to_string(),
        other => panic!("expected HELLO, got {other:?}"),
    }
}

#[test]
fn two_machines_pair_and_call_over_one_multiplexed_tunnel() {
    let (port, _relay) = relay();
    let endpoint = format!("ws://127.0.0.1:{port}");
    let ident_a = MachineIdentity::from_secret([31u8; 32]);
    let ident_b = MachineIdentity::from_secret([32u8; 32]);
    let key_b = ident_b.public_key();

    let session_a = TunnelSession::spawn(&endpoint, &ident_a, "token");
    let session_b = TunnelSession::spawn(&endpoint, &ident_b, "token");

    // B answers inbound channels: handshake, echo one message.
    let (tx, rx) = mpsc::channel();
    let inbound = session_b.take_inbound();
    let responder = std::sync::Arc::clone(&session_b);
    std::thread::spawn(move || {
        let state = inbound.recv().expect("an inbound channel");
        let transport = ChannelTransport::from_inbound(responder, state);
        let mut connection = handshake_responder(Box::new(transport), &ident_b).expect("handshake");
        let request = connection.receive(1 << 20).expect("receive");
        connection.send(b"pong").expect("reply");
        let _ = tx.send(request);
    });

    // A waits for the session to come up, then dials B.
    for _ in 0..200 {
        if session_a.status().connected {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(session_a.status().connected, "session A must reach READY");

    let channel = session_a.open_channel(key_b).expect("open a channel");
    let mut connection = handshake_initiator(Box::new(channel), &ident_a, Some(key_b), "machine b")
        .expect("handshake over the channel");
    connection.send(b"ping").expect("send");
    let reply = connection.receive(1 << 20).expect("receive");
    assert_eq!(reply, b"pong");
    assert_eq!(rx.recv().expect("the request"), b"ping");

    session_a.shutdown();
    session_b.shutdown();
}
