// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Test-only local calendar arithmetic comparison with Swift's InsightsModel.
fn main() {
    let timestamps: Vec<i64> = std::env::args()
        .skip(1)
        .map(|s| s.parse().unwrap())
        .collect();
    let values: Vec<Vec<String>> = timestamps
        .into_iter()
        .map(|instant| {
            [7, 30, 90]
                .into_iter()
                .map(|days| {
                    tokenstat_linux::insights::local_start_at(instant as libc::time_t, days)
                        .unwrap()
                })
                .collect()
        })
        .collect();
    println!("{}", serde_json::to_string(&values).unwrap());
}
