// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Read-only chat projections. Each call requires an exact, online-validated
//! share ticket as well as the publisher's current private source binding.

use super::{
    AuthorizedTeamPrincipal,
    publications::{ChatShare, ChatTarget, Folder, Owner, Store},
};
use crate::{
    error::DispatchError,
    remote::{TeamPageDirection, TeamReadMethod, TeamReadParams},
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    sync::Mutex,
    time::{Duration, Instant},
};
use tokenstat_sync::teams::{Page, RepositoryRole, TeamCapability, TeamClient};

const PAGE_TARGET: usize = 512 * 1024;
/// Base64 of this fits one Team response with room to spare.
const ATTACHMENT_LIMIT: u64 = 5 * 1024 * 1024;

fn allows_agent_runs(ready: bool, backend: &str, role: RepositoryRole) -> bool {
    ready
        && matches!(
            role,
            RepositoryRole::Contributor | RepositoryRole::Maintainer
        )
        && super::provider::supported(backend).is_ok()
}

pub(super) fn call(
    principal: &AuthorizedTeamPrincipal,
    method: TeamReadMethod,
    params: &TeamReadParams,
) -> Result<Value, DispatchError> {
    let scope = principal.value();
    let share = scope
        .share_id
        .as_deref()
        .filter(|_| scope.capabilities.contains(&TeamCapability::Read))
        .ok_or_else(|| {
            DispatchError::new(
                "chat_scope_required",
                "Open this shared chat to read its history.",
            )
        })?;
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
    let row = store.resolve_chat(&target, share)?;
    let workspace = crate::workspaces::get(&checkout.workspace_id).map_err(|_| changed())?;
    if Folder::capture(&workspace.path)? != checkout.folder {
        return Err(changed());
    }
    let chats = crate::chat::shared();
    let (marker, result) = match method {
        TeamReadMethod::ChatDetails => {
            let history = chats.shared_chat_index(
                &checkout.workspace_id,
                &row.conversation_id,
                &row.id,
                &row.preview,
            )?;
            let marker = history.binding;
            if marker.source_revision != row.source_revision {
                return Err(changed());
            }
            (
                marker,
                json!({"chat":{"id":row.id,"checkoutId":row.checkout_id,"title":history.title,
            "backend":history.backend,"historyTrimmed":history.history_trimmed,"allowsAgentRuns":allows_agent_runs(super::agent_runs_ready() && super::agent_access::allows(scope), &history.backend, scope.role),
            "allowsComments":row.source_revision.is_some() && matches!(scope.role,RepositoryRole::Contributor | RepositoryRole::Maintainer)}}),
            )
        }
        TeamReadMethod::ChatEvents => {
            let older = params.direction == Some(TeamPageDirection::Older);
            let viewed = chats.shared_event_page(
                &checkout.workspace_id,
                &row.conversation_id,
                &row.id,
                &row.preview,
                &crate::chat::sharing::PageRequest {
                    after: params.after(share)?,
                    older,
                    limit: params.limit.unwrap_or(100) as usize,
                    budget: PAGE_TARGET,
                },
            )?;
            if viewed.binding.source_revision != row.source_revision {
                return Err(changed());
            }
            let mut events = viewed.events;
            if let Some(current) =
                current_members(principal.issuer(), &scope.organization_id, scope.epoch)
            {
                for event in &mut events {
                    former_authors(event, &current);
                }
            }
            let body = page_body(
                share,
                events,
                viewed.has_more,
                viewed.history_trimmed,
                older,
                params.after(share)?,
            );
            (viewed.binding, body)
        }
        TeamReadMethod::ChatAttachment => {
            let wanted = params.attachment.as_deref().ok_or_else(changed)?;
            // Only a file the shared history shows. An id from anywhere else
            // in this chat, or in another chat, is not reachable from here.
            // The bounded file index is cached per shared revision. Archived
            // agent output cannot add files and is never expanded here.
            let (marker, size) = match shown_file(&row, wanted) {
                Some(found) => found,
                None => {
                    let history = chats.shared_chat_index(
                        &checkout.workspace_id,
                        &row.conversation_id,
                        &row.id,
                        &row.preview,
                    )?;
                    let marker = history.binding;
                    if marker.source_revision != row.source_revision {
                        return Err(changed());
                    }
                    let files = history.files;
                    let size = files.get(wanted).copied();
                    remember_files(&row, marker.clone(), files);
                    let Some(size) = size else {
                        return Err(not_shared());
                    };
                    (marker, size)
                }
            };
            if size > ATTACHMENT_LIMIT {
                return Err(too_large());
            }
            let data = chats
                .attachment_data(&row.conversation_id, wanted)
                .map_err(|_| {
                    DispatchError::new(
                        "attachment_unavailable",
                        "This file is no longer on the publishing computer.",
                    )
                })?;
            if data
                .attachment
                .size
                .is_none_or(|size| size > ATTACHMENT_LIMIT)
            {
                return Err(too_large());
            }
            (
                marker,
                json!({"shareId":share,"attachment":data.attachment,"data":data.data}),
            )
        }
        _ => return Err(changed()),
    };
    // A local withdrawal or folder replacement that raced the bounded read
    // must not publish a late result. A retired reference cannot be reused.
    if store.resolve_chat(&target, share)? != row
        || store.resolve(
            &owner,
            target.organization,
            target.repository,
            target.checkout,
        )? != checkout
        || Folder::capture(&workspace.path)? != checkout.folder
    {
        return Err(changed());
    }
    // Canonical-only recovery can leave a damaged or restored map intact.
    // Recheck the exact source marker, not just its private map reference.
    chats.ensure_sharing_snapshot(&checkout.workspace_id, &row.conversation_id, &marker)?;
    principal.ensure_live()?;
    Ok(result)
}

