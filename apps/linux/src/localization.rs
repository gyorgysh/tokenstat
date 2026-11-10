// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Use the same copy and placeholder rules as the SwiftUI desktop.

use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;

/// Platform tables override common copy, with the first available preferred locale.
pub struct LanguageCatalog {
    strings: HashMap<String, String>,
}

impl LanguageCatalog {
    /// Synthetic catalogs use the same path as translated tables and parity fixtures.
    pub fn from_strings(strings: HashMap<String, String>) -> Self {
        Self { strings }
    }

    /// A bundled English fallback works before any optional locale is installed.
    pub fn english() -> Self {
        let mut strings: HashMap<String, String> =
            serde_json::from_str(include_str!("../../localization/en/common.json"))
                .unwrap_or_default();
        let apple: HashMap<String, String> =
            serde_json::from_str(include_str!("../../localization/en/apple.json"))
                .unwrap_or_default();
        strings.extend(apple);
        Self { strings }
    }

    /// Missing tables behave like the existing desktop catalog, preserving English.
    pub fn from_directory(directory: &Path, languages: &[&str]) -> Self {
        let load = |language: &str| -> HashMap<String, String> {
            let mut result = HashMap::new();
            for table in ["common", "apple"] {
                if let Ok(text) =
                    std::fs::read_to_string(directory.join(language).join(format!("{table}.json")))
                    && let Ok(values) = serde_json::from_str::<HashMap<String, String>>(&text)
                {
                    result.extend(values);
                }
            }
            result
        };
        let mut strings = load("en");
        for language in languages {
            let normalized = language.replace('_', "-");
            let components: Vec<_> = normalized.split('-').collect();
            // Locale tags are directory names, never paths supplied by content.
            if components
                .iter()
                .any(|part| part.is_empty() || !part.chars().all(|c| c.is_ascii_alphanumeric()))
            {
                continue;
            }
            let mut translated = HashMap::new();
            for count in 1..=components.len() {
                translated.extend(load(&components[..count].join("-")));
            }
            if !translated.is_empty() {
                strings.extend(translated);
                break;
            }
        }
        Self { strings }
    }

    /// Replace only original numbered placeholders. Inserted values remain literal.
    pub fn text(&self, key: &str, arguments: &[&str]) -> String {
        let template = self.strings.get(key).map(String::as_str).unwrap_or(key);
        interpolate(template, arguments)
    }

    /// Inventory checks use this to distinguish missing copy from an empty label.
    pub fn contains(&self, key: &str) -> bool {
        self.strings.contains_key(key)
    }
}

/// Shared English copy is the initial desktop language, matching the other clients.
pub fn text(key: &str, arguments: &[&str]) -> String {
    static ENGLISH: OnceLock<LanguageCatalog> = OnceLock::new();
    ENGLISH
        .get_or_init(LanguageCatalog::english)
        .text(key, arguments)
}

fn interpolate(template: &str, arguments: &[&str]) -> String {
    let mut result = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        result.push_str(&rest[..start]);
        rest = &rest[start..];
        if let Some(end) = rest.find('}') {
            let token = &rest[1..end];
            if !token.is_empty()
                && token.bytes().all(|b| b.is_ascii_digit())
                && let Ok(index) = token.parse::<usize>()
                && let Some(value) = arguments.get(index)
            {
                result.push_str(value);
                rest = &rest[end + 1..];
                continue;
            }
        }
        result.push('{');
        rest = &rest[1..];
    }
    result.push_str(rest);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insertion_is_literal_and_preserves_nonplaceholder_syntax() {
        assert_eq!(
            interpolate("{1} {0} {1} %1$@ {4} {{0}}", &["{1}", "東京 $HOME"]),
            "東京 $HOME {1} 東京 $HOME %1$@ {4} {{1}}"
        );
        assert_eq!(
            interpolate("broken {x} {01} end {", &["a", "b"]),
            "broken {x} b end {"
        );
    }

    #[test]
    fn regional_overrides_use_the_first_available_preference() {
        let root = tempfile::tempdir().unwrap();
        for (locale, table, value) in [
            ("en", "common", r#"{"common.home":"Home"}"#),
            ("hu", "common", r#"{"test":"base","baseOnly":"kept"}"#),
            ("hu-HU", "apple", r#"{"test":"region"}"#),
            ("de", "common", r#"{"test":"second"}"#),
        ] {
            let path = root.path().join(locale);
            std::fs::create_dir_all(&path).unwrap();
            std::fs::write(path.join(format!("{table}.json")), value).unwrap();
        }
        let catalog = LanguageCatalog::from_directory(root.path(), &["missing", "hu_HU", "de"]);
        assert_eq!(catalog.text("test", &[]), "region");
        assert_eq!(catalog.text("baseOnly", &[]), "kept");
        assert_eq!(catalog.text("common.home", &[]), "Home");
    }
}
