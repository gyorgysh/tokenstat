// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.
//! Is this session working, or is it just sitting there.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

const ON_DELTA_PERCENT: f64 = 4.0;
const OFF_DELTA_PERCENT: f64 = 1.5;
const HARD_WORKING_FLOOR_PERCENT: f64 = 20.0;
const BASELINE_CREEP_PER_TICK: f64 = 0.05;
const ALPHA: f64 = 0.25;
const GRACE: Duration = Duration::from_secs(180);
const EVIDENCE_FRESH: Duration = Duration::from_secs(15);
const HOOK_STALE: Duration = Duration::from_secs(900);
const TICK: Duration = Duration::from_secs(1);

/// What a session is doing, as reported to a front end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Activity {
    Working,
    Idle,
}

impl Activity {
    pub fn as_str(self) -> &'static str {
        match self {
            Activity::Working => "working",
            Activity::Idle => "idle",
        }
    }
}

/// Why a person should look at this session.
///
/// Separate from [`Activity`]: idle-for-twenty-seconds is not a reason to
/// look, and a false alarm is worse than a quiet row. Only the detectors
/// below set this, and they stay conservative on purpose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attention {
    /// The agent is waiting on a permission or approval prompt.
    Permission,
}

impl Attention {
    pub fn as_str(self) -> &'static str {
        match self {
            Attention::Permission => "permission",
        }
    }
}

/// One session's answer, and the number behind it.
#[derive(Debug, Clone, Copy)]
pub struct Reading {
    pub activity: Activity,
    /// Smoothed CPU of the process subtree, percent of one core. Reported so
    /// a front end can show the measurement rather than only the verdict: a
    /// row that says Working and 140% has explained itself.
    pub cpu_percent: f64,
    /// Resident memory of the whole subtree, in megabytes.
    ///
    /// Not smoothed. Memory moves in steps rather than in noise, so an
    /// average would only lag the number the process actually holds.
    pub memory_mb: f64,
    /// Why the person should look, when we are sure. Absent is not idle.
    pub attention: Option<Attention>,
}

#[derive(Debug, Clone, Copy, Default)]
struct State {
    average: Option<f64>,
    baseline: Option<f64>,
    episode_floor: Option<f64>,
    working: bool,
}

/// A session the sampler should watch.
pub struct Watch {
    pub pid: u32,
    pub cwd: String,
    /// The harness id, when the launcher knew which one this is. Drives the
    /// transcript lookup, which is per-harness.
    pub harness: Option<String>,
    pub started_at_ms: u64,
    pub last_input_at_ms: u64,
}

struct Tracker {
    states: HashMap<u32, State>,
    last_working: HashMap<u32, Instant>,
    readings: HashMap<u32, Reading>,
}

fn tracker() -> &'static Mutex<Tracker> {
    static TRACKER: OnceLock<Mutex<Tracker>> = OnceLock::new();
    TRACKER.get_or_init(|| {
        Mutex::new(Tracker {
            states: HashMap::new(),
            last_working: HashMap::new(),
            readings: HashMap::new(),
        })
    })
}

/// The verdict for a pid, or `None` when the sampler has not seen it yet.
pub fn reading(pid: u32) -> Option<Reading> {
    tracker()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .readings
        .get(&pid)
        .copied()
}

/// Start the sampler. Safe to call more than once.
pub fn start() {
    static STARTED: OnceLock<()> = OnceLock::new();
    if STARTED.set(()).is_err() {
        return;
    }
    std::thread::Builder::new()
        .name("activity".into())
        .spawn(|| {
            loop {
                tick();
                crate::live_work::poll_terminals();
                std::thread::sleep(TICK);
            }
        })
        .ok();
}

