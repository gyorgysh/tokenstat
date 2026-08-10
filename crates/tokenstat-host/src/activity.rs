// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Is this session working, or is it just sitting there.
//!
//! `alive` answers whether a process exists, which is not the question anyone
//! looking at a sidebar is asking. This module answers the real one, from
//! three sources in decreasing order of authority:
//!
//! 1. **Hook records.** An agent that supports lifecycle hooks says outright
//!    what it is doing. Nothing beats being told.
//! 2. **Transcript writes.** The agent appended to its session log moments
//!    ago, so it is mid-turn. tokenstat already knows where every one of
//!    those logs lives, because parsing them is what it does.
//! 3. **Subtree CPU.** Everything else, measured against a level the session
//!    itself teaches us.
//!
//! Point 3 is the hard one and the thresholds here are not invented. An idle
//! `claude` sits near 0-2% of a core, an idle `grok` near 2-3%, and an editor
//! agent animating its spinner burns 6-12% while doing nothing at all, so a
//! fixed "busy" line is wrong for every agent at once. Each session instead
//! learns its own idle level as a decaying minimum of its smoothed CPU, and
//! working means the average rose a dead band above that, with hysteresis so
//! a session hovering at the boundary does not flicker. An absolute floor
//! catches a session that was already busy when first seen, whose baseline
//! would otherwise be learned at the working level.
//!
//! The release grace is what makes it usable: a model turn spends most of its
//! time waiting on a network round trip at zero CPU, and without the grace
//! every agent would blink idle between tokens.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

/// How far above its own baseline (percent of one core) a session's smoothed
/// CPU must rise to count as working.
const ON_DELTA_PERCENT: f64 = 4.0;
/// How far above the baseline it must stay to keep counting as working. The
/// gap between this and `ON_DELTA_PERCENT` is the hysteresis dead band.
const OFF_DELTA_PERCENT: f64 = 1.5;
/// Smoothed CPU at which a session is working whatever its baseline says. No
/// agent idles this hot, and this is what catches a session first sampled
/// mid-task, whose learned baseline is already at the working level.
const HARD_WORKING_FLOOR_PERCENT: f64 = 20.0;
/// How fast the learned baseline drifts upward per tick. It snaps downward
/// instantly, because a new low is new information about the idle level,
/// while a rise has to be earned.
const BASELINE_CREEP_PER_TICK: f64 = 0.05;
/// Smoothing weight for each new sample. At one sample a second this settles
/// a real change within a few seconds while damping the large tick-to-tick
/// noise of an animated terminal UI.
const ALPHA: f64 = 0.25;
/// How long a session stays "working" after the evidence stops.
///
/// Three minutes. A minute would bridge a typical network wait but not a slow
/// model turn or a long tool call, and a row that says Idle while the agent
/// is mid-thought is worse than one that lags going quiet.
const GRACE: Duration = Duration::from_secs(180);
/// How recently a transcript must have been written to count as proof of
/// work.
const EVIDENCE_FRESH: Duration = Duration::from_secs(15);
/// How long a hook record may go unwritten before it is ignored. A crashed
/// agent leaves its last record on disk saying "working" forever.
const HOOK_STALE: Duration = Duration::from_secs(900);
/// How often the sampler runs. One `ps` per second for the whole process
/// table, which is what the smoothing constants above are tuned against.
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
}

/// Per-session smoothing state.
///
/// Keyed by pid and rebuilt from the live set on every tick, so a pid that
/// the system reuses for an unrelated process starts from nothing rather
/// than inheriting a dead session's learned baseline.
#[derive(Debug, Clone, Copy, Default)]
struct State {
    average: Option<f64>,
    /// The learned idle level: a decaying minimum of `average`.
    baseline: Option<f64>,
    /// Lowest average seen during the current working episode, the ceiling
    /// the baseline may creep toward while working. Bursty real work keeps
    /// its headroom this way, while an idle level that genuinely rose during
    /// the episode (a leftover dev server the agent started) is eventually
    /// adopted, so the session is allowed to go idle again.
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
}

struct Tracker {
    states: HashMap<u32, State>,
    /// Last moment each pid had positive evidence, for the release grace.
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
                std::thread::sleep(TICK);
            }
        })
        .ok();
}

/// Which sessions to watch, taken from the pty manager on every tick so a
/// spawn is picked up without anything having to register itself.
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
            })
        })
        .collect()
}

/// The harness a command belongs to, by the name it was launched under.
///
/// Deliberately matched on the executable name rather than on a launcher id:
/// a session adopted from a daemon that outlived the app has a command line
/// and nothing else.
fn harness_of(command: &str) -> Option<String> {
    let name = command.rsplit('/').next().unwrap_or(command).trim();
    // Every session gets a name, not only the three with transcripts we know
    // how to find. The name is what stops one agent's hook record from being
    // adopted by a different agent running in the same directory, so a shell
    // being called "zsh" is exactly as useful here as an agent being called
    // "claude".
    (!name.is_empty()).then(|| name.to_string())
}

