//! How much of a plan's allowance is left.
//!
//! This is a different question from the rest of the crate. Everywhere else
//! counts tokens that were spent and prices them. This reports what the vendor
//! itself says about a quota: the rolling five hour window, the weekly one, the
//! monthly one. Those numbers are the vendor's, not ours, and are never derived
//! from the archive. A percentage we calculated would be a guess wearing a
//! number's clothes.
//!
//! Codex is read here because it writes its limits into its own session files,
//! so no request is involved. Anything that needs a request lives in
//! `tokenstat-sync`, which is the only crate allowed a network stack.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};

/// How close to the limit a window is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LimitSeverity {
    Normal,
    Warning,
    Critical,
}

impl LimitSeverity {
    /// Thresholds are ours, not the vendor's, and are the same for everything
    /// so that two providers side by side mean the same thing by "warning".
    pub fn from_percent(percent: f64) -> Self {
        if percent >= 90.0 {
            Self::Critical
        } else if percent >= 70.0 {
            Self::Warning
        } else {
            Self::Normal
        }
    }
}

/// One quota window.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    /// What the vendor calls it, normalised: `5-hour`, `weekly`, `monthly`.
    pub label: String,
    /// `primary` / `secondary` when available from the source payload.
    /// Older payloads or cache files may not include this.
    pub scope: Option<String>,
    /// Percent of the allowance used, 0 to 100.
    pub percent: f64,
    /// When the window rolls over, in unix milliseconds. Absent when the vendor
    /// did not say, which is not the same as "now".
    pub resets_at_ms: Option<i64>,
    pub severity: LimitSeverity,
}

/// What one provider reports about its own limits.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderLimits {
    /// Archive source id, so the mark beside it is the same mark used
    /// everywhere else: `codex`, `claude_code`.
    pub source: String,
    pub plan: Option<String>,
    pub windows: Vec<UsageWindow>,
    /// When these numbers were true, in unix milliseconds.
    pub observed_at_ms: i64,
    /// Why there is nothing to show, when there is nothing to show. Never left
    /// empty alongside empty windows: "no limits" and "we could not look" are
    /// different answers and must not render the same.
    pub note: Option<String>,
    /// These windows came out of the cache because this refresh could not read
    /// the vendor. The numbers are real, they are just old, and `note` says
    /// why. Presenting a remembered percentage as the current one would be a
    /// quiet lie about somebody's quota.
    #[serde(default)]
    pub stale: bool,
}

impl ProviderLimits {
    pub fn unavailable(source: &str, note: impl Into<String>) -> Self {
        Self {
            source: source.to_string(),
            plan: None,
            windows: Vec::new(),
            observed_at_ms: 0,
            note: Some(note.into()),
            stale: false,
        }
    }

    /// Whether this reading carries numbers, as opposed to only a reason.
    pub fn has_reading(&self) -> bool {
        !self.windows.is_empty()
    }
}

/// The last good reading per provider.
///
/// A vendor read fails for ordinary reasons: the login Claude Code stored has
/// expired, the account is out of quota, the machine is offline. None of those
/// mean the quota is unknown, they mean it could not be checked again just now.
/// Keeping the last answer turns "we cannot say" into "here is what was true at
/// 14:20, and here is why it is not newer", which is the honest version and
/// also the useful one.
///
/// One small JSON file in the data directory. Percentages and reset times only:
/// no token, no account id, nothing that is not already on the screen.
pub mod cache {
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use super::ProviderLimits;

    fn path() -> Option<PathBuf> {
        Some(tokenstat_paths::data_dir()?.join("limits-cache.json"))
    }

