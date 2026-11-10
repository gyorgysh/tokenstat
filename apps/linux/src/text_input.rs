// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Single-line editor state. Platform IME ranges are UTF-16; shaping and Rust
//! slicing use UTF-8. No platform range may split a scalar or panic a field.

use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Snapshot {
    text: String,
    anchor: usize,
    cursor: usize,
}

#[derive(Clone, Debug)]
/// Editing state belongs to a field, independently of its rendering/focus.
pub struct Input {
    text: String,
    anchor: usize,
    cursor: usize,
    pub marked: Option<Range<usize>>,
    composition: Option<Snapshot>,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
}
impl Input {
    /// Callers cannot mutate text without updating byte ranges and undo state.
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn new(text: String) -> Self {
        let end = text.len();
        Self {
            text,
            anchor: end,
            cursor: end,
            marked: None,
            composition: None,
            undo: Vec::new(),
            redo: Vec::new(),
        }
    }
    pub fn selection(&self) -> Range<usize> {
        self.anchor.min(self.cursor)..self.anchor.max(self.cursor)
    }
    pub fn cursor(&self) -> usize {
        self.cursor
    }
    pub fn reversed(&self) -> bool {
        self.cursor < self.anchor
    }
    pub fn select(&mut self, anchor: usize, cursor: usize) {
        self.anchor = boundary(&self.text, anchor);
        self.cursor = boundary(&self.text, cursor);
    }
    pub fn select_all(&mut self) {
        self.unmark();
        self.select(0, self.text.len());
    }
    pub fn selected(&self) -> &str {
        &self.text[self.selection()]
    }
    pub fn to_utf16(&self, range: Range<usize>) -> Range<usize> {
        utf16(&self.text, range.start)..utf16(&self.text, range.end)
    }
    pub fn from_utf16(&self, range: Range<usize>) -> Range<usize> {
        from_utf16(&self.text, range)
    }
    fn snapshot(&self) -> Snapshot {
        Snapshot {
            text: self.text.clone(),
            anchor: self.anchor,
            cursor: self.cursor,
        }
    }
    fn restore(&mut self, state: Snapshot) {
        self.text = state.text;
        self.anchor = state.anchor;
        self.cursor = state.cursor;
        self.marked = None;
        self.composition = None;
    }
    fn target(&self, range: Option<Range<usize>>) -> Range<usize> {
        range
            .map(|r| self.from_utf16(r))
            .or_else(|| self.marked.clone())
            .unwrap_or_else(|| self.selection())
    }
    /// An IME commit is one undo step, even after many marked replacements.
    pub fn replace(&mut self, range: Option<Range<usize>>, value: &str) {
        let before = self.composition.take().unwrap_or_else(|| self.snapshot());
        let range = self.target(range);
        self.text.replace_range(range.clone(), value);
        self.select(range.start + value.len(), range.start + value.len());
        self.marked = None;
        if before.text != self.text {
            self.undo.push(before);
            self.redo.clear();
        }
    }
    /// The selected range is relative to the newly inserted marked text,
    /// rather than the old document or the old replacement range's end.
    pub fn replace_marked(
        &mut self,
        range: Option<Range<usize>>,
        value: &str,
        selection: Option<Range<usize>>,
    ) {
        if self.composition.is_none() {
            self.composition = Some(self.snapshot());
        }
        let range = self.target(range);
        self.text.replace_range(range.clone(), value);
        self.marked = (!value.is_empty()).then_some(range.start..range.start + value.len());
        let selected = selection
            .map(|r| from_utf16(value, r))
            .unwrap_or(value.len()..value.len());
        self.select(range.start + selected.start, range.start + selected.end);
    }
    pub fn unmark(&mut self) {
        if let Some(before) = self.composition.take()
            && before.text != self.text
        {
            self.undo.push(before);
            self.redo.clear();
        }
        self.marked = None;
    }
    pub fn undo(&mut self) {
        self.unmark();
        if let Some(previous) = self.undo.pop() {
            self.redo.push(self.snapshot());
            self.restore(previous);
        }
    }
    pub fn redo(&mut self) {
        self.unmark();
        if let Some(next) = self.redo.pop() {
            self.undo.push(self.snapshot());
            self.restore(next);
        }
    }
    fn step(&self, forward: bool, word: bool) -> usize {
        if word {
            if forward {
                self.text[self.cursor..]
                    .split_word_bound_indices()
                    .find(|(_, s)| s.chars().any(char::is_alphanumeric))
                    .map(|(index, s)| self.cursor + index + s.len())
                    .unwrap_or(self.text.len())
            } else {
                self.text[..self.cursor]
                    .split_word_bound_indices()
                    .rev()
                    .find(|(_, s)| s.chars().any(char::is_alphanumeric))
                    .map(|(index, _)| index)
                    .unwrap_or(0)
            }
        } else if forward {
            self.text[self.cursor..]
                .graphemes(true)
                .next()
                .map(|s| self.cursor + s.len())
                .unwrap_or(self.text.len())
        } else {
            self.text[..self.cursor]
                .grapheme_indices(true)
                .next_back()
                .map(|(i, _)| i)
                .unwrap_or(0)
        }
    }
    pub fn move_cursor(&mut self, forward: bool, extend: bool, word: bool) {
        self.unmark();
        let next = if !extend && !self.selection().is_empty() {
            if forward {
                self.selection().end
            } else {
                self.selection().start
            }
        } else {
            self.step(forward, word)
        };
        if !extend {
            self.anchor = next;
        }
        self.cursor = next;
    }
    pub fn edge(&mut self, end: bool, extend: bool) {
        self.unmark();
        let next = if end { self.text.len() } else { 0 };
        if !extend {
            self.anchor = next;
        }
        self.cursor = next;
    }
    pub fn delete(&mut self, forward: bool, word: bool) {
        self.unmark();
        if self.selection().is_empty() {
            self.cursor = self.step(forward, word);
        }
        self.replace(None, "");
    }
}
fn boundary(text: &str, offset: usize) -> usize {
    let mut offset = offset.min(text.len());
    while !text.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}
