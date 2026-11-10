// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn cell(date: &str) -> HeatCell {
    HeatCell {
        date: date.into(),
        value: 1_500_000,
        level: 2,
        locked: false,
    }
}
fn detail(date: &str) -> DayDetail {
    DayDetail::fixture(&cell(date)).unwrap()
}

#[test]
fn leaving_hover_keeps_the_independent_pinned_read_alive() {
    let mut state = DayState::default();
    let day = cell("2026-11-09");
    let pinned = state
        .begin_selected(&day, ActivityScope::ThisMachine)
        .unwrap();
    let hover = state
        .begin_hover(Some(&day), ActivityScope::ThisMachine)
        .unwrap();
    state.clear_hover();
    assert!(!state.finish_detail(&hover, Ok(Some(detail(&day.date)))));
    assert!(state.selected.loading);
    assert!(state.finish_detail(&pinned, Ok(Some(detail(&day.date)))));
    assert!(state.selected.value.is_some());
    assert!(state.hovered.value.is_none());
    assert!(!state.selected.loading);
}

#[test]
fn a_hover_read_can_fill_a_matching_selection_without_retargeting_it() {
    let mut state = DayState::default();
    let first = cell("2026-11-08");
    let second = cell("2026-11-09");
    let stale = state
        .begin_selected(&first, ActivityScope::ThisMachine)
        .unwrap();
    state
        .begin_selected(&second, ActivityScope::ThisMachine)
        .unwrap();
    let hover = state
        .begin_hover(Some(&second), ActivityScope::ThisMachine)
        .unwrap();
    assert!(!state.finish_detail(&stale, Ok(Some(detail(&first.date)))));
    assert!(state.finish_detail(&hover, Ok(Some(detail(&second.date)))));
    assert_eq!(state.selected.value.as_ref().unwrap().date, second.date);
    assert!(
        state
            .begin_selected(&second, ActivityScope::ThisMachine)
            .is_none()
    );
}

#[test]
fn account_scope_cannot_reuse_local_detail_or_request_local_breakdowns() {
    let mut state = DayState::default();
    let day = cell("2026-11-09");
    let local = state
        .begin_selected(&day, ActivityScope::ThisMachine)
        .unwrap();
    let overview = state
        .begin_overview(&day, ActivityScope::ThisMachine)
        .unwrap();
    state.finish_detail(&local, Ok(Some(detail(&day.date))));
    let account = state
        .begin_selected(&day, ActivityScope::AllMachines)
        .unwrap();
    assert!(state.selected.value.is_none());
    assert!(!state.finish_overview(&overview, Ok(DayOverview::default())));
    assert!(!state.finish_detail(&local, Ok(Some(detail(&day.date)))));
    assert!(
        state
            .begin_overview(&day, ActivityScope::AllMachines)
            .is_none()
    );
    assert!(state.overview.date.is_none());
    assert!(state.finish_detail(&account, Ok(None)));
    assert!(!state.selected.loading);
}

#[test]
fn refresh_fences_old_replies_and_mismatched_dates_cannot_poison_the_cache() {
    let mut state = DayState::default();
    let day = cell("2026-11-09");
    let old = state
        .begin_selected(&day, ActivityScope::ThisMachine)
        .unwrap();
    state.finish_detail(&old, Ok(Some(detail(&day.date))));
    state.invalidate(true);
    assert!(state.selected.value.is_some() && state.selected.loading);
    let fresh = state
        .begin_selected(&day, ActivityScope::ThisMachine)
        .unwrap();
    assert!(!state.finish_detail(&old, Ok(None)));
    assert!(state.finish_detail(&fresh, Ok(Some(detail("2026-11-08")))));
    assert!(state.selected.value.is_none());
    assert!(state.selected.error.is_some());
    assert!(
        state
            .begin_selected(&day, ActivityScope::ThisMachine)
            .is_some()
    );
}