    /// Everything remembered, keyed by source id. A missing or unreadable file
    /// is an empty cache, never an error: this is a convenience, and failing a
    /// limits refresh because a cache file is corrupt would be absurd.
    pub fn load() -> BTreeMap<String, ProviderLimits> {
        let Some(path) = path() else {
            return BTreeMap::new();
        };
        std::fs::read_to_string(path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    /// Remember every reading that has numbers in it, leaving the previous
    /// entry alone for providers that only returned a reason this time.
    pub fn store(fresh: &[ProviderLimits]) {
        let Some(path) = path() else { return };
        let mut all = load();
        for provider in fresh {
            if provider.has_reading() && !provider.stale {
                let mut keep = provider.clone();
                // The note belongs to the attempt, not to the numbers.
                keep.note = None;
                all.insert(keep.source.clone(), keep);
            }
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(raw) = serde_json::to_string_pretty(&all) {
            let _ = std::fs::write(path, raw);
        }
    }

    /// Fill in from the cache wherever this round came back empty handed.
    ///
    /// The fresh reason is kept, because it is why the numbers are old. The
    /// windows, the plan and the timestamp come from the remembered reading, so
    /// the screen can say when it was true.
    pub fn backfill(fresh: Vec<ProviderLimits>) -> Vec<ProviderLimits> {
        merge(fresh, &load())
    }

    /// The decision itself, away from the disk so it can be tested.
    pub fn merge(
        fresh: Vec<ProviderLimits>,
        remembered: &BTreeMap<String, ProviderLimits>,
    ) -> Vec<ProviderLimits> {
        fresh
            .into_iter()
            .map(|provider| {
                if provider.has_reading() {
                    return provider;
                }
                match remembered.get(&provider.source) {
                    Some(old) => ProviderLimits {
                        source: provider.source,
                        plan: old.plan.clone(),
                        windows: old.windows.clone(),
                        observed_at_ms: old.observed_at_ms,
                        note: provider.note,
                        stale: true,
                    },
                    None => provider,
                }
            })
            .collect()
    }
}

/// Turn a window length in minutes into the name people use for it.
fn window_label(minutes: u64) -> String {
    match minutes {
        300 => "5-hour".to_string(),
        10080 => "weekly".to_string(),
        43200 => "monthly".to_string(),
        // Codex stated a percentage without saying what the window is. The
        // reading is still real, so it goes under a name that does not invent
        // a length for it.
        0 => "window".to_string(),
        m if m % 1440 == 0 => format!("{}-day", m / 1440),
        m if m % 60 == 0 => format!("{}-hour", m / 60),
        m => format!("{m}-minute"),
    }
}

// MARK: - Codex

#[derive(Debug, Deserialize)]
struct RolloutLine {
    #[serde(default)]
    timestamp: Option<String>,
    #[serde(default)]
    payload: Option<RolloutPayload>,
}

#[derive(Debug, Deserialize)]
struct RolloutPayload {
    #[serde(default)]
    rate_limits: Option<RateLimits>,
}

/// One `rate_limits` block, read as the object Codex wrote.
///
/// Not a struct of named fields. Codex adds and withdraws windows as its
/// plans change, and a window nobody wrote a field for here is exactly the
/// one a person needs to see: two hard coded names is what hid an exhausted
/// account limit behind a model's. Anything in the block that is not a
/// window carries no `used_percent` and is ignored.
#[derive(Debug, Deserialize)]
#[serde(transparent)]
struct RateLimits(serde_json::Map<String, serde_json::Value>);

impl RateLimits {
    /// Which allowance this block is about. `codex` is the account's own,
    /// anything else is a model's. Absent on older Codex builds.
    fn limit_id(&self) -> &str {
        self.text("limit_id")
    }

    /// What a person is shown for it, when the server names it at all:
    /// `GPT-5.3-Codex-Spark`. Usually absent even for a model's own block.
    fn limit_name(&self) -> &str {
        self.text("limit_name")
    }

    fn plan_type(&self) -> &str {
        self.text("plan_type")
    }

    fn text(&self, key: &str) -> &str {
        self.0
            .get(key)
            .and_then(|value| value.as_str())
            .unwrap_or("")
    }

    /// The windows in this block, under the names Codex gave them, in the
    /// order the block states them.
    fn windows(&self) -> Vec<(&str, RateWindow)> {
        self.0
            .iter()
            .filter_map(|(name, value)| {
                let window = RateWindow::deserialize(value).ok()?;
                // A percentage is the whole reading. Without one there is
                // nothing to report, and reporting zero would claim an
                // allowance is untouched when nobody said so.
                window.used_percent?;
                Some((name.as_str(), window))
            })
            .collect()
    }
}

#[derive(Debug, Deserialize)]
struct RateWindow {
    #[serde(default)]
    used_percent: Option<f64>,
    #[serde(default)]
    window_minutes: Option<u64>,
    /// Unix **seconds**, not milliseconds.
    #[serde(default)]
    resets_at: Option<i64>,
    /// Older builds wrote this instead, relative to the event's own timestamp.
    #[serde(default)]
    resets_in_seconds: Option<i64>,
}

/// Scope given to the account's own allowance, the one Codex shows under
/// "general usage limits".
const CODEX_ACCOUNT_SCOPE: &str = "general";
/// Scope given to a model's own allowance when the server did not name the
/// model. Only used once an account-wide window is in hand to contrast it
/// with, because a machine with no per-model limits has nothing to contrast.
const CODEX_MODEL_SCOPE: &str = "current model";

/// Read Codex's limits out of its own session log.
///
/// Codex records the rate limit block the API returned into every rollout file,
/// so the current picture is the last one it wrote. No request, no token, and
/// nothing to authenticate: this is a file Codex already put on the disk.
pub fn codex_limits() -> ProviderLimits {
    let now_ms = now_ms();
    if let Some(limits) = limits_in_sqlite(now_ms) {
        return limits;
    }

    let files = recent_rollouts(RECENT_ROLLOUTS);
    if files.is_empty() {
        return ProviderLimits::unavailable(
            "codex",
            "No Codex sessions found, so it has not reported a limit yet.",
        );
    }

    // Every recent file, not the newest one that happens to carry a block.
    // Codex reports the allowance for whatever model a turn ran on, so the
    // account's own weekly window and a model's rolling window arrive in
    // different blocks, often in different sessions. Stopping at the first
    // file with a block reported the model the last session used and hid an
    // account-wide limit that had already run out.
    let mut scan = CodexLimitScan::default();
    for file in &files {
        absorb_rollout(&mut scan, file);
    }

    match scan.finish(now_ms) {
        Some((windows, observed_at_ms, plan)) => ProviderLimits {
            source: "codex".to_string(),
            plan,
            windows,
            observed_at_ms,
            note: None,
            stale: false,
        },
        None => ProviderLimits::unavailable(
            "codex",
            "Codex has not written a limit into its recent session logs yet.",
        ),
    }
}

/// How many recent session files to look through. Enough to get past a run of
/// short sessions, few enough that this stays a disk read rather than a scan.
const RECENT_ROLLOUTS: usize = 25;

/// Feed every rate limit block in one rollout to the scan.
///
/// The whole file, not its tail. Codex scatters these blocks through a
/// session rather than restating the current one at the end, and the
/// account's own allowance is written only on a turn that spent it, which
/// can be megabytes back in a long session. Reading a 512 KB tail found the
/// running model's windows and missed an account limit that had already run
/// out. The `rate_limits` test keeps this cheap: a rollout is almost all
/// conversation, and a whole recent archive scans in well under a second.
fn absorb_rollout(scan: &mut CodexLimitScan, path: &Path) {
    use std::io::{BufRead, BufReader};

    let Ok(file) = std::fs::File::open(path) else {
        return;
    };
    let mut reader = BufReader::with_capacity(1 << 20, file);
    let mut line: Vec<u8> = Vec::new();
    loop {
        line.clear();
        // Bytes, not `read_line`: one stray byte sequence in somebody's
        // pasted output must not end the read on the line before the answer.
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => scan.absorb(&String::from_utf8_lossy(&line)),
        }
    }
}

/// The limits in one rollout file, if it has any.
#[cfg(test)]
fn limits_in(file: &Path, now_ms: i64) -> Option<ProviderLimits> {
    let mut scan = CodexLimitScan::default();
    absorb_rollout(&mut scan, file);
    scan.finish(now_ms)
        .map(|(windows, observed_at_ms, plan)| ProviderLimits {
            source: "codex".to_string(),
            plan,
            windows,
            observed_at_ms,
            note: None,
            stale: false,
        })
}

fn limits_in_sqlite(now_ms: i64) -> Option<ProviderLimits> {
    for path in codex_sqlite_db_candidates() {
        if let Some(found) = limits_in_sqlite_file(&path, now_ms) {
            return Some(found);
        }
    }
    None
}

fn limits_in_sqlite_file(db_path: &Path, now_ms: i64) -> Option<ProviderLimits> {
    let conn = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;

    let mut lines: Vec<String> = Vec::new();
    lines.extend(sqlite_candidate_rows(
        &conn,
        "thread_items",
        "item_json",
        "rowid",
    ));
    lines.extend(sqlite_candidate_rows(
        &conn,
        "thread_realtime_items",
        "item_json",
        "rowid",
    ));
    lines.extend(sqlite_candidate_rows(
        &conn,
        "thread_timeline_ledger",
        "payload_json",
        "sequence",
    ));

    if lines.is_empty() {
        return None;
    }

    let mut scan = CodexLimitScan::default();
    for line in &lines {
        scan.absorb(line);
    }

    scan.finish(now_ms)
        .map(|(windows, observed_at_ms, plan)| ProviderLimits {
            source: "codex".to_string(),
            plan,
            windows,
            observed_at_ms,
            note: None,
            stale: false,
        })
}

/// Which allowance a window belongs to: the limit, and its place in the block.
///
/// `limit_id` alone is not enough. Codex reports the account's own weekly
/// window and the running model's pair of windows under the same `codex` id,
/// and tells them apart only by the shape of the block, which is what the
/// position in the key preserves.
type CodexWindowKey = (String, String, u64, String);

/// The newest reading of every Codex limit seen while walking its logs.
///
/// Written to be fed blocks in any order, oldest first by preference: each
/// window keeps the reading with the latest timestamp, and the plan comes
/// from the latest block that named one. Codex sends sparse updates and
/// carries the unchanged fields forward itself, so a block can arrive with
/// windows and no plan while the account plainly still has one.
#[derive(Default)]
struct CodexLimitScan {
    windows: std::collections::HashMap<CodexWindowKey, (i64, UsageWindow)>,
    plan: Option<(i64, String)>,
}

impl CodexLimitScan {
    fn absorb(&mut self, line: &str) {
        // The exact spelling a record uses. Sessions about this very code
        // quote the word thousands of times in ordinary conversation, where
        // it arrives escaped as `\"rate_limits\":` and does not match, so a
        // looser test would parse megabytes of chat to learn nothing.
        if !line.contains(r#""rate_limits":{"#) {
            return;
        }
        let Ok(parsed) = serde_json::from_str::<RolloutLine>(line) else {
            return;
        };
        let Some(limits) = parsed.payload.and_then(|p| p.rate_limits) else {
            return;
        };
        let observed_at_ms = parsed
            .timestamp
            .as_deref()
            .and_then(parse_iso_ms)
            .unwrap_or(0);

        let plan = limits.plan_type();
        if !plan.is_empty() {
            let newer = self
                .plan
                .as_ref()
                .is_none_or(|(at, _)| observed_at_ms >= *at);
            if newer {
                self.plan = Some((observed_at_ms, plan.to_string()));
            }
        }

        let limit_id = limits.limit_id();
        let limit_name = limits.limit_name();
        let reported = limits.windows();
        let account_wide = is_account_wide(&reported);

        for (position, reported) in &reported {
            // `windows` already refused anything without one.
            let Some(percent) = reported.used_percent else {
                continue;
            };
            let minutes = reported.window_minutes.unwrap_or(0);
            let scope = match (limit_name, account_wide) {
                // The server named the limit, so use its name.
                ("", true) => CODEX_ACCOUNT_SCOPE.to_string(),
                // Nothing to distinguish it from yet. `finish` renames these
                // if an account-wide window turns up beside them.
                ("", false) => (*position).to_string(),
                (name, _) => name.to_string(),
            };
            let window = UsageWindow {
                label: window_label(minutes),
                scope: Some(scope),
                percent,
                // The reset figures come from the rollout log. Saturating keeps
                // a corrupt or absurd value from wrapping a deadline into the
                // past and hiding a window that is still in force.
                resets_at_ms: reported
                    .resets_at
                    .map(|s| s.saturating_mul(1000))
                    .or_else(|| {
                        reported
                            .resets_in_seconds
                            .map(|s| observed_at_ms.saturating_add(s.saturating_mul(1000)))
                    }),
                severity: LimitSeverity::from_percent(percent),
            };
            let key = (
                limit_id.to_string(),
                limit_name.to_string(),
                minutes,
                (*position).to_string(),
            );
            let newer = self
                .windows
                .get(&key)
                .is_none_or(|(at, _)| observed_at_ms >= *at);
            if newer {
                self.windows.insert(key, (observed_at_ms, window));
            }
        }
    }

    /// Every limit still in force, shortest remaining first.
    fn finish(self, now_ms: i64) -> Option<(Vec<UsageWindow>, i64, Option<String>)> {
        let mut readings: Vec<(i64, UsageWindow)> = self.windows.into_values().collect();
        // Newest first, so the duplicate check below keeps the fresher of two
        // readings of the same limit.
        readings.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.label.cmp(&b.1.label)));

        let mut kept: Vec<(i64, UsageWindow)> = Vec::new();
        for (at, window) in readings {
            // Already rolled over, so the percentage is somebody's history
            // rather than their quota. Codex stops reporting a limit the
            // moment no turn uses it, and a window nobody refreshed would
            // otherwise sit on the card claiming to be full.
            if window.resets_at_ms.is_some_and(|ms| ms <= now_ms) {
                continue;
            }
            // The same allowance under two ids: Codex moved the model's
            // windows from a named block to the plain `codex` one, and a
            // window that rolls over at the same instant as one already kept
            // is that same window seen under the older name.
            let duplicate = window.resets_at_ms.is_some()
                && kept.iter().any(|(_, other)| {
                    other.label == window.label && other.resets_at_ms == window.resets_at_ms
                });
            if duplicate {
                continue;
            }
            kept.push((at, window));
        }

        if kept.is_empty() {
            return None;
        }

        // Only now is there something to contrast a model's windows with.
        // Calling them "primary" and "secondary" beside an account-wide
        // window says nothing about which allowance they belong to.
        let has_account = kept
            .iter()
            .any(|(_, w)| w.scope.as_deref() == Some(CODEX_ACCOUNT_SCOPE));
        if has_account {
            for (_, window) in kept.iter_mut() {
                if matches!(window.scope.as_deref(), Some("primary") | Some("secondary")) {
                    window.scope = Some(CODEX_MODEL_SCOPE.to_string());
                }
            }
        }

        let observed_at_ms = kept.iter().map(|(at, _)| *at).max().unwrap_or(0);
        let mut windows: Vec<UsageWindow> = kept.into_iter().map(|(_, w)| w).collect();
        // Shortest window first: the one about to bite is the one to read.
        windows.sort_by_key(|w| w.resets_at_ms.unwrap_or(i64::MAX));
        Some((windows, observed_at_ms, self.plan.map(|(_, plan)| plan)))
    }
}

