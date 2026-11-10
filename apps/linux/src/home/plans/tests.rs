// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use serde_json::json;

#[test]
fn optional_cache_fields_accept_null_like_decode_if_present_but_reject_bad_types() {
    for value in [
        json!({}),
        json!({"enabled":null,"skip":null,"providers":null}),
    ] {
        let state: LimitsSync = serde_json::from_value(value).unwrap();
        assert!(!state.enabled && state.skip.is_empty() && state.providers.is_empty());
    }
    for value in [
        json!({"enabled":3}),
        json!({"skip":false}),
        json!({"providers":[{}]}),
    ] {
        assert!(serde_json::from_value::<LimitsSync>(value).is_err());
    }
}

#[test]
fn hiding_home_retires_its_delivery_but_a_new_reader_joins_the_same_vendor_flight() {
    use store::{Refresh, RefreshError};
    let mut reads = Reads::default();
    let reader = reads.register();
    let first = reads.begin_home(reader, true, 1_000_000, true).unwrap();
    let Refresh::Start(flight) = first.refresh else {
        panic!("expected flight")
    };
    reads.accept_cache(flight, fixture_cache(1_000_000));
    reads.hide(reader);
    let second = reads.begin_home(reader, true, 1_000_001, true).unwrap();
    assert_eq!(second.refresh, Refresh::Join(flight));
    assert!(!reads.finish_usage(first.request, Ok(vec![])));
    reads.finish_limits(
        flight,
        Err(RefreshError::Failed("offline".into())),
        1_000_002,
    );
    assert_eq!(reads.home(reader).error(), Some("offline"));
    assert!(reads.home(reader).usage_loading);
    reads.finish_usage(second.request, Ok(vec![]));
    assert!(!reads.home(reader).loading());
    assert!(reads.visible().iter().all(|p| p.is_stale()));
    // The shared attempt throttle returns immediately without another vendor read.
    let third = reads.begin_home(reader, false, 1_000_003, true).unwrap();
    assert_eq!(third.refresh, Refresh::Ready);
    assert!(reads.home(reader).has_loaded && reads.home(reader).limits_error.is_none());
    assert!(reads.home(reader).usage_loading);
    reads.finish_usage(third.request, Ok(vec![]));
    assert!(reads.begin_home(reader, false, 1_060_002, true).is_none());
    assert!(matches!(
        reads
            .begin_home(reader, false, 1_060_003, true)
            .unwrap()
            .refresh,
        Refresh::Start(_)
    ));
}

#[test]
fn owner_retirement_clears_home_and_neither_reply_can_finish_the_replacement() {
    use store::Refresh;
    let mut reads = Reads::fixture(1_000_000);
    let reader = reads.register();
    let first = reads.begin_home(reader, true, 1_000_000, true).unwrap();
    let Refresh::Start(old) = first.refresh else {
        panic!("expected flight")
    };
    reads.set_owner(2);
    assert!(reads.home(reader).by_source.is_empty() && reads.visible().is_empty());
    let second = reads.begin_home(reader, true, 1_000_001, true).unwrap();
    let Refresh::Start(new) = second.refresh else {
        panic!("expected replacement flight")
    };
    assert!(!reads.accept_cache(old, fixture_cache(1_000_002)));
    reads.finish_limits(old, Ok(fixture_cache(1_000_002).providers), 1_000_002);
    assert!(!reads.finish_usage(first.request, Ok(vec![])));
    assert!(reads.home(reader).loading() && reads.store.current(new, 2));
    reads.finish_limits(new, Ok(vec![]), 1_000_003);
    reads.finish_usage(second.request, Ok(vec![]));
    assert!(!reads.home(reader).loading());
    assert!(reads.home(reader).has_loaded && reads.visible().is_empty());
}

#[test]
fn independent_archive_failure_keeps_rows_and_hidden_busy_guards_do_not_read() {
    use store::{Refresh, RefreshError};
    let mut reads = Reads::fixture(1_000_000);
    let reader = reads.register();
    assert!(reads.begin_home(reader, false, 1_030_000, true).is_none());
    assert!(reads.begin_home(reader, true, 1_030_000, false).is_none());
    let load = reads.begin_home(reader, true, 1_030_000, true).unwrap();
    let Refresh::Start(flight) = load.refresh else {
        panic!("expected flight")
    };
    assert!(reads.begin_home(reader, true, 1_030_001, true).is_none());
    reads.finish_usage(load.request, Err("archive offline".into()));
    assert_eq!(reads.home(reader).by_source.len(), 2);
    assert!(reads.home(reader).loading());
    reads.finish_limits(flight, Err(RefreshError::Retired), 1_030_001);
    assert!(!reads.home(reader).loading());
    assert_eq!(reads.home(reader).error(), Some("archive offline"));
    reads.hide(reader);
    assert!(reads.home(reader).error().is_none());
}