/// Advance every watched session by one sample.
fn tick() {
    let watches = watches();
    if watches.is_empty() {
        let mut t = tracker().lock().unwrap_or_else(|e| e.into_inner());
        t.states.clear();
        t.last_working.clear();
        t.readings.clear();
        return;
    }

    let table = process_table();
    let hooks = hook_records();
    let now = Instant::now();

    let mut t = tracker().lock().unwrap_or_else(|e| e.into_inner());
    let mut states = HashMap::with_capacity(watches.len());
    let mut last_working = HashMap::with_capacity(watches.len());
    let mut readings = HashMap::with_capacity(watches.len());

    for w in &watches {
        let usage = table.as_ref().map(|table| subtree_usage(table, w.pid));
        let (sample, memory_mb) = usage
            .as_ref()
            .map(|u| (u.cpu_percent, u.memory_mb))
            .unwrap_or((0.0, 0.0));
        let subtree = usage.map(|u| u.pids).unwrap_or_default();
        let hook = hooks
            .iter()
            .find(|r| r.matches(w, &subtree))
            .map(|r| r.working);
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
            hook,
        );

        // The grace is applied to the answer, not to the state machine: the
        // EMA and the baseline must keep learning through a quiet stretch, or
        // a session held "working" by the grace would come out of it with a
        // baseline learned three minutes ago.
        let previous = t.last_working.get(&w.pid).copied();
        let within_grace = previous.is_some_and(|at| now.duration_since(at) < GRACE);
        if state.working {
            last_working.insert(w.pid, now);
        } else if let Some(at) = previous {
            last_working.insert(w.pid, at);
        }

        readings.insert(
            w.pid,
            Reading {
                activity: if state.working || within_grace {
                    Activity::Working
                } else {
                    Activity::Idle
                },
                cpu_percent: state.average.unwrap_or(0.0),
                memory_mb,
            },
        );
        states.insert(w.pid, state);
    }

    t.states = states;
    t.last_working = last_working;
    t.readings = readings;
}

/// One decision step. Pure, so the thresholds can be tested without a
/// process table.
fn step(state: State, sample: f64, fresh_evidence: bool, hook: Option<bool>) -> State {
    let mut next = state;
    let clamped = sample.max(0.0);
    let average = match state.average {
        Some(previous) => previous + ALPHA * (clamped - previous),
        None => clamped,
    };
    next.average = Some(average);

    // Learn the idle level while idle: snap down to any new minimum, drift
    // up slowly toward the observed average. While working it never snaps
    // down, because a dip mid-task is not a new idle level, and it creeps up
    // only toward the lowest average this episode has seen.
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
        // Being told beats every measurement.
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

/// One row of `ps` output.
struct Proc {
    ppid: u32,
    pcpu: f64,
    /// Resident set size in kilobytes, as `ps` reports it.
    rss: f64,
}

/// Every process with its parent and CPU share, in one call.
///
/// One `ps` for the whole table rather than one per session: the cost is the
/// same whether one agent is running or ten, and a per-session call would
/// scale a once-a-second sample by however many terminals are open.
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

/// CPU of a process and everything descended from it.
///
/// The subtree and not the process alone, because an agent's real work is
/// mostly its children: a build, a test run, a language server. The agent
/// process itself can sit at nothing while the machine is flat out on its
/// behalf.
fn subtree_usage(table: &HashMap<u32, Proc>, root: u32) -> Usage {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (pid, proc) in table {
        children.entry(proc.ppid).or_default().push(*pid);
    }
    let mut cpu = 0.0;
    let mut rss_kb = 0.0;
    let mut pids = HashSet::new();
    let mut stack = vec![root];
    let mut seen = 0usize;
    while let Some(pid) = stack.pop() {
        if !pids.insert(pid) {
            continue;
        }
        // A malformed table could in principle describe a cycle, and this
        // runs every second in a daemon. Bound it.
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

/// What one session's process subtree is using, and which processes it is.
#[derive(Default)]
struct Usage {
    cpu_percent: f64,
    memory_mb: f64,
    /// Every pid in the subtree, so a hook record can be checked against the
    /// processes this session actually owns rather than against a name.
    pids: HashSet<u32>,
}

/// How long ago the harness last wrote to its transcript for this directory.
///
/// The paths are per-harness and awkward, which is exactly why they are worth
/// having: an agent appends to its session log the moment a turn starts, well
/// before any of it reaches the terminal.
fn transcript_touched(harness: &str, cwd: &str) -> Option<Duration> {
    let home = std::env::var("HOME").ok()?;
    let dir: PathBuf = match harness {
        // ~/.claude/projects/<cwd with every non-alphanumeric as "-">/
        "claude" => {
            let slug: String = cwd
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect();
            format!("{home}/.claude/projects/{slug}").into()
        }
        // ~/.grok/sessions/<percent-encoded cwd>/
        "grok" => {
            let encoded: String = cwd
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == '_' {
                        c.to_string()
                    } else {
                        format!("%{:02X}", c as u32)
                    }
                })
                .collect();
            format!("{home}/.grok/sessions/{encoded}").into()
        }
        // Codex keys its rollouts by date rather than by directory, so the
        // day's folder stands in for the session. Yesterday counts too: a
        // rollout file is created when the session starts, so one running
        // across midnight keeps appending to the previous day's folder.
        "codex" => {
            let newest = newest_write(&format!("{home}/.codex/sessions"), 3);
            return newest.map(|at| SystemTime::now().duration_since(at).unwrap_or_default());
        }
        _ => return None,
    };
    let newest = newest_write(&dir.to_string_lossy(), 1)?;
    Some(SystemTime::now().duration_since(newest).unwrap_or_default())
}

/// Newest modification time under a directory, descending at most `depth`
/// levels. Errors are absence: a harness that is not installed has no
/// directory, and that is not a failure.
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

/// A lifecycle-hook record: an agent saying what it is doing.
struct HookRecord {
    cwd: Option<String>,
    agent: Option<String>,
    /// The pid the record is about, and the pid that owns it (an editor or
    /// app hosting the agent). Either being inside a session's own process
    /// subtree is proof the record belongs to that session.
    agent_pid: Option<u32>,
    owner_pid: Option<u32>,
    working: bool,
}

impl HookRecord {
    /// Does this record describe this session.
    ///
    /// Process identity first, and it is the only answer worth trusting. A
    /// directory routinely has several agents in it, and often several of the
    /// *same* agent: a second Claude Code in the same folder, or one running
    /// outside tokenstat entirely. Matching on directory and name meant every
    /// one of them adopted the busiest record in the folder, so a freshly
    /// opened agent sitting at an empty prompt reported Working because
    /// something else nearby was mid-turn.
    ///
    /// A record that names no pid falls back to directory and agent name,
    /// which is weak evidence but better than none, and cannot be worse than
    /// the CPU heuristic it is standing in for.
    fn matches(&self, watch: &Watch, subtree: &HashSet<u32>) -> bool {
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
            // Both named: they have to be the same agent.
            (Some(a), Some(b)) => a == b,
            // The record names an agent and this session does not. Refuse it.
            (Some(_), None) => false,
            // The record does not say which agent it is, so the directory is
            // all there is to go on.
            (None, _) => true,
        }
    }
}

