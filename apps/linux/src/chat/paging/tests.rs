// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use serde_json::json;

// These existing page-state fixtures deliberately complete CPU publication
// immediately. Serial executor and suspension races have separate tests.
fn settle(window: &mut Window, mut step: publication::Step) -> Completion {
    loop {
        match step {
            publication::Step::Complete(done) => return done,
            publication::Step::Project(work) => {
                let ticket = work.ticket();
                let projected = work.project();
                step = window.finish_projection(crate::chat::projector::Finished {
                    result: Ok(projected),
                    ticket,
                });
            }
        }
    }
}
impl Window {
    fn finish_page(&mut self, read: &Read, result: Result<EventPage, Failure>) -> Completion {
        let step = self.receive_page(read, result);
        settle(self, step)
    }
    fn finish_chunk(&mut self, read: &Read, result: Result<EventChunk, Failure>) -> Completion {
        let step = self.receive_chunk(read, result);
        settle(self, step)
    }
}

fn owner(account: &str, generation: u64) -> Owner {
    Owner {
        scope: crate::work::Scope::local(account),
        generation,
        local_host_identity: "host".into(),
    }
}
fn chat(id: &str, revision: u64) -> Conversation {
    serde_json::from_value(json!({"id":id,"workspaceId":"folder","title":"Synthetic","backend":"fixture","sendRevision":revision})).unwrap()
}
fn event(seq: u64) -> TimelineEvent {
    serde_json::from_value(json!({"kind":"user","seq":seq,"text":format!("Synthetic {seq}")}))
        .unwrap()
}
fn page(seqs: &[u64], offset: u64, earlier: bool) -> EventPage {
    EventPage {
        events: seqs.iter().copied().map(event).collect(),
        next_offset: offset,
        tail_cursor: Some(format!("opaque:{offset}")),
        cursor: earlier.then(|| "opaque:older".into()),
        has_earlier: earlier,
        usage: Some(UsageTotals {
            input: 123,
            ..UsageTotals::default()
        }),
        ..EventPage::default()
    }
}
fn window() -> Window {
    let mut window = Window::default();
    window.select(owner("account", 1), "folder", Some(chat("first", 3)), false);
    let read = window.begin_open(false).unwrap();
    assert!(
        window
            .finish_page(&read, Ok(page(&[50, 51], 80, true)))
            .accepted
    );
    window
}
fn seqs(window: &Window) -> Vec<u64> {
    window.events().iter().filter_map(|e| e.seq).collect()
}
fn failure(message: &str) -> Failure {
    Failure {
        message: message.into(),
        unknown_method: false,
    }
}

