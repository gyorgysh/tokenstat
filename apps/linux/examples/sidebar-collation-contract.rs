// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Compare the sidebar's actual ICU adapter with native source behavior.
use serde::Deserialize;
use serde_json::json;
use std::io::Read;
use tokenstat_linux::sidebar::{collation::SidebarCollation, layout::Collation};
#[derive(Deserialize)]
struct Fixture {
    locale: String,
    names: Vec<String>,
    queries: Vec<String>,
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let fixture: Fixture = serde_json::from_str(&input).unwrap();
    let collation = SidebarCollation::for_locale(&fixture.locale);
    let mut names = fixture.names.clone();
    names.sort_by(|a, b| collation.compare(a, b));
    let matches: Vec<_> = fixture
        .queries
        .iter()
        .map(|needle| {
            fixture
                .names
                .iter()
                .map(|name| collation.contains(name, needle))
                .collect::<Vec<_>>()
        })
        .collect();
    println!("{}", json!({"order": names, "matches": matches}));
}
