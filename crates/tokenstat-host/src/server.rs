//! Local socket transport for [`crate::dispatch`].
//!
//! Unix: a filesystem socket. Windows: a named pipe. Framing is the same.
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

#[cfg(unix)]
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
#[cfg(unix)]
use std::path::Path;
use std::path::PathBuf;
#[cfg(unix)]
use std::sync::Arc;
#[cfg(unix)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::session::Session;

/// Inbound request line budget. Editor saves can be multi-megabyte JSON.
/// Matches the remote message scale without allowing multi-GB DoS lines.
const MAX_REQUEST_LINE: usize = 32 * 1024 * 1024;
/// Concurrent local clients. The Mac app caps itself at 16; leave headroom.
const MAX_CONNECTIONS: usize = 64;

#[cfg(windows)]
#[path = "pipe_server.rs"]
mod pipe_server;
#[cfg(windows)]
pub use pipe_server::{bind, connect, serve};

#[cfg(unix)]
fn live_connections() -> &'static AtomicUsize {
    static LIVE: AtomicUsize = AtomicUsize::new(0);
    &LIVE
}

#[derive(Debug, Deserialize)]
struct Request {
    /// Echoed back. Any JSON value, so a client can use whatever it likes.
    #[serde(default)]
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

/// Windows named pipes live in a global namespace. The last component is the
/// user, so two sessions on one machine do not share a listener. Anything that
/// is not a safe pipe character becomes `_`.
///
/// Compiled on every OS so the unit tests can cover it without a Windows
/// runner. Production unix builds never call it.
#[cfg_attr(not(any(windows, test)), allow(dead_code))]
pub(crate) fn sanitize_pipe_component(raw: &str) -> String {
    let mut safe = String::with_capacity(raw.len());
    for c in raw.chars() {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
            safe.push(c);
        } else {
            safe.push('_');
        }
    }
    if safe.is_empty() {
        safe.push_str("user");
    }
    safe
}

/// Default local endpoint, beside the archive it serves.
///
/// Unix: a socket file in the data directory. Windows: a named pipe in the
/// global pipe namespace, scoped to the current user so two sessions on one
/// machine do not share a listener.
pub fn default_socket_path() -> Result<PathBuf, String> {
    #[cfg(windows)]
    {
        return Ok(PathBuf::from(pipe_server::default_pipe_name()));
    }
    #[cfg(not(windows))]
    Ok(tokenstat_paths::data_dir()
        .ok_or("no data directory on this platform")?
        .join("host.sock"))
}

