// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One inert data set shared by the actual component and SwiftUI references.

use super::Conversation;
use serde::Serialize;
use std::collections::HashMap;

/// Source and GPUI references use a fixed clock, not the render wall time.
pub const NOW_MS: i64 = 1_700_000_000_000;
/// Offline states cover the actual child composition, not a substitute layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Case {
    Ready,
    Empty,
    Loading,
    Failed,
    Expanded,
    Tail,
    Hover,
    Shift,
    Held,
    Decorated,
    Copying,
}
impl Case {
    /// Every state is emitted by the shared source-reference data executable.
    pub const ALL: [Self; 11] = [
        Self::Ready,
        Self::Empty,
        Self::Loading,
        Self::Failed,
        Self::Expanded,
        Self::Tail,
        Self::Hover,
        Self::Shift,
        Self::Held,
        Self::Decorated,
        Self::Copying,
    ];
    /// Stable names let a reference image identify its component fixture.
    pub fn name(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Empty => "empty",
            Self::Loading => "loading",
            Self::Failed => "failed",
            Self::Expanded => "expanded",
            Self::Tail => "selected-tail",
            Self::Hover => "hover",
            Self::Shift => "shift",
            Self::Held => "held",
            Self::Decorated => "decorated",
            Self::Copying => "copying",
        }
    }
    /// Reject unknown modes before any application or owner initialization.
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|case| case.name() == name)
    }
    /// Synthetic metadata never opens a transcript, folder or live endpoint.
    pub fn data(self) -> Fixture {
        let count = match self {
            Self::Empty | Self::Loading | Self::Failed => 0,
            Self::Expanded => 12,
            Self::Tail => 15,
            _ => 7,
        };
        let titles = [
            "Investigate streaming usage",
            "",
            "New chat",
            "Review the sidebar",
            "東京・árvíztűrő・🐧",
            "A deliberately long conversation title that should truncate inside its reserved controls",
            "Prepare Linux build",
        ];
        let mut rows = (0..count)
            .map(|index| Conversation {
                pending_steer: None,
                id: format!("chat-{index}"),
                workspace_id: "/fixture/alpha".into(),
                title: titles[index % titles.len()].into(),
                backend: ["codex", "claude", "unknown-tool"][index % 3].into(),
                team_share: None,
                updated_at_ms: NOW_MS - (index as i64 + 1) * 60000,
                last_message_at_ms: (index != 2).then_some(NOW_MS - (index as i64 + 1) * 60000),
                running: index == 0,
                pull: None,
                ..Conversation::default()
            })
            .collect::<Vec<_>>();
        if self == Self::Held {
            rows.rotate_left(2);
        }
        if self == Self::Decorated {
            for (index, row) in rows.iter_mut().take(5).enumerate() {
                row.running = false;
                row.pull = Some(super::Pull {
                    number: index as u32 + 1,
                    title: "A fixture pull request".into(),
                    url: format!("https://fixture.invalid/pull/{}", index + 1),
                    state: ["open", "open", "merged", "closed", "future"][index].into(),
                    draft: index == 0,
                    base_ref: "main".into(),
                });
            }
            rows[0].team_share = Some(super::Sharing {
                id: "fixture-publication".into(),
            });
        }
        Fixture {
            name: self.name().into(),
            rows,
            presentation: match self {
                Self::Empty => "empty",
                Self::Loading => "loading",
                Self::Failed => "failed",
                _ => "content",
            }
            .into(),
            expanded: matches!(self, Self::Expanded | Self::Tail),
            selected: if self == Self::Tail {
                Some("chat-12".into())
            } else {
                None
            },
            hovered: matches!(self, Self::Hover | Self::Shift | Self::Copying)
                .then(|| "chat-3".into()),
            shift: matches!(self, Self::Shift | Self::Copying),
            copying: if self == Self::Copying {
                vec!["chat-3".into()]
            } else {
                vec![]
            },
            drafts: [("chat-2".into(), true)].into_iter().collect(),
            held: (self == Self::Held)
                .then(|| (0..7).map(|index| format!("chat-{index}")).collect()),
            now: NOW_MS,
            running_since: NOW_MS - 10000,
        }
    }
}
/// These explicit facts are confined to offline fixtures and source references.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Fixture {
    pub name: String,
    pub rows: Vec<Conversation>,
    pub presentation: String,
    pub expanded: bool,
    pub selected: Option<String>,
    pub hovered: Option<String>,
    pub shift: bool,
    pub copying: Vec<String>,
    pub drafts: HashMap<String, bool>,
    pub held: Option<Vec<String>>,
    pub now: i64,
    pub running_since: i64,
}
/// The same informative messages are measured in the original native alert.
#[derive(Clone, Copy, Debug)]
pub enum ErrorCase {
    Failed,
    Long,
    Unicode,
    AccountChanged,
    Unsupported,
}
impl ErrorCase {
    /// Reject unknown component modes before any App or owner initialization.
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "failed" => Some(Self::Failed),
            "long" => Some(Self::Long),
            "unicode" => Some(Self::Unicode),
            "account-changed" => Some(Self::AccountChanged),
            "unsupported" => Some(Self::Unsupported),
            _ => None,
        }
    }
    /// Synthetic failures never start a copy or touch a transcript.
    pub fn message(self) -> String {
        match self {
        Self::Failed=>"The host could not copy this chat.".into(),
        Self::Long=>"The host could not copy this chat. A deliberately long failure message wraps over several lines so the original native alert decides its own content size.".into(),
        Self::Unicode=>"東京・árvíztűrő・🐧\nThe host is unavailable.".into(),
        Self::AccountChanged=>crate::localization::text("apple.chatmodel.the_account_changed_while_copying_the_chat.223191a0",&[]),
        Self::Unsupported=>crate::localization::text("apple.bridge.update_the_project_s_computer_to_fork_chat.4d57279f",&[]),
    }
    }
    /// Fixed logical viewport follows measured original native content size.
    pub fn height(self) -> f32 {
        match self {
            Self::Failed => 122.,
            Self::Long => 186.,
            _ => 138.,
        }
    }
}
