// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic date inputs for the original Insights day-axis comparison.
use serde_json::json;
use tokenstat_linux::insights::account::day_position;

fn main() {
    let keys = [
        "1970-01-01",
        "1969-12-31",
        "2026-01-02",
        "2026-2-3",
        "2026-001-002",
        " 2026-01-02 ",
        "2024-02-29",
        "2023-02-29",
        "1900-02-29",
        "2000-02-29",
        "1582-10-04",
        "1582-10-05",
        "1582-10-10",
        "1582-10-14",
        "1582-10-15",
        "1500-02-29",
        "0001-01-01",
        "26-1-2",
        "0000-01-01",
        "9999-12-31",
        "2026-00-01",
        "2026-13-01",
        "2026-04-31",
        "2026--1-2",
        "2026-01-02abc",
        "",
        "not-a-date",
    ];
    let result: Vec<_> = keys
        .into_iter()
        .map(|key| json!({"key":key,"position":day_position(key)}))
        .collect();
    println!("{}", serde_json::to_string(&result).unwrap());
}
