// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::super::tests::{Fixture, new, principal};
use super::*;

fn setup(f: &Fixture) -> PreparedAsk {
    let actor = principal("fixture_member", 'a', 'c');
    let prepared = new(f
        .prepare(&actor, &f.input(&actor, "output-attempt"))
        .unwrap());
    f.store
        .transition_owned_run(f.target(), &prepared, runs::State::Launching)
        .unwrap();
    f.store
        .transition_owned_run(f.target(), &prepared, runs::State::Running)
        .unwrap();
    prepared
}
fn words() -> Vec<Event> {
    vec![
        Event::Session {
            id: "PRIVATE_FIXTURE_VENDOR_SESSION".into(),
        },
        Event::Text {
            delta: "Reply with ".into(),
        },
        Event::Text {
            delta: "numbers".into(),
        },
    ]
}

#[test]
fn canonical_output_has_original_initiator_and_is_idempotent() {
    let f = Fixture::new();
    let prepared = setup(&f);
    f.store
        .append_owned_output(f.target(), &prepared, 0, words(), || Ok(()))
        .unwrap();
    let history = f.history();
    let reply = history.events.last().unwrap();
    assert_eq!(reply["event"]["delta"], "Reply with numbers");
    assert_eq!(reply["author"]["kind"], "agent");
    assert_eq!(reply["author"]["initiatedBy"]["id"], "fixture_member");
    let public = serde_json::to_string(&history.events).unwrap();
    assert!(!public.contains("PRIVATE_FIXTURE"));
    assert!(!public.contains("teamAgent"));
    assert!(!public.contains(prepared.binding.fence.incarnation()));
    let before = fs::read(f.store.root.join(&f.chat.id).join("events.ndjson")).unwrap();
    f.store
        .append_owned_output(f.target(), &prepared, 0, words(), || Ok(()))
        .unwrap();
    assert_eq!(
        fs::read(f.store.root.join(&f.chat.id).join("events.ndjson")).unwrap(),
        before
    );
    assert!(
        f.store
            .append_owned_output(
                f.target(),
                &prepared,
                0,
                vec![Event::Text {
                    delta: "Changed reply".into()
                }],
                || Ok(())
            )
            .is_err()
    );
    let journal = String::from_utf8(f.journal_bytes()).unwrap();
    assert!(!journal.contains("Reply with numbers"));
}

#[test]
fn a_reader_settles_only_an_exact_written_batch_after_interruption() {
    let f = Fixture::new();
    let prepared = setup(&f);
    let result = f.store.append_owned_output_at(
        f.target(),
        &prepared,
        0,
        words(),
        || Ok(()),
        |step| {
            if matches!(step, Step::Canonical) {
                Err(unavailable())
            } else {
                Ok(())
            }
        },
    );
    assert!(result.is_err());
    let journal = String::from_utf8(f.journal_bytes()).unwrap();
    assert!(!journal.contains("Reply with numbers"));
    let payload = output_file(&f, false);
    assert!(
        String::from_utf8(fs::read(&payload).unwrap())
            .unwrap()
            .contains("Reply with numbers")
    );
    assert_eq!(
        f.history().events.last().unwrap()["event"]["delta"],
        "Reply with numbers"
    );
    assert!(
        !String::from_utf8(f.journal_bytes())
            .unwrap()
            .contains("Reply with numbers")
    );
    f.store
        .append_owned_output(f.target(), &prepared, 0, words(), || Ok(()))
        .unwrap();
}

#[test]
fn unwritten_output_is_never_replayed_by_a_reader_or_another_writer() {
    let f = Fixture::new();
    let prepared = setup(&f);
    assert!(
        f.store
            .append_owned_output_at(
                f.target(),
                &prepared,
                0,
                words(),
                || Ok(()),
                |step| {
                    if matches!(step, Step::Reserved) {
                        Err(unavailable())
                    } else {
                        Ok(())
                    }
                }
            )
            .is_err()
    );
    assert!(
        !serde_json::to_string(&f.history().events)
            .unwrap()
            .contains("Reply with numbers")
    );
    assert!(
        f.store
            .append_owned_output(f.target(), &prepared, 0, words(), || Ok(()))
            .is_err()
    );
}

