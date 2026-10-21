// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Authority budgets count suspension as well as awake time. They are local
//! to this process and boot; never persist or accept these clock values over RPC.

use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug)]
pub struct Stamp {
    pub awake: Instant,
    pub boot: Duration,
}
impl Stamp {
    pub fn now() -> Option<Self> {
        // Sample the boot clock first so clock sampling itself cannot enlarge
        // the suspension-inclusive budget.
        let boot = boot_time()?;
        Some(Self {
            awake: Instant::now(),
            boot,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Deadline {
    awake_start: Instant,
    awake_end: Instant,
    boot_start: Duration,
    boot_end: Duration,
}
impl Deadline {
    pub fn at(start: Stamp, budget: Duration) -> Option<Self> {
        Some(Self {
            awake_start: start.awake,
            awake_end: start.awake.checked_add(budget)?,
            boot_start: start.boot,
            boot_end: start.boot.checked_add(budget)?,
        })
    }
    pub fn capture(budget: Duration) -> Option<Self> {
        Self::at(Stamp::now()?, budget)
    }
    /// Intersect an original budget with a newly observed shorter lease.
    /// Neither clock can extend the original authority.
    pub fn clipped(self, other: Self) -> Self {
        Self {
            awake_start: self.awake_start.max(other.awake_start),
            awake_end: self.awake_end.min(other.awake_end),
            boot_start: self.boot_start.max(other.boot_start),
            boot_end: self.boot_end.min(other.boot_end),
        }
    }
    pub fn remaining(&self) -> Option<Duration> {
        self.remaining_at(Stamp::now()?)
    }
    pub fn remaining_at(&self, now: Stamp) -> Option<Duration> {
        // A failed or regressing platform clock retires authority rather than
        // making an expired lease appear to have time left.
        if now.awake < self.awake_start || now.boot < self.boot_start {
            return None;
        }
        let remaining = self
            .awake_end
            .checked_duration_since(now.awake)?
            .min(self.boot_end.checked_sub(now.boot)?);
        (!remaining.is_zero()).then_some(remaining)
    }
}

#[cfg(any(target_vendor = "apple", target_os = "linux", target_os = "android"))]
fn boot_time() -> Option<Duration> {
    #[cfg(target_vendor = "apple")]
    let clock = libc::CLOCK_MONOTONIC_RAW;
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let clock = libc::CLOCK_BOOTTIME;
    let mut value = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: a valid writable timespec and the platform's documented
    // suspension-inclusive, non-settable clock. No pointers escape this call.
    if unsafe { libc::clock_gettime(clock, &mut value) } != 0
        || value.tv_sec < 0
        || !(0..1_000_000_000).contains(&value.tv_nsec)
    {
        return None;
    }
    Some(Duration::new(
        u64::try_from(value.tv_sec).ok()?,
        u32::try_from(value.tv_nsec).ok()?,
    ))
}

#[cfg(windows)]
fn boot_time() -> Option<Duration> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        #[link_name = "GetTickCount64"]
        fn get_tick_count64() -> u64;
    }
    // SAFETY: GetTickCount64 takes no arguments, is available on every
    // supported Windows version and includes sleep/hibernation time.
    Some(Duration::from_millis(unsafe { get_tick_count64() }))
}

#[cfg(not(any(
    target_vendor = "apple",
    target_os = "linux",
    target_os = "android",
    windows
)))]
fn boot_time() -> Option<Duration> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start() -> Stamp {
        Stamp {
            awake: Instant::now(),
            boot: Duration::from_secs(100),
        }
    }

    #[test]
    fn sleeping_past_a_lease_expires_even_when_awake_and_wall_clocks_do_not_advance() {
        let start = start();
        let lease = Deadline::at(start, Duration::from_secs(60)).unwrap();
        assert_eq!(lease.remaining_at(start), Some(Duration::from_secs(60)));
        let awake = Stamp {
            boot: start.boot + Duration::from_secs(59),
            ..start
        };
        assert_eq!(lease.remaining_at(awake), Some(Duration::from_secs(1)));
        assert!(
            lease
                .remaining_at(Stamp {
                    boot: start.boot + Duration::from_secs(60),
                    ..start
                })
                .is_none()
        );
    }

    #[test]
    fn either_clock_expiry_or_regression_retires_authority() {
        let start = start();
        let lease = Deadline::at(start, Duration::from_secs(60)).unwrap();
        assert!(
            lease
                .remaining_at(Stamp {
                    awake: start.awake + Duration::from_secs(60),
                    ..start
                })
                .is_none()
        );
        assert!(
            lease
                .remaining_at(Stamp {
                    boot: start.boot - Duration::from_secs(1),
                    ..start
                })
                .is_none()
        );
        assert!(
            lease
                .remaining_at(Stamp {
                    awake: start.awake - Duration::from_secs(1),
                    ..start
                })
                .is_none()
        );
    }

    #[test]
    fn a_later_snapshot_cannot_extend_an_original_budget() {
        let start = start();
        let original = Deadline::at(start, Duration::from_secs(20)).unwrap();
        let later = Stamp {
            awake: start.awake + Duration::from_secs(5),
            boot: start.boot + Duration::from_secs(5),
        };
        let fresh = Deadline::at(later, Duration::from_secs(60)).unwrap();
        assert_eq!(
            original.clipped(fresh).remaining_at(later),
            Some(Duration::from_secs(15))
        );
        assert_eq!(fresh.clipped(original), original.clipped(fresh));
        assert!(
            Deadline::at(start, Duration::ZERO)
                .unwrap()
                .remaining_at(start)
                .is_none()
        );
    }

    #[test]
    fn platform_clock_can_bound_a_local_authority_budget() {
        let lease = Deadline::capture(Duration::from_secs(60)).expect("supported platform clock");
        assert!(
            lease
                .remaining()
                .is_some_and(|left| left <= Duration::from_secs(60))
        );
    }
}
