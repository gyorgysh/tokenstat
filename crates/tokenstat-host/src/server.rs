//! Unix socket transport for [`crate::dispatch`].
//!
//! # Framing
//!
//! Line-delimited JSON, one request per line, one response per line:
//!
//! ```json
//! {"id": 1, "method": "totals", "params": {}}
//! {"id": 1, "ok": true, "result": {...}}
//! ```
//!
//! `id` is echoed back untouched so a client can have several requests in
//! flight. Everything else is exactly the envelope the in-process path returns,
//! because it is the same function producing it.
//!
//! Newlines rather than a length prefix because `serde_json` never emits a bare
//! newline inside a value, the frames are small, and a human can debug this
//! with `nc`.
//!
//! # Concurrency
//!
//! One thread per connection, all sharing one [`Session`] behind a mutex. The
//! archive is SQLite and a scan holds a write transaction for a long time, so
//! requests serialize whatever this does. A thread per connection keeps a slow
//! `scan` from blocking another client's connect, which is the part that would
//! actually be felt.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::session::Session;

#[derive(Debug, Deserialize)]
struct Request {
    /// Echoed back. Any JSON value, so a client can use whatever it likes.
    #[serde(default)]
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

/// Default socket path, beside the archive it serves.
///
/// In the data directory rather than a temp dir so it survives a reboot's
/// cleanup and so the archive and its socket are found the same way.
pub fn default_socket_path() -> Result<PathBuf, String> {
    let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .ok_or("no data directory on this platform")?;
    Ok(dirs.data_dir().join("host.sock"))
}

/// Bind the socket, replacing a stale one left by a crash.
///
/// A unix socket is a file: a process that died without unlinking leaves one
/// that nothing is listening on, and binding over it fails with "address in
/// use". Refusing to start in that case would mean the daemon never recovers
/// from a kill -9 without manual cleanup, so a socket that accepts no
/// connection is treated as debris.
pub fn bind(path: &Path) -> Result<UnixListener, String> {
    // A unix socket address is a fixed-size struct, so the path has a hard
    // limit of about 104 bytes on macOS and 108 on Linux. The kernel's own
    // error for this says "SUN_LEN", which tells a user nothing.
    const MAX_SOCKET_PATH: usize = 100;
    if path.as_os_str().len() > MAX_SOCKET_PATH {
        return Err(format!(
            "socket path is {} bytes, and a unix socket cannot exceed about {}: {}",
            path.as_os_str().len(),
            MAX_SOCKET_PATH,
            path.display()
        ));
    }

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }

    if path.exists() {
        match UnixStream::connect(path) {
            Ok(_) => {
                return Err(format!(
                    "another host is already listening on {}",
                    path.display()
                ));
            }
            Err(_) => {
                std::fs::remove_file(path)
                    .map_err(|e| format!("could not clear stale socket {}: {e}", path.display()))?;
            }
        }
    }

    let listener = UnixListener::bind(path).map_err(|e| format!("{}: {e}", path.display()))?;

    // The archive holds a user's project names and usage. Nobody else on a
    // shared machine gets to read it through this door.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("could not restrict {}: {e}", path.display()))?;
    }

    Ok(listener)
}

/// Serve until the listener fails. Blocks.
pub fn serve(listener: UnixListener, session: Session) -> Result<(), String> {
    let shared = Arc::new(Mutex::new(session));
    crate::automations::start_scheduler(Arc::clone(&shared));

    // Only if the user turned it on. Binding a port is a decision, not a
    // default: a remote client can spawn processes and write files.
    crate::remote::start_if_enabled(Arc::clone(&shared));

    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                let session = Arc::clone(&shared);
                // A client that hangs up mid-request must not take the daemon
                // with it, so each connection is its own thread and its own
                // failure.
                std::thread::spawn(move || {
                    if let Err(e) = handle(stream, &session) {
                        eprintln!("connection ended: {e}");
                    }
                });
            }
            Err(e) => eprintln!("accept failed: {e}"),
        }
    }
    Ok(())
}

