// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Held synthetic checkpoints for the original fetchRemotes lifecycle.
use serde_json::{Value, json};
use tokenstat_linux::insights::fetch::{Report, State};
fn point(label: &str, state: &State, error: Option<&str>, notifications: usize) -> Value {
    json!({"label":label,"fetching":state.fetching,"cooldown":state.cooling_down,
        "cooldownSeconds":if state.cooling_down { Some(tokenstat_linux::insights::fetch::COOLDOWN_SECONDS) } else { None },
        "action":state.action,"error":error,"notifications":notifications})
}
fn main() {
    let mut cases = Vec::new();
    for scenario in ["empty", "messages", "refresh_error", "fetch_error"] {
        let mut state = State::default();
        let ticket = state.begin().unwrap();
        let mut points = vec![point("fetch held", &state, None, 0)];
        assert!(state.begin().is_none());
        if scenario == "fetch_error" {
            assert!(!state.finish_fetch(ticket, Err("fetch offline".into())));
            points.push(point("finished", &state, state.error.as_deref(), 0));
        } else {
            let rows = if scenario == "messages" {
                [Some("one"), None, Some("two")]
                    .into_iter()
                    .map(|message| Report {
                        vendor: "fixture".into(),
                        events: 0,
                        from_cache: false,
                        skipped_no_token: false,
                        message: message.map(str::to_owned),
                    })
                    .collect()
            } else {
                Vec::new()
            };
            assert!(state.finish_fetch(ticket, Ok(rows)));
            points.push(point("refresh held", &state, None, 0));
            let error = (scenario == "refresh_error").then_some("refresh offline");
            assert!(state.awaiting_refresh(ticket));
            points.push(point("notification", &state, error, 1));
            assert!(state.finish_refresh(ticket));
            points.push(point("finished", &state, error, 1));
        }
        cases.push(json!({"scenario":scenario,"points":points}));
    }
    println!("{}", serde_json::to_string(&cases).unwrap());
}
