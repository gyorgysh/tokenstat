// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Draw the real alert in a hidden unfocused GPUI window, without any client.

fn main() -> anyhow::Result<()> {
    use anyhow::Context;
    let path = std::env::args()
        .nth(1)
        .context("Pass the original fork alert native.json")?;
    let input: serde_json::Value = serde_json::from_slice(&std::fs::read(path)?)?;
    let mut cases = Vec::new();
    for case in input["cases"]
        .as_array()
        .context("Missing reference cases")?
    {
        cases.push((
            case["name"].as_str().context("Missing name")?.to_owned(),
            case["message"]
                .as_str()
                .context("Missing message")?
                .to_owned(),
            case["dark"].as_bool().context("Missing appearance")?,
        ));
    }
    tokenstat_linux::desktop::measure_fork_alert_geometry(cases)
}
