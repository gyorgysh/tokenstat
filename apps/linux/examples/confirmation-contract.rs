// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Real GPUI component layout in a hidden, unfocused window; no host/archive.

fn main() -> anyhow::Result<()> {
    use anyhow::Context;
    let path = std::env::args()
        .nth(1)
        .context("Pass the original confirmation native.json")?;
    let input: serde_json::Value = serde_json::from_slice(&std::fs::read(path)?)?;
    let mut cases = Vec::new();
    for case in input["cases"]
        .as_array()
        .context("Missing reference cases")?
    {
        cases.push((
            case["name"].as_str().context("Missing name")?.to_owned(),
            case["folder"]
                .as_str()
                .context("Missing folder")?
                .to_owned(),
            case["dark"].as_bool().context("Missing appearance")?,
        ));
    }
    tokenstat_linux::desktop::measure_confirmation_geometry(cases)
}
