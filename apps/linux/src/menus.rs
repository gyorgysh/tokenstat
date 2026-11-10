// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! App-owned commands from TokenstatApp.swift plus the desktop's standard menus.
//! Renderers share this tree; a menu action must go through the same dispatcher
//! as its keyboard binding. Keeping an unported command visible is not completion.

use crate::commands::{ChatDetail, Command, EntryKind, MenuEntry};
use crate::localization;
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub struct MenuGroup {
    pub title: String,
    pub entries: Vec<MenuEntry>,
}

pub fn application_menus(detail: ChatDetail) -> Vec<MenuGroup> {
    use Command::*;
    let action = MenuEntry::action;
    let named = MenuEntry::named;
    let sep = MenuEntry::separator;
    let mut detail_picker = sep();
    detail_picker.kind = EntryKind::Action;
    detail_picker.enabled = true;
    detail_picker.title = localization::text("apple.chatdetail.title", &[]);
    detail_picker.children = [
        (ChatDetail::Minimal, "apple.chatdetail.minimal"),
        (ChatDetail::Compact, "apple.chatdetail.compact"),
        (ChatDetail::Standard, "apple.chatdetail.standard"),
        (ChatDetail::Detailed, "apple.chatdetail.detailed"),
    ]
    .map(|(level, key)| {
        let mut entry = action(key, SetChatDetail(level));
        entry.selected = level == detail;
        entry
    })
    .into();
    vec![
        MenuGroup {
            title: "tokenstat".into(),
            entries: vec![
                action("apple.tokenstatapp.about_tokenstat.2777c642", About),
                sep(),
                named("Quit tokenstat", Quit).shortcut("q"),
            ],
        },
        MenuGroup {
            title: "File".into(),
            entries: vec![
                named("New Window", NewWindow).shortcut("n"),
                action("apple.tokenstatapp.add_project.94d63fa2", AddRepository)
                    .shortcut("shift-o"),
                sep(),
                named("Close", CloseWindow).shortcut("w"),
                named("Close All", CloseAllWindows).shortcut("alt-w"),
            ],
        },
        MenuGroup {
            title: "Edit".into(),
            entries: vec![
                named("Undo", Undo).shortcut("z"),
                named("Redo", Redo).shortcut("shift-z"),
                sep(),
                named("Cut", Cut).shortcut("x"),
                named("Copy", Copy).shortcut("c"),
                named("Paste", Paste).shortcut("v"),
                named("Select All", SelectAll).shortcut("a"),
                sep(),
                action("apple.tokenstatapp.search_work.7b7bfbb6", SearchWork).shortcut("k"),
            ],
        },
        MenuGroup {
            title: "View".into(),
            entries: vec![
                action("apple.tokenstatapp.toggle_sidebar.1d4c17db", ToggleSidebar).shortcut("b"),
                action(
                    "apple.tokenstatapp.toggle_inspector.1d522187",
                    ToggleInspector,
                )
                .shortcut("alt-b"),
                action(
                    "apple.tokenstatapp.previous_conversation.2afe4350",
                    PreviousConversation,
                )
                .shortcut("alt-up"),
                action(
                    "apple.tokenstatapp.next_conversation.379370fa",
                    NextConversation,
                )
                .shortcut("alt-down"),
                sep(),
                detail_picker,
                action("apple.chatdetail.toggle_steps", ToggleSteps).shortcut("alt-e"),
            ],
        },
        MenuGroup {
            title: "Window".into(),
            entries: vec![
                named("Minimize", Minimize).shortcut("m"),
                named("Zoom", Zoom),
            ],
        },
    ]
}

/// A popup owns its snapshot until closing. Reopening rebuilds dynamic items.
/// `path` holds the selection in each open submenu, never a disabled row.
#[derive(Debug)]
pub struct PopupMenu {
    pub entries: Vec<MenuEntry>,
    pub path: Vec<Option<usize>>,
    prefix: String,
    last_typed: Option<Instant>,
}

