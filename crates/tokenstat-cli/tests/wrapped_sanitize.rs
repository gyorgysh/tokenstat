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