/// Whether a block describes the account's whole allowance rather than one
/// model's.
///
/// Codex writes the account-wide limit as a single window a week or longer,
/// and a model's as its rolling window plus that model's week. There is no
/// flag for it: both arrive with `limit_id` `codex` and no name, so the shape
/// is the only thing that separates them.
fn is_account_wide(windows: &[(&str, RateWindow)]) -> bool {
    matches!(
        windows,
        [(_, only)] if only.window_minutes.is_some_and(|minutes| minutes >= 1440)
    )
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn sqlite_candidate_rows(
    conn: &Connection,
    table: &str,
    column: &str,
    order_by: &str,
) -> Vec<String> {
    const RECENT_SQLITE_ROWS: usize = 240;
    let query = format!(
        "SELECT {column} FROM {table} WHERE {column} LIKE '%\"rate_limits\"%' \
         AND {column} LIKE '%token_count%' \
         ORDER BY {order_by} DESC \
         LIMIT {RECENT_SQLITE_ROWS}"
    );

    let mut out = Vec::new();
    let mut stmt = match conn.prepare(&query) {
        Ok(stmt) => stmt,
        Err(_) => return out,
    };
    let rows = match stmt.query_map([], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(_) => return out,
    };

    out.extend(rows.flatten());
    out
}

fn codex_sqlite_db_candidates() -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    let mut seen: HashSet<PathBuf> = HashSet::new();
    for home in codex_homes() {
        let db_dir = [home.clone(), home.join("sqlite")];

        for dir in db_dir {
            let Ok(entries) = std::fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_file() {
                    continue;
                }
                if is_sqlite_path(&path) && seen.insert(path.clone()) {
                    candidates.push(path);
                }
            }
        }
    }

    candidates.sort_by_key(|path| {
        std::fs::metadata(path)
            .and_then(|m| m.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH)
    });
    candidates.reverse();
    candidates
}

