// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! A durable selection of private chats, reviewed and published one at a time.
//! Saving or opening a selection grants no sharing consent. Every publication
//! uses a fresh preview and the item's original, host-persisted request ID.

use super::{
    chats,
    publications::{ChatTarget, Folder, Owner, Phase, Store},
    sharing,
};
use crate::{account_session::AccountSnapshot, error::DispatchError};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokenstat_sync::teams::TeamClient;

#[cfg(test)]
mod tests;

const MAX_RECORDS: usize = 4096;
const MAX_CHATS: usize = 100;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Target {
    organization: String,
    repository: String,
    checkout: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Item {
    conversation: String,
    created_at_ms: i64,
    request_id: String,
    review: Option<String>,
    publication: Option<Receipt>,
    skipped: bool,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Receipt {
    id: String,
    revision: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Record {
    id: String,
    owner: Owner,
    target: Target,
    workspace: String,
    folder: Folder,
    request_id: String,
    items: Vec<Item>,
    discarded: bool,
}
impl Record {
    fn pending(&self) -> bool {
        !self.discarded
            && self
                .items
                .iter()
                .any(|i| !i.skipped && i.publication.is_none())
    }
}
pub(super) enum Request {
    Read(Target),
    Begin {
        target: Target,
        conversations: Vec<String>,
        request: String,
    },
    Preview {
        selection: String,
        conversation: String,
    },
    Publish {
        selection: String,
        conversation: String,
        preview: String,
    },
    Skip {
        selection: String,
        conversation: String,
    },
    Discard {
        selection: String,
    },
}
fn invalid() -> DispatchError {
    DispatchError::new(
        "invalid_request",
        "Review the selected chats and try again.",
    )
}
fn unavailable() -> DispatchError {
    DispatchError::new(
        "chat_review_unavailable",
        "The saved chat review is unavailable. Keep its records and try again.",
    )
}
fn changed() -> DispatchError {
    DispatchError::new(
        "chat_review_changed",
        "This chat review changed. Open its current selection again.",
    )
}
fn id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
}
fn hash(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit())
}
pub(super) fn valid_id(s: &str) -> bool {
    s.strip_prefix("review_")
        .is_some_and(|s| s.len() == 32 && s.bytes().all(|c| c.is_ascii_hexdigit()))
}
impl Target {
    fn valid(&self) -> bool {
        [&self.organization, &self.repository, &self.checkout]
            .into_iter()
            .all(|s| id(s))
    }
    fn fields(&self) -> Value {
        json!({"organization":self.organization,"repository":self.repository,"checkout":self.checkout})
    }
    fn chat_target<'a>(&'a self, owner: &'a Owner) -> ChatTarget<'a> {
        ChatTarget {
            owner,
            organization: &self.organization,
            repository: &self.repository,
            checkout: &self.checkout,
        }
    }
}
pub(super) fn validate(rows: &[Record]) -> Result<(), DispatchError> {
    let mut ids = std::collections::HashSet::new();
    let mut requests = std::collections::HashSet::new();
    let mut pending = std::collections::HashSet::new();
    if rows.len() > MAX_RECORDS {
        return Err(unavailable());
    }
    for row in rows {
        if !valid_id(&row.id)
            || !ids.insert(&row.id)
            || !row.target.valid()
            || !id(&row.owner.publisher_id)
            || !hash(&row.owner.host_key)
            || row.owner.issuer.is_empty()
            || row.owner.issuer.len() > 2048
            || row.owner.issuer.chars().any(char::is_control)
            || row.workspace.is_empty()
            || row.workspace.len() > 16 * 1024
            || !row.folder.canonical.is_absolute()
            || !crate::chat_receipts::valid_id(&row.request_id)
            || row.items.is_empty()
            || row.items.len() > MAX_CHATS
            || !requests.insert((
                &row.owner.issuer,
                &row.owner.publisher_id,
                &row.owner.host_key,
                &row.request_id,
            ))
            || row.pending()
                && !pending.insert((
                    &row.owner.issuer,
                    &row.owner.publisher_id,
                    &row.owner.host_key,
                    &row.target.checkout,
                ))
        {
            return Err(unavailable());
        }
        let mut conversations = std::collections::HashSet::new();
        for item in &row.items {
            if !crate::chat_receipts::valid_id(&item.conversation)
                || !conversations.insert(&item.conversation)
                || item.created_at_ms < 0
                || !crate::chat_receipts::valid_id(&item.request_id)
                || !requests.insert((
                    &row.owner.issuer,
                    &row.owner.publisher_id,
                    &row.owner.host_key,
                    &item.request_id,
                ))
                || item.review.as_deref().is_some_and(|s| !hash(s))
                || item.publication.as_ref().is_some_and(|p| {
                    !p.id
                        .strip_prefix("share_")
                        .is_some_and(|s| s.len() == 32 && s.bytes().all(|c| c.is_ascii_hexdigit()))
                        || p.revision == 0
                        || p.revision > 9_007_199_254_740_991
                        || item.review.is_none()
                        || item.skipped
                })
            {
                return Err(unavailable());
            }
        }
    }
    Ok(())
}
pub(super) fn parse(method: &str, body: Value) -> Option<Result<Request, DispatchError>> {
    if !method.starts_with("teams.chatSharing.") {
        return None;
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Begin {
        organization: String,
        repository: String,
        checkout: String,
        conversations: Vec<String>,
        request_id: String,
        confirm_selection: bool,
    }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct ItemRequest {
        selection: String,
        conversation: String,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Publish {
        selection: String,
        conversation: String,
        preview: String,
        confirm_history: bool,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Skip {
        selection: String,
        conversation: String,
        confirm_skip: bool,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Discard {
        selection: String,
        confirm_discard: bool,
    }
    Some((|| {
        Ok(match method {
            "teams.chatSharing.read" => {
                let target: Target = serde_json::from_value(body).map_err(|_| invalid())?;
                if !target.valid() {
                    return Err(invalid());
                }
                Request::Read(target)
            }
            "teams.chatSharing.begin" => {
                let mut b: Begin = serde_json::from_value(body).map_err(|_| invalid())?;
                let target = Target {
                    organization: b.organization,
                    repository: b.repository,
                    checkout: b.checkout,
                };
                b.conversations.sort();
                b.conversations.dedup();
                if !target.valid()
                    || !b.confirm_selection
                    || !crate::chat_receipts::valid_id(&b.request_id)
                    || b.conversations.is_empty()
                    || b.conversations.len() > MAX_CHATS
                    || !b
                        .conversations
                        .iter()
                        .all(|s| crate::chat_receipts::valid_id(s))
                {
                    return Err(invalid());
                }
                Request::Begin {
                    target,
                    conversations: b.conversations,
                    request: b.request_id,
                }
            }
            "teams.chatSharing.preview" => {
                let b: ItemRequest = serde_json::from_value(body).map_err(|_| invalid())?;
                if !valid_id(&b.selection) || !crate::chat_receipts::valid_id(&b.conversation) {
                    return Err(invalid());
                }
                Request::Preview {
                    selection: b.selection,
                    conversation: b.conversation,
                }
            }
            "teams.chatSharing.publish" => {
                let b: Publish = serde_json::from_value(body).map_err(|_| invalid())?;
                if !valid_id(&b.selection)
                    || !crate::chat_receipts::valid_id(&b.conversation)
                    || !hash(&b.preview)
                    || !b.confirm_history
                {
                    return Err(invalid());
                }
                Request::Publish {
                    selection: b.selection,
                    conversation: b.conversation,
                    preview: b.preview,
                }
            }
            "teams.chatSharing.skip" => {
                let b: Skip = serde_json::from_value(body).map_err(|_| invalid())?;
                if !valid_id(&b.selection)
                    || !crate::chat_receipts::valid_id(&b.conversation)
                    || !b.confirm_skip
                {
                    return Err(invalid());
                }
                Request::Skip {
                    selection: b.selection,
                    conversation: b.conversation,
                }
            }
            "teams.chatSharing.discard" => {
                let b: Discard = serde_json::from_value(body).map_err(|_| invalid())?;
                if !valid_id(&b.selection) || !b.confirm_discard {
                    return Err(invalid());
                }
                Request::Discard {
                    selection: b.selection,
                }
            }
            _ => return Err(invalid()),
        })
    })())
}
fn dto(row: &Record) -> Value {
    let current = crate::chat::shared().list(&row.workspace);
    let items: Vec<_> = row.items.iter().map(|item| {
        let chat = current.iter().find(|c| c.id == item.conversation && c.created_at_ms == item.created_at_ms);
        json!({"conversation":item.conversation,"title":chat.map(|c| &c.title),"available":chat.is_some(),"shared":item.publication.is_some(),"skipped":item.skipped})
    }).collect();
    json!({"id":row.id,"organizationId":row.target.organization,"repositoryId":row.target.repository,"checkoutId":row.target.checkout,
        "items":items,"complete":!row.pending(),"discarded":row.discarded,"allowsAgentRuns":false})
}
fn save(store: &Store, before: &Record, after: &Record) -> Result<(), DispatchError> {
    store.chat_reviews(|rows| {
        let row = rows
            .iter_mut()
            .find(|r| r.id == before.id && r.owner == before.owner)
            .ok_or_else(unavailable)?;
        if row != before {
            return Err(changed());
        }
        *row = after.clone();
        Ok(())
    })
}
fn owned(store: &Store, owner: &Owner, selection: &str) -> Result<Record, DispatchError> {
    store.chat_reviews(|rows| {
        rows.iter()
            .find(|r| r.id == selection && r.owner == *owner)
            .cloned()
            .ok_or_else(unavailable)
    })
}
fn refresh(store: &Store, row: &Record) -> Result<Record, DispatchError> {
    let mut after = row.clone();
    for item in after
        .items
        .iter_mut()
        .filter(|i| !i.skipped && i.publication.is_none())
    {
        if let Some(p) =
            store.chat_request(&row.target.chat_target(&row.owner), &item.request_id)?
        {
            if p.conversation_id != item.conversation {
                return Err(changed());
            }
            if p.phase == Phase::Active {
                item.publication = Some(Receipt {
                    id: p.id,
                    revision: p.revision,
                });
            }
        }
    }
    if *row != after {
        save(store, row, &after)?;
    }
    Ok(after)
}
fn current(
    owner: &AccountSnapshot,
    client: &TeamClient,
    row: &Record,
    conversation: &str,
) -> Result<usize, DispatchError> {
    owner.ensure_current().map_err(super::changed)?;
    client.ensure_current().map_err(super::api_error)?;
    if row.discarded || sharing::binding(client)? != row.owner {
        return Err(changed());
    }
    let workspace = crate::workspaces::get(&row.workspace).map_err(|_| changed())?;
    if Folder::capture(&workspace.path)? != row.folder {
        return Err(changed());
    }
    row.folder.ensure_current()?;
    let index = row
        .items
        .iter()
        .position(|i| i.conversation == conversation && !i.skipped && i.publication.is_none())
        .ok_or_else(changed)?;
    if !crate::chat::shared()
        .list(&row.workspace)
        .iter()
        .any(|c| c.id == conversation && c.created_at_ms == row.items[index].created_at_ms)
    {
        return Err(changed());
    }
    Ok(index)
}
fn chat_call(
    owner: &AccountSnapshot,
    client: &TeamClient,
    method: &str,
    fields: Value,
) -> Result<Value, DispatchError> {
    chats::perform(
        owner,
        client,
        chats::parse(method, fields).ok_or_else(invalid)??,
    )
}
pub(super) fn perform(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: Request,
) -> Result<Value, DispatchError> {
    let store = Store::capture()?;
    let binding = sharing::local_binding(owner, client)?;
    match request {
        Request::Read(target) => {
            let found = store.chat_reviews(|rows| {
                Ok(rows
                    .iter()
                    .find(|r| r.owner == binding && r.target == target && r.pending())
                    .cloned())
            })?;
            if let Some(row) = found {
                let _lease = store.chat_review_lease(&row.id)?;
                let row = refresh(&store, &row)?;
                Ok(json!({"selection":row.pending().then(|| dto(&row))}))
            } else {
                Ok(json!({"selection":null}))
            }
        }
        Request::Begin {
            target,
            conversations,
            request,
        } => {
            if let Some(prior) = store.chat_reviews(|rows| {
                Ok(rows
                    .iter()
                    .find(|r| r.owner == binding && r.request_id == request)
                    .cloned())
            })? {
                if prior.target != target
                    || prior
                        .items
                        .iter()
                        .map(|i| &i.conversation)
                        .ne(conversations.iter())
                    || prior.discarded
                {
                    return Err(changed());
                }
                return Ok(json!({"selection":dto(&prior)}));
            }
            let checkout = chats::local_checkout(
                owner,
                client,
                &target.organization,
                &target.repository,
                &target.checkout,
            )?;
            let known = crate::chat::shared().list(&checkout.workspace_id);
            let items = conversations
                .into_iter()
                .map(|conversation| {
                    let chat = known
                        .iter()
                        .find(|c| c.id == conversation && c.team_share.is_none())
                        .ok_or_else(changed)?;
                    Ok(Item {
                        conversation,
                        created_at_ms: chat.created_at_ms,
                        request_id: super::publications::opaque("history"),
                        review: None,
                        publication: None,
                        skipped: false,
                    })
                })
                .collect::<Result<Vec<_>, DispatchError>>()?;
            let row = Record {
                id: super::publications::opaque("review"),
                owner: binding,
                target,
                workspace: checkout.workspace_id,
                folder: checkout.folder,
                request_id: request,
                items,
                discarded: false,
            };
            owner.ensure_current().map_err(super::changed)?;
            client.ensure_current().map_err(super::api_error)?;
            let row = store.chat_reviews(|rows| {
                if let Some(prior) = rows
                    .iter()
                    .find(|r| r.owner == row.owner && r.request_id == row.request_id)
                {
                    if prior.target != row.target
                        || prior
                            .items
                            .iter()
                            .map(|i| &i.conversation)
                            .ne(row.items.iter().map(|i| &i.conversation))
                        || prior.discarded
                    {
                        return Err(changed());
                    }
                    return Ok(prior.clone());
                }
                if rows.iter().any(|r| {
                    r.owner == row.owner && r.target.checkout == row.target.checkout && r.pending()
                }) {
                    return Err(DispatchError::new(
                        "chat_review_pending",
                        "This project has a saved chat selection. Open its current review.",
                    ));
                }
                if rows.len() >= MAX_RECORDS {
                    return Err(DispatchError::new(
                        "chat_review_limit",
                        "Chat review records are full. Existing selections and receipts are kept.",
                    ));
                }
                rows.push(row.clone());
                Ok(row)
            })?;
            Ok(json!({"selection":dto(&row)}))
        }
        Request::Discard { selection } => {
            let _lease = store.chat_review_lease(&selection)?;
            let row = owned(&store, &binding, &selection)?;
            let mut after = row.clone();
            after.discarded = true;
            save(&store, &row, &after)?;
            Ok(json!({"selection":dto(&after),"keepsSharedChats":true}))
        }
        Request::Skip {
            selection,
            conversation,
        } => {
            let _lease = store.chat_review_lease(&selection)?;
            let row = refresh(&store, &owned(&store, &binding, &selection)?)?;
            if row.discarded {
                return Err(changed());
            }
            let mut after = row.clone();
            let item = after
                .items
                .iter_mut()
                .find(|i| i.conversation == conversation && i.publication.is_none())
                .ok_or_else(changed)?;
            item.skipped = true;
            save(&store, &row, &after)?;
            Ok(json!({"selection":dto(&after),"keepsSharedChats":true}))
        }
        Request::Preview {
            selection,
            conversation,
        } => {
            let _lease = store.chat_review_lease(&selection)?;
            let row = refresh(&store, &owned(&store, &binding, &selection)?)?;
            let index = current(owner, client, &row, &conversation)?;
            let mut fields = row.target.fields();
            fields["conversation"] = json!(conversation);
            let preview = chat_call(owner, client, "teams.chat.preview", fields)?;
            let mut after = row.clone();
            after.items[index].review = Some(
                preview["preview"]
                    .as_str()
                    .filter(|s| hash(s))
                    .ok_or_else(unavailable)?
                    .into(),
            );
            current(owner, client, &row, &conversation)?;
            save(&store, &row, &after)?;
            Ok(json!({"selection":dto(&after),"preview":preview}))
        }
        Request::Publish {
            selection,
            conversation,
            preview,
        } => {
            let _lease = store.chat_review_lease(&selection)?;
            let row = refresh(&store, &owned(&store, &binding, &selection)?)?;
            if row.discarded {
                return Err(changed());
            }
            if row
                .items
                .iter()
                .any(|i| i.conversation == conversation && i.publication.is_some())
            {
                return Ok(json!({"selection":dto(&row)}));
            }
            let index = current(owner, client, &row, &conversation)?;
            if row.items[index].review.as_deref() != Some(&preview) {
                return Err(changed());
            }
            let mut fields = row.target.fields();
            fields["conversation"] = json!(conversation);
            fields["preview"] = json!(preview);
            fields["requestId"] = json!(row.items[index].request_id);
            fields["confirmHistory"] = json!(true);
            chat_call(owner, client, "teams.chat.publish", fields)?;
            owner.ensure_current().map_err(super::changed)?;
            client.ensure_current().map_err(super::api_error)?;
            let row = refresh(&store, &row)?;
            if row.items[index].publication.is_none() {
                return Err(unavailable());
            }
            Ok(json!({"selection":dto(&row)}))
        }
    }
}
