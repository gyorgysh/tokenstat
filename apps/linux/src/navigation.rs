// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Desktop routes follow Route.swift and RailPlace, including remembered destinations.

pub use crate::design::{GlobalSection, RailPlace, WorkspaceSection};
use serde::{Deserialize, Serialize};
use std::hash::{Hash, Hasher};
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Debug, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SshSection {
    Hosts { folder: Option<String> },
    Keys,
    Snippets,
    KnownHosts,
}

impl SshSection {
    pub fn label_key(&self) -> &'static str {
        match self {
            Self::Hosts { .. } => "apple.route.hosts.bba9af13",
            Self::Keys => "apple.route.keys.f0d66a79",
            Self::Snippets => "apple.route.snippets.ff717209",
            Self::KnownHosts => "apple.route.trusted_servers.b101ed86",
        }
    }
}

#[derive(Clone, Debug, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Route {
    Global {
        section: GlobalSection,
    },
    Workspace {
        id: String,
        section: WorkspaceSection,
    },
    WorkspacesOverview,
    Ssh {
        section: SshSection,
    },
    SshTerminals {
        host: String,
    },
}
// Synthesized Swift route equality/hash use canonical String identity. Route
// fences must preserve that rule, including a user leaving and returning.
impl PartialEq for SshSection {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Hosts { folder: a }, Self::Hosts { folder: b }) => match (a, b) {
                (Some(a), Some(b)) => crate::work::text::equal(a, b),
                (None, None) => true,
                _ => false,
            },
            (Self::Keys, Self::Keys)
            | (Self::Snippets, Self::Snippets)
            | (Self::KnownHosts, Self::KnownHosts) => true,
            _ => false,
        }
    }
}
impl Hash for SshSection {
    fn hash<H: Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        if let Self::Hosts { folder } = self {
            folder
                .as_ref()
                .map(|s| s.nfc().collect::<String>())
                .hash(state);
        }
    }
}
impl PartialEq for Route {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Global { section: a }, Self::Global { section: b }) => a == b,
            (Self::Workspace { id: a, section: x }, Self::Workspace { id: b, section: y }) => {
                x == y && crate::work::text::equal(a, b)
            }
            (Self::WorkspacesOverview, Self::WorkspacesOverview) => true,
            (Self::Ssh { section: a }, Self::Ssh { section: b }) => a == b,
            (Self::SshTerminals { host: a }, Self::SshTerminals { host: b }) => {
                crate::work::text::equal(a, b)
            }
            _ => false,
        }
    }
}
impl Hash for Route {
    fn hash<H: Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            Self::Global { section } => section.hash(state),
            Self::Workspace { id, section } => {
                id.nfc().collect::<String>().hash(state);
                section.hash(state);
            }
            Self::WorkspacesOverview => {}
            Self::Ssh { section } => section.hash(state),
            Self::SshTerminals { host } => host.nfc().collect::<String>().hash(state),
        }
    }
}

impl Default for Route {
    fn default() -> Self {
        Self::Global {
            section: GlobalSection::Home,
        }
    }
}

impl Route {
    /// Account, Teams, the new-chat landing and notes have no desktop inspector.
    pub fn has_inspector(&self) -> bool {
        !matches!(
            self,
            Self::Global {
                section: GlobalSection::Team
                    | GlobalSection::Account
                    | GlobalSection::NewChat
                    | GlobalSection::Notes
            } | Self::Workspace {
                section: WorkspaceSection::Notes,
                ..
            }
        )
    }

    /// Workspace routes select Repositories, while Workflows belongs to Automations.
    pub fn rail_place(&self) -> Option<RailPlace> {
        Some(match self {
            Self::Global { section } => match section {
                GlobalSection::Home => RailPlace::Home,
                GlobalSection::Insights => RailPlace::Insights,
                GlobalSection::Machines => RailPlace::Devices,
                GlobalSection::Todo => RailPlace::Tasks,
                GlobalSection::Notes => RailPlace::Notes,
                GlobalSection::Workflows | GlobalSection::Automations => RailPlace::Automations,
                GlobalSection::Team => RailPlace::Team,
                GlobalSection::Account | GlobalSection::NewChat => return None,
            },
            Self::Workspace { .. } | Self::WorkspacesOverview => RailPlace::Projects,
            Self::Ssh { .. } | Self::SshTerminals { .. } => RailPlace::Ssh,
        })
    }
}

