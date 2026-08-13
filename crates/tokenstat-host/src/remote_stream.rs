// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Byte streams between machines, on top of the remote transport.
//!
//! `remote.call` is one request, one response. A terminal subscription or a
//! localhost proxy is many bytes in each direction with no natural request, so
//! each is a dedicated Noise connection used as a pipe: the local side opens
//! a reservation with `stream.open` over the call channel, dials a fresh
//! connection, and claims it by sending `{"stream": "<token>"}` as its first
//! message. The owning side's accept path sees that handshake and hands the
//! connection to the pump instead of treating it as a request.
//!
//! Everything here runs over the same pinned, end-to-end encrypted session the
//! calls run over, so the tunnel stays a blind pipe for streams exactly as it
//! is for calls. See the streaming design in `docs/remote-streaming.md`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};
use tokenstat_remote::{Connection, StreamWriter};

/// How long a stream reservation waits for its connection before it is given
/// up. A dial that fails after `stream.open` would otherwise leave an entry
/// and a parked thread forever.
const CLAIM_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Debug, Clone)]
pub(crate) enum StreamKind {
    /// Reach a TCP service on the far machine's own loopback.
    Proxy { host: String, port: u16 },
    /// Push a far machine's terminal session output to the local daemon.
    PtySubscribe { session: String },
}

struct PendingStream {
    tx: mpsc::Sender<Connection>,
}

fn registry() -> &'static Mutex<HashMap<String, PendingStream>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, PendingStream>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Reserve a stream and start the pump that will serve it. Returns the token
/// the far side sends on its fresh connection to claim the reservation.
pub(crate) fn open(kind: StreamKind) -> Result<String, String> {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).map_err(|e| e.to_string())?;
    let token = tokenstat_identity::hex(&bytes);
    let (tx, rx) = mpsc::channel::<Connection>();
    registry()
        .lock()
        .map_err(|e| e.to_string())?
        .insert(token.clone(), PendingStream { tx });
    let answer = token.clone();
    std::thread::spawn(move || {
        let connection = match rx.recv_timeout(CLAIM_TIMEOUT) {
            Ok(connection) => connection,
            Err(_) => {
                // Nobody claimed it. Give the reservation back rather than
                // leaking an entry and a parked thread.
                let _ = registry().lock().map(|mut r| r.remove(&token));
                return;
            }
        };
        match kind {
            StreamKind::Proxy { host, port } => pump_proxy(connection, &host, port),
            StreamKind::PtySubscribe { session } => pump_pty_subscribe(connection, &session),
        }
    });
    Ok(answer)
}

/// Claim a reservation. Called from the serve path when a fresh connection's
/// first message is a stream handshake. Returns false when the token is not a
/// live reservation, in which case the caller closes the connection.
pub(crate) fn accept(token: &str, connection: Connection) -> bool {
    let pending = registry().lock().ok().and_then(|mut r| r.remove(token));
    match pending {
        Some(pending) => pending.tx.send(connection).is_ok(),
        None => {
            // Not a live reservation: refuse outright, and make sure the
            // connection is gone either way.
            drop(connection);
            false
        }
    }
}

/// `{"stream": "<token>"}` as a fresh connection's first message.
pub(crate) fn parse_handshake(first: &str) -> Option<String> {
    let value: Value = serde_json::from_str(first.trim()).ok()?;
    let token = value.get("stream")?.as_str()?;
    Some(token.to_string())
}

// MARK: - The pumps

