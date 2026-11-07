// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::transcript::{Event, Parser};

#[cfg(unix)]
#[test]
fn a_wrapper_downgrade_cannot_keep_a_stale_native_capability() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let wrapper = root.path().join("opencode");
    let version = root.path().join("version");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\ncat {}\n",
            crate::chat_gate::shell_quote(&version.display().to_string())
        ),
    )
    .unwrap();
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700)).unwrap();
    for (value, expected) in [
        ("opencode v2.0.32", true),
        ("opencode v2.0.1", false),
        ("1.19.3", false),
        ("2.1.4", true),
        ("3.0.0", false),
    ] {
        std::fs::write(&version, value).unwrap();
        assert_eq!(
            supports_version(wrapper.to_str().unwrap()),
            expected,
            "{value}"
        );
    }
}

fn feed(parser: &mut Parser, records: Vec<Value>) -> Vec<Event> {
    records
        .into_iter()
        .flat_map(|record| parser.push_events(format!("{record}\n").as_bytes()))
        .collect()
}

fn prose(events: &[Event], thinking: bool) -> String {
    events
        .iter()
        .filter_map(|event| match event {
            Event::Text { delta } if !thinking => Some(delta.as_str()),
            Event::Thinking { delta } if thinking => Some(delta.as_str()),
            _ => None,
        })
        .collect()
}

#[test]
fn captured_free_model_stream_keeps_text_reasoning_tools_and_final_usage_once() {
    let mut projection = Projection::default();
    let mut parser = Parser::new("opencode2");
    let mut events = Vec::new();
    for row in include_str!("../../../../../fixtures/chat/opencode2-stream.ndjson").lines() {
        let row: Value = serde_json::from_str(row).unwrap();
        let records = if row["source"] == "cli" {
            projection.cli(row["value"].clone())
        } else {
            projection.native(row["value"].clone())
        };
        events.extend(feed(&mut parser, records));
    }
    events.extend(parser.finish_events());
    assert_eq!(
        prose(&events, false),
        "The file sample.txt contains a single line. That line holds the word \"café\" followed by a globe emoji. It is otherwise empty, with no further text."
    );
    assert!(prose(&events, true).ends_with("Working dir."));
    assert_eq!(
        events
            .iter()
            .filter(|e| matches!(e, Event::Text { .. }))
            .count(),
        3
    );
    assert_eq!(
        events
            .iter()
            .filter(|e| matches!(e, Event::Thinking { .. }))
            .count(),
        9
    );
    let usage: Vec<_> = events
        .iter()
        .filter_map(|e| match e {
            Event::Usage {
                input,
                output,
                cost_usd,
                ..
            } => Some((*input, *output, *cost_usd)),
            _ => None,
        })
        .collect();
    assert_eq!(usage, [(7863, 115, Some(0.0)), (8005, 38, Some(0.0))]);
    assert_eq!(parser.take_inspection().unwrap().context_used, Some(8005));
    assert_eq!(
        events
            .iter()
            .filter(|e| matches!(e, Event::ToolEnd { ok: true, .. }))
            .count(),
        1
    );
    assert_eq!(
        events
            .iter()
            .filter(|e| matches!(e, Event::ToolStart { .. }))
            .count(),
        1
    );
}

fn native(kind: &str, text: &str) -> Value {
    json!({"type":format!("session.text.{kind}"),"id":"evt_part", "data":{"sessionID":"ses_main","assistantMessageID":"msg_text","ordinal":0,"delta":text,"text":text}})
}

fn snapshot(id: &str, text: &str) -> Value {
    json!({"type":"text","sessionID":"ses_main","part":{"id":id,"messageID":"msg_text","text":text}})
}

