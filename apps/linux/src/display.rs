// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Presentation helpers matching the desktop's bridge models.

use crate::{home::format_spend, localization};

pub fn money(micros: i64, estimated: bool, complete: bool) -> String {
    let amount = format_spend(micros.unsigned_abs());
    let amount = if micros < 0 {
        format!("-{amount}")
    } else {
        amount
    };
    if !complete {
        format!("{amount}+")
    } else if estimated {
        format!("~{amount}")
    } else {
        amount
    }
}

pub fn tokens(n: u64) -> String {
    let value = n as f64;
    match n {
        1_000_000_000.. => format!("{:.1}B", value / 1e9),
        1_000_000.. => format!("{:.1}M", value / 1e6),
        10_000.. => format!("{:.0}k", value / 1e3),
        1_000.. => format!("{:.1}k", value / 1e3),
        _ => n.to_string(),
    }
}

/// Initial English relative copy; desktop locale/CLDR integration remains a
/// parity gate. Keep timestamps untouched and share a coarse UI clock.
pub fn relative_english(target_ms: i64, now_ms: i64, named: bool) -> String {
    let delta = target_ms.saturating_sub(now_ms);
    let seconds = delta.unsigned_abs() / 1000;
    if seconds == 0 {
        return if named {
            "now".into()
        } else {
            localization::text("apple.relativetimetext.just_now.7ddb44d8", &[])
        };
    }
    let (count, unit) = if seconds >= 31_536_000 {
        (seconds / 31_536_000, "year")
    } else if seconds >= 2_592_000 {
        (seconds / 2_592_000, "month")
    } else if seconds >= 604_800 {
        (seconds / 604_800, "week")
    } else if seconds >= 86_400 {
        (seconds / 86_400, "day")
    } else if seconds >= 3600 {
        (seconds / 3600, "hour")
    } else if seconds >= 60 {
        (seconds / 60, "minute")
    } else {
        (seconds, "second")
    };
    if named && count == 1 {
        let word = match (delta >= 0, unit) {
            (true, "day") => Some("tomorrow"),
            (false, "day") => Some("yesterday"),
            (true, "week") => Some("next week"),
            (false, "week") => Some("last week"),
            (true, "month") => Some("next month"),
            (false, "month") => Some("last month"),
            (true, "year") => Some("next year"),
            (false, "year") => Some("last year"),
            _ => None,
        };
        if let Some(word) = word {
            return word.into();
        }
    }
    let words = format!("{count} {unit}{}", if count == 1 { "" } else { "s" });
    if delta >= 0 {
        format!("in {words}")
    } else {
        format!("{words} ago")
    }
}
pub fn capitalized(value: &str) -> String {
    let mut start = true;
    let mut out = String::new();
    for c in value.chars() {
        if c.is_alphabetic() {
            out.extend(if start {
                c.to_uppercase().collect::<Vec<_>>()
            } else {
                c.to_lowercase().collect()
            });
            start = false;
        } else {
            out.push(c);
            if c != '\'' && c != '’' {
                start = true
            }
        }
    }
    out
}

