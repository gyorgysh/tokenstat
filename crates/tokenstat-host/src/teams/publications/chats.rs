// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Chat references use the same durable, private publication journal as their
//! checkout. Transcript bytes remain in the canonical conversation archive.

use super::*;

const MAX_SHARES: usize = 10_000;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in crate::teams) struct ChatShare {
    pub id: String,
    pub checkout_id: String,
    pub conversation_id: String,
    pub request_id: String,
    pub preview: String,
    pub phase: Phase,
    pub revision: u64,
    pub cloud_revision: Option<u64>,
    pub cloud_withdrawn: bool,
}
#[derive(Clone, Copy)]
pub(in crate::teams) struct ChatTarget<'a> {
    pub owner: &'a Owner,
    pub organization: &'a str,
    pub repository: &'a str,
    pub checkout: &'a str,
}
fn parent<'a>(index: &'a Index, target: &ChatTarget<'_>) -> Result<&'a Checkout, DispatchError> {
    index
        .checkouts
        .iter()
        .find(|row| {
            row.owner == *target.owner
                && row.organization_id == target.organization
                && row.repository_id == target.repository
                && row.id == target.checkout
                && row.phase == Phase::Active
        })
        .ok_or_else(not_shared)
}
fn missing() -> DispatchError {
    unavailable(
        "chat_not_shared",
        "This chat is not shared from this checkout.",
    )
}
fn conflict() -> DispatchError {
    unavailable(
        "chat_sharing_changed",
        "This chat's sharing changed. Review it again.",
    )
}
fn reference(value: &str) -> bool {
    value.strip_prefix("share_").is_some_and(|suffix| {
        suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
    })
}
fn digest(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

impl Store {
    pub(in crate::teams) fn local_chats(
        &self,
        target: &ChatTarget<'_>,
    ) -> Result<Vec<ChatShare>, DispatchError> {
        self.local_chat_checkout(target)?;
        self.read(|index| {
            Ok(index
                .chats
                .iter()
                .filter(|row| row.checkout_id == target.checkout)
                .cloned()
                .collect())
        })
    }
    pub(in crate::teams) fn local_chat_checkout(
        &self,
        target: &ChatTarget<'_>,
    ) -> Result<Checkout, DispatchError> {
        self.read(|index| {
            index
                .checkouts
                .iter()
                .find(|row| {
                    row.id == target.checkout
                        && row.owner == *target.owner
                        && row.organization_id == target.organization
                        && row.repository_id == target.repository
                })
                .cloned()
                .ok_or_else(not_shared)
        })
    }
    pub(in crate::teams) fn local_chat(
        &self,
        target: &ChatTarget<'_>,
        id: &str,
    ) -> Result<ChatShare, DispatchError> {
        self.local_chat_checkout(target)?;
        self.read(|index| {
            index
                .chats
                .iter()
                .find(|row| row.id == id && row.checkout_id == target.checkout)
                .cloned()
                .ok_or_else(missing)
        })
    }
    pub(in crate::teams) fn chat_request(
        &self,
        target: &ChatTarget<'_>,
        request: &str,
    ) -> Result<Option<ChatShare>, DispatchError> {
        self.read(|index| {
            parent(index, target)?;
            Ok(index
                .chats
                .iter()
                .find(|row| row.checkout_id == target.checkout && row.request_id == request)
                .cloned())
        })
    }
    pub(in crate::teams) fn confirm_chat_withdrawal(
        &self,
        target: &ChatTarget<'_>,
        id: &str,
    ) -> Result<(), DispatchError> {
        self.local_chat_checkout(target)?;
        self.transaction(|index| {
            let row = index
                .chats
                .iter_mut()
                .find(|row| {
                    row.id == id
                        && row.checkout_id == target.checkout
                        && row.phase == Phase::Withdrawn
                })
                .ok_or_else(missing)?;
            if !row.cloud_withdrawn {
                row.cloud_withdrawn = true;
                row.revision = next_revision(row.revision)?;
            }
            Ok(())
        })
    }
    pub(in crate::teams) fn prepare_chat(
        &self,
        target: &ChatTarget<'_>,
        conversation: &str,
        request: &str,
        preview: &str,
    ) -> Result<ChatShare, DispatchError> {
        if !crate::chat_receipts::valid_id(conversation)
            || !crate::chat_receipts::valid_id(request)
            || !digest(preview)
        {
            return Err(conflict());
        }
        self.transaction(|index| {
            parent(index,target)?;
            if let Some(row) = index.chats.iter().find(|row| row.checkout_id == target.checkout && row.request_id == request) {
                if row.conversation_id != conversation || row.preview != preview || row.phase == Phase::Withdrawn { return Err(conflict()); }
                return Ok(row.clone());
            }
            if index.chats.iter().any(|row| row.conversation_id == conversation && row.phase != Phase::Withdrawn) {
                return Err(unavailable("chat_already_shared", "This chat already has a sharing record. Open its shared view or stop its current sharing first."));
            }
            if index.chats.len() >= MAX_SHARES { return Err(unavailable("chat_sharing_limit", "This computer's chat sharing records have reached their limit.")); }
            let row = ChatShare { id:opaque("share"), checkout_id:target.checkout.into(),conversation_id:conversation.into(),request_id:request.into(),preview:preview.into(),
                phase:Phase::Prepared,revision:1,cloud_revision:None,cloud_withdrawn:false };
            index.chats.push(row.clone()); Ok(row)
        })
    }
    pub(in crate::teams) fn activate_chat(
        &self,
        target: &ChatTarget<'_>,
        id: &str,
        expected: u64,
        cloud_revision: u64,
    ) -> Result<ChatShare, DispatchError> {
        if cloud_revision == 0 || cloud_revision > 9_007_199_254_740_991 {
            return Err(conflict());
        }
        self.transaction(|index| {
            parent(index, target)?;
            let row = index
                .chats
                .iter_mut()
                .find(|row| row.id == id && row.checkout_id == target.checkout)
                .ok_or_else(missing)?;
            if row.phase == Phase::Active
                && (row.revision == expected || expected.checked_add(1) == Some(row.revision))
                && row.cloud_revision == Some(cloud_revision)
            {
                return Ok(row.clone());
            }
            if row.phase != Phase::Prepared || row.revision != expected {
                return Err(conflict());
            }
            row.phase = Phase::Active;
            row.cloud_revision = Some(cloud_revision);
            row.revision = next_revision(row.revision)?;
            Ok(row.clone())
        })
    }
    pub(in crate::teams) fn resolve_chat(
        &self,
        target: &ChatTarget<'_>,
        id: &str,
    ) -> Result<ChatShare, DispatchError> {
        self.read(|index| {
            parent(index, target)?;
            index
                .chats
                .iter()
                .find(|row| {
                    row.checkout_id == target.checkout && row.id == id && row.phase == Phase::Active
                })
                .cloned()
                .ok_or_else(missing)
        })
    }
    pub(in crate::teams) fn withdraw_chat(
        &self,
        target: &ChatTarget<'_>,
        id: &str,
        expected: u64,
    ) -> Result<ChatShare, DispatchError> {
        self.transaction(|index| {
            // Local cleanup remains possible after withdrawing the parent.
            if !index.checkouts.iter().any(|row| {
                row.id == target.checkout
                    && row.owner == *target.owner
                    && row.organization_id == target.organization
                    && row.repository_id == target.repository
            }) {
                return Err(not_shared());
            }
            let row = index
                .chats
                .iter_mut()
                .find(|row| row.id == id && row.checkout_id == target.checkout)
                .ok_or_else(missing)?;
            if row.phase == Phase::Withdrawn {
                return Ok(row.clone());
            }
            if row.revision != expected {
                return Err(conflict());
            }
            row.phase = Phase::Withdrawn;
            row.revision = next_revision(row.revision)?;
            Ok(row.clone())
        })
    }
}

pub(super) fn validate(index: &Index) -> Result<(), DispatchError> {
    let mut ids = std::collections::HashSet::new();
    let mut sources = std::collections::HashSet::new();
    let mut requests = std::collections::HashSet::new();
    let parents: std::collections::HashSet<_> =
        index.checkouts.iter().map(|row| row.id.as_str()).collect();
    if index.chats.len() > MAX_SHARES
        || index.chats.iter().any(|row| {
            !reference(&row.id)
                || !ids.insert(row.id.as_str())
                || !crate::chat_receipts::valid_id(&row.conversation_id)
                || !crate::chat_receipts::valid_id(&row.request_id)
                || !digest(&row.preview)
                || !requests.insert((row.checkout_id.as_str(), row.request_id.as_str()))
                || !parents.contains(row.checkout_id.as_str())
                || row.phase != Phase::Withdrawn && !sources.insert(row.conversation_id.as_str())
                || row.revision == 0
                || row.revision > 9_007_199_254_740_991
                || row
                    .cloud_revision
                    .is_some_and(|revision| revision == 0 || revision > 9_007_199_254_740_991)
                || row.phase == Phase::Active && row.cloud_revision.is_none()
                || row.cloud_withdrawn && row.phase != Phase::Withdrawn
        })
    {
        return Err(storage());
    }
    Ok(())
}

#[cfg(test)]
mod tests;
