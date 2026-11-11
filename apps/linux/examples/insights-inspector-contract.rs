// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Synthetic inputs for the source InspectorView empty and project-split rules.
use serde_json::{Value, json};
use tokenstat_linux::insights::{Snapshot, State, Tab};

fn row(key: &str) -> Value {
    json!({"key":key,"counters":{"total":5,"inputTotal":5,"hasUnknown":false},"events":1,"sessions":1,"valueMicros":0,"estimated":false,"unpricedModels":[]})
}
fn split(key: &str, name: &str) -> Value {
    json!({"key":key,"split":name,"counters":{"total":5,"inputTotal":5,"hasUnknown":false},"events":1,"sessions":1})
}
fn snapshot(events: u64) -> Snapshot {
    serde_json::from_value(json!({
        "info":{"protocolVersion":"53","coreVersion":"fixture","dbPath":null,"hasArchive":true,"timezone":"UTC","priceBookEffectiveFrom":"","hasPrices":false},
        "totals":{"counters":{"total":5,"inputTotal":5,"hasUnknown":false},"events":events,"sessions":1,"days":1},
        "daily":[],"byModel":[],"byProject":[row("café"), row("empty")],"bySource":[],"bySession":[],"activeBlock":null,
        "projectHarnesses":[split("cafe\u{301}", "first"),split("other", "ignored"),split("café", "second")]
    })).unwrap()
}
fn main() {
    let mut empty = Vec::new();
    for (events, loading, error) in [
        (None, false, false),
        (Some(0), false, false),
        (Some(0), true, false),
        (Some(0), false, true),
        (Some(1), false, false),
    ] {
        let mut state = State::default();
        state.snapshot = events.map(snapshot);
        state.loading = loading;
        state.error = error.then(|| "offline".into());
        empty.push(state.inspector_empty_archive());
    }
    let mut groups = Vec::new();
    for (tab, key) in [
        (Tab::Projects, Some("cafe\u{301}")),
        (Tab::Projects, Some("empty")),
        (Tab::Projects, Some("other")),
        (Tab::Models, Some("café")),
        (Tab::Projects, None),
    ] {
        let mut state = State::default();
        state.snapshot = Some(snapshot(1));
        state.tab = tab;
        state.selected = key.map(|k| serde_json::from_value(row(k)).unwrap());
        groups.push(
            state
                .selected_project_harnesses()
                .iter()
                .map(|item| item.split.clone())
                .collect::<Vec<_>>(),
        );
    }
    println!("{}", json!({"empty":empty,"groups":groups}));
}