pub fn short_model(id: &str) -> String {
    // Foundation's .whitespaces includes horizontal separators and U+200B,
    // but excludes vertical tab, form feed, NEL and line/paragraph separators.
    fn whitespace(c: char) -> bool {
        matches!(
            c,
            '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
                ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
    }
    let raw = id.trim_matches(whitespace);
    let leaf = raw.rsplit('/').find(|p| !p.is_empty()).unwrap_or(raw);
    if [
        "default",
        "auto",
        "cursor-auto",
        "cursor-default",
        "cursor-router-auto",
    ]
    .contains(&leaf.to_lowercase().as_str())
    {
        return "cursor-router-auto".into();
    }
    if let Some((_, after)) = leaf.split_once(": ") {
        let after = after.trim_matches(whitespace);
        if !after.is_empty() {
            return after.to_owned();
        }
    }
    if leaf.is_empty() {
        "model".into()
    } else {
        leaf.into()
    }
}

pub fn harness_key(id: &str) -> &str {
    tokenstat_core::model::SourceId::tool_id(id)
}
pub fn harness_canonical(id: &str) -> &str {
    if id == "agy" || id.starts_with("antigravity") {
        "antigravity"
    } else {
        match id {
            "claude" => "claude_code",
            "opencode2" => "opencode",
            _ => id,
        }
    }
}
pub fn harness_name(id: &str) -> String {
    if id == "opencode2" {
        return "OpenCode 2".into();
    }
    let canonical = harness_canonical(id);
    let key = match canonical {
        "claude_code" => Some("apple.models.claude_code.246ef8c1"),
        "claude_code_estimate" | "claude_code_rollup" => {
            Some("apple.models.claude_code_recovered.93f5e6b2")
        }
        "grok" => Some("apple.models.grok_build.fd3bf01a"),
        "devin" => Some("apple.models.devin_cli.29247d05"),
        "dsh" => Some("apple.models.deepseek_harness.e562a9c5"),
        "copilot" => Some("apple.models.copilot_cli.c73e38d4"),
        "hermes" => Some("apple.models.hermes_agent.873e989a"),
        "kilo" => Some("apple.models.kilo_code.83abecfd"),
        "kimi" => Some("apple.models.kimi_code.0c486180"),
        "qwen" => Some("apple.models.qwen_code.47487dbd"),
        _ => None,
    };
    if let Some(key) = key {
        localization::text(key, &[])
    } else if canonical.is_empty() {
        "unknown".into()
    } else if canonical == "gemini" {
        "Gemini".into()
    } else {
        tokenstat_core::model::SourceId::label(canonical).to_owned()
    }
}

/// HarnessMark uses one whole character, including accents and joined emoji.
pub fn harness_initial(id: &str) -> String {
    use unicode_segmentation::UnicodeSegmentation;
    harness_name(id)
        .graphemes(true)
        .next()
        .map(str::to_uppercase)
        .unwrap_or_else(|| "?".into())
}

pub fn harness_brand_asset(id: &str) -> Option<String> {
    let canonical = harness_canonical(harness_key(id));
    [
        "claude_code",
        "codex",
        "grok",
        "opencode",
        "cline",
        "openclaw",
        "muse",
        "devin",
        "pi",
        "dsh",
        "zed",
        "copilot",
        "antigravity",
        "cursor",
        "gemini",
        "hermes",
        "kilo",
        "kimi",
        "qwen",
    ]
    .contains(&canonical)
    .then(|| format!("brand_{canonical}"))
}

/// C locale objects are per-call/thread, never a process-wide setlocale mutation.
#[cfg(unix)]
struct Locale(libc::locale_t);
#[cfg(unix)]
impl Locale {
    fn current(mask: libc::c_int) -> Option<Self> {
        // SAFETY: empty locale name requests the environment's current native
        // locale; the returned object is owned until Drop.
        let raw = unsafe { libc::newlocale(mask, c"".as_ptr(), std::ptr::null_mut()) };
        (!raw.is_null()).then_some(Self(raw))
    }
}
#[cfg(unix)]
impl Drop for Locale {
    fn drop(&mut self) {
        unsafe {
            libc::freelocale(self.0);
        }
    }
}

pub fn integer(n: u64) -> String {
    #[cfg(unix)]
    if let Some(locale) = Locale::current(libc::LC_NUMERIC_MASK) {
        // SAFETY: uselocale is thread-local. Restore it before the owned locale
        // is freed, and copy localeconv's borrowed fields while it is active.
        let (separator, groups) = unsafe {
            let previous = libc::uselocale(locale.0);
            let info = libc::localeconv();
            let separator = std::ffi::CStr::from_ptr((*info).thousands_sep)
                .to_string_lossy()
                .into_owned();
            let groups = std::ffi::CStr::from_ptr((*info).grouping)
                .to_bytes()
                .to_vec();
            libc::uselocale(previous);
            (separator, groups)
        };
        return grouped(n, &separator, &groups);
    }
    grouped(n, ",", &[3])
}

/// A local wall time for the current open block. Desktop-specific short-time
/// conventions (including 12-hour preferences) still need native integration.
#[cfg(unix)]
pub fn local_short_time(epoch_ms: i64) -> Option<String> {
    // time_t can be narrower than i64 on supported Unix targets.
    #[allow(clippy::useless_conversion)]
    let seconds: libc::time_t = epoch_ms.div_euclid(1000).try_into().ok()?;
    let mut parts = std::mem::MaybeUninit::<libc::tm>::uninit();
    // SAFETY: the input and output pointers are valid for this call.
    if unsafe { libc::localtime_r(&seconds, parts.as_mut_ptr()) }.is_null() {
        return None;
    }
    let parts = unsafe { parts.assume_init() };
    Some(format!("{:02}:{:02}", parts.tm_hour, parts.tm_min))
}

fn grouped(n: u64, separator: &str, groups: &[u8]) -> String {
    let raw = n.to_string();
    if separator.is_empty() || groups.is_empty() {
        return raw;
    }
    let mut chunks = Vec::new();
    let mut end = raw.len();
    let mut group = 0;
    while end > 0 {
        let count = usize::from(groups[group.min(groups.len() - 1)]);
        if count == 0 || count >= 127 {
            chunks.push(&raw[..end]);
            break;
        }
        let start = end.saturating_sub(count);
        chunks.push(&raw[start..end]);
        end = start;
        group += 1;
    }
    chunks.reverse();
    chunks.join(separator)
}

/// The inspector fixes UTC; the hover card deliberately uses local output time,
/// matching the two current Swift helpers. Full desktop-locale integration is
/// still required for platform preferences beyond LC_TIME/LC_NUMERIC.
#[cfg(unix)]
pub fn friendly_date(iso: &str, local_output: bool) -> String {
    let pieces: Vec<_> = iso.split('-').collect();
    if pieces.len() != 3 || iso.len() != 10 {
        return iso.into();
    }
    let parsed: Option<Vec<i32>> = pieces.iter().map(|s| s.parse().ok()).collect();
    let Some(parts) = parsed else {
        return iso.into();
    };
    let (year, month, day) = (parts[0], parts[1], parts[2]);
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    // SAFETY: timegm and localtime_r operate on valid, owned tm storage.
    let epoch = unsafe { libc::timegm(&mut tm) };
    if tm.tm_year != year - 1900 || tm.tm_mon != month - 1 || tm.tm_mday != day {
        return iso.into();
    }
    if local_output && unsafe { libc::localtime_r(&epoch, &mut tm) }.is_null() {
        return iso.into();
    }
    let Some(locale) = Locale::current(libc::LC_TIME_MASK) else {
        return iso.into();
    };
    let mut bytes = [0_u8; 128];
    let count = unsafe {
        libc::strftime_l(
            bytes.as_mut_ptr().cast(),
            bytes.len(),
            c"%b".as_ptr(),
            &tm,
            locale.0,
        )
    };
    if count == 0 {
        return iso.into();
    }
    format!(
        "{} {}, {}",
        String::from_utf8_lossy(&bytes[..count]),
        tm.tm_mday,
        tm.tm_year + 1900
    )
}

/// Initial abbreviated local month and day for sidebar chat groups.
#[cfg(unix)]
pub fn local_month_day(epoch_seconds: i64) -> Option<String> {
    #[allow(clippy::useless_conversion)]
    let epoch: libc::time_t = epoch_seconds.try_into().ok()?;
    let mut parts = std::mem::MaybeUninit::<libc::tm>::uninit();
    // SAFETY: localtime_r receives valid input and output pointers.
    if unsafe { libc::localtime_r(&epoch, parts.as_mut_ptr()) }.is_null() {
        return None;
    }
    // SAFETY: a successful localtime_r initialized the output.
    let parts = unsafe { parts.assume_init() };
    let locale = Locale::current(libc::LC_TIME_MASK)?;
    let mut bytes = [0_u8; 128];
    // SAFETY: the buffer, format, tm and locale remain valid for this call.
    let count = unsafe {
        libc::strftime_l(
            bytes.as_mut_ptr().cast(),
            bytes.len(),
            c"%b".as_ptr(),
            &parts,
            locale.0,
        )
    };
    (count > 0).then(|| {
        format!(
            "{} {}",
            String::from_utf8_lossy(&bytes[..count]),
            parts.tm_mday
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_group_patterns_support_repeated_and_secondary_groups() {
        assert_eq!(grouped(123456789, ",", &[3]), "123,456,789");
        assert_eq!(grouped(123456789, ",", &[3, 2]), "12,34,56,789");
        assert_eq!(grouped(123456789, ",", &[3, 127]), "123456,789");
    }
}