#[test]
fn unknown_zero_and_saturated_counters_remain_distinct() {
    let mut d = detail("2026-11-09");
    for row in &mut d.rows {
        row.fresh = None;
        row.cache_read = Some(0);
        row.output = Some(u64::MAX);
    }
    let counters = d.counters();
    assert_eq!(counters[0], None);
    assert_eq!(counters[1], Some(0));
    assert_eq!(counters[4], Some(u64::MAX));
    let segments = d.segments();
    assert_eq!(segments.len(), 2);
    assert!(segments.iter().all(|s| s.total == u64::MAX));
    assert!(segments.iter().all(|s| s.width(1.) >= 2.));
}

#[test]
fn locked_days_and_zero_value_hover_do_not_start_reads() {
    let mut state = DayState::default();
    let mut day = cell("2026-11-09");
    day.value = 0;
    assert!(
        state
            .begin_hover(Some(&day), ActivityScope::ThisMachine)
            .is_none()
    );
    day.locked = true;
    assert!(
        state
            .begin_selected(&day, ActivityScope::ThisMachine)
            .is_none()
    );
    assert!(
        state
            .begin_overview(&day, ActivityScope::ThisMachine)
            .is_none()
    );
    assert!(state.selected.value.is_none() && !state.selected.loading);
}

#[cfg(unix)]
#[test]
fn day_rpc_carries_scope_date_and_weeks_and_rejects_a_different_day() {
    use serde_json::{Value, json};
    use std::{
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
    };
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        drop(listener.accept().unwrap());
        for (method, result) in [
            ("protocol", json!({"protocolVersion":"53"})),
            (
                "activity.day",
                serde_json::to_value(detail("2026-11-08")).unwrap(),
            ),
        ] {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], method);
            if method == "activity.day" {
                assert_eq!(
                    request["params"],
                    json!({"date":"2026-11-09","scope":"account","weeks":53})
                );
            }
            writeln!(
                reader.get_mut(),
                "{}",
                json!({"id":request["id"],"ok":true,"result":result})
            )
            .unwrap();
        }
    });
    assert!(
        crate::client::Client {
            socket,
            allow_spawn: false
        }
        .day_detail("2026-11-09", ActivityScope::AllMachines)
        .is_err()
    );
    worker.join().unwrap();
}

#[cfg(unix)]
#[test]
fn overview_uses_the_selected_local_date_for_all_queries_and_survives_partial_failure() {
    use serde_json::{Value, json};
    use std::{
        collections::HashSet,
        io::{BufRead, BufReader, Write},
        os::unix::net::UnixListener,
    };
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        drop(listener.accept().unwrap());
        let mut seen = HashSet::new();
        for _ in 0..6 {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let r: Value = serde_json::from_str(&line).unwrap();
            let method = r["method"].as_str().unwrap();
            let group = if method == "report" {
                r["params"]["group"].as_str().unwrap()
            } else {
                method
            };
            assert!(seen.insert(group.to_owned()));
            if method != "protocol" {
                let mut expected = json!({"since":"2026-11-09","until":"2026-11-09"});
                if group == "session" {
                    expected["limit"] = 80.into();
                }
                assert_eq!(r["params"]["query"], expected);
            }
            let response = match group {
                "protocol" => json!({"ok":true,"result":{"protocolVersion":"53"}}),
                "totals" => json!({"ok":true,"result":{"sessions":7}}),
                "model" => json!({"ok":false,"error":{"code":"fixture","message":"unavailable"}}),
                "source" => {
                    json!({"ok":true,"result":[{"key":"codex","counters":{"total":42},"valueMicros":10000,"estimated":false,"unpricedModels":[]}]})
                }
                "project" | "session" => json!({"ok":true,"result":[]}),
                _ => panic!("unexpected query"),
            };
            let mut response = response;
            response["id"] = r["id"].clone();
            writeln!(reader.get_mut(), "{response}").unwrap();
        }
        assert_eq!(seen.len(), 6);
    });
    let overview = crate::client::Client {
        socket,
        allow_spawn: false,
    }
    .day_overview("2026-11-09")
    .unwrap();
    assert_eq!(overview.totals.unwrap().sessions, 7);
    assert!(overview.by_model.is_empty());
    assert_eq!(overview.by_source[0].counters.total, 42);
    worker.join().unwrap();
}