fn watches() -> Vec<Watch> {
    tokenstat_pty::manager()
        .list()
        .into_iter()
        .filter(|s| s.alive)
        .filter_map(|s| {
            s.pid.map(|pid| Watch {
                pid,
                cwd: s.cwd.clone(),
                harness: harness_of(&s.command),
                started_at_ms: s.started_at_ms,
                last_input_at_ms: tokenstat_pty::manager()
                    .last_input_at_ms(&s.id)
                    .unwrap_or(0),
            })
        })
        .collect()
}

fn harness_of(command: &str) -> Option<String> {
    let name = command.rsplit(['/', '\\']).next().unwrap_or(command).trim();
    let name = name.strip_suffix(".exe").unwrap_or(name);

    (!name.is_empty()).then(|| name.to_string())
}

fn tick() {
    let watches = watches();
    if watches.is_empty() {
        let mut t = tracker().lock().unwrap_or_else(|e| e.into_inner());
        t.states.clear();
        t.last_working.clear();
        t.readings.clear();
        return;
    }

    let Some(table) = process_table() else {
        return;
    };
    let children = children_index(&table);
    let hooks = hook_records();
    let now = Instant::now();

    let mut t = tracker().lock().unwrap_or_else(|e| e.into_inner());
    let mut states = HashMap::with_capacity(watches.len());
    let mut last_working = HashMap::with_capacity(watches.len());
    let mut readings = HashMap::with_capacity(watches.len());

    for w in &watches {
        let usage = subtree_usage(&table, &children, w.pid);
        let sample = usage.cpu_percent;
        let memory_mb = usage.memory_mb;
        let hook = hooks
            .iter()
            .filter(|r| r.matches(w, &usage.pids))
            .max_by_key(|r| r.observed_at_ms);
        let hook_working = hook.map(|r| r.working);
        let evidence = w
            .harness
            .as_deref()
            .and_then(|h| transcript_touched(h, &w.cwd))
            .map(|age| age <= EVIDENCE_FRESH)
            .unwrap_or(false);

        let state = step(
            t.states.get(&w.pid).copied().unwrap_or_default(),
            sample,
            evidence,
            hook_working,
        );

        let previous = t.last_working.get(&w.pid).copied();
        let hook_says_idle = hook_working == Some(false);
        let within_grace = previous.is_some_and(|at| now.duration_since(at) < GRACE);
        if state.working {
            last_working.insert(w.pid, now);
        } else if hook_says_idle {
        } else if let Some(at) = previous {
            last_working.insert(w.pid, at);
        }

        let attention = reported_attention(hook, || permission_prompt_for(w.pid));
        readings.insert(
            w.pid,
            Reading {
                activity: reported_activity(state.working, within_grace, hook_says_idle),
                cpu_percent: state.average.unwrap_or(0.0),
                memory_mb,
                attention,
            },
        );
        states.insert(w.pid, state);
    }

    t.states = states;
    t.last_working = last_working;
    t.readings = readings;
}

fn reported_attention(
    hook: Option<&HookRecord>,
    fallback: impl FnOnce() -> Option<Attention>,
) -> Option<Attention> {
    match hook {
        Some(record) => record.attention,
        None => fallback(),
    }
}

fn reported_activity(working: bool, within_grace: bool, hook_says_idle: bool) -> Activity {
    if working || (within_grace && !hook_says_idle) {
        Activity::Working
    } else {
        Activity::Idle
    }
}

fn step(state: State, sample: f64, fresh_evidence: bool, hook: Option<bool>) -> State {
    let mut next = state;
    let clamped = sample.max(0.0);
    let average = match state.average {
        Some(previous) => previous + ALPHA * (clamped - previous),
        None => clamped,
    };
    next.average = Some(average);

    let mut baseline = state.baseline.unwrap_or(average);
    if state.working {
        let floor = state.episode_floor.unwrap_or(average).min(average);
        next.episode_floor = Some(floor);
        if floor > baseline {
            baseline = (baseline + BASELINE_CREEP_PER_TICK).min(floor);
        }
    } else {
        next.episode_floor = None;
        baseline = if average < baseline {
            average
        } else {
            (baseline + BASELINE_CREEP_PER_TICK).min(average)
        };
    }
    next.baseline = Some(baseline);

    next.working = match hook {
        Some(working) => working,
        None => {
            let delta = if state.working {
                OFF_DELTA_PERCENT
            } else {
                ON_DELTA_PERCENT
            };
            fresh_evidence || average >= baseline + delta || average >= HARD_WORKING_FLOOR_PERCENT
        }
    };
    next
}