/// Hook records written by Keepresso, when it is installed.
///
/// Read, never written. Keepresso installs the hooks, owns the format, and
/// keeps the files current; tokenstat is a reader of somebody else's data
/// here, exactly like every log it parses. Nothing is required: with no
/// Keepresso on the machine this is an empty list and the CPU heuristic
/// decides on its own.
fn hook_records() -> Vec<HookRecord> {
    let Ok(home) = std::env::var("HOME") else {
        return Vec::new();
    };
    let dir = format!("{home}/Library/Application Support/Keepresso/agent-hooks");
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        // A crashed agent never writes its closing record, so an old file
        // would claim "working" until someone deleted it.
        if meta
            .modified()
            .ok()
            .and_then(|at| SystemTime::now().duration_since(at).ok())
            .is_some_and(|age| age > HOOK_STALE)
        {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        let state = value.get("state").and_then(|v| v.as_str()).unwrap_or("");
        let detail = value.get("detail").and_then(|v| v.as_str());
        out.push(HookRecord {
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
                .map(|v| v as u32),
            owner_pid: value
                .get("ownerPid")
                .and_then(|v| v.as_u64())
                .map(|v| v as u32),
            // "waiting" is the agent asking the user something. It is not
            // working, and a row that says Working while it waits for a
            // permission answer is why nobody would trust the indicator. The
            // exception is a pending approval, where the agent is blocked
            // mid-task and will resume the moment it is answered.
            working: state == "working"
                || (state == "waiting" && detail == Some("waiting-approval")),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

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
        // Learn an idle level near 2%, the sort a quiet agent sits at.
        for _ in 0..30 {
            state = step(state, 2.0, false, None);
        }
        assert!(!state.working);
        for _ in 0..30 {
            state = step(state, 40.0, false, None);
        }
        assert!(state.working);
    }

    /// The point of the learned baseline: an agent that idles hot must not
    /// read as working just because its floor is high.
    #[test]
    fn hot_idle_session_still_reads_idle() {
        let mut state = State::default();
        for _ in 0..60 {
            state = step(state, 11.0, false, None);
        }
        assert!(!state.working);
    }

    /// A session first seen mid-task learns its baseline at the working
    /// level, so only the absolute floor can catch it.
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
        // A single quiet sample must not flip it.
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
        }
    }

    fn record(agent: Option<&str>) -> HookRecord {
        HookRecord {
            cwd: Some("/work".into()),
            agent: agent.map(str::to_string),
            agent_pid: None,
            owner_pid: None,
            working: true,
        }
    }

    fn subtree(pids: &[u32]) -> HashSet<u32> {
        pids.iter().copied().collect()
    }

    /// Two agents in one directory is the normal case, not the exotic one.
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

    /// The case that made a freshly opened agent claim to be working: another
    /// Claude Code, in the same folder, mid-turn. Same directory, same agent
    /// name, different process.
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

    /// An agent hosted by an editor reports the host's pid, not its own.
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
}
