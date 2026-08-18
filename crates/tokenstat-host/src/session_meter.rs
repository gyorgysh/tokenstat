// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Live per-session token and list-rate meter.
//!
//! The sidebar wants two numbers the archive already knows how to compute:
//! how many tokens this session has used, and what that would have cost at
//! list rates. This module answers both from the same allowlisted parsers
//! the archive uses, without writing anything to the store.
//!
//! Conversation text is dropped at the parser boundary. The reading carries
//! counters, a model id, and a context fraction. Nothing else.
//!
//! **The reading starts when the process did.** A folder's transcript is the
//! folder's whole history, so folding all of it in reported the last session's
//! spend, or this month's, against a shell that opened a second ago. Every
//! event before the spawn is dropped, and a session that has not produced one
//! yet has no reading rather than an inherited one.
//!
//! First cut is Claude and Grok only. Other harnesses stay on CPU · RAM
//! until they grow a live path. Two sessions of the same harness in one
//! folder share the newest log: that is a known limitation, not a guess
//! dressed up as identity.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use tokenstat_core::pricing::{EquivalentValue, PriceTable, display_usage_model_id};
use tokenstat_core::sources::{claude_code, grok};
use tokenstat_core::{Catalog, UsageEvent};

/// What a front end can draw for one live session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MeterReading {
    pub tokens: u64,
    /// Absent when nothing priced. Never a made-up zero.
    pub cost_micros: Option<i64>,
    pub estimated: bool,
    pub complete: bool,
    pub model: String,
    /// Last turn's prompt-side tokens. The context bar, not the lifetime sum.
    pub context_used: Option<u64>,
    pub context_window: Option<u64>,
}

/// Fold a live session's usage into a sidebar reading, when we can find it.
///
/// `started_at_ms` is when the process was spawned. Nothing older than that
/// belongs to it, and a session with nothing newer gets no reading at all.
pub(crate) fn reading(command: &str, cwd: &str, started_at_ms: u64) -> Option<MeterReading> {
    if cwd.is_empty() {
        return None;
    }
    let events = match harness_name(command)? {
        "claude" => claude_events(cwd)?,
        "grok" => grok_events(cwd)?,
        _ => return None,
    };
    let mine = since(&events, started_at_ms);
    if mine.is_empty() {
        return None;
    }
    fold(&mine, &current_prices())
}

/// Events this session could have produced.
///
/// Borrowed, not cloned. This runs for every live session on every `pty.list`
/// poll, and a long transcript is thousands of events each holding several
/// strings: copying them all every two seconds to read them once is a lot of
/// allocator traffic for nothing.
///
/// A small grace before the spawn, because the two clocks are not the same
/// one: the harness stamps the turn, the daemon stamps the spawn, and a first
/// turn written a moment "before" launch is still this session's.
fn since(events: &[UsageEvent], started_at_ms: u64) -> Vec<&UsageEvent> {
    const GRACE_MS: i64 = 2_000;
    let floor = started_at_ms as i64 - GRACE_MS;
    events.iter().filter(|e| e.ts.utc_ms >= floor).collect()
}

/// Sum events into the wire shape. Pure, so tests do not need a home directory.
///
/// Owned slice for the tests, which build their events inline. The live path
/// goes through `fold`, which borrows.
#[cfg(test)]
pub(crate) fn fold_events(events: &[UsageEvent], prices: &PriceTable) -> Option<MeterReading> {
    fold(&events.iter().collect::<Vec<_>>(), prices)
}

