// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! AppKit's source confirmation roles, visual order and response lifetime.
//! A destructive confirmation has no implicit Return default.

use crate::{localization, project_edit};
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Choice {
    Cancel,
    Remove,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Role {
    Cancel,
    Destructive,
}
#[derive(Clone, Debug, Serialize)]
/// Declaration order and native visual order differ for the cancel role.
pub struct Button {
    pub choice: Choice,
    pub title: String,
    pub role: Role,
}
#[derive(Clone, Debug, Serialize)]
pub struct Content {
    pub title: String,
    pub message: String,
    pub buttons: Vec<Button>,
}
impl Content {
    /// The original fork alert's only OK button has the cancel role, Escape
    /// equivalent and no implicit Return default, just like native content.
    pub fn fork_error(message: String) -> Self {
        Self {
            title: localization::text("apple.rootview.couldn_t_fork_this_chat.3aace6d2", &[]),
            message,
            buttons: vec![Button {
                choice: Choice::Cancel,
                title: localization::text("apple.rootview.ok.565339bc", &[]),
                role: Role::Cancel,
            }],
        }
    }
    pub fn remove_project(name: Option<&str>) -> Self {
        Self {
            title: localization::text("apple.rootview.remove_from_tokenstat.ab2e2b74", &[]),
            message: project_edit::removal_message(name),
            buttons: vec![
                Button {
                    choice: Choice::Cancel,
                    title: localization::text("apple.rootview.keep_it.fdce5da2", &[]),
                    role: Role::Cancel,
                },
                Button {
                    choice: Choice::Remove,
                    title: localization::text("common.remove", &[]),
                    role: Role::Destructive,
                },
            ],
        }
    }
}

#[derive(Clone, Debug)]
/// Focus is not a default action. A stale or repeated event cannot complete twice.
pub struct Interaction {
    pub focused: Option<Choice>,
    pub show_focus: bool,
    completed: bool,
    choices: Vec<Choice>,
}
impl Default for Interaction {
    fn default() -> Self {
        Self {
            focused: Some(Choice::Cancel),
            show_focus: false,
            completed: false,
            choices: vec![Choice::Cancel, Choice::Remove],
        }
    }
}
impl Interaction {
    /// Only actual source buttons participate in focus and response handling.
    pub fn for_content(content: &Content) -> Self {
        let choices = content.buttons.iter().map(|b| b.choice).collect::<Vec<_>>();
        Self {
            focused: choices.first().copied(),
            choices,
            ..Self::default()
        }
    }
    pub fn focus(&mut self, choice: Choice) {
        if !self.completed && self.choices.contains(&choice) {
            self.focused = Some(choice);
            self.show_focus = true;
        }
    }
    pub fn step(&mut self, backward: bool) {
        if self.completed {
            return;
        }
        self.show_focus = true;
        let count = self.choices.len();
        if count == 0 {
            self.focused = None;
            return;
        }
        let index = self
            .focused
            .and_then(|choice| self.choices.iter().position(|c| *c == choice));
        self.focused = Some(
            self.choices[match index {
                None => {
                    if backward {
                        count - 1
                    } else {
                        0
                    }
                }
                Some(index) => {
                    if backward {
                        (index + count - 1) % count
                    } else {
                        (index + 1) % count
                    }
                }
            }],
        );
    }
    pub fn complete(&mut self, choice: Choice) -> Option<Choice> {
        if self.completed || !self.choices.contains(&choice) {
            None
        } else {
            self.completed = true;
            Some(choice)
        }
    }
    pub fn key(&mut self, key: &str, shift: bool) -> Option<Choice> {
        if self.completed {
            return None;
        }
        match key {
            "escape" => self.complete(Choice::Cancel),
            "tab" => {
                self.step(shift);
                None
            }
            "left" | "right" => {
                self.step(key == "left");
                None
            }
            "space" => self.focused.and_then(|choice| self.complete(choice)),
            // The measured native source has no Return key equivalent and no
            // defaultButtonCell, including on its destructive Remove button.
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fork_alert_focus_and_response_never_invent_a_second_or_default_button() {
        let content = Content::fork_error("synthetic failure".into());
        assert_eq!(content.buttons.len(), 1);
        assert_eq!(content.buttons[0].role, Role::Cancel);
        let mut interaction = Interaction::for_content(&content);
        for key in ["tab", "left", "right"] {
            assert_eq!(interaction.key(key, false), None);
            assert_eq!(interaction.focused, Some(Choice::Cancel));
        }
        assert_eq!(interaction.key("enter", false), None);
        assert_eq!(interaction.complete(Choice::Remove), None);
        assert_eq!(interaction.key("space", false), Some(Choice::Cancel));
        assert_eq!(interaction.key("escape", false), None);
    }
    #[test]
    fn return_never_guesses_a_destructive_action_and_escape_can_complete_only_once() {
        let mut state = Interaction::default();
        assert_eq!(state.key("enter", false), None);
        state.focus(Choice::Remove);
        assert_eq!(state.key("enter", false), None);
        assert_eq!(state.key("escape", false), Some(Choice::Cancel));
        assert_eq!(state.complete(Choice::Remove), None);
        assert_eq!(state.key("space", false), None);
    }
    #[test]
    fn tab_and_shift_tab_visit_both_visual_buttons_and_space_activates_only_focus() {
        let mut state = Interaction::default();
        assert_eq!(state.focused, Some(Choice::Cancel));
        state.key("tab", false);
        assert_eq!(state.focused, Some(Choice::Remove));
        state.key("tab", true);
        assert_eq!(state.focused, Some(Choice::Cancel));
        state.key("tab", true);
        assert_eq!(state.focused, Some(Choice::Remove));
        assert_eq!(state.key("space", false), Some(Choice::Remove));
    }
}

/// Measured from the original confirmation's native content/label/button views.
pub mod geometry {
    pub const WIDTH: f32 = 260.;
    pub const CORNER: f32 = 26.;
    pub const TEXT_INSET: f32 = 20.;
    pub const TITLE_GAP: f32 = 10.;
    pub const BUTTON_INSET: f32 = 16.;
    pub const BUTTON_GAP: f32 = 8.;
    pub const BUTTON_HEIGHT: f32 = 28.;
    pub const BUTTON_CORNER: f32 = 14.;
    pub const BUTTONS_TOP: f32 = 16.;
}
