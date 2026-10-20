// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Chart authoring must work offline, without opening an archive or contacting a host.
use std::io::Write;
use std::process::{Command, Stdio};

#[test]
fn chart_cli_round_trips_every_family_and_never_opens_an_archive() {
    let directory = tempfile::tempdir().unwrap();
    let data = directory.path().join("data");
    let identity = directory.path().join("identity");
    let invoke = |input: &str, args: &[&str]| {
        let mut child = Command::new(env!("CARGO_BIN_EXE_tokenstat"))
            .args(args)
            .env("TOKENSTAT_DATA_DIR", &data)
            .env("TOKENSTAT_IDENTITY_DIR", &identity)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        child.wait_with_output().unwrap()
    };
    for example in tokenstat_core::chart::examples().as_array().unwrap() {
        let result = invoke(&example.to_string(), &["chart", "-"]);
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        let text = String::from_utf8(result.stdout).unwrap();
        let json = text
            .trim()
            .strip_prefix("```tokenstat-chart\n")
            .unwrap()
            .strip_suffix("\n```")
            .unwrap();
        assert_eq!(
            tokenstat_core::chart::Chart::parse(json).unwrap().kind,
            example["type"].as_str().unwrap()
        );
    }
    assert!(!invoke("{}", &["chart", "-"]).status.success());
    let normalized = invoke(
        &tokenstat_core::chart::examples()[0].to_string(),
        &["--json", "chart", "-"],
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&normalized.stdout).unwrap()["version"],
        1
    );
    let schema = invoke("", &["chart", "--schema"]);
    assert!(schema.status.success());
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&schema.stdout).unwrap()["properties"]["version"]
            ["const"],
        1
    );
    assert!(!data.exists());
    assert!(!identity.exists());
}
