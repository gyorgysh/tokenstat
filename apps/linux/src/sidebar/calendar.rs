// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Local Gregorian day boundaries for the chat timeline. `localtime_r` and
//! `mktime` use the process's local timezone, including daylight-saving rules.
//! Non-Gregorian calendar preferences and localized date titles remain open.

#[cfg(unix)]
fn local_parts(epoch_ms: i64) -> Option<libc::tm> {
    // time_t may be narrower on other Unix targets.
    #[allow(clippy::useless_conversion)]
    let seconds: libc::time_t = epoch_ms.div_euclid(1000).try_into().ok()?;
    let mut result = std::mem::MaybeUninit::<libc::tm>::uninit();
    // SAFETY: both pointers are valid and localtime_r writes the result on success.
    if unsafe { libc::localtime_r(&seconds, result.as_mut_ptr()) }.is_null() {
        None
    } else {
        // SAFETY: localtime_r succeeded and initialized the structure.
        Some(unsafe { result.assume_init() })
    }
}

#[cfg(unix)]
fn start_of_day(mut parts: libc::tm) -> Option<i64> {
    parts.tm_hour = 0;
    parts.tm_min = 0;
    parts.tm_sec = 0;
    parts.tm_isdst = -1;
    // SAFETY: `parts` is initialized and mktime normalizes it in place.
    let start = unsafe { libc::mktime(&mut parts) };
    #[allow(clippy::useless_conversion)]
    let seconds: i64 = start.try_into().ok()?;
    let roundtrip = local_parts(seconds.checked_mul(1000)?)?;
    if (roundtrip.tm_year, roundtrip.tm_yday) != (parts.tm_year, parts.tm_yday) {
        return None;
    }
    Some(seconds)
}

/// Return the local start of the timestamp's day and its bounded distance to
/// today. Distance is capped at seven, and future dates return zero: these are
/// the only distinctions needed by SwiftUI's Today/Yesterday/Older buckets.
/// Counting actual boundaries handles skipped civil dates as well as DST.
#[cfg(unix)]
pub fn local_day(epoch_ms: i64, now_ms: i64) -> Option<(i64, i64)> {
    let start = start_of_day(local_parts(epoch_ms)?)?;
    let today = start_of_day(local_parts(now_ms)?)?;
    if start >= today {
        return Some((start, 0));
    }
    let base = local_parts(start.checked_mul(1000)?)?;
    let mut current = start;
    let mut offset = 0;
    for days in 1..=super::layout::OLDER_AFTER_DAYS {
        let parts = local_parts(current.checked_mul(1000)?)?;
        // Some timezone changes skip an entire date. In that case mktime may
        // normalize a nonexistent next midnight backwards; try later dates
        // until a boundary advances rather than counting the missing date.
        let mut next = None;
        for _ in 0..3 {
            offset += 1;
            let mut candidate = base;
            candidate.tm_mday += offset;
            candidate.tm_isdst = -1;
            // SAFETY: candidate is initialized and mktime normalizes it.
            let raw = unsafe { libc::mktime(&mut candidate) };
            #[allow(clippy::useless_conversion)]
            let value = i64::try_from(raw).ok()?;
            if value > current
                && let Some(next_parts) = value.checked_mul(1000).and_then(local_parts)
                && (next_parts.tm_year, next_parts.tm_yday) != (parts.tm_year, parts.tm_yday)
            {
                next = Some(value);
                break;
            }
        }
        current = next?;
        if current > today {
            return Some((start, days - 1));
        }
        if current == today {
            return Some((start, days));
        }
    }
    Some((start, super::layout::OLDER_AFTER_DAYS))
}