struct Proc {
    ppid: u32,
    pcpu: f64,
    rss: f64,
}

#[cfg(not(windows))]
fn process_table() -> Option<HashMap<u32, Proc>> {
    let out = std::process::Command::new("ps")
        .args(["-axo", "pid=,ppid=,pcpu=,rss="])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut table = HashMap::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let (Some(pid), Some(ppid), Some(pcpu), Some(rss)) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let (Ok(pid), Ok(ppid), Ok(pcpu), Ok(rss)) =
            (pid.parse(), ppid.parse(), pcpu.parse(), rss.parse())
        else {
            continue;
        };
        table.insert(pid, Proc { ppid, pcpu, rss });
    }
    Some(table)
}

#[cfg(windows)]
fn process_table() -> Option<HashMap<u32, Proc>> {
    windows_processes::table()
}

#[cfg(any(windows, test))]
fn process_cpu_percent(
    previous: Option<(u64, u64)>,
    created: u64,
    ticks: u64,
    elapsed: Duration,
) -> f64 {
    let Some((old_created, old_ticks)) = previous else {
        return 0.0;
    };
    if created != old_created || ticks < old_ticks || elapsed.is_zero() {
        return 0.0;
    }
    (ticks - old_ticks) as f64 / 100_000.0 / elapsed.as_secs_f64()
}

#[cfg(windows)]
mod windows_processes {
    use super::*;
    use crate::win32::{self, FileTime};
    use std::os::windows::io::AsRawHandle;

    struct Samples {
        at: Instant,
        times: HashMap<u32, (u64, u64)>,
    }

    fn ticks(time: FileTime) -> u64 {
        (u64::from(time.high) << 32) | u64::from(time.low)
    }

    pub(super) fn table() -> Option<HashMap<u32, Proc>> {
        static PREVIOUS: OnceLock<Mutex<Option<Samples>>> = OnceLock::new();
        let mut previous = PREVIOUS.get_or_init(|| Mutex::new(None)).lock().ok()?;

        let snapshot = unsafe { win32::handle_to_owned(win32::CreateToolhelp32Snapshot(2, 0)) }?;
        let now = Instant::now();
        let elapsed = previous
            .as_ref()
            .map(|p| now.duration_since(p.at))
            .unwrap_or_default();
        let mut entry: win32::ProcessEntry32 = unsafe { std::mem::zeroed() };
        entry.size = std::mem::size_of::<win32::ProcessEntry32>() as u32;
        if unsafe { win32::Process32FirstW(snapshot.as_raw_handle(), &mut entry) } == 0 {
            return None;
        }
        let mut table = HashMap::new();
        let mut times = HashMap::new();
        loop {
            let mut cpu = 0.0;
            let mut rss = 0.0;
            let process =
                unsafe { win32::handle_to_owned(win32::OpenProcess(0x1000, 0, entry.pid)) };
            if let Some(process) = process {
                let zero = || FileTime { low: 0, high: 0 };
                let (mut created, mut exited, mut kernel, mut user) =
                    (zero(), zero(), zero(), zero());
                if unsafe {
                    win32::GetProcessTimes(
                        process.as_raw_handle(),
                        &mut created,
                        &mut exited,
                        &mut kernel,
                        &mut user,
                    )
                } != 0
                {
                    let created = ticks(created);
                    let used = ticks(kernel).saturating_add(ticks(user));
                    let old = previous
                        .as_ref()
                        .and_then(|p| p.times.get(&entry.pid))
                        .copied();
                    cpu = process_cpu_percent(old, created, used, elapsed);
                    times.insert(entry.pid, (created, used));
                }
                let mut memory: win32::ProcessMemoryCounters = unsafe { std::mem::zeroed() };
                memory.size = std::mem::size_of::<win32::ProcessMemoryCounters>() as u32;
                if unsafe {
                    win32::K32GetProcessMemoryInfo(
                        process.as_raw_handle(),
                        &mut memory,
                        memory.size,
                    )
                } != 0
                {
                    rss = memory.working_set as f64 / 1024.0;
                }
            }

            table.insert(
                entry.pid,
                Proc {
                    ppid: entry.parent_pid,
                    pcpu: cpu,
                    rss,
                },
            );
            if unsafe { win32::Process32NextW(snapshot.as_raw_handle(), &mut entry) } == 0 {
                break;
            }
        }
        *previous = Some(Samples { at: now, times });
        Some(table)
    }
}

