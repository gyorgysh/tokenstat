// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Only approved display metadata crosses a broad checkout read connection.
//! Active cloud refs, private mappings and canonical markers must all agree.

use super::{
    AuthorizedTeamPrincipal, api_error,
    publications::{ChatTarget, Folder, Owner, Phase, Store},
};
use crate::{error::DispatchError, remote::TeamReadParams};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use tokenstat_sync::teams::{Page, TeamCapability, TeamError};

fn changed() -> DispatchError {
    DispatchError::new(
        "chat_catalog_changed",
        "Sharing changed while loading these chats. Refresh and try again.",
    )
}

pub(super) fn call(
    principal: &AuthorizedTeamPrincipal,
    params: &TeamReadParams,
) -> Result<Value, DispatchError> {
    let scope = principal.value();
    if scope.share_id.is_some() || !scope.capabilities.contains(&TeamCapability::Read) {
        return Err(DispatchError::new(
            "checkout_scope_required",
            "Open this checkout to browse its shared chats.",
        ));
    }
    let offset = params.catalog_offset(&scope.checkout_id)?;
    let limit = params.limit.unwrap_or(100);
    let client = principal.account_client()?;
    let owner = Owner {
        issuer: principal.issuer().into(),
        publisher_id: scope.publisher_id.clone(),
        host_key: scope.host_key.clone(),
    };
    let target = ChatTarget {
        owner: &owner,
        organization: &scope.organization_id,
        repository: &scope.repository_id,
        checkout: &scope.checkout_id,
    };
    let store = Store::capture()?;
    let checkout = store.resolve(
        &owner,
        target.organization,
        target.repository,
        target.checkout,
    )?;
    let workspace = crate::workspaces::get(&checkout.workspace_id).map_err(|_| changed())?;
    if Folder::capture(&workspace.path)? != checkout.folder {
        return Err(changed());
    }
    let local: HashMap<_, _> = store
        .local_chats(&target)?
        .into_iter()
        .filter(|row| row.phase == Phase::Active)
        .map(|row| (row.id.clone(), row))
        .collect();
    // Exactly one bounded account request, with no private source/map locks.
    // The guest's authority came from its verified principal, not this client.
    let page = client
        .shared_chats(target.organization, target.checkout, Page { limit, offset })
        .map_err(api_error)?;
    client.ensure_current().map_err(api_error)?;
    principal.ensure_live()?;
    let mut seen = HashSet::new();
    if page.shares.len() > limit as usize
        || page.next_offset.is_some_and(|next| {
            next <= offset || next > 10000 || next != offset + page.shares.len() as u32
        })
        || page.shares.iter().any(|row| {
            row.checkout_id != scope.checkout_id
                || row.revision == 0
                || row.revision > 9_007_199_254_740_991
                || row.created_at.len() > 128
                || !row.id.strip_prefix("share_").is_some_and(|id| {
                    id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
                })
                || !seen.insert(&row.id)
        })
    {
        return Err(api_error(TeamError::InvalidResponse));
    }
    let candidates: Vec<_> = page
        .shares
        .iter()
        .filter_map(|row| {
            local
                .get(&row.id)
                .filter(|local| local.cloud_revision == Some(row.revision))
                .map(|local| local.conversation_id.clone())
        })
        .collect();
    let chats = crate::chat::shared();
    let before = chats.sharing_catalog_entries(&checkout.workspace_id, &candidates)?;
    let mut rows = Vec::new();
    let mut selected = Vec::new();
    for cloud in &page.shares {
        let Some(local) = local
            .get(&cloud.id)
            .filter(|local| local.cloud_revision == Some(cloud.revision))
        else {
            continue;
        };
        let Some(entry) = before.get(&local.conversation_id).filter(|entry| {
            entry.binding.id == local.id
                && entry.binding.initial_fingerprint == local.preview
                && entry.binding.source_revision == local.source_revision
        }) else {
            continue;
        };
        let marker = &entry.binding;
        if marker
            .approved
            .as_ref()
            .is_some_and(|approved| !approved.valid())
        {
            return Err(changed());
        }
        // Older local markers remain readable through their exact share, but
        // have no approved catalog title. Never substitute a current title.
        rows.push(json!({"id":cloud.id,"checkoutId":cloud.checkout_id,"revision":cloud.revision,"createdAt":cloud.created_at,
            "title":marker.approved.as_ref().map(|approved| &approved.title),"backend":marker.approved.as_ref().map(|approved| &approved.backend),
            "lastMessageAtMs":entry.last_message_at_ms}));
        selected.push((local, marker));
    }
    let after = chats.sharing_bindings(&checkout.workspace_id, &candidates)?;
    let current: HashMap<_, _> = store
        .local_chats(&target)?
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect();
    if store.resolve(
        &owner,
        target.organization,
        target.repository,
        target.checkout,
    )? != checkout
        || Folder::capture(&workspace.path)? != checkout.folder
        || selected.iter().any(|(row, marker)| {
            current.get(&row.id) != Some(*row) || after.get(&row.conversation_id) != Some(*marker)
        })
    {
        return Err(changed());
    }
    client.ensure_current().map_err(api_error)?;
    principal.ensure_live()?;
    Ok(
        json!({"shares":rows,"nextCursor":page.next_offset.map(|next| format!("v1:catalog:{}:{next}", checkout.id)),
            "backends":crate::automations::agent_backends().map(|backend| json!({"id":backend.id,"label":backend.label})).collect::<Vec<_>>()}),
    )
}
