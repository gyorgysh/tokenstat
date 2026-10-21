// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{
    AuthorizedTeamPrincipal,
    publications::{ChatShare, ChatTarget, Checkout, Folder, Owner, Store},
};
use crate::error::DispatchError;

pub(super) struct Source {
    store: Store,
    owner: Owner,
    pub checkout: Checkout,
    pub chat: ChatShare,
}
fn changed() -> DispatchError {
    DispatchError::new(
        "chat_not_shared",
        "This chat is no longer available from that checkout.",
    )
}
impl Source {
    pub fn capture(principal: &AuthorizedTeamPrincipal) -> Result<Self, DispatchError> {
        principal.ensure_account_current()?;
        let p = principal.value();
        let share = p.share_id.as_deref().ok_or_else(changed)?;
        let owner = Owner {
            issuer: principal.issuer().into(),
            publisher_id: p.publisher_id.clone(),
            host_key: p.host_key.clone(),
        };
        let store = Store::capture()?;
        let checkout =
            store.resolve(&owner, &p.organization_id, &p.repository_id, &p.checkout_id)?;
        let chat = store.resolve_chat(
            &ChatTarget {
                owner: &owner,
                organization: &p.organization_id,
                repository: &p.repository_id,
                checkout: &p.checkout_id,
            },
            share,
        )?;
        let source = Self {
            store,
            owner,
            checkout,
            chat,
        };
        source.ensure_current()?;
        Ok(source)
    }
    pub fn ensure_current(&self) -> Result<(), DispatchError> {
        let target = ChatTarget {
            owner: &self.owner,
            organization: &self.checkout.organization_id,
            repository: &self.checkout.repository_id,
            checkout: &self.checkout.id,
        };
        let workspace =
            crate::workspaces::get(&self.checkout.workspace_id).map_err(|_| changed())?;
        if self.store.resolve_chat(&target, &self.chat.id)? != self.chat
            || self.store.resolve(
                &self.owner,
                target.organization,
                target.repository,
                target.checkout,
            )? != self.checkout
            || Folder::capture(&workspace.path)? != self.checkout.folder
        {
            return Err(changed());
        }
        Ok(())
    }
    pub fn target(&self) -> crate::chat::sharing::SharedSource<'_> {
        crate::chat::sharing::SharedSource {
            workspace: &self.checkout.workspace_id,
            id: &self.chat.conversation_id,
            preview: &self.chat.preview,
            revision: self.chat.source_revision,
        }
    }
}
