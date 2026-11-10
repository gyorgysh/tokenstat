// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::chat::{flights::Flights, tests::owner};

fn page(id: &str, cursor: Option<&str>, limit: usize, include_usage: bool) -> Query {
    Query::Page {
        id: id.into(),
        cursor: cursor.map(str::to_owned),
        limit,
        include_usage,
    }
}
#[test]
fn keys_use_typed_raw_parameters_and_not_the_callers_folder_for_timeline_reads() {
    let owner = owner(1, "installation");
    let mut pool = Flights::default();
    let query = page("café", None, 1500, true);
    let (first, start) = pool.join_query(&owner, "remote:café:one", query.clone(), 1);
    assert!(start);
    assert_eq!(
        pool.join_query(&owner, "remote:cafe\u{301}:two", query.clone(), 2),
        (first, false)
    );
    for query in [
        page("cafe\u{301}", None, 1500, true),
        page("café", Some(""), 1500, true),
        page("café", Some("cursor"), 1500, true),
        page("café", Some("café"), 1500, true),
        page("café", Some("cafe\u{301}"), 1500, true),
        page("café", None, 1200, true),
        page("café", None, 1500, false),
        Query::Events {
            id: "café".into(),
            offset: 0,
            tail_cursor: None,
        },
        Query::directory("café"),
    ] {
        assert!(pool.join_query(&owner, "remote:café:one", query, 3).1);
    }
    assert!(
        pool.join_query(&owner, "remote:other:one", query.clone(), 4)
            .1
    );
    assert!(
        pool.join_query(
            &super::super::tests::owner(2, "installation"),
            "remote:café:one",
            query.clone(),
            5
        )
        .1
    );
    assert_eq!(pool.complete(first).deliver, [1, 2]);
    assert!(
        pool.join_query(&owner, "remote:café:one", query, 6).1,
        "completed pages are not a global cache"
    );
}

#[test]
fn mutation_retries_every_read_type_with_its_original_query_and_only_live_waiters() {
    let owner = owner(1, "installation");
    let mut pool = Flights::default();
    for query in [
        Query::directory("remote:peer:folder"),
        page("id", Some("older"), 1200, true),
        Query::Events {
            id: "id".into(),
            offset: u64::MAX,
            tail_cursor: Some("tail".into()),
        },
    ] {
        let (old, _) = pool.join_query(&owner, "remote:peer:folder", query.clone(), 1);
        pool.join_query(&owner, "remote:peer:folder", query.clone(), 2);
        pool.retain_waiters(|waiter| *waiter != 1);
        pool.invalidate(&owner, Some("peer"));
        let completion = pool.complete(old);
        assert!(completion.deliver.is_empty());
        assert_eq!(completion.restart.len(), 1);
        let retry = &completion.restart[0];
        assert_eq!(retry.query, query);
        assert_eq!(retry.folder, "remote:peer:folder");
        let (successor, start) = pool.join_query(&owner, &retry.folder, query, 3);
        assert!(!start);
        assert_eq!(successor, retry.flight);
        assert!(pool.complete(old).deliver.is_empty());
        assert_eq!(pool.complete(successor).deliver, [2, 3]);
    }
}

#[test]
fn events_offsets_and_opaque_cursors_have_distinct_keys_and_exact_wire_spelling() {
    let owner = owner(1, "installation");
    let mut pool = Flights::default();
    for (offset, tail_cursor) in [
        (0, None),
        (1, None),
        (u64::MAX, None),
        (0, Some("")),
        (0, Some("café")),
        (0, Some("cafe\u{301}")),
    ] {
        let query = Query::Events {
            id: "id".into(),
            offset,
            tail_cursor: tail_cursor.map(str::to_owned),
        };
        assert!(pool.join_query(&owner, "folder", query.clone(), 1).1);
        let params = query.parameters();
        assert_eq!(params["offset"], json!(offset));
        assert_eq!(params["stablePositions"], true);
        assert_eq!(
            params.get("tailCursor").and_then(Value::as_str),
            tail_cursor
        );
    }
    assert_eq!(
        page("id", None, 1500, true).parameters(),
        json!({"id":"id","limit":1500,"stablePositions":true})
    );
    assert_eq!(
        page("id", Some(""), 1200, false).parameters(),
        json!({"id":"id","limit":1200,"stablePositions":true,"cursor":"","includeUsage":false})
    );
}

#[test]
fn compatibility_uses_remote_codes_or_original_raw_prefix_never_display_text() {
    use tokenstat_core::host_rpc::ExchangeError;
    for (code, message, unknown) in [
        (Some("unknown_method"), "Unsupported", true),
        (None, "unknown chat.eventPage", true),
        (Some("permission"), "unknown account", true),
        (None, "Unknown chat.eventPage", false),
        (None, "chat.eventPage: unknown method", false),
        (None, "unknown", false),
        (Some("unknown_method_later"), "Not available", false),
    ] {
        let error = anyhow::Error::new(ExchangeError::Remote {
            method: "remote.call".into(),
            code: code.map(str::to_owned),
            message: message.into(),
        })
        .context("outer transport context");
        let failure = super::super::paging::Failure::from_error(&error);
        assert_eq!(failure.unknown_method, unknown);
        assert_eq!(failure.message, message);
    }
    for error in [
        anyhow::anyhow!("unknown chat.eventPage"),
        anyhow::Error::new(ExchangeError::Transport("unknown frame".into())),
    ] {
        assert!(!super::super::paging::Failure::from_error(&error).unknown_method);
    }
}

