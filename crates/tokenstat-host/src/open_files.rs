// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Room for the descriptors a session actually needs.
//!
//! Apple's platforms hand a process a soft limit of 256 open files and a hard
//! limit orders of magnitude above it. Two hundred and fifty six is generous
//! for an app that opens documents and nothing like enough for this one: the
//! archive, a relay tunnel, a direct connection per screen session, the
//! pooled connection to every peer, and a socket per SSH session all live at
//! once, and none of them is a leak.
//!
//! What that ceiling looks like when it is reached is the reason this module
//! exists. The next `open` fails wherever it happens to be, so the sentence a
//! person reads names whichever file lost the race, usually the machine key
//! on the way into a screen session, and reads as corruption rather than as a
//! process out of descriptors.
//!
//! Raising the soft limit is not raising a safety margin: the hard limit is
//! still there and is the one the kernel enforces. This only stops the
//! process asking for less than it is allowed.

/// Raise this process's soft open-file limit towards its hard limit.
///
/// Idempotent and best effort. A platform that refuses, or has no such limit,
/// leaves the process exactly as it was: there is nothing to fall back to and
/// nothing worth failing a launch over.
pub fn raise_open_file_limit() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        #[cfg(unix)]
        raise();
    });
}

/// The most this asks for.
///
/// `RLIM_INFINITY` is a valid hard limit and a terrible thing to ask for as a
/// soft one: some of the C library's own tables are sized from it. Ten
/// thousand and change is what a shell's `ulimit -n unlimited` resolves to on
/// a Mac, and it is far beyond anything a session here opens.
#[cfg(unix)]
const WANTED: libc::rlim_t = 10_240;

#[cfg(unix)]
fn raise() {
    // SAFETY: `getrlimit` writes a fully initialized `rlimit` through the
    // pointer, and the pointer is to a local that outlives the call.
    let mut limit = unsafe {
        let mut value = std::mem::zeroed::<libc::rlimit>();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut value) != 0 {
            return;
        }
        value
    };
    let ceiling = if limit.rlim_max == libc::RLIM_INFINITY {
        WANTED
    } else {
        limit.rlim_max.min(WANTED)
    };
    if limit.rlim_cur >= ceiling {
        return;
    }
    limit.rlim_cur = ceiling;
    // SAFETY: the same fully initialized value, with only the soft limit
    // changed and never above the hard limit the kernel just reported.
    let _ = unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) };
}

/// The soft and hard open-file limits, for `info` and for a bug report.
///
/// `None` where the platform has no such limit to report.
pub fn open_file_limit() -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        // SAFETY: as in `raise`.
        unsafe {
            let mut value = std::mem::zeroed::<libc::rlimit>();
            if libc::getrlimit(libc::RLIMIT_NOFILE, &mut value) != 0 {
                return None;
            }
            Some((value.rlim_cur as u64, value.rlim_max as u64))
        }
    }
    #[cfg(not(unix))]
    {
        None
    }
}

/// How many descriptors this process has open right now.
///
/// Counted from `/dev/fd`, which both Apple's platforms and Linux provide, and
/// which is a directory read rather than a syscall table walk. `None` where
/// that is not readable, because a guess here would be worse than saying
/// nothing: this number exists to be put in a bug report beside the limit.
///
/// The read opens a descriptor of its own, which is counted and then closed.
/// One is not worth correcting for and pretending otherwise would be a second
/// number to keep true.
pub fn open_file_count() -> Option<usize> {
    #[cfg(unix)]
    {
        std::fs::read_dir("/dev/fd").ok().map(Iterator::count)
    }
    #[cfg(not(unix))]
    {
        None
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn the_open_count_is_plausible() {
        let count = open_file_count().expect("unix can count /dev/fd");
        let (soft, _) = open_file_limit().expect("unix reports a limit");
        // stdin, stdout, stderr and the directory being read, at least.
        assert!(count >= 3, "counted {count} open files");
        assert!(
            (count as u64) <= soft,
            "counted {count} open files against a soft limit of {soft}"
        );
    }

    #[test]
    fn the_soft_limit_is_at_least_what_a_session_needs() {
        raise_open_file_limit();
        let (soft, hard) = open_file_limit().expect("unix reports a limit");
        assert!(soft > 256 || soft == hard, "soft limit stayed at {soft}");
        assert!(soft <= hard, "soft {soft} must not exceed hard {hard}");
    }
}