#[test]
fn overlapping_prepend_and_tail_preserve_both_and_never_double_count_whole_archive_usage() {
    for tail_first in [false, true] {
        let mut window = window();
        let older = window.begin_earlier(false).unwrap();
        let tail = window.begin_tail(true).unwrap();
        let complete_tail = |window: &mut Window| {
            let complete = window.finish_chunk(
                &tail,
                Ok(EventChunk {
                    events: vec![event(52)],
                    next_offset: 90,
                    has_more: true,
                    ..EventChunk::default()
                }),
            );
            assert!(complete.accepted && complete.more_tail);
        };
        if tail_first {
            complete_tail(&mut window);
        }
        let complete = window.finish_page(&older, Ok(page(&[10, 20, 50], 80, false)));
        assert!(complete.accepted);
        if !tail_first {
            complete_tail(&mut window);
        }
        assert_eq!(seqs(&window), [10, 20, 50, 51, 52]);
        assert_eq!(window.offset(), 90);
        assert_eq!(window.usage().unwrap().input, 123);
        assert_eq!(window.usage_through(), Some(51));
        assert!(window.reached_start());
        assert!(!window.loading_earlier());
    }
}
#[test]
fn trim_replaces_the_window_and_retires_the_old_tail_without_its_error_or_records() {
    for late_error in [false, true] {
        let mut window = window();
        let older = window.begin_earlier(false).unwrap();
        let tail = window.begin_tail(false).unwrap();
        let mut reset = page(&[100], 120, false);
        reset.reset = true;
        reset.history_trimmed = true;
        assert!(window.finish_page(&older, Ok(reset)).restore_reading);
        assert!(!window.current(&tail));
        assert!(
            !window
                .finish_chunk(
                    &tail,
                    if late_error {
                        Err(failure("retired failure"))
                    } else {
                        Ok(EventChunk {
                            events: vec![event(52)],
                            next_offset: 90,
                            ..EventChunk::default()
                        })
                    }
                )
                .accepted
        );
        assert_eq!(seqs(&window), [100]);
        assert_eq!(window.offset(), 120);
        assert!(window.error().is_none());
        assert!(window.history_trimmed());
    }
}
#[test]
fn selection_account_and_helper_retirement_cannot_publish_old_pages_or_clear_a_successors_spinner()
{
    for retirement in 0..3 {
        for error in [false, true] {
            let mut window = window();
            let first = window.begin_earlier(false).unwrap();
            let (next_owner, next_id) = match retirement {
                0 => (owner("account", 1), "second"),
                1 => (owner("other", 1), "first"),
                _ => (owner("account", 2), "first"),
            };
            assert!(window.select(next_owner, "folder", Some(chat(next_id, 3)), false));
            let next = window.begin_open(false).unwrap();
            assert!(
                !window
                    .finish_page(
                        &first,
                        if error {
                            Err(failure("old failure"))
                        } else {
                            Ok(page(&[1], 10, false))
                        }
                    )
                    .accepted
            );
            assert!(window.opening());
            assert!(window.current(&next));
            assert!(window.events().is_empty());
            assert!(
                window
                    .finish_page(&next, Ok(page(&[80], 100, false)))
                    .accepted
            );
            assert_eq!(seqs(&window), [80]);
            window.retire();
            assert!(window.selected().is_none() && window.events().is_empty());
            assert!(!window.current(&next));
        }
    }
}
#[test]
fn same_selection_keeps_rows_and_duplicate_tails_cannot_erase_the_first_accepted_append() {
    let mut window = window();
    assert!(!window.select(owner("account", 1), "folder", Some(chat("first", 8)), false));
    assert_eq!(seqs(&window), [50, 51]);
    let first = window.begin_tail(false).unwrap();
    let second = window.begin_tail(false).unwrap();
    assert!(
        window
            .finish_chunk(
                &first,
                Ok(EventChunk {
                    events: vec![event(52)],
                    next_offset: 90,
                    ..EventChunk::default()
                })
            )
            .accepted
    );
    assert!(
        !window
            .finish_chunk(
                &second,
                Ok(EventChunk {
                    events: vec![event(53)],
                    next_offset: 91,
                    ..EventChunk::default()
                })
            )
            .accepted
    );
    assert_eq!(seqs(&window), [50, 51, 52]);
    assert_eq!(window.offset(), 90);
}
#[test]
fn unread_is_never_empty_and_page_fallback_is_bounded_without_a_recursive_reset_loop() {
    let mut window = Window::default();
    window.select(owner("account", 1), "folder", Some(chat("first", 3)), false);
    assert!(window.opening() && !window.live_loaded());
    let opening = window.begin_tail(false).unwrap();
    assert_eq!(opening.kind, ReadKind::Newest);
    assert!(window.begin_tail(false).is_none());
    let complete = window.finish_page(
        &opening,
        Err(Failure {
            message: "unknown chat.eventPage".into(),
            unknown_method: true,
        }),
    );
    let fallback = complete.reopen.unwrap();
    assert_eq!(fallback.kind, ReadKind::Whole);
    assert_eq!(
        fallback.parameters(),
        json!({"id":"first","offset":0,"stablePositions":true})
    );
    assert!(window.paging_unavailable());
    assert!(window.opening());
    let reset = window.finish_chunk(
        &fallback,
        Ok(EventChunk {
            reset: true,
            ..EventChunk::default()
        }),
    );
    assert!(reset.reopen.is_none());
    assert!(!window.live_loaded());
    assert!(!window.opening());
    let retry = window.begin_tail(false).unwrap();
    assert_eq!(retry.kind, ReadKind::Whole);
    assert!(
        window
            .finish_chunk(&retry, Ok(EventChunk::default()))
            .accepted
    );
    assert!(window.live_loaded());
    assert!(!window.reached_start());
}
#[test]
fn metadata_and_earlier_pages_cannot_grant_a_new_context_but_the_next_tail_acknowledges_its_capture()
 {
    let mut window = window();
    assert_eq!(window.context_revision(), Some(3));
    window.update_metadata(&owner("account", 1), "folder", chat("first", 8));
    let earlier = window.begin_earlier(false).unwrap();
    let mut reset = page(&[100], 120, false);
    reset.reset = true;
    window.finish_page(&earlier, Ok(reset));
    assert_eq!(window.context_revision(), Some(3));
    let tail = window.begin_tail(true).unwrap();
    window.update_metadata(&owner("account", 1), "folder", chat("first", 12));
    window.finish_chunk(
        &tail,
        Ok(EventChunk {
            next_offset: 120,
            ..EventChunk::default()
        }),
    );
    assert_eq!(window.context_revision(), Some(8));
    assert_eq!(window.selected().unwrap().send_revision, Some(12));
    let edit = window.begin_edit().unwrap();
    window.finish_edit(&edit, chat("first", 13));
    assert_eq!(window.context_revision(), Some(8));
    assert!(!window.finish_edit(&edit, chat("other", 14)));
}
#[test]
fn background_failures_are_quiet_and_failed_prepend_does_not_replace_verified_content() {
    for quiet in [false, true] {
        let mut window = window();
        let earlier = window.begin_earlier(quiet).unwrap();
        assert_eq!(window.loading_earlier(), !quiet);
        window.finish_page(&earlier, Err(failure("older failure")));
        assert_eq!(seqs(&window), [50, 51]);
        assert!(window.error().is_none());
        assert!(!window.loading_earlier());
        let tail = window.begin_tail(quiet).unwrap();
        window.finish_chunk(&tail, Err(failure("tail failure")));
        assert_eq!(
            window.error(),
            if quiet { None } else { Some("tail failure") }
        );
        let retry = window.begin_tail(quiet).unwrap();
        window.finish_chunk(
            &retry,
            Ok(EventChunk {
                next_offset: 80,
                ..EventChunk::default()
            }),
        );
        assert_eq!(seqs(&window), [50, 51]);
        assert_eq!(
            window.error(),
            if quiet { None } else { Some("tail failure") }
        );
    }
}

