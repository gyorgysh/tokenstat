// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Unsent writing is user data. Keep the original record/key semantics, stable
//! message IDs and conditional clearing independently of the active account.

pub mod coordination;
pub mod service;
pub mod storage;
#[cfg(test)]
mod tests;

use crate::work::{Reference, Scope, continuity::Date, text};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// All account/host/conversation records share one non-evicting user-data file.
pub type Records = BTreeMap<String, Draft>;
/// Original attachment IDs compare like Swift strings, including canonical
/// Unicode equivalence. Retention callers must use this membership operation
/// rather than converting the IDs to a byte-comparing string set.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(transparent)]
pub struct AttachmentIds(BTreeSet<String>);
impl AttachmentIds {
    /// The stored spelling stays intact while membership uses canonical equality.
    pub fn contains(&self, id: &str) -> bool {
        self.0.iter().any(|held| text::equal(held, id))
    }
    /// Count unique original IDs using the same equality as membership.
    pub fn len(&self) -> usize {
        self.0.len()
    }
    /// Whether any current or persisted draft protects an original.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    fn insert(&mut self, id: &str) {
        if !self.contains(id) {
            self.0.insert(id.into());
        }
    }
}
impl FromIterator<String> for AttachmentIds {
    fn from_iter<T: IntoIterator<Item = String>>(iter: T) -> Self {
        let mut ids = Self::default();
        for id in iter {
            ids.insert(&id);
        }
        ids
    }
}
impl PartialEq for AttachmentIds {
    fn eq(&self, other: &Self) -> bool {
        self.len() == other.len() && self.0.iter().all(|id| other.contains(id))
    }
}
impl Eq for AttachmentIds {}
/// Attachment metadata stays with the words; no attachment file is opened here.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub id: String,
    pub name: String,
    pub media_type: Option<String>,
    pub size: Option<u64>,
    pub tool_call_id: Option<String>,
}
impl PartialEq for Attachment {
    fn eq(&self, other: &Self) -> bool {
        text::equal(&self.id, &other.id)
            && text::equal(&self.name, &other.name)
            && optional_equal(&self.media_type, &other.media_type)
            && self.size == other.size
            && optional_equal(&self.tool_call_id, &other.tool_call_id)
    }
}
impl Eq for Attachment {}
fn optional_equal(a: &Option<String>, b: &Option<String>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => text::equal(a, b),
        (None, None) => true,
        _ => false,
    }
}
/// Codable Date keeps the source 2001 epoch; text is never normalized on disk.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Draft {
    pub reference: Reference,
    pub text: String,
    pub attachments: Vec<Attachment>,
    pub updated_at: Date,
    #[serde(rename = "messageId")]
    pub message_id: Option<String>,
}
impl PartialEq for Draft {
    fn eq(&self, other: &Self) -> bool {
        self.reference == other.reference
            && text::equal(&self.text, &other.text)
            && self.attachments == other.attachments
            && self.updated_at == other.updated_at
            && optional_equal(&self.message_id, &other.message_id)
    }
}
impl Draft {
    /// Whitespace alone removes a record; an attachment alone still holds work.
    pub fn is_empty(&self) -> bool {
        text::trim(&self.text).is_empty() && self.attachments.is_empty()
    }
}
/// Captured changes merge into current storage, never a stale memory snapshot.
#[derive(Clone, Debug)]
pub enum Mutation {
    Save(Draft),
    Remove,
    RemoveIfMatches(Draft),
}
impl Mutation {
    pub(crate) fn apply(&self, key: &str, records: &mut Records) {
        match self {
            Self::Save(draft) => {
                records.insert(key.into(), draft.clone());
            }
            Self::Remove => {
                records.remove(key);
            }
            Self::RemoveIfMatches(expected) => {
                if records.get(key) == Some(expected) {
                    records.remove(key);
                }
            }
        }
    }
}
/// Memory changes are immediate after registration; the serialized writer owns IO.
#[derive(Clone, Debug, Default)]
pub struct Model {
    records: Records,
    pub occupied: BTreeSet<String>,
}
impl Model {
    /// Restore a validated snapshot and derive its separate mark membership.
    pub fn from_records(records: Records) -> Self {
        Self {
            occupied: records.keys().cloned().collect(),
            records,
        }
    }
    /// Current unsent writing, independent of pending disk IO.
    pub fn records(&self) -> &Records {
        &self.records
    }
    /// Look up the complete captured record used for safe send acceptance.
    pub fn draft(&self, reference: &Reference) -> Option<&Draft> {
        self.records.get(&reference.conversation_key()?)
    }
    /// A cheap membership fact; no file access occurs while rendering a row.
    pub fn has_draft(&self, reference: &Reference) -> bool {
        reference
            .conversation_key()
            .is_some_and(|key| self.occupied.contains(&key))
    }
    /// Mint a new delivery ID only for new work, legacy drafts or an explicit new message.
    pub fn save(
        &mut self,
        reference: Reference,
        words: String,
        attachments: Vec<Attachment>,
        at: Date,
        new_message: bool,
    ) -> anyhow::Result<Option<(String, Mutation)>> {
        let Some(key) = reference.conversation_key() else {
            return Ok(None);
        };
        let message_id = match (!new_message)
            .then(|| {
                self.records
                    .get(&key)
                    .and_then(|draft| draft.message_id.clone())
            })
            .flatten()
        {
            Some(id) => Some(id),
            None => Some(storage::uuid()?),
        };
        let draft = Draft {
            reference,
            text: words,
            attachments,
            updated_at: at,
            message_id,
        };
        if draft.is_empty() {
            return Ok(self.clear(&draft.reference));
        }
        if !new_message
            && self.records.get(&key).is_some_and(|old| {
                text::equal(&old.text, &draft.text) && old.attachments == draft.attachments
            })
        {
            return Ok(None);
        }
        self.records.insert(key.clone(), draft.clone());
        self.occupied.insert(key.clone());
        Ok(Some((key, Mutation::Save(draft))))
    }
    /// Explicitly clear this conversation's memory and capture its deletion.
    pub fn clear(&mut self, reference: &Reference) -> Option<(String, Mutation)> {
        let key = reference.conversation_key()?;
        self.records.remove(&key)?;
        self.occupied.remove(&key);
        Some((key, Mutation::Remove))
    }
    /// Send acceptance cannot clear text edited in another window meanwhile.
    pub fn clear_expected(&mut self, expected: &Draft) -> Option<(String, Mutation)> {
        let key = expected.reference.conversation_key()?;
        if self.records.get(&key) != Some(expected) {
            return None;
        }
        self.records.remove(&key);
        self.occupied.remove(&key);
        Some((key, Mutation::RemoveIfMatches(expected.clone())))
    }
    /// Scope-specific writing, newest first, without retiring other accounts.
    pub fn in_scope(&self, scope: &Scope) -> Vec<&Draft> {
        let mut drafts = self
            .records
            .values()
            .filter(|draft| &draft.reference.scope == scope)
            .collect::<Vec<_>>();
        drafts.sort_by(|a, b| b.updated_at.0.total_cmp(&a.updated_at.0));
        drafts
    }
    /// Protect both unsaved memory references and the last persisted originals.
    pub fn protected_attachments(
        &self,
        stored: &Records,
        scope: &Scope,
    ) -> BTreeMap<String, AttachmentIds> {
        let mut result: BTreeMap<String, AttachmentIds> = BTreeMap::new();
        for draft in self
            .records
            .values()
            .chain(stored.values())
            .filter(|draft| &draft.reference.scope == scope)
        {
            if let Some(key) = draft.reference.conversation_key() {
                let ids = result.entry(key).or_default();
                for attachment in &draft.attachments {
                    ids.insert(&attachment.id);
                }
            }
        }
        result
    }
    /// Union current and persisted references before reviewing original bytes.
    pub fn referenced_attachments(&self, stored: &Records, reference: &Reference) -> AttachmentIds {
        let Some(key) = reference.conversation_key() else {
            return AttachmentIds::default();
        };
        let mut ids = AttachmentIds::default();
        for attachment in self
            .records
            .get(&key)
            .into_iter()
            .chain(stored.get(&key))
            .flat_map(|draft| &draft.attachments)
        {
            ids.insert(&attachment.id);
        }
        ids
    }
}