#[test]
fn separate_windows_share_vendors_but_not_archive_rows_errors_or_cancellation() {
    use store::Refresh;
    let mut reads = Reads::default();
    let first_reader = reads.register();
    let second_reader = reads.register();
    let first = reads
        .begin_home(first_reader, true, 1_000_000, true)
        .unwrap();
    let second = reads
        .begin_home(second_reader, true, 1_000_000, true)
        .unwrap();
    let Refresh::Start(flight) = first.refresh else {
        panic!("expected vendor flight")
    };
    assert_eq!(second.refresh, Refresh::Join(flight));
    reads.accept_cache(flight, fixture_cache(1_000_000));
    reads.finish_usage(first.request, Err("first archive unavailable".into()));
    reads.finish_usage(second.request, Ok(Plans::fixture(1_000_000).by_source));
    assert_eq!(reads.home(first_reader).by_source.len(), 0);
    assert_eq!(reads.home(second_reader).by_source.len(), 2);
    reads.hide(first_reader);
    reads.finish_limits(flight, Ok(fixture_cache(1_000_000).providers), 1_000_001);
    assert!(!reads.home(first_reader).has_loaded);
    assert!(reads.home(second_reader).has_loaded);
    assert!(
        reads.home(first_reader).error().is_none() && reads.home(second_reader).error().is_none()
    );
    assert!(!reads.home(second_reader).loading());
    assert_eq!(reads.visible().len(), 2);
}

#[test]
fn releasing_a_window_retires_its_delivery_and_does_not_cancel_another_reader() {
    use store::Refresh;
    let mut reads = Reads::default();
    let closed = reads.register();
    let first = reads.begin_home(closed, true, 1_000_000, true).unwrap();
    let Refresh::Start(flight) = first.refresh else {
        panic!("expected flight")
    };
    reads.release(closed);
    assert!(!reads.finish_usage(first.request, Ok(vec![])));
    assert!(reads.begin_home(closed, true, 1_000_001, true).is_none());
    let reopened = reads.register();
    assert_ne!(closed, reopened);
    let new = reads.begin_home(reopened, true, 1_000_001, true).unwrap();
    assert_eq!(new.refresh, Refresh::Join(flight));
    reads.finish_limits(flight, Ok(fixture_cache(1_000_001).providers), 1_000_002);
    reads.finish_usage(new.request, Ok(vec![]));
    assert!(reads.home(reopened).has_loaded && !reads.home(reopened).loading());
    assert!(reads.waiters.is_empty());
}

#[cfg(unix)]
#[test]
fn cache_vendor_and_archive_queries_use_the_existing_host_methods() {
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
    };
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        for (method, params, result) in [
            (
                "config.limitsSync",
                json!({}),
                json!({"enabled":true,"skip":[],"providers":[]}),
            ),
            ("usage.limits", json!({"force":true}), json!([])),
            (
                "report",
                json!({"group":"source","query":{"billing":"plan"}}),
                json!([]),
            ),
        ] {
            drop(listener.accept().unwrap()); // Readiness probe, no RPC.
            for (method, params, result) in [
                ("protocol", json!({}), json!({"protocolVersion":"53"})),
                (method, params, result),
            ] {
                let mut reader = BufReader::new(listener.accept().unwrap().0);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                assert_eq!(request["params"], params);
                writeln!(
                    reader.get_mut(),
                    "{}",
                    json!({"id":request["id"],"ok":true,"result":result})
                )
                .unwrap();
            }
        }
    });
    let client = crate::client::Client {
        socket,
        allow_spawn: false,
    };
    assert!(client.plan_cache().unwrap().enabled);
    assert!(client.plan_limits(true).unwrap().is_empty());
    assert!(client.plan_usage().unwrap().is_empty());
    worker.join().unwrap();
}
