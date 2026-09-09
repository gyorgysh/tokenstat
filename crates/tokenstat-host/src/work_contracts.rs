// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Identifier-only work references shared with clients. No new remote methods
//! are exposed here; authorization stays with the operation resolving a reference.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WorkReference {
    pub scope: WorkScope,
    pub host_identity: String,
    pub workspace_id: String,
    pub kind: WorkKind,
    pub item_id: Option<String>,
    pub anchor: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct WorkScope {
    pub kind: ScopeKind,
    pub origin: String,
    pub identity: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ScopeKind {
    Account,
    Local,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum WorkKind {
    Workspace,
    Conversation,
    Terminal,
    Commit,
    SavedDiff,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reference_uses_the_client_keys_and_rejects_unknown_kinds() {
        let json = r#"{"scope":{"kind":"account","origin":"https://example.com","identity":"alice"},"hostIdentity":"host-a","workspaceId":"folder","kind":"conversation","itemId":"chat"}"#;
        let reference: WorkReference = serde_json::from_str(json).unwrap();
        assert_eq!(reference.workspace_id, "folder");
        assert_eq!(reference.item_id.as_deref(), Some("chat"));
        let serialized = serde_json::to_value(&reference).unwrap();
        assert_eq!(serialized["workspaceId"], "folder");
        assert_eq!(serialized["itemId"], "chat");
        assert!(
            serde_json::from_str::<WorkReference>(&json.replace("conversation", "execute"))
                .is_err()
        );
    }
}