/// Switching a rail place is navigation, never permission to destroy retained panes.
#[derive(Clone, Debug)]
pub struct Navigation {
    pub route: Route,
    pub last_ssh: SshSection,
    last_workspace: std::collections::BTreeMap<String, WorkspaceSection>,
}

impl Default for Navigation {
    fn default() -> Self {
        Self {
            route: Route::default(),
            last_ssh: SshSection::Hosts { folder: None },
            last_workspace: Default::default(),
        }
    }
}

impl Navigation {
    /// Removing a registration also retires its remembered workspace section.
    pub fn forget_workspace(&mut self, id: &str) {
        self.last_workspace.remove(id);
    }
    pub fn navigate(&mut self, route: Route) {
        if let Route::Workspace { id, section } = &route {
            self.last_workspace.insert(id.clone(), *section);
        }
        if let Route::Ssh { section } = &route {
            self.last_ssh = section.clone();
        }
        self.route = route;
    }

    /// A folder pin reopens its previous section, defaulting to Chat.
    pub fn last_workspace_section(&self, id: &str) -> WorkspaceSection {
        self.last_workspace
            .get(id)
            .copied()
            .unwrap_or(WorkspaceSection::Chat)
    }

    /// Reopening Automations keeps Workflows selected when it is already active.
    pub fn open_rail(&mut self, place: RailPlace) {
        let section = match place {
            RailPlace::Home => GlobalSection::Home,
            RailPlace::Tasks => GlobalSection::Todo,
            RailPlace::Notes => GlobalSection::Notes,
            RailPlace::Automations
                if matches!(
                    self.route,
                    Route::Global {
                        section: GlobalSection::Workflows
                    }
                ) =>
            {
                return;
            }
            RailPlace::Automations => GlobalSection::Automations,
            RailPlace::Insights => GlobalSection::Insights,
            RailPlace::Devices => GlobalSection::Machines,
            RailPlace::Team => GlobalSection::Team,
            RailPlace::Projects => {
                self.navigate(Route::WorkspacesOverview);
                return;
            }
            RailPlace::Ssh => {
                self.navigate(Route::Ssh {
                    section: self.last_ssh.clone(),
                });
                return;
            }
        };
        self.navigate(Route::Global { section });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rail_navigation_retains_the_swift_destinations() {
        let mut navigation = Navigation::default();
        navigation.navigate(Route::Global {
            section: GlobalSection::Workflows,
        });
        navigation.open_rail(RailPlace::Automations);
        assert_eq!(
            navigation.route,
            Route::Global {
                section: GlobalSection::Workflows
            }
        );
        navigation.navigate(Route::Ssh {
            section: SshSection::Keys,
        });
        navigation.open_rail(RailPlace::Home);
        navigation.open_rail(RailPlace::Ssh);
        assert_eq!(
            navigation.route,
            Route::Ssh {
                section: SshSection::Keys
            }
        );
    }

    #[test]
    fn folder_shortcuts_reopen_each_folders_last_section() {
        let mut navigation = Navigation::default();
        assert_eq!(
            navigation.last_workspace_section("alpha"),
            WorkspaceSection::Chat
        );
        navigation.navigate(Route::Workspace {
            id: "alpha".into(),
            section: WorkspaceSection::Notes,
        });
        navigation.navigate(Route::Workspace {
            id: "beta".into(),
            section: WorkspaceSection::History,
        });
        navigation.open_rail(RailPlace::Home);
        assert_eq!(
            navigation.last_workspace_section("alpha"),
            WorkspaceSection::Notes
        );
        assert_eq!(
            navigation.last_workspace_section("beta"),
            WorkspaceSection::History
        );
    }

    #[test]
    fn every_generated_route_has_copy_in_the_existing_catalog() {
        let catalog = crate::localization::LanguageCatalog::english();
        for key in RailPlace::ALL
            .iter()
            .map(|r| r.label_key())
            .chain(GlobalSection::ALL.iter().map(|r| r.label_key()))
            .chain(WorkspaceSection::ALL.iter().map(|r| r.label_key()))
        {
            assert!(catalog.contains(key), "missing {key}");
        }
    }
}