/// Bind the socket, replacing a stale one left by a crash.
///
/// A unix socket is a file: a process that died without unlinking leaves one
/// that nothing is listening on, and binding over it fails with "address in
/// use". Refusing to start in that case would mean the daemon never recovers
/// from a kill -9 without manual cleanup, so a socket that accepts no
/// connection is treated as debris.
#[cfg(unix)]
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
#[cfg(unix)]
pub fn serve(listener: UnixListener, session: Session) -> Result<(), String> {
    let shared = Arc::new(Mutex::new(session));
    #[cfg(feature = "local-host")]
    {
        // Before anybody asks for a terminal. Resolving the login shell's PATH
        // costs a full startup file read, and paying it inside the first spawn
        // means paying it while a person waits for a window to fill.
        tokenstat_pty::warm_login_env();
        // Same head start for the shell pool: a started shell waits at a prompt
        // so the first Shell click hands it over instead of starting one.
        tokenstat_pty::warm_shell_pool();
        crate::automations::start_scheduler();
        crate::workflows::start_scheduler();
        crate::sync_scheduler::start(Arc::clone(&shared));
    }

    // Policy first: if hosting is off, the pause flag is set before the
    // tunnel thread can start, so a closed-lid or no-app start cannot
    // accept a remote shell for a beat and then drop it.
    crate::host_policy::start_runtime();
    // Only if the user turned it on. Binding a port is a decision, not a
    // default: a remote client can spawn processes and write files.
    crate::remote::start_if_enabled(Arc::clone(&shared));

    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                let live = live_connections();
                let prev = live.fetch_add(1, Ordering::AcqRel);
                if prev >= MAX_CONNECTIONS {
                    live.fetch_sub(1, Ordering::AcqRel);
                    // Refuse without a thread. Same-UID flood must not grow
                    // forever. Say so first: a socket that accepts and then
                    // closes without a word is indistinguishable from a daemon
                    // that died, and the app answers that by reinstalling the
                    // launch agent and restarting the daemon, which kills every
                    // terminal it owns. Losing somebody's running agents to a
                    // busy minute is not a trade worth making, so this refusal
                    // is a real envelope the caller can read and retry.
                    let _ = refuse_busy(&stream);
                    drop(stream);
                    continue;
                }
                let session = Arc::clone(&shared);
                // A client that hangs up mid-request must not take the daemon
                // with it, so each connection is its own thread and its own
                // failure.
                std::thread::spawn(move || {
                    let _guard = ConnectionGuard;
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

/// Tell a client the daemon is full, in the shape every other answer takes.
///
/// Best effort by design: the point is that the caller hears something, and a
/// client that has already gone away needs nothing.
#[cfg(unix)]
fn refuse_busy(stream: &UnixStream) -> std::io::Result<()> {
    let mut out = stream.try_clone()?;
    let response = json!({
        "id": Value::Null,
        "ok": false,
        "error": {
            "code": "host_busy",
            "message": format!(
                "the tokenstat host is already serving {MAX_CONNECTIONS} connections"
            )
        }
    })
    .to_string();
    out.write_all(response.as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()
}

#[cfg(unix)]
struct ConnectionGuard;

#[cfg(unix)]
impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        live_connections().fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(unix)]
fn handle(stream: UnixStream, session: &Mutex<Session>) -> Result<(), String> {
    let mut out = stream.try_clone().map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream);
    let mut buf = Vec::new();

    loop {
        buf.clear();
        // Cap each frame so a same-UID client cannot force multi-GB allocations.
        let n = reader
            .by_ref()
            .take(MAX_REQUEST_LINE as u64 + 1)
            .read_until(b'\n', &mut buf)
            .map_err(|e| e.to_string())?;
        if n == 0 {
            return Ok(());
        }
        // Cap hit mid-line when we filled MAX+1 without a newline, or the
        // frame itself is larger than the budget.
        let oversize = buf.len() > MAX_REQUEST_LINE || !buf.ends_with(b"\n");
        if oversize {
            if !buf.ends_with(b"\n") {
                let mut drain = Vec::new();
                let _ = reader.read_until(b'\n', &mut drain);
            }
            let response = json!({
                "id": Value::Null,
                "ok": false,
                "error": {
                    "code": "bad_request",
                    "message": format!("request exceeds {MAX_REQUEST_LINE} bytes")
                }
            })
            .to_string();
            out.write_all(response.as_bytes())
                .and_then(|_| out.write_all(b"\n"))
                .and_then(|_| out.flush())
                .map_err(|e| e.to_string())?;
            continue;
        }
        if buf.ends_with(b"\n") {
            buf.pop();
            if buf.ends_with(b"\r") {
                buf.pop();
            }
        }
        if buf.is_empty() {
            continue;
        }
        let line = match std::str::from_utf8(&buf) {
            Ok(s) => s,
            Err(_) => {
                let response = json!({
                    "id": Value::Null,
                    "ok": false,
                    "error": {"code": "bad_request", "message": "request is not valid UTF-8"}
                })
                .to_string();
                out.write_all(response.as_bytes())
                    .and_then(|_| out.write_all(b"\n"))
                    .and_then(|_| out.flush())
                    .map_err(|e| e.to_string())?;
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let response = respond(line, session);
        out.write_all(response.as_bytes())
            .and_then(|_| out.write_all(b"\n"))
            .and_then(|_| out.flush())
            .map_err(|e| e.to_string())?;
    }
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
    let envelope = if request.method == "scan" {
        // Parse can take minutes on a large archive. Open a dedicated Engine so
        // Home/Insights keep answering on the live session while this runs.
        // WAL + busy timeout allow the concurrent readers.
        let opened = {
            let guard = session.lock().unwrap_or_else(PoisonError::into_inner);
            guard.engine().ok().map(|engine| {
                (
                    engine.db_path().to_path_buf(),
                    engine.timezone().iana_name().map(str::to_string),
                )
            })
        };
        // No archive to scan. Hand it to the ordinary dispatch, which refuses
        // in the one place that refusal is worded, and still gets its id.
        let Some((db_path, tz_name)) = opened else {
            let mut guard = session.lock().unwrap_or_else(PoisonError::into_inner);
            let envelope = crate::dispatch::call(&mut guard, &request.method, &params);
            drop(guard);
            return with_id(envelope, request.id);
        };
        match tokenstat_core::Engine::open(Some(&db_path), tz_name.as_deref()) {
            Ok(mut engine) => match engine.scan() {
                Ok(r) => {
                    let dto = crate::dto::ScanReportDto::from(r);
                    match serde_json::to_value(dto) {
                        Ok(v) => json!({"ok": true, "result": v}).to_string(),
                        Err(e) => json!({
                            "ok": false,
                            "error": {"code": "call_failed", "message": e.to_string()}
                        })
                        .to_string(),
                    }
                }
                Err(e) => json!({
                    "ok": false,
                    "error": {"code": "call_failed", "message": e.to_string()}
                })
                .to_string(),
            },
            Err(e) => json!({
                "ok": false,
                "error": {"code": "call_failed", "message": e.to_string()}
            })
            .to_string(),
        }
    } else {
        match crate::dispatch::call_sessionless(&request.method, &params) {
            Some(envelope) => envelope,
            None => {
                // A poisoned lock means some earlier request panicked. The session
                // itself is still a valid open archive, so carry on rather than
                // refusing every request from here on.
                let mut guard = session.lock().unwrap_or_else(PoisonError::into_inner);
                crate::dispatch::call(&mut guard, &request.method, &params)
            }
        }
    };

    with_id(envelope, request.id)
}

/// Stamp a dispatch envelope with the request id this transport is tracking.
///
/// The envelope is already the right shape, and the id is the only thing this
/// transport adds. Splicing it in rather than re-encoding keeps the two
/// transports byte-identical in the parts they share.
fn with_id(envelope: String, id: Value) -> String {
    match serde_json::from_str::<Value>(&envelope) {
        Ok(Value::Object(mut map)) => {
            map.insert("id".into(), id);
            Value::Object(map).to_string()
        }
        _ => envelope,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::OpenParams;
    use std::path::Path;
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
    fn pipe_component_strips_separators() {
        assert_eq!(sanitize_pipe_component("Ada Lovelace"), "Ada_Lovelace");
        assert_eq!(sanitize_pipe_component(""), "user");
        assert_eq!(sanitize_pipe_component("ok.user-1"), "ok.user-1");
        assert_eq!(sanitize_pipe_component(r"evil\..\pipe"), "evil_.._pipe");
    }

    #[test]
    fn the_default_endpoint_is_local() {
        let path = default_socket_path().expect("a data directory");
        let s = path.to_string_lossy();
        #[cfg(windows)]
        {
            let lower = s.to_ascii_lowercase();
            assert!(lower.starts_with(r"\\.\pipe\ai.tokenstat.hostd."), "{s}");
        }
        #[cfg(not(windows))]
        assert!(s.ends_with("host.sock"), "{s}");
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

    #[cfg(unix)]
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

    #[cfg(unix)]
    #[test]
    fn an_over_long_path_is_refused_with_a_readable_reason() {
        // The kernel calls this "SUN_LEN", which tells a user nothing. A deep
        // temp or sandbox directory hits it easily.
        let long = std::env::temp_dir().join("x".repeat(120)).join("host.sock");
        let e = bind(&long).expect_err("should refuse");
        assert!(e.contains("unix socket cannot exceed"), "{e}");
    }

    #[cfg(unix)]
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

    #[cfg(unix)]
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
