// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{
    tests::{model, owner, row},
    *,
};
use serde_json::{Value, json};

#[cfg(unix)]
#[test]
fn fork_peer_gate_precedes_the_mutation_and_failure_never_dispatches_unknown_methods() {
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
    };
    for version in [
        json!("25"),
        json!("26"),
        json!("53"),
        json!("bad"),
        Value::Null,
        json!(0),
        json!("0"),
        json!("-1"),
    ] {
        let supported = version
            .as_str()
            .and_then(|s| s.parse::<i64>().ok())
            .is_some_and(|v| v >= FORK_MIN_PROTOCOL);
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = std::thread::spawn(move || {
            let mut requests = vec![
                None,
                Some(("protocol", json!({}), json!({"protocolVersion":"53"}))),
                Some((
                    "remote.call",
                    json!({"peer":"peer","method":"protocol","params":{}}),
                    json!({"protocolVersion":version}),
                )),
            ];
            if supported {
                requests.extend([None,Some(("protocol",json!({}),json!({"protocolVersion":"53"}))),Some(("remote.call",json!({"peer":"peer","method":"chat.fork","params":{"id":"a"}}),json!({"id":"copy","workspaceId":"a:b","title":"A (fork)","backend":"codex"})))]);
            }
            for request in requests {
                let (stream, _) = listener.accept().unwrap();
                if let Some((method, params, result)) = request {
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let sent: Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(sent["method"], method);
                    assert_eq!(sent["params"], params);
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        json!({"id":sent["id"],"ok":true,"result":result})
                    )
                    .unwrap();
                }
            }
            listener.set_nonblocking(true).unwrap();
            assert!(listener.accept().is_err());
        });
        let client = crate::client::Client {
            socket,
            allow_spawn: false,
        };
        let result = client
            .fork_supported_if_current("remote:peer:a:b", || true)
            .unwrap();
        assert_eq!(result, supported);
        if result {
            assert_eq!(
                client
                    .fork_conversation_if_current("remote:peer:a:b", "a", || true)
                    .unwrap()
                    .id,
                "copy"
            );
        }
        server.join().unwrap();
    }
}

#[cfg(unix)]
#[test]
fn local_fork_skips_peer_probe_and_retirement_after_protocol_prevents_any_copy() {
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
        sync::atomic::{AtomicUsize, Ordering},
    };
    for retire in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = std::thread::spawn(move || {
            drop(listener.accept().unwrap());
            let mut requests = vec![("protocol", json!({}), json!({"protocolVersion":"53"}))];
            if !retire {
                requests.push(("chat.fork",json!({"id":"a"}),json!({"id":"copy","workspaceId":"/fixture/a","title":"A (fork)","backend":"codex"})));
            }
            for (method, params, result) in requests {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let sent: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(sent["method"], method);
                assert_eq!(sent["params"], params);
                writeln!(
                    reader.get_mut(),
                    "{}",
                    json!({"id":sent["id"],"ok":true,"result":result})
                )
                .unwrap();
            }
        });
        let client = crate::client::Client {
            socket,
            allow_spawn: false,
        };
        assert!(
            client
                .fork_supported_if_current("/fixture/a", || true)
                .unwrap()
        );
        let checks = AtomicUsize::new(0);
        let result = client.fork_conversation_if_current("/fixture/a", "a", || {
            !retire || checks.fetch_add(1, Ordering::SeqCst) == 0
        });
        if retire {
            assert!(result.unwrap_err().to_string().contains("retired"));
        } else {
            assert_eq!(result.unwrap().id, "copy");
        }
        server.join().unwrap();
    }
}

#[test]
fn mutations_cannot_be_undone_by_predecessor_reads_but_fresh_host_edits_win() {
    let mut model = model();
    let owner = owner(1, "installation");
    let mut first = row("a");
    first.pending_steer = Some("keep note".into());
    model.seed("folder", Ok(vec![first.clone(), row("b")]), 0);
    let slow = model.begin("folder").unwrap();
    let mut changed = first.clone();
    changed.title = "Renamed".into();
    changed.pending_steer = None;
    assert!(model.publish(&owner, "folder", changed, 1));
    assert_eq!(
        model.rows("folder")[0].pending_steer.as_deref(),
        Some("keep note")
    );
    assert!(model.remove(&owner, "folder", "b", 2));
    model.finish(&slow, Ok(vec![first.clone(), row("b"), row("b")]), 3);
    assert_eq!(model.rows("folder").len(), 1);
    assert_eq!(model.rows("folder")[0].title, "Renamed");
    let fresh = model.begin("folder").unwrap();
    first.title = "Other device".into();
    model.finish(&fresh, Ok(vec![first]), 4);
    assert_eq!(model.rows("folder")[0].title, "Other device");
    assert!(!model.publish(&super::tests::owner(2, "other"), "folder", row("wrong"), 5));
}

