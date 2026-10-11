//! This executable has one test so environment changes cannot race other tests.
use std::fs;

use tokenstat_core::{
    scan,
    store::{Query, Store},
};

fn rollout(session: &str, input: u64) -> String {
    format!(
        r#"{{"type":"session_meta","payload":{{"id":"{session}","cwd":"/project"}}}}
{{"type":"turn_context","payload":{{"model":"gpt-6.1-sol"}}}}
{{"type":"event_msg","timestamp":"2026-10-11T10:00:00Z","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":{input},"output_tokens":5}},"total_token_usage":{{"input_tokens":{input},"output_tokens":5}}}}}}}}
"#
    )
}

#[test]
fn scans_private_homes_with_repeats_copies_and_appended_usage() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let data = dir.path().join("data");
    fs::create_dir_all(&home).unwrap();
    // This test process owns its environment and cannot see the user's logs.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("USERPROFILE", &home);
        std::env::set_var("TOKENSTAT_DATA_DIR", &data);
        std::env::set_var("CODEX_HOME", home.join(".codex"));
        for key in [
            "GROK_HOME",
            "CLAUDE_CONFIG_DIR",
            "KIMI_CODE_HOME",
            "QWEN_RUNTIME_DIR",
            "QWEN_HOME",
        ] {
            std::env::remove_var(key);
        }
    }
    assert_eq!(tokenstat_paths::home_dir().unwrap(), home);
    let ordinary = home.join(".codex/sessions/rollout-ordinary.jsonl");
    let private = data.join("chat/one/codex-hook/sessions/rollout-private.jsonl");
    let copied = data.join("chat/two/codex-hook/sessions/rollout-copy.jsonl");
    let third = data.join("chat/three/codex-hook/sessions/rollout-third.jsonl");
    for path in [&ordinary, &private, &copied, &third] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
    }
    fs::write(&ordinary, rollout("ordinary", 10)).unwrap();
    fs::write(&private, rollout("private", 100)).unwrap();
    fs::write(&copied, rollout("private", 100)).unwrap();
    fs::write(&third, rollout("third", 200)).unwrap();
    let tz = jiff::tz::TimeZone::UTC;
    let mut store = Store::open_in_memory().unwrap();
    let report = scan::scan(&mut store, &tz).unwrap();
    assert_eq!(report.files_found, 4);
    let events = store.events(&Query::default()).unwrap();
    assert_eq!(events.len(), 3);
    assert_eq!(events.iter().map(|e| e.counters.total()).sum::<u64>(), 325);
    assert_eq!(scan::scan(&mut store, &tz).unwrap().files_read, 0);
    assert_eq!(store.events(&Query::default()).unwrap().len(), 3);

    // Growing a private rollout is noticed by the ordinary scheduled scan.
    let mut updated = rollout("private", 100);
    updated.push_str(r#"{"type":"event_msg","timestamp":"2026-10-11T10:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":5},"total_token_usage":{"input_tokens":150,"output_tokens":10}}}}
"#);
    fs::write(&private, updated).unwrap();
    assert_eq!(scan::scan(&mut store, &tz).unwrap().files_read, 1);
    let events = store.events(&Query::default()).unwrap();
    assert_eq!(events.len(), 4);
    assert_eq!(events.iter().map(|e| e.counters.total()).sum::<u64>(), 380);

    // The workaround can point CODEX_HOME at an already discovered chat.
    unsafe { std::env::set_var("CODEX_HOME", private.parent().unwrap().parent().unwrap()) };
    assert_eq!(scan::scan(&mut store, &tz).unwrap().files_read, 0);
    assert_eq!(store.events(&Query::default()).unwrap().len(), 4);
}
