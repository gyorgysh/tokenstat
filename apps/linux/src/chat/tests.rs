// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::work::Scope;
use directory::{Model, Owner, Presentation};
use serde_json::{Value, json};

pub(super) fn owner(generation: u64, account: &str) -> Owner {
    Owner {
        scope: Scope::local(account),
        generation,
        local_host_identity: "fixture-host".into(),
    }
}
pub(super) fn row(id: &str) -> Conversation {
    serde_json::from_value(
        json!({"id":id,"workspaceId":"folder","title":"A conversation","backend":"codex"}),
    )
    .unwrap()
}
pub(super) fn model() -> Model {
    let mut model = Model::default();
    model.set_owner(Some(owner(1, "installation")));
    model
}

#[test]
fn collapse_retires_only_its_waiter_and_both_old_result_branches_cannot_restore_a_retired_owner() {
    for result in [Ok(vec![row("old")]), Err("old failure".into())] {
        let mut first = model();
        let mut second = model();
        let a = first.mount("folder").unwrap();
        let b = second.mount("folder").unwrap();
        let mut pool = flights::Flights::default();
        let (flight, start) = pool.join(&a.owner, &a.folder, (1, a.clone()));
        assert!(start);
        let (same, start) = pool.join(&b.owner, &b.folder, (2, b.clone()));
        assert_eq!(same, flight);
        assert!(!start);
        first.retain_mounts(&[]);
        pool.retain_waiters(|(window, _)| *window != 1);
        let deliveries = pool.complete(flight).deliver;
        assert_eq!(deliveries.len(), 1);
        assert!(!first.finish(&a, result.clone(), 10));
        assert!(second.finish(&b, result.clone(), 10));
        assert!(pool.complete(flight).deliver.is_empty());
        first.set_owner(Some(owner(2, "other")));
        let current = first.mount("folder").unwrap();
        assert!(!first.finish(&a, result, 10));
        assert_eq!(first.presentation("folder"), Presentation::Loading);
        assert!(first.finish(&current, Ok(vec![row("new")]), 20));
        assert_eq!(first.rows("folder")[0].id, "new");
        let (_, start) = pool.join(&current.owner, &current.folder, (1, current.clone()));
        assert!(
            start,
            "completed values must not become a global transport cache"
        );
    }
}
#[test]
fn directory_failures_are_not_empty_and_retries_keep_verified_content_or_empty_state() {
    let mut model = model();
    let first = model.mount("folder").unwrap();
    assert_eq!(model.presentation("folder"), Presentation::Loading);
    model.finish(&first, Err("offline".into()), 0);
    assert_eq!(model.presentation("folder"), Presentation::Failed);
    let retry = model.begin("folder").unwrap();
    assert!(model.begin("folder").is_none());
    assert_eq!(model.presentation("folder"), Presentation::Failed);
    model.finish(&retry, Ok(vec![]), 0);
    assert_eq!(model.presentation("folder"), Presentation::Empty);
    let refresh = model.begin("folder").unwrap();
    assert_eq!(model.presentation("folder"), Presentation::Empty);
    model.finish(&refresh, Err("offline again".into()), 0);
    assert_eq!(model.presentation("folder"), Presentation::Empty);
    assert!(model.error("folder").is_none());
    let ready = model.begin("folder").unwrap();
    model.finish(&ready, Ok(vec![row("é"), row("e\u{301}"), row("")]), 0);
    assert_eq!(model.rows("folder").len(), 1);
    let failure = model.begin("folder").unwrap();
    model.finish(&failure, Err("later offline".into()), 0);
    assert_eq!(model.presentation("folder"), Presentation::Content);
    assert_eq!(model.rows("folder")[0].id, "é");
}
#[test]
fn helper_restart_retires_transport_but_keeps_the_same_scopes_verified_titles_and_running_stamp() {
    let mut model = model();
    let mut running = row("active");
    running.running = true;
    let first = model.mount("folder").unwrap();
    model.finish(&first, Ok(vec![running.clone()]), 1000);
    assert_eq!(model.running_since("active"), Some(1000));
    let read = model.begin("folder").unwrap();
    assert!(!model.set_owner(Some(owner(2, "installation"))));
    assert!(!model.finish(&read, Ok(vec![]), 9000));
    assert_eq!(model.presentation("folder"), Presentation::Content);
    assert_eq!(model.running_since("active"), Some(1000));
    let fresh = model.begin("folder").unwrap();
    model.finish(&fresh, Ok(vec![running]), 9000);
    assert_eq!(model.running_since("active"), Some(1000));
    let ended = model.begin("folder").unwrap();
    model.finish(&ended, Ok(vec![row("active")]), 10000);
    assert!(model.running_since("active").is_none());
    assert!(model.set_owner(Some(owner(3, "other"))));
    assert!(model.rows("folder").is_empty());
}
#[test]
fn history_initialization_and_order_holds_do_not_reverse_input_or_move_existing_rows() {
    let mut state = history::State::default();
    state.set_expanded("e\u{301}", true);
    let mut preferences = crate::sidebar::Snapshot::default();
    preferences.apply(&crate::sidebar::Mutation::Expansion {
        key: "history:é".into(),
        expanded: false,
    });
    state.initialize(&preferences);
    assert!(state.expanded("é"));
    let incoming = vec![row("new"), row("b"), row("a")];
    state.hold("folder", &["a".into(), "b".into(), "a".into()]);
    assert_eq!(
        history::holding_order(&incoming, state.held("folder"))
            .iter()
            .map(|r| r.id.as_str())
            .collect::<Vec<_>>(),
        ["a", "b", "new"]
    );
    state.release("folder");
    assert_eq!(
        history::holding_order(&incoming, state.held("folder"))[0].id,
        "new"
    );
    let mut empty = row("new-chat");
    empty.title = "New chat".into();
    assert!(
        history::shown(&empty, None, None),
        "unknown drafts cannot prove an unused chat"
    );
    assert!(!history::shown(&empty, None, Some(false)));
    assert!(history::shown(&empty, Some("new-chat"), Some(false)));
    state.hold("folder", &["a".into()]);
    state.retain_holds(&[]);
    assert!(
        state.held("folder").is_none(),
        "collapsing while the pointer is over the footer must release the hold"
    );
}
#[test]
fn wire_decoration_is_optional_but_required_row_identity_and_known_boolean_types_are_strict() {
    for pull in [
        Value::Null,
        json!({"future":1}),
        json!({"number":1,"title":"PR","url":"https://fixture.invalid/pull/1","state":"open","draft":false,"baseRef":"main"}),
    ] {
        let mut value = serde_json::to_value(row("one")).unwrap();
        value["pull"] = pull.clone();
        let result: Conversation = serde_json::from_value(value).unwrap();
        assert_eq!(result.pull.is_some(), pull.get("number").is_some());
    }
    let mut value = serde_json::to_value(row("one")).unwrap();
    value["running"] = json!("yes");
    assert!(serde_json::from_value::<Conversation>(value).is_err());
    let mut value = serde_json::to_value(row("one")).unwrap();
    value["running"] = Value::Null;
    value["updatedAtMs"] = Value::Null;
    let result: Conversation = serde_json::from_value(value).unwrap();
    assert!(!result.running);
    assert_eq!(result.updated_at_ms, 0);
}

