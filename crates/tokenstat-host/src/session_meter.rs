// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use tokenstat_core::model::{BillingMode, Counters, EventId, SourceId};
use tokenstat_core::pricing::{EquivalentValue, PriceTable, display_usage_model_id};
use tokenstat_core::sources::{
    antigravity_cli, claude_code, codex, devin, dsh, grok, hermes, kilo, kimi, muse, omp, opencode,
    pi, qwen,
};
use tokenstat_core::{Catalog, UsageEvent};

/// What a front end can draw for one live session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MeterReading {
    pub tokens: u64,
    /// Absent when nothing priced. Zero once something did: see `fold`.
    pub cost_micros: Option<i64>,
    pub estimated: bool,
    pub complete: bool,
    /// Whether this session is metered or covered by a subscription. A plan
    /// figure is an equivalent, and the front end must say so.
    pub billing: BillingMode,
    pub model: String,
    /// Last turn's prompt-side tokens. The context bar, not the lifetime sum.
    pub context_used: Option<u64>,
    pub context_window: Option<u64>,
    /// The window came from sibling models, not from a published figure.
    pub context_estimated: bool,
    /// Verified vendor IDs from this PTY's attributed transcript. These stay
    /// on the full terminal route and never enter account usage snapshots.
    pub session_identities: Option<crate::chat_sessions::SessionInventory>,
}

/// Fold a live session's usage into a sidebar reading, when we can find it.
///
/// `started_at_ms` is when the process was spawned. Nothing older than that
/// belongs to it, and a session with nothing newer gets no reading at all.
/// `session_id` is this pty's id. `siblings` is every other live process of
/// the same harness in the same folder, as `(id, started_at_ms)`, so two
/// windows that share a spawn timestamp still claim different logs.
pub(crate) fn reading(
    command: &str,
    cwd: &str,
    session_id: &str,
    started_at_ms: u64,
    siblings: &[(&str, u64)],
) -> Option<MeterReading> {
    if cwd.is_empty() {
        return None;
    }
    let harness = harness_name(command)?;
    let spawn = SpawnMatch {
        id: session_id,
        started_at_ms,
        siblings,
    };
    let mut native_parent = None;
    let events = match harness {
        "claude" => claude_events(cwd, spawn)?,
        "grok" => grok_events(cwd, spawn)?,
        "codex" => codex_events(cwd, spawn)?,
        "opencode" => opencode_events(cwd, spawn)?,
        "kilo" => kilo_events(cwd, spawn)?,
        "hermes" => hermes_events(cwd, spawn)?,
        "pi" => pi_events(cwd, spawn)?,
        "omp" => omp_events(cwd, spawn)?,
        "dsh" => dsh_events(cwd, spawn)?,
        "muse" => {
            let (events, parent_id) = muse_events(cwd, spawn)?;
            native_parent = Some(parent_id);
            events
        }
        "devin" => devin_events(cwd, spawn)?,
        "kimi" => kimi_events(cwd, spawn)?,
        "qwen" => qwen_events(cwd, spawn)?,
        "antigravity" => antigravity_events(cwd, spawn)?,
        _ => return None,
    };
    let mine = since(&events, started_at_ms);
    if mine.is_empty() {
        return None;
    }
    let mut reading = fold(&mine, &current_prices())?;
    reading.session_identities =
        terminal_session_identities(harness, &mine, native_parent.as_deref());

    if harness == "grok" && reading.billing == BillingMode::Unknown {
        reading.billing = grok_billing();
    }
    Some(reading)
}

fn terminal_session_identities(
    harness: &str,
    events: &[&UsageEvent],
    native_parent: Option<&str>,
) -> Option<crate::chat_sessions::SessionInventory> {
    use crate::chat_sessions::{SessionInventory, SessionReference, valid_native_id};
    let backend = if harness == "antigravity" {
        "agy"
    } else {
        harness
    };
    let latest = events
        .iter()
        .filter(|event| native_parent.is_none_or(|parent| event.session == parent))
        .max_by_key(|event| event.ts.utc_ms)?
        .session
        .as_str();
    let mut identities: HashMap<&str, (i64, i64)> = HashMap::new();
    for event in events {
        if native_parent.is_some_and(|parent| event.session != parent)
            || !valid_native_id(backend, &event.session)
        {
            continue;
        }
        identities
            .entry(&event.session)
            .and_modify(|(first, last)| {
                *first = (*first).min(event.ts.utc_ms);
                *last = (*last).max(event.ts.utc_ms);
            })
            .or_insert((event.ts.utc_ms, event.ts.utc_ms));
    }
    if identities.is_empty() {
        return None;
    }
    let total = identities.len() as u64;
    let mut entries: Vec<_> = identities
        .into_iter()
        .map(|(id, (first, last))| SessionReference {
            backend: backend.to_string(),
            id: id.to_string(),
            status: if id == latest {
                "current"
            } else {
                "historical"
            }
            .into(),
            first_seen_at_ms: Some(first),
            last_seen_at_ms: Some(last),
            ..Default::default()
        })
        .collect();
    entries.sort_by(|left, right| {
        right
            .status
            .eq("current")
            .cmp(&left.status.eq("current"))
            .then(right.last_seen_at_ms.cmp(&left.last_seen_at_ms))
            .then(left.id.cmp(&right.id))
    });
    entries.truncate(64);
    Some(SessionInventory {
        truncated: total > entries.len() as u64,
        total,
        entries,
        ..Default::default()
    })
}

fn grok_billing() -> BillingMode {
    let Some(home) = tokenstat_paths::home_dir() else {
        return BillingMode::Unknown;
    };
    let Ok(text) = std::fs::read_to_string(home.join(".grok").join("auth.json")) else {
        return BillingMode::Unknown;
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
        return BillingMode::Unknown;
    };
    let Some(records) = value.as_object() else {
        return BillingMode::Unknown;
    };
    let mut seen = BillingMode::Unknown;
    for record in records.values() {
        match record.get("auth_mode").and_then(|m| m.as_str()) {
            Some("oidc") => return BillingMode::Plan,
            Some(_) => seen = BillingMode::Metered,
            None => {}
        }
    }
    seen
}

const GRACE_MS: i64 = 2_000;

#[derive(Clone, Copy)]
struct SpawnMatch<'a> {
    id: &'a str,
    started_at_ms: u64,
    siblings: &'a [(&'a str, u64)],
}

fn spawn_floor(start: u64) -> i64 {
    i64::try_from(start)
        .unwrap_or(i64::MAX)
        .saturating_sub(GRACE_MS)
}

fn since(events: &[UsageEvent], started_at_ms: u64) -> Vec<&UsageEvent> {
    let floor = spawn_floor(started_at_ms);
    events.iter().filter(|e| e.ts.utc_ms >= floor).collect()
}

