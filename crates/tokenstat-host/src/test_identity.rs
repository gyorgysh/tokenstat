// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One private identity directory at a time, for the tests that need one.
//!
//! `TOKENSTAT_IDENTITY_DIR` is process-wide, so two tests pointing it at their
//! own temp directory at the same time would read each other's identity and
//! grants, and the failure would look like a policy bug rather than a harness
//! bug. Everything that sets it takes this lock for the whole test.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

pub(crate) static IDENTITY_LOCK: Mutex<()> = Mutex::new(());

/// A clock alone is not unique enough: two tests entering within the same tick
/// would build the same path and fight over one file.
static SEQ: AtomicU64 = AtomicU64::new(0);

/// Run `body` against an identity directory nobody else can see.
///
/// The variable is restored on the way out, panic or not, so a failing test
/// cannot leave the rest of the suite writing into a temp directory.
pub(crate) fn isolated<T>(body: impl FnOnce() -> T) -> T {
    let guard = IDENTITY_LOCK
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let dir = std::env::temp_dir().join(format!(
        "tokenstat-identity-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let previous = std::env::var_os("TOKENSTAT_IDENTITY_DIR");
    unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", &dir) };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body));
    match previous {
        Some(value) => unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", value) },
        None => unsafe { std::env::remove_var("TOKENSTAT_IDENTITY_DIR") },
    }
    let _ = std::fs::remove_dir_all(&dir);
    drop(guard);
    match result {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}