impl PopupMenu {
    pub fn new(entries: Vec<MenuEntry>, keyboard: bool) -> Self {
        let selected = keyboard
            .then(|| entries.iter().position(MenuEntry::is_selectable))
            .flatten();
        Self {
            entries,
            path: vec![selected],
            prefix: String::new(),
            last_typed: None,
        }
    }

    pub fn level(&self, depth: usize) -> &[MenuEntry] {
        let mut entries = self.entries.as_slice();
        for index in self.path.iter().take(depth) {
            let Some(entry) = index.and_then(|i| entries.get(i)) else {
                return &[];
            };
            entries = &entry.children;
        }
        entries
    }

    pub fn hover(&mut self, depth: usize, index: usize) {
        if self
            .level(depth)
            .get(index)
            .is_some_and(MenuEntry::is_selectable)
        {
            self.path.truncate(depth + 1);
            if let Some(selected) = self.path.get_mut(depth) {
                *selected = Some(index);
            }
            self.prefix.clear();
        }
    }

    pub fn step(&mut self, forward: bool) {
        let depth = self.path.len() - 1;
        let entries = self.level(depth);
        if entries.is_empty() {
            return;
        }
        let current = self.path[depth];
        let start = current.unwrap_or(if forward { entries.len() - 1 } else { 0 });
        let selected = (1..=entries.len())
            .map(|offset| {
                if forward {
                    (start + offset) % entries.len()
                } else {
                    (start + entries.len() - offset) % entries.len()
                }
            })
            .find(|&index| entries[index].is_selectable());
        self.path[depth] = selected;
        self.prefix.clear();
    }

    /// Returns an action only for an enabled leaf. Enter/right opens a submenu.
    pub fn activate(&mut self) -> Option<Command> {
        let depth = self.path.len() - 1;
        let entry = self.path[depth].and_then(|i| self.level(depth).get(i))?;
        if !entry.is_selectable() {
            return None;
        }
        if entry.children.is_empty() {
            return entry.command;
        }
        let selected = entry.children.iter().position(MenuEntry::is_selectable);
        self.path.push(selected);
        self.prefix.clear();
        None
    }

    /// A pointer press must not execute the previously selected row when the
    /// pressed row is disabled. This also rejects separators and stale indices.
    pub fn click(&mut self, depth: usize, index: usize) -> Option<Command> {
        if !self
            .level(depth)
            .get(index)
            .is_some_and(MenuEntry::is_selectable)
        {
            return None;
        }
        self.hover(depth, index);
        self.activate()
    }

    pub fn close_submenu(&mut self) -> bool {
        if self.path.len() <= 1 {
            return false;
        }
        self.path.pop();
        self.prefix.clear();
        true
    }

    /// Right arrow opens children; it must never invoke a leaf command.
    pub fn open_submenu(&mut self) -> bool {
        let depth = self.path.len() - 1;
        let Some(entry) = self.path[depth].and_then(|i| self.level(depth).get(i)) else {
            return false;
        };
        if !entry.is_selectable() || entry.children.is_empty() {
            return false;
        }
        let selected = entry.children.iter().position(MenuEntry::is_selectable);
        self.path.push(selected);
        self.prefix.clear();
        true
    }

