// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Bounded live-search evaluation. Authority is supplied by the host, never
//! deserialized from a request. Sources must revalidate durable ownership when
//! reading snapshots; access is checked before reads and again before output.

use crate::{
    chat::SearchSnapshot,
    work_contracts::{WorkKind, WorkReference, WorkScope},
    work_search::{Coverage, Hit, MAX_DISPLAYED, Request, Response},
    work_search_conversation,
    work_search_cursor::{Context, Cursors},
    work_search_text,
};
use sha2::{Digest, Sha256};
use std::time::Instant;

pub struct Folder {
    pub id: String,
    pub name: String,
}

pub trait Source {
    fn permitted(&self) -> bool;
    fn folders(&self) -> Vec<Folder>;
    fn conversations(&self, workspace: &str) -> Result<Vec<String>, String>;
    fn snapshot(&self, workspace: &str, conversation: &str) -> Result<SearchSnapshot, String>;
}

/// Production source captures the authenticated transport context at creation.
/// It never accepts a peer identity or an authorization boolean from JSON.
pub struct StoreSource {
    store: std::sync::Arc<crate::chat::Store>,
    peer: Option<String>,
}

impl StoreSource {
    pub fn current() -> Self {
        Self {
            store: crate::chat::shared(),
            peer: crate::request_context::remote_peer(),
        }
    }
}

impl Source for StoreSource {
    fn permitted(&self) -> bool {
        self.peer
            .as_deref()
            .is_none_or(crate::workspace_policy::is_allowed)
    }
    fn folders(&self) -> Vec<Folder> {
        if !self.permitted() {
            return vec![];
        }
        crate::workspaces::read()
            .workspaces
            .iter()
            .map(|folder| Folder {
                id: folder.id.clone(),
                name: folder.name.clone(),
            })
            .collect()
    }
    fn conversations(&self, workspace: &str) -> Result<Vec<String>, String> {
        if !self.permitted() {
            return Err("workspace access is no longer available".into());
        }
        crate::workspaces::folder(workspace).map_err(|_| "folder is no longer available")?;
        Ok(self
            .store
            .list(workspace)
            .into_iter()
            .map(|chat| chat.id)
            .collect())
    }
    fn snapshot(&self, workspace: &str, conversation: &str) -> Result<SearchSnapshot, String> {
        if !self.permitted() {
            return Err("workspace access is no longer available".into());
        }
        crate::workspaces::folder(workspace).map_err(|_| "folder is no longer available")?;
        self.store.search_snapshot(workspace, conversation)
    }
}

/// Fixed server facts for one invocation. No Deserialize implementation.
pub struct Owner {
    pub scope: WorkScope,
    pub host_identity: String,
    pub requester: String,
}

