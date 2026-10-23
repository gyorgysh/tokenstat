// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Durable orchestration of folder sharing. A repository create has no retry
//! receipt on older account servers: persist its uncertain outcome before
//! sending, then require an explicit existing-project choice after interruption.
//! Checkout publication retains its original host-owned receipt throughout.

use super::{
    api_error,
    publications::{Folder, Owner, Store},
    sharing,
};
use crate::{account_session::AccountSnapshot, error::DispatchError};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokenstat_sync::teams::{
    ChangeRepositoryAccess, OrganizationRole, OrganizationState, Page, RepositoryRole, TeamClient,
};

#[cfg(test)]
mod tests;

const MAX_RECORDS: usize = 4096;
const MAX_MEMBERS: usize = 1000;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Phase {
    Ready,
    Creating,
    Repository,
    Complete,
    Discarded,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Record {
    id: String,
    owner: Owner,
    folder: Folder,
    input: Begin,
    phase: Phase,
    repository: Option<String>,
    publication: Option<Value>,
}

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Begin {
    organization: String,
    workspace: String,
    name: String,
    repository: Option<String>,
    #[serde(default)]
    member_ids: Vec<String>,
    role: RepositoryRole,
    request_id: String,
    confirm_sharing: bool,
}

pub(super) enum Request {
    Read {
        organization: Option<String>,
        workspace: String,
    },
    Begin(Begin),
    Resume {
        setup: String,
        repository: Option<String>,
    },
    Discard {
        setup: String,
    },
}

fn invalid() -> DispatchError {
    DispatchError::new(
        "invalid_request",
        "Review the project sharing choices and try again.",
    )
}
fn unavailable() -> DispatchError {
    DispatchError::new(
        "sharing_setup_unavailable",
        "This sharing setup is unavailable. Keep its records and try again.",
    )
}
fn id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}
pub(super) fn valid_id(value: &str) -> bool {
    value
        .strip_prefix("setup_")
        .is_some_and(|s| s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit()))
}
impl Begin {
    fn validate(&self) -> bool {
        id(&self.organization)
            && !self.workspace.is_empty()
            && self.workspace.len() <= 16 * 1024
            && !self.name.is_empty()
            && self.name.encode_utf16().count() <= 80
            && !self.name.chars().any(char::is_control)
            && self.repository.as_deref().is_none_or(id)
            && (self.repository.is_none() || self.member_ids.is_empty())
            && self.member_ids.len() <= MAX_MEMBERS
            && self.member_ids.iter().all(|s| id(s))
            && self.member_ids.windows(2).all(|pair| pair[0] < pair[1])
            && matches!(
                self.role,
                RepositoryRole::Viewer | RepositoryRole::Contributor
            )
            && crate::chat_receipts::valid_id(&self.request_id)
            && self.confirm_sharing
    }
}
pub(super) fn validate(rows: &[Record]) -> Result<(), DispatchError> {
    let mut ids = std::collections::HashSet::new();
    let mut requests = std::collections::HashSet::new();
    let mut unfinished = std::collections::HashSet::new();
    if rows.len() > MAX_RECORDS
        || rows.iter().any(|r| {
            !valid_id(&r.id)
                || !ids.insert(&r.id)
                || !id(&r.owner.publisher_id)
                || r.owner.issuer.is_empty()
                || r.owner.issuer.len() > 2048
                || r.owner.issuer.chars().any(char::is_control)
                || r.owner.host_key.len() != 64
                || !r.owner.host_key.bytes().all(|b| b.is_ascii_hexdigit())
                || !requests.insert((
                    &r.owner.issuer,
                    &r.owner.publisher_id,
                    &r.owner.host_key,
                    &r.input.request_id,
                ))
                || !matches!(r.phase, Phase::Complete | Phase::Discarded)
                    && !unfinished.insert((
                        &r.owner.issuer,
                        &r.owner.publisher_id,
                        &r.owner.host_key,
                        &r.input.organization,
                        &r.input.workspace,
                    ))
                || !r.input.validate()
                || r.repository.as_deref().is_some_and(|s| !id(s))
                || matches!(r.phase, Phase::Ready | Phase::Creating) && r.repository.is_some()
                || matches!(r.phase, Phase::Repository | Phase::Complete) && r.repository.is_none()
                || (r.phase == Phase::Complete) != r.publication.is_some()
                || r.publication.as_ref().is_some_and(|p| {
                    p.get("organizationId").and_then(Value::as_str)
                        != Some(r.input.organization.as_str())
                        || p.get("repositoryId").and_then(Value::as_str) != r.repository.as_deref()
                        || p.get("workspaceId").and_then(Value::as_str)
                            != Some(r.input.workspace.as_str())
                        || p.get("phase").and_then(Value::as_str) != Some("active")
                        || !p.get("id").and_then(Value::as_str).is_some_and(|s| {
                            s.strip_prefix("checkout_").is_some_and(|s| {
                                s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit())
                            })
                        })
                })
                || !r.folder.canonical.is_absolute()
        })
    {
        return Err(unavailable());
    }
    Ok(())
}
pub(super) fn parse(method: &str, body: Value) -> Option<Result<Request, DispatchError>> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Read {
        organization: Option<String>,
        workspace: String,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Resume {
        setup: String,
        repository: Option<String>,
        confirm_sharing: bool,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Discard {
        setup: String,
        confirm_discard: bool,
    }
    Some(match method {
        "teams.projectSharing.read" => serde_json::from_value::<Read>(body)
            .map_err(|_| invalid())
            .and_then(|r| {
                if r.organization.as_deref().is_some_and(|s| !id(s))
                    || r.workspace.is_empty()
                    || r.workspace.len() > 16 * 1024
                {
                    return Err(invalid());
                }
                Ok(Request::Read {
                    organization: r.organization,
                    workspace: r.workspace,
                })
            }),
        "teams.projectSharing.begin" => serde_json::from_value::<Begin>(body)
            .map_err(|_| invalid())
            .and_then(|mut r| {
                r.name = r.name.trim().to_owned();
                r.member_ids.sort();
                r.member_ids.dedup();
                if !r.validate() {
                    return Err(invalid());
                }
                Ok(Request::Begin(r))
            }),
        "teams.projectSharing.resume" => serde_json::from_value::<Resume>(body)
            .map_err(|_| invalid())
            .and_then(|r| {
                if !r.confirm_sharing
                    || !valid_id(&r.setup)
                    || r.repository.as_deref().is_some_and(|s| !id(s))
                {
                    return Err(invalid());
                }
                Ok(Request::Resume {
                    setup: r.setup,
                    repository: r.repository,
                })
            }),
        "teams.projectSharing.discard" => serde_json::from_value::<Discard>(body)
            .map_err(|_| invalid())
            .and_then(|r| {
                if !r.confirm_discard || !valid_id(&r.setup) {
                    return Err(invalid());
                }
                Ok(Request::Discard { setup: r.setup })
            }),
        _ => return None,
    })
}

fn dto(record: &Record) -> Value {
    json!({"id":record.id, "organizationId":record.input.organization, "workspaceId":record.input.workspace,
        "name":record.input.name, "repositoryId":record.repository, "memberIds":record.input.member_ids,
        "role":record.input.role, "phase":record.phase, "needsRepositoryChoice":record.phase == Phase::Creating,
        "publication":record.publication, "sharesExistingChats":false, "allowsAgentRuns":false})
}
fn owned(store: &Store, owner: &Owner, setup: &str) -> Result<Record, DispatchError> {
    store.project_setups(|rows| {
        rows.iter()
            .find(|r| r.id == setup && r.owner == *owner)
            .cloned()
            .ok_or_else(unavailable)
    })
}
fn save(store: &Store, before: &Record, after: &Record) -> Result<(), DispatchError> {
    store.project_setups(|rows| {
        let row = rows
            .iter_mut()
            .find(|r| r.id == before.id && r.owner == before.owner)
            .ok_or_else(unavailable)?;
        if row != before {
            return Err(DispatchError::new(
                "sharing_setup_changed",
                "This sharing setup changed. Open its current review again.",
            ));
        }
        *row = after.clone();
        Ok(())
    })
}
fn current(
    owner: &AccountSnapshot,
    client: &TeamClient,
    record: &Record,
) -> Result<(), DispatchError> {
    owner.ensure_current().map_err(super::changed)?;
    client.ensure_current().map_err(api_error)?;
    let workspace = crate::workspaces::get(&record.input.workspace).map_err(|_| {
        DispatchError::new(
            "checkout_missing",
            "Choose the original project folder again.",
        )
    })?;
    if Folder::capture(&workspace.path)? != record.folder {
        return Err(DispatchError::new(
            "checkout_changed",
            "This project folder changed. Review a new sharing setup.",
        ));
    }
    record.folder.ensure_current()
}
fn organization(client: &TeamClient, record: &Record, create: bool) -> Result<(), DispatchError> {
    let org = client
        .organization(&record.input.organization)
        .map_err(api_error)?
        .organization;
    if org.id != record.input.organization
        || org.state != OrganizationState::Active
        || !org.eligible
        || (create || !record.input.member_ids.is_empty())
            && !matches!(org.role, OrganizationRole::Owner | OrganizationRole::Admin)
    {
        return Err(DispatchError::new(
            "sharing_access_changed",
            "Team access changed. Review the current project and teammates before continuing.",
        ));
    }
    Ok(())
}
fn review_members(client: &TeamClient, record: &Record) -> Result<(), DispatchError> {
    if record.input.member_ids.is_empty() {
        return Ok(());
    }
    let mut remaining: std::collections::HashSet<_> =
        record.input.member_ids.iter().map(String::as_str).collect();
    let mut offset = 0;
    for _ in 0..=10 {
        let page = client
            .members(&record.input.organization, Page { limit: 100, offset })
            .map_err(api_error)?;
        for member in page.members {
            if member.eligible {
                remaining.remove(member.person.id.as_str());
            }
        }
        if remaining.is_empty() {
            return Ok(());
        }
        match page.next_offset {
            Some(next) if next > offset => offset = next,
            _ => break,
        }
    }
    Err(DispatchError::new(
        "sharing_access_changed",
        "A selected teammate left or is no longer eligible. Review the current team before continuing.",
    ))
}
fn access(client: &TeamClient, record: &Record, grant: bool) -> Result<(), DispatchError> {
    if record.input.member_ids.is_empty() {
        return Ok(());
    }
    let repository = record.repository.as_deref().ok_or_else(unavailable)?;
    let mut members = std::collections::HashMap::new();
    let mut offset = 0;
    let mut complete = false;
    for _ in 0..=10 {
        let page = client
            .repository_members(
                &record.input.organization,
                repository,
                Page { limit: 100, offset },
            )
            .map_err(api_error)?;
        for member in page.members {
            if members.insert(member.person.id.clone(), member).is_some() {
                return Err(unavailable());
            }
        }
        match page.next_offset {
            None => {
                complete = true;
                break;
            }
            Some(next) if next > offset => offset = next,
            _ => return Err(unavailable()),
        }
    }
    if !complete {
        return Err(unavailable());
    }
    let mut changes = Vec::new();
    for id in &record.input.member_ids {
        let member = members.get(id).filter(|m| m.eligible).ok_or_else(|| DispatchError::new("sharing_access_changed", "A selected teammate is no longer eligible. Review the current team before continuing."))?;
        if member.role == Some(record.input.role) || member.role == Some(RepositoryRole::Maintainer)
        {
            continue;
        }
        if grant && member.role.is_none() && member.revision == 0 {
            changes.push(id);
        } else {
            return Err(DispatchError::new(
                "sharing_access_changed",
                "A teammate’s access changed. This setup will not restore or replace that access.",
            ));
        }
    }
    for user in changes {
        client
            .repository_access(
                &record.input.organization,
                repository,
                user,
                &ChangeRepositoryAccess {
                    role: Some(record.input.role),
                    expected_revision: 0,
                },
            )
            .map_err(api_error)?;
    }
    Ok(())
}
fn share(
    owner: &AccountSnapshot,
    client: &TeamClient,
    method: &str,
    fields: Value,
) -> Result<Value, DispatchError> {
    sharing::perform(
        owner,
        client,
        sharing::parse(method, fields).ok_or_else(invalid)??,
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
        Request::Read {
            organization,
            workspace,
        } => {
            let rows = store.project_setups(|rows| {
                Ok(rows
                    .iter()
                    .filter(|r| {
                        r.owner == binding
                            && organization
                                .as_ref()
                                .is_none_or(|org| r.input.organization == *org)
                            && r.input.workspace == workspace
                            && !matches!(r.phase, Phase::Complete | Phase::Discarded)
                    })
                    .cloned()
                    .collect::<Vec<_>>())
            })?;
            if rows.len() > 1 {
                return Err(unavailable());
            }
            let workspace = rows
                .first()
                .and_then(|r| crate::workspaces::get(&r.input.workspace).ok())
                .map(|w| json!({"id":w.id,"name":w.name,"path":w.path}));
            Ok(json!({"setup": rows.first().map(dto), "workspace": workspace}))
        }
        Request::Begin(input) => {
            if sharing::binding(client)? != binding {
                return Err(unavailable());
            }
            let workspace = crate::workspaces::get(&input.workspace).map_err(|_| invalid())?;
            let record = Record {
                id: super::publications::opaque("setup"),
                owner: binding.clone(),
                folder: Folder::capture(&workspace.path)?,
                repository: input.repository.clone(),
                phase: if input.repository.is_some() {
                    Phase::Repository
                } else {
                    Phase::Ready
                },
                input,
                publication: None,
            };
            current(owner, client, &record)?;
            if let Some(prior) = store.project_setups(|rows| {
                Ok(rows
                    .iter()
                    .find(|r| r.owner == binding && r.input.request_id == record.input.request_id)
                    .cloned())
            })? {
                if prior.input != record.input
                    || prior.folder != record.folder
                    || prior.phase == Phase::Discarded
                {
                    return Err(invalid());
                }
                return Ok(json!({"setup":dto(&prior)}));
            }
            store.ensure_setup_target(
                &binding,
                &record.folder,
                &record.input.organization,
                record.repository.as_deref(),
            )?;
            organization(client, &record, record.repository.is_none())?;
            review_members(client, &record)?;
            let record = store.project_setups(|rows| {
                if let Some(prior) = rows.iter().find(|r| r.owner == binding && r.input.request_id == record.input.request_id) {
                    if prior.input != record.input || prior.folder != record.folder || prior.phase == Phase::Discarded { return Err(invalid()); }
                    return Ok(prior.clone());
                }
                if rows.iter().any(|r| r.owner == binding && r.folder.physical_match(&record.folder)
                    && !matches!(r.phase, Phase::Complete | Phase::Discarded)) {
                    return Err(DispatchError::new("sharing_setup_pending", "This folder already has an unfinished sharing setup. Open its saved review."));
                }
                if rows.len() >= MAX_RECORDS { return Err(DispatchError::new("sharing_setup_limit", "Sharing records are full. Existing setups and receipts are kept; no new setup was started.")); }
                rows.push(record.clone()); Ok(record)
            })?;
            Ok(json!({"setup":dto(&record)}))
        }
        Request::Discard { setup } => {
            let _lease = store.project_setup_lease(&setup)?;
            let record = owned(&store, &binding, &setup)?;
            if record.phase == Phase::Complete {
                return Err(invalid());
            }
            let mut after = record.clone();
            after.phase = Phase::Discarded;
            save(&store, &record, &after)?;
            Ok(json!({"setup":dto(&after), "keepsExistingProjectAndAccess":true}))
        }
        Request::Resume { setup, repository } => {
            let _lease = store.project_setup_lease(&setup)?;
            let mut record = owned(&store, &binding, &setup)?;
            current(owner, client, &record)?;
            if sharing::binding(client)? != binding {
                return Err(unavailable());
            }
            if record.phase == Phase::Discarded {
                return Err(invalid());
            }
            if record.phase == Phase::Creating && repository.is_none() {
                return Ok(json!({"setup":dto(&record)}));
            }
            if let Some(repository) = repository {
                if record.phase != Phase::Creating {
                    return Err(invalid());
                }
                sharing::repository(client, &record.input.organization, &repository)?;
                organization(client, &record, false)?;
                let mut after = record.clone();
                after.repository = Some(repository);
                after.phase = Phase::Repository;
                current(owner, client, &record)?;
                save(&store, &record, &after)?;
                record = after;
            }
            if record.phase == Phase::Ready {
                store.ensure_setup_target(
                    &binding,
                    &record.folder,
                    &record.input.organization,
                    None,
                )?;
                organization(client, &record, true)?;
                review_members(client, &record)?;
                let mut creating = record.clone();
                creating.phase = Phase::Creating;
                // Persist BEFORE the one non-idempotent request. Any uncertain
                // outcome remains Creating and cannot repeat this call.
                current(owner, client, &record)?;
                save(&store, &record, &creating)?;
                record = creating;
                let reply = client
                    .create_repository(&record.input.organization, &record.input.name)
                    .map_err(api_error)?
                    .repository;
                if reply.organization_id != record.input.organization
                    || !id(&reply.id)
                    || reply.role != Some(RepositoryRole::Maintainer)
                {
                    return Err(unavailable());
                }
                let mut after = record.clone();
                after.repository = Some(reply.id);
                after.phase = Phase::Repository;
                current(owner, client, &record)?;
                save(&store, &record, &after)?;
                record = after;
            }
            organization(client, &record, false)?;
            let repository = record.repository.as_deref().ok_or_else(unavailable)?;
            store.ensure_setup_target(
                &binding,
                &record.folder,
                &record.input.organization,
                Some(repository),
            )?;
            let current_repository =
                sharing::repository(client, &record.input.organization, repository)?;
            if record.phase == Phase::Complete {
                let publication = record.publication.as_ref().ok_or_else(unavailable)?;
                let id = publication
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or_else(unavailable)?;
                store.resolve(&binding, &record.input.organization, repository, id)?;
                let cloud = client
                    .checkout_publication(&record.input.organization, id)
                    .map_err(api_error)?
                    .checkout;
                if cloud.id != id
                    || cloud.publisher_id != binding.publisher_id
                    || cloud.host_key != binding.host_key
                    || cloud.organization_id != record.input.organization
                    || cloud.repository_id != repository
                {
                    return Err(unavailable());
                }
                return Ok(
                    json!({"setup":dto(&record), "repository":current_repository, "publication":publication}),
                );
            }
            access(client, &record, true)?;
            current(owner, client, &record)?;
            access(client, &record, false)?;
            let target = json!({"organization":record.input.organization,"repository":repository,"workspace":record.input.workspace});
            let preview = share(owner, client, "teams.checkout.preview", target.clone())?;
            let mut publish = target;
            publish["preview"] = preview["preview"].clone();
            publish["requestId"] = json!(record.input.request_id);
            publish["confirmSharing"] = json!(true);
            current(owner, client, &record)?;
            let result = share(owner, client, "teams.checkout.publish", publish)?;
            let publication = result
                .get("publication")
                .filter(|v| v.is_object())
                .cloned()
                .ok_or_else(unavailable)?;
            let mut after = record.clone();
            after.phase = Phase::Complete;
            after.publication = Some(publication.clone());
            current(owner, client, &record)?;
            save(&store, &record, &after)?;
            Ok(
                json!({"setup":dto(&after), "repository":current_repository, "publication":publication}),
            )
        }
    }
}
