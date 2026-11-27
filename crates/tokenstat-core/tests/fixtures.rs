// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use tokenstat_core::sources::{claude_code, dsh, pi, qwen};

fn fixtures_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("workspace root")
        .join("fixtures")
}

fn fixture_files() -> Vec<PathBuf> {
    let root = fixtures_root();
    if !root.is_dir() {
        return Vec::new();
    }
    walkdir::WalkDir::new(&root)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| !p.components().any(|c| c.as_os_str() == "local"))
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect()
}

const ALLOWED_KEYS: &[&str] = &[
    "type",
    "requestId",
    "uuid",
    "parentUuid",
    "sessionId",
    "timestamp",
    "version",
    "isSidechain",
    "message",
    "id",
    "model",
    "role",
    "stop_reason",
    "usage",
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "cache_creation",
    "ephemeral_5m_input_tokens",
    "ephemeral_1h_input_tokens",
    "server_tool_use",
    "web_search_requests",
    "web_fetch_requests",
    "service_tier",
    "iterations",
];

fn collect_keys(v: &serde_json::Value, out: &mut HashSet<String>) {
    match v {
        serde_json::Value::Object(map) => {
            for (k, inner) in map {
                out.insert(k.clone());
                collect_keys(inner, out);
            }
        }
        serde_json::Value::Array(items) => items.iter().for_each(|i| collect_keys(i, out)),
        _ => {}
    }
}

fn collect_strings(v: &serde_json::Value, out: &mut Vec<String>) {
    match v {
        serde_json::Value::String(s) => out.push(s.clone()),
        serde_json::Value::Object(map) => map.values().for_each(|i| collect_strings(i, out)),
        serde_json::Value::Array(items) => items.iter().for_each(|i| collect_strings(i, out)),
        _ => {}
    }
}

#[test]
fn committed_fixtures_contain_no_paths() {
    for path in fixture_files() {
        let contents = std::fs::read_to_string(&path).unwrap();
        for (n, line) in contents.lines().enumerate() {
            let v: serde_json::Value = serde_json::from_str(line)
                .unwrap_or_else(|e| panic!("{}:{}: {e}", path.display(), n + 1));
            let mut strings = Vec::new();
            collect_strings(&v, &mut strings);
            for s in strings {
                for marker in ["/Users/", "/home/", "C:\\", "/var/", "/private/"] {
                    assert!(
                        !s.contains(marker),
                        "{}:{} leaks a path: {s}",
                        path.display(),
                        n + 1
                    );
                }
            }
        }
    }
}

#[test]
fn committed_fixtures_contain_no_long_strings() {
    for path in fixture_files() {
        let contents = std::fs::read_to_string(&path).unwrap();
        for (n, line) in contents.lines().enumerate() {
            let v: serde_json::Value = serde_json::from_str(line).unwrap();
            let mut strings = Vec::new();
            collect_strings(&v, &mut strings);
            for s in strings {
                assert!(
                    s.len() <= 64,
                    "{}:{} has a {} character string, which is too long to be safe",
                    path.display(),
                    n + 1,
                    s.len()
                );
            }
        }
    }
}

const PI_ALLOWED_KEYS: &[&str] = &[
    "type",
    "id",
    "parentId",
    "timestamp",
    "version",
    "provider",
    "modelId",
    "message",
    "role",
    "model",
    "usage",
    "input",
    "output",
    "cacheRead",
    "cacheWrite",
    "reasoning",
    "totalTokens",
    "cost",
    "total",
];

const DSH_ALLOWED_KEYS: &[&str] = &[
    "type",
    "seq",
    "time",
    "data",
    "turn",
    "step",
    "message",
    "role",
    "id",
    "source",
    "kind",
    "provider",
    "model",
    "usage",
    "inputTokens",
    "outputTokens",
    "cacheReadTokens",
    "reasoningTokens",
];

const QWEN_ALLOWED_KEYS: &[&str] = &[
    "schemaVersion",
    "id",
    "timestamp",
    "sessionId",
    "model",
    "authType",
    "source",
    "inputTokens",
    "outputTokens",
    "cachedTokens",
    "thoughtsTokens",
    "totalTokens",
    "apiDurationMs",
];

