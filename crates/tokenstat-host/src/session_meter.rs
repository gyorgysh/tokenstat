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
//! Every harness that writes a local log naming its folder is metered:
//! Claude, Grok, Codex, OpenCode and Antigravity. Each supplies a locator
//! that answers "which log is this folder's", and they share one `fold`.
//! A harness whose log cannot say which folder it belongs to keeps CPU · RAM
//! rather than being given somebody else's numbers.
//!
//! Two sessions of the same harness in one folder share the newest log: that
//! is a known limitation, not a guess dressed up as identity.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use tokenstat_core::model::{BillingMode, Counters, EventId, SourceId};
use tokenstat_core::pricing::{EquivalentValue, PriceTable, display_usage_model_id};
use tokenstat_core::sources::{
    antigravity_cli, claude_code, codex, dsh, grok, hermes, kilo, opencode, pi,
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
}

/// Fold a live session's usage into a sidebar reading, when we can find it.
///
/// `started_at_ms` is when the process was spawned. Nothing older than that
/// belongs to it, and a session with nothing newer gets no reading at all.
pub(crate) fn reading(command: &str, cwd: &str, started_at_ms: u64) -> Option<MeterReading> {
    if cwd.is_empty() {
        return None;
    }
    let harness = harness_name(command)?;
    let events = match harness {
        "claude" => claude_events(cwd)?,
        "grok" => grok_events(cwd)?,
        "codex" => codex_events(cwd)?,
        "opencode" => opencode_events(cwd, started_at_ms)?,
        "kilo" => kilo_events(cwd, started_at_ms)?,
        "hermes" => hermes_events(cwd, started_at_ms)?,
        "pi" => pi_events(cwd)?,
        "dsh" => dsh_events(cwd)?,
        "antigravity" => antigravity_events(cwd)?,
        _ => return None,
    };
    let mine = since(&events, started_at_ms);
    if mine.is_empty() {
        return None;
    }
    let mut reading = fold(&mine, &current_prices())?;
    // Grok's own log says nothing about how the session is paid for, but the
    // login it runs under does: an OIDC login is a SuperGrok subscription, an
    // API key is metered. Read, never written, and no token leaves this call.
    if harness == "grok" && reading.billing == BillingMode::Unknown {
        reading.billing = grok_billing();
    }
    Some(reading)
}

/// Whether the Grok CLI on this machine is signed in to a subscription.
///
/// `auth.json` holds one record per issuer with an `auth_mode`. `oidc` is the
/// SuperGrok sign-in; anything else is a key the person pasted, which bills.
/// An unreadable or absent file is `Unknown`, not a guess in either direction.
fn grok_billing() -> BillingMode {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
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

/// How far before the spawn a turn still counts as this session's.
///
/// The harness stamps the turn and the daemon stamps the spawn, and they are
/// not the same clock. Used by the in-memory filter and by the sources that
/// can push the same floor down into their own query.
const GRACE_MS: i64 = 2_000;

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

/// Collapse events that are the same request seen more than once.
///
/// A transcript is not a list of requests, it is a list of rows, and one
/// request is written many times while it streams: the prompt side is fixed
/// and `output_tokens` grows. The archive never sees that, because the store
/// upserts on the event id and keeps the larger counter per field, so a
/// duplicate updates a row instead of adding one. The meter reads the same
/// parsers and never goes near the store, so without this it charged a
/// session once per row and read roughly double what the harness itself
/// reports. Same key, same rule: highest wins per field, `None` is absent
/// rather than zero.
///
/// First-seen order is kept, so the model and the context figure still come
/// from the newest turn.
///
/// Borrowed, like `since`: this runs for every live session on every
/// `pty.list` poll, so a merged request carries the strings it needs by
/// reference rather than cloning a long session's events to read them once.
fn collapse<'a>(events: &[&'a UsageEvent]) -> Vec<Folded<'a>> {
    let mut order: Vec<EventId> = Vec::with_capacity(events.len());
    let mut by_id: HashMap<EventId, Folded<'a>> = HashMap::with_capacity(events.len());
    for event in events {
        match by_id.get_mut(&event.id) {
            Some(kept) => {
                keep_larger(&mut kept.counters, &event.counters);
                // A row that streamed a model or a billing mode the first one
                // lacked is still this request. Later rows win where they say
                // something, never where they say nothing.
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

/// One request after the rows that streamed it have been merged.
struct Folded<'a> {
    /// A session running total rather than one turn: see `is_rollup`.
    rollup: bool,
    model: &'a str,
    billing: BillingMode,
    counters: Counters,
}

/// Whether this row is a session running total rather than one turn's usage.
///
/// Hermes only ever writes one, per session+model+task. Codex writes per
/// request deltas until they disagree with the vendor's own total, and then
/// replaces them with a single cumulative row. Either way the input side is
/// the session's whole prompt history, so it cannot stand in for the live
/// context.
fn is_rollup(event: &UsageEvent) -> bool {
    match event.source {
        SourceId::Hermes => true,
        SourceId::Codex => event.id == codex::rollup_event_id(&event.session),
        _ => false,
    }
}

/// Per-field maximum, mirroring the store's `ON CONFLICT` update.
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

    // A rollup row carries the session's running total, not a per-turn prompt.
    // Hermes writes nothing else, and it persists no live context figure at
    // all: the `124K / 200K` its own `/usage` prints is in-session state that
    // never reaches `state.db`. Codex falls back to one when its deltas
    // disagree with the vendor's total. The "last event's input_total" below is
    // then the whole session's cumulative prompt (input + cache_read), which
    // makes a context bar read as hundreds of percent. Withhold it rather than
    // show a number that is meaningless as a context fill.
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
    // A model the snapshot has not caught up with used to cost the bar
    // outright: `context_used` was thrown away whenever the window was
    // missing, so a Grok 4.6 session showed a lifetime token count and
    // nothing else. The used figure stands on its own, and a sibling window
    // is a marked estimate rather than a silent one.
    let context_window = published.or_else(|| {
        prices
            .catalog()
            .and_then(|c| c.sibling_context_window(&lookup))
    });
    let context_estimated = published.is_none() && context_window.is_some();

    // Zero is an answer once something priced: a session that has run a turn
    // costs what it costs, and $0.00 counting up reads as a meter where an
    // absent figure that later appears at $7.98 reads as a surprise. Nothing
    // priced at all is still nothing, never a made-up zero.
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
    })
}

