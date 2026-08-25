// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! A breadcrumb written the moment before a panic takes the app down.
//!
//! The workspace builds with `panic = "abort"` and this library is linked into
//! the app rather than run beside it, so a panic anywhere under the C ABI ends
//! the whole process. There is no unwinding to catch and no error envelope to
//! return: from the outside the app simply disappears, which is what people
//! reported and what nobody could act on, because an abort inside a static
//! library leaves a crash report full of offsets and no Rust frame that names
//! the line.
//!
//! A panic hook still runs before the abort. This one writes where and what to
//! a file next to the archive, so the next report is a sentence instead of a
//! guess.
//!
//! **Nothing here may carry user content.** The panic message is written by
//! this codebase, and the location is a path inside this repository. A payload,
//! a file path from somebody's machine or a record id would turn a debugging
//! aid into a log of what somebody was doing, so nothing but the panic's own
//! message and location is recorded.

use std::io::Write;
use std::path::PathBuf;

/// Where the breadcrumb goes. Beside the archive, not in a temp directory that
/// is swept before anybody thinks to look.
fn log_path() -> Option<PathBuf> {
    tokenstat_paths::data_dir().map(|dir| dir.join("last-panic.log"))
}

/// Install the hook once per process.
///
/// Called from the first call over the ABI rather than from an initialiser,
/// because the ABI has no initialiser and a front end cannot be trusted to
/// remember one.
pub fn install() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            record(info);
            previous(info);
        }));
    });
}

fn record(info: &std::panic::PanicHookInfo<'_>) {
    let location = info
        .location()
        .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
        .unwrap_or_else(|| "unknown location".into());
    // `payload` is the argument to `panic!`, which in this codebase is always
    // a literal or a message this codebase composed.
    let message = info
        .payload()
        .downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| info.payload().downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "panic with no message".into());
    // Seconds since the epoch rather than a formatted date: this crate has no
    // calendar dependency, and the only question ever asked of this line is
    // whether it belongs to the crash being looked at.
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!("t={at} panic at {location}: {message}\n");
    // Best effort by design. This runs while the process is already ending, so
    // a failure to write must not become a second panic inside the hook.
    if let Some(path) = log_path()
        && let Some(parent) = path.parent()
    {
        let _ = std::fs::create_dir_all(parent);
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut file| file.write_all(line.as_bytes()));
    }
    // Also to stderr, which is where a development run and the daemon's
    // journal both look.
    let _ = std::io::stderr().write_all(line.as_bytes());
}