#[test]
fn tampered_or_deleted_output_pauses_sharing() {
    for change in 0..3 {
        let f = Fixture::new();
        let prepared = setup(&f);
        f.store
            .append_owned_output(f.target(), &prepared, 0, words(), || Ok(()))
            .unwrap();
        let path = output_file(&f, change == 1);
        let bytes = fs::read(&path).unwrap();
        let changed = if change == 1 {
            bytes
                .split_inclusive(|byte| *byte == b'\n')
                .filter(|line| !line.windows(16).any(|w| w == b"teamAgentSegment"))
                .flatten()
                .copied()
                .collect::<Vec<_>>()
        } else if change == 0 {
            let mut bytes = bytes;
            let marker = b"Reply with numbers";
            let start = bytes
                .windows(marker.len())
                .position(|w| w == marker)
                .unwrap();
            bytes[start] = b'F';
            bytes
        } else {
            String::from_utf8(bytes)
                .unwrap()
                .replace(
                    "\"delta\":\"Reply with numbers\"",
                    "\"delta\":\"Reply with numbers\",\"unproven\":true",
                )
                .into_bytes()
        };
        fs::write(path, changed).unwrap();
        assert!(
            f.store
                .shared_history(
                    &f.chat.workspace_id,
                    &f.chat.id,
                    &format!("share_{}", "a".repeat(32)),
                    &f.preview
                )
                .is_err()
        );
    }
}

#[test]
fn expired_authority_cannot_append_and_large_unicode_is_split_safely() {
    let f = Fixture::new();
    let prepared = setup(&f);
    assert!(
        f.store
            .append_owned_output(f.target(), &prepared, 0, words(), || Err(unavailable()))
            .is_err()
    );
    let text = "👩🏽‍💻".repeat(3000);
    f.store
        .append_owned_output(
            f.target(),
            &prepared,
            0,
            vec![
                Event::Text {
                    delta: text.clone(),
                },
                Event::Attachment {
                    id: "private-ref".into(),
                    name: "private".into(),
                    media_type: None,
                    size: 1,
                    call_id: None,
                },
            ],
            || Ok(()),
        )
        .unwrap();
    let combined = f
        .history()
        .events
        .iter()
        .filter_map(|row| row["event"]["delta"].as_str())
        .collect::<String>();
    assert_eq!(combined, text);
    assert!(
        !serde_json::to_string(&f.history().events)
            .unwrap()
            .contains("private-ref")
    );
}

fn output_file(f: &Fixture, chain: bool) -> std::path::PathBuf {
    let root = f.store.root.join(&f.chat.id).join("team-output");
    if chain {
        return root.join("chain.ndjson");
    }
    fs::read_dir(&root)
        .unwrap()
        .find_map(|entry| {
            let entry = entry.unwrap();
            (entry.file_name() != "chain.ndjson").then(|| entry.path())
        })
        .unwrap()
}

