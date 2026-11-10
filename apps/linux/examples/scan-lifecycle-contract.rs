// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic checkpoints for the original InsightsModel.scan control flow.

use serde_json::{Value, json};
use tokenstat_linux::home::scan::{Report, State};

fn snapshot(label: &str, state: &State, error: Option<&str>, notifications: usize) -> Value {
    json!({"label":label,"scanning":state.scanning,"cooldown":state.cooling_down,
        "action":state.action.is_some(),"error":error,"notifications":notifications})
}

fn main() {
    let report: Report = serde_json::from_value(json!({"filesFound":2,"filesRead":1,"rowsSeen":3,"eventsNew":2,"eventsRecovered":0,"daysRecovered":0,"elapsedMs":10,"warnings":[]})).unwrap();
    let mut cases = Vec::new();
    for scenario in ["success", "refresh_error", "scan_error"] {
        let mut state = State::default();
        let ticket = state.begin().unwrap();
        let mut points = vec![snapshot("scan held", &state, None, 0)];
        assert!(state.begin().is_none());
        if scenario == "scan_error" {
            assert!(!state.finish_scan(ticket, Err("scan offline".into())));
            points.push(snapshot("finished", &state, state.error.as_deref(), 0));
        } else {
            assert!(state.finish_scan(ticket, Ok(report.clone())));
            points.push(snapshot("refresh held", &state, None, 0));
            let error = (scenario == "refresh_error").then_some("refresh offline");
            assert!(state.awaiting_refresh(ticket));
            points.push(snapshot("notification", &state, error, 1));
            assert!(state.finish_refresh(ticket));
            points.push(snapshot("finished", &state, error, 1));
        }
        cases.push(json!({"scenario":scenario,"points":points}));
    }
    println!("{}", serde_json::to_string(&cases).unwrap());
}