#[cfg(test)]
mod process_sampling_tests {
    use super::*;

    #[test]
    fn process_cpu_tracks_elapsed_work_without_reusing_a_recycled_pid() {
        let previous = Some((42, 10_000_000));
        assert_eq!(
            process_cpu_percent(previous, 42, 15_000_000, Duration::from_secs(1)),
            50.0
        );
        assert_eq!(
            process_cpu_percent(previous, 42, 30_000_000, Duration::from_secs(1)),
            200.0
        );
        assert_eq!(
            process_cpu_percent(previous, 43, 30_000_000, Duration::from_secs(1)),
            0.0
        );
        assert_eq!(
            process_cpu_percent(previous, 42, 1, Duration::from_secs(1)),
            0.0
        );
        assert_eq!(
            process_cpu_percent(previous, 42, 30_000_000, Duration::ZERO),
            0.0
        );
        assert_eq!(
            process_cpu_percent(None, 42, 30_000_000, Duration::from_secs(1)),
            0.0
        );
    }
}

fn children_index(table: &HashMap<u32, Proc>) -> HashMap<u32, Vec<u32>> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (pid, proc) in table {
        children.entry(proc.ppid).or_default().push(*pid);
    }
    children
}

fn subtree_usage(
    table: &HashMap<u32, Proc>,
    children: &HashMap<u32, Vec<u32>>,
    root: u32,
) -> Usage {
    let mut cpu = 0.0;
    let mut rss_kb = 0.0;
    let mut pids = HashSet::new();
    let mut stack = vec![root];
    let mut seen = 0usize;
    while let Some(pid) = stack.pop() {
        if !pids.insert(pid) {
            continue;
        }

        seen += 1;
        if seen > 10_000 {
            break;
        }
        if let Some(proc) = table.get(&pid) {
            cpu += proc.pcpu;
            rss_kb += proc.rss;
        }
        if let Some(kids) = children.get(&pid) {
            stack.extend(kids.iter().copied());
        }
    }
    Usage {
        cpu_percent: cpu,
        memory_mb: rss_kb / 1024.0,
        pids,
    }
}

#[derive(Default)]
struct Usage {
    cpu_percent: f64,
    memory_mb: f64,
    pids: HashSet<u32>,
}

fn transcript_touched(harness: &str, cwd: &str) -> Option<Duration> {
    let home = tokenstat_paths::home_dir()?.display().to_string();
    let dir: PathBuf = match harness {
        "claude" => {
            let slug: String = cwd
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect();
            format!("{home}/.claude/projects/{slug}").into()
        }
        "grok" => {
            let encoded = percent_encoded_directory(cwd);
            format!("{home}/.grok/sessions/{encoded}").into()
        }

        "codex" => return None,
        _ => return None,
    };
    let newest = newest_write_cached(&dir.to_string_lossy(), 1)?;
    SystemTime::now().duration_since(newest).ok()
}

