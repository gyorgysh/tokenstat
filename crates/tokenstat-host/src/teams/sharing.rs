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
use tokenstat_sync::teams::{Page, Repository, RepositoryRole, Revision, TeamClient, TeamError};

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
fn binding(client: &TeamClient) -> Result<Owner, DispatchError> {
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
    if !capabilities
        .features
        .iter()
        .any(|feature| feature == "checkout-publication")
    {
        return Err(DispatchError::new(
            "teams_unavailable",
            "Checkout sharing is not available on this account server yet.",
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
fn local_binding(owner: &AccountSnapshot, client: &TeamClient) -> Result<Owner, DispatchError> {
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
fn repository(
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
            Ok(json!({"publication":local_dto(&active)}))
        }
        Request::List {
            page,
            organization,
            repository,
        } => {
            page.validate().map_err(api_error)?;
            let binding = local_binding(owner, client)?;
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
            if retired.cloud_withdrawn {
                return Ok(json!({"withdrawn":true}));
            }
            let revision = match client.checkout_publication(&retired.organization_id, &retired.id)
            {
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
                    Some(current.revision)
                }
                Err(TeamError::Rejected {
                    status: 404, code, ..
                }) if code == "not_found" => {
                    store.confirm_cloud_withdrawal(&binding, &retired.id)?;
                    return Ok(json!({"withdrawn":true}));
                }
                Err(_) => None,
            };
            let Some(expected_revision) = revision else {
                return Ok(json!({"withdrawn":true,"accountCleanupPending":true}));
            };
            match client.withdraw_checkout(
                &retired.organization_id,
                &retired.id,
                Revision { expected_revision },
            ) {
                Ok(result) if result.withdrawn => {
                    store.confirm_cloud_withdrawal(&binding, &retired.id)?;
                    serialize(result)
                }
                Ok(_) => Ok(json!({"withdrawn":true,"accountCleanupPending":true})),
                Err(TeamError::Rejected {
                    status: 404, code, ..
                }) if code == "not_found" => {
                    store.confirm_cloud_withdrawal(&binding, &retired.id)?;
                    Ok(json!({"withdrawn":true}))
                }
                Err(_) => Ok(json!({"withdrawn":true,"accountCleanupPending":true})),
            }
        }
    }
}