/// Sum events into the wire shape. Pure, so tests do not need a home directory.
pub(crate) fn fold(events: &[&UsageEvent], prices: &PriceTable) -> Option<MeterReading> {
    if events.is_empty() {
        return None;
    }

    let mut tokens = 0u64;
    let mut cost = 0i64;
    let mut priced = 0u32;
    let mut estimated = false;
    let mut complete = true;

    for event in events {
        tokens = tokens.saturating_add(event.counters.total());
        let lookup = display_usage_model_id(&event.model);
        match EquivalentValue::price(prices, &lookup, &event.counters) {
            Some(value) => {
                cost = cost.saturating_add(value.micros().max(0));
                priced = priced.saturating_add(1);
                estimated |= prices.is_estimate(&lookup);
            }
            None => complete = false,
        }
    }

    if tokens == 0 {
        return None;
    }

    let model = events
        .iter()
        .rev()
        .find(|e| e.model != "unknown" && !e.model.is_empty())
        .or_else(|| events.last())
        .map(|e| e.model.clone())
        .unwrap_or_default();

    let context_used = events
        .iter()
        .rev()
        .map(|e| e.counters.input_total())
        .find(|&n| n > 0);
    let lookup = display_usage_model_id(&model);
    let context_window = prices
        .catalog()
        .and_then(|c| c.get(&lookup))
        .and_then(|m| m.context_window());
    let (context_used, context_window) = match (context_used, context_window) {
        (Some(used), Some(window)) => (Some(used), Some(window)),
        _ => (None, None),
    };

    Some(MeterReading {
        tokens,
        cost_micros: (priced > 0 && cost > 0).then_some(cost),
        estimated,
        complete,
        model,
        context_used,
        context_window,
    })
}

fn harness_name(command: &str) -> Option<&'static str> {
    let name = command.rsplit('/').next().unwrap_or(command).trim();
    match name {
        "claude" => Some("claude"),
        "grok" => Some("grok"),
        _ => None,
    }
}

fn claude_events(cwd: &str) -> Option<Arc<Vec<UsageEvent>>> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let projects = claude_code::discover(&home)?;
    let slug: String = cwd
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let dir = projects.join(slug);
    let path = newest_jsonl(&dir)?;
    cached_events(&path, |contents| {
        claude_code::parse_file(&path, &projects, contents).events
    })
}

fn grok_events(cwd: &str) -> Option<Arc<Vec<UsageEvent>>> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let grok_home = grok::discover(&home)?;
    let encoded = grok_encode(cwd);
    let session_dir = grok_home.join("sessions").join(&encoded);
    let sid = newest_child_dir(&session_dir)?;
    let log = grok::log_path(&grok_home)?;
    // Parse with an empty session index so the cached events do not belong
    // to whichever session happened to ask first. Model is joined after
    // the filter, from this session's own summary.
    let events = cached_events(&log, |contents| {
        grok::parse_file(&log, contents, &HashMap::new()).events
    })?;
    let model = grok_one_session(&grok_home, &encoded, &sid)
        .map(|m| m.model)
        .unwrap_or_else(|| "unknown".into());
    let mine: Vec<UsageEvent> = events
        .iter()
        .filter(|e| e.session == sid)
        .map(|e| {
            let mut event = e.clone();
            event.model = model.clone();
            event
        })
        .collect();
    if mine.is_empty() {
        return None;
    }
    Some(Arc::new(mine))
}

fn grok_encode(cwd: &str) -> String {
    cwd.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == '_' {
                c.to_string()
            } else {
                format!("%{:02X}", c as u32)
            }
        })
        .collect()
}

fn grok_one_session(home: &Path, encoded_cwd: &str, sid: &str) -> Option<grok::SessionMeta> {
    let path = home
        .join("sessions")
        .join(encoded_cwd)
        .join(sid)
        .join("summary.json");
    let text = std::fs::read_to_string(path).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    Some(grok::SessionMeta {
        model: value
            .get("current_model_id")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string(),
        project: "unknown".into(),
    })
}

/// Newest `.jsonl` directly in `dir`. Does not descend: Claude subagent
/// transcripts live one level down and belong to a parent we cannot name.
fn newest_jsonl(dir: &Path) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut best: Option<(SystemTime, PathBuf)> = None;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|ext| ext != "jsonl") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let Ok(mtime) = meta.modified() else { continue };
        if best.as_ref().is_none_or(|(best_at, _)| mtime >= *best_at) {
            best = Some((mtime, path));
        }
    }
    best.map(|(_, path)| path)
}

