// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The source pin store refuses a ninth pin, retains unavailable work and
//! rereads current preferences before each mutation.

use super::{Kind, Reference, Scope, continuity::Date, preferences::Preferences, text};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use unicode_segmentation::UnicodeSegmentation;

/// A short label belongs to the shortcut, independently of saved-copy retention.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pin {
    pub reference: Reference,
    pub label: String,
    pub folder_name: String,
    pub pinned_at: Date,
}
impl Pin {
    /// Keys intentionally ignore reading anchors and include host/workspace.
    pub fn key(&self) -> Option<String> {
        key(&self.reference)
    }
}

/// Reuse a preferences handle across windows, or independent handles to the
/// same file. Both retain read-modify-write semantics.
#[derive(Clone, Default)]
pub struct Pins {
    pub preferences: Preferences,
}
impl Pins {
    pub const CAPACITY: usize = 8;
    /// Invalid rows are omitted, while malformed encoded arrays read as empty.
    pub fn pins(&self, scope: Option<&Scope>) -> anyhow::Result<Vec<Pin>> {
        self.preferences
            .read(|map| scope.map(|scope| read(map, scope)).unwrap_or_default())
    }
    /// Re-pinning is allowed even when the shelf is full and refreshes labels.
    pub fn pin(
        &self,
        reference: &Reference,
        label: &str,
        folder_name: &str,
        at: Date,
    ) -> anyhow::Result<bool> {
        self.update_pin(reference, label, Some(folder_name), at, true)
    }
    /// Project rename must never recreate a shortcut removed while its host
    /// request was pending. Check/update under one preferences transaction.
    pub fn relabel_if_pinned(
        &self,
        reference: &Reference,
        label: &str,
        folder_name: &str,
        at: Date,
    ) -> anyhow::Result<bool> {
        self.update_pin(reference, label, Some(folder_name), at, false)
    }
    /// Chat rename preserves the latest pinned folder label under the same
    /// transaction that verifies the shortcut still exists.
    pub fn relabel_title_if_pinned(
        &self,
        reference: &Reference,
        label: &str,
        at: Date,
    ) -> anyhow::Result<bool> {
        self.update_pin(reference, label, None, at, false)
    }
    fn update_pin(
        &self,
        reference: &Reference,
        label: &str,
        folder_name: Option<&str>,
        at: Date,
        inserts: bool,
    ) -> anyhow::Result<bool> {
        let Some(key) = key(reference) else {
            return Ok(false);
        };
        self.preferences.update(|map| {
            let mut current = read(map, &reference.scope);
            if let Some(existing) = current
                .iter_mut()
                .find(|p| p.key().is_some_and(|k| text::equal(&k, &key)))
            {
                existing.label = safe_label(label);
                if let Some(folder_name) = folder_name {
                    existing.folder_name = safe_label(folder_name);
                }
                existing.pinned_at = at;
            } else {
                if !inserts || current.len() >= Self::CAPACITY {
                    return Ok(false);
                }
                current.push(Pin {
                    reference: reference.clone(),
                    label: safe_label(label),
                    folder_name: safe_label(folder_name.unwrap_or_default()),
                    pinned_at: at,
                });
            }
            current.sort_by(|a, b| {
                b.pinned_at
                    .0
                    .partial_cmp(&a.pinned_at.0)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            let name = storage_key(&reference.scope);
            match serde_json::to_string(&current) {
                Ok(data) => {
                    map.insert(name, Value::String(data));
                }
                Err(_) => {
                    map.remove(&name);
                }
            }
            Ok(true)
        })
    }
    /// Removing one shortcut never changes offline-cache retention.
    pub fn unpin(&self, reference: &Reference) -> anyhow::Result<()> {
        let Some(key) = key(reference) else {
            return Ok(());
        };
        self.preferences.update(|map| {
            let current: Vec<_> = read(map, &reference.scope)
                .into_iter()
                .filter(|p| p.key().is_none_or(|k| !text::equal(&k, &key)))
                .collect();
            map.insert(
                storage_key(&reference.scope),
                Value::String(serde_json::to_string(&current)?),
            );
            Ok(())
        })
    }
    /// A malformed reference cannot accidentally match another invalid pin.
    pub fn is_pinned(&self, reference: &Reference) -> anyhow::Result<bool> {
        let Some(key) = key(reference) else {
            return Ok(false);
        };
        Ok(self
            .pins(Some(&reference.scope))?
            .iter()
            .any(|p| p.key().is_some_and(|k| text::equal(&k, &key))))
    }
}

/// Source key validation counts Swift Characters, not bytes or scalar values.
pub fn key(reference: &Reference) -> Option<String> {
    if !reference.scope.valid_for_pins()
        || !valid_identifier(&reference.host_identity)
        || !valid_identifier(&reference.workspace_id)
    {
        return None;
    }
    let kind = match reference.kind {
        Kind::Workspace => "workspace",
        Kind::Conversation => "conversation",
        Kind::Terminal => "terminal",
        Kind::Commit => "commit",
        Kind::SavedDiff => "savedDiff",
    };
    let mut fields = vec![
        kind.to_owned(),
        text::encode(&reference.host_identity),
        text::encode(&reference.workspace_id),
    ];
    if reference.kind == Kind::Workspace {
        if reference.item_id.is_some() {
            return None;
        }
    } else {
        let item = reference.item_id.as_ref().filter(|s| valid_identifier(s))?;
        fields.push(text::encode(item));
    }
    Some(fields.join("|"))
}
fn valid_identifier(value: &str) -> bool {
    !value.is_empty() && value.graphemes(true).count() <= 256 && !text::has_controls(value)
}

/// Reject path/command-shaped labels and trim at the same grapheme boundary.
pub fn safe_label(label: &str) -> String {
    let trimmed = text::trim(label);
    if trimmed.is_empty() || trimmed.contains(['/', '\\']) || text::has_controls(trimmed) {
        return crate::localization::text("apple.pinnedwork.pinned_work.23dd8f45", &[]);
    }
    trimmed.graphemes(true).take(80).collect()
}
fn storage_key(scope: &Scope) -> String {
    format!("pinned.work.v1.{}", scope.storage_key())
}
fn read(map: &Map<String, Value>, scope: &Scope) -> Vec<Pin> {
    let Some(data) = map.get(&storage_key(scope)).and_then(Value::as_str) else {
        return vec![];
    };
    let Ok(stored) = serde_json::from_str::<Vec<Pin>>(data) else {
        return vec![];
    };
    let mut seen: Vec<String> = vec![];
    let mut result = vec![];
    for pin in stored {
        let Some(key) = pin.key() else {
            continue;
        };
        if seen.iter().any(|k| text::equal(k, &key)) {
            continue;
        }
        seen.push(key);
        if pin.reference.scope != *scope {
            continue;
        }
        result.push(Pin {
            label: safe_label(&pin.label),
            folder_name: safe_label(&pin.folder_name),
            ..pin
        });
    }
    result.sort_by(|a, b| {
        b.pinned_at
            .0
            .partial_cmp(&a.pinned_at.0)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    result
}