#[test]
fn a_page_reads_only_the_payloads_it_shows() {
    let f = Fixture::new();
    let prepared = setup(&f);
    for (batch, text) in ["segment-alpha", "segment-beta", "segment-gamma"]
        .into_iter()
        .enumerate()
    {
        f.store
            .append_owned_output(
                f.target(),
                &prepared,
                batch as u32,
                vec![Event::Text { delta: text.into() }],
                || Ok(()),
            )
            .unwrap();
    }
    let transcript = fs::read(f.store.root.join(&f.chat.id).join("events.ndjson")).unwrap();
    assert!(
        !transcript
            .windows(b"segment-alpha".len())
            .any(|window| window == b"segment-alpha")
    );
    let share = format!("share_{}", "a".repeat(32));
    let newest = f
        .store
        .shared_event_page(
            &f.chat.workspace_id,
            &f.chat.id,
            &share,
            &f.preview,
            &crate::chat::sharing::PageRequest {
                after: None,
                older: true,
                limit: 1,
                budget: 512 * 1024,
            },
        )
        .unwrap();
    assert!(newest.has_more);
    assert_eq!(newest.events[0]["event"]["delta"], "segment-gamma");
    let chain = fs::read_to_string(output_file(&f, true)).unwrap();
    let first: serde_json::Value = serde_json::from_str(chain.lines().next().unwrap()).unwrap();
    let path = f
        .store
        .root
        .join(&f.chat.id)
        .join("team-output")
        .join(first["digest"].as_str().unwrap());
    let mut bytes = fs::read(&path).unwrap();
    bytes[0] ^= 0xff;
    fs::write(&path, bytes).unwrap();
    assert_eq!(
        f.store
            .shared_event_page(
                &f.chat.workspace_id,
                &f.chat.id,
                &share,
                &f.preview,
                &crate::chat::sharing::PageRequest {
                    after: None,
                    older: true,
                    limit: 1,
                    budget: 512 * 1024,
                },
            )
            .unwrap()
            .events[0]["event"]["delta"],
        "segment-gamma"
    );
    assert!(
        f.store
            .shared_event_page(
                &f.chat.workspace_id,
                &f.chat.id,
                &share,
                &f.preview,
                &crate::chat::sharing::PageRequest {
                    after: None,
                    older: true,
                    limit: 100,
                    budget: 512 * 1024,
                },
            )
            .is_err()
    );
}