/// How this session is paid for, from the events themselves.
///
/// Metered wins over plan: a session that billed one request per token is not
/// covered, whatever the rest of it says.
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
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return false;
    };
    match harness {
        "claude" => claude_code::discover(&home).is_some(),
        "grok" => grok::discover(&home).is_some(),
        "codex" => codex::discover(&home).is_some(),
        "opencode" => opencode::discover(&home).is_some(),
        "kilo" => kilo::discover(&home).is_some(),
        "hermes" => hermes::discover(&home).is_some(),
        "pi" => pi::discover(&home).is_some(),
        "dsh" => dsh::discover(&home).is_some(),
        "antigravity" => antigravity_cli::discover(&home).is_some(),
        _ => false,
    }
}

fn harness_name(command: &str) -> Option<&'static str> {
    let name = command.rsplit('/').next().unwrap_or(command).trim();
    match name {
        "claude" => Some("claude"),
        "grok" => Some("grok"),
        "codex" => Some("codex"),
        // The launcher ships a second OpenCode tile for a side-by-side
        // install. Same logs, same database, so the same reader.
        "opencode" | "opencode2" => Some("opencode"),
        // Kilo Code forked OpenCode but keeps its own database, so it is its
        // own harness here rather than another name for that one.
        "kilo" | "kilocode" => Some("kilo"),
        "hermes" => Some("hermes"),
        "pi" => Some("pi"),
        "dsh" => Some("dsh"),
        "agy" => Some("antigravity"),
        _ => None,
    }
}

/// The Codex rollout for this folder, if one has been written.
///
/// A rollout says which directory it was recorded in, so the match is the
/// folder itself rather than a label. Newest first, and only the head of each
/// candidate is read: the answer is on a rollout's first records and the file
/// itself can be tens of megabytes.
///
/// The scan is memoised. This runs from `pty.info`, which a focused session
/// polls four times a second, and answering it by reading every rollout each
/// time would be hundreds of megabytes a second on a machine with a year of
/// them. See `resolve_log`.
fn codex_events(cwd: &str) -> Option<Arc<Vec<UsageEvent>>> {
    let path = resolve_log("codex", cwd, || {
        let home = std::env::var_os("HOME").map(PathBuf::from)?;
        let sessions = codex::discover(&home)?;
        newest_first(codex::shards(&sessions))
            .into_iter()
            .take(SCAN_LIMIT)
            .find(|path| {
                read_head(path)
                    .and_then(|head| codex::session_cwd(&head))
                    .is_some_and(|dir| dir == cwd)
            })
    })?;
    cached_events(&path, |contents| codex::parse_file(&path, contents).events)
}