pub fn search(
    source: &impl Source,
    owner: &Owner,
    request: &Request,
    cursors: &mut Cursors,
) -> Result<Response, String> {
    request.validate()?;
    if !source.permitted() {
        return Err("workspace access is no longer available".into());
    }
    let terms = work_search_text::terms(&request.query);
    let mut folders = source.folders();
    folders.retain(|f| request.workspace_ids.is_empty() || request.workspace_ids.contains(&f.id));
    folders.sort_by(|a, b| a.id.cmp(&b.id));
    let mut digest = Sha256::new();
    let mut hits = Vec::new();
    let mut coverage = Coverage {
        searched: 0,
        unreadable: 0,
        partial: false,
    };
    for folder in folders {
        if !source.permitted() {
            return Err("workspace access is no longer available".into());
        }
        let reference = WorkReference {
            scope: owner.scope.clone(),
            host_identity: owner.host_identity.clone(),
            workspace_id: folder.id.clone(),
            kind: WorkKind::Workspace,
            item_id: None,
            anchor: None,
        };
        bind(&mut digest, &folder.id);
        bind(&mut digest, &folder.name);
        if includes(request, &WorkKind::Workspace) {
            coverage.searched += 1;
            if let Some(hit) = matched(
                reference.clone(),
                "",
                &folder.name,
                "",
                &folder.name,
                0,
                false,
                &terms,
            ) {
                hits.push(hit);
                rank(&mut hits);
                hits.truncate(MAX_DISPLAYED);
            }
        }
        if !includes(request, &WorkKind::Conversation) {
            continue;
        }
        let mut ids = match source.conversations(&folder.id) {
            Ok(ids) => ids,
            Err(_) => {
                coverage.unreadable += 1;
                coverage.partial = true;
                bind(&mut digest, "unavailable-folder");
                continue;
            }
        };
        ids.sort();
        ids.dedup();
        for id in ids {
            if !source.permitted() {
                return Err("workspace access is no longer available".into());
            }
            bind(&mut digest, &id);
            let snapshot = match source.snapshot(&folder.id, &id) {
                Ok(snapshot) => snapshot,
                Err(_) => {
                    coverage.unreadable += 1;
                    coverage.partial = true;
                    bind(&mut digest, "unreadable");
                    continue;
                }
            };
            coverage.searched += 1;
            coverage.partial |= snapshot.partial;
            bind(&mut digest, &snapshot.revision);
            let mut reference = reference.clone();
            reference.kind = WorkKind::Conversation;
            reference.item_id = Some(id);
            let mut best = matched(
                reference.clone(),
                &snapshot.revision,
                &snapshot.title,
                "",
                &folder.name,
                snapshot.updated_at_ms,
                snapshot.partial,
                &terms,
            );
            for block in work_search_conversation::blocks(&snapshot.events, &snapshot.backend) {
                reference.anchor = Some(block.anchor);
                if let Some(hit) = matched(
                    reference.clone(),
                    &snapshot.revision,
                    &snapshot.title,
                    &block.text,
                    &folder.name,
                    snapshot.updated_at_ms,
                    snapshot.partial,
                    &terms,
                ) {
                    if best
                        .as_ref()
                        .is_none_or(|previous| hit.score > previous.score)
                    {
                        best = Some(hit);
                    }
                }
            }
            if let Some(hit) = best {
                hits.push(hit);
            }
            // Only the best displayed destinations are retained, even on hosts
            // with many conversations. Text snapshots drop after each iteration.
            rank(&mut hits);
            hits.truncate(MAX_DISPLAYED);
        }
    }
    if !source.permitted() {
        return Err("workspace access is no longer available".into());
    }
    rank(&mut hits);
    hits.truncate(MAX_DISPLAYED);
    // A deletion or edit after an earlier snapshot must not publish its old
    // excerpt. Reject this generation and let the caller retain/retry results.
    let current_folders = source.folders();
    for hit in &hits {
        if !current_folders
            .iter()
            .any(|folder| folder.id == hit.reference.workspace_id && folder.name == hit.folder_name)
        {
            return Err("search work changed; retry search".into());
        }
        if !source.permitted() {
            return Err("workspace access is no longer available".into());
        }
        if let Some(id) = &hit.reference.item_id {
            let current = source
                .snapshot(&hit.reference.workspace_id, id)
                .map_err(|_| "search work changed; retry search")?;
            if current.revision != hit.revision {
                return Err("search work changed; retry search".into());
            }
        }
    }
    if !source.permitted() {
        return Err("workspace access is no longer available".into());
    }
    let hash = digest.finalize();
    let context = Context {
        scope: owner.scope.clone(),
        requester: owner.requester.clone(),
        generation: u64::from_le_bytes(hash[..8].try_into().expect("SHA256 length")),
    };
    let now = Instant::now();
    let offset = if request.cursor.is_some() {
        cursors.resume(request, &context, now)?
    } else {
        0
    };
    let end = (offset + usize::from(request.limit)).min(hits.len());
    let next_cursor = if end < hits.len() {
        Some(cursors.issue(request, &context, end, now)?)
    } else {
        None
    };
    let hits = hits
        .into_iter()
        .skip(offset)
        .take(usize::from(request.limit))
        .collect();
    Ok(Response {
        hits,
        next_cursor,
        coverage,
    })
}

fn bind(digest: &mut Sha256, text: &str) {
    digest.update((text.len() as u64).to_le_bytes());
    digest.update(text.as_bytes());
}

fn includes(request: &Request, kind: &WorkKind) -> bool {
    request.entity_kinds.is_empty() || request.entity_kinds.contains(kind)
}

fn rank(hits: &mut [Hit]) {
    hits.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then(b.updated_at_ms.cmp(&a.updated_at_ms))
            .then(a.reference.workspace_id.cmp(&b.reference.workspace_id))
            .then(a.reference.item_id.cmp(&b.reference.item_id))
    });
}