/// Who is in the organization now, from the publisher's own view. Reuse a
/// roster within its verified membership epoch for at most a minute.
/// `None` when the list cannot be read: authors then show as recorded.
struct MemberRoster {
    issuer: String,
    organization: String,
    epoch: u64,
    at: Instant,
    members: HashSet<String>,
}
fn cached_members(
    cache: &Mutex<Option<MemberRoster>>,
    issuer: &str,
    organization: &str,
    epoch: u64,
    load: impl FnOnce() -> Option<HashSet<String>>,
) -> Option<HashSet<String>> {
    if let Ok(cached) = cache.lock()
        && let Some(roster) = cached.as_ref()
        && roster.issuer == issuer
        && roster.organization == organization
        && roster.epoch == epoch
        && roster.at.elapsed() < Duration::from_secs(60)
    {
        return Some(roster.members.clone());
    }
    let members = load()?;
    if let Ok(mut cached) = cache.lock() {
        *cached = Some(MemberRoster {
            issuer: issuer.into(),
            organization: organization.into(),
            epoch,
            at: Instant::now(),
            members: members.clone(),
        });
    }
    Some(members)
}
fn current_members(issuer: &str, organization: &str, epoch: u64) -> Option<HashSet<String>> {
    static CACHE: Mutex<Option<MemberRoster>> = Mutex::new(None);
    cached_members(&CACHE, issuer, organization, epoch, || {
        let client = TeamClient::capture().ok()?;
        if client.origin() != issuer {
            return None;
        }
        let mut members = HashSet::new();
        let mut offset = 0;
        for _ in 0..20 {
            let page = client
                .members(organization, Page { limit: 100, offset })
                .ok()?;
            members.extend(page.members.into_iter().map(|member| member.person.id));
            match page.next_offset {
                Some(next) => offset = next,
                None => return Some(members),
            }
        }
        None
    })
}

/// A person who has left the organization, or deleted their account, reads
/// as a former member with nothing that links back to them. The event keeps
/// its place, so the conversation still reads in order.
fn former_authors(event: &mut Value, current: &HashSet<String>) {
    let former = |person: &mut Value| {
        if person["kind"] == "person"
            && person["id"]
                .as_str()
                .is_some_and(|id| !current.contains(id))
        {
            *person = json!({"kind":"formerMember"});
        }
    };
    if let Some(author) = event.get_mut("author") {
        former(author);
        if let Some(initiator) = author.get_mut("initiatedBy") {
            former(initiator);
        }
    }
}

type ChatMarker = crate::chat::sharing::Binding;
type ShownFiles = (ChatShare, ChatMarker, HashMap<String, u64>);
static SHOWN: Mutex<Vec<ShownFiles>> = Mutex::new(Vec::new());

