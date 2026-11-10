// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

fn main() {
    let fixtures = tokenstat_linux::chat::fixtures::Case::ALL.map(|case| case.data());
    println!("{}", serde_json::to_string(&fixtures).unwrap());
}
