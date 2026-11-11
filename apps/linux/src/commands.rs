// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Menu descriptions are rebuilt at opening time, matching NativeMenuTrigger.

use crate::{design::ActionIcon, localization};

/// One action identity can be used by menus, shortcuts and content controls.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    SignIn,
    SignOut,
    OpenAccount,
    OpenTeams,
    SyncNow,
    CheckForUpdates,
    About,
    NewWindow,
    AddRepository,
    SetProjectsSort(crate::sidebar::ProjectsSort),
    MoveSidebarSection(bool),
    CloseWindow,
    CloseAllWindows,
    SearchWork,
    ToggleSidebar,
    ToggleInspector,
    PreviousConversation,
    NextConversation,
    SetChatDetail(ChatDetail),
    ToggleSteps,
    CustomizeHome,
    OpenSelectedDayInInsights,
    OpenApplicationMenu(usize),
    Project(crate::project_menu::ProjectAction),
    Chat(crate::chat::menu::Action),
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    SelectAll,
    Minimize,
    Zoom,
    Quit,
}

/// ChatTranscriptFold.swift, including the fourth level omitted by its old comment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ChatDetail {
    Minimal,
    #[default]
    Compact,
    Standard,
    Detailed,
}
impl ChatDetail {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Minimal => "minimal",
            Self::Compact => "compact",
            Self::Standard => "standard",
            Self::Detailed => "detailed",
        }
    }
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "minimal" => Some(Self::Minimal),
            "compact" => Some(Self::Compact),
            "standard" => Some(Self::Standard),
            "detailed" => Some(Self::Detailed),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    Action,
    Separator,
    Heading,
}

/// Preserve presentation metadata rather than inferring enablement in a renderer.
#[derive(Clone, Debug)]
pub struct MenuEntry {
    pub kind: EntryKind,
    pub title: String,
    pub enabled: bool,
    pub selected: bool,
    pub icon: Option<ActionIcon>,
    pub destructive: bool,
    pub command: Option<Command>,
    pub shortcut: Option<&'static str>,
    pub children: Vec<MenuEntry>,
}

impl MenuEntry {
    pub(crate) fn action(key: &str, command: Command) -> Self {
        Self::named(localization::text(key, &[]), command)
    }
    pub(crate) fn named(title: impl Into<String>, command: Command) -> Self {
        Self {
            kind: EntryKind::Action,
            title: title.into(),
            enabled: true,
            selected: false,
            icon: None,
            destructive: false,
            command: Some(command),
            shortcut: None,
            children: Vec::new(),
        }
    }
    pub(crate) fn separator() -> Self {
        Self {
            kind: EntryKind::Separator,
            title: String::new(),
            enabled: false,
            selected: false,
            icon: None,
            destructive: false,
            command: None,
            shortcut: None,
            children: Vec::new(),
        }
    }

    pub fn is_selectable(&self) -> bool {
        self.enabled && self.kind == EntryKind::Action
    }

    pub(crate) fn shortcut(mut self, shortcut: &'static str) -> Self {
        self.shortcut = Some(shortcut);
        self
    }
}

/// Only values actually read by RootView.accountMenuItems belong in this snapshot.
#[derive(Clone, Copy, Debug, Default)]
pub struct AccountMenuState {
    pub signed_in: bool,
    pub syncing: bool,
    pub sync_cooldown: bool,
    pub checking_updates: bool,
}

/// The signed-out and signed-in menus retain their exact item and separator order.
pub fn account_menu(state: AccountMenuState) -> Vec<MenuEntry> {
    let mut updates = MenuEntry::action(
        if state.checking_updates {
            "apple.rootview.checking_for_updates.497a1998"
        } else {
            "apple.rootview.check_for_updates.f26f3275"
        },
        Command::CheckForUpdates,
    );
    updates.enabled = !state.checking_updates;
    if !state.signed_in {
        return vec![
            MenuEntry::action(
                "apple.rootview.sign_in_to_tokenstat_ai.6276dc4d",
                Command::SignIn,
            ),
            MenuEntry::separator(),
            MenuEntry::action("common.account", Command::OpenAccount),
            MenuEntry::separator(),
            updates,
        ];
    }
    let mut team = MenuEntry::action("common.teams.title", Command::OpenTeams);
    team.icon = Some(ActionIcon::Team);
    let mut sync = MenuEntry::action("common.sync_now", Command::SyncNow);
    sync.enabled = !state.syncing && !state.sync_cooldown;
    vec![
        team,
        MenuEntry::separator(),
        sync,
        MenuEntry::separator(),
        updates,
        MenuEntry::separator(),
        MenuEntry::action("common.sign_out", Command::SignOut),
        MenuEntry::action(
            "apple.rootview.account_settings.a587aa1f",
            Command::OpenAccount,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_sync_and_update_items_cannot_be_confused_with_missing_commands() {
        let menu = account_menu(AccountMenuState {
            signed_in: true,
            sync_cooldown: true,
            checking_updates: true,
            ..Default::default()
        });
        assert_eq!(
            menu.iter()
                .find(|e| e.command == Some(Command::SyncNow))
                .map(|e| e.enabled),
            Some(false)
        );
        assert_eq!(
            menu.iter()
                .find(|e| e.command == Some(Command::CheckForUpdates))
                .map(|e| e.enabled),
            Some(false)
        );
        assert!(!menu.iter().any(|e| e.command == Some(Command::SignIn)));
    }
}
