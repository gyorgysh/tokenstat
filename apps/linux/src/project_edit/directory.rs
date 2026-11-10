// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! RootView's known-project/disclosure and missing-current-route reconciliation.
//! Unknown/error results do not become an authoritative empty directory.

use crate::{
    navigation::{Navigation, Route, WorkspaceSection},
    work::text,
};
use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Directory {
    known: HashSet<String>,
    expanded: HashSet<String>,
    pending: HashSet<String>,
    projects_expanded: bool,
    section_pending: bool,
}
impl Default for Directory {
    fn default() -> Self {
        Self {
            known: HashSet::new(),
            expanded: HashSet::new(),
            pending: HashSet::new(),
            projects_expanded: true,
            section_pending: true,
        }
    }
}
fn key(id: &str) -> String {
    id.nfc().collect()
}
impl Directory {
    pub fn expanded(&self, id: &str) -> bool {
        self.expanded.contains(&key(id))
    }
    /// Explicit project expansion also reveals its parent section as in RootView.
    pub fn set_expanded(&mut self, id: &str, expanded: bool) {
        let id = key(id);
        self.pending.remove(&id);
        if expanded {
            self.expanded.insert(id);
            self.set_projects_expanded(true);
        } else {
            self.expanded.remove(&id);
        }
    }
    pub fn toggle(&mut self, id: &str) {
        self.set_expanded(id, !self.expanded(id));
    }
    /// The Projects section retains this window's state after initialization.
    pub fn projects_expanded(&self) -> bool {
        self.projects_expanded
    }
    /// Before the first read, expanding a project must also protect its parent
    /// section from a later persisted collapse.
    pub fn needs_projects_expansion(&self) -> bool {
        !self.projects_expanded || self.section_pending
    }
    /// User input retires the pending first-read default for this section.
    pub fn set_projects_expanded(&mut self, expanded: bool) {
        self.projects_expanded = expanded;
        self.section_pending = false;
    }
    /// A delayed first read may initialize untouched rows, but never reverses
    /// explicit user input. Later storage reads do not reset known rows.
    pub fn apply_preferences(&mut self, preferences: &crate::sidebar::Snapshot) {
        if self.section_pending {
            self.projects_expanded = preferences.is_expanded("section:projects", true);
            self.section_pending = false;
        }
        for id in self.pending.drain() {
            if preferences.is_expanded(&format!("project:{id}"), true) {
                self.expanded.insert(id);
            } else {
                self.expanded.remove(&id);
            }
        }
    }
    /// Memory-only callers use the source defaults without waiting for IO.
    pub fn reconcile(
        &mut self,
        ids: Option<&[String]>,
        navigation: &mut Navigation,
    ) -> Option<Route> {
        self.reconcile_with_preferences(ids, navigation, Some(&crate::sidebar::Snapshot::default()))
    }
    /// Source applies preferences only to newly known IDs, retaining stored
    /// keys when a peer or registration disappears from the directory.
    pub fn reconcile_with_preferences(
        &mut self,
        ids: Option<&[String]>,
        navigation: &mut Navigation,
        preferences: Option<&crate::sidebar::Snapshot>,
    ) -> Option<Route> {
        let ids = ids?;
        let incoming = ids.iter().map(|id| key(id)).collect::<HashSet<_>>();
        for id in incoming.difference(&self.known) {
            self.pending.insert(id.clone());
            self.expanded.insert(id.clone());
        }
        self.pending.retain(|id| incoming.contains(id));
        self.expanded.retain(|id| incoming.contains(id));
        self.known = incoming;
        if let Some(preferences) = preferences {
            self.apply_preferences(preferences);
        }
        let Route::Workspace { id, .. } = &navigation.route else {
            return None;
        };
        if ids.iter().any(|present| text::equal(id, present)) {
            return None;
        }
        let removed = id.clone();
        navigation.forget_workspace(&removed);
        Some(
            ids.first()
                .map(|id| Route::Workspace {
                    id: id.clone(),
                    section: WorkspaceSection::Sessions,
                })
                .unwrap_or_default(),
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::sidebar::{Mutation, Snapshot};
    #[test]
    fn first_read_only_initializes_untouched_rows_and_each_window_keeps_local_choices() {
        let mut first = Directory::default();
        let mut navigation = Navigation::default();
        let ids = ["a".into(), "b".into(), "c".into()];
        first.reconcile_with_preferences(Some(&ids), &mut navigation, None);
        first.set_expanded("a", false);
        first.set_expanded("b", true);
        first.set_projects_expanded(false);
        let mut preferences = Snapshot::default();
        for key in ["project:a", "project:b", "project:c"] {
            preferences.apply(&Mutation::Expansion {
                key: key.into(),
                expanded: false,
            });
        }
        first.apply_preferences(&preferences);
        assert!(!first.expanded("a") && first.expanded("b") && !first.expanded("c"));
        assert!(!first.projects_expanded());
        preferences.apply(&Mutation::Expansion {
            key: "project:b".into(),
            expanded: false,
        });
        first.apply_preferences(&preferences);
        assert!(first.expanded("b"));
        let mut reopened = Directory::default();
        reopened.reconcile_with_preferences(Some(&ids), &mut navigation, Some(&preferences));
        assert!(!reopened.expanded("b"));
        assert!(reopened.projects_expanded());
        first.reconcile_with_preferences(
            Some(&["a".into(), "c".into()]),
            &mut navigation,
            Some(&preferences),
        );
        first.reconcile_with_preferences(Some(&ids), &mut navigation, Some(&preferences));
        assert!(!first.expanded("b"));
        first.set_expanded("b", true);
        assert!(first.projects_expanded());
    }
    #[test]
    fn an_explicit_project_expansion_also_protects_an_uninitialized_parent_section() {
        let mut directory = Directory::default();
        let mut navigation = Navigation::default();
        directory.reconcile_with_preferences(Some(&["a".into()]), &mut navigation, None);
        assert!(directory.needs_projects_expansion());
        directory.set_expanded("a", true);
        let mut preferences = Snapshot::default();
        preferences.apply(&Mutation::Expansion {
            key: "section:projects".into(),
            expanded: false,
        });
        directory.apply_preferences(&preferences);
        assert!(directory.projects_expanded() && directory.expanded("a"));
    }
    #[test]
    fn errors_preserve_disclosure_and_route_and_confirmed_removal_selects_the_next_folder() {
        let mut state = Directory::default();
        let mut navigation = Navigation::default();
        let ids = vec!["a".into(), "b".into()];
        state.reconcile(Some(&ids), &mut navigation);
        assert!(state.expanded("a"));
        state.toggle("a");
        navigation.navigate(Route::Workspace {
            id: "a".into(),
            section: WorkspaceSection::History,
        });
        let before = state.clone();
        assert!(state.reconcile(None, &mut navigation).is_none());
        assert_eq!(state, before);
        assert_eq!(
            navigation.last_workspace_section("a"),
            WorkspaceSection::History
        );
        assert_eq!(
            state.reconcile(Some(&["b".into()]), &mut navigation),
            Some(Route::Workspace {
                id: "b".into(),
                section: WorkspaceSection::Sessions
            })
        );
        assert_eq!(
            navigation.last_workspace_section("a"),
            WorkspaceSection::Chat
        );
        assert!(!state.expanded("a"));
    }
    #[test]
    fn unrelated_routes_and_known_choices_survive_reload_and_unicode_keys_match_swift() {
        let mut state = Directory::default();
        let mut navigation = Navigation::default();
        state.reconcile(Some(&["é".into(), "b".into()]), &mut navigation);
        state.toggle("e\u{301}");
        assert!(!state.expanded("é"));
        assert!(
            state
                .reconcile(Some(&["é".into(), "b".into(), "c".into()]), &mut navigation)
                .is_none()
        );
        assert!(state.expanded("c"));
        assert!(!state.expanded("é"));
        navigation.navigate(Route::Workspace {
            id: "e\u{301}".into(),
            section: WorkspaceSection::Chat,
        });
        assert!(
            state
                .reconcile(Some(&["é".into()]), &mut navigation)
                .is_none()
        );
        assert_eq!(
            state.reconcile(Some(&[]), &mut navigation),
            Some(Route::default())
        );
    }
}