/// How many logs a locator will look at before giving up.
///
/// The list is newest first, so a session's own log is at the front in every
/// realistic case. The cap is what stops a folder with no log at all from
/// paying for the whole history on the way to saying so.
const SCAN_LIMIT: usize = 40;

/// How long a resolved (or absent) log stays trusted.
///
/// Long enough that a 4Hz poll scans at most once per interval, short enough
/// that a session whose first turn has just been written starts reporting
/// within a few seconds of it.
const RESOLVE_TTL: Duration = Duration::from_secs(5);

struct ResolvedLog {
    at: Instant,
    path: Option<PathBuf>,
}

fn resolve_cache() -> &'static Mutex<HashMap<(&'static str, String), ResolvedLog>> {
    static CACHE: OnceLock<Mutex<HashMap<(&'static str, String), ResolvedLog>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Which log belongs to this folder, scanned at most once per `RESOLVE_TTL`.
///
/// A miss is cached too, and deliberately: a folder the harness has never been
/// used in is the case that would otherwise scan everything on every poll and
/// find nothing every time.
fn resolve_log(
    harness: &'static str,
    cwd: &str,
    scan: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    let key = (harness, cwd.to_string());
    if let Ok(guard) = resolve_cache().lock()
        && let Some(hit) = guard.get(&key)
        && hit.at.elapsed() < RESOLVE_TTL
    {
        return hit.path.clone();
    }
    let found = scan();
    // A path that has since been deleted is not an answer. Cheaper to check
    // here than to let a stale hit send the parser at a missing file.
    let found = found.filter(|path| path.exists());
    if let Ok(mut guard) = resolve_cache().lock() {
        guard.insert(
            key,
            ResolvedLog {
                at: Instant::now(),
                path: found.clone(),
            },
        );
    }
    found
}

/// Paths sorted by modification time, newest first. Unreadable entries drop.
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

/// The first part of a file, as text.
///
/// Enough for the records that name a session's folder, and bounded so that
/// asking a 40 MB rollout which directory it belongs to costs 64 KB. Cut at
/// the last newline so the caller never sees half a JSON object.
fn read_head(path: &Path) -> Option<String> {
    use std::io::Read;
    const HEAD_BYTES: usize = 64 * 1024;
    let mut buffer = Vec::with_capacity(HEAD_BYTES);
    std::fs::File::open(path)
        .ok()?
        .take(HEAD_BYTES as u64)
        .read_to_end(&mut buffer)
        .ok()?;
    let text = String::from_utf8_lossy(&buffer).into_owned();
    match text.rfind('\n') {
        Some(cut) => Some(text[..cut].to_string()),
        None => Some(text),
    }
}

/// OpenCode's database, read for one folder since this session started.
///
/// Both narrowings are SQL. One database holds every folder this machine has
/// ever opened and reaches gigabytes: on a working Mac one folder is 3,700
/// messages and 12 MB of JSON, all but a handful of it older than the session
/// asking. Reading it whole four times a second is what this avoids.
fn opencode_events(cwd: &str, started_at_ms: u64) -> Option<Arc<Vec<UsageEvent>>> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let db = opencode::discover(&home)?;
    let floor = started_at_ms as i64 - GRACE_MS;
    let scope = format!("{cwd}#{floor}");
    let events = cached_db_events(&db, &scope, |path| {
        opencode::parse_db_in(path, Some(cwd), Some(floor)).events
    })?;
    (!events.is_empty()).then_some(events)
}

/// Kilo Code's database, narrowed the same way OpenCode's is. Same schema,
/// same reason for the narrowing.
fn kilo_events(cwd: &str, started_at_ms: u64) -> Option<Arc<Vec<UsageEvent>>> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let db = kilo::discover(&home)?;
    let floor = started_at_ms as i64 - GRACE_MS;
    let scope = format!("{cwd}#{floor}");
    let events = cached_db_events(&db, &scope, |path| {
        kilo::parse_db_in(path, Some(cwd), Some(floor)).events
    })?;
    (!events.is_empty()).then_some(events)
}

/// Hermes's state database, for this folder since this session started.
///
/// Its rows are running totals rather than per-call records, so a reading here
/// is the session's total so far rather than a sum of turns. That is the same
/// number either way while only one session of it is running in a folder,
/// which is the case the meter is for.
fn hermes_events(cwd: &str, started_at_ms: u64) -> Option<Arc<Vec<UsageEvent>>> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let db = hermes::discover(&home)?;
    let floor = started_at_ms as i64 - GRACE_MS;
    let scope = format!("{cwd}#{floor}");
    let events = cached_db_events(&db, &scope, |path| {
        hermes::parse_db_in(path, Some(cwd), Some(floor)).events
    })?;
    (!events.is_empty()).then_some(events)
}

