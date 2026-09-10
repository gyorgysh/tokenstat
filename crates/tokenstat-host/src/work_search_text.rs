// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Canonical Unicode search keys and original-text excerpts. Folded text is
//! for matching only, never shown or used as an accessibility label.

use unicase::UniCase;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

use crate::work_search::{Highlight, MAX_EXCERPT_CHARACTERS};

pub fn normalize(text: &str) -> String {
    let decomposed: String = text.nfd().collect();
    UniCase::new(decomposed).to_folded_case().nfc().collect()
}

pub fn terms(query: &str) -> Vec<String> {
    let mut result = Vec::new();
    for word in query.split_whitespace() {
        let word = normalize(word);
        if !word.is_empty() && !result.contains(&word) {
            result.push(word);
        }
    }
    result
}

pub fn excerpt(original: &str, terms: &[String]) -> (String, Vec<Highlight>) {
    let graphemes: Vec<&str> = original.graphemes(true).collect();
    let mut folded = String::new();
    let mut offsets = vec![0];
    for grapheme in &graphemes {
        folded.push_str(&normalize(grapheme));
        offsets.push(folded.len());
    }
    let matches: Vec<_> = terms
        .iter()
        .filter(|term| !term.is_empty())
        .filter_map(|term| {
            folded.find(term).map(|start| {
                let end = start + term.len();
                let first = offsets
                    .partition_point(|value| *value <= start)
                    .saturating_sub(1);
                let last = offsets
                    .partition_point(|value| *value < end)
                    .min(graphemes.len());
                first..last
            })
        })
        .collect();
    let first = matches.iter().map(|range| range.start).min().unwrap_or(0);
    let mut start = first.saturating_sub(48);
    let earliest = start.saturating_sub(24);
    while start > earliest && !graphemes[start - 1].chars().all(char::is_whitespace) {
        start -= 1;
    }
    if start == earliest && start > 0 && !graphemes[start - 1].chars().all(char::is_whitespace) {
        start = first.saturating_sub(48);
    }
    let prefix = usize::from(start > 0);
    let mut end = graphemes.len().min(start + MAX_EXCERPT_CHARACTERS - prefix);
    if end < graphemes.len() {
        end -= 1;
    }
    // A single grapheme may contain arbitrarily many combining marks.
    // Never split it, and never let it create an unbounded wire excerpt.
    let mut bytes = prefix * "…".len();
    for (index, grapheme) in graphemes.iter().enumerate().take(end).skip(start) {
        if bytes + grapheme.len() + "…".len() > 16 * 1024 {
            end = index;
            break;
        }
        bytes += grapheme.len();
    }
    let mut text = if prefix == 1 {
        "…".to_string()
    } else {
        String::new()
    };
    text.push_str(&graphemes[start..end].concat());
    if end < graphemes.len() {
        text.push('…');
    }
    let mut ranges: Vec<_> = matches
        .into_iter()
        .filter_map(|range| {
            let lower = range.start.max(start);
            let upper = range.end.min(end);
            (lower < upper).then_some(lower..upper)
        })
        .collect();
    let visible = &folded[offsets[start]..offsets[end]];
    for term in terms.iter().filter(|term| !term.is_empty()) {
        for (position, _) in visible.match_indices(term.as_str()) {
            let lower = offsets
                .partition_point(|offset| *offset <= offsets[start] + position)
                .saturating_sub(1);
            let upper = offsets
                .partition_point(|offset| *offset < offsets[start] + position + term.len())
                .min(end);
            ranges.push(lower..upper);
        }
    }
    ranges.sort_by_key(|range| range.start);
    let mut merged: Vec<std::ops::Range<usize>> = Vec::new();
    for range in ranges {
        if let Some(previous) = merged
            .last_mut()
            .filter(|previous| previous.end >= range.start)
        {
            previous.end = previous.end.max(range.end);
        } else {
            merged.push(range);
        }
    }
    let highlights = merged
        .into_iter()
        .map(|range| Highlight {
            location: prefix
                + graphemes[start..range.start]
                    .iter()
                    .map(|s| s.encode_utf16().count())
                    .sum::<usize>(),
            length: graphemes[range]
                .iter()
                .map(|s| s.encode_utf16().count())
                .sum(),
        })
        .collect();
    (text, highlights)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_and_offsets_preserve_original_unicode() {
        assert_eq!(normalize("CAFÉ"), normalize("Cafe\u{301}"));
        assert_eq!(normalize("Straße"), normalize("STRASSE"));
        assert_eq!(normalize("Σςσ"), "σσσ");
        let original = "👩🏽‍💻 Cafe\u{301}, CAFÉ and Straße.";
        let (text, highlights) = excerpt(original, &terms("café STRASSE"));
        assert_eq!(text, original);
        let utf16: Vec<_> = text.encode_utf16().collect();
        let matches: Vec<_> = highlights
            .iter()
            .map(|range| {
                String::from_utf16(&utf16[range.location..range.location + range.length]).unwrap()
            })
            .collect();
        assert_eq!(matches, ["Cafe\u{301}", "CAFÉ", "Straße"]);
        assert_eq!(
            excerpt("ß", &terms("s ss")).1,
            vec![Highlight {
                location: 0,
                length: 1
            }]
        );
        assert_eq!(terms(".* [x] OR"), [".*", "[x]", "or"]);
    }

    #[test]
    fn excerpts_are_bounded_without_splitting_graphemes() {
        let source = format!("{} needle {}", "👩🏽‍💻".repeat(300), "e\u{301}".repeat(300));
        let (text, highlights) = excerpt(&source, &terms("needle"));
        assert_eq!(text.graphemes(true).count(), 240);
        assert!(text.starts_with('…') && text.ends_with('…'));
        assert_eq!(highlights.len(), 1);
        let (oversized, _) = excerpt(&format!("a{}", "\u{301}".repeat(20_000)), &[]);
        assert_eq!(oversized, "…");
        assert_eq!(excerpt("", &[]), (String::new(), vec![]));
    }
}
