// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{
    api_error,
    publications::{Checkout, Folder, Owner, Phase, Store},
    serialize,
};
use crate::{account_session::AccountSnapshot, error::DispatchError};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokenstat_sync::teams::{Page, Repository, RepositoryRole, TeamClient, TeamError};

#[cfg(test)]
mod tests;

pub(super) enum Request {
    Options(Page),
    Preview(Target),
    Publish(Publish),
    List {
        page: Page,
        organization: Option<String>,
        repository: Option<String>,
    },
    Withdraw(Withdraw),
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Target {
    organization: String,
    repository: String,
    workspace: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Publish {
    organization: String,
    repository: String,
    workspace: String,
    request_id: String,
    preview: String,
    confirm_sharing: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Withdraw {
    checkout: String,
    expected_revision: u64,
}

pub(super) fn parse(method: &str, body: Value) -> Option<Result<Request, DispatchError>> {
    let invalid = || {
        DispatchError::new(
            "invalid_request",
            "Check the checkout sharing request and try again.",
        )
    };
    Some(match method {
        "teams.checkout.preview" => serde_json::from_value(body)
            .map(Request::Preview)
            .map_err(|_| invalid()),
        "teams.checkout.publish" => serde_json::from_value::<Publish>(body)
            .map_err(|_| invalid())
            .and_then(|value| {
                if !value.confirm_sharing
                    || !crate::chat_receipts::valid_id(&value.request_id)
                    || value.preview.len() != 64
                    || !value.preview.bytes().all(|byte| byte.is_ascii_hexdigit())
                {
                    return Err(invalid());
                }
                Ok(Request::Publish(value))
            }),
        "teams.checkout.list" | "teams.checkout.options" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct List {
                #[serde(default)]
                page: Page,
                organization: Option<String>,
                repository: Option<String>,
            }
            serde_json::from_value::<List>(body)
                .map_err(|_| invalid())
                .and_then(|value| {
                    if value.organization.is_some() != value.repository.is_some()
                        || method == "teams.checkout.options" && value.organization.is_some()
                    {
                        return Err(invalid());
                    }
                    Ok(if method == "teams.checkout.options" {
                        Request::Options(value.page)
                    } else {
                        Request::List {
                            page: value.page,
                            organization: value.organization,
                            repository: value.repository,
                        }
                    })
                })
        }
        "teams.checkout.withdraw" => serde_json::from_value(body)
            .map(Request::Withdraw)
            .map_err(|_| invalid()),
        _ => return None,
    })
}
pub(super) fn binding(client: &TeamClient) -> Result<Owner, DispatchError> {
    binding_features(client, &["checkout-publication"])
}
pub(super) fn binding_features(
    client: &TeamClient,
    required: &[&str],
) -> Result<Owner, DispatchError> {
    let identity = tokenstat_identity::MachineIdentity::load_or_create().map_err(|_| {
        DispatchError::new(
            "identity_unavailable",
            "This computer’s connection key is unavailable.",
        )
    })?;
    let capabilities = client.capabilities().map_err(api_error)?;
    if !capabilities.ready() {
        return Err(DispatchError::new(
            "teams_authorization_required",
            "Enable Teams for this computer in your account settings.",
        ));
    }
    if required.iter().any(|required| {
        !capabilities
            .features
            .iter()
            .any(|feature| feature == required)
    }) {
        return Err(DispatchError::new(
            "teams_unavailable",
            if required.contains(&"chat-publication") {
                "Chat sharing is not available on this account server yet."
            } else {
                "Checkout sharing is not available on this account server yet."
            },
        ));
    }
    if capabilities.device_key.as_deref() != Some(identity.public_key_hex().as_str()) {
        return Err(DispatchError::new(
            "device_changed",
            "This computer’s connection key changed. Review its Teams authorization.",
        ));
    }
    Ok(Owner {
        issuer: client.origin().into(),
        publisher_id: capabilities
            .actor_id
            .ok_or_else(|| api_error(TeamError::InvalidResponse))?,
        host_key: identity.public_key_hex(),
    })
}
pub(super) fn local_binding(
    owner: &AccountSnapshot,
    client: &TeamClient,
) -> Result<Owner, DispatchError> {
    let status = owner
        .status(false)
        .map_err(|_| api_error(TeamError::NotSignedIn))?;
    let publisher_id = status
        .account_id
        .filter(|id| !id.is_empty())
        .ok_or_else(|| api_error(TeamError::NotSignedIn))?;
    let identity = tokenstat_identity::MachineIdentity::load_or_create().map_err(|_| {
        DispatchError::new(
            "identity_unavailable",
            "This computer’s connection key is unavailable.",
        )
    })?;
    owner.ensure_current().map_err(super::changed)?;
    Ok(Owner {
        issuer: client.origin().into(),
        publisher_id,
        host_key: identity.public_key_hex(),
    })
}

pub(super) fn restore_remote_reach(
    owner: &AccountSnapshot,
    identity: &tokenstat_identity::MachineIdentity,
) -> Result<(), DispatchError> {
    let key = identity.public_key_hex();
    let store = Store::capture()?;
    if !store.has_active_key(&key)? {
        return Ok(());
    }
    crate::remote::team_reach_restoring(owner, true).map_err(super::changed)?;
    let result = (|| {
        let client = super::client(owner)?;
        let binding = binding(&client)?;
        let active = binding.host_key == key && store.has_active(&binding)?;
        owner.ensure_current().map_err(super::changed)?;
        crate::remote::team_hosting(owner, &key, active).map_err(super::changed)
    })();
    let retry = result.as_ref().is_err_and(|error: &DispatchError| {
        matches!(
            error.code.as_str(),
            "teams_unreachable" | "teams_busy" | "teams_unconfigured" | "teams_request_failed"
        )
    });
    crate::remote::team_reach_restoring(owner, retry).map_err(super::changed)?;
    if retry { result } else { Ok(()) }
}

fn update_remote_reach(
    owner: &AccountSnapshot,
    store: &Store,
    binding: &Owner,
) -> Result<(), DispatchError> {
    let active = store.has_active(binding)?;
    crate::remote::team_hosting(owner, &binding.host_key, active).map_err(super::changed)?;
    if active {
        crate::remote::start_team_reach(owner.clone());
    }
    Ok(())
}
pub(super) fn repository(
    client: &TeamClient,
    organization: &str,
    id: &str,
) -> Result<Repository, DispatchError> {
    let mut offset = 0;
    for _ in 0..=10 {
        let page = client
            .repositories(organization, Page { limit: 100, offset })
            .map_err(api_error)?;
        if let Some(repository) = page.repositories.into_iter().find(|row| row.id == id) {
            if !matches!(
                repository.role,
                Some(RepositoryRole::Contributor | RepositoryRole::Maintainer)
            ) {
                return Err(DispatchError::new(
                    "contributor_required",
                    "Ask a maintainer for Contributor access before publishing a checkout.",
                ));
            }
            return Ok(repository);
        }
        match page.next_offset {
            Some(next) if next > offset => offset = next,
            _ => break,
        }
    }
    Err(DispatchError::new(
        "repository_not_found",
        "This repository is not available to your account.",
    ))
}
fn target(
    owner: &AccountSnapshot,
    client: &TeamClient,
    organization: &str,
    repository_id: &str,
    workspace: &str,
) -> Result<
    (
        Owner,
        Repository,
        tokenstat_workspace::Workspace,
        Folder,
        String,
    ),
    DispatchError,
> {
    let binding = binding(client)?;
    let repository = repository(client, organization, repository_id)?;
    owner.ensure_current().map_err(super::changed)?;
    let workspace = crate::workspaces::get(workspace).map_err(|_| {
        DispatchError::new(
            "checkout_missing",
            "Choose a repository registered on this computer.",
        )
    })?;
    let folder = Folder::capture(&workspace.path)?;
    let data = serde_json::to_vec(&json!({"v":1,"account":owner.id,"owner":binding,"organization":organization,"repository":repository.id,"repositoryRevision":repository.revision,"workspace":workspace.id,"folder":folder})).map_err(|_| api_error(TeamError::InvalidResponse))?;
    let preview = tokenstat_identity::hex(&Sha256::digest(data));
    Ok((binding, repository, workspace, folder, preview))
}
fn local_dto(row: &Checkout) -> Value {
    json!({"id":row.id,"organizationId":row.organization_id,"repositoryId":row.repository_id,"workspaceId":row.workspace_id,"phase":row.phase,"revision":row.revision,"accountCleanupPending":row.phase == Phase::Withdrawn && !row.cloud_withdrawn})
}
/// Whether the account server says a publication no longer exists. Only an
/// explicit `not_found` counts: an outage or a refused request proves nothing,
/// and a folder must never look private while teammates can still reach it.
fn stopped_elsewhere<T>(reply: &Result<T, TeamError>) -> bool {
    matches!(reply, Err(TeamError::Rejected { status: 404, code, .. }) if code == "not_found")
}
/// How often one publication is asked about, at most. The list is read on
/// every refresh while Teams is open, and one request per shared folder on
/// each of those would be a steady load for a change that is rare.
const SETTLE_CHECK_INTERVAL: std::time::Duration = std::time::Duration::from_secs(120);
fn due_for_settle_check(id: &str) -> bool {
    use std::{collections::HashMap, sync::Mutex, time::Instant};
    static CHECKED: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);
    let Ok(mut checked) = CHECKED.lock() else {
        return true;
    };
    let checked = checked.get_or_insert_with(HashMap::new);
    let now = Instant::now();
    checked.retain(|_, at| now.duration_since(*at) < SETTLE_CHECK_INTERVAL);
    if checked.contains_key(id) {
        return false;
    }
    checked.insert(id.to_string(), now);
    true
}
/// Sharing can end without this computer: the publisher stops it from
/// another device or a maintainer removes the checkout. The local row then
/// still reads as shared, so the folder keeps its badge and keeps serving
/// teammates who can no longer find it. Retire it here, the same way a
/// local stop would, and leave the repository, its chats and history alone.
fn settle_stopped_elsewhere(
    owner: &AccountSnapshot,
    client: &TeamClient,
    store: &Store,
    binding: &Owner,
) -> Result<(), DispatchError> {
    let mut settled = false;
    for row in store.list(binding)? {
        if row.phase != Phase::Active || !due_for_settle_check(&row.id) {
            continue;
        }
        if !stopped_elsewhere(&client.checkout_publication(&row.organization_id, &row.id)) {
            continue;
        }
        owner.ensure_current().map_err(super::changed)?;
        match store.withdraw(binding, &row.id, row.revision) {
            Ok(_) => {
                store.confirm_cloud_withdrawal(binding, &row.id)?;
                settled = true;
            }
            // A row that moved since the read was changed by a local action,
            // which wins over this cleanup.
            Err(error) if error.code == "publication_changed" => {}
            Err(error) => return Err(error),
        }
    }
    if settled {
        update_remote_reach(owner, store, binding)?;
    }
    Ok(())
}
pub(super) fn perform(
    owner: &AccountSnapshot,
    client: &TeamClient,
    request: Request,
) -> Result<Value, DispatchError> {
    let store = Store::capture()?;
    match request {
        Request::Options(page) => {
            page.validate().map_err(api_error)?;
            binding(client)?;
            let (workspaces, total) = {
                let registry = crate::workspaces::read();
                (registry.workspaces.iter().skip(page.offset as usize).take(page.limit as usize)
                    .map(|workspace| json!({"id":workspace.id,"name":workspace.name,"path":workspace.path})).collect::<Vec<_>>(), registry.workspaces.len())
            };
            let next = page.offset as usize + workspaces.len();
            Ok(
                json!({"workspaces":workspaces,"deviceName":tokenstat_identity::machine_label(),"nextOffset":if next < total { Some(next) } else { None }}),
            )
        }
        Request::Preview(input) => {
            let (_, repository, workspace, _, preview) = target(
                owner,
                client,
                &input.organization,
                &input.repository,
                &input.workspace,
            )?;
            Ok(
                json!({"repository":repository,"workspaceId":workspace.id,"workspaceName":workspace.name,"preview":preview,"sharesExistingChats":false,"allowsAgentRuns":false}),
            )
        }
        Request::Publish(input) => {
            let (binding, _, workspace, folder, preview) = target(
                owner,
                client,
                &input.organization,
                &input.repository,
                &input.workspace,
            )?;
            if preview != input.preview {
                return Err(DispatchError::new(
                    "checkout_changed",
                    "The checkout or repository changed. Review sharing again.",
                ));
            }
            let prepared = store.prepare(
                &binding,
                &input.organization,
                &input.repository,
                &workspace.id,
                &folder,
                &input.request_id,
            )?;
            if prepared.phase == Phase::Active {
                let current =
                    match client.checkout_publication(&prepared.organization_id, &prepared.id) {
                        Ok(reply) => reply.checkout,
                        Err(TeamError::Rejected { status: 404, .. }) => {
                            store.withdraw(&binding, &prepared.id, prepared.revision)?;
                            return Err(DispatchError::new(
                                "publication_changed",
                                "Sharing was stopped. Review a new publication for this checkout.",
                            ));
                        }
                        Err(error) => return Err(api_error(error)),
                    };
                if current.id != prepared.id
                    || current.organization_id != prepared.organization_id
                    || current.repository_id != prepared.repository_id
                    || current.publisher_id != binding.publisher_id
                    || current.host_key != binding.host_key
                {
                    return Err(api_error(TeamError::InvalidResponse));
                }
                update_remote_reach(owner, &store, &binding)?;
                return Ok(json!({"publication":local_dto(&prepared)}));
            }
            let reply = client
                .publish_checkout(&input.organization, &input.repository, &prepared.id)
                .map_err(api_error)?;
            let row = reply.checkout;
            if row.id != prepared.id
                || row.organization_id != input.organization
                || row.repository_id != input.repository
                || row.publisher_id != binding.publisher_id
                || row.host_key != binding.host_key
            {
                return Err(api_error(TeamError::InvalidResponse));
            }
            owner.ensure_current().map_err(super::changed)?;
            let active = store.activate(&binding, &prepared.id, prepared.revision, row.revision)?;
            if let Err(error) = owner.ensure_current() {
                let _ = store.withdraw(&binding, &active.id, active.revision);
                return Err(super::changed(error));
            }
            update_remote_reach(owner, &store, &binding)?;
            Ok(json!({"publication":local_dto(&active)}))
        }
        Request::List {
            page,
            organization,
            repository,
        } => {
            page.validate().map_err(api_error)?;
            let binding = local_binding(owner, client)?;
            settle_stopped_elsewhere(owner, client, &store, &binding)?;
            let rows: Vec<_> = store
                .list(&binding)?
                .into_iter()
                .filter(|row| {
                    (row.phase != Phase::Withdrawn || !row.cloud_withdrawn)
                        && organization
                            .as_deref()
                            .is_none_or(|org| row.organization_id == org)
                        && repository
                            .as_deref()
                            .is_none_or(|repo| row.repository_id == repo)
                })
                .collect();
            let page_rows: Vec<_> = rows
                .iter()
                .skip(page.offset as usize)
                .take(page.limit as usize)
                .map(local_dto)
                .collect();
            let next = page.offset as usize + page_rows.len();
            Ok(
                json!({"publications":page_rows,"nextOffset":if next < rows.len() { Some(next) } else { None }}),
            )
        }
        Request::Withdraw(input) => {
            let binding = local_binding(owner, client)?;
            // Stop local reads first. An unknown cloud outcome remains a
            // withdrawn local publication and can be retried safely.
            let retired = store.withdraw(&binding, &input.checkout, input.expected_revision)?;
            update_remote_reach(owner, &store, &binding)?;
            if retired.cloud_withdrawn {
                return Ok(json!({"withdrawn":true}));
            }
            for _ in 0..2 {
                let revision =
                    match client.checkout_publication(&retired.organization_id, &retired.id) {
                        Ok(reply) => {
                            let current = reply.checkout;
                            if current.id != retired.id
                                || current.organization_id != retired.organization_id
                                || current.repository_id != retired.repository_id
                                || current.publisher_id != binding.publisher_id
                                || current.host_key != binding.host_key
                            {
                                return Err(api_error(TeamError::InvalidResponse));
                            }
                            current.revision
                        }
                        Err(TeamError::Rejected {
                            status: 404, code, ..
                        }) if code == "not_found" => 0,
                        Err(_) => break,
                    };
                match client.withdraw_checkout_reference(
                    &retired.organization_id,
                    &retired.repository_id,
                    &retired.id,
                    revision,
                ) {
                    Ok(result) if result.withdrawn => {
                        store.confirm_cloud_withdrawal(&binding, &retired.id)?;
                        return serialize(result);
                    }
                    Err(TeamError::Rejected {
                        status: 409, code, ..
                    }) if code == "revision_conflict" => continue,
                    _ => break,
                }
            }
            Ok(json!({"withdrawn":true,"accountCleanupPending":true}))
        }
    }
}