fn utf16(text: &str, offset: usize) -> usize {
    text[..boundary(text, offset)].encode_utf16().count()
}
fn byte_at(text: &str, offset: usize, up: bool) -> usize {
    let mut units = 0;
    for (index, scalar) in text.char_indices() {
        if units == offset {
            return index;
        }
        if units + scalar.len_utf16() > offset {
            return if up { index + scalar.len_utf8() } else { index };
        }
        units += scalar.len_utf16();
    }
    text.len()
}
fn from_utf16(text: &str, range: Range<usize>) -> Range<usize> {
    let start = byte_at(text, range.start.min(range.end), false);
    let end = if range.start == range.end {
        start
    } else {
        byte_at(text, range.end.max(range.start), true)
    };
    start..end
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn utf16_ranges_survive_surrogates_combining_marks_and_out_of_bounds_requests() {
        let mut input = Input::new("a🐧e\u{301}終".into());
        assert_eq!(input.from_utf16(2..2), 1..1);
        assert_eq!(input.from_utf16(2..3), 1..5);
        assert_eq!(
            input.from_utf16(999..1000),
            input.text.len()..input.text.len()
        );
        assert_eq!(input.to_utf16(1..5), 1..3);
        input.replace(Some(1..3), "🦀");
        assert_eq!(input.text, "a🦀e\u{301}終");
        input.edge(true, false);
        input.delete(false, false);
        input.delete(false, false);
        assert_eq!(input.text, "a🦀");
        input.undo();
        assert_eq!(input.text, "a🦀e\u{301}");
        input.redo();
        assert_eq!(input.text, "a🦀");
    }
    #[test]
    fn ime_selection_is_relative_to_new_text_and_a_composition_is_one_undo_step() {
        let mut input = Input::new("prefix suffix".into());
        input.select(7, 7);
        input.replace_marked(None, "に", None);
        input.replace_marked(None, "日本🐧", Some(2..4));
        assert_eq!(input.selected(), "🐧");
        assert_eq!(input.to_utf16(input.marked.clone().unwrap()), 7..11);
        input.replace(None, "日本語");
        assert_eq!(input.text, "prefix 日本語suffix");
        input.undo();
        assert_eq!(input.text, "prefix suffix");
        input.redo();
        assert_eq!(input.text, "prefix 日本語suffix");
    }
    #[test]
    fn reverse_selection_and_edit_after_undo_do_not_reuse_a_retired_redo_branch() {
        let mut input = Input::new("árvíz 東京".into());
        input.select(input.text.len(), 0);
        assert!(input.reversed());
        input.replace(None, "one");
        input.undo();
        input.replace(None, "two");
        input.redo();
        assert_eq!(input.text, "two");
        input.edge(true, false);
        input.move_cursor(false, true, true);
        assert_eq!(input.selected(), "two");
    }
    #[test]
    fn selecting_all_commits_marked_text_before_the_next_replacement() {
        let mut input = Input::new("before after".into());
        input.select(7, 7);
        input.replace_marked(None, "日本", None);
        input.select_all();
        input.replace(None, "whole field");
        assert_eq!(input.text, "whole field");
        input.undo();
        assert_eq!(input.text, "before 日本after");
    }
}