fn is_sqlite_path(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    if name.ends_with("-shm") || name.ends_with("-wal") {
        return false;
    }
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("sqlite") | Some("db")
    )
}

/// `2026-07-12T06:44:58.735Z` and friends, to unix milliseconds.
fn parse_iso_ms(raw: &str) -> Option<i64> {
    raw.parse::<jiff::Timestamp>()
        .ok()
        .map(|t| t.as_millisecond())
}

/// Where Codex keeps its sessions, in the order to prefer them.
fn codex_homes() -> Vec<PathBuf> {
    let mut homes = Vec::new();
    if let Ok(explicit) = std::env::var("CODEX_HOME") {
        if !explicit.is_empty() {
            homes.push(PathBuf::from(explicit));
        }
    }
    if let Some(dirs) = directories::UserDirs::new() {
        homes.push(dirs.home_dir().join(".codex"));
    }
    homes.dedup();
    homes
}

/// The most recently written rollout files across every Codex home, newest
/// first.
///
/// Walks the `sessions/YYYY/MM/DD` tree newest-named first and stops once it
/// has enough, so a machine with years of sessions is not listed end to end to
/// answer a question about this week.
fn recent_rollouts(want: usize) -> Vec<PathBuf> {
    let mut found: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    for home in codex_homes() {
        collect_rollouts(&home.join("sessions"), 3, want, &mut found);
    }
    found.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    found.truncate(want);
    found.into_iter().map(|(_, path)| path).collect()
}

