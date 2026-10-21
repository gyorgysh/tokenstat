// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{
    api_error,
    publications::{self, ChatShare, ChatTarget, Owner, Phase, Store},
    sharing,
};
use crate::{account_session::AccountSnapshot, error::DispatchError};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokenstat_sync::teams::{Page, Repository, Revision, TeamClient, TeamError};

pub(super) enum Request {
    Options(List),
    List(List),
    Preview(Target),
    Publish(Publish),
    Withdraw(Withdraw),
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct List {
    organization: String,
    repository: String,
    checkout: String,
    #[serde(default)]
    page: Page,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Target {
    organization: String,
    repository: String,
    checkout: String,
    conversation: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Publish {
    organization: String,
    repository: String,
    checkout: String,
    conversation: String,
    preview: String,
    request_id: String,
    confirm_history: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Withdraw {
    organization: String,
    repository: String,
    checkout: String,
    share: String,
    expected_revision: u64,
}
fn invalid() -> DispatchError {
    api_error(TeamError::InvalidRequest)
}
fn changed() -> DispatchError {
    DispatchError::new(
        "chat_sharing_changed",
        "This chat's sharing changed. Review it again.",
    )
}
fn identifier(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}
fn identifiers(values: [&str; 3]) -> Result<(), DispatchError> {
    if values.into_iter().all(identifier) {
        Ok(())
    } else {
        Err(invalid())
    }
}
pub(super) fn parse(method: &str, body: Value) -> Option<Result<Request, DispatchError>> {
    if !matches!(
        method,
        "teams.chat.options"
            | "teams.chat.list"
            | "teams.chat.preview"
            | "teams.chat.publish"
            | "teams.chat.withdraw"
    ) {
        return None;
    }
    Some((|| match method {
        "teams.chat.options" | "teams.chat.list" => {
            let value: List = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            value.page.validate().map_err(api_error)?;
            Ok(if method == "teams.chat.options" {
                Request::Options(value)
            } else {
                Request::List(value)
            })
        }
        "teams.chat.preview" => {
            let value: Target = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            Ok(Request::Preview(value))
        }
        "teams.chat.publish" => {
            let value: Publish = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            if !value.confirm_history
                || !crate::chat_receipts::valid_id(&value.request_id)
                || value.preview.len() != 64
                || !value.preview.bytes().all(|byte| byte.is_ascii_hexdigit())
            {
                return Err(invalid());
            }
            Ok(Request::Publish(value))
        }
        "teams.chat.withdraw" => {
            let value: Withdraw = serde_json::from_value(body).map_err(|_| invalid())?;
            identifiers([&value.organization, &value.repository, &value.checkout])?;
            if !value.share.strip_prefix("share_").is_some_and(|suffix| {
                suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
            }) || value.expected_revision == 0
                || value.expected_revision > 9_007_199_254_740_991
            {
                return Err(invalid());
            }
            Ok(Request::Withdraw(value))
        }
        _ => Err(invalid()),
    })())
}
struct Review {
    checkout: publications::Checkout,
    repository: Repository,
    history: crate::chat::sharing::History,
    preview: String,
}
fn target<'a>(binding: &'a Owner, request: &'a Target) -> ChatTarget<'a> {
    ChatTarget {
        owner: binding,
        organization: &request.organization,
        repository: &request.repository,
        checkout: &request.checkout,
    }
}
fn review(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: &Target,
) -> Result<Review, DispatchError> {
    let (binding, local, repository, cloud_revision) = review_context(owner, client, request)?;
    finish_review(owner, request, binding, local, repository, cloud_revision)
}
fn review_context(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: &Target,
) -> Result<(Owner, publications::Checkout, Repository, u64), DispatchError> {
    let binding = sharing::binding_features(
        client,
        &[
            "checkout-publication",
            "chat-publication",
            "scoped-connections",
        ],
    )?;
    let repository = sharing::repository(client, &request.organization, &request.repository)?;
    let local = Store::capture()?.resolve(
        &binding,
        &request.organization,
        &request.repository,
        &request.checkout,
    )?;
    let workspace = crate::workspaces::get(&local.workspace_id).map_err(|_| changed())?;
    if publications::Folder::capture(&workspace.path)? != local.folder {
        return Err(changed());
    }
    let published = client
        .checkout_publication(&request.organization, &request.checkout)
        .map_err(api_error)?
        .checkout;
    if published.id != local.id
        || published.organization_id != local.organization_id
        || published.repository_id != local.repository_id
        || published.publisher_id != binding.publisher_id
        || published.host_key != binding.host_key
    {
        return Err(api_error(TeamError::InvalidResponse));
    }
    owner.ensure_current().map_err(super::changed)?;
    Ok((binding, local, repository, published.revision))
}
fn finish_review(
    owner: &AccountSnapshot,
    request: &Target,
    binding: Owner,
    local: publications::Checkout,
    repository: Repository,
    cloud_revision: u64,
) -> Result<Review, DispatchError> {
    let history =
        crate::chat::shared().sharing_history(&local.workspace_id, &request.conversation)?;
    let receipt = json!({"v":1,"account":owner.id,"owner":binding,"organization":request.organization,"repository":repository.id,"repositoryRevision":repository.revision,
        "checkout":local.id,"publicationRevision":local.revision,"cloudRevision":cloud_revision,"conversation":request.conversation,"history":history.fingerprint});
    let preview = tokenstat_identity::hex(&Sha256::digest(
        serde_json::to_vec(&receipt).map_err(|_| invalid())?,
    ));
    Ok(Review {
        checkout: local,
        repository,
        history,
        preview,
    })
}
fn publication_dto(row: &ChatShare) -> Value {
    json!({"id":row.id,"checkoutId":row.checkout_id,"revision":row.revision})
}
pub(super) fn perform(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: Request,
) -> Result<Value, DispatchError> {
    match request {
        Request::Options(request) => {
            let source = Target {
                organization: request.organization,
                repository: request.repository,
                checkout: request.checkout,
                conversation: String::new(),
            };
            let (_, checkout, _, _) = review_context(owner, client, &source)?;
            let rows = crate::chat::shared().list(&checkout.workspace_id);
            let start = request.page.offset as usize;
            let count = request.page.limit as usize;
            let chats:Vec<_>=rows.iter().skip(start).take(count).map(|chat| json!({"id":chat.id,"title":chat.title,"backend":chat.backend,"shared":chat.team_share.is_some()})).collect();
            Ok(json!({"chats":chats,"nextOffset":(rows.len()>start+count).then_some(start+count)}))
        }
        Request::List(request) => {
            let binding = sharing::local_binding(owner, client)?;
            let target = ChatTarget {
                owner: &binding,
                organization: &request.organization,
                repository: &request.repository,
                checkout: &request.checkout,
            };
            let rows = Store::capture()?.local_chats(&target)?;
            let start = request.page.offset as usize;
            let count = request.page.limit as usize;
            let rows: Vec<_> = rows
                .iter()
                .filter(|row| row.phase != Phase::Withdrawn || !row.cloud_withdrawn)
                .collect();
            let publications:Vec<_>=rows.iter().skip(start).take(count).map(|row| json!({"id":row.id,"checkoutId":row.checkout_id,"conversationId":row.conversation_id,"phase":row.phase,"revision":row.revision,"accountCleanupPending":row.phase==Phase::Withdrawn && !row.cloud_withdrawn})).collect();
            Ok(
                json!({"publications":publications,"nextOffset":(rows.len()>start+count).then_some(start+count)}),
            )
        }
        Request::Preview(request) => {
            let review = review(owner, client, &request)?;
            Ok(
                json!({"conversation":request.conversation,"checkoutId":review.checkout.id,"repository":review.repository,
                "deviceName":tokenstat_identity::machine_label(),"history":review.history,"preview":review.preview,
                "audience":"currentAndFutureRepositoryMembers","allowsAgentRuns":false}),
            )
        }
        Request::Publish(input) => {
            let request = Target {
                organization: input.organization,
                repository: input.repository,
                checkout: input.checkout,
                conversation: input.conversation,
            };
            let (binding, checkout, repository, cloud_revision) =
                review_context(owner, client, &request)?;
            let store = Store::capture()?;
            let target = target(&binding, &request);
            // Repeating an accepted publication settles its original receipt;
            // later shared messages must not turn it into a new publication.
            if let Some(previous) = store.chat_request(&target, &input.request_id)?
                && previous.phase == Phase::Active
            {
                if previous.conversation_id != request.conversation {
                    return Err(changed());
                }
                crate::chat::shared().shared_history(
                    &checkout.workspace_id,
                    &previous.conversation_id,
                    &previous.id,
                    &previous.preview,
                )?;
                let current = client
                    .chat_publication(&request.organization, &request.checkout, &previous.id)
                    .map_err(api_error)?
                    .share;
                if current.id != previous.id
                    || current.checkout_id != previous.checkout_id
                    || Some(current.revision) != previous.cloud_revision
                {
                    return Err(changed());
                }
                return Ok(
                    json!({"publication":publication_dto(&store.resolve_chat(&target,&previous.id)?)}),
                );
            }
            let review = finish_review(
                owner,
                &request,
                binding.clone(),
                checkout,
                repository,
                cloud_revision,
            )?;
            if review.preview != input.preview {
                return Err(DispatchError::new(
                    "chat_history_changed",
                    "This chat changed after its sharing preview. Review the history again.",
                ));
            }
            let prepared = store.prepare_chat(
                &target,
                &request.conversation,
                &input.request_id,
                &review.history.fingerprint,
            )?;
            let chats = crate::chat::shared();
            if let Err(error) = chats.freeze_sharing(
                &review.checkout.workspace_id,
                &request.conversation,
                &prepared.id,
                &review.history.fingerprint,
            ) {
                if matches!(
                    error.code.as_str(),
                    "chat_history_changed" | "chat_already_shared" | "chat_running"
                ) {
                    let _ = store.withdraw_chat(&target, &prepared.id, prepared.revision);
                }
                return Err(error);
            }
            owner.ensure_current().map_err(super::changed)?;
            let published = client
                .publish_chat(&request.organization, &request.checkout, &prepared.id, true)
                .map_err(api_error)?
                .share;
            if published.id != prepared.id
                || published.checkout_id != prepared.checkout_id
                || published.revision == 0
            {
                return Err(api_error(TeamError::InvalidResponse));
            }
            owner.ensure_current().map_err(super::changed)?;
            store.activate_chat(&target, &prepared.id, prepared.revision, published.revision)?;
            Ok(json!({"publication":publication_dto(&store.resolve_chat(&target,&prepared.id)?)}))
        }
        Request::Withdraw(request) => {
            let binding = sharing::local_binding(owner, client)?;
            let target = ChatTarget {
                owner: &binding,
                organization: &request.organization,
                repository: &request.repository,
                checkout: &request.checkout,
            };
            let store = Store::capture()?;
            let parent = store.local_chat_checkout(&target)?;
            let previous = store.local_chat(&target, &request.share)?;
            let retired =
                store.withdraw_chat(&target, &request.share, request.expected_revision)?;
            crate::chat::shared().clear_sharing(
                &parent.workspace_id,
                &retired.conversation_id,
                &retired.id,
            )?;
            if previous.cloud_withdrawn {
                return Ok(json!({"withdrawn":true}));
            }
            let current = match client.chat_publication(
                &request.organization,
                &request.checkout,
                &retired.id,
            ) {
                Ok(value)
                    if value.share.id == retired.id
                        && value.share.checkout_id == retired.checkout_id =>
                {
                    value.share
                }
                Err(TeamError::Rejected {
                    status: 404, code, ..
                }) if code == "not_found" => {
                    store.confirm_chat_withdrawal(&target, &retired.id)?;
                    return Ok(json!({"withdrawn":true}));
                }
                _ => return Ok(json!({"withdrawn":true,"accountCleanupPending":true})),
            };
            match client.withdraw_chat(
                &request.organization,
                &request.checkout,
                &retired.id,
                Revision {
                    expected_revision: current.revision,
                },
            ) {
                Ok(value) if value.withdrawn => {
                    store.confirm_chat_withdrawal(&target, &retired.id)?;
                    Ok(json!({"withdrawn":true}))
                }
                Err(TeamError::Rejected {
                    status: 404, code, ..
                }) if code == "not_found" => {
                    store.confirm_chat_withdrawal(&target, &retired.id)?;
                    Ok(json!({"withdrawn":true}))
                }
                _ => Ok(json!({"withdrawn":true,"accountCleanupPending":true})),
            }
        }
    }
}