fn claim_since<T: Ord>(
    candidates: impl IntoIterator<Item = (i64, T)>,
    spawn: SpawnMatch<'_>,
) -> Option<T> {
    let mut remaining: Vec<(i64, T)> = candidates.into_iter().collect();

    remaining.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    remaining.dedup_by(|a, b| a.1 == b.1);
    remaining.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let mut starts: Vec<(&str, u64, bool)> = spawn
        .siblings
        .iter()
        .map(|(id, started)| (*id, *started, false))
        .collect();
    starts.push((spawn.id, spawn.started_at_ms, true));
    starts.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(b.0)));
    for (_, start, is_self) in starts {
        let floor = spawn_floor(start);
        let Some(idx) = remaining.iter().position(|(born, _)| *born >= floor) else {
            if is_self {
                return None;
            }
            continue;
        };
        let item = remaining.remove(idx);
        if is_self {
            return Some(item.1);
        }
    }
    None
}

#[cfg(test)]
fn earliest_since<T: Ord>(
    candidates: impl IntoIterator<Item = (i64, T)>,
    started_at_ms: u64,
) -> Option<T> {
    claim_since(
        candidates,
        SpawnMatch {
            id: "",
            started_at_ms,
            siblings: &[],
        },
    )
}

fn pick_session(events: Arc<Vec<UsageEvent>>, spawn: SpawnMatch<'_>) -> Arc<Vec<UsageEvent>> {
    let births = named_session_births(&events);
    if births.is_empty() {
        return events;
    }
    pick_named_session(events, births, spawn)
}

fn named_session_births(events: &[UsageEvent]) -> Vec<(i64, String)> {
    let mut born: HashMap<&str, i64> = HashMap::new();
    for event in events {
        let sid = event.session.as_str();
        if sid.is_empty() {
            continue;
        }
        let ts = event.ts.utc_ms;
        born.entry(sid)
            .and_modify(|existing| *existing = (*existing).min(ts))
            .or_insert(ts);
    }
    born.into_iter()
        .map(|(id, at)| (at, id.to_string()))
        .collect()
}

fn pick_named_session(
    events: Arc<Vec<UsageEvent>>,
    births: Vec<(i64, String)>,
    spawn: SpawnMatch<'_>,
) -> Arc<Vec<UsageEvent>> {
    let Some(chosen) = claim_since(births, spawn) else {
        return Arc::new(Vec::new());
    };
    if events.iter().all(|event| event.session == chosen) {
        return events;
    }
    let mine: Vec<UsageEvent> = events
        .iter()
        .filter(|event| event.session == chosen)
        .cloned()
        .collect();
    Arc::new(mine)
}

fn file_born_ms(path: &Path, head: Option<&str>) -> i64 {
    if let Some(head) = head
        && let Some(ms) = first_timestamp_ms(head)
    {
        return ms;
    }
    let Ok(meta) = std::fs::metadata(path) else {
        return 0;
    };
    if let Ok(created) = meta.created() {
        return system_time_ms(created);
    }
    meta.modified().ok().map(system_time_ms).unwrap_or(0)
}

fn system_time_ms(time: SystemTime) -> i64 {
    time.duration_since(SystemTime::UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

fn first_timestamp_ms(head: &str) -> Option<i64> {
    for line in head.lines().take(20) {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        for key in ["timestamp", "time", "ts", "recorded_at"] {
            if let Some(ms) = json_time_ms(&value, key) {
                return Some(ms);
            }
        }
    }
    None
}

fn json_time_ms(value: &serde_json::Value, key: &str) -> Option<i64> {
    let stamp = value.get(key)?;
    if let Some(n) = stamp.as_i64() {
        return Some(if n.unsigned_abs() < 10_000_000_000 {
            n.saturating_mul(1_000)
        } else if n.unsigned_abs() < 10_000_000_000_000 {
            n
        } else {
            n / 1_000
        });
    }
    stamp
        .as_str()?
        .parse::<jiff::Timestamp>()
        .ok()
        .map(|t| t.as_millisecond())
}

/// Sum events into the wire shape. Pure, so tests do not need a home directory.
///
/// Owned slice for the tests, which build their events inline. The live path
/// goes through `fold`, which borrows.
#[cfg(test)]
pub(crate) fn fold_events(events: &[UsageEvent], prices: &PriceTable) -> Option<MeterReading> {
    fold(&events.iter().collect::<Vec<_>>(), prices)
}

fn collapse<'a>(events: &[&'a UsageEvent]) -> Vec<Folded<'a>> {
    let mut order: Vec<EventId> = Vec::with_capacity(events.len());
    let mut by_id: HashMap<EventId, Folded<'a>> = HashMap::with_capacity(events.len());
    for event in events {
        match by_id.get_mut(&event.id) {
            Some(kept) => {
                keep_larger(&mut kept.counters, &event.counters);

                if kept.model.is_empty() || kept.model == "unknown" {
                    kept.model = &event.model;
                }
                if kept.billing == BillingMode::Unknown {
                    kept.billing = event.billing;
                }
            }
            None => {
                order.push(event.id);
                by_id.insert(
                    event.id,
                    Folded {
                        rollup: is_rollup(event),
                        model: &event.model,
                        billing: event.billing,
                        counters: event.counters,
                    },
                );
            }
        }
    }
    order.iter().filter_map(|id| by_id.remove(id)).collect()
}

struct Folded<'a> {
    rollup: bool,
    model: &'a str,
    billing: BillingMode,
    counters: Counters,
}

fn is_rollup(event: &UsageEvent) -> bool {
    match event.source {
        SourceId::Hermes => true,
        SourceId::Codex => event.id == codex::rollup_event_id(&event.session),
        _ => false,
    }
}

fn keep_larger(kept: &mut Counters, seen: &Counters) {
    fn larger(kept: &mut Option<u64>, seen: Option<u64>) {
        if let Some(n) = seen {
            *kept = Some(kept.map_or(n, |k| k.max(n)));
        }
    }
    larger(&mut kept.input_fresh, seen.input_fresh);
    larger(&mut kept.cache_read, seen.cache_read);
    larger(&mut kept.cache_write_5m, seen.cache_write_5m);
    larger(&mut kept.cache_write_1h, seen.cache_write_1h);
    larger(&mut kept.output, seen.output);
}