/// Pi's newest session log for this folder.
///
/// Pi files sessions under a directory named after the folder, so the folder
/// is found by name rather than by reading heads: `/Users/x/git/demo` is
/// `--Users-x-git-demo--`. That encoding is lossy in the other direction, so
/// this only ever goes forwards, from the folder we already know to the
/// directory it must be in.
fn pi_events(cwd: &str) -> Option<Arc<Vec<UsageEvent>>> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let root = pi::discover(&home)?;
    let dir = root.join(pi_dir_name(cwd));
    let path = resolve_log("pi", cwd, || {
        let files = std::fs::read_dir(&dir)
            .ok()?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"))
            .collect();
        newest_first(files).into_iter().next()
    })?;
    let root_for_parse = root.clone();
    cached_events(&path, |contents| {
        pi::parse_file(&path, &root_for_parse, contents).events
    })
}

/// The DeepSeek Harness transcript for this folder, newest session first.
///
/// Its sessions live one folder deeper than Pi's (`<encoded>/session-<uuid>/`)
/// and the file is compressed, so the parser opens it rather than being handed
/// text. Small enough to decompress on a poll: a long session is tens of
/// kilobytes.
fn dsh_events(cwd: &str) -> Option<Arc<Vec<UsageEvent>>> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let root = dsh::discover(&home)?;
    let dir = root.join(pi_dir_name(cwd));
    let path = resolve_log("dsh", cwd, || {
        let files = std::fs::read_dir(&dir)
            .ok()?
            .filter_map(Result::ok)
            .map(|e| e.path().join("session.jsonl.zstd"))
            .filter(|p| p.is_file())
            .collect();
        newest_first(files).into_iter().next()
    })?;
    let root_for_parse = root.clone();
    let events = cached_db_events(&path, cwd, move |p| {
        dsh::parse_file(p, &root_for_parse).events
    })?;
    (!events.is_empty()).then_some(events)
}

/// How Pi and the DeepSeek Harness spell a folder as a directory name. The two
/// encode it the same way; only the depth below it differs.
fn pi_dir_name(cwd: &str) -> String {
    format!("--{}--", cwd.trim_matches('/').replace('/', "-"))
}

/// The Antigravity conversation whose workspace is this folder.
///
/// One database per conversation, each naming its workspace as a `file://`
/// URI. Newest first, because a folder can have several and the live one is
/// the one being written. Memoised like the Codex scan: opening forty SQLite
/// databases four times a second to answer one question is not a poll, it is
/// a load test.
fn antigravity_events(cwd: &str) -> Option<Arc<Vec<UsageEvent>>> {
    let path = resolve_log("antigravity", cwd, || {
        let home = std::env::var_os("HOME").map(PathBuf::from)?;
        let root = antigravity_cli::discover(&home)?;
        newest_first(antigravity_cli::shards(&root))
            .into_iter()
            .take(SCAN_LIMIT)
            .find(|path| antigravity_cli::workspace_path(path).is_some_and(|dir| dir == cwd))
    })?;
    cached_db_events(&path, "", |path| antigravity_cli::parse_db(path).events)
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
    /// When this parse ran, for stores that are written to continuously.
    at: Instant,
    events: Arc<Vec<UsageEvent>>,
}

/// The shortest a parse of a live store is trusted, whatever its mtime says.
///
/// A database being written to by the session being measured changes on every
/// poll, so mtime alone caches nothing at exactly the moment it matters. Two
/// seconds is what the price book already uses for the same reason.
const LIVE_PARSE_FLOOR: Duration = Duration::from_secs(2);

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
                at: Instant::now(),
                events: Arc::clone(&events),
            },
        );
    }
    Some(events)
}

/// When a SQLite store was last written, sidecars included.
///
/// This is why OpenCode 2 kept reporting `0% ctx · $0.00 · 0k`. The database
/// runs in WAL mode, so a turn lands in `opencode.db-wal` and the database
/// file itself does not change until a checkpoint, hours later. The cache
/// compared the database file's mtime, found it equal every time, and served
/// the parse it made when the session was still empty for the whole life of
/// that session. Taking the newest of the database and its `-wal` and `-shm`
/// sidecars makes "has this changed" mean what the cache assumed it meant.
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

