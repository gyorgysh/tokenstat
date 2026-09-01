//! The process-wide session behind the C ABI.
//!
//! The only thing this module adds to [`tokenstat_host::dispatch`] is somewhere
//! to keep the session between calls. A C caller has no handle to pass back in,
//! so the session lives in a static rather than on the stack of whoever called.

use std::sync::{Mutex, OnceLock, PoisonError};

use tokenstat_host::{Session, dispatch};

static SESSION: OnceLock<Mutex<Option<Session>>> = OnceLock::new();

fn cell() -> &'static Mutex<Option<Session>> {
    SESSION.get_or_init(|| Mutex::new(None))
}

/// Work worth doing before anybody asks for it, started on first call.
///
/// Only the login shell's PATH so far. The daemon warms it in `serve`, and the
/// in-process bridge needs the same head start: an app running without an
/// installed host agent would otherwise pay a full shell startup inside its
/// first `pty.spawn`, with a person watching an empty pane.
///
/// Nothing to warm without `local-host`. There is no shell to start on a
/// platform that cannot start one.
fn warm() {
    #[cfg(feature = "local-host")]
    {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| {
            tokenstat_host::warm_login_env();
            tokenstat_host::warm_shell_pool();
        });
    }
}

/// Handle one call, opening the default archive on first use.
///
/// Lazy rather than requiring a handshake, so a front end that wants one
/// number does not have to sequence an open first. Never panics on bad input
/// and never returns a non-JSON string, so the caller can decode
/// unconditionally.
pub fn call(method: &str, params: &str) -> String {
    // First, and before anything that could fail. `panic = "abort"` means a
    // panic under here ends the app with no Rust frame in the crash report, so
    // the hook that names the line has to be in place before the first call
    // rather than after the first successful one.
    crate::crashlog::install();
    // Before the first connection, and before the first archive open. A
    // process that runs out of descriptors reports it as whichever file
    // happened to be next, which is a sentence about the machine key or the
    // database rather than about the limit. See `open_files`.
    tokenstat_host::open_files::raise_open_file_limit();
    warm();

    // Answered without the lock where the method allows it. A terminal polls
    // for output continuously, and holding this mutex to do that would put
    // every keystroke behind whatever archive or git work was already running.
    if let Some(response) = dispatch::call_sessionless(method, params) {
        return response;
    }

    let mut guard = cell().lock().unwrap_or_else(PoisonError::into_inner);

    if guard.is_none() {
        match Session::open_default() {
            Ok(s) => *guard = Some(s),
            Err(e) => {
                return serde_json::json!({
                    "ok": false,
                    "error": {"code": "open_failed", "message": e}
                })
                .to_string();
            }
        }
    }

    // Match the daemon path: a scan owns its own SQLite connection so a UI
    // report does not queue behind minutes of disk parsing when the app is
    // temporarily using the in-process fallback.
    if method == "scan" {
        let opened = guard.as_ref().and_then(|session| {
            session.engine().ok().map(|engine| {
                (
                    engine.db_path().to_path_buf(),
                    engine.timezone().iana_name().map(str::to_string),
                )
            })
        });
        let Some((db_path, timezone)) = opened else {
            return match guard.as_mut() {
                Some(session) => dispatch::call(session, method, params),
                None => serde_json::json!({
                    "ok": false,
                    "error": {"code": "no_session", "message": "the archive is not open"}
                })
                .to_string(),
            };
        };
        drop(guard);
        return match tokenstat_core::Engine::open(Some(&db_path), timezone.as_deref()) {
            Ok(mut engine) => match engine.scan() {
                Ok(report) => {
                    match serde_json::to_value(tokenstat_host::dto::ScanReportDto::from(report)) {
                        Ok(value) => serde_json::json!({"ok": true, "result": value}).to_string(),
                        Err(error) => serde_json::json!({
                            "ok": false,
                            "error": {"code": "call_failed", "message": error.to_string()}
                        })
                        .to_string(),
                    }
                }
                Err(error) => serde_json::json!({
                    "ok": false,
                    "error": {"code": "call_failed", "message": error.to_string()}
                })
                .to_string(),
            },
            Err(error) => serde_json::json!({
                "ok": false,
                "error": {"code": "call_failed", "message": error.to_string()}
            })
            .to_string(),
        };
    }

    match guard.as_mut() {
        Some(session) => dispatch::call(session, method, params),
        None => serde_json::json!({
            "ok": false,
            "error": {"code": "no_session", "message": "the archive is not open"}
        })
        .to_string(),
    }
}