fn handle(stream: UnixStream, session: &Mutex<Session>) -> Result<(), String> {
    let mut out = stream.try_clone().map_err(|e| e.to_string())?;
    let reader = BufReader::new(stream);

    for line in reader.lines() {
        let line = line.map_err(|e| e.to_string())?;
        if line.trim().is_empty() {
            continue;
        }

        let response = respond(&line, session);
        out.write_all(response.as_bytes())
            .and_then(|_| out.write_all(b"\n"))
            .and_then(|_| out.flush())
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Turn one request line into one response line.
///
/// Split out from the socket handling so it can be tested without a socket,
/// and so a future transport reuses the framing rather than the plumbing.
pub fn respond(line: &str, session: &Mutex<Session>) -> String {
    let request: Request = match serde_json::from_str(line) {
        Ok(r) => r,
        Err(e) => {
            // No id to echo: it was in the part that would not parse.
            return json!({
                "id": Value::Null,
                "ok": false,
                "error": {"code": "bad_request", "message": e.to_string()}
            })
            .to_string();
        }
    };

    let params = match &request.params {
        Value::Null => "{}".to_string(),
        other => other.to_string(),
    };

    // Answered without the lock where the method allows it. Connections share
    // one session, so a terminal polling for output would otherwise serialize
    // against every other client's archive and git work.
    let envelope = match crate::dispatch::call_sessionless(&request.method, &params) {
        Some(envelope) => envelope,
        None => {
            // A poisoned lock means some earlier request panicked. The session
            // itself is still a valid open archive, so carry on rather than
            // refusing every request from here on.
            let mut guard = session.lock().unwrap_or_else(PoisonError::into_inner);
            crate::dispatch::call(&mut guard, &request.method, &params)
        }
    };

    // The envelope is already the right shape; the id is the only thing this
    // transport adds. Splicing it in textually rather than re-encoding keeps
    // the two transports byte-identical in the parts they share.
    match serde_json::from_str::<Value>(&envelope) {
        Ok(Value::Object(mut map)) => {
            map.insert("id".into(), request.id);
            Value::Object(map).to_string()
        }
        _ => envelope,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::OpenParams;
    use std::sync::atomic::{AtomicU64, Ordering};

    static SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-server-{tag}-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn session(dir: &Path) -> Session {
        Session::open(&OpenParams {
            db_path: Some(dir.join("tokenstat.db").display().to_string()),
            timezone: Some("UTC".into()),
        })
        .unwrap()
    }

    #[test]
    fn a_request_gets_its_id_back() {
        let dir = temp_dir("id");
        let s = Mutex::new(session(&dir));
        let out = respond(r#"{"id": 7, "method": "info"}"#, &s);
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["id"], 7);
        assert_eq!(v["ok"], true, "{out}");
        assert_eq!(v["result"]["protocolVersion"], crate::PROTOCOL_VERSION);
    }

    #[test]
    fn a_string_id_survives_too() {
        // Clients pick their own id type. JavaScript would send a string.
        let dir = temp_dir("strid");
        let s = Mutex::new(session(&dir));
        let out = respond(r#"{"id": "abc", "method": "info"}"#, &s);
        assert_eq!(serde_json::from_str::<Value>(&out).unwrap()["id"], "abc");
    }

    #[test]
    fn a_malformed_line_is_still_an_envelope() {
        let dir = temp_dir("bad");
        let s = Mutex::new(session(&dir));
        let out = respond("{not json", &s);
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["id"].is_null());
        assert_eq!(v["error"]["code"], "bad_request");
    }

    #[test]
    fn missing_params_are_the_same_as_empty() {
        let dir = temp_dir("noparams");
        let s = Mutex::new(session(&dir));
        let out = respond(r#"{"id": 1, "method": "totals"}"#, &s);
        assert_eq!(
            serde_json::from_str::<Value>(&out).unwrap()["ok"],
            true,
            "{out}"
        );
    }

    #[test]
    fn a_stale_socket_file_is_replaced_rather_than_fatal() {
        // A daemon killed with SIGKILL leaves the socket file behind. Refusing
        // to bind would mean it never restarts without manual cleanup.
        let dir = temp_dir("stale");
        let path = dir.join("host.sock");
        std::fs::write(&path, b"not a socket").unwrap();
        let listener = bind(&path).expect("stale socket should be cleared");
        drop(listener);
    }

    #[test]
    fn an_over_long_path_is_refused_with_a_readable_reason() {
        // The kernel calls this "SUN_LEN", which tells a user nothing. A deep
        // temp or sandbox directory hits it easily.
        let long = std::env::temp_dir().join("x".repeat(120)).join("host.sock");
        let e = bind(&long).expect_err("should refuse");
        assert!(e.contains("unix socket cannot exceed"), "{e}");
    }

    #[test]
    fn a_live_socket_is_not_stolen() {
        let dir = temp_dir("live");
        let path = dir.join("host.sock");
        let first = bind(&path).expect("first bind");
        let second = bind(&path);
        assert!(
            second.is_err(),
            "a second host must not take over the socket"
        );
        drop(first);
    }

    #[test]
    fn a_full_round_trip_over_a_real_socket() {
        let dir = temp_dir("roundtrip");
        let path = dir.join("host.sock");
        let listener = bind(&path).unwrap();
        let s = session(&dir);
        std::thread::spawn(move || {
            let _ = serve(listener, s);
        });

        let stream = UnixStream::connect(&path).expect("connect");
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);

        // Two requests on one connection, to prove the loop keeps going.
        for id in 1..=2 {
            writeln!(writer, r#"{{"id": {id}, "method": "info"}}"#).unwrap();
            writer.flush().unwrap();
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(v["id"], id);
            assert_eq!(v["ok"], true, "{line}");
        }
    }
}
