// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The running clock owns its own invalidation. Ticks never notify Desktop or
//! rebuild the directory/held order, matching TurnElapsedText's small lifetime.

use super::{home_shared::HomeShared, *};
use crate::chat::history;

#[derive(Clone, PartialEq)]
pub(super) struct Reading {
    pub running: bool,
    pub since: Option<i64>,
    pub updated: i64,
    pub dark: bool,
}
pub(super) struct Status {
    reading: Reading,
    now: i64,
    generation: u64,
    frozen: bool,
}
impl Status {
    fn new(reading: Reading, now: i64, frozen: bool, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            reading,
            now,
            generation: 0,
            frozen,
        };
        view.tick(cx);
        view
    }
    fn label(&self) -> String {
        if self.reading.running {
            self.reading
                .since
                .map(|since| {
                    format!(
                        "{} · {}",
                        l("common.working"),
                        history::elapsed(since, self.now)
                    )
                })
                .unwrap_or_else(|| l("common.working"))
        } else {
            history::age(self.reading.updated, self.now)
        }
    }
    fn set(&mut self, reading: Reading, now: i64, cx: &mut Context<Self>) {
        let before = self.label();
        let changed = self.reading != reading;
        let was_running = self.reading.running;
        self.reading = reading;
        self.now = now;
        if !self.reading.running {
            self.generation = self.generation.wrapping_add(1);
        } else if !was_running {
            self.tick(cx);
        }
        if changed || before != self.label() {
            cx.notify();
        }
    }
    fn tick(&mut self, cx: &mut Context<Self>) {
        if self.frozen || !self.reading.running {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        cx.spawn(async move |view, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_secs(1))
                    .await;
                if view
                    .update(cx, |view, cx| {
                        if !view.reading.running || view.generation != generation {
                            return false;
                        }
                        let before = view.label();
                        view.now = crate::home::plans::now_ms();
                        if before != view.label() {
                            cx.notify();
                        }
                        true
                    })
                    .ok()
                    != Some(true)
                {
                    break;
                }
            }
        })
        .detach();
    }
}
impl Render for Status {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let mut row = div().flex().items_center().gap(px(4.)).flex_none();
        if self.reading.running {
            row = row.child(
                div()
                    .size(px(5.))
                    .rounded_full()
                    .bg(palette::ACCENT.resolve(self.reading.dark)),
            );
        }
        row.child(
            presentation::numeric(
                self.label(),
                FontToken {
                    points: 11.,
                    weight: 400,
                },
            )
            .whitespace_nowrap(),
        )
    }
}
impl Desktop {
    /// Mount clocks only for actually visible conversations, never the archive.
    pub(super) fn prepare_chat_statuses(
        &mut self,
        visible: bool,
        dark: bool,
        cx: &mut Context<Self>,
    ) {
        let mut readings = Vec::new();
        if visible
            && self.project_directory.projects_expanded()
            && self.projects_display == crate::sidebar::ProjectsDisplay::ByChat
        {
            for (folder, row) in self.timeline_visible_rows(cx) {
                readings.push((
                    (folder.id.clone(), row.id.clone()),
                    Reading {
                        running: row.running,
                        since: self.chat_directory.running_since(&row.id),
                        updated: row.last_message_at_ms.unwrap_or(row.updated_at_ms),
                        dark,
                    },
                ));
            }
        } else if visible && self.project_directory.projects_expanded() {
            for folder in self
                .visible_project_folders(cx)
                .into_iter()
                .filter(|folder| self.project_directory.expanded(&folder.id))
            {
                let selected = self.selected_chat.as_ref().map(|(_, id)| id.as_str());
                let rows = self.visible_project_chats(folder, cx);
                let ordered = history::holding_order(&rows, self.chat_history.held(&folder.id));
                let index = selected.and_then(|id| {
                    ordered
                        .iter()
                        .position(|row| crate::work::text::equal(&row.id, id))
                });
                let range =
                    history::visible(ordered.len(), index, self.chat_history.expanded(&folder.id));
                for row in &ordered[range] {
                    readings.push((
                        (folder.id.clone(), row.id.clone()),
                        Reading {
                            running: row.running,
                            since: self.chat_directory.running_since(&row.id),
                            updated: row.last_message_at_ms.unwrap_or(row.updated_at_ms),
                            dark,
                        },
                    ));
                }
            }
        }
        self.chat_statuses
            .retain(|key, _| readings.iter().any(|(present, _)| present == key));
        let action_keys = readings
            .iter()
            .filter_map(|(key, _)| self.chat_action_key(&key.0, &key.1))
            .collect();
        self.chat_actions.retain(&action_keys);
        let frozen = self.fixture.is_some();
        let now = if frozen {
            cx.global::<HomeShared>().clock_ms
        } else {
            crate::home::plans::now_ms()
        };
        let mut marks = std::collections::BTreeSet::new();
        for (key, reading) in readings {
            if let Some(mark) = self.prepare_draft_mark(&key.0, &key.1, dark, cx) {
                marks.insert(mark);
            }
            if !reading.running {
                cx.global::<HomeShared>().clock_read.set(true);
            }
            if let Some(status) = self.chat_statuses.get(&key) {
                status.update(cx, |status, cx| status.set(reading, now, cx));
            } else {
                let status = cx.new(|cx| Status::new(reading, now, frozen, cx));
                self.chat_statuses.insert(key, status);
            }
        }
        self.draft_marks.retain(|key, _| marks.contains(key));
    }
}
