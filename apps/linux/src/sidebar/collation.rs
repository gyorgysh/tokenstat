// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Locale-aware numeric ordering and case/diacritic-insensitive filtering for
//! sidebar names. Platform locale selection and comparison remain subject to
//! same-locale SwiftUI and native Linux validation.

use super::layout::Collation;
use icu_casemap::CaseMapper;
use icu_collator::{
    Collator, CollatorBorrowed, CollatorPreferences, options::CollatorOptions,
    preferences::CollationNumericOrdering,
};
use icu_locale::Locale;
use std::cmp::Ordering;
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

pub struct SidebarCollation {
    ordering: CollatorBorrowed<'static>,
}
impl SidebarCollation {
    /// The compiled ICU provider includes the root locale as a fallback.
    pub fn for_locale(name: &str) -> Self {
        let normalized = name
            .split(['.', '@'])
            .next()
            .unwrap_or("")
            .replace('_', "-");
        let locale = Locale::try_from_str(&normalized).unwrap_or(Locale::UNKNOWN);
        let mut preferences: CollatorPreferences = locale.into();
        preferences.numeric_ordering = Some(CollationNumericOrdering::True);
        let ordering = Collator::try_new(preferences, CollatorOptions::default())
            .expect("compiled ICU collation data includes the root locale");
        Self { ordering }
    }
    pub fn current() -> Self {
        let locale = ["LC_ALL", "LC_COLLATE", "LANG"]
            .into_iter()
            .filter_map(|key| std::env::var(key).ok())
            .find(|value| !value.is_empty())
            .unwrap_or_default();
        Self::for_locale(&locale)
    }
}
fn search_key(value: &str) -> String {
    let folded = CaseMapper::new().fold_string(value);
    folded.nfd().filter(|c| !is_combining_mark(*c)).collect()
}
// Foundation forces an order when collation considers two strings equal. It
// compares encoded spelling, but equal decimal runs prefer fewer leading zeros.
fn forced_order(left: &str, right: &str) -> Ordering {
    let a: Vec<_> = left.encode_utf16().collect();
    let b: Vec<_> = right.encode_utf16().collect();
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if (48..=57).contains(&a[i]) && (48..=57).contains(&b[j]) {
            let (start_i, start_j) = (i, j);
            while i < a.len() && (48..=57).contains(&a[i]) {
                i += 1;
            }
            while j < b.len() && (48..=57).contains(&b[j]) {
                j += 1;
            }
            let order = (i - start_i).cmp(&(j - start_j));
            if order != Ordering::Equal {
                return order;
            }
            let order = a[start_i..i].cmp(&b[start_j..j]);
            if order != Ordering::Equal {
                return order;
            }
        } else {
            let order = a[i].cmp(&b[j]);
            if order != Ordering::Equal {
                return order;
            }
            i += 1;
            j += 1;
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

impl Collation for SidebarCollation {
    fn contains(&self, haystack: &str, needle: &str) -> bool {
        if needle.is_empty() {
            return false;
        }
        let key = search_key(needle);
        if key.is_empty() {
            return haystack.contains(needle);
        }
        search_key(haystack).contains(&key)
    }
    fn compare(&self, left: &str, right: &str) -> Ordering {
        self.ordering
            .compare(left, right)
            .then_with(|| forced_order(left, right))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn numeric_names_canonical_ties_and_casefolded_search() {
        let collation = SidebarCollation::for_locale("en-US");
        assert_eq!(collation.compare("file2", "file10"), Ordering::Less);
        assert_eq!(collation.compare("cafe\u{301}", "café"), Ordering::Less);
        assert!(collation.contains("Straße", "STRASSE"));
        assert!(collation.contains("café", "CAFE"));
        assert!(!collation.contains("æther", "ae"));
        assert!(!collation.contains("alpha", ""));
    }
}
