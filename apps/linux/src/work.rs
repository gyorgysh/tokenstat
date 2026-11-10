// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Identifier-only work routing. Scope construction and durable stores are
//! separate from these records and the Home projection that consumes them.

pub mod continuity;
pub mod destination;
pub mod pins;
pub mod preferences;
mod scope;
pub mod service;
#[cfg(test)]
mod tests;
pub mod text;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Local work must never join an account's continuity records after sign-in.
pub enum ScopeKind {
    Account,
    Local,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
/// Scope components preserve the owner independently of the current helper's
/// lifetime. Constructors and pin validation live in the scope module.
pub struct Scope {
    pub kind: ScopeKind,
    pub origin: String,
    pub identity: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Keep all source kinds even where Home deliberately declines an open action.
pub enum Kind {
    Workspace,
    Conversation,
    Terminal,
    Commit,
    SavedDiff,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// A destination contains identifiers only. Its current labels live elsewhere.
pub struct Reference {
    pub scope: Scope,
    pub host_identity: String,
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
    pub kind: Kind,
    #[serde(rename = "itemId")]
    pub item_id: Option<String>,
    pub anchor: Option<String>,
}

impl Reference {
    /// A conversation key is shared with draft and reading-position stores.
    pub fn conversation_key(&self) -> Option<String> {
        if self.kind != Kind::Conversation
            || self.host_identity.is_empty()
            || self.workspace_id.is_empty()
            || self.item_id.as_ref().is_none_or(|s| s.is_empty())
        {
            return None;
        }
        Some(format!(
            "{}{}",
            self.folder_key(),
            text::encode(self.item_id.as_deref().unwrap_or_default())
        ))
    }
    /// Folder prefixes end in a separator that cannot occur in an identifier.
    pub fn folder_key(&self) -> String {
        format!(
            "{}|{}|{}|",
            self.scope.storage_key(),
            text::encode(&self.host_identity),
            text::encode(&self.workspace_id)
        )
    }
    /// A reading anchor does not change which saved shortcut it names.
    pub fn same_pin(&self, other: &Self) -> bool {
        self.scope == other.scope
            && text::equal(&self.host_identity, &other.host_identity)
            && text::equal(&self.workspace_id, &other.workspace_id)
            && self.kind == other.kind
            && (self.kind == Kind::Workspace || optional_equal(&self.item_id, &other.item_id))
    }
}

fn optional_equal(a: &Option<String>, b: &Option<String>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => text::equal(a, b),
        (None, None) => true,
        _ => false,
    }
}
impl PartialEq for Scope {
    fn eq(&self, other: &Self) -> bool {
        self.kind == other.kind
            && text::equal(&self.origin, &other.origin)
            && text::equal(&self.identity, &other.identity)
    }
}
impl Eq for Scope {}
impl std::hash::Hash for Scope {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        use unicode_normalization::UnicodeNormalization;
        self.kind.hash(state);
        self.origin.nfc().collect::<String>().hash(state);
        self.identity.nfc().collect::<String>().hash(state);
    }
}
impl PartialEq for Reference {
    fn eq(&self, other: &Self) -> bool {
        self.same_pin(other)
            && optional_equal(&self.item_id, &other.item_id)
            && optional_equal(&self.anchor, &other.anchor)
    }
}
impl Eq for Reference {}
impl std::hash::Hash for Reference {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        use unicode_normalization::UnicodeNormalization;
        self.scope.hash(state);
        self.kind.hash(state);
        for field in [&self.host_identity, &self.workspace_id] {
            field.nfc().collect::<String>().hash(state);
        }
        for field in [&self.item_id, &self.anchor] {
            field
                .as_ref()
                .map(|s| s.nfc().collect::<String>())
                .hash(state);
        }
    }
}