#[test]
fn metadata_and_approved_files_remain_bounded_above_the_full_history_limit() {
    let f = Fixture::with_source(&[serde_json::json!({
        "kind":"agent","backend":"codex","at_ms":1,
        "event":{"kind":"attachment","id":"file_fixture","name":"Report.txt","mediaType":"text/plain","size":23}
    })]);
    let prepared = setup(&f);
    let share = format!("share_{}", "a".repeat(32));
    let mut large = false;
    let mut expected_text_bytes = 0;
    for batch in 0..128 {
        let mut events = vec![Event::Text {
            delta: "x".repeat(384 * 1024),
        }];
        if batch == 0 {
            // New agent output cannot make another attachment reachable.
            events.push(Event::Attachment {
                id: "not_approved".into(),
                name: "Private.txt".into(),
                media_type: Some("text/plain".into()),
                size: 99,
                call_id: None,
            });
        }
        f.store
            .append_owned_output(f.target(), &prepared, batch, events, || Ok(()))
            .unwrap();
        expected_text_bytes += 384 * 1024;
        let chain = fs::read_to_string(output_file(&f, true)).unwrap();
        let bytes: u64 = chain
            .lines()
            .map(|line| {
                serde_json::from_str::<serde_json::Value>(line).unwrap()["bytes"]
                    .as_u64()
                    .unwrap()
            })
            .sum();
        if bytes > 32 * 1024 * 1024 {
            large = true;
            break;
        }
    }
    assert!(
        large,
        "The fixture must exceed the full-history expansion bound."
    );
    assert_eq!(
        f.store
            .shared_history(&f.chat.workspace_id, &f.chat.id, &share, &f.preview)
            .err()
            .unwrap()
            .code,
        "team_history_limit"
    );
    let index = f
        .store
        .shared_chat_index(&f.chat.workspace_id, &f.chat.id, &share, &f.preview)
        .unwrap();
    assert_eq!(index.title, "Shared review");
    assert_eq!(index.backend, "codex");
    assert!(!index.history_trimmed);
    assert_eq!(index.binding.id, share);
    assert_eq!(
        index.files,
        std::collections::HashMap::from([("file_fixture".into(), 23)])
    );
    assert!(
        f.store
            .shared_chat_index(&f.chat.workspace_id, &f.chat.id, &share, &"00".repeat(32))
            .is_err()
    );

    // No process exists in this storage fixture. Settle its recorded orphan,
    // then admit a fresh Ask against the genuinely large authenticated archive.
    let fence = prepared.binding().fence.clone();
    drop(prepared);
    f.store
        .recover_orphaned_run(&f.chat.workspace_id, &f.chat.id, &fence, true, || Ok(()))
        .unwrap();
    let actor = principal("fixture_member", 'a', 'c');
    let input = f.input(&actor, "large-context-attempt");
    let approved = new(f.prepare(&actor, &input).unwrap());
    let context = approved.context().sdk();
    assert!(context.byte_bound().unwrap() > 32 * 1024 * 1024);
    assert!(context.full_if_small(4 * 1024 * 1024).unwrap().is_none());
    f.store
        .team_comment(
            f.target(),
            &actor,
            &CommentInput {
                text: "FROZEN_CONTEXT_LATE_SENTINEL".into(),
                client_message_id: "later-large-comment".into(),
                client_message_created_at_ms: now_ms(),
            },
            || Ok(()),
        )
        .unwrap();
    f.store
        .ensure_prepared_ask(f.target(), &approved, || Ok(()))
        .unwrap();
    f.store
        .transition_owned_run(f.target(), &approved, runs::State::Launching)
        .unwrap();
    f.store
        .transition_owned_run(f.target(), &approved, runs::State::Running)
        .unwrap();
    f.store
        .append_owned_output(
            f.target(),
            &approved,
            0,
            vec![Event::Text {
                delta: "FROZEN_CONTEXT_LATE_SENTINEL".into(),
            }],
            || Ok(()),
        )
        .unwrap();
    let mut after = None;
    let mut count = 0;
    let mut text_bytes = 0;
    loop {
        let (events, more) = context.page(after, 100, 256 * 1024).unwrap();
        assert!(!events.is_empty());
        for event in &events {
            let seq = event["seq"].as_u64().unwrap();
            assert!(after.is_none_or(|previous| seq > previous));
            after = Some(seq);
            count += 1;
            text_bytes += event["event"]["delta"].as_str().map_or(0, str::len);
            assert!(!event.to_string().contains("FROZEN_CONTEXT_LATE_SENTINEL"));
        }
        if !more {
            break;
        }
    }
    assert_eq!(count, context.count().unwrap());
    assert_eq!(text_bytes, expected_text_bytes);
    assert_eq!(context.metadata["message"]["text"], input.text);
    // Metadata/file discovery validates the sealed chain, without opening an
    // unrelated archived payload. Reading that payload still verifies bytes.
    let chain = fs::read_to_string(output_file(&f, true)).unwrap();
    let first: serde_json::Value = serde_json::from_str(chain.lines().next().unwrap()).unwrap();
    let path = f
        .store
        .root
        .join(&f.chat.id)
        .join("team-output")
        .join(first["digest"].as_str().unwrap());
    let mut bytes = fs::read(&path).unwrap();
    bytes[0] ^= 0xff;
    fs::write(&path, bytes).unwrap();
    assert!(context.page(None, 100, 256 * 1024).is_err());
    let index = f
        .store
        .shared_chat_index(&f.chat.workspace_id, &f.chat.id, &share, &f.preview)
        .unwrap();
    assert_eq!(index.files.get("file_fixture"), Some(&23));
    assert!(!index.files.contains_key("not_approved"));
    assert!(
        f.store
            .shared_event_page(
                &f.chat.workspace_id,
                &f.chat.id,
                &share,
                &f.preview,
                &crate::chat::sharing::PageRequest {
                    after: None,
                    older: false,
                    limit: 100,
                    budget: 512 * 1024
                }
            )
            .is_err()
    );
    // Avoiding old payload reads must not skip authentication of the chain
    // that declares which payloads belong to this shared conversation.
    let digest = first["digest"].as_str().unwrap();
    let replacement = format!(
        "{}{}",
        if digest.starts_with('0') { '1' } else { '0' },
        &digest[1..]
    );
    fs::write(
        output_file(&f, true),
        chain.replacen(digest, &replacement, 1),
    )
    .unwrap();
    assert!(
        f.store
            .shared_chat_index(&f.chat.workspace_id, &f.chat.id, &share, &f.preview)
            .is_err()
    );
}