#[test]
fn shared_waiter_cancellation_mutation_retry_and_old_teardown_preserve_successor_slot() {
    let owner = owner(1, "installation");
    let mut pool = flights::Flights::default();
    let (old, start) = pool.join(&owner, "folder", 0);
    assert!(start);
    for n in 1..30 {
        assert_eq!(pool.join(&owner, "folder", n), (old, false));
    }
    pool.retain_waiters(|n| *n != 0);
    pool.invalidate(&owner, None);
    let (new, start) = pool.join(&owner, "folder", 30);
    assert!(start);
    let late = pool.complete(old);
    assert!(late.deliver.is_empty() && late.restart.is_empty());
    assert_eq!(pool.join(&owner, "folder", 31), (new, false));
    let delivery = pool.complete(new).deliver;
    assert_eq!(delivery.len(), 31);
    assert!(!delivery.contains(&0));
    assert!(pool.complete(new).deliver.is_empty());
    let (failed, _) = pool.join(&owner, "folder", 32);
    pool.invalidate(&owner, None);
    let retried = pool.complete(failed);
    assert!(retried.deliver.is_empty());
    assert_eq!(retried.restart.len(), 1);
    assert_eq!(pool.complete(retried.restart[0].flight).deliver, [32]);
    let (canceled, _) = pool.join(&owner, "folder", 33);
    pool.invalidate(&owner, None);
    pool.retain_waiters(|_| false);
    assert!(pool.complete(canceled).restart.is_empty());
}

#[test]
fn deferred_retirement_extracts_only_its_own_producer_before_invalidated_retry() {
    let owner = owner(1, "installation");
    let mut pool = flights::Flights::default();
    let (first, _) = pool.join(&owner, "one", (1, false));
    pool.join(&owner, "one", (2, true));
    let (unrelated, _) = pool.join(&owner, "two", (3, true));
    pool.invalidate(&owner, None);
    assert!(pool.take_waiters(unrelated, |waiter| !waiter.1).is_empty());
    assert_eq!(pool.take_waiters(first, |waiter| !waiter.1), [(1, false)]);
    let retry = pool.complete(first);
    assert!(retry.deliver.is_empty());
    assert_eq!(retry.restart.len(), 1);
    assert_eq!(pool.complete(retry.restart[0].flight).deliver, [(2, true)]);
    let retry = pool.complete(unrelated);
    assert_eq!(retry.restart.len(), 1);
    assert_eq!(pool.complete(retry.restart[0].flight).deliver, [(3, true)]);
    assert!(pool.take_waiters(first, |_| true).is_empty());
}

#[test]
fn flight_domains_match_encoded_owner_bytes_peer_strings_and_raw_workspace_parameters() {
    let mut pool = flights::Flights::default();
    let a = owner(1, "café");
    let b = owner(1, "cafe\u{301}");
    let (first, _) = pool.join(&a, "remote:café:folder", 1);
    assert_eq!(
        pool.join(&a, "remote:cafe\u{301}:folder", 2),
        (first, false)
    );
    assert!(pool.join(&b, "remote:café:folder", 3).1);
    assert!(pool.join(&a, "remote:café:cafe\u{301}", 4).1);
    assert!(pool.join(&a, "remote:café:café", 5).1);
    let (same_peer, _) = pool.join(&a, "remote:café:other", 6);
    let (other_peer, _) = pool.join(&a, "remote:other:folder", 7);
    pool.invalidate(&a, Some("cafe\u{301}"));
    assert!(pool.complete(first).deliver.is_empty());
    assert!(pool.complete(same_peer).deliver.is_empty());
    assert_eq!(pool.complete(other_peer).deliver, [7]);
}

#[cfg(unix)]
#[test]
fn rename_transport_uses_captured_project_route_and_retirement_prevents_dispatch() {
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
        sync::atomic::{AtomicUsize, Ordering},
    };
    for (folder, method, params) in [
        (
            "/fixture/a:b",
            "chat.update",
            json!({"id":"a","title":"Renamed"}),
        ),
        (
            "remote:peer:a:b",
            "remote.call",
            json!({"peer":"peer","method":"chat.update","params":{"id":"a","title":"Renamed"}}),
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
                    json!({"id":"a","workspaceId":"a:b","title":"Renamed","backend":"codex"}),
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
        let client = crate::client::Client {
            socket,
            allow_spawn: false,
        };
        assert_eq!(
            client
                .rename_conversation_if_current(folder, "a", "Renamed", || true)
                .unwrap()
                .title,
            "Renamed"
        );
        worker.join().unwrap();
    }
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        drop(listener.accept().unwrap());
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        writeln!(
            reader.get_mut(),
            "{}",
            json!({"id":1,"ok":true,"result":{"protocolVersion":"53"}})
        )
        .unwrap();
    });
    let checks = AtomicUsize::new(0);
    let client = crate::client::Client {
        socket,
        allow_spawn: false,
    };
    assert!(
        client
            .rename_conversation_if_current("folder", "a", "Renamed", || checks
                .fetch_add(1, Ordering::SeqCst)
                == 0)
            .unwrap_err()
            .to_string()
            .contains("retired")
    );
    worker.join().unwrap();
}
