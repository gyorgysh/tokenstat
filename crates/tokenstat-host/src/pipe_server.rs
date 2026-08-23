// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Named-pipe transport for [`crate::dispatch`] on Windows.
//!
//! Same framing as the unix socket: one JSON request line, one JSON response
//! line, ids echoed back. A named pipe is the local door on Windows the way a
//! unix socket is on macOS. Remote clients are rejected at create time.

#![cfg(windows)]

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::windows::io::{FromRawHandle, IntoRawHandle, OwnedHandle};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};

use super::{MAX_CONNECTIONS, MAX_REQUEST_LINE, respond, sanitize_pipe_component};
use crate::session::Session;
use crate::win32::{
    self, FILE_FLAG_FIRST_PIPE_INSTANCE, GENERIC_READ, GENERIC_WRITE, OPEN_EXISTING,
    PIPE_ACCESS_DUPLEX, PIPE_REJECT_REMOTE_CLIENTS,
};

const PIPE_BUFFER: u32 = 64 * 1024;

fn live_connections() -> &'static AtomicUsize {
    static LIVE: AtomicUsize = AtomicUsize::new(0);
    &LIVE
}

/// Default local pipe, scoped to the Windows user so two sessions on one
/// machine do not collide in the global pipe namespace.
pub fn default_pipe_name() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
    format!(
        r"\\.\pipe\ai.tokenstat.hostd.{}",
        sanitize_pipe_component(&user)
    )
}

/// First pipe instance. Further clients get a new instance inside [`serve`].
pub struct PipeListener {
    name: PathBuf,
    first: OwnedHandle,
}

/// Bind the default (or given) pipe. Fails if another host already owns it.
///
/// `SECURITY_ATTRIBUTES` is left null, so the creating token's default DACL
/// applies: this user, SYSTEM, and Administrators. Combined with
/// `PIPE_REJECT_REMOTE_CLIENTS`, that is the named-pipe equivalent of the
/// unix socket's `0o600`.
pub fn bind(path: &Path) -> Result<PipeListener, String> {
    let name = path
        .to_str()
        .ok_or_else(|| format!("pipe name is not valid unicode: {}", path.display()))?
        .to_string();
    if name.len() > 250 {
        return Err(format!(
            "pipe name is {} bytes, and a Windows named pipe cannot exceed about 256: {name}",
            name.len()
        ));
    }
    let handle = create_instance(&name, true)?;
    Ok(PipeListener {
        name: path.to_path_buf(),
        first: handle,
    })
}

fn create_instance(name: &str, first: bool) -> Result<OwnedHandle, String> {
    let wide = win32::wide(name);
    let mut open_mode = PIPE_ACCESS_DUPLEX;
    if first {
        open_mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
    }
    let handle = unsafe {
        win32::CreateNamedPipeW(
            wide.as_ptr(),
            open_mode,
            // Byte mode and blocking wait are the zero defaults.
            PIPE_REJECT_REMOTE_CLIENTS,
            MAX_CONNECTIONS as u32,
            PIPE_BUFFER,
            PIPE_BUFFER,
            0,
            std::ptr::null_mut(),
        )
    };
    unsafe { win32::handle_to_owned(handle) }.ok_or_else(|| {
        let err = win32::last_error();
        if first {
            format!("another host is already listening on {name} (win32 {err})")
        } else {
            format!("could not create a pipe instance on {name} (win32 {err})")
        }
    })
}

fn wait_for_client(handle: &OwnedHandle) -> Result<(), String> {
    use std::os::windows::io::AsRawHandle;
    let ok = unsafe { win32::ConnectNamedPipe(handle.as_raw_handle(), std::ptr::null_mut()) };
    if ok != 0 {
        return Ok(());
    }
    let err = win32::last_error();
    if err == win32::ERROR_PIPE_CONNECTED {
        Ok(())
    } else {
        Err(format!("ConnectNamedPipe failed (win32 {err})"))
    }
}

/// Serve until creating a new instance fails. Blocks.
pub fn serve(listener: PipeListener, session: Session) -> Result<(), String> {
    let shared = Arc::new(Mutex::new(session));
    #[cfg(feature = "local-host")]
    {
        tokenstat_pty::warm_login_env();
        tokenstat_pty::warm_shell_pool();
        crate::automations::start_scheduler();
        crate::workflows::start_scheduler();
        crate::sync_scheduler::start(Arc::clone(&shared));
    }

    crate::host_policy::start_runtime();
    crate::remote::start_if_enabled(Arc::clone(&shared));

    let pipe_name = listener
        .name
        .to_str()
        .ok_or("pipe name is not valid unicode")?
        .to_string();
    let mut incoming = listener.first;

    loop {
        if let Err(e) = wait_for_client(&incoming) {
            eprintln!("accept failed: {e}");
            incoming = match create_instance(&pipe_name, false) {
                Ok(h) => h,
                Err(e) => {
                    eprintln!("pipe instance: {e}");
                    continue;
                }
            };
            continue;
        }

        let live = live_connections();
        let prev = live.fetch_add(1, Ordering::AcqRel);
        if prev >= MAX_CONNECTIONS {
            live.fetch_sub(1, Ordering::AcqRel);
            let _ = refuse_busy(&incoming);
            drop(incoming);
            incoming = match create_instance(&pipe_name, false) {
                Ok(h) => h,
                Err(e) => return Err(e),
            };
            continue;
        }

        let connected = incoming;
        incoming = match create_instance(&pipe_name, false) {
            Ok(h) => h,
            Err(e) => {
                live.fetch_sub(1, Ordering::AcqRel);
                let _ = refuse_busy(&connected);
                return Err(e);
            }
        };

        let session = Arc::clone(&shared);
        std::thread::spawn(move || {
            let _guard = ConnectionGuard;
            if let Err(e) = handle(connected, &session) {
                eprintln!("connection ended: {e}");
            }
        });
    }
}

