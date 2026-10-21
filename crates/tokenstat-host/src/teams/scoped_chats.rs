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
use tokenstat_sync::teams::{RepositoryRole, TeamCapability};

const PAGE_TARGET: usize = 512 * 1024;

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
    let result = match method {
        TeamReadMethod::ChatDetails => {
            json!({"chat":{"id":row.id,"checkoutId":row.checkout_id,"title":history.title,
            "backend":history.backend,"historyTrimmed":history.history_trimmed,"allowsAgentRuns":false,
            "allowsComments":row.source_revision.is_some() && matches!(scope.role,RepositoryRole::Contributor | RepositoryRole::Maintainer)}})
        }
        TeamReadMethod::ChatEvents => page(share, history.events, history.history_trimmed, params)?,
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

fn changed() -> DispatchError {
    DispatchError::new(
        "chat_not_shared",
        "This chat is no longer available from that checkout.",
    )
}

fn page(
    share: &str,
    events: Vec<Value>,
    history_trimmed: bool,
    params: &TeamReadParams,
) -> Result<Value, DispatchError> {
    let after = params.after(share)?;
    let latest = events.last().and_then(|event| event["seq"].as_u64());
    if after.is_some_and(|position| latest.is_none_or(|last| position > last)) {
        return Err(DispatchError::new(
            "chat_cursor_invalid",
            "Refresh this shared chat's history.",
        ));
    }
    let limit = params.limit.unwrap_or(100) as usize;
    let older = params.direction == Some(TeamPageDirection::Older);
    let mut selected = Vec::new();
    let mut size = 0;
    let mut more = false;
    let mut events = events;
    if older {
        events.reverse();
    }
    for event in events.into_iter().filter(|event| {
        after.is_none_or(|after| {
            event["seq"]
                .as_u64()
                .is_some_and(|seq| if older { seq < after } else { seq > after })
        })
    }) {
        let bytes = serde_json::to_vec(&event).map_err(|_| changed())?.len();
        if selected.len() == limit || !selected.is_empty() && size + bytes > PAGE_TARGET {
            more = true;
            break;
        }
        size += bytes;
        selected.push(event);
    }
    if older {
        selected.reverse();
    }
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
    Ok(
        json!({"shareId":share,"events":selected,"nextCursor":next,"firstCursor":first,"lastCursor":last,"hasMore":more,"historyTrimmed":history_trimmed,"asOfMs":crate::chat::now_ms()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
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
                cursor: Some(first["nextCursor"].as_str().unwrap().into()),
            },
        )
        .unwrap();
        assert_eq!(previous["events"], json!([{"seq":0}]));
        assert_eq!(previous["hasMore"], false);
    }
}
