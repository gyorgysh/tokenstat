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