/// Descend `depth` levels of date directories, newest name first, gathering
/// rollout files until `want` of them are in hand.
fn collect_rollouts(
    dir: &Path,
    depth: usize,
    want: usize,
    out: &mut Vec<(std::time::SystemTime, PathBuf)>,
) {
    if out.len() >= want {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };

    if depth == 0 {
        for entry in entries.flatten() {
            let path = entry.path();
            let is_rollout = path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(".jsonl"));
            if !is_rollout {
                continue;
            }
            if let Ok(modified) = entry.metadata().and_then(|m| m.modified()) {
                out.push((modified, path));
            }
        }
        return;
    }

    let mut children: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    // Names are zero padded dates, so descending by name is descending by date.
    children.sort_by(|a, b| b.file_name().cmp(&a.file_name()));
    for child in children {
        collect_rollouts(&child, depth - 1, want, out);
        if out.len() >= want {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_names_match_what_people_call_them() {
        assert_eq!(window_label(300), "5-hour");
        assert_eq!(window_label(10080), "weekly");
        assert_eq!(window_label(43200), "monthly");
        assert_eq!(window_label(2880), "2-day");
        assert_eq!(window_label(180), "3-hour");
        assert_eq!(window_label(7), "7-minute");
    }

    #[test]
    fn severity_is_the_same_scale_for_every_provider() {
        assert_eq!(LimitSeverity::from_percent(0.0), LimitSeverity::Normal);
        assert_eq!(LimitSeverity::from_percent(69.9), LimitSeverity::Normal);
        assert_eq!(LimitSeverity::from_percent(70.0), LimitSeverity::Warning);
        assert_eq!(LimitSeverity::from_percent(89.9), LimitSeverity::Warning);
        assert_eq!(LimitSeverity::from_percent(100.0), LimitSeverity::Critical);
    }

    #[test]
    fn the_newest_block_in_a_file_is_the_reading() {
        let dir = std::env::temp_dir().join(format!("tokenstat-codex-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout-test.jsonl");

        // Two blocks: the later one is the answer, and a line without limits in
        // between must not stop the scan.
        let body = concat!(
            r#"{"timestamp":"2026-07-12T06:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":43200,"resets_at":1784460000},"plan_type":"free"}}}"#,
            "\n",
            r#"{"timestamp":"2026-07-12T06:30:00.000Z","type":"event_msg","payload":{"type":"token_count"}}"#,
            "\n",
            r#"{"timestamp":"2026-07-12T06:44:58.735Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"window_minutes":43200,"resets_at":1784460506},"secondary":null,"plan_type":"pro"}}}"#,
            "\n",
        );
        std::fs::write(&file, body).unwrap();

        let found = limits_in(&file, 1_784_400_000_000).expect("the file carries a block");
        assert_eq!(found.plan.as_deref(), Some("pro"));
        assert_eq!(found.windows.len(), 1);
        assert_eq!(found.windows[0].percent, 100.0);
        assert_eq!(found.windows[0].label, "monthly");
        // Seconds, not milliseconds. Treating it as millis would put the reset
        // in 1970 and the window would read as permanently expired.
        assert_eq!(found.windows[0].resets_at_ms, Some(1_784_460_506_000));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_newer_session_without_limits_falls_back_to_an_older_one() {
        // The real case this was found on: the newest rollout file carried no
        // `rate_limits` at all, because Codex only writes the block when the API
        // sends one and a short session never gets that far. Reading only the
        // newest file reported "no limit" while sixteen older files had one.
        let dir = std::env::temp_dir().join(format!("tokenstat-codex-fb-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let older = dir.join("rollout-older.jsonl");
        std::fs::write(
            &older,
            format!(
                "{}\n",
                r#"{"timestamp":"2026-07-12T06:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1784460000},"plan_type":"pro"}}}"#
            ),
        )
        .unwrap();

        let newer = dir.join("rollout-newer.jsonl");
        std::fs::write(
            &newer,
            format!(
                "{}\n",
                r#"{"timestamp":"2026-07-13T06:00:00.000Z","payload":{"type":"token_count"}}"#
            ),
        )
        .unwrap();

        assert!(
            limits_in(&newer, 1_784_400_000_000).is_none(),
            "the newer file carries nothing"
        );
        let found =
            limits_in(&older, 1_784_400_000_000).expect("the older file still has the answer");
        assert_eq!(found.windows[0].percent, 42.0);
        assert_eq!(found.windows[0].label, "5-hour");
        assert_eq!(found.plan.as_deref(), Some("pro"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_sparse_update_keeps_the_plan_from_an_older_block() {
        // Codex carries unchanged fields forward itself, so the newest block
        // can hold windows with no plan named. The windows are the reading;
        // the plan must keep scanning older blocks instead of going missing.
        let dir =
            std::env::temp_dir().join(format!("tokenstat-codex-sparse-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout-sparse.jsonl");
        std::fs::write(
            &file,
            concat!(
                r#"{"timestamp":"2026-07-12T06:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1784460000},"plan_type":"pro"}}}"#,
                "\n",
                r#"{"timestamp":"2026-07-12T06:44:58.735Z","payload":{"rate_limits":{"primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1784460506}}}}"#,
                "\n",
            ),
        )
        .unwrap();

        let found = limits_in(&file, 1_784_400_000_000)
            .expect("sparse newest block still yields a reading");
        assert_eq!(
            found.windows[0].percent, 42.0,
            "windows come from the newest block"
        );
        assert_eq!(
            found.plan.as_deref(),
            Some("pro"),
            "plan carries forward from the older block"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_exhausted_account_window_survives_a_session_on_one_model() {
        // The case this exists for: the account's weekly allowance ran out, so
        // Codex fell back to a model with its own allowance and reported only
        // that model's windows from then on. Reading the newest block alone
        // showed the model at 88% and hid the account at 100%, which is the
        // one that stopped the work.
        let dir = std::env::temp_dir().join(format!("tokenstat-codex-two-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout-two.jsonl");
        std::fs::write(
            &file,
            concat!(
                r#"{"timestamp":"2026-09-10T21:01:58.000Z","payload":{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1789641363},"secondary":null,"plan_type":"prolite"}}}"#,
                "\n",
                r#"{"timestamp":"2026-09-10T21:32:16.000Z","payload":{"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1789093407},"secondary":{"used_percent":45.0,"window_minutes":10080,"resets_at":1789680207}}}}"#,
                "\n",
                r#"{"timestamp":"2026-09-11T19:34:31.000Z","payload":{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":88.0,"window_minutes":300,"resets_at":1789172231},"secondary":{"used_percent":84.0,"window_minutes":10080,"resets_at":1789680207}}}}"#,
                "\n",
            ),
        )
        .unwrap();

        // Just after the last block was written.
        let now_ms = 1_789_162_000_000;
        let found = limits_in(&file, now_ms).expect("both allowances are readable");

        let labels: Vec<String> = found
            .windows
            .iter()
            .map(|w| format!("{} ({})", w.label, w.scope.clone().unwrap_or_default()))
            .collect();
        assert_eq!(
            labels,
            vec![
                "5-hour (current model)",
                "weekly (general)",
                "weekly (current model)",
            ],
            "shortest remaining first, and each window says whose it is"
        );
        assert_eq!(found.windows[0].percent, 88.0);
        assert_eq!(found.windows[1].percent, 100.0);
        assert_eq!(found.windows[1].severity, LimitSeverity::Critical);
        // The named block's week is the same week as the plain one's, seen
        // under the older id, so it appears once at its newer reading.
        assert_eq!(found.windows[2].percent, 84.0);
        assert_eq!(found.plan.as_deref(), Some("prolite"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_window_that_already_rolled_over_is_not_reported() {
        let dir = std::env::temp_dir().join(format!("tokenstat-codex-past-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout-past.jsonl");
        std::fs::write(
            &file,
            concat!(
                r#"{"timestamp":"2026-09-10T21:32:16.000Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1789093407},"secondary":{"used_percent":45.0,"window_minutes":10080,"resets_at":1789680207}}}}"#,
                "\n",
            ),
        )
        .unwrap();

        let found = limits_in(&file, 1_789_162_000_000).expect("the week is still running");
        assert_eq!(found.windows.len(), 1, "the spent five hour window is gone");
        assert_eq!(found.windows[0].label, "weekly");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// One rollout in a temp dir, and the reading taken from it.
    fn reading_from(name: &str, body: &str, now_ms: i64) -> Option<ProviderLimits> {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-codex-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout.jsonl");
        std::fs::write(&file, body).unwrap();
        let found = limits_in(&file, now_ms);
        let _ = std::fs::remove_dir_all(&dir);
        found
    }

    #[test]
    fn a_withdrawn_model_limit_leaves_the_account_reading_alone() {
        // What next week looks like: the per-model allowance is gone and
        // Codex reports the account's own windows under the plain `codex` id
        // again. Nothing should be renamed on its account, and the model's
        // last windows are left to expire on their own reset rather than
        // being guessed at.
        let found = reading_from(
            "gone",
            concat!(
                r#"{"timestamp":"2026-09-11T19:34:31.000Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":88.0,"window_minutes":300,"resets_at":1789172231},"secondary":{"used_percent":84.0,"window_minutes":10080,"resets_at":1789680207}}}}"#,
                "\n",
                r#"{"timestamp":"2026-09-18T09:00:00.000Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1790240000},"secondary":{"used_percent":30.0,"window_minutes":10080,"resets_at":1790500000},"plan_type":"prolite"}}}"#,
                "\n",
            ),
            // A week on, so the older pair has rolled over.
            1_789_700_000_000,
        )
        .expect("the account's own windows are the reading");

        let shown: Vec<String> = found
            .windows
            .iter()
            .map(|w| format!("{} ({})", w.label, w.scope.clone().unwrap_or_default()))
            .collect();
        assert_eq!(
            shown,
            vec!["5-hour (primary)", "weekly (secondary)"],
            "with no account-wide block beside them the old names stand"
        );
        assert_eq!(found.windows[0].percent, 12.0);
        assert_eq!(found.windows[1].percent, 30.0);
    }

    #[test]
    fn a_window_codex_has_not_named_a_field_for_is_still_reported() {
        // The windows are read by shape, not by two hard coded field names,
        // so a third one arrives instead of vanishing. This is the failure
        // that hid an exhausted limit once already, and it must not depend
        // on this file having been updated first.
        let found = reading_from(
            "third",
            concat!(
                r#"{"timestamp":"2026-09-11T19:34:31.000Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1789172231},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1789680207},"tertiary":{"used_percent":30.0,"window_minutes":43200,"resets_at":1791680207},"credits":{"has_credits":false,"balance":"0"},"rate_limit_reached_type":null}}}"#,
                "\n",
            ),
            1_789_160_000_000,
        )
        .expect("all three windows are readable");

        assert_eq!(found.windows.len(), 3, "credits is not a window");
        assert_eq!(found.windows[2].label, "monthly");
        assert_eq!(found.windows[2].scope.as_deref(), Some("tertiary"));
    }

    #[test]
    fn a_missing_field_costs_only_what_it_says() {
        // A block with no length, no reset and no plan. The percentage is
        // still a real reading and is still shown, under a name that does
        // not claim a length nobody stated.
        let found = reading_from(
            "sparse",
            concat!(
                r#"{"timestamp":"2026-09-11T19:34:31.000Z","payload":{"rate_limits":{"primary":{"used_percent":73.0}}}}"#,
                "\n",
            ),
            1_789_160_000_000,
        )
        .expect("a percentage on its own is still a reading");

        assert_eq!(found.windows.len(), 1);
        assert_eq!(found.windows[0].label, "window");
        assert_eq!(found.windows[0].percent, 73.0);
        assert_eq!(found.windows[0].resets_at_ms, None);
        assert_eq!(found.plan, None);
    }

    #[test]
    fn a_window_with_no_percentage_is_not_a_reading() {
        // Never zero. "The vendor did not say" and "none of it is used" are
        // different answers and must not render the same.
        let found = reading_from(
            "nopct",
            concat!(
                r#"{"timestamp":"2026-09-11T19:34:31.000Z","payload":{"rate_limits":{"primary":{"window_minutes":300,"resets_at":1789172231},"plan_type":"prolite"}}}"#,
                "\n",
            ),
            1_789_160_000_000,
        );
        assert!(found.is_none(), "a block with no percentage says nothing");
    }

    #[test]
    fn a_failed_read_falls_back_to_the_last_good_one_and_says_it_is_old() {
        // The case this exists for: Claude Code's stored login expires, or the
        // account runs out, and the vendor cannot be asked again. The quota did
        // not become unknown, it just stopped being re-checked.
        let mut remembered = std::collections::BTreeMap::new();
        remembered.insert(
            "claude_code".to_string(),
            ProviderLimits {
                source: "claude_code".to_string(),
                plan: Some("max".to_string()),
                windows: vec![UsageWindow {
                    label: "5-hour".to_string(),
                    scope: None,
                    percent: 64.0,
                    resets_at_ms: Some(1_784_460_000_000),
                    severity: LimitSeverity::Normal,
                }],
                observed_at_ms: 1_784_450_000_000,
                note: None,
                stale: false,
            },
        );

        let fresh = vec![
            ProviderLimits::unavailable("claude_code", "The stored login has expired."),
            ProviderLimits::unavailable("cursor", "Never read this one."),
        ];
        let merged = cache::merge(fresh, &remembered);

        let claude = &merged[0];
        assert!(claude.stale, "remembered numbers must be marked as old");
        assert_eq!(claude.windows[0].percent, 64.0);
        assert_eq!(claude.observed_at_ms, 1_784_450_000_000, "not now");
        assert!(
            claude.note.is_some(),
            "the reason the numbers are old is the fresh one, not the cached one"
        );

        // Nothing remembered means nothing invented.
        assert!(!merged[1].stale);
        assert!(merged[1].windows.is_empty());
    }

    #[test]
    fn a_fresh_reading_is_never_replaced_by_a_remembered_one() {
        let mut remembered = std::collections::BTreeMap::new();
        remembered.insert(
            "codex".to_string(),
            ProviderLimits {
                source: "codex".to_string(),
                plan: None,
                windows: vec![UsageWindow {
                    label: "5-hour".to_string(),
                    scope: None,
                    percent: 10.0,
                    resets_at_ms: None,
                    severity: LimitSeverity::Normal,
                }],
                observed_at_ms: 1,
                note: None,
                stale: false,
            },
        );

        let fresh = vec![ProviderLimits {
            source: "codex".to_string(),
            plan: None,
            windows: vec![UsageWindow {
                label: "5-hour".to_string(),
                scope: None,
                percent: 90.0,
                resets_at_ms: None,
                severity: LimitSeverity::Critical,
            }],
            observed_at_ms: 2,
            note: None,
            stale: false,
        }];

        let merged = cache::merge(fresh, &remembered);
        assert_eq!(merged[0].windows[0].percent, 90.0);
        assert!(!merged[0].stale);
    }

    #[test]
    fn no_codex_at_all_says_so_rather_than_reporting_zero() {
        // The rule everywhere in this project: a number nobody measured is not
        // zero. An absent Codex must not render as "0% used".
        let out = ProviderLimits::unavailable("codex", "nothing here");
        assert!(out.windows.is_empty());
        assert!(out.note.is_some());
    }
}
