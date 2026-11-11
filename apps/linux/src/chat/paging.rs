// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Retained live transcript window with guarded raw-event/row publication.
//! Page work follows selection, epoch and cursor; metadata work follows the
//! selection and event revision. Transport and CPU work run elsewhere.
//! Saved copies, outgoing rows and the view's scroll/follow state have separate
//! owners and are not represented as successful live pages here.

use super::{Conversation, directory::Owner, send_context, wire::*};
use crate::work::text;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
static NEXT_WINDOW: AtomicU64 = AtomicU64::new(1);
pub mod publication;
#[cfg(test)]
mod tests;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadKind {
    Newest,
    Whole,
    Tail,
    Earlier,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    pub owner: Owner,
    pub folder: String,
    pub id: String,
    pub kind: ReadKind,
    pub offset: u64,
    pub cursor: Option<String>,
    pub quiet: bool,
    selection: u64,
    epoch: u64,
    ticket: u64,
    revision: Option<u64>,
    instance: u64,
}
/// A setup/rename acknowledgment belongs to the selection and revision at its
/// start, even if a metadata refresh updates that same selection while waiting.
#[derive(Clone, Debug)]
pub struct Edit {
    owner: Owner,
    folder: String,
    id: String,
    selection: u64,
    revision: Option<u64>,
    instance: u64,
}
impl Read {
    pub fn method(&self) -> &'static str {
        self.query().method()
    }
    pub fn parameters(&self) -> serde_json::Value {
        self.query().parameters()
    }
}
#[derive(Clone, Debug)]
pub struct Failure {
    pub message: String,
    pub unknown_method: bool,
}
/// One completion can request a source fallback/reopen. The caller must route
/// it through shared read flights and recheck ownership before dispatching IO.
#[derive(Clone, Default)]
pub struct Completion {
    pub accepted: bool,
    pub records_changed: bool,
    pub reopen: Option<Read>,
    pub restore_reading: bool,
    pub more_tail: bool,
}
#[derive(Default)]
pub struct Window {
    instance: u64,
    owner: Option<Owner>,
    folder: Option<String>,
    selected: Option<Conversation>,
    selection: u64,
    epoch: u64,
    next: u64,
    replacement: Option<u64>,
    earlier: Option<u64>,
    events: Arc<Vec<TimelineEvent>>,
    rows: Arc<Vec<super::transcript::Row>>,
    events_revision: u64,
    display_revision: u64,
    display_key: Option<publication::DisplayKey>,
    metadata_ticket: Option<u64>,
    live_loaded: bool,
    opening: bool,
    paging_unavailable: bool,
    offset: u64,
    tail_cursor: Option<String>,
    earlier_cursor: Option<String>,
    has_earlier: bool,
    loading_earlier: bool,
    reached_start: bool,
    history_trimmed: bool,
    usage: Option<UsageTotals>,
    usage_through: Option<u64>,
    context_revision: Option<u64>,
    error: Option<String>,
}
impl Window {
    pub fn owner(&self) -> Option<&Owner> {
        self.owner.as_ref()
    }
    #[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
    pub(crate) fn selection_generation(&self) -> u64 {
        self.selection
    }
    pub fn selected(&self) -> Option<&Conversation> {
        self.selected.as_ref()
    }
    pub fn folder(&self) -> Option<&str> {
        self.folder.as_deref()
    }
    pub fn events(&self) -> &[TimelineEvent] {
        &self.events
    }
    pub fn rows(&self) -> &[super::transcript::Row] {
        &self.rows
    }
    /// Retain an immutable projection while view-specific folding runs off-thread.
    pub fn shared_rows(&self) -> Arc<Vec<super::transcript::Row>> {
        self.rows.clone()
    }
    pub fn events_revision(&self) -> u64 {
        self.events_revision
    }
    pub fn display_revision(&self) -> u64 {
        self.display_revision
    }
    pub fn live_loaded(&self) -> bool {
        self.live_loaded
    }
    pub fn opening(&self) -> bool {
        self.opening
    }
    pub fn paging_unavailable(&self) -> bool {
        self.paging_unavailable
    }
    pub fn offset(&self) -> u64 {
        self.offset
    }
    pub fn tail_cursor(&self) -> Option<&str> {
        self.tail_cursor.as_deref()
    }
    pub fn earlier_cursor(&self) -> Option<&str> {
        self.earlier_cursor.as_deref()
    }
    pub fn has_earlier(&self) -> bool {
        self.has_earlier
    }
    pub fn loading_earlier(&self) -> bool {
        self.loading_earlier
    }
    pub fn reached_start(&self) -> bool {
        self.reached_start
    }
    pub fn history_trimmed(&self) -> bool {
        self.history_trimmed
    }
    pub fn usage(&self) -> Option<&UsageTotals> {
        self.usage.as_ref()
    }
    pub fn usage_through(&self) -> Option<u64> {
        self.usage_through
    }
    pub fn context_revision(&self) -> Option<u64> {
        self.context_revision
    }
    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    pub fn dismiss_error(&mut self) {
        self.error = None;
    }
    /// The caller saves/restores warm display rows and drafts around this step.
    /// Selecting the same chat refreshes in place rather than clearing its rows.
    pub fn select(
        &mut self,
        owner: Owner,
        folder: &str,
        chat: Option<Conversation>,
        fresh: bool,
    ) -> bool {
        if self.instance == 0 {
            self.instance = NEXT_WINDOW.fetch_add(1, Ordering::Relaxed);
        }
        let same = self.owner.as_ref() == Some(&owner)
            && self
                .folder
                .as_deref()
                .is_some_and(|f| text::equal(f, folder))
            && matches!((&self.selected,&chat),(Some(a),Some(b)) if text::equal(&a.id,&b.id));
        if same {
            return false;
        }
        let previous_peer = self
            .folder
            .as_deref()
            .and_then(|f| crate::work::destination::route(f, None).peer);
        let next_peer = crate::work::destination::route(folder, None).peer;
        let peer_changed = match (previous_peer.as_deref(), next_peer.as_deref()) {
            (Some(a), Some(b)) => !text::equal(a, b),
            (None, None) => false,
            _ => true,
        };
        // ChatModel.load resets this host capability only when peer changes.
        if peer_changed {
            self.paging_unavailable = false;
        }
        self.selection = self.selection.wrapping_add(1);
        self.owner = Some(owner);
        self.folder = Some(folder.into());
        self.selected = chat;
        self.events = Arc::default();
        self.events_revision = self.events_revision.wrapping_add(1);
        self.rows = Arc::default();
        self.display_key = None;
        self.metadata_ticket = None;
        self.forget_window();
        self.opening = self.selected.is_some() && !fresh;
        if fresh && self.selected.is_some() {
            self.live_loaded = true;
            self.context_revision = self.selected.as_ref().and_then(|c| c.send_revision);
        }
        true
    }
    /// Scope retirement destroys private live state; hidden navigation does not.
    pub fn retire(&mut self) {
        let selection = self.selection.wrapping_add(1);
        let next = self.next;
        let instance = self.instance;
        let events_revision = self.events_revision.wrapping_add(1);
        let display_revision = self.display_revision;
        let epoch = self.epoch.wrapping_add(1);
        *self = Self {
            selection,
            next,
            instance,
            events_revision,
            display_revision,
            epoch,
            ..Self::default()
        };
    }
    fn forget_window(&mut self) {
        self.context_revision = None;
        self.live_loaded = false;
        self.replacement = None;
        self.epoch = self.epoch.wrapping_add(1);
        self.offset = 0;
        self.tail_cursor = None;
        self.usage = None;
        self.usage_through = None;
        self.earlier_cursor = None;
        self.has_earlier = false;
        self.loading_earlier = false;
        self.earlier = None;
        self.reached_start = false;
        self.history_trimmed = false;
    }
    fn allocate(&mut self, kind: ReadKind, quiet: bool) -> Option<Read> {
        let owner = self.owner.clone()?;
        let folder = self.folder.clone()?;
        let selected = self.selected.as_ref()?;
        self.next = self.next.wrapping_add(1);
        Some(Read {
            owner,
            folder,
            id: selected.id.clone(),
            offset: if kind == ReadKind::Whole {
                0
            } else {
                self.offset
            },
            cursor: match kind {
                ReadKind::Earlier => self.earlier_cursor.clone(),
                ReadKind::Tail => self.tail_cursor.clone(),
                _ => None,
            },
            kind,
            quiet,
            selection: self.selection,
            epoch: self.epoch,
            ticket: self.next,
            revision: selected.send_revision,
            instance: self.instance,
        })
    }
    pub fn begin_open(&mut self, quiet: bool) -> Option<Read> {
        if self.replacement.is_some() {
            return None;
        }
        let mut read = self.allocate(
            if self.paging_unavailable {
                ReadKind::Whole
            } else {
                ReadKind::Newest
            },
            quiet,
        )?;
        self.epoch = self.epoch.wrapping_add(1);
        read.epoch = self.epoch;
        self.replacement = Some(read.ticket);
        self.opening = true;
        Some(read)
    }
    pub fn begin_tail(&mut self, quiet: bool) -> Option<Read> {
        if !self.live_loaded {
            return self.begin_open(quiet);
        }
        if self.replacement.is_some() {
            return None;
        }
        self.allocate(ReadKind::Tail, quiet)
    }
    pub fn begin_earlier(&mut self, quiet: bool) -> Option<Read> {
        if self.paging_unavailable
            || !self.has_earlier
            || self.earlier.is_some()
            || self.earlier_cursor.is_none()
        {
            return None;
        }
        let read = self.allocate(ReadKind::Earlier, quiet)?;
        self.earlier = Some(read.ticket);
        self.loading_earlier = !quiet;
        Some(read)
    }
    pub fn current(&self, read: &Read) -> bool {
        self.instance == read.instance
            && self.owner.as_ref() == Some(&read.owner)
            && self.selection == read.selection
            && self.epoch == read.epoch
            && self
                .selected
                .as_ref()
                .is_some_and(|c| text::equal(&c.id, &read.id))
            && match read.kind {
                ReadKind::Newest | ReadKind::Whole => self.replacement == Some(read.ticket),
                ReadKind::Tail => self.offset == read.offset && self.tail_cursor == read.cursor,
                ReadKind::Earlier => {
                    self.earlier == Some(read.ticket) && self.earlier_cursor == read.cursor
                }
            }
    }
    fn acknowledge_context(&mut self, read: &Read) {
        if let Some(revision) = read.revision {
            self.context_revision = Some(self.context_revision.unwrap_or_default().max(revision));
        }
    }
    fn release(&mut self, read: &Read) {
        if self.instance != read.instance || self.owner.as_ref() != Some(&read.owner) {
            return;
        }
        if self.replacement == Some(read.ticket) {
            self.replacement = None;
        }
        // The opening defer belongs to the selection, while replacement
        // tickets can be superseded by a trimming earlier-page response.
        if self.selection == read.selection
            && matches!(read.kind, ReadKind::Newest | ReadKind::Whole)
        {
            self.opening = false;
        }
        if self.earlier == Some(read.ticket) {
            self.earlier = None;
            self.loading_earlier = false;
        }
    }
    /// Return an awaited read's cancellation defer without turning it into a
    /// host failure/fallback. Call at its actual completion boundary; another
    /// model/selection/helper cannot clear the current progress through it.
    pub fn cancel_read(&mut self, read: &Read) {
        self.release(read);
    }
    pub fn begin_edit(&self) -> Option<Edit> {
        let selected = self.selected.as_ref()?;
        Some(Edit {
            owner: self.owner.clone()?,
            folder: self.folder.clone()?,
            id: selected.id.clone(),
            selection: self.selection,
            revision: selected.send_revision,
            instance: self.instance,
        })
    }
    pub fn finish_edit(&mut self, edit: &Edit, updated: Conversation) -> bool {
        if self.instance != edit.instance
            || self.selection != edit.selection
            || !self.metadata_matches(&edit.owner, &edit.folder, &edit.id)
            || !text::equal(&edit.id, &updated.id)
        {
            return false;
        }
        self.context_revision = send_context::after_own_edit(
            self.context_revision,
            edit.revision,
            updated.send_revision,
        );
        let updated = super::steer_overlay::Model::preserving_note(updated, self.selected.as_ref());
        self.adopt_metadata(updated);
        true
    }
    fn metadata_matches(&self, owner: &Owner, folder: &str, id: &str) -> bool {
        self.owner.as_ref() == Some(owner)
            && self
                .folder
                .as_deref()
                .is_some_and(|f| text::equal(f, folder))
            && self
                .selected
                .as_ref()
                .is_some_and(|c| text::equal(&c.id, id))
    }
    /// A list/poll can update metadata without proving the displayed context.
    /// The caller supplies its captured directory owner and owning project.
    pub fn update_metadata(&mut self, owner: &Owner, folder: &str, updated: Conversation) -> bool {
        if !self.metadata_matches(owner, folder, &updated.id) {
            return false;
        }
        self.adopt_metadata(updated);
        true
    }
    fn adopt_metadata(&mut self, updated: Conversation) {
        if self.selected.as_ref().is_some_and(|old| {
            !text::equal(&old.backend, &updated.backend) || old.running != updated.running
        }) {
            self.metadata_ticket = None;
        }
        self.selected = Some(updated);
    }
}