fn allowlist_for(path: &Path) -> &'static [&'static str] {
    if path.components().any(|c| c.as_os_str() == "pi") {
        PI_ALLOWED_KEYS
    } else if path.components().any(|c| c.as_os_str() == "dsh") {
        DSH_ALLOWED_KEYS
    } else if path.components().any(|c| c.as_os_str() == "qwen") {
        QWEN_ALLOWED_KEYS
    } else {
        ALLOWED_KEYS
    }
}

#[test]
fn committed_fixtures_use_only_allowlisted_keys() {
    for path in fixture_files() {
        let allowed: HashSet<&str> = allowlist_for(&path).iter().copied().collect();
        let contents = std::fs::read_to_string(&path).unwrap();
        for (n, line) in contents.lines().enumerate() {
            let v: serde_json::Value = serde_json::from_str(line).unwrap();
            let mut keys = HashSet::new();
            collect_keys(&v, &mut keys);
            for k in keys {
                assert!(
                    allowed.contains(k.as_str()),
                    "{}:{} contains key {k:?}, which is not on the fixture allowlist",
                    path.display(),
                    n + 1
                );
            }
        }
    }
}

fn parse_dir(dir: &Path) -> Vec<tokenstat_core::UsageEvent> {
    let mut events = Vec::new();
    for path in walkdir::WalkDir::new(dir)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
    {
        let contents = std::fs::read_to_string(path.path()).unwrap();
        let out = claude_code::parse_file(path.path(), dir, &contents);
        assert!(
            out.warnings.is_empty(),
            "{}: unexpected warnings {:?}",
            path.path().display(),
            out.warnings
        );
        events.extend(out.events);
    }
    events
}

#[test]
fn pi_fixtures_parse_into_events() {
    let dir = fixtures_root().join("pi");
    if !dir.is_dir() {
        return;
    }
    let mut events = Vec::new();
    for path in walkdir::WalkDir::new(&dir)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
    {
        let contents = std::fs::read_to_string(path.path()).unwrap();
        let out = pi::parse_file(path.path(), &dir, &contents);
        assert!(
            out.warnings.is_empty(),
            "{}: unexpected warnings {:?}",
            path.path().display(),
            out.warnings
        );
        events.extend(out.events);
    }
    assert!(!events.is_empty(), "fixtures produced no events");

    assert!(
        events
            .iter()
            .all(|e| e.counters.input_fresh.unwrap_or(0) > 0 || e.counters.output.unwrap_or(0) > 0),
        "an all-zero turn became an event"
    );

    let unique: HashSet<_> = events.iter().map(|e| e.id).collect();
    assert_eq!(unique.len(), events.len(), "two turns share an id");

    for e in &events {
        if let (Some(reasoning), Some(output)) =
            (e.extras.reasoning_within_output, e.counters.output)
        {
            assert!(
                reasoning <= output,
                "reasoning {reasoning} exceeds output {output}, so it is not inside it"
            );
        }
    }
}

#[test]
fn dsh_fixtures_parse_into_events() {
    let dir = fixtures_root().join("dsh");
    if !dir.is_dir() {
        return;
    }
    let mut events = Vec::new();
    for path in walkdir::WalkDir::new(&dir)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
    {
        let contents = std::fs::read_to_string(path.path()).unwrap();
        let out = dsh::parse_text(path.path(), &dir, &contents);
        assert!(
            out.warnings.is_empty(),
            "{}: unexpected warnings {:?}",
            path.path().display(),
            out.warnings
        );
        events.extend(out.events);
    }
    assert!(!events.is_empty(), "fixtures produced no events");

    let unique: HashSet<_> = events.iter().map(|e| e.id).collect();
    assert_eq!(unique.len(), events.len(), "two turns share an id");

    for e in &events {
        if let (Some(reasoning), Some(output)) =
            (e.extras.reasoning_within_output, e.counters.output)
        {
            assert!(
                reasoning <= output,
                "reasoning {reasoning} exceeds output {output}"
            );
        }
        assert_eq!(
            e.counters.cache_write_5m, None,
            "this vendor reports no cache write, so it must not claim a zero"
        );
    }
}

