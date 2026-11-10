// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! ChatSidebarConversationRow.menu and its captured opening-time pin decision.

use crate::{
    commands::{Command, MenuEntry},
    design::ActionIcon,
    work::pins::Pins,
};
use serde::{Deserialize, Serialize};

/// Capture a command identity independently of later selection changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Rename,
    Pin,
    Unpin,
    Fork,
    Remove,
}
/// Loaded owner facts build a menu without reading disk or contacting the host.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub shared: bool,
    pub running: bool,
    pub copying: bool,
    pub reference: bool,
    pub pinned: bool,
    pub pin_count: usize,
}
fn action(key: &str, icon: ActionIcon, command: Action, enabled: bool) -> MenuEntry {
    let mut row = MenuEntry::action(key, Command::Chat(command));
    row.icon = Some(icon);
    row.enabled = enabled;
    row
}
/// Shared/running/copying state affects individual commands, not menu visibility.
pub fn items(state: &State) -> Vec<MenuEntry> {
    let mut items = vec![action(
        "apple.rootview.rename.6fa62b3d",
        ActionIcon::Edit,
        Action::Rename,
        !state.shared,
    )];
    if state.reference {
        let full = !state.pinned && state.pin_count >= Pins::CAPACITY;
        items.push(if state.pinned {
            action(
                "apple.sidebarrowactions.unpin_from_home.df00f5de",
                ActionIcon::Pinned,
                Action::Unpin,
                true,
            )
        } else {
            action(
                "apple.sidebarrowactions.pin_to_home.db029e6f",
                ActionIcon::Pin,
                Action::Pin,
                !full,
            )
        });
        if full {
            let mut explanation = MenuEntry::action(
                "apple.sidebarrowactions.home_holds_eight_pins_unpin_one_to_make_ro.7d0eb1cf",
                Command::Chat(Action::Pin),
            );
            explanation.enabled = false;
            explanation.command = None;
            items.push(explanation);
        }
    }
    let enabled = !state.shared && !state.running && !state.copying;
    items.push(action(
        if state.copying {
            "apple.rootview.forking.b24686d8"
        } else {
            "apple.rootview.fork_chat.dfbcbb35"
        },
        ActionIcon::Copy,
        Action::Fork,
        enabled,
    ));
    items.push(MenuEntry::separator());
    let mut remove = action(
        "apple.rootview.delete_chat.f618c627",
        ActionIcon::Delete,
        Action::Remove,
        enabled,
    );
    remove.destructive = true;
    items.push(remove);
    items
}