#[test]
fn decoding_is_typed_and_cloning_deliveries_keeps_the_same_immutable_page() {
    let query = page("id", None, 1500, true);
    assert!(query.decode(json!([])).is_err());
    assert!(
        Query::directory("folder")
            .decode(json!({"events":[],"nextOffset":0}))
            .is_err()
    );
    let decoded = query.decode(json!({"events":[{"kind":"agent","seq":1,"event":{"kind":"text","delta":"Synthetic"}}],"nextOffset":1})).unwrap();
    let Reply::Page(first) = &decoded else {
        panic!("wrong type")
    };
    let Reply::Page(second) = decoded.clone() else {
        panic!("wrong type")
    };
    assert!(Arc::ptr_eq(first, &second));
    assert_eq!(first.events.len(), 1);
    assert!(
        Query::Events {
            id: "id".into(),
            offset: 0,
            tail_cursor: None
        }
        .decode(json!({"events":[],"nextOffset":0}))
        .is_ok()
    );
}

#[cfg(unix)]
fn host(
    feature: Option<Value>,
    protocol: &str,
) -> (
    tempfile::TempDir,
    crate::client::Client,
    std::thread::JoinHandle<Vec<Value>>,
) {
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
        time::{Duration, Instant},
    };
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let protocol = protocol.to_owned();
    let worker = std::thread::spawn(move || {
        let mut requests = Vec::new();
        let count = if feature.is_some() { 3 } else { 2 };
        let deadline = Instant::now() + Duration::from_secs(5);
        for index in 0..count {
            let (stream, _) = loop {
                match listener.accept() {
                    Ok(pair) => break pair,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        std::thread::sleep(Duration::from_millis(1))
                    }
                    Err(error) => panic!("missing owned fixture connection: {error}"),
                }
            };
            if index == 0 {
                drop(stream);
                continue;
            }
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            let response = if index == 1 {
                assert_eq!(request["method"], "protocol");
                json!({"ok":true,"result":{"protocolVersion":protocol}})
            } else {
                feature.as_ref().unwrap().clone()
            };
            writeln!(reader.get_mut(), "{response}").unwrap();
            requests.push(request);
        }
        requests
    });
    (
        root,
        crate::client::Client {
            socket,
            allow_spawn: false,
        },
        worker,
    )
}

#[cfg(unix)]
#[test]
fn timeline_transport_prepares_then_routes_all_typed_reads_through_the_shared_host() {
    for folder in ["/fixture/a:b", "remote:peer:a:b", "remote:malformed"] {
        for (query, answer) in [
            (
                page("id", Some("older"), 1200, false),
                json!({"events":[],"nextOffset":0}),
            ),
            (
                Query::Events {
                    id: "id".into(),
                    offset: u64::MAX,
                    tail_cursor: Some("opaque".into()),
                },
                json!({"events":[],"nextOffset":0}),
            ),
            (Query::directory(folder), json!([])),
        ] {
            let (_root, client, worker) = host(Some(json!({"ok":true,"result":answer})), "53");
            client
                .chat_read_if_current(folder, &query, || true)
                .unwrap();
            let requests = worker.join().unwrap();
            let feature = &requests[1];
            if folder.starts_with("remote:peer:") {
                assert_eq!(feature["method"], "remote.call");
                assert_eq!(
                    feature["params"],
                    json!({"peer":"peer","method":query.method(),"params":query.parameters()})
                );
            } else {
                assert_eq!(feature["method"], query.method());
                assert_eq!(feature["params"], query.parameters());
            }
        }
    }
}

#[cfg(unix)]
#[test]
fn retirement_before_io_after_protocol_and_after_reply_never_publishes_a_typed_result() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let root = tempfile::tempdir().unwrap();
    let client = crate::client::Client {
        socket: root.path().join("missing.sock"),
        allow_spawn: false,
    };
    let error = client
        .chat_read_if_current("folder", &page("id", None, 1500, true), || false)
        .unwrap_err();
    assert_eq!(error.to_string(), "Chat read was retired");
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    for stop in [1, 2] {
        let feature = (stop == 2).then(|| json!({"ok":true,"result":{"events":[],"nextOffset":0}}));
        let (_root, client, worker) = host(feature, "53");
        let checks = AtomicUsize::new(0);
        let result = client.chat_read_if_current("folder", &page("id", None, 1500, true), || {
            checks.fetch_add(1, Ordering::SeqCst) < stop
        });
        assert_eq!(result.unwrap_err().to_string(), "Chat read was retired");
        assert_eq!(worker.join().unwrap().len(), stop);
        assert_eq!(checks.load(Ordering::SeqCst), stop + 1);
    }
}

#[cfg(unix)]
#[test]
fn protocol_decode_and_remote_errors_remain_distinct_at_the_client_boundary() {
    let query = page("id", None, 1500, true);
    let (_root, client, worker) = host(None, "52");
    assert!(
        client
            .chat_read_if_current("folder", &query, || true)
            .unwrap_err()
            .to_string()
            .contains("protocol 53")
    );
    assert_eq!(worker.join().unwrap().len(), 1);
    for (answer, unknown) in [
        (
            json!({"ok":false,"error":{"code":"unknown_method","message":"Unsupported"}}),
            true,
        ),
        (json!({"ok":false,"error":"unknown chat.eventPage"}), true),
        (
            json!({"ok":false,"error":{"code":"forbidden","message":"Denied"}}),
            false,
        ),
        (json!({"ok":true,"result":[]}), false),
        (
            json!({"ok":"false","error":"unknown chat.eventPage"}),
            false,
        ),
    ] {
        let (_root, client, worker) = host(Some(answer), "53");
        let error = client
            .chat_read_if_current("remote:peer:folder", &query, || true)
            .unwrap_err();
        assert_eq!(
            super::super::paging::Failure::from_error(&error).unknown_method,
            unknown
        );
        assert_eq!(worker.join().unwrap().len(), 2);
    }
}
