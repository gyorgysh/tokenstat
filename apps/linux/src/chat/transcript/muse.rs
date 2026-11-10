// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Bounded recovery of documented metadata from older Muse tool results.

use super::{has_prefix, lf_lines};
use crate::work::text;
use serde::Serialize;

pub const MAXIMUM_DETAIL_BYTES: usize = 128 * 1024;
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Presentation {
    pub verb: String,
    pub target: String,
}
pub fn completed(
    backend: Option<&str>,
    verb: &str,
    target: &str,
    detail: Option<&str>,
) -> Presentation {
    if backend != Some("muse") {
        return Presentation {
            verb: verb.into(),
            target: target.into(),
        };
    }
    let canonical = match verb.to_lowercase().as_str() {
        "bash input" | "bash_input" => "Bash",
        "read skill" | "read_skill" => "Read",
        "write todos" | "write_todos" => "TodoWrite",
        _ => verb,
    };
    let Some(detail) = detail.filter(|_| target.is_empty()) else {
        return Presentation {
            verb: canonical.into(),
            target: target.into(),
        };
    };
    let bounded =
        String::from_utf8_lossy(&detail.as_bytes()[..detail.len().min(MAXIMUM_DETAIL_BYTES)]);
    let lines = lf_lines(&bounded, 2);
    let first = text::trim(lines[0]);
    let object = if detail.len() <= MAXIMUM_DETAIL_BYTES && has_prefix(first, "{") {
        serde_json::from_str::<serde_json::Value>(detail)
            .ok()
            .filter(|v| v.is_object())
    } else {
        None
    };
    let field = |key: &str| {
        object
            .as_ref()
            .and_then(|o| o.get(key))
            .and_then(|v| v.as_str())
            .map(str::to_owned)
    };
    let recovered = match canonical {
        "Bash" | "Shell" => field("command").filter(|s| !s.is_empty()).or_else(|| {
            if has_prefix(first, "$ ") {
                Some(first[2..].into())
            } else {
                lines
                    .get(1)
                    .filter(|l| has_prefix(l, "$ "))
                    .map(|l| l[2..].into())
            }
        }),
        "Read" => field("path").or_else(|| {
            if has_prefix(first, "Read text file `") && first.ends_with("`.") {
                Some(first[16..first.len() - 2].into())
            } else {
                read_skill(first).map(xml_attribute)
            }
        }),
        "Write" => field("path").or_else(|| wrote(first)),
        "WebSearch" => field("query"),
        "WebFetch" => field("url"),
        "TodoWrite" => todo(first).then(|| first.into()),
        _ => None,
    };
    Presentation {
        verb: canonical.into(),
        target: recovered.unwrap_or_else(|| target.into()),
    }
}
fn read_skill(first: &str) -> Option<&str> {
    let rest = first.strip_prefix("<read-skill-result")?;
    let trimmed = rest.trim_start_matches(char::is_whitespace);
    if rest.len() == trimmed.len() {
        return None;
    }
    let name = trimmed.strip_prefix("name=\"")?;
    let end = name.find('"')?;
    if end == 0 {
        return None;
    }
    let after = &name[end + 1..];
    if !after.starts_with('>') && !after.chars().next().is_some_and(char::is_whitespace) {
        return None;
    }
    Some(&name[..end])
}
fn wrote(first: &str) -> Option<String> {
    let rest = first.strip_prefix("wrote ")?;
    let end = rest.bytes().take_while(u8::is_ascii_digit).count();
    if end == 0 {
        return None;
    }
    let path = rest[end..].strip_prefix(" bytes to ")?;
    (!path.is_empty() && !path.chars().any(regex_line_end)).then(|| path.into())
}
fn todo(first: &str) -> bool {
    let end = first.bytes().take_while(u8::is_ascii_digit).count();
    if end == 0 {
        return false;
    }
    let Some(rest) = first[end..].strip_prefix(" todos (revision ") else {
        return false;
    };
    let end = rest.bytes().take_while(u8::is_ascii_digit).count();
    end > 0 && &rest[end..] == ")"
}
fn regex_line_end(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}
fn xml_attribute(text: &str) -> String {
    text.replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}
