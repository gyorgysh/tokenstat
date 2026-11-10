// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! ChatRecentMessages: bounded warm display rows, not an event archive or disk
//! cache. The same live row renderer must show these with actions disabled.

use std::collections::{HashMap, HashSet};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

pub const PER_FOLDER_LIMIT: usize = 10;
pub const CONVERSATION_LIMIT: usize = 60;
pub const MESSAGE_LIMIT: usize = 150;
pub const BYTE_LIMIT: usize = 512 * 1024;

fn key(value: &str) -> String {
    value.nfc().collect()
}
fn folder(value: &str) -> &str {
    value.rfind('|').map_or("", |bar| &value[..=bar])
}
fn has_prefix(value: &str, prefix: &str) -> bool {
    value.starts_with(prefix)
        && (prefix.is_empty()
            || prefix.len() == value.len()
            || value
                .grapheme_indices(true)
                .any(|(index, _)| index == prefix.len()))
}
pub struct RecentMessages<Row> {
    entries: HashMap<String, Vec<Row>>,
    order: Vec<String>,
    speculative: HashSet<String>,
}
impl<Row> Default for RecentMessages<Row> {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            order: vec![],
            speculative: HashSet::new(),
        }
    }
}
impl<Row: Clone> RecentMessages<Row> {
    pub fn store(
        &mut self,
        messages: &[Row],
        raw_key: &str,
        speculative: bool,
        cost: impl Fn(&Row) -> i64,
    ) {
        let mut remaining = BYTE_LIMIT;
        let mut kept = vec![];
        for message in messages.iter().rev().take(MESSAGE_LIMIT) {
            let bytes = cost(message).max(0) as u64;
            if bytes > remaining as u64 {
                break;
            }
            kept.push(message.clone());
            remaining -= bytes as usize;
        }
        // A selection retired before its page arrived cannot erase its preview.
        if kept.is_empty() {
            return;
        }
        kept.reverse();
        let key = key(raw_key);
        self.remove(&key);
        self.entries.insert(key.clone(), kept);
        self.order.push(key.clone());
        if speculative {
            self.speculative.insert(key.clone());
        }
        let mut same_folder = self
            .order
            .iter()
            .filter(|k| folder(k) == folder(&key))
            .cloned()
            .collect::<Vec<_>>();
        while same_folder.len() > PER_FOLDER_LIMIT {
            let victim = same_folder
                .iter()
                .find(|k| self.speculative.contains(*k) && **k != key)
                .unwrap_or(&same_folder[0])
                .clone();
            self.remove(&victim);
            same_folder.retain(|k| *k != victim);
        }
        while self.order.len() > CONVERSATION_LIMIT {
            let victim = self
                .order
                .iter()
                .find(|k| self.speculative.contains(*k) && **k != key)
                .unwrap_or(&self.order[0])
                .clone();
            self.remove(&victim);
        }
    }
    pub fn contains(&self, raw_key: &str) -> bool {
        self.entries.contains_key(&key(raw_key))
    }
    pub fn peek(&self, raw_key: &str) -> &[Row] {
        self.entries.get(&key(raw_key)).map_or(&[], Vec::as_slice)
    }
    pub fn messages(&mut self, raw_key: &str) -> Vec<Row> {
        let key = key(raw_key);
        let Some(rows) = self.entries.get(&key) else {
            return vec![];
        };
        self.order.retain(|k| *k != key);
        self.order.push(key.clone());
        self.speculative.remove(&key);
        rows.clone()
    }
    pub fn remove(&mut self, raw_key: &str) {
        let key = key(raw_key);
        self.entries.remove(&key);
        self.order.retain(|k| *k != key);
        self.speculative.remove(&key);
    }
    pub fn retain(&mut self, keys: &HashSet<String>, raw_folder: &str) {
        let keys = keys.iter().map(|k| key(k)).collect::<HashSet<_>>();
        let folder = key(raw_folder);
        let victims = self
            .order
            .iter()
            .filter(|k| has_prefix(k, &folder) && !keys.contains(*k))
            .cloned()
            .collect::<Vec<_>>();
        for victim in victims {
            self.remove(&victim);
        }
    }
    pub fn remove_all(&mut self) {
        self.entries.clear();
        self.order.clear();
        self.speculative.clear();
    }
}