/// Newest directory under `dir`, by the directory's own mtime.
fn newest_child_dir(dir: &Path) -> Option<String> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut best: Option<(SystemTime, String)> = None;
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.is_empty() || name.starts_with('.') {
            continue;
        }
        let Ok(mtime) = meta.modified() else { continue };
        if best.as_ref().is_none_or(|(best_at, _)| mtime >= *best_at) {
            best = Some((mtime, name));
        }
    }
    best.map(|(_, name)| name)
}

struct CachedParse {
    mtime: SystemTime,
    events: Arc<Vec<UsageEvent>>,
}

fn parse_cache() -> &'static Mutex<HashMap<PathBuf, CachedParse>> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, CachedParse>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cached_events(
    path: &Path,
    parse: impl FnOnce(&str) -> Vec<UsageEvent>,
) -> Option<Arc<Vec<UsageEvent>>> {
    let mtime = path.metadata().ok()?.modified().ok()?;
    if let Ok(guard) = parse_cache().lock()
        && let Some(hit) = guard.get(path)
        && hit.mtime == mtime
    {
        return Some(Arc::clone(&hit.events));
    }
    let contents = std::fs::read_to_string(path).ok()?;
    let events = Arc::new(parse(&contents));
    if let Ok(mut guard) = parse_cache().lock() {
        guard.insert(
            path.to_path_buf(),
            CachedParse {
                mtime,
                events: Arc::clone(&events),
            },
        );
    }
    Some(events)
}

struct Books {
    checked_at: Instant,
    prices_mtime: Option<SystemTime>,
    catalog_mtime: Option<SystemTime>,
    prices: Arc<PriceTable>,
}

fn books() -> &'static Mutex<Books> {
    static BOOKS: OnceLock<Mutex<Books>> = OnceLock::new();
    BOOKS.get_or_init(|| {
        Mutex::new(Books {
            checked_at: Instant::now()
                .checked_sub(Duration::from_secs(60))
                .unwrap_or_else(Instant::now),
            prices_mtime: None,
            catalog_mtime: None,
            prices: Arc::new(PriceTable::load_with_catalog()),
        })
    })
}

