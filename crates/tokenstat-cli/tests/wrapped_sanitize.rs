// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The wrapped report must not let log-derived labels reach the terminal raw.

use std::process::Command;
use tokenstat_core::{
    BillingMode, Confidence, Counters, EventId, Extras, SourceId, Store, Timestamp, UsageEvent,
};

static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// An OSC sequence. The app never emits one itself, so any occurrence in
/// captured output came from data, not formatting.
const OSC: &str = "\u{1b}]0;PWNED\u{7}";

#[test]
fn wrapped_sanitizes_hostile_labels() {
    let dir = std::env::temp_dir().join(format!(
        "tokenstat-wrapped-sanitize-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("tokenstat.db");
    let mut store = Store::open(&db).unwrap();
    let tz = jiff::tz::TimeZone::UTC;
    store
        .insert_events(
            &[UsageEvent {
                id: EventId::derive(&["evil"]),
                source: SourceId::ClaudeCode,
                ts: Timestamp::from_ms(1_720_000_000_000),
                model: format!("evil-model-{OSC}"),
                session: "s1".into(),
                project: format!("/work/{OSC}"),
                counters: Counters {
                    input_fresh: Some(1000),
                    cache_read: None,
                    cache_write_5m: None,
                    cache_write_1h: None,
                    output: Some(1000),
                },
                extras: Extras::default(),
                billing: BillingMode::Metered,
                confidence: Confidence::Exact,
            }],
            &tz,
        )
        .unwrap();
    drop(store);

    let out = Command::new(env!("CARGO_BIN_EXE_tokenstat"))
        .arg("--db")
        .arg(&db)
        .args(["wrapped", "--year", "2024"])
        .env("TOKENSTAT_DATA_DIR", dir.join("data"))
        .env("CLICOLOR_FORCE", "1")
        .output()
        .unwrap();
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        !text.contains("\u{1b}]0;"),
        "raw OSC sequence reached the terminal: {text:?}"
    );
    assert!(
        text.contains('\u{FFFD}'),
        "expected replacement chars for hostile labels: {text:?}"
    );
}

#[test]
fn an_empty_export_replaces_old_output_with_a_valid_empty_document() {
    let dir = std::env::temp_dir().join(format!(
        "ts-review-export-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("archive.db");
    let output = dir.join("export.json");
    std::fs::write(&output, "old report").unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_tokenstat"))
        .arg("--db")
        .arg(&db)
        .args(["export", "--format", "json", "--out"])
        .arg(&output)
        .env("TOKENSTAT_DATA_DIR", dir.join("data"))
        .env("TOKENSTAT_IDENTITY_DIR", dir.join("identity"))
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&output).unwrap()).unwrap();
    assert_eq!(value, serde_json::json!([]));
    assert!(result.stdout.is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}
