// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Isolated process adapter for local-calendar comparisons.
use serde::Deserialize;
use serde_json::json;
use std::io::Read;

#[derive(Deserialize)]
struct Fixture {
    now_ms: i64,
    timestamps_ms: Vec<i64>,
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let fixture: Fixture = serde_json::from_str(&input).unwrap();
    let results = fixture
        .timestamps_ms
        .iter()
        .map(|ms| {
            tokenstat_linux::sidebar::calendar::local_day(*ms, fixture.now_ms)
                .map(|(start, days)| json!([start, days]))
        })
        .collect::<Vec<_>>();
    println!("{}", json!(results));
}