#[test]
fn paging_capability_follows_canonical_peer_identity_while_helper_and_project_changes_retire_reads()
{
    let mut window = Window::default();
    window.select(
        owner("account", 1),
        "remote:café:a",
        Some(chat("first", 3)),
        false,
    );
    let read = window.begin_open(false).unwrap();
    let fallback = window
        .finish_page(
            &read,
            Err(Failure {
                message: "unsupported".into(),
                unknown_method: true,
            }),
        )
        .reopen
        .unwrap();
    window.finish_chunk(&fallback, Ok(EventChunk::default()));
    assert!(window.paging_unavailable());
    window.select(
        owner("account", 2),
        "remote:cafe\u{301}:b",
        Some(chat("second", 3)),
        false,
    );
    assert!(window.paging_unavailable());
    assert_eq!(window.begin_open(false).unwrap().kind, ReadKind::Whole);
    window.select(
        owner("account", 2),
        "remote:other:b",
        Some(chat("third", 3)),
        false,
    );
    assert!(!window.paging_unavailable());
    assert_eq!(window.begin_open(false).unwrap().kind, ReadKind::Newest);
}

#[test]
fn own_edits_capture_their_original_revision_and_cannot_cross_a_selection_or_owner_change() {
    let mut window = window();
    let edit = window.begin_edit().unwrap();
    let mut refreshed = chat("first", 8);
    refreshed.pending_steer = Some("A newer pending note".into());
    assert!(window.update_metadata(&owner("account", 1), "folder", refreshed));
    assert!(window.finish_edit(&edit, chat("first", 4)));
    assert_eq!(window.context_revision(), Some(4));
    assert_eq!(
        window.selected().unwrap().pending_steer.as_deref(),
        Some("A newer pending note")
    );
    assert!(!window.update_metadata(&owner("other", 1), "folder", chat("first", 9)));
    assert!(!window.update_metadata(&owner("account", 1), "other-folder", chat("first", 9)));
    let edit = window.begin_edit().unwrap();
    window.select(
        owner("account", 1),
        "folder",
        Some(chat("second", 3)),
        false,
    );
    window.select(owner("account", 1), "folder", Some(chat("first", 3)), true);
    assert!(!window.finish_edit(&edit, chat("first", 5)));
    assert_eq!(window.context_revision(), Some(3));
    let edit = window.begin_edit().unwrap();
    window.select(owner("other", 1), "folder", Some(chat("first", 8)), true);
    assert!(!window.finish_edit(&edit, chat("first", 9)));
    assert_eq!(window.context_revision(), Some(8));
}
