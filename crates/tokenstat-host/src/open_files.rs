// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Room for the descriptors a session actually needs.

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

#[cfg(unix)]
const WANTED: libc::rlim_t = 10_240;

#[cfg(unix)]
fn raise() {
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

    let _ = unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) };
}

/// The soft and hard open-file limits, for `info` and for a bug report.
///
/// `None` where the platform has no such limit to report.
pub fn open_file_limit() -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
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