/// The same cache, for a source that is read by path rather than as text.
///
/// A SQLite database cannot be handed to a parser as a string, and OpenCode's
/// holds every folder this machine has opened, so the key carries the
/// directory the rows were filtered to as well as the file.
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
    // Mtime **or** recency. A store the measured session is writing to changes
    // on every poll, so mtime alone stops being a cache at the one moment the
    // meter is actually being watched.
    if let Ok(guard) = parse_cache().lock()
        && let Some(hit) = guard.get(&key)
        && (hit.mtime == mtime || hit.at.elapsed() < LIVE_PARSE_FLOOR)
    {
        return Some(Arc::clone(&hit.events));
    }
    let events = Arc::new(parse(path));
    if let Ok(mut guard) = parse_cache().lock() {
        guard.insert(
            key,
            CachedParse {
                mtime,
                at: Instant::now(),
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

    /// The trap the archive avoids in SQL and the meter used to walk into: a
    /// streaming request is written once per chunk, so summing rows charges a
    /// session twice for one turn.
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
    fn hermes_rollup_rows_do_not_feed_a_context_bar() {
        // Hermes stores one running total per session+model+task, so its last
        // row's input_total is the whole session's cumulative prompt (input +
        // cache_read ≈ its "Prompt tokens (total)"), not the live context. The
        // in-session `124K / 200K` it prints is never persisted, so there is no
        // honest bar to draw: withhold `context_used` rather than show hundreds
        // of percent. Tokens and cost still accumulate from the same rows.
        let mut e = event("grok-composer-2.5-fast", 328_000, 4_962_304, 44_969);
        e.source = SourceId::Hermes;
        let reading = fold_events(&[e], &prices()).expect("reading");
        assert_eq!(reading.context_used, None);
        assert_eq!(reading.tokens, 328_000 + 4_962_304 + 44_969);
    }

    #[test]
    fn codex_rollup_rows_do_not_feed_a_context_bar_but_per_turn_rows_do() {
        // When codex's per-request deltas disagree with the vendor's running
        // total, the parser replaces them with one cumulative row. That row is
        // the same shape as a Hermes one, so it must be withheld from the bar
        // for the same reason. An ordinary codex turn is unaffected.
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
        // No catalog at all: no window to draw a bar against, but what the
        // last turn sent is still known and still worth saying.
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
        // Priced at zero is a figure. An absent one that later appears at
        // several dollars reads as a surprise rather than as a meter.
        assert_eq!(reading.cost_micros, Some(0));
    }

    #[test]
    fn a_model_the_catalog_missed_borrows_its_siblings_window() {
        // The case this exists for: the price book knew grok-4.6 while the
        // catalog snapshot had no row for it, so the bar vanished.
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
    fn pi_names_a_folders_directory_the_way_pi_does() {
        assert_eq!(pi_dir_name("/Users/x/git/demo"), "--Users-x-git-demo--");
        assert_eq!(pi_dir_name("/private/tmp"), "--private-tmp--");
        // A trailing separator must not add an empty part, or the directory
        // gains a third dash and is never found.
        assert_eq!(pi_dir_name("/Users/x/git/"), "--Users-x-git--");
    }

    /// The harness that shares Pi's folder encoding must keep sharing it.
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
        // The launcher's second OpenCode tile is the same reader.
        assert_eq!(harness_name("opencode2"), Some("opencode"));
        // Kilo forked OpenCode and kept the schema, but not the database, so
        // it must not resolve to that reader.
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
        // Two short lines, then far more than the head budget, so a reader
        // that took the whole file would be obvious in the result.
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

    /// A WAL write must count as a change to the store.
    ///
    /// OpenCode's database file sits still for hours while every turn lands in
    /// the `-wal` beside it, so a cache keyed on the database file alone
    /// served a session's opening emptiness for the session's whole life.
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
        // A miss is cached too: a folder the harness was never used in is
        // exactly the case that would otherwise scan everything every poll.
        assert_eq!(resolve_log("codex", &cwd, scan), None);
        assert_eq!(resolve_log("codex", &cwd, scan), None);
        assert_eq!(resolve_log("codex", &cwd, scan), None);
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
        // A rollout with no session_meta cannot claim a folder.
        assert_eq!(codex::session_cwd("{\"type\":\"event_msg\"}"), None);
    }

    #[test]
    fn grok_encodes_a_unix_path_the_way_the_session_dir_is_named() {
        assert_eq!(
            grok_encode("/Users/me/git/tokenstat"),
            "%2FUsers%2Fme%2Fgit%2Ftokenstat"
        );
    }
}
