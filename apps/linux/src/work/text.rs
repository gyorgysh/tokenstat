// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Foundation's work-key, whitespace, control and Character boundary rules.

use unicode_normalization::UnicodeNormalization;
use unicode_properties::{GeneralCategory, UnicodeGeneralCategory};

/// Swift String comparisons preserve canonical equivalence without rewriting
/// the stored identifiers or their percent-encoded representation.
pub fn equal(a: &str, b: &str) -> bool {
    a.nfc().eq(b.nfc())
}

/// Foundation includes zero-width space in whitespacesAndNewlines.
pub fn trim(value: &str) -> &str {
    value.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
}

/// Format controls are rejected by source pin labels and identifiers too.
pub fn has_controls(value: &str) -> bool {
    value.chars().any(|c| {
        matches!(
            c.general_category(),
            GeneralCategory::Control | GeneralCategory::Format
        )
    })
}

/// Foundation emits non-ASCII scalars as UTF-8 escapes even when its supplied
/// CharacterSet includes those letters or combining marks.
pub fn encode(value: &str) -> String {
    let mut result = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() {
            result.push(byte as char);
        } else {
            result.push_str(&format!("%{byte:02X}"));
        }
    }
    result
}
