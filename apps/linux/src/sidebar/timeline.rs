// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Per-window task identity for the cross-project chat directory warmer.
//! A task reads one folder at a time and is replaced when its owner or folder
//! list changes, like the SwiftUI view's scoped task.

use crate::{chat::directory::Owner, work::text};
use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WarmMode {
    Timeline,
    Filter,
    Recent,
    RecentFiltered,
}

#[derive(Default)]
pub struct WarmTask {
    owner: Option<Owner>,
    folders: Vec<String>,
    remaining: VecDeque<String>,
    mode: Option<WarmMode>,
}
impl WarmTask {
    /// Re-entering the chat view starts a fresh read of every folder. A helper
    /// or account change also replaces the task, retiring old deliveries.
    pub fn reconcile(
        &mut self,
        mode: Option<WarmMode>,
        owner: Option<&Owner>,
        folders: &[String],
    ) -> bool {
        let same_folders = self.folders.len() == folders.len()
            && self
                .folders
                .iter()
                .zip(folders)
                .all(|(a, b)| text::equal(a, b));
        let changed = if mode.is_some() && owner.is_some() {
            self.mode != mode || self.owner.as_ref() != owner || !same_folders
        } else {
            self.mode.is_some()
        };
        if mode.is_some() && owner.is_some() {
            if changed {
                self.owner = owner.cloned();
                self.folders = folders.to_vec();
                self.remaining = folders.iter().cloned().collect();
            }
            self.mode = mode;
        } else {
            self.mode = None;
            self.owner = None;
            self.folders.clear();
            self.remaining.clear();
        }
        changed
    }
    /// A pending directory read must finish or be retired before another starts.
    pub fn next(&mut self, busy: bool) -> Option<String> {
        if self.mode.is_some() && !busy {
            self.remaining.pop_front()
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::work::{Scope, ScopeKind};
    fn owner(generation: u64) -> Owner {
        Owner {
            scope: Scope {
                kind: ScopeKind::Local,
                origin: "".into(),
                identity: "fixture".into(),
            },
            generation,
            local_host_identity: "host".into(),
        }
    }
    #[test]
    fn task_is_serial_and_restarts_only_for_a_new_view_owner_or_folder_list() {
        let mut task = WarmTask::default();
        let first = owner(1);
        let folders = vec!["é".into(), "second".into()];
        task.reconcile(Some(WarmMode::Timeline), Some(&first), &folders);
        assert_eq!(task.next(false).as_deref(), Some("é"));
        task.reconcile(
            Some(WarmMode::Timeline),
            Some(&first),
            &["e\u{301}".into(), "second".into()],
        );
        assert_eq!(task.next(true), None);
        assert_eq!(task.next(false).as_deref(), Some("second"));
        assert_eq!(task.next(false), None);
        assert!(task.reconcile(Some(WarmMode::Filter), Some(&first), &folders));
        assert_eq!(task.next(false).as_deref(), Some("é"));
        assert!(task.reconcile(Some(WarmMode::Recent), Some(&first), &folders));
        assert_eq!(task.next(false).as_deref(), Some("é"));
        task.reconcile(Some(WarmMode::Timeline), Some(&owner(2)), &folders);
        assert_eq!(task.next(false).as_deref(), Some("é"));
        task.reconcile(None, Some(&first), &folders);
        assert_eq!(task.next(false), None);
        task.reconcile(Some(WarmMode::Timeline), Some(&first), &folders);
        assert_eq!(task.next(false).as_deref(), Some("é"));
        task.reconcile(Some(WarmMode::Timeline), None, &folders);
        assert_eq!(task.next(false), None);
    }
}