#[test]
fn qwen_ledger_fixtures_parse_into_complete_unique_events() {
    let dir = fixtures_root().join("qwen");
    if !dir.is_dir() {
        return;
    }
    let sessions = HashMap::new();
    let mut events = Vec::new();
    for path in walkdir::WalkDir::new(&dir)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file())
    {
        let contents = std::fs::read_to_string(path.path()).unwrap();
        let out = qwen::parse_file(path.path(), &contents, &sessions);
        assert!(out.warnings.is_empty(), "{:?}", out.warnings);
        events.extend(out.events);
    }
    assert!(!events.is_empty(), "fixtures produced no events");
    let unique: HashSet<_> = events.iter().map(|e| e.id).collect();
    assert_eq!(unique.len(), events.len(), "two ledger rows share an id");
    for event in events {
        assert!(event.counters.total() > 0);
        if let Some(reasoning) = event.extras.reasoning_within_output {
            assert!(reasoning <= event.counters.output.unwrap_or(0));
        }
    }
}

#[test]
fn resume_duplicates_collapse_by_request_identity() {
    let dir = fixtures_root().join("claude_code/resume-duplicates");
    if !dir.is_dir() {
        return;
    }
    let events = parse_dir(&dir);
    assert!(!events.is_empty(), "fixture produced no events");

    let unique: HashSet<_> = events.iter().map(|e| e.id).collect();
    assert!(
        unique.len() < events.len(),
        "expected duplicate rows across files, got {} unique of {}",
        unique.len(),
        events.len()
    );

    let mut by_id: HashMap<_, &tokenstat_core::UsageEvent> = HashMap::new();
    let mut streaming_partials = 0;
    for e in &events {
        if let Some(prev) = by_id.insert(e.id, e) {
            assert_eq!(prev.model, e.model, "same identity, different model");
            assert_eq!(
                prev.counters.input_fresh, e.counters.input_fresh,
                "same identity, different prompt tokens"
            );
            assert_eq!(
                prev.counters.cache_read, e.counters.cache_read,
                "same identity, different cache read"
            );
            if prev.counters.output != e.counters.output {
                streaming_partials += 1;
            }
        }
    }

    let tz = jiff::tz::TimeZone::UTC;
    let mut store = tokenstat_core::Store::open_in_memory().unwrap();
    store.insert_events(&events, &tz).unwrap();
    let stored = store.totals(&tokenstat_core::Query::default()).unwrap();

    let mut best: HashMap<_, u64> = HashMap::new();
    for e in &events {
        let slot = best.entry(e.id).or_default();
        *slot = (*slot).max(e.counters.output.unwrap_or(0));
    }
    let expected: u64 = best.values().sum();
    assert_eq!(
        stored.counters.output,
        Some(expected),
        "stored output should be the sum of each request's largest observed value"
    );

    assert!(
        streaming_partials > 0,
        "fixture no longer contains streamed partial rows"
    );
}

#[test]
fn ingesting_a_fixture_twice_changes_no_total() {
    let dir = fixtures_root().join("claude_code/resume-duplicates");
    if !dir.is_dir() {
        return;
    }
    let events = parse_dir(&dir);
    let tz = jiff::tz::TimeZone::UTC;
    let mut store = tokenstat_core::Store::open_in_memory().unwrap();

    let first = store.insert_events(&events, &tz).unwrap();
    let before = store.totals(&tokenstat_core::Query::default()).unwrap();
    let second = store.insert_events(&events, &tz).unwrap();
    let after = store.totals(&tokenstat_core::Query::default()).unwrap();

    assert!(first > 0);
    assert_eq!(second, 0, "re-ingesting inserted rows");
    assert_eq!(before.counters, after.counters);
    assert_eq!(before.events, after.events);
}

#[test]
fn splitting_a_fixture_across_files_yields_the_same_totals() {
    let dir = fixtures_root().join("claude_code/resume-duplicates");
    if !dir.is_dir() {
        return;
    }
    let mut events = parse_dir(&dir);
    let tz = jiff::tz::TimeZone::UTC;

    let mut a = tokenstat_core::Store::open_in_memory().unwrap();
    a.insert_events(&events, &tz).unwrap();
    let whole = a.totals(&tokenstat_core::Query::default()).unwrap();

    events.reverse();
    let (left, right) = events.split_at(events.len() / 2);
    let mut b = tokenstat_core::Store::open_in_memory().unwrap();
    b.insert_events(right, &tz).unwrap();
    b.insert_events(left, &tz).unwrap();
    let split = b.totals(&tokenstat_core::Query::default()).unwrap();

    assert_eq!(whole.counters, split.counters);
    assert_eq!(whole.events, split.events);
}
