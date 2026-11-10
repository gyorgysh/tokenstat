// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Snapshot, project on one worker, then validate/rebase and publish both raw
//! events and rows. No intermediate raw window can be observed by a renderer.

use super::*;
use crate::chat::{
    projector::Finished,
    transcript::{self, Row},
};
#[cfg(test)]
mod tests;

pub enum Step {
    Complete(Completion),
    Project(Work),
}
#[derive(Clone)]
enum Commit {
    Page(Read, Arc<EventPage>, Option<u64>),
    Chunk(Read, Arc<EventChunk>),
    Metadata(u64),
}
#[derive(Clone)]
pub struct Ticket {
    instance: u64,
    owner: Owner,
    id: String,
    selection: u64,
    epoch: u64,
    commit: Commit,
}
pub struct Work {
    ticket: Arc<Ticket>,
    initial_revision: u64,
    revision: u64,
    backend: Option<String>,
    running: bool,
    held: Arc<Vec<TimelineEvent>>,
    rebases: bool,
}
pub struct Projected {
    work: Work,
    events: Arc<Vec<TimelineEvent>>,
    rows: Arc<Vec<Row>>,
}
#[derive(Clone)]
pub(super) struct DisplayKey {
    revision: u64,
    count: usize,
    first: Option<u64>,
    last: Option<u64>,
    backend: Option<String>,
    running: bool,
}
fn optional_equal(a: Option<&str>, b: Option<&str>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a == b || text::equal(a, b),
        (None, None) => true,
        _ => false,
    }
}
impl PartialEq for DisplayKey {
    fn eq(&self, b: &Self) -> bool {
        self.revision == b.revision
            && self.count == b.count
            && self.first == b.first
            && self.last == b.last
            && self.running == b.running
            && optional_equal(self.backend.as_deref(), b.backend.as_deref())
    }
}
impl Work {
    pub fn ticket(&self) -> Ticket {
        self.ticket.as_ref().clone()
    }
    pub(crate) fn project(self) -> Projected {
        let events = match &self.ticket.commit {
            Commit::Page(read, page, _) if read.kind == ReadKind::Newest || page.reset => {
                page.events.clone()
            }
            Commit::Page(_, page, _) => {
                let oldest = self.held.first().and_then(|e| e.seq).unwrap_or(u64::MAX);
                page.events
                    .iter()
                    .filter(|e| e.seq.unwrap_or_default() < oldest)
                    .chain(self.held.iter())
                    .cloned()
                    .collect()
            }
            Commit::Chunk(read, chunk) if read.kind == ReadKind::Whole => chunk.events.clone(),
            Commit::Chunk(_, chunk) => self.held.iter().chain(&chunk.events).cloned().collect(),
            Commit::Metadata(_) => {
                return Projected {
                    events: self.held.clone(),
                    rows: Arc::new(transcript::coalesce(
                        &self.held,
                        self.backend.as_deref(),
                        self.running,
                    )),
                    work: self,
                };
            }
        };
        let rows = Arc::new(transcript::coalesce(
            &events,
            self.backend.as_deref(),
            self.running,
        ));
        Projected {
            work: self,
            events: Arc::new(events),
            rows,
        }
    }
}
impl Window {
    fn make_work(&self, commit: Commit, rebases: bool) -> Step {
        let Some(selected) = &self.selected else {
            return Step::Complete(Completion::default());
        };
        Step::Project(Work {
            ticket: Arc::new(Ticket {
                instance: self.instance,
                owner: self.owner.clone().expect("selected owner"),
                id: selected.id.clone(),
                selection: self.selection,
                epoch: self.epoch,
                commit,
            }),
            initial_revision: self.events_revision,
            revision: self.events_revision,
            backend: Some(selected.backend.clone()),
            running: selected.running,
            held: self.events.clone(),
            rebases,
        })
    }
    fn ticket_current(&self, ticket: &Ticket) -> bool {
        self.instance == ticket.instance
            && self.owner.as_ref() == Some(&ticket.owner)
            && self.selection == ticket.selection
            && (matches!(ticket.commit, Commit::Metadata(_)) || self.epoch == ticket.epoch)
            && self
                .selected
                .as_ref()
                .is_some_and(|c| text::equal(&c.id, &ticket.id))
            && match &ticket.commit {
                Commit::Metadata(id) => self.metadata_ticket == Some(*id),
                Commit::Page(read, page, Some(replacement)) if page.reset => {
                    self.replacement == Some(*replacement) && self.earlier == Some(read.ticket)
                }
                Commit::Page(read, _, _) | Commit::Chunk(read, _) => self.current(read),
            }
    }
    fn release_ticket(&mut self, ticket: &Ticket) {
        if self.instance != ticket.instance
            || self.owner.as_ref() != Some(&ticket.owner)
            || self.selection != ticket.selection
        {
            return;
        }
        match &ticket.commit {
            Commit::Metadata(id) => {
                if self.metadata_ticket == Some(*id) {
                    self.metadata_ticket = None;
                }
            }
            Commit::Page(read, _, replacement) => {
                self.release(read);
                if self.replacement == *replacement {
                    self.replacement = None;
                }
            }
            Commit::Chunk(read, _) => self.release(read),
        }
    }
    /// A dropped/failed worker cannot change records or rows; defer-owned
    /// progress flags are released only if this is still their exact owner.
    pub fn cancel_projection(&mut self, ticket: Ticket) {
        self.release_ticket(&ticket);
    }
    pub fn prepare_metadata(&mut self) -> Option<Work> {
        if self.events.is_empty() {
            return None;
        }
        self.prepare_metadata_task()
    }
    /// The selected observer has already checked for events before enqueueing
    /// its task. The task snapshots at actual execution, even if a page has
    /// since made that same selection empty.
    pub(crate) fn prepare_metadata_task(&mut self) -> Option<Work> {
        self.selected.as_ref()?;
        self.next = self.next.wrapping_add(1);
        self.metadata_ticket = Some(self.next);
        match self.make_work(Commit::Metadata(self.next), true) {
            Step::Project(work) => Some(work),
            Step::Complete(_) => None,
        }
    }
    /// Caller returns the exact result from the retained serial Lane. Metadata
    /// or a rebasable window change asks that same lane for a fresh projection.
    pub fn finish_projection(&mut self, finished: Finished) -> Step {
        let Ok(mut projected) = finished.result else {
            self.release_ticket(&finished.ticket);
            return Step::Complete(Completion::default());
        };
        if !self.ticket_current(&projected.work.ticket)
            || !projected.work.rebases && self.events_revision != projected.work.initial_revision
        {
            self.release_ticket(&projected.work.ticket);
            return Step::Complete(Completion::default());
        }
        let backend = self.selected.as_ref().map(|c| c.backend.as_str());
        let running = self.selected.as_ref().is_some_and(|c| c.running);
        if self.events_revision != projected.work.revision
            || !optional_equal(backend, projected.work.backend.as_deref())
            || running != projected.work.running
        {
            projected.work.revision = self.events_revision;
            projected.work.backend = backend.map(str::to_owned);
            projected.work.running = running;
            projected.work.held = self.events.clone();
            return Step::Project(projected.work);
        }
        let changed = !matches!(projected.work.ticket.commit, Commit::Metadata(_));
        if changed {
            self.events = projected.events;
            self.events_revision = self.events_revision.wrapping_add(1);
            if self.events.is_empty() {
                self.rows = Arc::default();
                self.display_key = None;
            }
        }
        let key = DisplayKey {
            revision: self.events_revision,
            count: self.events.len(),
            first: self.events.first().and_then(|e| e.seq),
            last: self.events.last().and_then(|e| e.seq),
            backend: backend.map(str::to_owned),
            running,
        };
        if self.display_key.as_ref() != Some(&key) {
            self.display_revision = self.display_revision.wrapping_add(1);
        }
        self.display_key = Some(key);
        if self.rows.as_ref() != projected.rows.as_ref() {
            self.rows = projected.rows;
        }
        let ticket = projected.work.ticket;
        let mut completion = Completion {
            accepted: true,
            records_changed: changed,
            ..Completion::default()
        };
        match &ticket.commit {
            Commit::Page(read, page, _) => {
                let earlier = read.kind == ReadKind::Earlier;
                if !earlier || page.reset {
                    self.offset = page.next_offset;
                    self.tail_cursor = page.tail_cursor.clone();
                    self.usage = page.usage.clone();
                    self.usage_through = page.events.iter().filter_map(|e| e.seq).max();
                }
                self.earlier_cursor = page.cursor.clone();
                self.has_earlier = page.has_earlier;
                self.history_trimmed = if !earlier || page.reset {
                    page.history_trimmed
                } else {
                    self.history_trimmed || page.history_trimmed
                };
                if !earlier || page.reset {
                    self.reached_start = !self.has_earlier && !page.events.is_empty();
                } else if !self.has_earlier {
                    self.reached_start = true;
                }
                if !earlier {
                    self.live_loaded = true;
                }
                completion.restore_reading = earlier && page.reset;
            }
            Commit::Chunk(read, chunk) => {
                if read.kind == ReadKind::Whole {
                    self.live_loaded = true;
                    self.earlier_cursor = None;
                    self.has_earlier = false;
                    self.reached_start = !chunk.events.is_empty();
                }
                self.offset = chunk.next_offset;
                self.tail_cursor = chunk.tail_cursor.clone();
                completion.more_tail = chunk.has_more && chunk.next_offset > read.offset;
            }
            Commit::Metadata(_) => {}
        }
        self.release_ticket(&ticket);
        Step::Complete(completion)
    }
    pub fn receive_page(&mut self, read: &Read, result: Result<EventPage, Failure>) -> Step {
        self.receive_shared_page(read, result.map(Arc::new))
    }
    pub fn receive_shared_page(
        &mut self,
        read: &Read,
        result: Result<Arc<EventPage>, Failure>,
    ) -> Step {
        if !matches!(read.kind, ReadKind::Newest | ReadKind::Earlier) || !self.current(read) {
            if read.selection == self.selection {
                self.release(read);
            }
            return Step::Complete(Completion::default());
        }
        let page = match result {
            Ok(page) => page,
            Err(error) => {
                if error.unknown_method {
                    self.paging_unavailable = true;
                }
                self.release(read);
                let reopen = if read.kind == ReadKind::Newest {
                    self.epoch = self.epoch.wrapping_add(1);
                    let mut next = self
                        .allocate(ReadKind::Whole, read.quiet)
                        .expect("current selection");
                    next.epoch = self.epoch;
                    self.replacement = Some(next.ticket);
                    self.opening = true;
                    Some(next)
                } else {
                    None
                };
                return Step::Complete(Completion {
                    reopen,
                    ..Completion::default()
                });
            }
        };
        let replacement = if read.kind == ReadKind::Earlier && page.reset {
            self.next = self.next.wrapping_add(1);
            self.replacement = Some(self.next);
            self.epoch = self.epoch.wrapping_add(1);
            Some(self.next)
        } else {
            None
        };
        if read.kind == ReadKind::Newest {
            self.acknowledge_context(read);
        }
        let rebases = read.kind == ReadKind::Earlier && !page.reset;
        self.make_work(Commit::Page(read.clone(), page, replacement), rebases)
    }
    pub fn receive_chunk(&mut self, read: &Read, result: Result<EventChunk, Failure>) -> Step {
        self.receive_shared_chunk(read, result.map(Arc::new))
    }
    pub fn receive_shared_chunk(
        &mut self,
        read: &Read,
        result: Result<Arc<EventChunk>, Failure>,
    ) -> Step {
        if !matches!(read.kind, ReadKind::Whole | ReadKind::Tail) || !self.current(read) {
            if read.selection == self.selection {
                self.release(read);
            }
            return Step::Complete(Completion::default());
        }
        let chunk = match result {
            Ok(chunk) => chunk,
            Err(error) => {
                if !read.quiet {
                    self.error = Some(error.message);
                }
                self.release(read);
                return Step::Complete(Completion::default());
            }
        };
        if chunk.reset {
            self.release(read);
            return Step::Complete(if read.kind == ReadKind::Whole {
                Completion::default()
            } else {
                Completion {
                    reopen: self.begin_open(read.quiet),
                    restore_reading: true,
                    ..Completion::default()
                }
            });
        }
        self.acknowledge_context(read);
        if read.kind == ReadKind::Tail
            && chunk.events.is_empty()
            && chunk.next_offset == self.offset
        {
            self.tail_cursor = chunk.tail_cursor.clone();
            return Step::Complete(Completion {
                accepted: true,
                ..Completion::default()
            });
        }
        self.make_work(
            Commit::Chunk(read.clone(), chunk),
            read.kind == ReadKind::Tail,
        )
    }
}
