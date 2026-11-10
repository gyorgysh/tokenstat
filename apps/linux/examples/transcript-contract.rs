// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic original-source display projection. No host, filesystem or GUI IO.

use serde_json::{Value, json};
use std::io::Read;
use tokenstat_linux::chat::{
    transcript::{
        self, auth,
        fold::{self, Detail},
        images, muse, question, tool,
    },
    wire::TimelineEvent,
};

fn rows(input: &Value) -> Vec<transcript::Row> {
    let events: Vec<TimelineEvent> = serde_json::from_value(input["events"].clone()).unwrap();
    transcript::coalesce(
        &events,
        input["backend"].as_str(),
        input["running"].as_bool().unwrap(),
    )
}
fn history(input: &Value) -> Value {
    let raw = rows(input);
    let presented = auth::presented(&raw);
    let prepared = images::prepare(&presented);
    let running = input["running"].as_bool().unwrap();
    let mut folds = vec![];
    for detail in [
        Detail::Minimal,
        Detail::Compact,
        Detail::Standard,
        Detail::Detailed,
    ] {
        for mode in ["closed", "open", "some"] {
            let folded = fold::fold(&prepared, detail, running, |id| {
                mode == "open" || mode == "some" && id.contains("tool")
            });
            let places = raw.iter().map(|r| json!({
                "id": r.id, "owner": fold::owner(&r.id, &folded), "gallery": images::row_id(&r.id, &prepared)
            })).collect::<Vec<_>>();
            folds.push(json!({"detail": format!("{detail:?}").to_lowercase(), "mode": mode, "rows": folded, "places": places}));
        }
    }
    let recoveries = [
        "claude",
        "claude_code",
        "cursor",
        "cursor_agent",
        "muse",
        "codex",
    ]
    .map(|backend| json!({"backend": backend, "recovery": auth::latest_recovery(&raw, backend)}));
    json!({"raw": raw, "presented": presented, "prepared": prepared, "folds": folds, "recoveries": recoveries})
}
fn main() {
    let mut source = String::new();
    std::io::stdin().read_to_string(&mut source).unwrap();
    let input: Value = serde_json::from_str(&source).unwrap();
    let histories = input["histories"]
        .as_array()
        .unwrap()
        .iter()
        .map(history)
        .collect::<Vec<_>>();
    let snippets=input["snippets"].as_array().unwrap().iter().map(|v|json!({"clip":tool::clip(v["text"].as_str().unwrap()),"diff":tool::is_diff_line(v["text"].as_str().unwrap()),"snippet":tool::snippet(v["verb"].as_str().unwrap(),v["text"].as_str())})).collect::<Vec<_>>();
    let questions = input["questions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| {
            question::stripping(
                v["text"].as_str().unwrap(),
                v["streaming"].as_bool().unwrap(),
            )
        })
        .collect::<Vec<_>>();
    let muse = input["muse"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| {
            muse::completed(
                v["backend"].as_str(),
                v["verb"].as_str().unwrap(),
                v["target"].as_str().unwrap(),
                v["detail"].as_str(),
            )
        })
        .collect::<Vec<_>>();
    let clocks = input["clocks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| tool::duration(v[0].as_i64().unwrap(), v[1].as_i64()))
        .collect::<Vec<_>>();
    let ordinals = input["ordinals"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| tool::ordinal(v.as_i64().unwrap()))
        .collect::<Vec<_>>();
    let previews = input["previews"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| fold::preview(v.as_str().unwrap()))
        .collect::<Vec<_>>();
    let equality = input["equality"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| {
            let a = rows(&v[0]);
            let b = rows(&v[1]);
            let equal = a == b;
            let folded_equal = [
                Detail::Minimal,
                Detail::Compact,
                Detail::Standard,
                Detail::Detailed,
            ]
            .map(|d| {
                fold::fold(&images::prepare(&auth::presented(&a)), d, false, |_| false)
                    == fold::fold(&images::prepare(&auth::presented(&b)), d, false, |_| false)
            });
            json!({"equal":equal,"folded":folded_equal})
        })
        .collect::<Vec<_>>();
    let auth_flags = input["auth"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| auth::needs_sign_in(v["text"].as_str().unwrap(), v["backend"].as_str().unwrap()))
        .collect::<Vec<_>>();
    println!(
        "{}",
        json!({"histories":histories,"snippets":snippets,"questions":questions,"muse":muse,"clocks":clocks,"ordinals":ordinals,"previews":previews,"equality":equality,"auth":auth_flags})
    );
}