/// Sum events into the wire shape. Pure, so tests do not need a home directory.
pub(crate) fn fold(events: &[&UsageEvent], prices: &PriceTable) -> Option<MeterReading> {
    if events.is_empty() {
        return None;
    }
    let events = collapse(events);

    let mut tokens = 0u64;
    let mut cost = 0i64;
    let mut priced = 0u32;
    let mut estimated = false;
    let mut complete = true;

    for event in &events {
        tokens = tokens.saturating_add(event.counters.total());
        let lookup = display_usage_model_id(event.model);
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
        .map(|e| e.model.to_string())
        .unwrap_or_default();

    let rollup = events.iter().any(|e| e.rollup);
    let context_used = if rollup {
        None
    } else {
        events
            .iter()
            .rev()
            .map(|e| e.counters.input_total())
            .find(|&n| n > 0)
    };
    let lookup = display_usage_model_id(&model);
    let published = prices
        .catalog()
        .and_then(|c| c.get(&lookup))
        .and_then(|m| m.context_window());

    let context_window = published.or_else(|| {
        prices
            .catalog()
            .and_then(|c| c.sibling_context_window(&lookup))
    });
    let context_estimated = published.is_none() && context_window.is_some();

    let billing = billing_mode(&events);
    Some(MeterReading {
        tokens,
        cost_micros: (priced > 0).then_some(cost),
        estimated,
        complete,
        billing,
        model,
        context_used,
        context_window,
        context_estimated,
        session_identities: None,
    })
}

fn billing_mode(events: &[Folded<'_>]) -> BillingMode {
    if events.iter().any(|e| e.billing == BillingMode::Metered) {
        return BillingMode::Metered;
    }
    if events.iter().any(|e| e.billing == BillingMode::Plan) {
        return BillingMode::Plan;
    }
    BillingMode::Unknown
}

/// Whether this command is one the meter can read **on this machine**.
///
/// Separate from `reading`, which answers only once a turn has been logged.
/// The difference is what lets a fresh session start at zero and count up.
///
/// The store has to exist for that to be honest. A harness that has never
/// written a log here will never produce a reading, and a row that sits at
/// `$0.00` forever is the made-up zero this module refuses everywhere else.
pub(crate) fn can_meter(command: &str) -> bool {
    let Some(harness) = harness_name(command) else {
        return false;
    };
    let Some(home) = tokenstat_paths::home_dir() else {
        return false;
    };
    match harness {
        "claude" => claude_code::discover(&home).is_some(),
        "grok" => grok::discover(&home).is_some(),
        "codex" => !codex::discover_all(&home).is_empty(),
        "opencode" => opencode::discover(&home).is_some(),
        "kilo" => kilo::discover(&home).is_some(),
        "hermes" => hermes::discover(&home).is_some(),
        "pi" => pi::discover(&home).is_some(),
        "omp" => !omp::discover(&home).is_empty(),
        "dsh" => dsh::discover(&home).is_some(),
        "muse" => muse::discover(&home).is_some(),
        "devin" => devin::discover(&home).is_some(),
        "kimi" => kimi::discover(&home).is_some(),
        "qwen" => qwen::discover(&home).is_some(),
        "antigravity" => antigravity_cli::discover(&home).is_some(),
        _ => false,
    }
}

pub(crate) fn harness_name(command: &str) -> Option<&'static str> {
    let name = command.trim().rsplit(['/', '\\']).next().unwrap_or(command);
    let name = name.to_ascii_lowercase();
    let name = name.strip_suffix(".exe").unwrap_or(&name);
    match name {
        "claude" => Some("claude"),
        "grok" => Some("grok"),
        "codex" => Some("codex"),

        "opencode" | "opencode2" => Some("opencode"),

        "kilo" | "kilocode" => Some("kilo"),
        "hermes" => Some("hermes"),
        "pi" => Some("pi"),
        "omp" => Some("omp"),
        "dsh" => Some("dsh"),
        "muse" => Some("muse"),
        "devin" => Some("devin"),
        "kimi" => Some("kimi"),
        "qwen" => Some("qwen"),
        "agy" => Some("antigravity"),
        _ => None,
    }
}

fn codex_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let path = resolve_logs("codex", cwd, spawn, || {
        let home = tokenstat_paths::home_dir()?;
        Some(
            newest_first(
                codex::discover_all(&home)
                    .iter()
                    .flat_map(|sessions| codex::shards(sessions))
                    .collect(),
            )
            .into_iter()
            .filter_map(|path| {
                let head = read_head(&path)?;
                let dir = codex::session_cwd(&head)?;
                (dir == cwd).then(|| (file_born_ms(&path, Some(&head)), path))
            })
            .take(SCAN_LIMIT)
            .collect(),
        )
    })?;
    cached_events(&path, |contents| codex::parse_file(&path, contents).events)
}

fn devin_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let db = devin::discover(&home)?;
    let births = devin::session_births(&db, cwd);
    let floor = spawn_floor(spawn.started_at_ms);
    let scope = format!("{cwd}#{floor}");
    let events = cached_db_events(&db, &scope, |path| {
        devin::parse_db_in(path, Some(cwd), Some(floor)).events
    })?;
    let events = pick_named_session(events, births, spawn);
    (!events.is_empty()).then_some(events)
}

fn kimi_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let root = kimi::discover(&home)?;
    let grouped = kimi::session_wires_for_cwd(&root, cwd);
    let candidates = grouped.iter().filter_map(|(session, wires)| {
        let born = wires
            .iter()
            .map(|path| {
                let head = read_head(path);
                file_born_ms(path, head.as_deref())
            })
            .min()?;
        Some((born, session.clone()))
    });
    let session = claim_since(candidates, spawn)?;
    let wires = grouped
        .into_iter()
        .find(|(id, _)| *id == session)
        .map(|(_, wires)| wires)?;
    let mut all = Vec::new();
    for path in wires {
        if let Some(events) =
            cached_events(&path, |contents| kimi::parse_file(&path, contents).events)
        {
            all.extend(events.iter().cloned());
        }
    }
    (!all.is_empty()).then_some(Arc::new(all))
}

fn qwen_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let root = qwen::discover(&home)?;
    let session_ids: std::collections::HashSet<_> =
        qwen::sessions_for_cwd(&root, cwd).into_iter().collect();
    if session_ids.is_empty() {
        return None;
    }
    let mut all = Vec::new();
    for path in qwen::ledgers(&root) {
        let empty = HashMap::new();
        if let Some(events) = cached_events(&path, |contents| {
            qwen::parse_file(&path, contents, &empty).events
        }) {
            all.extend(
                events
                    .iter()
                    .filter(|event| session_ids.contains(&event.session))
                    .cloned(),
            );
        }
    }
    if all.is_empty() {
        return None;
    }
    let events = pick_session(Arc::new(all), spawn);
    (!events.is_empty()).then_some(events)
}