#[allow(clippy::too_many_arguments)]
fn matched(
    reference: WorkReference,
    revision: &str,
    title: &str,
    body: &str,
    folder: &str,
    updated_at_ms: i64,
    partial: bool,
    terms: &[String],
) -> Option<Hit> {
    let title_key = work_search_text::normalize(title);
    let body_key = work_search_text::normalize(body);
    let folder_key = work_search_text::normalize(folder);
    let mut score = 0;
    for term in terms {
        let title_match = title_key.contains(term);
        let body_match = body_key.contains(term);
        let folder_match = folder_key.contains(term);
        if !title_match && !body_match && !folder_match {
            return None;
        }
        score += u32::from(title_match) * 8
            + u32::from(body_match) * 4
            + u32::from(folder_match && !title_match && !body_match);
    }
    let (excerpt, highlights) =
        work_search_text::excerpt(if body.is_empty() { title } else { body }, terms);
    Some(Hit {
        source: crate::work_search::HitSource::Live,
        reference,
        revision: revision.into(),
        title: title.into(),
        folder_name: folder.into(),
        excerpt,
        highlights,
        score,
        updated_at_ms,
        partial,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::work_contracts::ScopeKind;
    use std::cell::Cell;
    struct Fixture {
        allowed: Cell<bool>,
        reads: Cell<usize>,
        revoke: bool,
        revision: Cell<u64>,
    }
    impl Source for Fixture {
        fn permitted(&self) -> bool {
            self.allowed.get()
        }
        fn folders(&self) -> Vec<Folder> {
            assert!(self.allowed.get());
            vec![Folder {
                id: "folder".into(),
                name: "Design".into(),
            }]
        }
        fn conversations(&self, _: &str) -> Result<Vec<String>, String> {
            Ok(vec!["b".into(), "a".into()])
        }
        fn snapshot(&self, _: &str, _: &str) -> Result<SearchSnapshot, String> {
            self.reads.set(self.reads.get() + 1);
            if self.revoke {
                self.allowed.set(false);
            }
            Ok(SearchSnapshot {
                title: "Layout".into(),
                backend: "agent".into(),
                updated_at_ms: 1,
                revision: self.revision.get().to_string(),
                partial: false,
                events: vec![serde_json::json!({"seq":42,"kind":"user","text":"A café layout"})],
            })
        }
    }
    fn fixture() -> Fixture {
        Fixture {
            allowed: Cell::new(true),
            reads: Cell::new(0),
            revoke: false,
            revision: Cell::new(1),
        }
    }
    fn owner() -> Owner {
        Owner {
            scope: WorkScope {
                kind: ScopeKind::Local,
                origin: "".into(),
                identity: "host".into(),
            },
            host_identity: "host".into(),
            requester: "peer".into(),
        }
    }
    #[test]
    fn ranks_anchored_matches_and_binds_continuations_to_revisions() {
        let source = fixture();
        let mut cursors = Cursors::default();
        let mut request = Request::parse(r#"{"query":"CAFÉ layout","limit":1}"#).unwrap();
        let first = search(&source, &owner(), &request, &mut cursors).unwrap();
        assert_eq!(first.hits[0].reference.item_id.as_deref(), Some("a"));
        assert_eq!(first.hits[0].reference.anchor.as_deref(), Some("user-s42"));
        assert_eq!(first.coverage.searched, 3);
        request.cursor = first.next_cursor;
        let second = search(&source, &owner(), &request, &mut cursors).unwrap();
        assert_eq!(second.hits[0].reference.item_id.as_deref(), Some("b"));
        assert!(second.next_cursor.is_none());
        source.revision.set(2);
        assert!(search(&source, &owner(), &request, &mut cursors).is_err());
    }
    #[test]
    fn refusal_precedes_reads_and_revocation_discards_excerpts() {
        let mut source = fixture();
        let mut cursors = Cursors::default();
        let request = Request::parse(r#"{"query":"layout"}"#).unwrap();
        source.allowed.set(false);
        assert!(search(&source, &owner(), &request, &mut cursors).is_err());
        assert_eq!(source.reads.get(), 0);
        source.allowed.set(true);
        source.revoke = true;
        assert!(search(&source, &owner(), &request, &mut cursors).is_err());
        assert_eq!(source.reads.get(), 1);
    }
}