#[cfg(unix)]
#[test]
fn directory_transport_routes_without_reading_events_or_starting_agents() {
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
    };
    for (folder, method, params) in [
        (
            "/fixture/a:b",
            "chat.list",
            json!({"workspaceId":"/fixture/a:b"}),
        ),
        (
            "remote:peer:a:b",
            "remote.call",
            json!({"peer":"peer","method":"chat.list","params":{"workspaceId":"a:b"}}),
        ),
        (
            "remote:malformed",
            "chat.list",
            json!({"workspaceId":"remote:malformed"}),
        ),
    ] {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = std::thread::spawn(move || {
            drop(listener.accept().unwrap());
            for (method, params, answer) in [
                ("protocol", json!({}), json!({"protocolVersion":"53"})),
                (
                    method,
                    params,
                    json!([{"id":"one","workspaceId":"a:b","title":"Hello","backend":"codex","pull":{"future":1}}]),
                ),
            ] {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                assert_eq!(request["params"], params);
                writeln!(
                    reader.get_mut(),
                    "{}",
                    json!({"id":request["id"],"ok":true,"result":answer})
                )
                .unwrap();
            }
        });
        let rows = crate::client::Client {
            socket,
            allow_spawn: false,
        }
        .conversations(folder)
        .unwrap();
        worker.join().unwrap();
        assert_eq!(rows[0].title, "Hello");
        assert!(rows[0].pull.is_none());
    }
}

#[cfg(unix)]
#[test]
fn retiring_during_protocol_io_prevents_dispatch_for_the_earlier_owner() {
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
        sync::atomic::{AtomicUsize, Ordering},
    };
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        drop(listener.accept().unwrap());
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["method"], "protocol");
        writeln!(
            reader.get_mut(),
            "{}",
            json!({"id":request["id"],"ok":true,"result":{"protocolVersion":"53"}})
        )
        .unwrap();
    });
    let checks = AtomicUsize::new(0);
    let error = crate::client::Client {
        socket,
        allow_spawn: false,
    }
    .conversations_if_current("folder", || checks.fetch_add(1, Ordering::SeqCst) == 0)
    .unwrap_err();
    worker.join().unwrap();
    assert!(error.to_string().contains("retired"));
    assert_eq!(checks.load(Ordering::SeqCst), 2);
}
