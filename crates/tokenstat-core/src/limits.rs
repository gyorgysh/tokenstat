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

use std::path::{Path, PathBuf};

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
        let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")?;
        Some(dirs.data_dir().join("limits-cache.json"))
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

#[derive(Debug, Deserialize)]
struct RateLimits {
    #[serde(default)]
    primary: Option<RateWindow>,
    #[serde(default)]
    secondary: Option<RateWindow>,
    #[serde(default)]
    plan_type: Option<String>,
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

/// Read Codex's limits out of its own session log.
///
/// Codex records the rate limit block the API returned into every rollout file,
/// so the current picture is the last one it wrote. No request, no token, and
/// nothing to authenticate: this is a file Codex already put on the disk.
pub fn codex_limits() -> ProviderLimits {
    let files = recent_rollouts(RECENT_ROLLOUTS);
    if files.is_empty() {
        return ProviderLimits::unavailable(
            "codex",
            "No Codex sessions found, so it has not reported a limit yet.",
        );
    }

    // Newest first, and keep going until one of them actually carries a block.
    // Reading only the newest file is wrong: Codex writes the rate limit block
    // when the API sends one, so a short or interrupted session records none at
    // all, and the answer is in the session before it rather than absent.
    for file in files {
        if let Some(limits) = limits_in(&file) {
            return limits;
        }
    }

    ProviderLimits::unavailable(
        "codex",
        "Codex has not written a limit into its recent session logs yet.",
    )
}

/// How many recent session files to look through. Enough to get past a run of
/// short sessions, few enough that this stays a disk read rather than a scan.
const RECENT_ROLLOUTS: usize = 25;

/// The last rate limit block in one rollout file, if it has one.
fn limits_in(file: &Path) -> Option<ProviderLimits> {
    let raw = tail(file, 512 * 1024)?;

    // Backwards: the most recent block is the current one, and a long session
    // contains hundreds of them.
    for line in raw.lines().rev() {
        if !line.contains("rate_limits") {
            continue;
        }
        let Ok(parsed) = serde_json::from_str::<RolloutLine>(line) else {
            continue;
        };
        let Some(limits) = parsed.payload.and_then(|p| p.rate_limits) else {
            continue;
        };

        let observed_at_ms = parsed
            .timestamp
            .as_deref()
            .and_then(parse_iso_ms)
            .unwrap_or(0);

        let mut windows: Vec<UsageWindow> = [limits.primary, limits.secondary]
            .into_iter()
            .flatten()
            .filter_map(|w| {
                let percent = w.used_percent?;
                let minutes = w.window_minutes.unwrap_or(0);
                let resets_at_ms = w
                    .resets_at
                    .map(|s| s * 1000)
                    .or_else(|| w.resets_in_seconds.map(|s| observed_at_ms + s * 1000));
                Some(UsageWindow {
                    label: window_label(minutes),
                    percent,
                    resets_at_ms,
                    severity: LimitSeverity::from_percent(percent),
                })
            })
            .collect();
        // Shortest window first: the one about to bite is the one to read.
        windows.sort_by_key(|w| w.resets_at_ms.unwrap_or(i64::MAX));

        if windows.is_empty() {
            continue;
        }
        return Some(ProviderLimits {
            source: "codex".to_string(),
            plan: limits.plan_type,
            windows,
            observed_at_ms,
            note: None,
            stale: false,
        });
    }
    None
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

/// The last `limit` bytes of a file, starting at a line boundary.
///
/// A rollout file grows to megabytes and the block wanted is at the end, so
/// reading the whole thing to find it would be wasteful on every refresh.
fn tail(path: &Path, limit: u64) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};

    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    let from = size.saturating_sub(limit);
    file.seek(SeekFrom::Start(from)).ok()?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf).into_owned();

    // The first line is a fragment when the file was longer than the window.
    if from > 0 {
        text.find('\n').map(|i| text[i + 1..].to_string())
    } else {
        Some(text)
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
    fn a_rollout_tail_yields_the_last_rate_limit_block() {
        let dir = std::env::temp_dir().join(format!("tokenstat-codex-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout-test.jsonl");

        // Two blocks: the later one is the answer, and a line without limits in
        // between must not stop the scan.
        let body = concat!(
            r#"{"timestamp":"2026-07-12T06:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1784460000},"plan_type":"free"}}}"#,
            "\n",
            r#"{"timestamp":"2026-07-12T06:30:00.000Z","type":"event_msg","payload":{"type":"token_count"}}"#,
            "\n",
            r#"{"timestamp":"2026-07-12T06:44:58.735Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"window_minutes":43200,"resets_at":1784460506},"secondary":null,"plan_type":"pro"}}}"#,
            "\n",
        );
        std::fs::write(&file, body).unwrap();

        let raw = tail(&file, 512 * 1024).unwrap();
        let line = raw
            .lines()
            .rev()
            .find(|l| l.contains("rate_limits"))
            .unwrap();
        let parsed: RolloutLine = serde_json::from_str(line).unwrap();
        let limits = parsed.payload.unwrap().rate_limits.unwrap();
        assert_eq!(limits.plan_type.as_deref(), Some("pro"));

        let primary = limits.primary.unwrap();
        assert_eq!(primary.used_percent, Some(100.0));
        assert_eq!(window_label(primary.window_minutes.unwrap()), "monthly");
        // Seconds, not milliseconds. Treating it as millis would put the reset
        // in 1970 and the window would read as permanently expired.
        assert_eq!(primary.resets_at, Some(1784460506));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_tail_that_cut_a_line_drops_the_fragment() {
        let dir = std::env::temp_dir().join(format!("tokenstat-codex-cut-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout-cut.jsonl");
        std::fs::write(&file, "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n").unwrap();

        // A window that lands mid-line: the partial first line must go, or the
        // JSON parse fails on rubbish rather than on a real problem.
        let raw = tail(&file, 16).unwrap();
        assert!(!raw.contains("aaaa"));
        assert!(raw.ends_with("cccccccccc\n"));

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
            limits_in(&newer).is_none(),
            "the newer file carries nothing"
        );
        let found = limits_in(&older).expect("the older file still has the answer");
        assert_eq!(found.windows[0].percent, 42.0);
        assert_eq!(found.windows[0].label, "5-hour");
        assert_eq!(found.plan.as_deref(), Some("pro"));

        let _ = std::fs::remove_dir_all(&dir);
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
