// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Local loopback → peer localhost proxy for client builds (phones).
//!
//! The full stream machinery in `remote_stream` owns pty subscriptions and is
//! gated on `local-host`. Phones still need to open a browser tab against a
//! service on a Mac's loopback, which is exactly this half: bind here, dial a
//! proxy stream on the peer, pump bytes.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{Value, json};
use tokenstat_remote::Connection;

const MAX_PROXY_LISTENERS: usize = 16;

fn listeners() -> &'static Mutex<HashMap<String, Arc<AtomicBool>>> {
    static LISTENERS: OnceLock<Mutex<HashMap<String, Arc<AtomicBool>>>> = OnceLock::new();
    LISTENERS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Bind a loopback port and bridge every accepted connection to a proxy stream
/// on `peer`. Returns an `http://127.0.0.1:<port>/` URL for the browser.
pub(crate) fn listen(peer: &str, host: &str, target: u16) -> Result<Value, String> {
    let host = if host.is_empty() {
        "127.0.0.1".to_string()
    } else {
        host.to_string()
    };
    if !matches!(host.as_str(), "127.0.0.1" | "localhost" | "::1" | "[::1]") {
        return Err("proxy target must be on the far machine's own loopback".into());
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("could not bind a loopback port: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let peer = peer.to_string();

    let key = format!("{peer}:{host}:{target}");
    let mut registry = listeners().lock().map_err(|e| e.to_string())?;
    if let Some(stop) = registry.remove(&key) {
        stop.store(true, Ordering::Relaxed);
    }
    if registry.len() >= MAX_PROXY_LISTENERS {
        return Err(format!(
            "too many local port bridges (max {MAX_PROXY_LISTENERS}); close some browser tabs"
        ));
    }
    let stop = Arc::new(AtomicBool::new(false));
    registry.insert(key.clone(), Arc::clone(&stop));
    drop(registry);

    let _ = listener.set_nonblocking(true);
    std::thread::spawn(move || {
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            match listener.accept() {
                Ok((tcp, _)) => {
                    let _ = tcp.set_nodelay(true);
                    match open_proxy_stream(&peer, &host, target) {
                        Ok(connection) => pump_tcp(tcp, connection),
                        Err(error) => {
                            eprintln!("remote proxy: {peer} {host}:{target} failed: {error}");
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(_) => break,
            }
        }
        if let Ok(mut registry) = listeners().lock() {
            registry.remove(&key);
        }
    });
    // Prefer localhost over 127.0.0.1: WKWebView / ATS treat local names more
    // kindly, and iOS App Transport "local networking" covers both.
    Ok(json!({"url": format!("http://localhost:{port}/")}))
}

fn open_proxy_stream(peer: &str, host: &str, port: u16) -> Result<Connection, String> {
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

fn pump_tcp(tcp: TcpStream, connection: Connection) {
    let (reader, writer) = connection.split();
    let tcp_reader = tcp.try_clone().expect("cloning a socket for the pump");
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
