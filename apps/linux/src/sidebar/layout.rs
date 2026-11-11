// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Source sidebar filtering, ordering and day buckets. Locale-sensitive string
//! comparison and calendar arithmetic are supplied by the platform adapter.

use super::ProjectsSort;
use crate::{chat::Conversation, desktop_data::Repository, work::text};
use std::cmp::Ordering;

pub const CHAT_PAGE_SIZE: usize = 30;
pub const OLDER_AFTER_DAYS: i64 = 7;

/// Foundation uses localized, case/diacritic-insensitive substring matching
/// and localized standard (numeric) ordering. Keep those platform decisions
/// outside the layout so they can be verified independently.
pub trait Collation {
    fn contains(&self, haystack: &str, needle: &str) -> bool;
    fn compare(&self, left: &str, right: &str) -> Ordering;
}

pub fn folder_matches(folder: &Repository, needle: &str, collation: &impl Collation) -> bool {
    collation.contains(&folder.name, needle)
        || folder
            .machine_label
            .as_deref()
            .is_some_and(|name| collation.contains(name, needle))
}

pub fn conversation_matches(chat: &Conversation, needle: &str, collation: &impl Collation) -> bool {
    collation.contains(&chat.title, needle)
        || chat
            .branch
            .as_deref()
            .is_some_and(|branch| collation.contains(branch, needle))
        || collation.contains(&chat.backend, needle)
}

pub fn matches(
    folder: &Repository,
    chats: &[Conversation],
    query: &str,
    collation: &impl Collation,
) -> bool {
    let needle = text::trim(query);
    needle.is_empty()
        || folder_matches(folder, needle, collation)
        || chats
            .iter()
            .any(|chat| conversation_matches(chat, needle, collation))
}

pub fn filtered_chats<'a>(
    chats: &'a [Conversation],
    query: &str,
    collation: &impl Collation,
) -> Vec<&'a Conversation> {
    let needle = text::trim(query);
    chats
        .iter()
        .filter(|chat| needle.is_empty() || conversation_matches(chat, needle, collation))
        .collect()
}

pub fn ordered_folders<'a>(
    folders: impl IntoIterator<Item = &'a Repository>,
    sort: ProjectsSort,
    activity: impl Fn(&Repository) -> i64,
    collation: &impl Collation,
) -> Vec<&'a Repository> {
    let mut folders: Vec<_> = folders.into_iter().collect();
    match sort {
        ProjectsSort::Manual => {}
        ProjectsSort::Name => folders.sort_by(|a, b| collation.compare(&a.name, &b.name)),
        ProjectsSort::Recent => folders.sort_by(|a, b| {
            activity(b)
                .cmp(&activity(a))
                .then_with(|| collation.compare(&a.name, &b.name))
        }),
    }
    folders
}

#[derive(Clone, Copy, Debug)]
pub struct ChatEntry<'a> {
    pub folder: &'a Repository,
    pub chat: &'a Conversation,
}
impl ChatEntry<'_> {
    pub fn activity_ms(&self) -> i64 {
        self.chat
            .last_message_at_ms
            .unwrap_or(self.chat.updated_at_ms)
    }
}

pub fn chat_entries<'a>(
    folders: &'a [Repository],
    chats: impl Fn(&Repository) -> &'a [Conversation],
    query: &str,
    sort: ProjectsSort,
    collation: &impl Collation,
) -> Vec<ChatEntry<'a>> {
    let needle = text::trim(query);
    let mut entries = Vec::new();
    for folder in folders {
        let folder_hit = !needle.is_empty() && folder_matches(folder, needle, collation);
        for chat in chats(folder) {
            if needle.is_empty() || folder_hit || conversation_matches(chat, needle, collation) {
                entries.push(ChatEntry { folder, chat });
            }
        }
    }
    match sort {
        ProjectsSort::Manual | ProjectsSort::Recent => entries.sort_by(|a, b| {
            b.chat
                .running
                .cmp(&a.chat.running)
                .then_with(|| b.activity_ms().cmp(&a.activity_ms()))
                .then_with(|| collation.compare(&a.chat.title, &b.chat.title))
        }),
        ProjectsSort::Name => entries.sort_by(|a, b| {
            collation
                .compare(&a.chat.title, &b.chat.title)
                .then_with(|| collation.compare(&a.folder.name, &b.folder.name))
        }),
    }
    entries
}

/// `Day(start)` carries the platform calendar's start-of-day identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Day {
    Working,
    Today,
    Yesterday,
    Day(i64),
    Older,
}

/// The adapter supplies the calendar start and calendar-day distance from a
/// timestamp to today; elapsed seconds are insufficient across DST changes.
pub fn day_groups<'a>(
    entries: &[ChatEntry<'a>],
    calendar_day: impl Fn(i64) -> (i64, i64),
) -> Vec<(Day, Vec<ChatEntry<'a>>)> {
    let mut groups: Vec<(Day, Vec<ChatEntry<'a>>)> = Vec::new();
    for entry in entries {
        let day = if entry.chat.running {
            Day::Working
        } else {
            let (start, days) = calendar_day(entry.activity_ms());
            match days {
                ..=0 => Day::Today,
                1 => Day::Yesterday,
                2..OLDER_AFTER_DAYS => Day::Day(start),
                _ => Day::Older,
            }
        };
        if let Some((_, bucket)) = groups.iter_mut().find(|(key, _)| *key == day) {
            bucket.push(*entry);
        } else {
            groups.push((day, vec![*entry]));
        }
    }
    groups
}