fn muse_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<(Arc<Vec<UsageEvent>>, String)> {
    let parent = resolve_logs("muse", cwd, spawn, || {
        let home = tokenstat_paths::home_dir()?;
        let sessions = muse::discover(&home)?;
        Some(
            newest_first(muse::shards(&sessions))
                .into_iter()
                .filter_map(|path| {
                    let parent = muse::parent_session_dir(&path)?;
                    if path.parent() != Some(parent) {
                        return None;
                    }
                    let head = read_head(&path)?;
                    let dir = muse::session_workspace(&head)?;
                    (dir == cwd).then(|| (file_born_ms(&path, Some(&head)), parent.to_path_buf()))
                })
                .take(SCAN_LIMIT)
                .collect(),
        )
    })?;
    let parent_id = parent.file_name()?.to_str()?.to_owned();
    let mut all = Vec::new();
    for path in muse::shards(&parent) {
        if let Some(events) =
            cached_events(&path, |contents| muse::parse_file(&path, contents).events)
        {
            all.extend(events.iter().cloned());
        }
    }
    (!all.is_empty()).then_some((Arc::new(all), parent_id))
}

const SCAN_LIMIT: usize = 40;

const RESOLVE_TTL: Duration = Duration::from_secs(5);

struct ResolvedLogs {
    at: Instant,
    paths: Vec<(i64, PathBuf)>,
}

fn resolve_cache() -> &'static Mutex<HashMap<(&'static str, String), ResolvedLogs>> {
    static CACHE: OnceLock<Mutex<HashMap<(&'static str, String), ResolvedLogs>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn resolve_logs(
    harness: &'static str,
    cwd: &str,
    spawn: SpawnMatch<'_>,
    scan: impl FnOnce() -> Option<Vec<(i64, PathBuf)>>,
) -> Option<PathBuf> {
    let key = (harness, cwd.to_string());
    let candidates = if let Ok(guard) = resolve_cache().lock()
        && let Some(hit) = guard.get(&key)
        && hit.at.elapsed() < RESOLVE_TTL
    {
        hit.paths.clone()
    } else {
        let found = scan()
            .unwrap_or_default()
            .into_iter()
            .filter(|(_, path)| path.exists())
            .collect::<Vec<_>>();
        if let Ok(mut guard) = resolve_cache().lock() {
            guard.retain(|_, entry| entry.at.elapsed() < RESOLVE_TTL);
            guard.insert(
                key,
                ResolvedLogs {
                    at: Instant::now(),
                    paths: found.clone(),
                },
            );
        }
        found
    };
    claim_since(candidates, spawn)
}

fn newest_first(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut stamped: Vec<(SystemTime, PathBuf)> = paths
        .into_iter()
        .filter_map(|path| {
            let modified = std::fs::metadata(&path).and_then(|m| m.modified()).ok()?;
            Some((modified, path))
        })
        .collect();
    stamped.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    stamped.into_iter().map(|(_, path)| path).collect()
}

fn read_head(path: &Path) -> Option<String> {
    use std::io::Read;
    const HEAD_BYTES: usize = 64 * 1024;
    let mut buffer = Vec::with_capacity(HEAD_BYTES);
    std::fs::File::open(path)
        .ok()?
        .take(HEAD_BYTES as u64)
        .read_to_end(&mut buffer)
        .ok()?;
    let mut text = String::from_utf8_lossy_owned(buffer);
    if let Some(cut) = text.rfind('\n') {
        text.truncate(cut);
    }
    Some(text)
}

fn opencode_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let db = opencode::discover(&home)?;
    let births = opencode::session_births(&db, cwd);
    let floor = spawn_floor(spawn.started_at_ms);
    let scope = format!("{cwd}#{floor}");
    let events = cached_db_events(&db, &scope, |path| {
        opencode::parse_db_in(path, Some(cwd), Some(floor)).events
    })?;
    let events = pick_named_session(events, births, spawn);
    (!events.is_empty()).then_some(events)
}

fn kilo_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let db = kilo::discover(&home)?;
    let births = kilo::session_births(&db, cwd);
    let floor = spawn_floor(spawn.started_at_ms);
    let scope = format!("{cwd}#{floor}");
    let events = cached_db_events(&db, &scope, |path| {
        kilo::parse_db_in(path, Some(cwd), Some(floor)).events
    })?;
    let events = pick_named_session(events, births, spawn);
    (!events.is_empty()).then_some(events)
}

fn hermes_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let db = hermes::discover(&home)?;
    let floor = spawn_floor(spawn.started_at_ms);
    let scope = format!("{cwd}#{floor}");
    let events = cached_db_events(&db, &scope, |path| {
        hermes::parse_db_in(path, Some(cwd), Some(floor)).events
    })?;
    let events = pick_session(events, spawn);
    (!events.is_empty()).then_some(events)
}

fn pi_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let root = pi::discover(&home)?;
    let dir = root.join(pi_dir_name(cwd));
    let path = resolve_logs("pi", cwd, spawn, || {
        let files = std::fs::read_dir(&dir)
            .ok()?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"));
        Some(
            files
                .map(|path| {
                    let head = read_head(&path);
                    (file_born_ms(&path, head.as_deref()), path)
                })
                .collect(),
        )
    })?;
    let root_for_parse = root.clone();
    cached_events(&path, |contents| {
        pi::parse_file(&path, &root_for_parse, contents).events
    })
}

fn omp_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let roots = omp::discover(&home);
    let path = resolve_logs("omp", cwd, spawn, || {
        let files: Vec<_> = roots
            .iter()
            .flat_map(|root| {
                std::fs::read_dir(root)
                    .into_iter()
                    .flatten()
                    .filter_map(Result::ok)
                    .flat_map(|entry| std::fs::read_dir(entry.path()).into_iter().flatten())
                    .filter_map(Result::ok)
                    .map(|entry| entry.path())
                    .filter(|path| path.extension().and_then(|e| e.to_str()) == Some("jsonl"))
                    .collect::<Vec<_>>()
            })
            .collect();
        Some(
            newest_first(files)
                .into_iter()
                .filter_map(|path| {
                    let head = read_head(&path)?;
                    let matches = head
                        .lines()
                        .find_map(|line| {
                            let row: serde_json::Value = serde_json::from_str(line).ok()?;
                            (row.get("type")?.as_str()? == "session")
                                .then(|| row.get("cwd")?.as_str().map(str::to_owned))
                                .flatten()
                        })
                        .is_some_and(|dir| {
                            dir == cwd
                                || std::fs::canonicalize(&dir)
                                    .ok()
                                    .zip(std::fs::canonicalize(cwd).ok())
                                    .is_some_and(|(a, b)| a == b)
                        });
                    matches.then(|| (file_born_ms(&path, Some(&head)), path))
                })
                .take(SCAN_LIMIT)
                .collect(),
        )
    })?;
    let root = roots.iter().find(|root| path.starts_with(root))?;
    cached_events(&path, |contents| {
        pi::parse_omp_file(&path, root, contents).events
    })
}

