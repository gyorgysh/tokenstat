//! The C boundary. The only module in the crate with `unsafe`.
//!
//! Two functions, both taking and returning UTF-8 C strings. Everything the
//! caller needs to know:
//!
//! - Both arguments to [`tokenstat_ffi_call`] may be null, and are read as an
//!   empty string if they are.
//! - The returned pointer is owned by the caller and **must** be released with
//!   [`tokenstat_ffi_string_free`]. It is never null: allocation failure aside,
//!   even a rejected call comes back as a JSON error envelope.
//! - Calls are serialized internally, so it is safe to call from any thread,
//!   but `scan` holds the lock for as long as it runs. Do not call it from a
//!   thread that is drawing.
//!
//! The workspace builds with `panic = "abort"`, so a panic here cannot be
//! caught and turned into an error envelope: it takes the host process with it.
//! That is why [`crate::api`] returns `Result` everywhere rather than
//! unwrapping, and why it is the module carrying the tests.

use std::ffi::{CStr, CString, c_char};

use crate::api;

/// Read a C string as Rust, treating null and invalid UTF-8 as empty.
///
/// # Safety
///
/// `ptr` must be null or a valid pointer to a NUL-terminated string that stays
/// alive for the duration of the call.
unsafe fn as_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string.
    unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("")
}

/// The wire contract this build speaks, as a static NUL-terminated string.
///
/// Separate from [`tokenstat_ffi_call`] because a front end asks this before it
/// has chosen a transport, and going through the call path would start the
/// login-environment resolve and the shell pool inside an app that is about to
/// hand its work to the daemon instead. Nothing to free: the pointer is to a
/// string constant with the same lifetime as the library.
#[unsafe(no_mangle)]
pub extern "C" fn tokenstat_ffi_protocol_version() -> *const c_char {
    // A C string has to be NUL terminated and the Rust constant is not, so
    // this is written out once and checked against it at compile time. Bumping
    // one without the other is a build error rather than a silent disagreement.
    const VERSION: &str = "3\0";
    const _: () = {
        let spoken = tokenstat_host::PROTOCOL_VERSION.as_bytes();
        assert!(
            spoken.len() == 1 && spoken[0] == b'3',
            "PROTOCOL_VERSION moved: update the C ABI string beside it"
        );
    };
    VERSION.as_ptr() as *const c_char
}

/// Invoke one bridge method. See [`crate::api`] for the envelope shape.
///
/// # Safety
///
/// `method` and `params` must each be null or a valid NUL-terminated UTF-8
/// string. The returned pointer must be released with
/// [`tokenstat_ffi_string_free`] and not freed by any other allocator.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tokenstat_ffi_call(
    method: *const c_char,
    params: *const c_char,
) -> *mut c_char {
    // SAFETY: forwarded from this function's own contract.
    let method = unsafe { as_str(method) };
    // SAFETY: as above.
    let params = unsafe { as_str(params) };

    let response = api::call(method, params);

    // A NUL inside the response would mean serde_json emitted an interior NUL,
    // which it cannot. Fall back rather than panic, because a panic here aborts
    // the host app.
    match CString::new(response) {
        Ok(s) => s.into_raw(),
        Err(_) => CString::new(r#"{"ok":false,"error":{"code":"encoding","message":"response contained an interior NUL"}}"#)
            .unwrap_or_default()
            .into_raw(),
    }
}

/// Release a string returned by [`tokenstat_ffi_call`].
///
/// Null is accepted and ignored.
///
/// # Safety
///
/// `s` must be null, or a pointer previously returned by
/// [`tokenstat_ffi_call`] and not yet freed. Passing anything else, or the same
/// pointer twice, is undefined behaviour.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tokenstat_ffi_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: the caller guarantees this came from CString::into_raw.
    drop(unsafe { CString::from_raw(s) });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// Drive the real C entry point the way Swift will.
    fn c_call(method: &str, params: &str) -> String {
        let m = CString::new(method).unwrap();
        let p = CString::new(params).unwrap();
        // SAFETY: both strings outlive the call, and the result is freed below.
        let raw = unsafe { tokenstat_ffi_call(m.as_ptr(), p.as_ptr()) };
        assert!(!raw.is_null());
        // SAFETY: raw came from tokenstat_ffi_call and is still owned here.
        let out = unsafe { CStr::from_ptr(raw) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: freeing exactly once, immediately after copying the contents.
        unsafe { tokenstat_ffi_string_free(raw) };
        out
    }

    #[test]
    fn a_round_trip_through_the_boundary_returns_json() {
        let out = c_call("info", "{}");
        let v: Value = serde_json::from_str(&out).expect("valid JSON");
        assert!(v["ok"].is_boolean());
    }

    #[test]
    fn null_arguments_do_not_crash() {
        // SAFETY: null is explicitly part of the contract.
        let raw = unsafe { tokenstat_ffi_call(std::ptr::null(), std::ptr::null()) };
        assert!(!raw.is_null());
        // SAFETY: raw is owned here.
        let out = unsafe { CStr::from_ptr(raw) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: freeing exactly once.
        unsafe { tokenstat_ffi_string_free(raw) };

        let v: Value = serde_json::from_str(&out).expect("valid JSON");
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn freeing_null_is_a_no_op() {
        // SAFETY: null is explicitly accepted.
        unsafe { tokenstat_ffi_string_free(std::ptr::null_mut()) };
    }
}