#[test]
fn stream_before_cli_identity_and_recovery_snapshot_preserve_unicode_and_spacing() {
    for cli_id in ["prt_part", "prt_text_text-0"] {
        let mut projection = Projection::default();
        let mut parser = Parser::new("opencode2");
        assert!(projection.native(native("started", "")).is_empty());
        for text in ["café", " ", "🌍\n"] {
            assert!(projection.native(native("delta", text)).is_empty());
        }
        let events = feed(&mut parser, projection.cli(snapshot(cli_id, "café 🌍\n!")));
        assert_eq!(prose(&events, false), "café 🌍\n!");
        assert!(
            prose(
                &feed(
                    &mut parser,
                    projection.native(native("ended", "café 🌍\n!"))
                ),
                false
            )
            .is_empty()
        );
    }
}

#[test]
fn cli_snapshot_winning_the_race_does_not_repeat_late_native_chunks() {
    let mut projection = Projection::default();
    let mut parser = Parser::new("opencode2");
    let mut events = feed(
        &mut parser,
        projection.cli(snapshot("prt_part", "Hello 🌍.")),
    );
    projection.native(native("started", ""));
    for text in ["Hello", " ", "🌍."] {
        events.extend(feed(&mut parser, projection.native(native("delta", text))));
    }
    events.extend(feed(
        &mut parser,
        projection.native(native("ended", "Hello 🌍.")),
    ));
    assert_eq!(prose(&events, false), "Hello 🌍.");
}

#[test]
fn another_session_cannot_write_text_or_end_the_selected_turn() {
    let mut projection = Projection::default();
    projection.cli(json!({"type":"step_start","sessionID":"ses_main"}));
    for kind in ["session.text.delta", "session.execution.succeeded"] {
        assert!(projection.native(json!({"type":kind,"data":{"sessionID":"ses_child","assistantMessageID":"msg_text","ordinal":0,"delta":"wrong"}})).is_empty());
    }
    assert!(!projection.ended);
}

#[test]
fn long_turns_keep_bounded_state_without_losing_or_repeating_text() {
    let mut projection = Projection::default();
    let mut parser = Parser::new("opencode2");
    projection.cli(json!({"type":"step_start","sessionID":"ses_main"}));
    let mut actual = String::new();
    let mut expected = String::new();
    for index in 0..PART_CAP * 3 {
        let message = format!("msg_{index}");
        let event_id = format!("evt_{index}");
        let text = format!("{index} café 🌍.\n");
        for (phase, delta) in [
            ("started", ""),
            ("delta", text.as_str()),
            ("ended", text.as_str()),
        ] {
            let record = json!({"type":format!("session.text.{phase}"),"id":event_id,"data":{"sessionID":"ses_main","assistantMessageID":message,"ordinal":0,"text":delta,"delta":delta}});
            actual.push_str(&prose(&feed(&mut parser, projection.native(record)), false));
        }
        let snapshot = json!({"type":"text","sessionID":"ses_main","part":{"id":format!("prt_{index}"),"messageID":message,"text":text}});
        actual.push_str(&prose(&feed(&mut parser, projection.cli(snapshot)), false));
        expected.push_str(&text);
    }
    assert_eq!(actual, expected);
    assert!(projection.ordinals.len() <= PART_CAP);
    assert!(projection.parts.is_empty() && projection.admitted.is_empty());
}

#[test]
fn sse_handles_crlf_multiline_data_and_partial_network_reads() {
    let source = ": heartbeat\r\nevent: message\r\ndata: {\"type\":\"text\",\r\ndata: \"data\":\"café\"}\r\n\r\n";
    struct Short<'a>(&'a [u8]);
    impl Read for Short<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.0.read(&mut buffer[..1])
        }
    }
    let mut values = Vec::new();
    read_sse(BufReader::new(Short(source.as_bytes())), |value, _| {
        values.push(value);
        true
    })
    .unwrap();
    assert_eq!(values, [json!({"type":"text","data":"café"})]);
    assert!(read_sse(BufReader::new(&b"data: {invalid}\n\n"[..]), |_, _| true).is_err());
    let large = format!("data: {}\n\n", "x".repeat(RECORD_CAP));
    assert!(read_sse(BufReader::new(large.as_bytes()), |_, _| true).is_err());
}