/// Bridge a TCP socket and a stream connection in both directions.
///
/// Two threads, one per direction. EOF on either side is propagated: a closed
/// stream sends an empty message (the clean end-of-stream marker) before
/// closing, and a closed socket shuts the remote TCP end down.
fn pump_tcp_connection(tcp: TcpStream, connection: Connection) {
    let (reader, writer) = connection.split();
    let tcp_reader = match tcp.try_clone() {
        Ok(clone) => clone,
        Err(_) => {
            let _ = tcp.shutdown(std::net::Shutdown::Both);
            return;
        }
    };
    let reader = Arc::new(reader);
    let writer = Arc::new(writer);

    let to_remote = {
        let mut tcp_reader = tcp_reader;
        let writer = Arc::clone(&writer);
        std::thread::spawn(move || {
            let mut buffer = [0u8; 64 * 1024];
            loop {
                match tcp_reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        if writer.write(&buffer[..n]).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let _ = writer.write(&[]);
            writer.close();
        })
    };

    let to_tcp = std::thread::spawn(move || {
        let mut tcp = tcp;
        loop {
            match reader.read(1 << 20) {
                Ok(data) if data.is_empty() => break,
                Ok(data) => {
                    if tcp.write_all(&data).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        reader.close();
        let _ = tcp.shutdown(std::net::Shutdown::Both);
    });

    let _ = to_remote.join();
    let _ = to_tcp.join();
}

/// The owning side of a proxy stream: dial the far machine's own loopback and
/// bridge.
fn pump_proxy(mut connection: Connection, host: &str, port: u16) {
    let tcp = match TcpStream::connect((host, port)) {
        Ok(tcp) => tcp,
        Err(error) => {
            eprintln!("remote stream: proxy to {host}:{port} failed: {error}");
            let message = error.to_string();
            let _ = connection.send(proxy_error_response(&message).as_bytes());
            drop(connection);
            return;
        }
    };
    let _ = tcp.set_nodelay(true);
    pump_tcp_connection(tcp, connection);
}

/// Open a proxy stream on a peer and claim a fresh connection for it.
///
/// The local half of `proxy.listen`: reserve with `stream.open` over the call
/// channel, dial a fresh connection, and claim it with the stream handshake.
pub(crate) fn open_proxy_stream(peer: &str, host: &str, port: u16) -> Result<Connection, String> {
    let params = json!({"kind": "proxy", "host": host, "port": port});
    let result = crate::remote::call_peer_result(peer, "stream.open", &params.to_string())?;
    let token = result
        .get("token")
        .and_then(Value::as_str)
        .ok_or("the peer's stream.open returned no token")?
        .to_string();
    let mut connection = crate::remote::dial_peer(peer)?;
    let handshake = json!({"stream": token});
    connection
        .send(handshake.to_string().as_bytes())
        .map_err(|e| e.to_string())?;
    Ok(connection)
}

/// Bridge a local TCP socket to a claimed stream connection. The local half
/// of `proxy.listen`, mirrored from the owning side's `pump_proxy`.
pub(crate) fn pump_local(tcp: TcpStream, connection: Connection) {
    pump_tcp_connection(tcp, connection);
}

/// Return a readable HTTP response when the tunnel or target service fails.
/// Without this, WKWebView reports every proxy failure as a generic lost
/// connection and hides the reason the user can act on.
pub(crate) fn write_proxy_error(mut tcp: TcpStream, error: &str) {
    let _ = tcp.write_all(proxy_error_response(error).as_bytes());
    let _ = tcp.shutdown(std::net::Shutdown::Both);
}

fn proxy_error_response(error: &str) -> String {
    let body = format!("tokenstat could not reach the service on the host.\n\n{error}\n");
    format!(
        "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

/// One pushed chunk of terminal output. The same shape `pty.read` answers
/// with, so the local daemon can serve its cache with no translation.
#[derive(Debug, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PtyFrame {
    next_offset: u64,
    dropped: u64,
    data: String,
    #[serde(default)]
    paused: bool,
}

/// The owning side of a terminal subscription: read the session's buffer by
/// offset and push every new chunk. The far side's bounded buffer does the
/// memory accounting and its `dropped` counter travels with each frame, so no
/// ack channel is needed in this version; the read half is kept only so the
/// connection's close is observed.
fn pump_pty_subscribe(connection: Connection, session: &str) {
    let (reader, writer) = connection.split();
    // The channel is bidirectional: output flows this way (pushed below),
    // keystrokes flow the other way, straight into the pty. A keystroke is a
    // single frame over the persistent tunnel socket instead of a request and
    // a round trip per key, which is what makes typing feel native.
    let session_id = session.to_string();
    let input = {
        let reader = std::sync::Arc::new(reader);
        let session = session_id.clone();
        std::thread::spawn(move || {
            loop {
                match reader.read(1 << 20) {
                    Ok(data) if data.is_empty() => break,
                    Ok(data) => {
                        let _ = tokenstat_pty::manager().write(&session, &data);
                    }
                    Err(_) => break,
                }
            }
        })
    };
    let mut offset = 0u64;
    let reader_id = format!("remote-stream:{session}");
    loop {
        let alive = tokenstat_pty::manager()
            .info(session)
            .map(|info| info.alive)
            .unwrap_or(false);
        match tokenstat_pty::manager().read_for_stream(session, &reader_id, offset) {
            Ok(chunk) if !chunk.bytes.is_empty() => {
                let frame = PtyFrame {
                    next_offset: chunk.next_offset,
                    dropped: chunk.dropped,
                    data: crate::base64::encode(&chunk.bytes),
                    paused: chunk.paused,
                };
                let Ok(encoded) = serde_json::to_vec(&frame) else {
                    break;
                };
                if writer.write(&encoded).is_err() {
                    break;
                }
                offset = chunk.next_offset;
            }
            Ok(_) if !alive => {
                // The process is gone and the buffer is drained: a clean end.
                let _ = writer.write(&[]);
                break;
            }
            Ok(_) => {}
            Err(error) => {
                eprintln!("remote stream: pty subscribe {session} ended: {error}");
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    tokenstat_pty::manager().forget_reader(session, &reader_id);
    writer.close();
    let _ = input.join();
}

// MARK: - The local side of a terminal subscription

/// How much pushed output a subscription cache keeps. Terminals are small, and
/// anything older is evicted from the front with the lost bytes counted.
const PTY_CACHE_CAP: usize = 8 * 1024 * 1024;

struct PtySubscription {
    buffer: Vec<u8>,
    /// Bytes evicted from the front because the cache hit its cap.
    trimmed: u64,
    active: bool,
    /// The channel's write half: keystrokes ride it to the owning machine.
    writer: Option<StreamWriter>,
    space: Arc<Condvar>,
}

fn pty_subscriptions() -> &'static Mutex<HashMap<String, Arc<Mutex<PtySubscription>>>> {
    static SUBSCRIPTIONS: OnceLock<Mutex<HashMap<String, Arc<Mutex<PtySubscription>>>>> =
        OnceLock::new();
    SUBSCRIPTIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Make sure a remote session is being pushed into a local cache. Called on
/// the first `pty.read` for that session; the pump runs until the stream or
/// the session ends, and later reads are served from the cache locally.
pub(crate) fn ensure_pty_subscription(peer: &str, session: &str) {
    let key = format!("{peer}:{session}");
    {
        let mut map = match pty_subscriptions().lock() {
            Ok(map) => map,
            Err(_) => return,
        };
        if let Some(existing) = map.get(&key) {
            let active = existing.lock().ok().is_some_and(|guard| guard.active);
            if active {
                return;
            }
            map.remove(&key);
        }
    }
    let cache = Arc::new(Mutex::new(PtySubscription {
        buffer: Vec::new(),
        trimmed: 0,
        active: true,
        writer: None,
        space: Arc::new(Condvar::new()),
    }));
    match pty_subscriptions().lock() {
        Ok(mut map) => {
            if map.contains_key(&key) {
                return;
            }
            map.insert(key.clone(), Arc::clone(&cache));
        }
        Err(_) => return,
    }

    let peer = peer.to_string();
    let session = session.to_string();
    std::thread::spawn(move || {
        let forget = |cache: &Arc<Mutex<PtySubscription>>| {
            if let Ok(mut guard) = cache.lock() {
                guard.active = false;
                guard.writer = None;
                guard.buffer.clear();
            }
            if let Ok(mut map) = pty_subscriptions().lock()
                && map.get(&key).is_some_and(|entry| Arc::ptr_eq(entry, cache))
            {
                map.remove(&key);
            }
        };
        let params = json!({"kind": "pty.subscribe", "id": session});
        let result =
            match crate::remote::call_peer_result(&peer, "stream.open", &params.to_string()) {
                Ok(result) => result,
                Err(error) => {
                    eprintln!("remote pty: subscribe to {session} failed: {error}");
                    forget(&cache);
                    return;
                }
            };
        let Some(token) = result.get("token").and_then(Value::as_str) else {
            forget(&cache);
            return;
        };
        let mut connection = match crate::remote::dial_peer(&peer) {
            Ok(connection) => connection,
            Err(error) => {
                eprintln!("remote pty: dial for {session} failed: {error}");
                forget(&cache);
                return;
            }
        };
        let handshake = json!({"stream": token});
        if connection.send(handshake.to_string().as_bytes()).is_err() {
            forget(&cache);
            return;
        }
        let (reader, writer) = connection.split();
        if let Ok(mut guard) = cache.lock() {
            guard.writer = Some(writer);
        }
        loop {
            let mut guard = match cache.lock() {
                Ok(guard) => guard,
                Err(_) => break,
            };
            while guard.buffer.len() >= PTY_CACHE_CAP && guard.active {
                let space = Arc::clone(&guard.space);
                guard = space.wait(guard).unwrap_or_else(PoisonError::into_inner);
            }
            drop(guard);
            match reader.read(1 << 20) {
                Ok(data) if data.is_empty() => break,
                Ok(data) => {
                    let Ok(frame) = serde_json::from_slice::<PtyFrame>(&data) else {
                        continue;
                    };
                    let bytes = crate::base64::decode(&frame.data).unwrap_or_default();
                    let mut guard = match cache.lock() {
                        Ok(guard) => guard,
                        Err(_) => break,
                    };
                    guard.buffer.extend_from_slice(&bytes);
                    // The owning side is blocked while this cache is full, so
                    // output is never evicted to make room.
                }
                Err(_) => break,
            }
        }
        reader.close();
        forget(&cache);
    });
}

/// Serve a `pty.read` from the subscription cache when one is live. Returns
/// None when there is no subscription or it has ended, so the caller falls
/// back to forwarding the read to the peer.
pub(crate) fn cached_pty_read(peer: &str, session: &str, offset: u64) -> Option<Value> {
    let key = format!("{peer}:{session}");
    let cache = pty_subscriptions().lock().ok()?.get(&key)?.clone();
    let mut guard = cache.lock().ok()?;
    if !guard.active {
        return None;
    }
    let acknowledged = offset.saturating_sub(guard.trimmed) as usize;
    if acknowledged > 0 {
        let count = acknowledged.min(guard.buffer.len());
        guard.buffer.drain(..count);
        guard.trimmed += count as u64;
    }
    let (start, take, next_offset, dropped) =
        cache_window(guard.buffer.len(), guard.trimmed, offset);
    guard.space.notify_all();
    Some(json!({
        "data": crate::base64::encode(&guard.buffer[start..start + take]),
        "nextOffset": next_offset,
        "dropped": dropped,
        "paused": guard.buffer.len() >= PTY_CACHE_CAP,
    }))
}

/// Cap one cached read the same way the owning `pty.read` does, so a phone
/// attaching to a full window does not decode 8 MiB of JSON in one go.
const READ_CHUNK_BYTES: usize = 256 * 1024;

fn cache_window(len: usize, trimmed: u64, offset: u64) -> (usize, usize, u64, u64) {
    let len = len as u64;
    let dropped = trimmed.saturating_sub(offset);
    let start = offset.max(trimmed).saturating_sub(trimmed).min(len) as usize;
    let take = (len as usize).saturating_sub(start).min(READ_CHUNK_BYTES);
    let next_offset = trimmed
        .saturating_add(start as u64)
        .saturating_add(take as u64);
    (start, take, next_offset, dropped)
}

/// Send keystrokes to a subscribed remote session over its channel. Returns
/// false when there is no live subscription, so the caller falls back to the
/// forwarded request path.
pub(crate) fn write_pty_input(peer: &str, session: &str, bytes: &[u8]) -> Result<bool, String> {
    let key = format!("{peer}:{session}");
    let cache = pty_subscriptions()
        .lock()
        .map_err(|e| e.to_string())?
        .get(&key)
        .cloned()
        .ok_or_else(|| String::from("no subscription"))?;
    let writer = {
        let guard = cache.lock().map_err(|e| e.to_string())?;
        if !guard.active {
            return Ok(false);
        }
        guard
            .writer
            .clone()
            .ok_or_else(|| String::from("no channel"))?
    };
    writer
        .write(bytes)
        .map(|_| true)
        .map_err(|e| format!("the tunnel channel dropped: {e}"))
}

// MARK: - Remote pty list

/// How long a peer's pty list is reused before the peer is dialled again.
///
/// The app reconciles `pty.list` every few seconds (session parity), and
/// dialling a peer on every one of those calls is what the relay log shows as
/// a new channel every few seconds. Sessions do not appear and vanish that
/// fast, so a short cache absorbs the polling.
const PTY_LIST_TTL: Duration = Duration::from_secs(30);

/// Per-peer cached pty lists: wall-clock fetch time and the sessions.
/// `Instant` does not advance while a Mac sleeps, so an empty list fetched
/// just before the lid closed stayed "fresh" after wake.
type PtyListCache = HashMap<String, (i64, Vec<Value>)>;

static PTY_LISTS: OnceLock<Mutex<PtyListCache>> = OnceLock::new();

/// The pty sessions of every reachable peer, renamespaced, cached per peer.
pub(crate) fn remote_pty_lists() -> Vec<Value> {
    let cache = PTY_LISTS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut out = Vec::new();
    for peer in crate::remote::reachable_peers() {
        let cached = {
            let guard = cache.lock().unwrap_or_else(|e| e.into_inner());
            guard
                .get(&peer)
                .filter(|(at_ms, _)| pty_list_is_fresh(*at_ms))
                .map(|(_, items)| items.clone())
        };
        let items = match cached {
            Some(items) => items,
            None => {
                // Cache hits **and** misses. A peer that is offline used to be
                // redialled on every `pty.list` (the app polls this for session
                // parity), and each dial retries the tunnel with backoff. That
                // turned every local terminal poll cycle into multi-second
                // stalls whenever a machine on the account was asleep.
                let items = match crate::remote::call_peer_result(
                    &peer,
                    "pty.list",
                    r#"{"includeRemote":false}"#,
                ) {
                    Ok(Value::Array(items)) => items,
                    _ => Vec::new(),
                };
                cache
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(peer.clone(), (pty_list_now_ms(), items.clone()));
                items
            }
        };
        for mut item in items {
            crate::dispatch::renamespace_session(&mut item, &peer);
            out.push(item);
        }
    }
    out
}

/// Drop a peer's cached pty list, so a session that just spawned or closed on
/// it is seen immediately instead of after the cache TTL.
fn pty_list_now_ms() -> i64 {
    jiff::Timestamp::now().as_millisecond()
}

fn pty_list_is_fresh(at_ms: i64) -> bool {
    pty_list_now_ms().saturating_sub(at_ms) < PTY_LIST_TTL.as_millis() as i64
}

pub(crate) fn invalidate_pty_list(peer: &str) {
    if let Ok(mut cache) = PTY_LISTS.get_or_init(|| Mutex::new(HashMap::new())).lock() {
        cache.remove(peer);
    }
}

pub(crate) fn invalidate_all_pty_lists() {
    if let Ok(mut cache) = PTY_LISTS.get_or_init(|| Mutex::new(HashMap::new())).lock() {
        cache.clear();
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpStream;

    use tokenstat_identity::MachineIdentity;
    use tokenstat_remote::{handshake_initiator, handshake_responder};

    use super::{
        READ_CHUNK_BYTES, cache_window, parse_handshake, proxy_error_response, pump_local,
        pump_proxy,
    };

    #[test]
    fn remote_cache_offsets_remain_absolute_after_trim() {
        assert_eq!(cache_window(8, 100, 100), (0, 8, 108, 0));
        assert_eq!(cache_window(8, 100, 104), (4, 4, 108, 0));
        assert_eq!(cache_window(8, 100, 90), (0, 8, 108, 10));
        assert_eq!(cache_window(8, 100, 200), (8, 0, 108, 0));
    }

    #[test]
    fn a_cached_read_is_capped_so_attach_does_not_return_the_whole_window() {
        let (start, take, next, dropped) = cache_window(READ_CHUNK_BYTES + 64, 0, 0);
        assert_eq!((start, take, dropped), (0, READ_CHUNK_BYTES, 0));
        assert_eq!(next, READ_CHUNK_BYTES as u64);
    }

    #[test]
    fn a_stream_handshake_names_its_token() {
        assert_eq!(
            parse_handshake(r#"{"stream":"abcd1234"}"#).as_deref(),
            Some("abcd1234")
        );
        assert!(parse_handshake(r#"{"id":0,"method":"info"}"#).is_none());
        assert!(parse_handshake("not json").is_none());
    }

    #[test]
    fn proxy_failures_are_readable_http() {
        let response = proxy_error_response("connection refused");
        assert!(response.starts_with("HTTP/1.1 502 Bad Gateway\r\n"));
        assert!(response.contains("Content-Type: text/plain; charset=utf-8"));
        assert!(response.ends_with("connection refused\n"));
    }

    /// A local port on one machine bridged through a Noise connection to a
    /// service on another machine's loopback, both directions, with EOF
    /// propagated. This is the whole proxy path minus the dispatch layer.
    #[test]
    fn a_proxy_stream_bridges_a_local_port_to_the_peer() {
        let echo = std::net::TcpListener::bind("127.0.0.1:0").expect("an echo listener");
        let echo_port = echo.local_addr().expect("its port").port();
        let echo_thread = std::thread::spawn(move || {
            let (mut sock, _) = echo.accept().expect("an echo client");
            let mut buffer = [0u8; 4096];
            loop {
                match sock.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        if sock.write_all(&buffer[..n]).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a peer listener");
        let address = listener.local_addr().expect("its address");
        let responder_ident = MachineIdentity::from_secret([3u8; 32]);
        let initiator_ident = MachineIdentity::from_secret([4u8; 32]);
        let responder_key = responder_ident.public_key();

        let peer_side = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("a peer connection");
            let connection =
                handshake_responder(Box::new(stream), &responder_ident).expect("handshake");
            pump_proxy(connection, "127.0.0.1", echo_port);
        });

        let stream = TcpStream::connect(address).expect("dial the peer");
        let connection = handshake_initiator(
            Box::new(stream),
            &initiator_ident,
            Some(responder_key),
            "test",
        )
        .expect("handshake");

        let local = std::net::TcpListener::bind("127.0.0.1:0").expect("a local listener");
        let local_port = local.local_addr().expect("its port").port();
        let local_side = std::thread::spawn(move || {
            let (tcp, _) = local.accept().expect("a local client");
            pump_local(tcp, connection);
        });

        let mut client = TcpStream::connect(("127.0.0.1", local_port)).expect("connect locally");
        client.write_all(b"ping").expect("write");
        let mut reply = [0u8; 4];
        client.read_exact(&mut reply).expect("read");
        assert_eq!(
            &reply, b"ping",
            "the service's reply came back through the stream"
        );

        drop(client);
        let _ = local_side.join();
        let _ = peer_side.join();
        let _ = echo_thread.join();
    }
}
