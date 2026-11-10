// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Synthetic states for comparison with the original SwiftUI card.

use serde_json::json;
use tokenstat_linux::home::scan;

fn main() {
    let mut rows = Vec::new();
    for signed_in in [false, true] {
        for scanning in [false, true] {
            for cooling_down in [false, true] {
                rows.push(json!({"signedIn":signed_in,"scanning":scanning,
                    "coolingDown":cooling_down,"steps":scan::steps(signed_in,scanning,cooling_down)}));
            }
        }
    }
    println!("{}", serde_json::to_string(&rows).unwrap());
}
