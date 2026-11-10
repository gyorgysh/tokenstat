// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Preserve accepted pending notes across older list/metadata replies. This does
//! not send, deliver, clear or start an agent; those owners join it separately.

use super::{Conversation, list_mutations::key};
use std::collections::{HashMap, HashSet};

/// One project list request, ordered independently from all other projects.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    owner: String,
    sequence: u64,
}
/// An explicit removal must still own the same note acceptance at completion.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mutation {
    owner: String,
    conversation_id: String,
    revision: u64,
}
struct Change {
    note: Option<String>,
    through: u64,
}
#[derive(Default)]
struct Project {
    requested: u64,
    applied: u64,
    changes: HashMap<String, Change>,
    mutations: HashMap<String, u64>,
}
/// Per-window ephemeral acknowledgments keyed by full account/host/project owner.
#[derive(Default)]
pub struct Model {
    projects: HashMap<String, Project>,
}
impl Model {
    /// Capture a sequence before a list request can race with a note mutation.
    pub fn begin_read(&mut self, owner: &str) -> Read {
        let owner = key(owner);
        let project = self.projects.entry(owner.clone()).or_default();
        project.requested = project.requested.wrapping_add(1);
        Read {
            owner,
            sequence: project.requested,
        }
    }
    /// Snapshot acceptance ownership, even if a fresh list retired its overlay.
    pub fn mutation(&self, owner: &str, id: &str) -> Mutation {
        let owner = key(owner);
        let conversation_id = key(id);
        let revision = self
            .projects
            .get(&owner)
            .and_then(|p| p.mutations.get(&conversation_id))
            .copied()
            .unwrap_or(0);
        Mutation {
            owner,
            conversation_id,
            revision,
        }
    }
    /// Identical note text can still belong to a newer acceptance.
    pub fn remember(
        &mut self,
        owner: &str,
        id: &str,
        note: Option<String>,
        since: Option<&Mutation>,
    ) -> bool {
        let owner = key(owner);
        let id = key(id);
        let project = self.projects.entry(owner.clone()).or_default();
        let revision = project.mutations.get(&id).copied().unwrap_or(0);
        if since
            .is_some_and(|m| m.owner != owner || m.conversation_id != id || m.revision != revision)
        {
            return false;
        }
        project
            .mutations
            .insert(id.clone(), revision.wrapping_add(1));
        project.changes.insert(
            id,
            Change {
                note,
                through: project.requested,
            },
        );
        true
    }
    /// Old lists retain accepted notes; lists begun after acceptance are fresh.
    pub fn apply(
        &mut self,
        mut rows: Vec<Conversation>,
        read: &Read,
        current: &[Conversation],
    ) -> Vec<Conversation> {
        let project = self.projects.entry(read.owner.clone()).or_default();
        if read.sequence < project.applied {
            return current.to_vec();
        }
        project.applied = read.sequence;
        let present = rows.iter().map(|row| key(&row.id)).collect::<HashSet<_>>();
        for row in &mut rows {
            let id = key(&row.id);
            if let Some(change) = project.changes.get(&id) {
                if read.sequence > change.through {
                    project.changes.remove(&id);
                } else {
                    row.pending_steer = change.note.clone();
                }
            }
        }
        project
            .changes
            .retain(|id, change| present.contains(id) || read.sequence <= change.through);
        rows
    }
    /// Retire all account/host/project acknowledgment state on a real scope change.
    pub fn remove_all(&mut self) {
        self.projects.clear();
    }
    /// Metadata replies omit ephemeral notes; absence there is not consumption.
    pub fn preserving_note(
        mut record: Conversation,
        current: Option<&Conversation>,
    ) -> Conversation {
        if let Some(current) = current.filter(|c| crate::work::text::equal(&c.id, &record.id)) {
            record.pending_steer = current.pending_steer.clone();
        }
        record
    }
}