/// The file's size when this exact share record, unchanged in every field,
/// is known to show it, and the chat still carries the same binding.
/// `None` means not cached: that share is read in full.
fn shown_file(row: &ChatShare, wanted: &str) -> Option<(ChatMarker, u64)> {
    row.source_revision?;
    let cache = SHOWN.lock().ok()?;
    let (_, marker, files) = cache.iter().find(|(cached, _, _)| cached == row)?;
    Some((marker.clone(), *files.get(wanted)?))
}

fn remember_files(row: &ChatShare, marker: ChatMarker, files: HashMap<String, u64>) {
    if row.source_revision.is_none() || marker.source_revision != row.source_revision {
        return;
    }
    if let Ok(mut cache) = SHOWN.lock() {
        cache.retain(|(cached, _, _)| cached.id != row.id);
        if cache.len() >= 32 {
            cache.remove(0);
        }
        cache.push((row.clone(), marker, files));
    }
}

fn not_shared() -> DispatchError {
    DispatchError::new(
        "attachment_not_shared",
        "This file is not part of the shared chat.",
    )
}

fn too_large() -> DispatchError {
    DispatchError::new(
        "attachment_too_large",
        "This file is too large to open from another computer.",
    )
}

fn changed() -> DispatchError {
    DispatchError::new(
        "chat_not_shared",
        "This chat is no longer available from that checkout.",
    )
}

#[cfg(test)]
fn page(
    share: &str,
    events: Vec<Value>,
    history_trimmed: bool,
    params: &TeamReadParams,
) -> Result<Value, DispatchError> {
    let after = params.after(share)?;
    let older = params.direction == Some(TeamPageDirection::Older);
    let (events, has_more) = crate::chat::sharing::select_inline_page(
        &events,
        &crate::chat::sharing::PageRequest {
            after,
            older,
            limit: params.limit.unwrap_or(100) as usize,
            budget: PAGE_TARGET,
        },
    )?;
    Ok(page_body(
        share,
        events,
        has_more,
        history_trimmed,
        older,
        after,
    ))
}