    /// Repeated initials cycle, while a short sequence searches the whole label.
    pub fn type_character(&mut self, text: &str, now: Instant) {
        if text.chars().any(char::is_control) || text.is_empty() {
            return;
        }
        if self
            .last_typed
            .is_none_or(|last| now.saturating_duration_since(last) > Duration::from_millis(700))
        {
            self.prefix.clear();
        }
        self.last_typed = Some(now);
        let input = text.to_lowercase();
        if self.prefix != input {
            self.prefix.push_str(&input);
        }
        let depth = self.path.len() - 1;
        let entries = self.level(depth);
        let start = self.path[depth].map_or(0, |i| (i + 1) % entries.len());
        let selected = (0..entries.len())
            .map(|offset| (start + offset) % entries.len())
            .find(|&i| {
                entries[i].is_selectable()
                    && entries[i].title.to_lowercase().starts_with(&self.prefix)
            });
        if selected.is_some() {
            self.path[depth] = selected;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::{AccountMenuState, account_menu};

    #[test]
    fn app_owned_bindings_and_copy_match_the_current_swift_command_groups() {
        let actual: Vec<_> = application_menus(ChatDetail::default())
            .into_iter()
            .flat_map(|g| g.entries)
            .filter(|e| {
                matches!(
                    e.command,
                    Some(
                        Command::AddRepository
                            | Command::SearchWork
                            | Command::ToggleSidebar
                            | Command::ToggleInspector
                            | Command::PreviousConversation
                            | Command::NextConversation
                            | Command::ToggleSteps
                    )
                )
            })
            .map(|e| (e.title, e.shortcut.unwrap()))
            .collect();
        let expected: Vec<_> = crate::design::application_contract::BINDINGS
            .iter()
            .map(|(key, shortcut)| (localization::text(key, &[]), *shortcut))
            .collect();
        assert_eq!(actual, expected);
        assert_eq!(
            format!("{:?}", ChatDetail::default()).to_lowercase(),
            crate::design::DEFAULT_CHAT_DETAIL
        );
        let actual: Vec<_> = application_menus(ChatDetail::default())[3].entries[5]
            .children
            .iter()
            .map(|e| match e.command {
                Some(Command::SetChatDetail(level)) => {
                    (format!("{level:?}").to_lowercase(), e.title.clone())
                }
                _ => panic!("detail menu contains a non-detail action"),
            })
            .collect();
        let expected: Vec<_> = crate::design::CHAT_DETAIL_LEVELS
            .iter()
            .map(|(id, key)| (id.to_string(), localization::text(key, &[])))
            .collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn keyboard_wraps_and_never_executes_disabled_or_separator_rows() {
        let mut menu = PopupMenu::new(
            account_menu(AccountMenuState {
                signed_in: true,
                syncing: true,
                checking_updates: true,
                ..Default::default()
            }),
            true,
        );
        assert_eq!(menu.activate(), Some(Command::OpenTeams));
        assert!(!menu.open_submenu());
        assert_eq!(menu.click(0, 2), None);
        assert_eq!(menu.click(0, 1), None);
        assert_eq!(menu.click(0, 200), None);
        menu.step(true);
        assert_eq!(menu.activate(), Some(Command::SignOut));
        menu.step(false);
        assert_eq!(menu.activate(), Some(Command::OpenTeams));
        menu.step(false);
        assert_eq!(menu.activate(), Some(Command::OpenAccount));
    }

    #[test]
    fn submenu_retains_parent_and_checks_the_current_detail_level() {
        let groups = application_menus(ChatDetail::Compact);
        let mut menu = PopupMenu::new(groups[3].entries.clone(), false);
        menu.hover(0, 5);
        assert_eq!(menu.activate(), None);
        assert_eq!(menu.path.len(), 2);
        assert!(menu.level(1)[1].selected);
        assert_eq!(
            menu.activate(),
            Some(Command::SetChatDetail(ChatDetail::Minimal))
        );
        menu.step(false);
        assert_eq!(
            menu.activate(),
            Some(Command::SetChatDetail(ChatDetail::Detailed))
        );
        assert!(menu.close_submenu());
        assert_eq!(menu.path, vec![Some(5)]);
        assert!(!menu.close_submenu());
    }

    #[test]
    fn typeahead_cycles_initials_and_resets_after_a_pause() {
        let now = Instant::now();
        let mut menu = PopupMenu::new(
            vec![
                MenuEntry::named("Copy", Command::Copy),
                MenuEntry::separator(),
                MenuEntry::named("Close", Command::CloseWindow),
                MenuEntry::named("Paste", Command::Paste),
            ],
            true,
        );
        menu.type_character("c", now);
        assert_eq!(menu.activate(), Some(Command::CloseWindow));
        menu.type_character("c", now);
        assert_eq!(menu.activate(), Some(Command::Copy));
        menu.type_character("p", now + Duration::from_secs(1));
        assert_eq!(menu.activate(), Some(Command::Paste));
    }
}