fn percent_encoded_directory(cwd: &str) -> String {
    cwd.bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_') {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

fn newest_write_cached(dir: &str, depth: usize) -> Option<SystemTime> {
    struct Cached {
        at: Instant,
        value: Option<SystemTime>,
    }
    static CACHE: OnceLock<Mutex<HashMap<String, Cached>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock()
        && let Some(hit) = guard.get(dir)
        && hit.at.elapsed() < Duration::from_millis(900)
    {
        return hit.value;
    }
    let value = newest_write(dir, depth);
    if let Ok(mut guard) = cache.lock() {
        guard.retain(|_, entry| entry.at.elapsed() < Duration::from_secs(60));
        guard.insert(
            dir.to_string(),
            Cached {
                at: Instant::now(),
                value,
            },
        );
    }
    value
}

fn newest_write(dir: &str, depth: usize) -> Option<SystemTime> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut newest: Option<SystemTime> = None;
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        if meta.is_dir() {
            if depth > 1
                && let Some(at) = newest_write(&entry.path().to_string_lossy(), depth - 1)
            {
                newest = Some(newest.map_or(at, |best| best.max(at)));
            }
            continue;
        }
        if let Ok(at) = meta.modified() {
            newest = Some(newest.map_or(at, |best| best.max(at)));
        }
    }
    newest
}

struct HookRecord {
    observed_at_ms: u64,
    cwd: Option<String>,
    agent: Option<String>,
    agent_pid: Option<u32>,
    owner_pid: Option<u32>,
    working: bool,
    attention: Option<Attention>,
}

const PERMISSION_MARKERS: &[&str] = &[
    "Do you want to proceed",
    "Yes, and don't ask again",
    "Allow this command",
    "Approve and run",
    "waiting-approval",
    "Do you want to allow",
];

fn permission_prompt_for(pid: u32) -> Option<Attention> {
    let bytes = tokenstat_pty::manager().tail_since_input_for_pid(pid, 8 * 1024)?;
    let tail = String::from_utf8_lossy(&bytes);
    permission_prompt_in(&tail).then_some(Attention::Permission)
}

fn permission_prompt_in(tail: &str) -> bool {
    PERMISSION_MARKERS.iter().any(|m| tail.contains(m))
}

impl HookRecord {
    fn matches(&self, watch: &Watch, subtree: &HashSet<u32>) -> bool {
        if self.observed_at_ms < watch.started_at_ms
            || self.attention.is_some() && self.observed_at_ms <= watch.last_input_at_ms
        {
            return false;
        }
        if let Some(pid) = self.agent_pid {
            return subtree.contains(&pid);
        }
        if let Some(pid) = self.owner_pid {
            return subtree.contains(&pid);
        }
        if self.cwd.as_deref() != Some(watch.cwd.as_str()) {
            return false;
        }
        match (&self.agent, &watch.harness) {
            (Some(a), Some(b)) => a == b,
            (Some(_), None) => false,

            (None, _) => true,
        }
    }
}

fn hook_records() -> Vec<HookRecord> {
    let Some(home) = tokenstat_paths::home_dir() else {
        return Vec::new();
    };
    let home = home.display();
    let dir = format!("{home}/Library/Application Support/Keepresso/agent-hooks");
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };

        if meta
            .modified()
            .ok()
            .and_then(|at| SystemTime::now().duration_since(at).ok())
            .is_some_and(|age| age > HOOK_STALE)
        {
            continue;
        }
        if !meta.is_file() || meta.len() > 64 * 1024 {
            continue;
        }
        let Ok(text) = read_hook(&entry.path()) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        let state = value.get("state").and_then(|v| v.as_str()).unwrap_or("");
        let detail = value.get("detail").and_then(|v| v.as_str());

        let waiting = state == "waiting" || detail == Some("waiting-approval");
        out.push(HookRecord {
            observed_at_ms: meta
                .modified()
                .ok()
                .and_then(|at| at.duration_since(SystemTime::UNIX_EPOCH).ok())
                .map(|age| age.as_millis() as u64)
                .unwrap_or(0),
            cwd: value
                .get("cwd")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            agent: value
                .get("agent")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            agent_pid: value
                .get("agentPid")
                .and_then(|v| v.as_u64())
                .and_then(|v| u32::try_from(v).ok()),
            owner_pid: value
                .get("ownerPid")
                .and_then(|v| v.as_u64())
                .and_then(|v| u32::try_from(v).ok()),
            working: state == "working",
            attention: waiting.then_some(Attention::Permission),
        });
    }
    out
}