fn dsh_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let root = dsh::discover(&home)?;
    let dir = root.join(pi_dir_name(cwd));
    let path = resolve_logs("dsh", cwd, spawn, || {
        let files = std::fs::read_dir(&dir)
            .ok()?
            .filter_map(Result::ok)
            .map(|e| e.path().join("session.jsonl.zstd"));
        Some(
            files
                .filter(|p| p.is_file())
                .map(|path| (file_born_ms(&path, None), path))
                .collect(),
        )
    })?;
    let root_for_parse = root.clone();
    let events = cached_db_events(&path, cwd, move |p| {
        dsh::parse_file(p, &root_for_parse).events
    })?;
    (!events.is_empty()).then_some(events)
}

fn pi_dir_name(cwd: &str) -> String {
    format!("--{}--", cwd.trim_matches('/').replace('/', "-"))
}

fn antigravity_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let path = resolve_logs("antigravity", cwd, spawn, || {
        let home = tokenstat_paths::home_dir()?;
        let root = antigravity_cli::discover(&home)?;
        Some(
            newest_first(antigravity_cli::shards(&root))
                .into_iter()
                .filter(|path| antigravity_cli::workspace_path(path).is_some_and(|dir| dir == cwd))
                .take(SCAN_LIMIT)
                .map(|path| (file_born_ms(&path, None), path))
                .collect(),
        )
    })?;
    cached_db_events(&path, "", |path| antigravity_cli::parse_db(path).events)
}

fn claude_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let projects = claude_code::discover(&home)?;
    let slug: String = cwd
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let dir = projects.join(slug);
    let path = resolve_logs("claude", cwd, spawn, || Some(jsonl_born(&dir)))?;
    cached_events(&path, |contents| {
        claude_code::parse_file(&path, &projects, contents).events
    })
}

fn grok_events(cwd: &str, spawn: SpawnMatch<'_>) -> Option<Arc<Vec<UsageEvent>>> {
    let home = tokenstat_paths::home_dir()?;
    let grok_home = grok::discover(&home)?;
    let encoded = grok_encode(cwd);
    let session_dir = grok_home.join("sessions").join(&encoded);
    let sid = claim_since(child_dirs_born(&session_dir), spawn)?;
    let log = grok::log_path(&grok_home)?;

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
    cwd.bytes()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, b'-' | b'.' | b'_') {
                char::from(c).to_string()
            } else {
                format!("%{c:02X}")
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

fn jsonl_born(dir: &Path) -> Vec<(i64, PathBuf)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension().is_none_or(|ext| ext != "jsonl") {
                return None;
            }
            let Ok(meta) = entry.metadata() else {
                return None;
            };
            if !meta.is_file() {
                return None;
            }
            let head = read_head(&path);
            Some((file_born_ms(&path, head.as_deref()), path))
        })
        .collect()
}

fn child_dirs_born(dir: &Path) -> Vec<(i64, String)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let Ok(meta) = entry.metadata() else {
                return None;
            };
            if !meta.is_dir() {
                return None;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.is_empty() || name.starts_with('.') {
                return None;
            }
            Some((file_born_ms(&entry.path(), None), name))
        })
        .collect()
}

struct CachedParse {
    mtime: SystemTime,
    at: Instant,
    events: Arc<Vec<UsageEvent>>,
}

const LIVE_PARSE_FLOOR: Duration = Duration::from_secs(2);

fn parse_cache() -> &'static Mutex<HashMap<PathBuf, CachedParse>> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, CachedParse>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

const PARSE_CACHE_ENTRIES: usize = 64;

fn cache_parse(key: PathBuf, entry: CachedParse) {
    let Ok(mut guard) = parse_cache().lock() else {
        return;
    };
    guard.insert(key, entry);
    while guard.len() > PARSE_CACHE_ENTRIES {
        let Some(oldest) = guard
            .iter()
            .min_by_key(|(_, cached)| cached.at)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        guard.remove(&oldest);
    }
}

fn cached_events(
    path: &Path,
    parse: impl FnOnce(&str) -> Vec<UsageEvent>,
) -> Option<Arc<Vec<UsageEvent>>> {
    let mtime = path.metadata().ok()?.modified().ok()?;
    if let Ok(mut guard) = parse_cache().lock()
        && let Some(hit) = guard.get_mut(path)
        && hit.mtime == mtime
    {
        hit.at = Instant::now();
        return Some(Arc::clone(&hit.events));
    }
    let contents = std::fs::read_to_string(path).ok()?;
    let events = Arc::new(parse(&contents));
    cache_parse(
        path.to_path_buf(),
        CachedParse {
            mtime,
            at: Instant::now(),
            events: Arc::clone(&events),
        },
    );
    Some(events)
}

fn store_mtime(path: &Path) -> Option<SystemTime> {
    let mut newest = path.metadata().ok()?.modified().ok()?;
    for suffix in ["-wal", "-shm"] {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        if let Ok(m) = PathBuf::from(name).metadata()
            && let Ok(t) = m.modified()
            && t > newest
        {
            newest = t;
        }
    }
    Some(newest)
}