fn current_prices() -> Arc<PriceTable> {
    let mut guard = books().lock().unwrap_or_else(|e| e.into_inner());
    if guard.checked_at.elapsed() < Duration::from_secs(2) {
        return Arc::clone(&guard.prices);
    }
    guard.checked_at = Instant::now();
    let prices_mtime = PriceTable::default_path()
        .ok()
        .and_then(|p| p.metadata().ok())
        .and_then(|m| m.modified().ok());
    let catalog_mtime = Catalog::default_path()
        .ok()
        .and_then(|p| p.metadata().ok())
        .and_then(|m| m.modified().ok());
    if prices_mtime != guard.prices_mtime || catalog_mtime != guard.catalog_mtime {
        guard.prices = Arc::new(PriceTable::load_with_catalog());
        guard.prices_mtime = prices_mtime;
        guard.catalog_mtime = catalog_mtime;
    }
    Arc::clone(&guard.prices)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tokenstat_core::model::{
        BillingMode, Confidence, Counters, EventId, Extras, SourceId, Timestamp,
    };

    const BOOK: &str = r#"{
      "effective_from": "2026-08-01",
      "models": [
        {"match":"claude-opus-4-5","input":5.0,"output":25.0,"cache_read":0.5,"cache_write_5m":6.25,"cache_write_1h":10.0},
        {"match":"grok-4.5","input":2.0,"output":6.0,"cache_read":0.3,"cache_write_5m":0.0,"cache_write_1h":0.0}
      ]
    }"#;

    const CATALOG: &str = r#"{
      "effective_from": "2026-08-01",
      "models": [
        {"id":"anthropic/claude-opus-4-5","aliases":["claude-opus-4-5"],"ctx":200000},
        {"id":"xai/grok-4.5","aliases":["grok-4.5"],"ctx":131072}
      ]
    }"#;

    fn prices() -> PriceTable {
        PriceTable::parse(BOOK)
            .expect("book")
            .with_catalog(Arc::new(Catalog::parse(CATALOG).expect("catalog")))
    }

    fn event(model: &str, input: u64, cache_read: u64, output: u64) -> UsageEvent {
        UsageEvent {
            id: EventId::derive(&["meter", model, &input.to_string(), &output.to_string()]),
            source: SourceId::ClaudeCode,
            ts: Timestamp::from_ms(0),
            model: model.to_string(),
            session: "s".into(),
            project: "p".into(),
            counters: Counters {
                input_fresh: Some(input),
                cache_read: Some(cache_read),
                cache_write_5m: None,
                cache_write_1h: None,
                output: Some(output),
            },
            extras: Extras::default(),
            billing: BillingMode::Plan,
            confidence: Confidence::Exact,
        }
    }

    fn stamped(ms: i64) -> UsageEvent {
        let mut e = event("claude-opus-4-1", 100, 0, 10);
        e.ts = Timestamp::from_ms(ms);
        e
    }

    #[test]
    fn empty_events_are_not_a_reading() {
        assert!(fold_events(&[], &prices()).is_none());
    }

    #[test]
    fn a_new_session_does_not_inherit_the_folder_history() {
        let events = [stamped(1_000), stamped(2_000)];
        assert!(
            since(&events, 60_000).is_empty(),
            "a session spawned after both turns owns neither"
        );
    }

    #[test]
    fn only_turns_after_the_spawn_are_counted() {
        let events = [stamped(1_000), stamped(90_000), stamped(95_000)];
        assert_eq!(since(&events, 60_000).len(), 2);
    }

    #[test]
    fn a_first_turn_just_before_the_spawn_still_counts() {
        // The harness stamps the turn and the daemon stamps the spawn. They
        // are not the same clock, and a turn a moment "before" launch is
        // still this session's.
        let events = [stamped(59_500)];
        assert_eq!(since(&events, 60_000).len(), 1);
    }

    #[test]
    fn sums_tokens_and_list_rate_across_turns() {
        let events = [
            event("claude-opus-4-5", 1_000, 0, 100),
            event("claude-opus-4-5", 2_000, 0, 200),
        ];
        let reading = fold_events(&events, &prices()).expect("reading");
        assert_eq!(reading.tokens, 3_300);
        // 3000 input * $5/M + 300 output * $25/M = $0.015 + $0.0075 = $0.0225
        assert_eq!(reading.cost_micros, Some(22_500));
        assert!(reading.complete);
        assert!(!reading.estimated);
        assert_eq!(reading.model, "claude-opus-4-5");
    }

    #[test]
    fn context_bar_uses_the_last_turn_not_the_lifetime_sum() {
        let events = [
            event("claude-opus-4-5", 10_000, 0, 50),
            event("claude-opus-4-5", 1_500, 4_500, 80),
        ];
        let reading = fold_events(&events, &prices()).expect("reading");
        assert_eq!(reading.context_used, Some(6_000));
        assert_eq!(reading.context_window, Some(200_000));
        assert!(reading.tokens > 6_000, "lifetime tokens still accumulate");
    }

    #[test]
    fn missing_catalog_window_hides_the_bar() {
        let bare = PriceTable::parse(BOOK).expect("book");
        let reading = fold_events(&[event("claude-opus-4-5", 100, 0, 10)], &bare).expect("reading");
        assert_eq!(reading.context_used, None);
        assert_eq!(reading.context_window, None);
        assert!(reading.cost_micros.is_some(), "price book still works");
    }

    #[test]
    fn unpriced_model_still_reports_tokens() {
        let reading =
            fold_events(&[event("mystery-model", 400, 0, 20)], &prices()).expect("reading");
        assert_eq!(reading.tokens, 420);
        assert_eq!(reading.cost_micros, None);
        assert!(!reading.complete);
        assert_eq!(reading.model, "mystery-model");
    }

    #[test]
    fn a_zero_cost_is_omitted_rather_than_shown() {
        let free = PriceTable::parse(
            r#"{"effective_from":"2026-08-01","models":[
                 {"match":"free","input":0,"output":0,"cache_read":0,"cache_write_5m":0,"cache_write_1h":0}
               ]}"#,
        )
        .expect("book");
        let reading = fold_events(&[event("free", 100, 0, 10)], &free).expect("reading");
        assert_eq!(reading.tokens, 110);
        assert_eq!(reading.cost_micros, None);
    }

    #[test]
    fn parsers_drop_prompt_text_before_the_reading() {
        let secret = "SECRET_PROMPT_DO_NOT_KEEP";
        let user = format!(r#"{{"type":"user","message":{{"content":"{secret}"}}}}"#);
        let input = format!(
            "{user}\n{}\n",
            r#"{"type":"assistant","requestId":"r","sessionId":"s","timestamp":"2026-08-01T00:00:00Z","message":{"id":"m","model":"claude-opus-4-5","usage":{"input_tokens":10,"output_tokens":4}}}"#
        );
        let path = PathBuf::from("/tmp/does-not-matter.jsonl");
        let root = PathBuf::from("/tmp/projects");
        let out = claude_code::parse_file(&path, &root, &input);
        assert_eq!(out.events.len(), 1);
        assert_eq!(out.events[0].counters.input_fresh, Some(10));
        let dumped = format!("{:?}", out.events);
        assert!(
            !dumped.contains(secret),
            "parser must not carry conversation text: {dumped}"
        );
        let reading = fold_events(&out.events, &prices()).expect("reading");
        let shown = format!("{reading:?}");
        assert!(
            !shown.contains(secret),
            "reading must not carry conversation text: {shown}"
        );
    }

    #[test]
    fn newest_jsonl_wins_in_a_folder() {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-meter-jsonl-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let older = dir.join("older.jsonl");
        let newer = dir.join("newer.jsonl");
        std::fs::write(&older, "{}\n").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        let mut file = std::fs::File::create(&newer).unwrap();
        file.write_all(b"{}\n").unwrap();
        file.sync_all().unwrap();
        let picked = newest_jsonl(&dir).expect("a jsonl");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(picked.file_name().unwrap(), "newer.jsonl");
    }

    #[test]
    fn grok_events_keep_only_the_named_session() {
        let sessions = HashMap::from([(
            "sess-live".into(),
            grok::SessionMeta {
                model: "grok-4.5".into(),
                project: "tokenstat".into(),
            },
        )]);
        let input = format!(
            "{}\n{}\n",
            r#"{"msg":"shell.turn.inference_done","sid":"sess-live","ts":"2026-08-01T00:00:00Z","ctx":{"loop_index":0,"prompt_tokens":1000,"cached_prompt_tokens":0,"completion_tokens":20,"reasoning_tokens":0}}"#,
            r#"{"msg":"shell.turn.inference_done","sid":"sess-other","ts":"2026-08-01T00:00:01Z","ctx":{"loop_index":0,"prompt_tokens":99999,"cached_prompt_tokens":0,"completion_tokens":9,"reasoning_tokens":0}}"#
        );
        let path = PathBuf::from("/tmp/unified.jsonl");
        let events: Vec<UsageEvent> = grok::parse_file(&path, &input, &sessions)
            .events
            .into_iter()
            .filter(|e| e.session == "sess-live")
            .collect();
        let reading = fold_events(&events, &prices()).expect("reading");
        assert_eq!(reading.tokens, 1_020);
        assert_eq!(reading.model, "grok-4.5");
        assert_eq!(reading.context_used, Some(1_000));
        assert_eq!(reading.context_window, Some(131_072));
    }

    #[test]
    fn unsupported_harnesses_have_no_reading() {
        assert_eq!(harness_name("zsh"), None);
        assert_eq!(harness_name("codex"), None);
        assert_eq!(harness_name("/opt/homebrew/bin/claude"), Some("claude"));
        assert_eq!(harness_name("grok"), Some("grok"));
    }

    #[test]
    fn grok_encodes_a_unix_path_the_way_the_session_dir_is_named() {
        assert_eq!(
            grok_encode("/Users/me/git/tokenstat"),
            "%2FUsers%2Fme%2Fgit%2Ftokenstat"
        );
    }
}
