// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! RootView.projectActions, WorkspaceRow.menu and SidebarPinAction.items.
//! Facts belong to the loaded owners; constructing a menu performs no IO.

use crate::{
    commands::{Command, MenuEntry},
    design::ActionIcon,
    localization,
    work::{Kind, Reference, Scope, destination, pins::Pins},
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
/// Keep the opening-time pin decision distinct from a later toggle decision.
pub enum ProjectAction {
    Rename,
    Pin,
    Unpin,
    SavedWork,
    OpenShared,
    NewPrivateChat,
    Share,
    StopSharing,
    Reveal,
    Disconnect,
    NewChat,
    NewTerminal,
    Worktrees,
    DeleteChats,
    Remove,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Loaded directory, sharing and pin-store facts used when the menu opens.
pub struct State {
    pub reference: bool,
    pub pinned: bool,
    pub pin_count: usize,
    pub machine_id: Option<String>,
    pub machine_label: Option<String>,
    pub stale: bool,
    pub shared: bool,
    pub stop_sharing: bool,
    pub git_is_repo: Option<bool>,
}

fn action(key: &str, icon: ActionIcon, action: ProjectAction) -> MenuEntry {
    let mut item = MenuEntry::action(key, Command::Project(action));
    item.icon = Some(icon);
    item
}
fn destructive(key: &str, icon: ActionIcon, command: ProjectAction) -> MenuEntry {
    let mut item = action(key, icon, command);
    item.destructive = true;
    item
}

/// Preserve the source separators, including those adjacent to absent groups.
pub fn items(state: &State) -> Vec<MenuEntry> {
    use ProjectAction::*;
    let mut items = Vec::new();
    if !state.stale {
        items.push(action(
            "apple.rootview.rename.6fa62b3d",
            ActionIcon::Edit,
            Rename,
        ));
    }
    if state.reference {
        let full = !state.pinned && state.pin_count >= Pins::CAPACITY;
        let mut pin = if state.pinned {
            action(
                "apple.sidebarrowactions.unpin_from_home.df00f5de",
                ActionIcon::Pinned,
                Unpin,
            )
        } else {
            action(
                "apple.sidebarrowactions.pin_to_home.db029e6f",
                ActionIcon::Pin,
                Pin,
            )
        };
        pin.enabled = !full;
        items.push(pin);
        if full {
            // This is a disabled action in the source, rather than a heading.
            let mut explanation = MenuEntry::action(
                "apple.sidebarrowactions.home_holds_eight_pins_unpin_one_to_make_ro.7d0eb1cf",
                Command::Project(Pin),
            );
            explanation.enabled = false;
            explanation.command = None;
            items.push(explanation);
        }
        items.push(action(
            "apple.rootview.saved_work_on_this_device.6942a15d",
            ActionIcon::Archive,
            SavedWork,
        ));
    }
    items.push(MenuEntry::separator());
    if state.machine_id.is_none() {
        if state.shared {
            items.push(action(
                "common.teams.open_shared_project",
                ActionIcon::Team,
                OpenShared,
            ));
            items.push(action(
                "common.teams.new_private_chat",
                ActionIcon::Create,
                NewPrivateChat,
            ));
        }
        items.push(action(
            "common.teams.share_project",
            ActionIcon::Connect,
            Share,
        ));
        if state.stop_sharing {
            items.push(destructive(
                "common.teams.stop_sharing",
                ActionIcon::Revoke,
                StopSharing,
            ));
        }
        items.push(MenuEntry::separator());
        items.push(action(
            "apple.rootview.reveal_in_finder.cc849385",
            ActionIcon::Reveal,
            Reveal,
        ));
    } else if state
        .machine_id
        .as_ref()
        .is_some_and(|peer| !peer.is_empty())
    {
        let label = state
            .machine_label
            .clone()
            .unwrap_or_else(|| localization::text("apple.rootview.this_computer.058bf37c", &[]));
        let mut item = MenuEntry::named(
            localization::text("apple.rootview.disconnect_from_0.cc8c176c", &[&label]),
            Command::Project(Disconnect),
        );
        item.icon = Some(ActionIcon::Disconnect);
        items.push(item);
    }
    // projectActions checks peer staleness; the row's separate stale flag also
    // controls Rename. A local row cannot trigger this early return.
    if state.machine_id.is_some() && state.stale {
        return items;
    }
    items.push(MenuEntry::separator());
    items.push(action(
        "apple.rootview.new_chat.db18382a",
        ActionIcon::Create,
        NewChat,
    ));
    items.push(action(
        "apple.rootview.new_terminal.9456c8eb",
        ActionIcon::Create,
        NewTerminal,
    ));
    if state.git_is_repo == Some(true) {
        items.push(action(
            "apple.rootview.worktrees.c336cb52",
            ActionIcon::Source,
            Worktrees,
        ));
    }
    items.push(destructive(
        "apple.rootview.delete_all_chats.9753e785",
        ActionIcon::Delete,
        DeleteChats,
    ));
    items.push(MenuEntry::separator());
    items.push(destructive(
        "apple.rootview.remove_from_tokenstat.195e6064",
        ActionIcon::Delete,
        Remove,
    ));
    items
}

/// Route IDs carry remote public identity; machine labels and addresses do not.
pub fn reference(
    scope: Option<&Scope>,
    local_identity: Option<&str>,
    folder_id: &str,
) -> Option<Reference> {
    let scope = scope?.clone();
    let route = destination::route(folder_id, None);
    let host_identity = route.peer.or_else(|| local_identity.map(str::to_owned))?;
    if route.workspace_id.is_empty() {
        return None;
    }
    Some(Reference {
        scope,
        host_identity,
        workspace_id: route.workspace_id,
        kind: Kind::Workspace,
        item_id: None,
        anchor: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{commands::EntryKind, menus::PopupMenu};

    #[test]
    fn capacity_explanation_cannot_activate_or_execute_previous_selection() {
        let mut menu = PopupMenu::new(
            items(&State {
                reference: true,
                pin_count: 8,
                ..State::default()
            }),
            true,
        );
        assert_eq!(menu.path, vec![Some(0)]);
        assert_eq!(menu.click(0, 1), None);
        assert_eq!(menu.click(0, 2), None);
        assert_eq!(menu.level(0)[2].kind, EntryKind::Action);
        let repin = items(&State {
            reference: true,
            pinned: true,
            pin_count: 8,
            ..State::default()
        });
        assert!(repin[1].enabled);
        assert_eq!(
            repin[1].command,
            Some(Command::Project(ProjectAction::Unpin))
        );
    }

    #[test]
    fn unavailable_scope_never_becomes_a_local_reference() {
        let scope = Scope::local("fixture");
        assert!(reference(None, Some("local"), "folder").is_none());
        assert!(reference(Some(&scope), None, "folder").is_none());
        assert!(reference(Some(&scope), Some("local"), "").is_none());
        let remote = reference(Some(&scope), None, "remote:peer:folder").unwrap();
        assert_eq!(remote.host_identity, "peer");
        assert_eq!(remote.workspace_id, "folder");
    }

    #[test]
    fn opened_menu_keeps_the_pin_operation_until_it_is_reopened() {
        let mut facts = State {
            reference: true,
            ..Default::default()
        };
        let mut opened = PopupMenu::new(items(&facts), false);
        facts.pinned = true;
        assert_eq!(
            opened.click(0, 1),
            Some(Command::Project(ProjectAction::Pin))
        );
        let mut reopened = PopupMenu::new(items(&facts), false);
        assert_eq!(
            reopened.click(0, 1),
            Some(Command::Project(ProjectAction::Unpin))
        );
    }
}
