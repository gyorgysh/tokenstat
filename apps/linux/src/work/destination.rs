// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! WorkDestinationResolver and WorkPlaceRestoration's folder matching.

use super::Reference;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Distinguish recoverable connection state from access and deletion failures.
pub enum Availability {
    Live,
    SavedCopy,
    Reconnecting,
    AccessRequired,
    HostRemoved,
    ItemDeleted,
    UnsupportedHost,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Facts are supplied by the owning loaded models, never inferred from labels.
pub struct Facts {
    pub account_verified: bool,
    pub host_linked: bool,
    pub access_allowed: Option<bool>,
    pub supported: Option<bool>,
    pub item_exists: Option<bool>,
    pub connected: bool,
    pub saved_copy: bool,
    pub reconnecting: bool,
}

/// Revocation and removal outrank a retained saved copy and a live connection.
pub fn availability(facts: Facts) -> Availability {
    if !facts.account_verified {
        Availability::AccessRequired
    } else if !facts.host_linked {
        Availability::HostRemoved
    } else if facts.access_allowed == Some(false) {
        Availability::AccessRequired
    } else if facts.item_exists == Some(false) {
        Availability::ItemDeleted
    } else if facts.supported == Some(false) {
        Availability::UnsupportedHost
    } else if facts.connected {
        Availability::Live
    } else if facts.saved_copy {
        Availability::SavedCopy
    } else if facts.reconnecting {
        Availability::Reconnecting
    } else {
        Availability::Unavailable
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// A local folder intentionally has no peer, which is a valid route.
pub struct FolderRoute {
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
    pub peer: Option<String>,
}

/// Split only the source route prefix. Colons inside a raw workspace id survive.
pub fn route(folder_id: &str, explicit_peer: Option<&str>) -> FolderRoute {
    let parts = components(folder_id);
    let remote = folder_id.starts_with("remote:") && parts.len() == 3;
    FolderRoute {
        workspace_id: if remote { parts[2] } else { folder_id }.into(),
        peer: explicit_peer
            .filter(|p| !p.is_empty())
            .or_else(|| remote.then_some(parts.get(1).copied()).flatten())
            .map(str::to_owned),
    }
}

pub(crate) fn components(folder_id: &str) -> Vec<&str> {
    // Swift split omits empty subsequences while counting at most two splits.
    let mut rest = folder_id;
    let mut parts = Vec::new();
    while parts.len() < 2 {
        rest = rest.trim_start_matches(':');
        match rest.split_once(':') {
            Some((part, tail)) => {
                parts.push(part);
                rest = tail;
            }
            None => break,
        }
    }
    if !rest.is_empty() {
        parts.push(rest);
    }
    parts
}

/// Resolve against the current directory, never a remembered display label.
pub fn folder_id<'a>(
    reference: &Reference,
    ids: impl IntoIterator<Item = &'a str>,
    local_host_identity: Option<&str>,
) -> Option<&'a str> {
    ids.into_iter().find(|id| {
        let resolved = route(id, None);
        super::text::equal(&resolved.workspace_id, &reference.workspace_id)
            && match resolved.peer {
                Some(peer) => super::text::equal(&peer, &reference.host_identity),
                None => local_host_identity
                    .filter(|s| !s.is_empty())
                    .is_some_and(|local| super::text::equal(local, &reference.host_identity)),
            }
    })
}

impl Availability {
    /// Use the same unavailable copy as every desktop work entry point.
    pub fn message(self) -> Option<String> {
        let key = match self {
            Self::Live | Self::SavedCopy => return None,
            Self::AccessRequired => {
                "apple.rootview.verify_this_account_and_its_project_access.e7a9f207"
            }
            Self::HostRemoved => "apple.rootview.this_machine_is_no_longer_linked.b502d162",
            Self::ItemDeleted => "apple.rootview.this_work_is_no_longer_available.81259506",
            Self::UnsupportedHost => "apple.rootview.update_the_host_to_open_this_work.596b980e",
            Self::Reconnecting => "apple.rootview.reconnecting_to_the_machine.ff19692f",
            Self::Unavailable => {
                "apple.rootview.connect_the_machine_and_open_its_folder_in.04907021"
            }
        };
        Some(crate::localization::text(key, &[]))
    }
}
