// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The error half of the response envelope.
//!
//! Every failure used to arrive as a bare string under one code, `call_failed`,
//! which is enough for a person reading a message and not enough for a front
//! end deciding what to do next. A client with no local archive asks for a
//! report and has to tell "this build cannot answer that" apart from "the
//! archive is corrupt", and a sentence cannot be matched on without inventing a
//! second, worse protocol out of substring checks.
//!
//! So a dispatch failure carries a code. `From<String>` keeps every existing
//! `map_err(|e| e.to_string())?` working unchanged and lands it on
//! [`CALL_FAILED`], which is exactly what those call sites meant.

use std::fmt;

/// The general failure. What a call returns when nothing more specific applies.
pub const CALL_FAILED: &str = "call_failed";

/// This build has no archive of its own, so the method cannot be answered here.
///
/// Not a fault and not a transient condition: a mobile client is a client of a
/// machine that keeps logs, and asking it to report on its own is a category
/// error. A front end reads this code and offers the account instead of
/// retrying or showing a fault.
pub const NO_LOCAL_ARCHIVE: &str = "no_local_archive";

/// A failed call, and the code the envelope will carry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DispatchError {
    pub code: String,
    pub message: String,
}

impl DispatchError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        DispatchError {
            code: code.into(),
            message: message.into(),
        }
    }

    /// Said the same way everywhere, because a front end may show it verbatim.
    pub fn no_local_archive() -> Self {
        DispatchError::new(
            NO_LOCAL_ARCHIVE,
            "This build keeps no archive of its own. Ask a machine that does, \
             or use the account.",
        )
    }
}

impl fmt::Display for DispatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for DispatchError {}

impl From<String> for DispatchError {
    fn from(message: String) -> Self {
        DispatchError::new(CALL_FAILED, message)
    }
}

impl From<&str> for DispatchError {
    fn from(message: &str) -> Self {
        DispatchError::new(CALL_FAILED, message.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_string_lands_on_the_general_code() {
        let e: DispatchError = "the archive is locked".to_string().into();
        assert_eq!(e.code, CALL_FAILED);
        assert_eq!(e.message, "the archive is locked");
    }

    #[test]
    fn the_missing_archive_keeps_its_own_code() {
        let e = DispatchError::no_local_archive();
        assert_eq!(e.code, NO_LOCAL_ARCHIVE);
        assert!(!e.message.is_empty());
    }
}
