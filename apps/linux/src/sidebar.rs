// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Device-local SidebarPreferences semantics. Each disclosure has its own key;
//! unknown values and future sections survive independent mutations.

pub mod service;

use crate::work::{preferences::Preferences, text};
use serde_json::{Map, Value};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// Keep the Swift preference namespace stable as sidebar rows are added.
pub const EXPANSION_PREFIX: &str = "shell.sidebar.expanded.";
/// Known-section moves must retain the original array's future values.
pub const ORDER_KEY: &str = "shell.sidebar.sectionOrder";
/// Missing known sections return in the same stable order as SwiftUI.
pub const DEFAULT_ORDER: [&str; 2] = ["projects", "servers"];

/// A sidebar-only reading is safe to project into independent window state.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    values: Map<String, Value>,
}
impl Snapshot {
    /// A worker captures only the additive sidebar namespace.
    pub fn from_values(values: &Map<String, Value>) -> Self {
        Self {
            values: values
                .iter()
                .filter(|(key, _)| key.starts_with(EXPANSION_PREFIX) || *key == ORDER_KEY)
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect(),
        }
    }
    /// NSNumber integers and strings are not persisted boolean choices.
    pub fn is_expanded(&self, key: &str, fallback: bool) -> bool {
        let key = format!("{EXPANSION_PREFIX}{key}");
        get(&self.values, &key)
            .and_then(Value::as_bool)
            .unwrap_or(fallback)
    }
    /// History and server lists opt in; absent and unsupported values stay shut.
    pub fn expanded_ids(&self, prefix: &str) -> Vec<String> {
        let prefix = format!("{EXPANSION_PREFIX}{prefix}");
        let count = prefix.graphemes(true).count();
        let normalized: String = prefix.nfc().collect();
        let mut ids = self
            .values
            .iter()
            .filter(|(key, value)| {
                key.nfc().collect::<String>().starts_with(&normalized)
                    && value.as_bool() == Some(true)
            })
            .map(|(key, _)| key.graphemes(true).skip(count).collect::<String>())
            .collect::<Vec<_>>();
        ids.sort();
        ids.dedup_by(|a, b| text::equal(a, b));
        ids
    }
    /// Unknown and repeated values stay in storage but never render as sections.
    pub fn section_order(&self) -> Vec<String> {
        let mut order = Vec::new();
        if let Some(raw) = get(&self.values, ORDER_KEY).and_then(Value::as_array) {
            for section in raw.iter().filter_map(Value::as_str) {
                if DEFAULT_ORDER.contains(&section) && !order.iter().any(|s| s == section) {
                    order.push(section.to_owned());
                }
            }
        }
        for section in DEFAULT_ORDER {
            if !order.iter().any(|s| s == section) {
                order.push(section.to_owned());
            }
        }
        order
    }
    /// The UI overlays pending intents without waiting for disk or overwriting
    /// another window's independent local disclosure state.
    pub fn apply(&mut self, mutation: &Mutation) {
        mutation.apply(&mut self.values);
    }
}

/// Capture the intended key or move, never an entire stale preference snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mutation {
    Expansion { key: String, expanded: bool },
    Move { section: String, before: String },
}
impl Mutation {
    /// The source ignores unknown, identical or unsupported section moves.
    pub fn valid(&self) -> bool {
        match self {
            Self::Expansion { .. } => true,
            Self::Move { section, before } => {
                DEFAULT_ORDER.contains(&section.as_str())
                    && DEFAULT_ORDER.contains(&before.as_str())
                    && section != before
            }
        }
    }
    fn property(&self) -> String {
        match self {
            Self::Expansion { key, .. } => format!("{EXPANSION_PREFIX}{key}").nfc().collect(),
            Self::Move { .. } => ORDER_KEY.into(),
        }
    }
    fn apply(&self, values: &mut Map<String, Value>) {
        if !self.valid() {
            return;
        }
        match self {
            Self::Expansion { key, expanded } => {
                insert(
                    values,
                    &format!("{EXPANSION_PREFIX}{key}"),
                    Value::Bool(*expanded),
                );
            }
            Self::Move { section, before } => {
                let mut raw = get(values, ORDER_KEY)
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_else(|| DEFAULT_ORDER.map(|s| Value::String(s.into())).to_vec());
                raw.retain(|v| v.as_str() != Some(section));
                let index = raw
                    .iter()
                    .position(|v| v.as_str() == Some(before))
                    .unwrap_or_else(|| {
                        raw.push(Value::String(before.clone()));
                        raw.len() - 1
                    });
                raw.insert(index, Value::String(section.clone()));
                insert(values, ORDER_KEY, Value::Array(raw));
            }
        }
    }
}
fn get<'a>(values: &'a Map<String, Value>, key: &str) -> Option<&'a Value> {
    values
        .iter()
        .find(|(stored, _)| text::equal(stored, key))
        .map(|(_, value)| value)
}
fn insert(values: &mut Map<String, Value>, key: &str, value: Value) {
    let key = values
        .keys()
        .find(|stored| text::equal(stored, key))
        .cloned()
        .unwrap_or_else(|| key.into());
    values.insert(key, value);
}

/// Sidebar keys share the existing atomic GUI container with other metadata.
#[derive(Clone, Default)]
pub struct Store {
    /// Inject private memory for fixtures or the Linux device-local file.
    pub preferences: Preferences,
}
impl Store {
    /// Blocking storage access belongs to a worker, never a view borrow.
    pub fn read(&self) -> anyhow::Result<Snapshot> {
        self.preferences.read(Snapshot::from_values)
    }
    /// Read current storage under the same lock as the individual key write.
    pub fn mutate(&self, mutation: &Mutation) -> anyhow::Result<Snapshot> {
        if !mutation.valid() {
            return self.read();
        }
        self.preferences.update(|values| {
            mutation.apply(values);
            Ok(Snapshot::from_values(values))
        })
    }
}