fn read_hook(path: &std::path::Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other("hook record is not a regular file"));
    }
    let mut text = String::new();
    file.take(64 * 1024 + 1).read_to_string(&mut text)?;
    if text.len() > 64 * 1024 {
        return Err(std::io::Error::other("hook record is too large"));
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directory_encoding_uses_utf8_bytes_and_windows_commands_have_plain_names() {
        assert_eq!(percent_encoded_directory("/界"), "%2F%E7%95%8C");
        assert_eq!(
            harness_of(r"C:\tools\claude.exe").as_deref(),
            Some("claude")
        );
    }

    #[test]
    fn quiet_session_reads_idle() {
        let mut state = State::default();
        for _ in 0..30 {
            state = step(state, 1.0, false, None);
        }
        assert!(!state.working);
    }

    #[test]
    fn rise_above_baseline_reads_working() {
        let mut state = State::default();
        for _ in 0..30 {
            state = step(state, 2.0, false, None);
        }
        assert!(!state.working);
        for _ in 0..30 {
            state = step(state, 40.0, false, None);
        }
        assert!(state.working);
    }

    #[test]
    fn hot_idle_session_still_reads_idle() {
        let mut state = State::default();
        for _ in 0..60 {
            state = step(state, 11.0, false, None);
        }
        assert!(!state.working);
    }

    #[test]
    fn session_born_busy_reads_working() {
        let mut state = State::default();
        for _ in 0..10 {
            state = step(state, 120.0, false, None);
        }
        assert!(state.working);
    }

    #[test]
    fn hysteresis_holds_through_a_dip() {
        let mut state = State::default();
        for _ in 0..30 {
            state = step(state, 2.0, false, None);
        }
        for _ in 0..30 {
            state = step(state, 40.0, false, None);
        }
        assert!(state.working);
        state = step(state, 3.0, false, None);
        assert!(state.working);
    }

    #[test]
    fn hook_state_beats_the_measurement() {
        let mut state = State::default();
        for _ in 0..30 {
            state = step(state, 200.0, false, Some(false));
        }
        assert!(!state.working, "a hook saying idle wins over hot CPU");
        state = step(state, 0.0, false, Some(true));
        assert!(state.working, "a hook saying working wins over no CPU");
    }

    fn watch(harness: Option<&str>) -> Watch {
        Watch {
            pid: 1,
            cwd: "/work".into(),
            harness: harness.map(str::to_string),
            started_at_ms: 0,
            last_input_at_ms: 0,
        }
    }

    fn record(agent: Option<&str>) -> HookRecord {
        HookRecord {
            observed_at_ms: 1,
            cwd: Some("/work".into()),
            agent: agent.map(str::to_string),
            agent_pid: None,
            owner_pid: None,
            working: true,
            attention: None,
        }
    }

    #[test]
    fn permission_prompt_markers_are_narrow() {
        assert!(permission_prompt_in(
            "Do you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again"
        ));
        assert!(permission_prompt_in("Allow this command to run?"));
        assert!(
            !permission_prompt_in("edit crates/tokenstat-host/src/activity.rs"),
            "a file path about activity is not a prompt"
        );
        assert!(
            !permission_prompt_in("checking file permissions on the tree"),
            "talking about permissions is not a prompt"
        );
    }

    #[test]
    fn lifecycle_clear_does_not_resurrect_a_prompt() {
        let mut hook = record(Some("claude"));
        assert_eq!(
            reported_attention(Some(&hook), || Some(Attention::Permission)),
            None
        );
        hook.attention = Some(Attention::Permission);
        assert_eq!(
            reported_attention(Some(&hook), || None),
            Some(Attention::Permission)
        );
        assert_eq!(
            reported_attention(None, || Some(Attention::Permission)),
            Some(Attention::Permission)
        );
    }

    #[test]
    fn answered_or_previous_launch_hooks_cannot_pin_attention() {
        let mut hook = record(Some("claude"));
        hook.observed_at_ms = 100;
        hook.attention = Some(Attention::Permission);
        let mut session = watch(Some("claude"));
        session.last_input_at_ms = 101;
        assert!(!hook.matches(&session, &subtree(&[])));
        hook.observed_at_ms = 102;
        assert!(
            hook.matches(&session, &subtree(&[])),
            "a newly reported wait is still authoritative"
        );
        session.started_at_ms = 103;
        assert!(
            !hook.matches(&session, &subtree(&[])),
            "a pooled or reused process must not adopt a previous launch"
        );
    }

    fn subtree(pids: &[u32]) -> HashSet<u32> {
        pids.iter().copied().collect()
    }

    #[test]
    fn a_hook_record_belongs_to_one_agent() {
        let none = subtree(&[]);
        assert!(record(Some("claude")).matches(&watch(Some("claude")), &none));
        assert!(
            !record(Some("claude")).matches(&watch(Some("grok")), &none),
            "grok must not adopt claude's verdict"
        );
        assert!(
            !record(Some("claude")).matches(&watch(None), &none),
            "an unnamed session must not adopt a named record"
        );
        assert!(record(None).matches(&watch(Some("grok")), &none));
    }

    #[test]
    fn a_hook_record_stays_in_its_own_directory() {
        let mut elsewhere = watch(Some("claude"));
        elsewhere.cwd = "/somewhere-else".into();
        assert!(!record(Some("claude")).matches(&elsewhere, &subtree(&[])));
    }

    #[test]
    fn two_of_the_same_agent_in_one_folder_do_not_share_a_verdict() {
        let mut theirs = record(Some("claude"));
        theirs.agent_pid = Some(4242);
        assert!(
            theirs.matches(&watch(Some("claude")), &subtree(&[7, 4242])),
            "a record naming a pid we own is ours"
        );
        assert!(
            !theirs.matches(&watch(Some("claude")), &subtree(&[7, 8])),
            "a record naming a pid we do not own is somebody else's"
        );
    }

    #[test]
    fn an_owner_pid_also_identifies_a_session() {
        let mut hosted = record(None);
        hosted.owner_pid = Some(99);
        assert!(hosted.matches(&watch(None), &subtree(&[99])));
        assert!(!hosted.matches(&watch(None), &subtree(&[1])));
    }

    #[test]
    fn fresh_transcript_beats_quiet_cpu() {
        let mut state = State::default();
        for _ in 0..30 {
            state = step(state, 0.0, false, None);
        }
        assert!(!state.working);
        state = step(state, 0.0, true, None);
        assert!(state.working);
    }

    #[test]
    fn grace_does_not_override_hook_idle() {
        assert_eq!(
            reported_activity(false, true, true),
            Activity::Idle,
            "hook idle must win even when the grace clock is still running"
        );
        assert_eq!(
            reported_activity(false, true, false),
            Activity::Working,
            "grace still holds when no hook said idle"
        );
        assert_eq!(
            reported_activity(true, false, true),
            Activity::Working,
            "a hook saying working is working"
        );
    }
}
