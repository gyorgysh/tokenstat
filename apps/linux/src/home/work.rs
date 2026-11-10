// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Home reads only current directory/chat summaries and local work metadata.
//! It never loads a transcript or initiates peer IO to label a destination.

mod fixtures;
#[cfg(test)]
mod tests;

use crate::{
    devices::Machine,
    localization,
    work::{
        Kind, Reference, Scope,
        destination::{self, Availability, Facts},
    },
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Home needs only the already-loaded folder's identity and display metadata.
pub struct Folder {
    pub id: String,
    pub name: String,
    pub machine_label: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
/// A sidebar summary and draft-aware emptiness fact, never transcript text.
pub struct Conversation {
    pub id: String,
    pub title: String,
    /// Supplied by ChatModel.isUnused, including its scoped draft check.
    pub unused: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Presentation input from the pin store. This does not validate or persist pins.
pub struct Pin {
    pub reference: Reference,
    pub label: String,
    pub folder_name: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Current loaded-model facts. Saved entries must already have passed the
/// owning cache/access checks before being supplied here.
pub struct Catalog {
    pub scope: Option<Scope>,
    pub local_host_identity: Option<String>,
    pub folders: Vec<Folder>,
    pub machines: Vec<Machine>,
    pub access: BTreeMap<String, bool>,
    pub saved: Vec<Reference>,
    pub conversations: BTreeMap<String, Vec<Conversation>>,
    pub terminals: BTreeMap<String, Vec<String>>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// A recent reference can remain visible while temporarily unavailable.
pub struct RecentRow {
    pub reference: Reference,
    pub title: String,
    pub subtitle: String,
    pub unavailable: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
/// Unpin remains available independently of the open target's availability.
pub struct PinRow {
    pub pin: Pin,
    pub subtitle: String,
    pub unavailable: Option<String>,
}

/// None in the desktop adapter means its metadata/identity/directory is not loaded.
/// A synthetic empty store is different from an unimplemented production read.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HomeWork {
    pub catalog: Catalog,
    pub recent: Vec<Reference>,
    pub pins: Vec<Pin>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
/// Resolve again at activation time before the shell attempts navigation.
pub enum OpenTarget {
    SavedCopy { reference: Reference },
    Workspace { folder: String },
    Conversation { folder: String, item: String },
    Terminal { folder: String, item: String },
}

impl Catalog {
    /// Resolve only against the directory currently owned by the shell.
    pub fn folder_id(&self, reference: &Reference) -> Option<&str> {
        destination::folder_id(
            reference,
            self.folders.iter().map(|f| f.id.as_str()),
            self.local_host_identity.as_deref(),
        )
    }
    fn folder(&self, reference: &Reference) -> Option<&Folder> {
        self.folder_id(reference)
            .and_then(|id| self.folders.iter().find(|f| f.id == id))
    }
    fn machine_name(&self, reference: &Reference) -> String {
        if Some(reference.host_identity.as_str()) == self.local_host_identity.as_deref() {
            l("apple.rootview.this_mac.79a4aefc")
        } else {
            self.folder(reference)
                .and_then(|f| f.machine_label.clone())
                .unwrap_or_else(|| l("apple.rootview.remote_machine.d9dd1af3"))
        }
    }
    /// Use the same loaded account, access and saved-copy facts as RootView.
    pub fn availability(&self, reference: &Reference) -> Availability {
        let local = Some(reference.host_identity.as_str()) == self.local_host_identity.as_deref();
        let machine = self
            .machines
            .iter()
            .find(|m| m.public_identity.as_deref() == Some(&reference.host_identity));
        destination::availability(Facts {
            account_verified: self.scope.as_ref() == Some(&reference.scope),
            host_linked: local || machine.is_some(),
            access_allowed: if local {
                Some(true)
            } else {
                self.access.get(&reference.host_identity).copied()
            },
            connected: self.folder_id(reference).is_some()
                && (local || machine.is_some_and(|m| m.online == Some(true))),
            saved_copy: matches!(
                reference.kind,
                Kind::Conversation | Kind::Commit | Kind::SavedDiff
            ) && !reference.host_identity.is_empty()
                && !reference.workspace_id.is_empty()
                && reference
                    .item_id
                    .as_ref()
                    .is_some_and(|item| !item.is_empty())
                && self.saved.iter().any(|r| r.same_pin(reference)),
            ..Facts::default()
        })
    }
    /// Folder pins show the machine, while item pins keep their folder label.
    pub fn pin_subtitle(&self, pin: &Pin) -> String {
        let machine = self.machine_name(&pin.reference);
        if pin.reference.kind == Kind::Workspace {
            machine
        } else {
            format!("{} · {machine}", pin.folder_name)
        }
    }
    /// Host availability alone cannot make an ended terminal session openable.
    pub fn pin_unavailable(&self, pin: &Pin) -> Option<String> {
        self.availability(&pin.reference).message().or_else(|| {
            (pin.reference.kind == Kind::Terminal && !self.terminal_exists(&pin.reference))
                .then(|| l("apple.rootview.this_terminal_session_has_ended.022b26e2"))
        })
    }
    fn terminal_exists(&self, reference: &Reference) -> bool {
        self.folder_id(reference)
            .and_then(|folder| self.terminals.get(folder))
            .is_some_and(|items| {
                reference
                    .item_id
                    .as_ref()
                    .is_some_and(|item| items.contains(item))
            })
    }
    /// A previously drawn row cannot bypass a newer account/access decision.
    pub fn open_recent(&self, reference: &Reference) -> Option<OpenTarget> {
        if self.availability(reference).message().is_some() {
            return None;
        }
        if self.availability(reference) == Availability::SavedCopy {
            return Some(OpenTarget::SavedCopy {
                reference: reference.clone(),
            });
        }
        if self.scope.as_ref() != Some(&reference.scope) {
            return None;
        }
        Some(OpenTarget::Conversation {
            folder: self.folder_id(reference)?.into(),
            item: reference.item_id.clone()?,
        })
    }
    /// Preserve the source's saved-reader priority and unsupported-kind no-op.
    pub fn open_pin(&self, pin: &Pin) -> Option<OpenTarget> {
        let reference = &pin.reference;
        if self.pin_unavailable(pin).is_some() {
            return None;
        }
        if self.availability(reference) == Availability::SavedCopy {
            return Some(OpenTarget::SavedCopy {
                reference: reference.clone(),
            });
        }
        let folder = self.folder_id(reference)?.to_owned();
        match reference.kind {
            Kind::Workspace => Some(OpenTarget::Workspace { folder }),
            Kind::Conversation => Some(OpenTarget::Conversation {
                folder,
                item: reference.item_id.clone().filter(|s| !s.is_empty())?,
            }),
            Kind::Terminal => Some(OpenTarget::Terminal {
                folder,
                item: reference.item_id.clone()?,
            }),
            Kind::Commit | Kind::SavedDiff => None,
        }
    }
}

impl HomeWork {
    /// Apply the store's four-entry limit before removing unused/removed work.
    pub fn recent_rows(&self) -> Vec<RecentRow> {
        let Some(scope) = &self.catalog.scope else {
            return vec![];
        };
        self.recent
            .iter()
            .filter(|r| r.scope == *scope)
            .take(4)
            .filter_map(|reference| {
                if matches!(
                    self.catalog.availability(reference),
                    Availability::HostRemoved | Availability::ItemDeleted
                ) {
                    return None;
                }
                let folder = self.catalog.folder(reference);
                let conversation = folder
                    .and_then(|f| self.catalog.conversations.get(&f.id))
                    .and_then(|chats| {
                        chats
                            .iter()
                            .find(|c| Some(&c.id) == reference.item_id.as_ref())
                    });
                if conversation.is_some_and(|c| c.unused) {
                    return None;
                }
                let previous = folder
                    .map(|f| f.name.clone())
                    .unwrap_or_else(|| l("apple.rootview.a_previous_folder.b0435053"));
                Some(RecentRow {
                    reference: reference.clone(),
                    title: conversation.map(|c| c.title.clone()).unwrap_or_else(|| {
                        localization::text(
                            "apple.rootview.conversation_in_0.ad84a8f5",
                            &[&previous],
                        )
                    }),
                    subtitle: format!(
                        "{} · {}",
                        folder
                            .map(|f| f.name.clone())
                            .unwrap_or_else(|| l("apple.rootview.folder.74ccd433")),
                        self.catalog.machine_name(reference)
                    ),
                    unavailable: self.catalog.availability(reference).message(),
                })
            })
            .collect()
    }
    /// Read the active scope's already-ordered, validated pin-store input.
    pub fn pin_rows(&self) -> Vec<PinRow> {
        self.pins
            .iter()
            .filter(|pin| Some(&pin.reference.scope) == self.catalog.scope.as_ref())
            .map(|pin| PinRow {
                pin: pin.clone(),
                subtitle: self.catalog.pin_subtitle(pin),
                unavailable: self.catalog.pin_unavailable(pin),
            })
            .collect()
    }
    /// Fixture-only mutation. Reuse the real validator/capacity/order rules
    /// against private memory, without enabling the desktop IO service.
    pub fn pin_ephemeral(
        &mut self,
        reference: Reference,
        label: &str,
        folder_name: &str,
    ) -> anyhow::Result<bool> {
        use crate::work::{continuity::Date, pins::Pins};
        let store = Pins::default();
        for (index, pin) in self.pins.iter().rev().enumerate() {
            store.pin(
                &pin.reference,
                &pin.label,
                &pin.folder_name,
                Date(index as f64),
            )?;
        }
        let accepted = store.pin(
            &reference,
            label,
            folder_name,
            Date::from_unix_ms(crate::home::plans::now_ms()),
        )?;
        self.pins = store
            .pins(self.catalog.scope.as_ref())?
            .into_iter()
            .map(|pin| Pin {
                reference: pin.reference,
                label: pin.label,
                folder_name: pin.folder_name,
            })
            .collect();
        Ok(accepted)
    }
    /// Fixture removal changes shortcuts only, independently of cache retention.
    pub fn unpin(&mut self, reference: &Reference) {
        self.pins.retain(|pin| !pin.reference.same_pin(reference));
    }
}

fn l(key: &str) -> String {
    localization::text(key, &[])
}