fn page_body(
    share: &str,
    selected: Vec<Value>,
    more: bool,
    history_trimmed: bool,
    older: bool,
    after: Option<u64>,
) -> Value {
    let cursor = |position| format!("v1:{share}:{position}");
    let first = selected
        .first()
        .and_then(|event| event["seq"].as_u64())
        .map(cursor);
    let last = selected
        .last()
        .and_then(|event| event["seq"].as_u64())
        .map(cursor);
    let next = (if older {
        selected.first()
    } else {
        selected.last()
    })
    .and_then(|event| event["seq"].as_u64())
    .or(after)
    .map(cursor);
    json!({"shareId":share,"events":selected,"nextCursor":next,"firstCursor":first,"lastCursor":last,"hasMore":more,"historyTrimmed":history_trimmed,"asOfMs":crate::chat::now_ms()})
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn membership_changes_refresh_author_names_without_waiting_for_roster_expiry() {
        let cache = Mutex::new(None);
        let issuer = "https://accounts.example.test";
        let people = |ids: &[&str]| ids.iter().map(|id| (*id).to_string()).collect();
        let old = cached_members(&cache, issuer, "org", 1, || Some(people(&["owner"]))).unwrap();
        let mut before = json!({"author":{"kind":"person","id":"joined","name":"New teammate"}});
        former_authors(&mut before, &old);
        assert_eq!(before["author"]["kind"], "formerMember");
        let joined = cached_members(&cache, issuer, "org", 2, || {
            Some(people(&["owner", "joined"]))
        })
        .unwrap();
        let mut named = json!({"author":{"kind":"person","id":"joined","name":"New teammate"}});
        former_authors(&mut named, &joined);
        assert_eq!(named["author"]["name"], "New teammate");
        // Paging within the same verified membership epoch can reuse the list.
        assert!(
            cached_members(&cache, issuer, "org", 2, || panic!(
                "unchanged roster refetched"
            ))
            .unwrap()
            .contains("joined")
        );
        let removed =
            cached_members(&cache, issuer, "org", 3, || Some(people(&["owner"]))).unwrap();
        former_authors(&mut named, &removed);
        assert_eq!(named["author"], json!({"kind":"formerMember"}));
        assert!(cached_members(&cache, "https://other.example.test", "org", 3, || None).is_none());
        assert!(cached_members(&cache, issuer, "org", 4, || None).is_none());
    }

    #[test]
    fn read_only_members_are_never_offered_agent_execution() {
        for ready in [false, true] {
            for role in [
                RepositoryRole::Viewer,
                RepositoryRole::Contributor,
                RepositoryRole::Maintainer,
            ] {
                for backend in crate::automations::agent_backends()
                    .map(|backend| backend.id)
                    .chain(["sh", "unknown"])
                {
                    assert_eq!(
                        allows_agent_runs(ready, backend, role),
                        ready
                            && !matches!(backend, "sh" | "unknown")
                            && role != RepositoryRole::Viewer,
                        "{ready:?} {backend} {role:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn people_who_left_read_as_former_members() {
        let current = HashSet::from(["kept".to_string()]);
        let mut comment = json!({"kind":"user","author":{"kind":"person","id":"gone","name":"Gone","handle":"gone","avatar":"a"}});
        let mut reply = json!({"kind":"agent","author":{"kind":"agent","initiatedBy":{"kind":"person","id":"gone","name":"Gone"}}});
        let mut stays = json!({"author":{"kind":"person","id":"kept","name":"Kept"}});
        let mut local = json!({"author":{"kind":"localBeforeTeams"}});
        for event in [&mut comment, &mut reply, &mut stays, &mut local] {
            former_authors(event, &current);
        }
        assert_eq!(comment["author"], json!({"kind":"formerMember"}));
        assert_eq!(
            reply["author"]["initiatedBy"],
            json!({"kind":"formerMember"})
        );
        assert_eq!(reply["author"]["kind"], "agent");
        assert_eq!(stays["author"]["name"], "Kept");
        assert_eq!(local["author"]["kind"], "localBeforeTeams");
    }
    #[test]
    fn pages_keep_large_events_whole_and_cursors_cannot_cross_shares() {
        let events = vec![
            json!({"seq":0,"text":"a".repeat(PAGE_TARGET+1)}),
            json!({"seq":1,"text":"tail"}),
        ];
        let first = page(
            "share_one",
            events.clone(),
            true,
            &TeamReadParams::default(),
        )
        .unwrap();
        assert_eq!(first["events"].as_array().unwrap().len(), 1);
        assert_eq!(first["hasMore"], true);
        let params = TeamReadParams {
            cursor: Some(first["nextCursor"].as_str().unwrap().into()),
            limit: Some(1),
            direction: None,
            client_message_id: None,
            attachment: None,
        };
        assert!(page("share_other", events.clone(), false, &params).is_err());
        let last = page("share_one", events.clone(), false, &params).unwrap();
        assert_eq!(last["events"][0]["text"], "tail");
        assert_eq!(last["hasMore"], false);
        assert!(
            page(
                "share_one",
                events,
                false,
                &TeamReadParams {
                    cursor: Some("v1:share_one:2".into()),
                    limit: None,
                    direction: None,
                    client_message_id: None,
                    attachment: None,
                }
            )
            .is_err()
        );
    }
    #[test]
    fn newest_pages_are_chronological_and_older_reads_do_not_repeat_the_boundary() {
        let events = vec![json!({"seq":0}), json!({"seq":10}), json!({"seq":20})];
        let first = page(
            "share_one",
            events.clone(),
            false,
            &TeamReadParams {
                limit: Some(2),
                direction: Some(TeamPageDirection::Older),
                client_message_id: None,
                attachment: None,
                cursor: None,
            },
        )
        .unwrap();
        assert_eq!(first["events"], json!([{"seq":10},{"seq":20}]));
        assert_eq!(first["hasMore"], true);
        let previous = page(
            "share_one",
            events,
            false,
            &TeamReadParams {
                limit: Some(2),
                direction: Some(TeamPageDirection::Older),
                client_message_id: None,
                attachment: None,
                cursor: Some(first["nextCursor"].as_str().unwrap().into()),
            },
        )
        .unwrap();
        assert_eq!(previous["events"], json!([{"seq":0}]));
        assert_eq!(previous["hasMore"], false);
    }
}