fn cached_db_events(
    path: &Path,
    scope: &str,
    parse: impl FnOnce(&Path) -> Vec<UsageEvent>,
) -> Option<Arc<Vec<UsageEvent>>> {
    let mtime = store_mtime(path)?;
    let key = if scope.is_empty() {
        path.to_path_buf()
    } else {
        path.with_file_name(format!(
            "{}#{scope}",
            path.file_name().unwrap_or_default().to_string_lossy()
        ))
    };

    if let Ok(mut guard) = parse_cache().lock()
        && let Some(hit) = guard.get_mut(&key)
        && (hit.mtime == mtime || hit.at.elapsed() < LIVE_PARSE_FLOOR)
    {
        if hit.mtime == mtime {
            hit.at = Instant::now();
        }
        return Some(Arc::clone(&hit.events));
    }
    let events = Arc::new(parse(path));
    cache_parse(
        key,
        CachedParse {
            mtime,
            at: Instant::now(),
            events: Arc::clone(&events),
        },
    );
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
    if prices_mtime != guard.prices_mtime
        || catalog_mtime != guard.catalog_mtime
        || guard.prices.local_models_stale()
    {
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
            profile_id: None,
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
    fn terminal_native_ids_are_validated_deduplicated_and_ordered_by_observation() {
        let a = "550e8400-e29b-41d4-a716-446655440000";
        let b = "550e8400-e29b-41d4-a716-446655440001";
        let mut first = stamped(100);
        first.session = a.into();
        let mut other = stamped(200);
        other.session = b.into();
        let mut repeated = stamped(300);
        repeated.session = a.into();
        let entries =
            terminal_session_identities("claude", &[&repeated, &first, &other], None).unwrap();
        assert_eq!(entries.total, 2);
        assert!(!entries.truncated);
        assert_eq!(entries.entries[0].id, a);
        assert_eq!(entries.entries[0].status, "current");
        assert_eq!(entries.entries[0].first_seen_at_ms, Some(100));
        assert_eq!(entries.entries[0].last_seen_at_ms, Some(300));
        assert_eq!(entries.entries[1].status, "historical");
        assert!(
            entries
                .entries
                .iter()
                .all(|entry| entry.source_conversation_id.is_none())
        );
        let mut unknown = stamped(400);
        unknown.session = "unknown".into();
        let historic = terminal_session_identities("claude", &[&first, &unknown], None).unwrap();
        assert_eq!(historic.entries[0].status, "historical");
        assert!(terminal_session_identities("claude", &[&unknown], None).is_none());
        assert!(terminal_session_identities("sh", &[&first], None).is_none());
    }

    #[test]
    fn terminal_native_ids_exclude_older_work_and_bound_the_report() {
        let mut old = stamped(0);
        old.session = "550e8400-e29b-41d4-a716-446655440000".into();
        let mut current = stamped(4_000);
        current.session = "550e8400-e29b-41d4-a716-446655440001".into();
        let events = vec![old, current];
        let mine = since(&events, 4_000);
        let identities = terminal_session_identities("claude", &mine, None).unwrap();
        assert_eq!(identities.total, 1);
        assert_eq!(identities.entries[0].id, events[1].session);

        let events: Vec<_> = (0..70)
            .map(|index| {
                let mut event = stamped(index);
                event.session = format!("550e8400-e29b-41d4-a716-{index:012x}");
                event
            })
            .collect();
        let refs: Vec<_> = events.iter().collect();
        let identities = terminal_session_identities("claude", &refs, None).unwrap();
        assert_eq!(identities.total, 70);
        assert_eq!(identities.entries.len(), 64);
        assert!(identities.truncated);
        assert_eq!(identities.entries[0].id, events[69].session);
        assert_eq!(identities.entries[0].status, "current");
        let wire = serde_json::to_value(identities).unwrap();
        assert_eq!(wire["entries"][0]["backend"], "claude");
        assert!(wire["entries"][0].get("sourceConversationId").is_none());
        assert!(wire.get("archivePath").is_none());
    }

    #[test]
    fn muse_terminal_identity_stays_with_parent_when_child_usage_is_newer() {
        let parent_id = "550e8400-e29b-41d4-a716-446655440000";
        let child_id = "550e8400-e29b-41d4-a716-446655440001";
        let mut parent = stamped(100);
        parent.session = parent_id.into();
        let mut child = stamped(200);
        child.session = child_id.into();
        let identities =
            terminal_session_identities("muse", &[&parent, &child], Some(parent_id)).unwrap();
        assert_eq!(identities.total, 1);
        assert_eq!(identities.entries[0].id, parent_id);
        assert_eq!(identities.entries[0].status, "current");
        assert!(terminal_session_identities("muse", &[&child], Some(parent_id)).is_none());
    }

    #[test]
    fn terminal_native_id_limit_keeps_current_when_latest_timestamps_tie() {
        let events: Vec<_> = (0..70)
            .map(|index| {
                let mut event = stamped(1_000);
                event.session = format!("550e8400-e29b-41d4-a716-{index:012x}");
                event
            })
            .collect();
        let refs: Vec<_> = events.iter().collect();
        let identities = terminal_session_identities("claude", &refs, None).unwrap();
        assert!(identities.truncated);
        assert_eq!(identities.entries.len(), 64);
        assert_eq!(identities.entries[0].id, events[69].session);
        assert_eq!(identities.entries[0].status, "current");
    }

    #[test]
    fn a_streamed_request_is_counted_once() {
        let mut first = event("claude-opus-4-5", 10, 1_000, 5);
        first.counters.cache_write_5m = Some(200);
        let mut last = first.clone();
        last.counters.output = Some(120);
        last.ts = Timestamp::from_ms(1_000);

        let once = fold_events(&[last.clone()], &prices()).expect("one row");
        let streamed = fold_events(&[first, last], &prices()).expect("same row twice");

        assert_eq!(streamed.tokens, once.tokens);
        assert_eq!(streamed.cost_micros, once.cost_micros);
        assert_eq!(streamed.tokens, 10 + 1_000 + 200 + 120);
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
        let events = [stamped(59_500)];
        assert_eq!(since(&events, 60_000).len(), 1);
    }

    fn spawn(
        id: &'static str,
        started_at_ms: u64,
        siblings: &'static [(&'static str, u64)],
    ) -> SpawnMatch<'static> {
        SpawnMatch {
            id,
            started_at_ms,
            siblings,
        }
    }

    #[test]
    fn the_earliest_log_after_spawn_wins_not_the_newest() {
        let older = (10_000, PathBuf::from("older.jsonl"));
        let newer = (90_000, PathBuf::from("newer.jsonl"));
        assert_eq!(
            earliest_since([newer.clone(), older.clone()], 9_000).as_deref(),
            Some(Path::new("older.jsonl")),
            "the process that started first owns the first log, not the latest"
        );
        assert_eq!(
            earliest_since([newer, older], 80_000).as_deref(),
            Some(Path::new("newer.jsonl"))
        );
    }

    #[test]
    fn two_spawns_that_both_precede_both_logs_split_them() {
        let older = (20_000, PathBuf::from("a.jsonl"));
        let newer = (30_000, PathBuf::from("b.jsonl"));
        assert_eq!(
            claim_since(
                [older.clone(), newer.clone()],
                spawn("a", 9_000, &[("b", 10_000)])
            )
            .as_deref(),
            Some(Path::new("a.jsonl"))
        );
        assert_eq!(
            claim_since([older, newer], spawn("b", 10_000, &[("a", 9_000)])).as_deref(),
            Some(Path::new("b.jsonl"))
        );
    }

    #[test]
    fn equal_spawn_times_and_births_split_by_id() {
        let older = (20_000, PathBuf::from("a.jsonl"));
        let newer = (20_000, PathBuf::from("b.jsonl"));
        assert_eq!(
            claim_since(
                [older.clone(), newer.clone()],
                spawn("a", 9_000, &[("b", 9_000)])
            )
            .as_deref(),
            Some(Path::new("a.jsonl"))
        );
        assert_eq!(
            claim_since([older, newer], spawn("b", 9_000, &[("a", 9_000)])).as_deref(),
            Some(Path::new("b.jsonl"))
        );
        let first = pick_session(
            Arc::new(vec![
                {
                    let mut e = stamped(20_000);
                    e.session = "sess-a".into();
                    e
                },
                {
                    let mut e = stamped(20_000);
                    e.session = "sess-b".into();
                    e
                },
            ]),
            spawn("a", 9_000, &[("b", 9_000)]),
        );
        let second = pick_session(
            Arc::new(vec![
                {
                    let mut e = stamped(20_000);
                    e.session = "sess-a".into();
                    e
                },
                {
                    let mut e = stamped(20_000);
                    e.session = "sess-b".into();
                    e
                },
            ]),
            spawn("b", 9_000, &[("a", 9_000)]),
        );
        assert_eq!(first[0].session, "sess-a");
        assert_eq!(second[0].session, "sess-b");
    }

    #[test]
    fn a_session_does_not_inherit_a_log_from_before_it_started() {
        let older = (10_000, PathBuf::from("older.jsonl"));
        assert!(
            earliest_since([older], 60_000).is_none(),
            "a later process has no reading until it writes its own log"
        );
    }

    #[test]
    fn database_rows_from_a_later_sibling_are_dropped() {
        let mut older = stamped(10_000);
        older.session = "sess-a".into();
        older.counters.input_fresh = Some(100);
        older.counters.output = Some(10);
        let mut newer = stamped(90_000);
        newer.session = "sess-b".into();
        newer.counters.input_fresh = Some(99_000);
        newer.counters.output = Some(9);
        let picked = pick_session(
            Arc::new(vec![older.clone(), newer.clone()]),
            spawn("a", 9_000, &[]),
        );
        assert_eq!(picked.len(), 1);
        assert_eq!(picked[0].session, "sess-a");
        let later = pick_session(
            Arc::new(vec![older.clone(), newer.clone()]),
            spawn("b", 80_000, &[]),
        );
        assert_eq!(later.len(), 1);
        assert_eq!(later[0].session, "sess-b");

        let mut older_again = stamped(82_000);
        older_again.session = "sess-a".into();
        older_again.counters.input_fresh = Some(200);
        older_again.counters.output = Some(20);
        let births = vec![(10_000, "sess-a".into()), (90_000, "sess-b".into())];
        let floored = Arc::new(vec![older_again, newer.clone()]);
        let named = pick_named_session(floored, births, spawn("b", 80_000, &[]));
        assert_eq!(named.len(), 1);
        assert_eq!(named[0].session, "sess-b");
        let first = pick_session(
            Arc::new(vec![older.clone(), newer.clone()]),
            spawn("a", 9_000, &[("b", 10_000)]),
        );
        let second = pick_session(
            Arc::new(vec![older.clone(), newer]),
            spawn("b", 10_000, &[("a", 9_000)]),
        );
        assert_eq!(first[0].session, "sess-a");
        assert_eq!(second[0].session, "sess-b");
        let only_first = pick_session(
            Arc::new(vec![older.clone()]),
            spawn("a", 9_000, &[("b", 10_000)]),
        );
        let later_empty = pick_session(Arc::new(vec![older]), spawn("b", 10_000, &[("a", 9_000)]));
        assert_eq!(only_first[0].session, "sess-a");
        assert!(
            later_empty.is_empty(),
            "a later window does not inherit the only log"
        );
    }

    #[test]
    fn muse_recorded_at_microseconds_are_session_birth() {
        let head = r#"{"recorded_at":1788257844312475,"payload":{}}"#;
        assert_eq!(first_timestamp_ms(head), Some(1_788_257_844_312));
    }

    #[test]
    fn sums_tokens_and_list_rate_across_turns() {
        let events = [
            event("claude-opus-4-5", 1_000, 0, 100),
            event("claude-opus-4-5", 2_000, 0, 200),
        ];
        let reading = fold_events(&events, &prices()).expect("reading");
        assert_eq!(reading.tokens, 3_300);

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
    fn hermes_rollup_rows_do_not_feed_a_context_bar() {
        let mut e = event("grok-composer-2.5-fast", 328_000, 4_962_304, 44_969);
        e.source = SourceId::Hermes;
        let reading = fold_events(&[e], &prices()).expect("reading");
        assert_eq!(reading.context_used, None);
        assert_eq!(reading.tokens, 328_000 + 4_962_304 + 44_969);
    }

    #[test]
    fn codex_rollup_rows_do_not_feed_a_context_bar_but_per_turn_rows_do() {
        let mut rollup = event("gpt-5.4-codex", 300_000, 1_200_000, 20_000);
        rollup.source = SourceId::Codex;
        rollup.id = codex::rollup_event_id(&rollup.session);
        let reading = fold_events(&[rollup], &prices()).expect("reading");
        assert_eq!(reading.context_used, None);
        assert_eq!(reading.tokens, 300_000 + 1_200_000 + 20_000);

        let mut turn = event("gpt-5.4-codex", 1_000, 5_000, 200);
        turn.source = SourceId::Codex;
        let reading = fold_events(&[turn], &prices()).expect("reading");
        assert_eq!(reading.context_used, Some(6_000));
    }

    #[test]
    fn missing_catalog_window_keeps_the_used_figure() {
        let bare = PriceTable::parse(BOOK).expect("book");
        let reading = fold_events(&[event("claude-opus-4-5", 100, 0, 10)], &bare).expect("reading");
        assert_eq!(reading.context_used, Some(100));
        assert_eq!(reading.context_window, None);
        assert!(!reading.context_estimated);
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
    fn a_priced_session_reports_zero_rather_than_nothing() {
        let free = PriceTable::parse(
            r#"{"effective_from":"2026-08-01","models":[
                 {"match":"free","input":0,"output":0,"cache_read":0,"cache_write_5m":0,"cache_write_1h":0}
               ]}"#,
        )
        .expect("book");
        let reading = fold_events(&[event("free", 100, 0, 10)], &free).expect("reading");
        assert_eq!(reading.tokens, 110);
        assert_eq!(reading.cost_micros, Some(0));
    }

    #[test]
    fn a_model_the_catalog_missed_borrows_its_siblings_window() {
        let table = PriceTable::parse(BOOK)
            .expect("book")
            .with_catalog(Arc::new(
                Catalog::parse(
                    r#"{"effective_from":"2026-08-01","models":[
                     {"id":"xai/grok-4.5","aliases":["grok-4.5"],"ctx":1000000},
                     {"id":"xai/grok-4.3","aliases":["grok-4.3"],"ctx":1000000},
                     {"id":"xai/grok-4","aliases":["grok-4"],"ctx":256000}
                   ]}"#,
                )
                .expect("catalog"),
            ));
        let reading = fold_events(&[event("grok-4.6", 5_000, 0, 100)], &table).expect("reading");
        assert_eq!(reading.context_used, Some(5_000));
        assert_eq!(reading.context_window, Some(1_000_000), "the family's mode");
        assert!(reading.context_estimated, "and it says so");
    }

    #[test]
    fn a_published_window_is_never_marked_as_an_estimate() {
        let reading =
            fold_events(&[event("claude-opus-4-5", 1_000, 0, 10)], &prices()).expect("reading");
        assert_eq!(reading.context_window, Some(200_000));
        assert!(!reading.context_estimated);
    }

    #[test]
    fn one_metered_event_makes_the_session_metered() {
        let mut plan = event("claude-opus-4-5", 100, 0, 10);
        plan.billing = BillingMode::Plan;
        let mut metered = event("claude-opus-4-5", 200, 0, 20);
        metered.billing = BillingMode::Metered;
        let reading = fold_events(&[plan.clone(), metered], &prices()).expect("reading");
        assert_eq!(reading.billing, BillingMode::Metered);
        let plan_only = fold_events(&[plan], &prices()).expect("reading");
        assert_eq!(plan_only.billing, BillingMode::Plan);
    }

    #[test]
    fn an_unpriceable_session_still_has_no_cost() {
        let reading =
            fold_events(&[event("mystery-model", 400, 0, 20)], &prices()).expect("reading");
        assert_eq!(reading.cost_micros, None, "never a made-up zero");
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
    fn jsonl_in_a_folder_is_matched_by_spawn_not_newest() {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-meter-jsonl-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("older.jsonl"), "{\"timestamp\":10}\n").unwrap();
        std::fs::write(dir.join("newer.jsonl"), "{\"timestamp\":90}\n").unwrap();
        let first = earliest_since(jsonl_born(&dir), 9_000).expect("first log");
        let second = earliest_since(jsonl_born(&dir), 80_000).expect("second log");
        let none = earliest_since(jsonl_born(&dir), 200_000);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(first.file_name().unwrap(), "older.jsonl");
        assert_eq!(second.file_name().unwrap(), "newer.jsonl");
        assert!(
            none.is_none(),
            "a later process has no log until it writes one"
        );
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
    fn pi_names_a_folders_directory_the_way_pi_does() {
        assert_eq!(pi_dir_name("/Users/x/git/demo"), "--Users-x-git-demo--");
        assert_eq!(pi_dir_name("/private/tmp"), "--private-tmp--");

        assert_eq!(pi_dir_name("/Users/x/git/"), "--Users-x-git--");
    }

    #[test]
    fn the_deepseek_harness_spells_a_folder_the_same_way() {
        assert_eq!(
            pi_dir_name("/Users/gyorgy/git/tokenstat"),
            "--Users-gyorgy-git-tokenstat--"
        );
    }

    #[test]
    fn unsupported_harnesses_have_no_reading() {
        assert_eq!(harness_name("zsh"), None);
        assert_eq!(harness_name("cline"), None);
        assert_eq!(harness_name("/opt/homebrew/bin/claude"), Some("claude"));
        assert_eq!(harness_name("grok"), Some("grok"));
    }

    #[test]
    fn every_harness_with_a_local_log_is_metered() {
        assert_eq!(harness_name("codex"), Some("codex"));
        assert_eq!(harness_name("/usr/local/bin/opencode"), Some("opencode"));
        assert_eq!(harness_name("opencode2"), Some("opencode"));

        assert_eq!(harness_name("kilo"), Some("kilo"));
        assert_eq!(harness_name("kilocode"), Some("kilo"));
        assert_eq!(harness_name("hermes"), Some("hermes"));
        assert_eq!(harness_name("pi"), Some("pi"));
        assert_eq!(harness_name("dsh"), Some("dsh"));
        assert_eq!(harness_name("agy"), Some("antigravity"));
    }

    #[test]
    fn a_head_read_stops_at_a_line_boundary() {
        let dir = std::env::temp_dir().join(format!("tokenstat-head-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("rollout.jsonl");
        let mut file = std::fs::File::create(&path).expect("create");
        writeln!(file, "{{\"a\":1}}").expect("write");
        writeln!(file, "{{\"b\":2}}").expect("write");
        writeln!(file, "{}", "x".repeat(200_000)).expect("write");
        drop(file);
        let head = read_head(&path).expect("head");
        assert!(head.len() < 100_000, "reads a bounded head, not the file");
        assert!(head.starts_with("{\"a\":1}"));
        assert!(!head.ends_with('x'), "cut at a line boundary");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_wal_write_moves_the_store_mtime() {
        let dir = std::env::temp_dir().join(format!("tokenstat-wal-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let db = dir.join("opencode.db");
        std::fs::write(&db, b"db").expect("write db");
        let checkpointed = store_mtime(&db).expect("mtime");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(dir.join("opencode.db-wal"), b"turn").expect("write wal");
        let after_turn = store_mtime(&db).expect("mtime");
        assert!(
            after_turn > checkpointed,
            "a turn written to the wal is a change to the store"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_resolved_log_is_not_rescanned_on_the_next_poll() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static SCANS: AtomicUsize = AtomicUsize::new(0);
        let cwd = format!("/tmp/resolve-test-{}", std::process::id());
        let scan = || {
            SCANS.fetch_add(1, Ordering::Relaxed);
            None
        };

        assert_eq!(resolve_logs("codex", &cwd, spawn("a", 1, &[]), scan), None);
        assert_eq!(resolve_logs("codex", &cwd, spawn("a", 1, &[]), scan), None);
        assert_eq!(resolve_logs("codex", &cwd, spawn("a", 1, &[]), scan), None);
        assert_eq!(SCANS.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn a_codex_rollout_names_the_folder_it_was_recorded_in() {
        let rollout = concat!(
            r#"{"type":"session_meta","timestamp":"2026-08-01T00:00:00Z","payload":{"type":"session_meta","id":"s1","cwd":"/Users/me/git/tokenstat"}}"#,
            "\n",
            r#"{"type":"event_msg","timestamp":"2026-08-01T00:00:01Z","payload":{"type":"token_count","info":{}}}"#,
        );
        assert_eq!(
            codex::session_cwd(rollout).as_deref(),
            Some("/Users/me/git/tokenstat")
        );

        assert_eq!(codex::session_cwd("{\"type\":\"event_msg\"}"), None);
    }

    #[test]
    fn session_matching_handles_duplicate_logs_and_extreme_timestamps() {
        assert_eq!(
            claim_since(
                [(20_000, "a"), (21_000, "a"), (30_000, "b")],
                spawn("second", 10_000, &[("first", 9_000)])
            ),
            Some("b")
        );
        assert!(since(&[stamped(0)], u64::MAX).is_empty());
        assert_eq!(
            json_time_ms(&serde_json::json!({"ts": i64::MIN}), "ts"),
            Some(i64::MIN / 1_000)
        );
        assert_eq!(harness_name(r"C:\Tools\CODEX.EXE"), Some("codex"));
        assert_eq!(grok_encode("/été"), "%2F%C3%A9t%C3%A9");
    }

    #[test]
    fn grok_encodes_a_unix_path_the_way_the_session_dir_is_named() {
        assert_eq!(
            grok_encode("/Users/me/git/tokenstat"),
            "%2FUsers%2Fme%2Fgit%2Ftokenstat"
        );
    }
}
