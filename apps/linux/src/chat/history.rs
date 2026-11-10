// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! ChatHistoryWindow's visible/looped rules and per-window order/disclosures.
//! Transcript preview selection remains with the unported preview owner.

use super::Conversation;
use crate::{localization, sidebar::Snapshot, work::text};
use std::{
    collections::{HashMap, HashSet},
    ops::Range,
};
use unicode_normalization::UnicodeNormalization;

/// The source's compact sidebar leaves room for other live work.
pub const COLLAPSED_LIMIT: usize = 5;
/// The older archive belongs to the full chat overview rather than this list.
pub const INLINE_LIMIT: usize = 10;

/// A selection outside the first five stays visible in a window of at most ten.
pub fn visible(count: usize, selected: Option<usize>, expanded: bool) -> Range<usize> {
    if let Some(s) = selected.filter(|s| *s < count)
        && (expanded || s >= COLLAPSED_LIMIT)
    {
        if count <= INLINE_LIMIT {
            return 0..count;
        }
        if s < INLINE_LIMIT {
            return 0..INLINE_LIMIT;
        }
        let start = (s - 4).min(count - INLINE_LIMIT);
        return start..start + INLINE_LIMIT;
    }
    0..count.min(if expanded {
        INLINE_LIMIT
    } else {
        COLLAPSED_LIMIT
    })
}
/// Conversation shortcuts loop only the warm ten; search owns the older archive.
pub fn looped(count: usize, current: Option<usize>, step: i32) -> Option<usize> {
    let bound = count.min(INLINE_LIMIT);
    if bound == 0 || ![-1, 1].contains(&step) {
        return None;
    }
    match current.filter(|current| *current < bound) {
        Some(current) => Some((current as i32 + step + bound as i32) as usize % bound),
        None => Some(if step > 0 { 0 } else { bound - 1 }),
    }
}
fn key(value: &str) -> String {
    value.nfc().collect()
}
/// Preserve existing rows under the pointer, appending newly arrived chats.
pub fn holding_order<'a>(
    rows: &'a [Conversation],
    held: Option<&[String]>,
) -> Vec<&'a Conversation> {
    let Some(held) = held else {
        return rows.iter().collect();
    };
    let mut rank = HashMap::new();
    for (index, id) in held.iter().enumerate() {
        rank.entry(key(id)).or_insert(index);
    }
    let mut known = rows
        .iter()
        .filter(|row| rank.contains_key(&key(&row.id)))
        .collect::<Vec<_>>();
    known.sort_by_key(|row| rank[&key(&row.id)]);
    known.extend(rows.iter().filter(|row| !rank.contains_key(&key(&row.id))));
    known
}

/// Device preferences initialize each window once, retaining explicit early input.
#[derive(Default)]
pub struct State {
    expanded: HashSet<String>,
    early: HashMap<String, bool>,
    initialized: bool,
    held: HashMap<String, Vec<String>>,
}
impl State {
    /// Late device IO may initialize the window but cannot reverse early input.
    pub fn initialize(&mut self, snapshot: &Snapshot) {
        if self.initialized {
            return;
        }
        self.expanded = snapshot
            .expanded_ids("history:")
            .iter()
            .map(|id| key(id))
            .collect();
        self.initialized = true;
        for (id, expanded) in std::mem::take(&mut self.early) {
            self.set_expanded(&id, expanded);
        }
    }
    /// Swift String identity also applies to stored disclosure IDs.
    pub fn expanded(&self, folder: &str) -> bool {
        self.expanded.contains(&key(folder))
    }
    /// Keep explicit choices while the initial preference worker is pending.
    pub fn set_expanded(&mut self, folder: &str, expanded: bool) {
        let id = key(folder);
        if !self.initialized {
            self.early.insert(id.clone(), expanded);
        }
        if expanded {
            self.expanded.insert(id);
        } else {
            self.expanded.remove(&id);
        }
    }
    /// A held list affects pointer stability, not live keyboard order.
    pub fn held(&self, folder: &str) -> Option<&[String]> {
        self.held.get(&key(folder)).map(Vec::as_slice)
    }
    /// Remember the actual drawn order at pointer entry.
    pub fn hold(&mut self, folder: &str, rows: &[String]) {
        self.held.insert(key(folder), rows.to_vec());
    }
    /// Pointer exit or list disappearance restores incoming order.
    pub fn release(&mut self, folder: &str) {
        self.held.remove(&key(folder));
    }
    /// Retiring a private owner cannot leave order held for the next account.
    pub fn release_all(&mut self) {
        self.held.clear();
    }
    /// A disappearing list cannot leave hover order held while off screen.
    pub fn retain_holds(&mut self, folders: &[String]) {
        self.held
            .retain(|folder, _| folders.iter().any(|id| text::equal(id, folder)));
    }
}

/// CompactAge uses the last message, with setup-update time as its fallback.
pub fn age(ms: i64, now_ms: i64) -> String {
    if ms <= 0 {
        return String::new();
    }
    let seconds = (now_ms as f64 - ms as f64) / 1000.;
    let (key, unit) = if seconds < 60. {
        return localization::text("apple.compactage.now.ed5eb9a3", &[]);
    } else if seconds < 3600. {
        ("apple.compactage.0_m.7f5ea983", 60.)
    } else if seconds < 86400. {
        ("apple.compactage.0_h.360a8af5", 3600.)
    } else if seconds < 86400. * 14. {
        ("apple.compactage.0_d.6c61dd03", 86400.)
    } else if seconds < 86400. * 365. {
        ("apple.compactage.0_w.f5fe75d1", 86400. * 7.)
    } else {
        ("apple.compactage.0_y.2956709f", 86400. * 365.)
    };
    localization::text(key, &[&(seconds / unit).trunc().to_string()])
}
/// Turn starts are first-observed stamps, never inferred from setup timestamps.
pub fn elapsed(start_ms: i64, now_ms: i64) -> String {
    let seconds = ((now_ms as i128 - start_ms as i128) / 1000).max(0);
    if seconds < 60 {
        return localization::text("apple.chatturntiming.0_s.c4c041f8", &[&seconds.to_string()]);
    }
    let minutes = seconds / 60;
    if minutes < 60 {
        return localization::text("apple.chatturntiming.0_m.7f5ea983", &[&minutes.to_string()]);
    }
    let hours = minutes / 60;
    let rest = minutes % 60;
    if rest == 0 {
        localization::text("apple.chatturntiming.0_h.360a8af5", &[&hours.to_string()])
    } else {
        localization::text(
            "apple.chatturntiming.0_h_1_m.d426ce3b",
            &[&hours.to_string(), &rest.to_string()],
        )
    }
}
/// Selected empty conversations stay drawn; absent draft facts remain unknown.
pub fn shown(row: &Conversation, selected: Option<&str>, has_draft: Option<bool>) -> bool {
    selected.is_some_and(|id| text::equal(id, &row.id)) || row.unused(has_draft) != Some(true)
}
