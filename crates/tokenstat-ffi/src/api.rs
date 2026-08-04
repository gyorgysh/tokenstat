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

/// Handle one call, opening the default archive on first use.
///
/// Lazy rather than requiring a handshake, so a front end that wants one
/// number does not have to sequence an open first. Never panics on bad input
/// and never returns a non-JSON string, so the caller can decode
/// unconditionally.
pub fn call(method: &str, params: &str) -> String {
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

    match guard.as_mut() {
        Some(session) => dispatch::call(session, method, params),
        None => serde_json::json!({
            "ok": false,
            "error": {"code": "no_session", "message": "the archive is not open"}
        })
        .to_string(),
    }
}
