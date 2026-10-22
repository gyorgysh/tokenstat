// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Read-only chat projections. Each call requires an exact, online-validated
//! share ticket as well as the publisher's current private source binding.

use super::{
    AuthorizedTeamPrincipal,
    publications::{ChatTarget, Folder, Owner, Store},
};
use crate::{
    error::DispatchError,
    remote::{TeamPageDirection, TeamReadMethod, TeamReadParams},
};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    sync::Mutex,
    time::{Duration, Instant},
};
use tokenstat_sync::teams::{Page, RepositoryRole, TeamCapability, TeamClient};

const PAGE_TARGET: usize = 512 * 1024;
/// Base64 of this fits one Team response with room to spare.
const ATTACHMENT_LIMIT: u64 = 5 * 1024 * 1024;

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
            let history = chats.shared_history(
                &checkout.workspace_id,
                &row.conversation_id,
                &row.id,
                &row.preview,
            )?;
            let marker = history.binding.clone().ok_or_else(changed)?;
            if marker.source_revision != row.source_revision {
                return Err(changed());
            }
            (
                marker,
                json!({"chat":{"id":row.id,"checkoutId":row.checkout_id,"title":history.title,
            "backend":history.backend,"historyTrimmed":history.history_trimmed,"allowsAgentRuns":super::agent_runs_ready() && super::provider::supported(&history.backend).is_ok(),
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
            if let Some(current) = current_members(&scope.organization_id) {
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
            let history = chats.shared_history(
                &checkout.workspace_id,
                &row.conversation_id,
                &row.id,
                &row.preview,
            )?;
            let marker = history.binding.clone().ok_or_else(changed)?;
            if marker.source_revision != row.source_revision {
                return Err(changed());
            }
            // Only a file the shared history shows. An id from anywhere else
            // in this chat, or in another chat, is not reachable from here.
            let shown = history.events.iter().find(|event| {
                event["event"]["kind"] == "attachment" && event["event"]["id"] == wanted
            });
            let Some(shown) = shown else {
                return Err(DispatchError::new(
                    "attachment_not_shared",
                    "This file is not part of the shared chat.",
                ));
            };
            if shown["event"]["size"]
                .as_u64()
                .is_none_or(|size| size > ATTACHMENT_LIMIT)
            {
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

/// Who is in the organization now, from the publisher's own view, held for a
/// minute so paging through a chat does not ask the server every time.
/// `None` when the list cannot be read: authors then show as recorded.
fn current_members(organization: &str) -> Option<HashSet<String>> {
    static CACHE: Mutex<Option<(String, Instant, HashSet<String>)>> = Mutex::new(None);
    if let Ok(cache) = CACHE.lock()
        && let Some((org, at, members)) = cache.as_ref()
        && org == organization
        && at.elapsed() < Duration::from_secs(60)
    {
        return Some(members.clone());
    }
    let client = TeamClient::capture().ok()?;
    let mut members = HashSet::new();
    let mut offset = 0;
    for _ in 0..20 {
        let page = client
            .members(organization, Page { limit: 100, offset })
            .ok()?;
        members.extend(page.members.into_iter().map(|member| member.person.id));
        match page.next_offset {
            Some(next) => offset = next,
            None => {
                if let Ok(mut cache) = CACHE.lock() {
                    *cache = Some((organization.to_string(), Instant::now(), members.clone()));
                }
                return Some(members);
            }
        }
    }
    None
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