struct ConnectionGuard;

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        live_connections().fetch_sub(1, Ordering::AcqRel);
    }
}

fn file_from_handle(handle: OwnedHandle) -> File {
    unsafe { File::from_raw_handle(handle.into_raw_handle()) }
}

fn refuse_busy(handle: &OwnedHandle) -> std::io::Result<()> {
    use std::mem::ManuallyDrop;
    use std::os::windows::io::{AsRawHandle, FromRawHandle};
    // Wrap without taking ownership, duplicate, then drop only the duplicate
    // so CloseHandle stays with `handle`.
    let view = ManuallyDrop::new(unsafe { File::from_raw_handle(handle.as_raw_handle()) });
    let mut out = view.try_clone()?;
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

fn handle(owned: OwnedHandle, session: &Mutex<Session>) -> Result<(), String> {
    let file = file_from_handle(owned);
    let mut out = file.try_clone().map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(file);
    let mut buf = Vec::new();

    loop {
        buf.clear();
        let n = reader
            .by_ref()
            .take(MAX_REQUEST_LINE as u64 + 1)
            .read_until(b'\n', &mut buf)
            .map_err(|e| e.to_string())?;
        if n == 0 {
            return Ok(());
        }
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

/// Connect to a local host pipe as a client. Used by ownership probes.
pub fn connect(path: &Path, timeout_ms: u32) -> Result<File, String> {
    let name = path
        .to_str()
        .ok_or_else(|| format!("pipe name is not valid unicode: {}", path.display()))?;
    let wide = win32::wide(name);
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms as u64);
    loop {
        let handle = unsafe {
            win32::CreateFileW(
                wide.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                std::ptr::null_mut(),
                OPEN_EXISTING,
                0,
                std::ptr::null_mut(),
            )
        };
        if let Some(owned) = unsafe { win32::handle_to_owned(handle) } {
            return Ok(file_from_handle(owned));
        }
        let err = win32::last_error();
        if err != win32::ERROR_PIPE_BUSY {
            return Err(format!("could not connect to {name} (win32 {err})"));
        }
        if std::time::Instant::now() >= deadline {
            return Err(format!("timed out connecting to {name}"));
        }
        let remain = deadline
            .saturating_duration_since(std::time::Instant::now())
            .as_millis()
            .min(u128::from(u32::MAX)) as u32;
        let waited = unsafe { win32::WaitNamedPipeW(wide.as_ptr(), remain.max(1)) };
        if waited == 0 {
            return Err(format!("timed out connecting to {name}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{OpenParams, Session};
    use std::sync::atomic::{AtomicU64, Ordering};

    static SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_session() -> (std::path::PathBuf, Session) {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-pipe-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let session = Session::open(&OpenParams {
            db_path: Some(dir.join("tokenstat.db").display().to_string()),
            timezone: Some("UTC".into()),
        })
        .unwrap();
        (dir, session)
    }

    fn unique_pipe() -> PathBuf {
        PathBuf::from(format!(
            r"\\.\pipe\tokenstat-test-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn an_over_long_name_is_refused_with_a_readable_reason() {
        let long = PathBuf::from(format!(r"\\.\pipe\{}", "x".repeat(260)));
        let e = bind(&long).expect_err("should refuse");
        assert!(e.contains("named pipe cannot exceed"), "{e}");
    }

    #[test]
    fn a_full_round_trip_over_a_real_pipe() {
        let (_dir, session) = temp_session();
        let path = unique_pipe();
        let listener = bind(&path).expect("bind");
        std::thread::spawn(move || {
            let _ = serve(listener, session);
        });

        let mut stream = None;
        for _ in 0..50 {
            match connect(&path, 200) {
                Ok(f) => {
                    stream = Some(f);
                    break;
                }
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(20)),
            }
        }
        let stream = stream.expect("connect");
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);
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

    #[test]
    fn a_live_pipe_is_not_stolen() {
        let path = unique_pipe();
        let first = bind(&path).expect("first bind");
        let second = bind(&path);
        assert!(second.is_err(), "a second host must not take over the pipe");
        drop(first);
    }
}
