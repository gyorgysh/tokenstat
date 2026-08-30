//! Daemon-owned agent jobs: a backend, a prompt, a schedule, and a budget.
//!
//! Automations are deliberately separate from `tokenstat_workspace::gitwrite`.
//! This module owns persistence, scheduling, and the run budget. A job may run
//! an agent that changes a repository, but no timer calls a gitwrite function.
//!
//! A run is an agent CLI launched headless in a pty, exactly as a person would
//! launch it in a terminal. Output drains into a transcript file as it is
//! produced, so a run can be watched live and replayed later. The pty is owned
//! by the host and killed when the budget expires, so an automation can never
//! run away.

use std::collections::{HashSet, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::transcript::{self, Parser};

use serde::{Deserialize, Serialize};

/// How many completed runs to remember per machine.
const RUNS_KEPT: usize = 100;

/// Default time limit for a new job or card, in seconds (180 minutes).
pub const DEFAULT_BUDGET_SECONDS: u64 = 180 * 60;

/// Default number of agent runs that may execute at once.
pub const DEFAULT_MAX_CONCURRENT: u32 = 2;

/// How often the scheduler looks for due jobs.
const TICK: Duration = Duration::from_secs(5);

/// How fast the transcript drain polls the pty buffer.
const DRAIN_POLL: Duration = Duration::from_millis(20);

/// How long to keep reading after the process has gone.
///
/// Short enough that nobody waits on it, long enough for the terminal's own
/// reader to hand over what the process wrote on its way out.
const DRAIN_TAIL: Duration = Duration::from_millis(300);

/// How long to wait for a finished process to report its exit code.
///
/// Output can end a moment before the process is reaped, and a run that exited
/// cleanly must not be filed as an error because the code had not landed yet.
const EXIT_SETTLE: Duration = Duration::from_secs(2);

// MARK: - Schedule

/// Monday through Friday as a bitset, Monday = bit 0.
const WEEKDAYS_MASK: u8 = 0b0001_1111;

/// The kinds a schedule can take.
///
/// Wire values are camelCase (`once`, `interval`, `daily`, `weekdays`,
/// `weekly`, `custom`). Older files only wrote once/interval/daily/weekly;
/// weekdays and custom are additive. Unknown future kinds fail to decode and
/// the job is refused rather than silently mis-scheduled.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum ScheduleKind {
    /// Fire once, when Run now is pressed. Never fires on its own.
    #[default]
    Once,
    Interval,
    Daily,
    /// Monday through Friday at the wall-clock time.
    Weekdays,
    /// One day of the week (`weekday`), or several when `weekdays` is set.
    Weekly,
    /// Free multi-day pick via the `weekdays` bitset (Monday = bit 0).
    Custom,
}

/// When a job fires. A plain struct rather than a tagged enum so the wire shape
/// is one thing a client can edit field by field.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct ScheduleSpec {
    pub kind: ScheduleKind,
    /// Interval only. Seconds between runs, floored at one minute.
    pub every_seconds: u64,
    /// Wall-clock kinds only. Local hour, 0..23.
    pub hour: u8,
    /// Wall-clock kinds only. Local minute, 0..59.
    pub minute: u8,
    /// Weekly single-day. 0 = Monday, matching the calendar the app draws.
    pub weekday: u8,
    /// Multi-day bitset, Monday = bit 0 … Sunday = bit 6. Used by Custom,
    /// by Weekdays (always Mon–Fri), and by Weekly when more than one day is
    /// selected. Zero with Weekly falls back to the single `weekday` field so
    /// older saves keep working.
    #[serde(default)]
    pub weekdays: u8,
}

impl ScheduleSpec {
    pub fn validate(&self) -> Result<(), String> {
        match self.kind {
            ScheduleKind::Once => Ok(()),
            ScheduleKind::Interval => {
                if self.every_seconds < 60 {
                    Err("an interval must be at least a minute".into())
                } else {
                    Ok(())
                }
            }
            ScheduleKind::Daily | ScheduleKind::Weekdays => self.validate_time(),
            ScheduleKind::Weekly => {
                self.validate_time()?;
                if self.day_mask() == 0 {
                    Err("a weekly schedule needs at least one day".into())
                } else {
                    Ok(())
                }
            }
            ScheduleKind::Custom => {
                self.validate_time()?;
                if self.weekdays == 0 || self.weekdays & 0b0111_1111 == 0 {
                    Err("a custom schedule needs at least one day".into())
                } else {
                    Ok(())
                }
            }
        }
    }

    fn validate_time(&self) -> Result<(), String> {
        if self.hour > 23 || self.minute > 59 {
            Err("a schedule time must be a real hour and minute".into())
        } else {
            Ok(())
        }
    }

    /// Days of the week this schedule fires on, Monday = bit 0.
    /// Zero means "not a multi-day wall-clock mask": Daily ignores this and
    /// uses every day at the call site; Once/Interval never consult it.
    fn day_mask(&self) -> u8 {
        match self.kind {
            ScheduleKind::Once | ScheduleKind::Interval | ScheduleKind::Daily => 0,
            ScheduleKind::Weekdays => WEEKDAYS_MASK,
            ScheduleKind::Weekly => {
                if self.weekdays & 0b0111_1111 != 0 {
                    self.weekdays & 0b0111_1111
                } else if self.weekday <= 6 {
                    1u8 << self.weekday
                } else {
                    0
                }
            }
            ScheduleKind::Custom => self.weekdays & 0b0111_1111,
        }
    }

    /// The next time this fires, or None for a once job.
    pub fn next_run_ms(&self, from: i64) -> Option<i64> {
        match self.kind {
            ScheduleKind::Once => None,
            ScheduleKind::Interval => Some(from + self.every_seconds as i64 * 1000),
            ScheduleKind::Daily => next_wall_clock(from, self.hour, self.minute, None),
            ScheduleKind::Weekdays | ScheduleKind::Weekly | ScheduleKind::Custom => {
                let mask = self.day_mask();
                if mask == 0 {
                    return None;
                }
                next_wall_clock(from, self.hour, self.minute, Some(mask))
            }
        }
    }
}

/// Next local occurrence of hour:minute, optionally restricted to a day mask.
///
/// The mask uses Monday = bit 0 so the picker matches the calendar the app
/// already draws. Pass `None` for every day. The result is strictly after
/// `from_ms`.
fn next_wall_clock(from_ms: i64, hour: u8, minute: u8, day_mask: Option<u8>) -> Option<i64> {
    use jiff::civil::DateTime;
    use jiff::tz::TimeZone;

    let from = jiff::Timestamp::from_millisecond(from_ms).ok()?;
    let tz = TimeZone::system();
    let zoned = from.to_zoned(tz.clone());
    let mut day = zoned.date();
    // A schedule within a year of today is far more than anybody asks for.
    for _ in 0..400 {
        let on_day = match day_mask {
            None => true,
            Some(mask) => {
                let bit = 1u8 << (day.weekday().to_monday_zero_offset() as u8);
                mask & bit != 0
            }
        };
        if on_day {
            let dt = DateTime::new(
                day.year(),
                day.month(),
                day.day(),
                hour as i8,
                minute as i8,
                0,
                0,
            )
            .ok()?;
            let z = dt.to_zoned(tz.clone()).ok()?;
            let ms = z.timestamp().as_millisecond();
            if ms > from_ms {
                return Some(ms);
            }
        }
        day = day.tomorrow().ok()?;
    }
    None
}

// MARK: - Backends

/// The agent CLIs a job can run, with the flags that make them headless.
///
/// Each launches in the workspace folder, reads the prompt from argv, and
/// prints to stdout. That is the whole contract: if the CLI has a print mode,
/// the automation uses it. `--` before the prompt stops a prompt that starts
/// with `-` from being parsed as a flag.
///
/// `model` and `effort` are passed through only where the CLI advertises the
/// flags; the flags were verified against each CLI's `--help`. A backend whose
/// list is empty never receives them.
pub fn agent_command(
    backend: &str,
    prompt: &str,
    model: Option<&str>,
    effort: Option<&str>,
    budget_seconds: u64,
) -> Result<Vec<String>, String> {
    let p = prompt.trim();
    if p.is_empty() {
        return Err("an automation needs a prompt".into());
    }

    let model = crate::agent_models::sanitize_cli_model(backend, model);
    let model = model.as_deref();
    let mut args: Vec<String> = Vec::new();
    match backend {
        "sh" => {
            args = shell_argv(p).into_iter().map(str::to_string).collect();
        }
        "claude" => {
            args.push("claude".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            if let Some(e) = effort {
                args.push("--effort".into());
                args.push(e.into());
            }
            args.extend(
                [
                    "-p",
                    p,
                    "--output-format",
                    "stream-json",
                    // Claude refuses `--print --output-format=stream-json`
                    // without this ("requires --verbose"); every run failed at
                    // launch until it was added.
                    "--verbose",
                    "--dangerously-skip-permissions",
                ]
                .map(str::to_string),
            );
        }
        "codex" => {
            args.push("codex".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            args.extend(
                [
                    "exec",
                    "--skip-git-repo-check",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "--json",
                    "--",
                    p,
                ]
                .map(str::to_string),
            );
        }
        "grok" => {
            args.push("grok".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            if let Some(e) = effort {
                args.push("--reasoning-effort".into());
                args.push(e.into());
            }
            args.extend(
                [
                    "-p",
                    p,
                    "--output-format",
                    "streaming-json",
                    "--permission-mode",
                    "bypassPermissions",
                ]
                .map(str::to_string),
            );
        }
        "cursor" => {
            args.push("cursor-agent".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            args.extend(
                [
                    "-p",
                    "--output-format",
                    "stream-json",
                    "--stream-partial-output",
                    "--trust",
                    "--",
                    p,
                ]
                .map(str::to_string),
            );
        }
        "agy" => {
            args.push("agy".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            // Effort lives in the model id (`gemini-3.6-flash-high`). Passing
            // `--effort` on top is rejected as unsupported for those models.
            // Host drain is the real stop. Give print enough room that a
            // 180-minute job is not killed by this first.
            let timeout = agy_print_timeout(budget_seconds);
            args.extend(
                [
                    "--print",
                    p,
                    "--output-format",
                    "stream-json",
                    "--print-timeout",
                    timeout.as_str(),
                    // Headless: agy cannot prompt, so a tool that needs
                    // "command" is denied unless this is on.
                    "--dangerously-skip-permissions",
                ]
                .map(str::to_string),
            );
        }
        "opencode" => {
            args.push("opencode".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            if let Some(e) = effort {
                args.push("--variant".into());
                args.push(e.into());
            }
            args.extend(["run", "--auto", "--format", "json", "--", p].map(str::to_string));
        }
        "opencode2" => {
            // OpenCode 2 rejects `--model` on the root command. Flags belong
            // on `run`.
            args.push("opencode2".into());
            args.extend(["run", "--auto", "--format", "json"].map(str::to_string));
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            if let Some(e) = effort {
                args.push("--variant".into());
                args.push(e.into());
            }
            args.extend(["--", p].map(str::to_string));
        }
        other => return Err(format!("unknown backend {other}")),
    }
    Ok(args)
}

/// Chat-only execution choices. Keeping these together avoids an ever-growing
/// command constructor as the chat contract gains capabilities.
pub struct ChatLaunch<'a> {
    pub resume: Option<&'a str>,
    pub bypass: bool,
    /// Absolute path of this daemon for lifecycle hooks. Relative PATH lookup
    /// is wrong for launchd and for the private environment of an agent CLI.
    pub hook_command: Option<&'a str>,
    pub attachments: &'a [std::path::PathBuf],
}

/// Headless argv for a chat turn. Unlike an automation, a chat retains the
/// backend session token after every turn and gives it back on the next one.
/// Keep the backend-specific resume spelling beside `agent_command`: the two
/// paths launch the same CLIs and must not quietly drift apart.
pub fn chat_agent_command(
    backend: &str,
    prompt: &str,
    model: Option<&str>,
    effort: Option<&str>,
    budget_seconds: u64,
    launch: ChatLaunch<'_>,
) -> Result<Vec<String>, String> {
    let mut argv = agent_command(backend, prompt, model, effort, budget_seconds)?;
    // Automations are an explicit background action and retain their existing
    // bypass contract. Chat is interactive: until a backend's hook-based
    // approval channel decides otherwise, it must not inherit those flags.
    // Removing them means a CLI that cannot prompt headlessly fails closed
    // instead of silently editing the workspace.
    if !launch.bypass {
        match backend {
            "claude" | "agy" => argv.retain(|arg| arg != "--dangerously-skip-permissions"),
            "codex" => argv.retain(|arg| arg != "--dangerously-bypass-approvals-and-sandbox"),
            "grok" => {
                argv.retain(|arg| arg != "--permission-mode" && arg != "bypassPermissions");
            }
            "cursor" => argv.retain(|arg| arg != "--trust"),
            "opencode" | "opencode2" => argv.retain(|arg| arg != "--auto"),
            _ => {}
        }
    }
    if backend == "claude" && !launch.bypass {
        if let Some(command) = launch.hook_command {
            // Claude accepts settings JSON directly. The hook itself owns the
            // fail-closed decision; keeping this inline avoids a settings file
            // in the person's project or home directory.
            let settings = serde_json::json!({
                "hooks": {"PreToolUse": [{
                    "matcher": ".*",
                    "hooks": [{"type": "command", "command": format!("{command} hook claude pre")}]
                }]}
            })
            .to_string();
            let at = argv
                .iter()
                .position(|arg| arg == "-p")
                .unwrap_or(argv.len());
            argv.splice(at..at, ["--settings".into(), settings]);
        }
    }
    if backend == "codex" && !launch.bypass && launch.hook_command.is_some() {
        // Codex otherwise silently skips an untrusted hook. The caller gives
        // it a private, tokenstat-owned CODEX_HOME, so this flag is safe only
        // beside that setup and must never be used for the user's home.
        let at = argv
            .iter()
            .position(|arg| arg == "exec")
            .unwrap_or(argv.len());
        argv.splice(at + 1..at + 1, ["--dangerously-bypass-hook-trust".into()]);
    }
    // These two CLIs accept image files natively. The other backends receive
    // the staged paths in the prompt, which lets their normal Read tool make
    // the same files available without pretending they have image support.
    if matches!(backend, "codex" | "opencode" | "opencode2") {
        let flag = if backend == "codex" { "-i" } else { "-f" };
        let at = argv
            .iter()
            .position(|arg| arg == "--")
            .unwrap_or(argv.len());
        let flags = launch
            .attachments
            .iter()
            .flat_map(|path| [flag.to_string(), path.display().to_string()]);
        argv.splice(at..at, flags);
    }
    let Some(token) = launch.resume.filter(|token| !token.trim().is_empty()) else {
        return Ok(argv);
    };
    match backend {
        "claude" => {
            // `--resume` belongs with Claude's print flags, before the prompt.
            let at = argv
                .iter()
                .position(|arg| arg == "-p")
                .unwrap_or(argv.len());
            argv.splice(at..at, ["--resume".into(), token.into()]);
        }
        "codex" => {
            // `codex exec resume <thread>` is a different subcommand shape.
            if let Some(at) = argv.iter().position(|arg| arg == "exec") {
                argv.splice(at + 1..at + 1, ["resume".into(), token.into()]);
            }
        }
        "grok" | "cursor" => {
            let at = argv.len().saturating_sub(1);
            argv.splice(at..at, ["--resume".into(), token.into()]);
        }
        "agy" => {
            let at = argv
                .iter()
                .position(|arg| arg == "--print")
                .unwrap_or(argv.len());
            argv.splice(at..at, ["--conversation".into(), token.into()]);
        }
        "opencode" | "opencode2" => {
            if let Some(at) = argv.iter().position(|arg| arg == "run") {
                argv.splice(at + 1..at + 1, ["-s".into(), token.into()]);
            }
        }
        "sh" => return Err("shell conversations cannot be resumed".into()),
        _ => {}
    }
    Ok(argv)
}

/// Argv for an interactive TTY. Same backends as [`agent_command`], without
/// print / stream-json flags. The front end `pty.spawn`s this so the person
/// can watch the agent. Not an automation run: no transcript, no budget.
pub fn interactive_agent_command(
    backend: &str,
    prompt: &str,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<Vec<String>, String> {
    let p = prompt.trim();
    if p.is_empty() {
        return Err("an interactive run needs a prompt".into());
    }

    let model = crate::agent_models::sanitize_cli_model(backend, model);
    let model = model.as_deref();
    let mut args: Vec<String> = Vec::new();
    match backend {
        "sh" => {
            args = shell_argv(p).into_iter().map(str::to_string).collect();
        }
        "claude" => {
            args.push("claude".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            if let Some(e) = effort {
                args.push("--effort".into());
                args.push(e.into());
            }
            args.extend(["--dangerously-skip-permissions", p].map(str::to_string));
        }
        "codex" => {
            args.push("codex".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            args.extend(
                [
                    "--dangerously-bypass-approvals-and-sandbox",
                    "--skip-git-repo-check",
                    p,
                ]
                .map(str::to_string),
            );
        }
        "grok" => {
            args.push("grok".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            if let Some(e) = effort {
                args.push("--reasoning-effort".into());
                args.push(e.into());
            }
            args.extend(["--permission-mode", "bypassPermissions", p].map(str::to_string));
        }
        "cursor" => {
            args.push("cursor-agent".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            args.extend(["--trust", p].map(str::to_string));
        }
        "agy" => {
            args.push("agy".into());
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            // A positional prompt is ignored. `-i` / `--prompt-interactive`
            // starts the TUI with that first message.
            args.extend(
                ["--dangerously-skip-permissions", "--prompt-interactive", p].map(str::to_string),
            );
        }
        "opencode" => {
            // `--prompt` only fills the TUI box. `run -i` sends the first
            // message and stays in the interactive split-footer, so a task
            // opened In front does not wait for Enter.
            args.push("opencode".into());
            args.extend(["run", "-i", "--auto"].map(str::to_string));
            if let Some(m) = model {
                args.push("--model".into());
                args.push(m.into());
            }
            if let Some(e) = effort {
                args.push("--variant".into());
                args.push(e.into());
            }
            args.extend(["--", p].map(str::to_string));
        }
        "opencode2" => {
            // Root command rejects `--model`. `--prompt` is the TUI seed.
            // OpenCode 2 has no `run -i`. The front end submits Enter once
            // the TUI is up.
            args.push("opencode2".into());
            args.extend(["--auto", "--prompt", p].map(str::to_string));
        }
        other => return Err(format!("unknown backend {other}")),
    }
    Ok(args)
}

/// Agy's print-session ceiling. `0` means no host budget, so use a day.
fn agy_print_timeout(budget_seconds: u64) -> String {
    if budget_seconds == 0 {
        "24h".into()
    } else {
        format!("{}m", budget_seconds.div_ceil(60).max(1))
    }
}

#[cfg(unix)]
fn shell_argv(prompt: &str) -> Vec<&str> {
    vec!["/bin/sh", "-c", prompt]
}

#[cfg(windows)]
fn shell_argv(prompt: &str) -> Vec<&str> {
    vec!["cmd.exe", "/C", prompt]
}

/// The backends a client can choose from, in picker order.
///
/// `models` are taken from the installed CLI when it can list them
/// (`grok models`, `cursor-agent models`, `agy models`, `opencode models`).
/// The arrays below are the fallback when that CLI is missing, errors, or
/// times out. Claude has no list command: `--help` documents aliases, and
/// those stay the contract. A backend with an empty list gets no model
/// picker. Effort values are still the flags each CLI's `--help` names.
pub fn backends() -> Vec<serde_json::Value> {
    crate::agent_models::refresh();
    [
        ("sh", "Shell", "sh -c \"…\"", &[] as &[&str], serde_json::json!([])),
        (
            "claude",
            "Claude",
            "claude -p \"…\"",
            // Claude Code resolves these aliases itself ("fable", "opus", or
            // "sonnet" per its `--help`); haiku is the long-standing third
            // tier. Full ids change with every release and need an account to
            // enumerate, so the aliases are the stable contract.
            &["fable", "opus", "sonnet", "haiku"],
            serde_json::json!(["low", "medium", "high"]),
        ),
        ("codex", "Codex", "codex exec … -- \"…\"", &[], serde_json::json!([])),
        (
            "grok",
            "Grok",
            "grok -p \"…\"",
            &["grok-4.6", "grok-4.5"],
            serde_json::json!(["low", "medium", "high"]),
        ),
        (
            "cursor",
            "Cursor",
            "cursor-agent -p …",
            &[
                "auto",
                "gpt-5.4-nano-medium",
                "gpt-5.1",
                "gpt-5.1-high",
                "claude-4.5-sonnet",
                "claude-4.5-sonnet-thinking",
                "gemini-3-flash",
                "gpt-5-mini",
                "glm-5.2-high",
            ],
            serde_json::json!([]),
        ),
        (
            "agy",
            "Antigravity",
            "agy --print \"…\"",
            &[
                "gemini-3.6-flash-high",
                "gemini-3.5-flash-high",
                "gemini-3.1-pro-high",
                "claude-sonnet-4-6",
                "gpt-oss-120b-medium",
            ],
            // High / medium / low are separate model ids, not a second flag.
            serde_json::json!([]),
        ),
        (
            "opencode",
            "OpenCode",
            "opencode run \"…\"",
            &[],
            serde_json::json!(["minimal", "medium", "high", "max"]),
        ),
        (
            "opencode2",
            "OpenCode 2",
            "opencode2 run \"…\"",
            &[],
            serde_json::json!(["minimal", "medium", "high", "max"]),
        ),
    ]
    .into_iter()
    .map(|(id, label, command, fallback, efforts)| {
        let models = crate::agent_models::for_backend(id, fallback);
        serde_json::json!({"id": id, "label": label, "command": command, "models": models, "efforts": efforts})
    })
    .collect()
}

// MARK: - The job

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Automation {
    pub id: String,
    pub name: String,
    pub backend: String,
    /// The CLI's model alias, when the backend advertises a model list.
    #[serde(default)]
    pub model: Option<String>,
    /// The CLI's reasoning effort, when the backend advertises effort levels.
    #[serde(default)]
    pub effort: Option<String>,
    pub workspace_id: String,
    pub prompt: String,
    #[serde(default)]
    pub schedule: ScheduleSpec,
    pub budget_seconds: u64,
    pub enabled: bool,
    pub last_run_at_ms: Option<i64>,
    pub next_run_at_ms: Option<i64>,
    pub last_run_id: Option<String>,
}

const AUTO_COMMIT_NAME: &str = "Auto commit";

fn is_auto_commit_name(name: &str) -> bool {
    name.trim().eq_ignore_ascii_case(AUTO_COMMIT_NAME)
}

/// One completed or still-running agent run.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRecord {
    pub id: String,
    pub job_id: String,
    pub name: String,
    pub backend: String,
    pub workspace_id: String,
    pub started_at_ms: i64,
    pub ended_at_ms: Option<i64>,
    pub exit_code: Option<i32>,
    /// running, queued, ok, error, stopped (by budget), or interrupted.
    pub status: String,
    pub transcript_path: String,
    /// The live pty, kept so a run can be stopped before its budget.
    pub pty_id: Option<String>,
    /// The workflow run this one is a step of, when it is one.
    ///
    /// A workflow node starts an ordinary automation run, so every step
    /// finishing looked exactly like a job somebody scheduled: the Mac said
    /// "Run finished" once per step and again for the workflow itself, and a
    /// phone got a push for each. A step is machinery under a thing the person
    /// started, and machinery does not report to them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_run_id: Option<String>,
}

/// How long a run may live, and how many may run at once.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueConfig {
    /// Default per-run budget in seconds. 0 means no limit.
    #[serde(default = "default_budget_seconds")]
    pub default_budget_seconds: u64,
    /// How many runs may execute at once. 0 means no cap.
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent: u32,
}

fn default_budget_seconds() -> u64 {
    DEFAULT_BUDGET_SECONDS
}

fn default_max_concurrent() -> u32 {
    DEFAULT_MAX_CONCURRENT
}

impl Default for QueueConfig {
    fn default() -> Self {
        Self {
            default_budget_seconds: DEFAULT_BUDGET_SECONDS,
            max_concurrent: DEFAULT_MAX_CONCURRENT,
        }
    }
}

/// A job waiting for a free slot.
struct Pending {
    job: Automation,
    run_id: String,
    transcript_path: PathBuf,
    /// See `RunRecord::parent_run_id`.
    parent_run_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct JobsFile {
    #[serde(default)]
    jobs: Vec<Automation>,
    #[serde(default)]
    queue: QueueConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct RunsFile {
    #[serde(default)]
    runs: Vec<RunRecord>,
}

pub struct Store {
    path: PathBuf,
    runs_path: PathBuf,
    runs_dir: PathBuf,
    jobs: Mutex<Vec<Automation>>,
    runs: Mutex<Vec<RunRecord>>,
    queue: Mutex<QueueConfig>,
    waiting: Mutex<VecDeque<Pending>>,
    /// Slots currently in use. Separate from the runs list so a count
    /// cannot race a status write.
    active: Mutex<u32>,
    /// Run ids the user asked to stop. Drain records those as stopped
    /// rather than as an error from the signal.
    killed: Mutex<HashSet<String>>,
}

pub fn shared() -> Arc<Store> {
    static STORE: std::sync::OnceLock<Arc<Store>> = std::sync::OnceLock::new();
    Arc::clone(STORE.get_or_init(|| Arc::new(Store::load())))
}

impl Store {
    #[cfg(test)]
    fn at(path: PathBuf) -> Store {
        let runs_dir = path.parent().unwrap_or(&path).join("runs");
        Store {
            path,
            runs_path: runs_dir.join("runs.json"),
            runs_dir,
            jobs: Mutex::new(Vec::new()),
            runs: Mutex::new(Vec::new()),
            queue: Mutex::new(QueueConfig::default()),
            waiting: Mutex::new(VecDeque::new()),
            active: Mutex::new(0),
            killed: Mutex::new(HashSet::new()),
        }
    }

    pub fn load() -> Store {
        let dir = tokenstat_paths::data_dir().unwrap_or_else(|| PathBuf::from("."));
        let path = dir.join("automations.json");
        let file = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<JobsFile>(&text).ok())
            .unwrap_or_default();
        let jobs = file.jobs;
        let queue = file.queue;
        let runs_dir = dir.join("runs");
        let runs_path = runs_dir.join("runs.json");
        let mut runs = std::fs::read_to_string(&runs_path)
            .ok()
            .and_then(|text| serde_json::from_str::<RunsFile>(&text).ok())
            .map(|file| file.runs)
            .unwrap_or_default();
        let mut recovered = false;
        for run in &mut runs {
            if run.status == "running" || run.status == "queued" {
                // The pty belongs to the old daemon process. A queued run
                // lost its pending payload. Do not resurrect either.
                run.status = "interrupted".into();
                run.ended_at_ms = Some(now_ms());
                run.pty_id = None;
                recovered = true;
            }
        }
        let store = Store {
            path,
            runs_path,
            runs_dir,
            jobs: Mutex::new(jobs),
            runs: Mutex::new(runs),
            queue: Mutex::new(queue),
            waiting: Mutex::new(VecDeque::new()),
            active: Mutex::new(0),
            killed: Mutex::new(HashSet::new()),
        };
        if recovered {
            let _ = store.save_runs();
        }
        store
    }

    fn save(&self) -> Result<(), String> {
        let jobs = self
            .jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let queue = *self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let body =
            serde_json::to_string_pretty(&JobsFile { jobs, queue }).map_err(|e| e.to_string())?;
        write_atomic(&self.path, &body)
    }

    pub fn queue_config(&self) -> QueueConfig {
        *self.queue.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn set_queue_config(&self, mut next: QueueConfig) -> Result<QueueConfig, String> {
        next.max_concurrent = next.max_concurrent.min(32);
        *self.queue.lock().unwrap_or_else(PoisonError::into_inner) = next;
        self.save()?;
        Ok(next)
    }

    /// Persist the queue and start any waiters the new cap can take.
    pub fn apply_queue_config(self: &Arc<Self>, next: QueueConfig) -> Result<QueueConfig, String> {
        let next = self.set_queue_config(next)?;
        self.pump();
        Ok(next)
    }

    fn is_killed(&self, run_id: &str) -> bool {
        self.killed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(run_id)
    }

    fn mark_killed(&self, run_id: &str) {
        self.killed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(run_id.to_string());
    }

    fn save_runs(&self) -> Result<(), String> {
        let runs = self
            .runs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        std::fs::create_dir_all(&self.runs_dir).map_err(|e| e.to_string())?;
        let body = serde_json::to_string_pretty(&RunsFile { runs }).map_err(|e| e.to_string())?;
        write_atomic(&self.runs_path, &body)
    }

    // MARK: jobs

    pub fn list(&self) -> Vec<Automation> {
        self.jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn create(&self, mut job: Automation) -> Result<Automation, String> {
        validate(&job)?;
        job.schedule.validate()?;
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        if jobs
            .iter()
            .any(|existing| existing.id == job.id && !job.id.is_empty())
        {
            return Err(format!("an automation with id {} already exists", job.id));
        }
        // One Auto commit per folder. A later create with a different
        // agent edits that job rather than adding another row.
        if is_auto_commit_name(&job.name) {
            if let Some(idx) = jobs.iter().position(|existing| {
                existing.workspace_id == job.workspace_id && is_auto_commit_name(&existing.name)
            }) {
                let id = jobs[idx].id.clone();
                let last_run_at_ms = jobs[idx].last_run_at_ms;
                let last_run_id = jobs[idx].last_run_id.clone();
                job.id = id;
                job.last_run_at_ms = last_run_at_ms;
                job.last_run_id = last_run_id;
                if job.enabled {
                    job.next_run_at_ms = job.schedule.next_run_ms(now_ms());
                } else {
                    job.next_run_at_ms = None;
                }
                jobs[idx] = job.clone();
                drop(jobs);
                self.save()?;
                return Ok(job);
            }
        }
        if job.id.is_empty() {
            job.id = format!("automation-{}", now_ms());
        }
        if job.enabled {
            job.next_run_at_ms = job.schedule.next_run_ms(now_ms());
        }
        jobs.push(job.clone());
        drop(jobs);
        self.save()?;
        Ok(job)
    }

    pub fn update(&self, mut job: Automation) -> Result<Automation, String> {
        validate(&job)?;
        job.schedule.validate()?;
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        if is_auto_commit_name(&job.name)
            && jobs.iter().any(|other| {
                other.id != job.id
                    && other.workspace_id == job.workspace_id
                    && is_auto_commit_name(&other.name)
            })
        {
            return Err("this folder already has an Auto commit job".into());
        }
        let current = jobs
            .iter_mut()
            .find(|existing| existing.id == job.id)
            .ok_or_else(|| format!("no automation with id {}", job.id))?;
        let last_run_at_ms = current.last_run_at_ms;
        let last_run_id = current.last_run_id.clone();
        job.last_run_at_ms = last_run_at_ms;
        job.last_run_id = last_run_id;
        // Always recompute next run from the schedule the client just sent.
        // Preserving a stale next_run_at_ms left edits that changed time/days
        // (or switched to Once) still due on the previous schedule.
        if !job.enabled {
            job.next_run_at_ms = None;
        } else {
            job.next_run_at_ms = job.schedule.next_run_ms(now_ms());
        }
        *current = job;
        let result = current.clone();
        drop(jobs);
        self.save()?;
        Ok(result)
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<Automation, String> {
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let job = jobs
            .iter_mut()
            .find(|job| job.id == id)
            .ok_or_else(|| format!("no automation with id {id}"))?;
        job.enabled = enabled;
        job.next_run_at_ms = if enabled {
            job.schedule.next_run_ms(now_ms())
        } else {
            None
        };
        let result = job.clone();
        drop(jobs);
        self.save()?;
        Ok(result)
    }

    pub fn remove(&self, id: &str) -> Result<bool, String> {
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let old = jobs.len();
        jobs.retain(|job| job.id != id);
        let changed = old != jobs.len();
        if changed {
            drop(jobs);
            self.save()?;
        }
        Ok(changed)
    }

    // MARK: runs

    pub fn runs(&self) -> Vec<RunRecord> {
        self.runs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Insert a job without recomputing its schedule. Tests only.
    #[cfg(test)]
    fn seed(&self, job: Automation) {
        self.jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(job);
    }

    pub fn get_run(&self, id: &str) -> Option<RunRecord> {
        self.runs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|run| run.id == id)
            .cloned()
    }

    /// Start a stored job without taking a queue slot. A workflow that already
    /// occupies the cap uses this so an automation node cannot deadlock.
    ///
    /// `prompt_override` replaces the stored prompt when it is non-empty.
    pub fn start_now(
        self: &Arc<Store>,
        id: &str,
        prompt_override: Option<&str>,
        parent_run_id: Option<&str>,
    ) -> Result<RunRecord, String> {
        let mut snapshot = {
            let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
            jobs.iter()
                .find(|job| job.id == id)
                .cloned()
                .ok_or_else(|| format!("no automation with id {id}"))?
        };
        if let Some(over) = prompt_override.map(str::trim).filter(|s| !s.is_empty()) {
            snapshot.prompt = over.to_string();
        }
        let workspace = crate::workspaces::folder(&snapshot.workspace_id)?;
        let _argv = agent_command(
            &snapshot.backend,
            &snapshot.prompt,
            snapshot.model.as_deref(),
            snapshot.effort.as_deref(),
            snapshot.budget_seconds,
        )?;
        let run_id = format!("run-{}", now_ms());
        let transcript_path = self.runs_dir.join(format!("{run_id}.txt"));
        let pending = Pending {
            job: snapshot.clone(),
            run_id: run_id.clone(),
            transcript_path,
            parent_run_id: parent_run_id.map(str::to_string),
        };
        match self.spawn_pending(pending, workspace.id) {
            Ok((run, budget)) => {
                let started = run.started_at_ms;
                let started_id = run.id.clone();
                let out = self.persist_and_drain(run, budget, |r| self.push_run(r), false)?;
                let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(job) = jobs.iter_mut().find(|job| job.id == id) {
                    job.last_run_at_ms = Some(started);
                    job.last_run_id = Some(started_id);
                }
                drop(jobs);
                let _ = self.save();
                Ok(out)
            }
            Err(e) => Err(e),
        }
    }

    fn push_run(&self, run: RunRecord) -> Result<(), String> {
        let mut runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        runs.insert(0, run);
        runs.truncate(RUNS_KEPT);
        drop(runs);
        self.save_runs()
    }

    /// The drain thread calls this when a run's process has exited.
    pub fn finish_run(&self, id: &str, exit_code: Option<i32>, status: &str) {
        let mut runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(run) = runs.iter_mut().find(|run| run.id == id) {
            run.exit_code = exit_code;
            run.status = status.to_string();
            run.ended_at_ms = Some(now_ms());
        }
        drop(runs);
        let _ = self.save_runs();
    }

    /// Bytes of a run's transcript after `offset`.
    ///
    /// Always the readable file. Raw JSON stays on disk for debugging and is
    /// never what a front end should display. Runs that finished before
    /// drain-time parsing are materialised here on first read.
    pub fn transcript(&self, run_id: &str, offset: u64) -> Result<(String, u64), String> {
        let runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        let run = runs
            .iter()
            .find(|run| run.id == run_id)
            .ok_or("no run with that id")?;
        let raw = PathBuf::from(&run.transcript_path);
        let backend = run.backend.clone();
        let running = run.status == "running";
        drop(runs);
        if !raw.is_absolute() {
            return Err("a run transcript is not absolute".into());
        }
        let readable = transcript::readable_path(&raw);
        let missing = !readable.is_file();
        let empty = if readable.is_file() {
            std::fs::metadata(&readable)
                .map(|m| m.len() == 0)
                .unwrap_or(true)
        } else {
            false
        };
        // A live drain creates an empty readable file on purpose. Do not
        // stomp it by re-parsing the raw stream while it is still growing.
        // Serve the in-memory prose when rematerialize ran, so a sibling
        // write that failed still never returns NDJSON.
        if missing || (empty && !running) {
            if let Some(text) = transcript::rematerialize(&raw, &backend, false) {
                return Ok(transcript::slice_reply(text.as_bytes(), offset));
            }
        } else if !running && offset == 0 && raw.is_file() {
            // Finished runs reparse from raw on first read so a better
            // parser (paths, edit snippets) applies to old transcripts.
            if let Some(text) = transcript::rematerialize(&raw, &backend, true) {
                return Ok(transcript::slice_reply(text.as_bytes(), offset));
            }
        }
        if !readable.is_file() {
            return Ok(("(No readable output)".into(), 0));
        }
        let bytes = std::fs::read(&readable).map_err(|e| e.to_string())?;
        if bytes.is_empty() {
            return Ok((
                if running {
                    String::new()
                } else {
                    "(No readable output)".into()
                },
                0,
            ));
        }
        if transcript::looks_like_ndjson(&bytes) {
            // A stale readable that is actually the raw file. Rebuild it.
            if let Some(text) = transcript::rematerialize(&raw, &backend, true) {
                return Ok(transcript::slice_reply(text.as_bytes(), offset));
            }
            return Ok(("(No readable output)".into(), 0));
        }
        Ok(transcript::slice_reply(&bytes, offset))
    }

    // MARK: running

    /// Run a job that is not part of the stored list: the todo board's
    /// delegate path. Returns the run so the caller can link it to its card.
    /// Starts now when a slot is free, otherwise waits in the queue.
    pub fn run_adhoc(self: &Arc<Store>, job: Automation) -> Result<RunRecord, String> {
        let workspace = crate::workspaces::folder(&job.workspace_id)?;
        // Fail before we take a slot: a bad backend must not occupy the queue.
        let _argv = agent_command(
            &job.backend,
            &job.prompt,
            job.model.as_deref(),
            job.effort.as_deref(),
            job.budget_seconds,
        )?;

        let run_id = format!("run-{}", now_ms());
        let transcript_path = self.runs_dir.join(format!("{run_id}.txt"));
        let pending = Pending {
            job: job.clone(),
            run_id: run_id.clone(),
            transcript_path: transcript_path.clone(),
            parent_run_id: None,
        };

        if self.try_take_slot() {
            match self.spawn_pending(pending, workspace.id.clone()) {
                Ok((run, budget)) => {
                    self.persist_and_drain(run, budget, |r| self.push_run(r), true)
                }
                Err(e) => {
                    self.release_slot();
                    Err(e)
                }
            }
        } else {
            let run = RunRecord {
                id: run_id,
                job_id: job.id.clone(),
                name: job.name,
                backend: job.backend,
                workspace_id: workspace.id,
                started_at_ms: now_ms(),
                ended_at_ms: None,
                exit_code: None,
                status: "queued".into(),
                transcript_path: transcript_path.display().to_string(),
                pty_id: None,
                parent_run_id: pending.parent_run_id.clone(),
            };
            self.waiting
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push_back(pending);
            self.push_run(run.clone())?;
            Ok(run)
        }
    }

    pub(crate) fn try_take_slot(&self) -> bool {
        let max = self
            .queue
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .max_concurrent;
        let mut active = self.active.lock().unwrap_or_else(PoisonError::into_inner);
        if max == 0 || *active < max {
            *active += 1;
            true
        } else {
            false
        }
    }

    pub(crate) fn release_slot(&self) {
        let mut active = self.active.lock().unwrap_or_else(PoisonError::into_inner);
        if *active > 0 {
            *active -= 1;
        }
    }

    #[cfg(test)]
    pub(crate) fn active_slots(&self) -> u32 {
        *self.active.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn spawn_pending(
        self: &Arc<Store>,
        pending: Pending,
        workspace_id: String,
    ) -> Result<(RunRecord, u64), String> {
        if self.is_killed(&pending.run_id) {
            return Err("stopped".into());
        }
        let workspace = crate::workspaces::folder(&pending.job.workspace_id)?;
        let argv = agent_command(
            &pending.job.backend,
            &pending.job.prompt,
            pending.job.model.as_deref(),
            pending.job.effort.as_deref(),
            pending.job.budget_seconds,
        )?;
        let info = tokenstat_pty::manager()
            .spawn(&tokenstat_pty::Spawn {
                command: argv[0].clone(),
                args: argv[1..].to_vec(),
                cwd: workspace.path.clone(),
                workspace_id: Some(workspace.id.clone()),
                hidden: true,
                rows: 24,
                cols: 120,
                no_color: false,
                dark: None,
                environment: Vec::new(),
            })
            .map_err(|e| e.to_string())?;

        let run = RunRecord {
            id: pending.run_id.clone(),
            job_id: pending.job.id.clone(),
            name: pending.job.name.clone(),
            backend: pending.job.backend.clone(),
            workspace_id,
            started_at_ms: now_ms(),
            ended_at_ms: None,
            exit_code: None,
            status: "running".into(),
            transcript_path: pending.transcript_path.display().to_string(),
            pty_id: Some(info.id.clone()),
            parent_run_id: pending.parent_run_id.clone(),
        };

        if self.is_killed(&pending.run_id) {
            let _ = tokenstat_pty::manager().kill(&info.id);
            let _ = tokenstat_pty::manager().close(&info.id);
            return Err("stopped".into());
        }
        Ok((run, pending.job.budget_seconds))
    }

    /// Write the row, then start drain. A drain that starts before the row
    /// exists can finish into a missing record, then the write leaves a
    /// forever-running job with no pty.
    fn persist_and_drain(
        self: &Arc<Store>,
        run: RunRecord,
        budget: u64,
        persist: impl FnOnce(RunRecord) -> Result<(), String>,
        owns_slot: bool,
    ) -> Result<RunRecord, String> {
        if let Err(e) = persist(run.clone()) {
            if let Some(pty_id) = &run.pty_id {
                let _ = tokenstat_pty::manager().kill(pty_id);
                let _ = tokenstat_pty::manager().close(pty_id);
            }
            return Err(e);
        }
        self.start_drain(&run, budget, owns_slot);
        Ok(run)
    }

    fn start_drain(self: &Arc<Store>, run: &RunRecord, budget: u64, owns_slot: bool) {
        let Some(pty_id) = run.pty_id.clone() else {
            return;
        };
        let transcript_path = PathBuf::from(&run.transcript_path);
        let run_id = run.id.clone();
        let backend = run.backend.clone();
        let me = Arc::clone(self);
        std::thread::spawn(move || {
            me.drain(
                &pty_id,
                &transcript_path,
                budget,
                &run_id,
                &backend,
                owns_slot,
            );
            if owns_slot {
                me.pump();
            }
        });
    }

    fn pump(self: &Arc<Store>) {
        loop {
            if !self.try_take_slot() {
                return;
            }
            let pending = self
                .waiting
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .pop_front();
            let Some(pending) = pending else {
                self.release_slot();
                return;
            };
            let workspace_id = pending.job.workspace_id.clone();
            let run_id = pending.run_id.clone();
            let transcript_path = pending.transcript_path.clone();
            if self.is_killed(&run_id) {
                self.release_slot();
                self.finish_run(&run_id, None, "stopped");
                continue;
            }
            match self.spawn_pending(pending, workspace_id) {
                Ok((run, budget)) => {
                    if self
                        .persist_and_drain(run, budget, |r| self.update_run(r), true)
                        .is_err()
                    {
                        self.release_slot();
                        self.finish_run(&run_id, None, "error");
                    }
                }
                Err(err) => {
                    self.release_slot();
                    if self.is_killed(&run_id) || err == "stopped" {
                        self.finish_run(&run_id, None, "stopped");
                    } else {
                        let note = format!("(failed to start: {err})\n");
                        let _ = std::fs::write(
                            transcript::readable_path(&transcript_path),
                            note.as_bytes(),
                        );
                        self.finish_run(&run_id, None, "error");
                    }
                }
            }
        }
    }

    fn update_run(&self, run: RunRecord) -> Result<(), String> {
        let mut runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = runs.iter_mut().find(|r| r.id == run.id) {
            // Drain may have already recorded a terminal status. Do not put
            // the row back to running.
            if matches!(existing.status.as_str(), "ok" | "error" | "stopped") {
                drop(runs);
                return Ok(());
            }
            *existing = run;
        } else {
            runs.insert(0, run);
        }
        drop(runs);
        self.save_runs()
    }

    /// Run one stored job immediately, or one due job from the scheduler.
    pub fn run(self: &Arc<Store>, id: &str) -> Result<Automation, String> {
        let snapshot = {
            let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
            jobs.iter()
                .find(|job| job.id == id)
                .cloned()
                .ok_or_else(|| format!("no automation with id {id}"))?
        };
        let run = self.run_adhoc(snapshot)?;
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let job = jobs
            .iter_mut()
            .find(|job| job.id == id)
            .ok_or_else(|| format!("no automation with id {id}"))?;
        job.last_run_at_ms = Some(run.started_at_ms);
        job.last_run_id = Some(run.id.clone());
        job.next_run_at_ms = if job.enabled {
            job.schedule.next_run_ms(now_ms())
        } else {
            None
        };
        let result = job.clone();
        drop(jobs);
        self.save()?;
        Ok(result)
    }

    /// Kill the pty behind a run, by its run id. The drain then records the
    /// run as stopped when the process is gone. A queued run is pulled off
    /// the wait list and marked stopped.
    pub fn kill_run(&self, run_id: &str) -> Result<(), String> {
        // Mark first so a pump that already popped this id will not spawn it.
        self.mark_killed(run_id);
        let removed = {
            let mut waiting = self.waiting.lock().unwrap_or_else(PoisonError::into_inner);
            let before = waiting.len();
            waiting.retain(|p| p.run_id != run_id);
            before != waiting.len()
        };
        if removed {
            self.finish_run(run_id, None, "stopped");
            return Ok(());
        }
        let runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        let run = runs
            .iter()
            .find(|run| run.id == run_id)
            .ok_or("no run with that id")?;
        let pty_id = run.pty_id.clone();
        let status = run.status.clone();
        drop(runs);
        if let Some(pty_id) = pty_id {
            match tokenstat_pty::manager().kill(&pty_id) {
                Ok(()) | Err(tokenstat_pty::PtyError::NoSession(_)) => {}
                Err(e) => return Err(e.to_string()),
            }
            return Ok(());
        }
        if status == "queued" {
            // pump owns it now. spawn_pending / pump will see the kill mark.
            return Ok(());
        }
        if status != "running" {
            return Err("that run is not running".into());
        }
        // Marked killed, no pty yet. Drain will see the mark if it starts.
        Ok(())
    }

    /// Drain a run's pty into its transcript file, kill on budget, then record
    /// the outcome and close the pty. Runs on its own thread.
    pub fn drain(
        &self,
        pty_id: &str,
        path: &Path,
        budget_seconds: u64,
        run_id: &str,
        backend: &str,
        owns_slot: bool,
    ) {
        let manager = tokenstat_pty::manager();
        let deadline = if budget_seconds == 0 {
            None
        } else {
            Some(Instant::now() + Duration::from_secs(budget_seconds))
        };
        let mut file = std::fs::File::create(path).ok();
        let readable_path = transcript::readable_path(path);
        // Create the readable file immediately so a live tail never falls
        // through to the raw JSON while the first event is still arriving.
        let _ = std::fs::write(&readable_path, b"");
        let mut readable_body = String::new();
        let mut parser = Parser::new(backend);
        let mut offset = 0u64;
        let reader_id = format!("automation:{run_id}");
        let mut stopped_by_budget = false;

        let take = |bytes: &[u8],
                    file: &mut Option<std::fs::File>,
                    readable_body: &mut String,
                    parser: &mut Parser| {
            if let Some(f) = file {
                let _ = f.write_all(bytes);
            }
            let piece = parser.push(bytes);
            if !piece.is_empty() {
                readable_body.push_str(&piece);
                transcript::cap_readable(readable_body);
                let _ = std::fs::write(&readable_path, readable_body.as_bytes());
            }
        };

        loop {
            let alive = manager.info(pty_id).map(|i| i.alive).unwrap_or(false);
            if !alive {
                // The last of the output arrives after the process that wrote
                // it has gone: the thread reading the terminal is a moment
                // behind the process being reaped. Reading once here lost the
                // entire transcript of a command that exited as fast as it
                // printed, which is most of them.
                let tail = Instant::now() + DRAIN_TAIL;
                while Instant::now() < tail {
                    if let Ok(chunk) = manager.read_for_stream(pty_id, &reader_id, offset)
                        && !chunk.bytes.is_empty()
                    {
                        offset = chunk.next_offset;
                        take(&chunk.bytes, &mut file, &mut readable_body, &mut parser);
                    }
                    std::thread::sleep(DRAIN_POLL);
                }
                break;
            }
            if let Ok(chunk) = manager.read_for_stream(pty_id, &reader_id, offset) {
                offset = chunk.next_offset;
                if !chunk.bytes.is_empty() {
                    take(&chunk.bytes, &mut file, &mut readable_body, &mut parser);
                }
            }
            if deadline.is_some_and(|d| Instant::now() >= d) {
                let _ = manager.kill(pty_id);
                stopped_by_budget = true;
            }
            if self.is_killed(run_id) {
                let _ = manager.kill(pty_id);
            }
            std::thread::sleep(DRAIN_POLL);
        }

        let tail = parser.finish();
        if !tail.is_empty() {
            readable_body.push_str(&tail);
            transcript::cap_readable(&mut readable_body);
            let _ = std::fs::write(&readable_path, readable_body.as_bytes());
        }

        manager.forget_reader(pty_id, &reader_id);
        let exit_code = Self::settle_exit_code(pty_id);
        let user_stopped = self
            .killed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(run_id);
        let status = if stopped_by_budget || user_stopped {
            "stopped"
        } else if exit_code == Some(0) {
            "ok"
        } else {
            "error"
        };
        let _ = manager.close(pty_id);
        self.finish_run(run_id, exit_code, status);
        // Tell this account's phones, if it has any. Only here, at the end of
        // a drain: the other `finish_run` callers are a run somebody stopped
        // by hand and a launch that never started, and neither is news to the
        // person who just pressed the button. A stopped run is not a failure
        // either, so it goes out as "finished" or not at all.
        //
        // The Mac notifies itself locally from the app, so this is for a
        // phone with the app closed. Fire and forget: a run that finished is
        // finished whether or not Apple was reachable.
        // A workflow step is not news either: the workflow itself says how it
        // went when it ends, and a five-node workflow otherwise buzzed a phone
        // five times on the way there. See `RunRecord::parent_run_id`.
        let is_step = self
            .get_run(run_id)
            .is_some_and(|run| run.parent_run_id.is_some());
        if status != "stopped" && !is_step {
            tokenstat_sync::push::notify_in_background(tokenstat_sync::push::Reason::for_exit(
                status, exit_code,
            ));
        }
        if owns_slot {
            self.release_slot();
        }
    }

    /// Wait, briefly, for a process that has stopped producing output to report
    /// how it ended. `None` once the wait is up, which is the honest answer:
    /// the run ended, but with no status anyone can quote.
    fn settle_exit_code(pty_id: &str) -> Option<i32> {
        let manager = tokenstat_pty::manager();
        let deadline = Instant::now() + EXIT_SETTLE;
        loop {
            match manager.info(pty_id) {
                Ok(info) if info.exit_code.is_some() => return info.exit_code,
                Ok(_) => {}
                Err(_) => return None,
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(DRAIN_POLL);
        }
    }

    pub fn run_due(self: &Arc<Store>) {
        let now = now_ms();
        let ids: Vec<String> = self
            .list()
            .into_iter()
            .filter(|job| job.enabled && job.next_run_at_ms.is_some_and(|at| at <= now))
            .map(|job| job.id)
            .collect();
        for id in ids {
            let _ = self.run(&id);
        }
    }
}

// MARK: - Scheduler

/// Start the recurring scheduler. Only the daemon server calls this; the
/// in-process bridge never runs jobs on a timer.
/// Takes no session, and that matters. This used to lock the shared session on
/// every tick and hold it while it spawned agents, so a five-second timer was
/// enough to make an interactive call wait behind it. A job needs a folder and
/// a pty, neither of which is the archive.
pub fn start_scheduler() {
    let store = shared();
    std::thread::spawn(move || {
        loop {
            store.run_due();
            std::thread::sleep(TICK);
        }
    });
}

// MARK: - Helpers

fn validate(job: &Automation) -> Result<(), String> {
    if job.name.trim().is_empty() {
        return Err("an automation needs a name".into());
    }
    if job.workspace_id.is_empty() {
        return Err("an automation needs a workspace".into());
    }
    // 0 is a real answer: no time limit. The queue settings own the default.
    // backend and prompt are checked where the command is built, so both errors
    // are the ones a user sees when they try to run it.
    Ok(())
}

fn write_atomic(path: &Path, body: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, body).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_dir(tag: &str) -> PathBuf {
        let n = DIR_SEQ.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "tokenstat-automation-{tag}-{}-{n}",
            std::process::id()
        ))
    }

    fn job(id: &str, schedule: ScheduleSpec, budget: u64) -> Automation {
        Automation {
            id: id.into(),
            name: "test".into(),
            backend: "claude".into(),
            model: None,
            effort: None,
            workspace_id: "w".into(),
            prompt: "do the thing".into(),
            schedule,
            budget_seconds: budget,
            enabled: true,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
        }
    }

    #[test]
    fn validation_allows_unbounded_jobs() {
        assert!(validate(&job("a", ScheduleSpec::default(), 0)).is_ok());
    }

    #[test]
    fn an_interval_floors_at_a_minute() {
        let mut s = ScheduleSpec {
            kind: ScheduleKind::Interval,
            every_seconds: 10,
            ..ScheduleSpec::default()
        };
        assert!(s.validate().is_err());
        s.every_seconds = 60;
        assert!(s.validate().is_ok());
    }

    #[test]
    fn once_jobs_never_fire_on_their_own() {
        let s = ScheduleSpec::default();
        assert_eq!(s.next_run_ms(now_ms()), None);
    }

    #[test]
    fn an_interval_advances_by_its_own_length() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Interval,
            every_seconds: 120,
            ..ScheduleSpec::default()
        };
        assert_eq!(s.next_run_ms(1_000), Some(121_000));
    }

    #[test]
    fn a_daily_schedule_is_always_in_the_future() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Daily,
            hour: 9,
            ..ScheduleSpec::default()
        };
        let from = now_ms();
        let next = s.next_run_ms(from).unwrap();
        assert!(next > from, "next run must be after now");
    }

    #[test]
    fn a_weekly_schedule_stays_on_its_weekday() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Weekly,
            weekday: 0,
            hour: 9,
            ..ScheduleSpec::default()
        };
        let from = now_ms();
        let next = s.next_run_ms(from).unwrap();
        assert!(next > from);
    }

    #[test]
    fn weekdays_kind_is_monday_through_friday() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Weekdays,
            hour: 9,
            minute: 0,
            ..ScheduleSpec::default()
        };
        assert!(s.validate().is_ok());
        assert_eq!(s.day_mask(), 0b0001_1111);
        let from = now_ms();
        let next = s.next_run_ms(from).unwrap();
        assert!(next > from);
    }

    #[test]
    fn custom_schedule_uses_the_day_bitset() {
        // Tuesday and Thursday only (bits 1 and 3).
        let s = ScheduleSpec {
            kind: ScheduleKind::Custom,
            hour: 8,
            minute: 30,
            weekdays: (1 << 1) | (1 << 3),
            ..ScheduleSpec::default()
        };
        assert!(s.validate().is_ok());
        assert!(s.next_run_ms(now_ms()).is_some());
        let empty = ScheduleSpec {
            kind: ScheduleKind::Custom,
            hour: 8,
            weekdays: 0,
            ..ScheduleSpec::default()
        };
        assert!(empty.validate().is_err());
    }

    #[test]
    fn older_weekly_json_without_weekdays_still_decodes() {
        let raw = r#"{"kind":"weekly","everySeconds":0,"hour":9,"minute":0,"weekday":2}"#;
        let s: ScheduleSpec = serde_json::from_str(raw).unwrap();
        assert_eq!(s.kind, ScheduleKind::Weekly);
        assert_eq!(s.weekday, 2);
        assert_eq!(s.weekdays, 0);
        assert_eq!(s.day_mask(), 1 << 2);
    }

    #[test]
    fn updating_a_schedule_recomputes_next_run() {
        let dir = temp_dir("update-next");
        let store = Store::at(dir.join("automations.json"));
        let mut job = job(
            "a",
            ScheduleSpec {
                kind: ScheduleKind::Daily,
                hour: 9,
                minute: 0,
                ..ScheduleSpec::default()
            },
            120,
        );
        job = store.create(job).unwrap();
        let first_next = job.next_run_at_ms;
        assert!(first_next.is_some());

        // Client still sends the old next time (as the app used to). Switching
        // to Once must clear it so the job no longer fires on its own.
        job.schedule = ScheduleSpec {
            kind: ScheduleKind::Once,
            ..ScheduleSpec::default()
        };
        job.next_run_at_ms = first_next;
        let updated = store.update(job).unwrap();
        assert_eq!(updated.next_run_at_ms, None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn one_auto_commit_job_per_workspace() {
        let dir = temp_dir("auto-commit-once");
        let store = Store::at(dir.join("automations.json"));
        let mut first = job("auto-1", ScheduleSpec::default(), 900);
        first.name = "Auto commit".into();
        first.backend = "claude".into();
        first.model = Some("sonnet".into());
        let first = store.create(first).unwrap();

        let mut second = job("", ScheduleSpec::default(), 900);
        second.name = "auto commit".into();
        second.backend = "grok".into();
        second.model = Some("grok-4".into());
        let second = store.create(second).unwrap();

        assert_eq!(second.id, first.id);
        assert_eq!(second.backend, "grok");
        assert_eq!(second.model.as_deref(), Some("grok-4"));
        assert_eq!(store.list().len(), 1);

        let mut other = job("", ScheduleSpec::default(), 900);
        other.name = "Auto commit".into();
        other.workspace_id = "other".into();
        let other = store.create(other).unwrap();
        assert_ne!(other.id, first.id);
        assert_eq!(store.list().len(), 2);

        let mut rename = other.clone();
        rename.workspace_id = first.workspace_id.clone();
        assert!(store.update(rename).is_err());
        assert_eq!(store.list().len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn every_backend_builds_a_command() {
        for backend in [
            "claude",
            "codex",
            "grok",
            "cursor",
            "agy",
            "opencode",
            "opencode2",
        ] {
            let argv = agent_command(backend, "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
            assert!(!argv.is_empty(), "{backend} produced no command");
            assert!(argv.iter().any(|a| a == "do it"));
        }
        // Regression: claude rejects stream-json print output without this.
        let claude = agent_command("claude", "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
        assert!(claude.iter().any(|a| a == "--verbose"));
        assert!(claude.iter().any(|a| a == "--dangerously-skip-permissions"));
        let agy = agent_command("agy", "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
        assert!(agy.iter().any(|a| a == "--dangerously-skip-permissions"));
        assert!(
            agy.windows(2)
                .any(|w| w == ["--output-format", "stream-json"])
        );
        assert!(agy.windows(2).any(|w| w == ["--print-timeout", "180m"]));
        let mashed = agent_command(
            "agy",
            "do it",
            Some("gemini-3.6-flash-high\tGemini 3.6 Flash (High)"),
            Some("high"),
            DEFAULT_BUDGET_SECONDS,
        )
        .unwrap();
        assert!(
            mashed
                .windows(2)
                .any(|w| w == ["--model", "gemini-3.6-flash-high"]),
            "{mashed:?}"
        );
        assert!(
            !mashed.iter().any(|a| a == "--effort"),
            "agy models already encode effort: {mashed:?}"
        );
        let unlimited = agent_command("agy", "do it", None, None, 0).unwrap();
        assert!(
            unlimited
                .windows(2)
                .any(|w| w == ["--print-timeout", "24h"])
        );
        let grok = agent_command("grok", "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
        assert!(
            grok.windows(2)
                .any(|w| w == ["--permission-mode", "bypassPermissions"])
        );
        let opencode =
            agent_command("opencode", "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
        assert!(opencode.windows(2).any(|w| w == ["--format", "json"]));
        assert!(opencode.iter().any(|a| a == "--auto"));
        let next = agent_command("opencode2", "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
        assert_eq!(next.first().map(String::as_str), Some("opencode2"));
        assert!(next.windows(2).any(|w| w == ["--format", "json"]));
        assert!(next.iter().any(|a| a == "run"));
        let codex = agent_command("codex", "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
        assert!(
            codex
                .iter()
                .any(|a| a == "--dangerously-bypass-approvals-and-sandbox")
        );
        assert!(agent_command("nope", "do it", None, None, DEFAULT_BUDGET_SECONDS).is_err());
        assert!(agent_command("claude", "   ", None, None, DEFAULT_BUDGET_SECONDS).is_err());
    }

    #[test]
    fn grok_models_include_the_current_default() {
        let grok = backends()
            .into_iter()
            .find(|v| v.get("id").and_then(|id| id.as_str()) == Some("grok"))
            .expect("grok is a backend");
        let models = grok
            .get("models")
            .and_then(|v| v.as_array())
            .expect("a model list");
        assert!(
            models.iter().any(|m| m.as_str() == Some("grok-4.6")),
            "picker must offer grok-4.6 (live list or fallback), got {models:?}"
        );
    }

    #[test]
    fn chat_defaults_to_no_bypass_flags() {
        let claude = chat_agent_command(
            "claude",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                hook_command: None,
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            !claude
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions")
        );
        let guarded_claude = chat_agent_command(
            "claude",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                hook_command: Some(
                    "/Applications/Tokenstat.app/Contents/Resources/tokenstat-hostd",
                ),
                attachments: &[],
            },
        )
        .unwrap();
        let settings = guarded_claude
            .windows(2)
            .find(|pair| pair[0] == "--settings")
            .map(|pair| &pair[1])
            .expect("a standard Claude chat must install its pre-tool hook");
        assert!(settings.contains("PreToolUse"));
        assert!(settings.contains("hook claude pre"));
        let codex = chat_agent_command(
            "codex",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                hook_command: None,
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            !codex
                .iter()
                .any(|arg| arg == "--dangerously-bypass-approvals-and-sandbox")
        );
        let guarded_codex = chat_agent_command(
            "codex",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                hook_command: Some("/tmp/tokenstat-hostd"),
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            guarded_codex
                .iter()
                .any(|arg| arg == "--dangerously-bypass-hook-trust")
        );
        let bypass = chat_agent_command(
            "claude",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: true,
                hook_command: None,
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            bypass
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions")
        );
    }

    #[test]
    fn chat_uses_native_image_flags_when_a_backend_has_them() {
        let attachment = std::path::PathBuf::from("/private/tmp/diagram.png");
        let codex = chat_agent_command(
            "codex",
            "look",
            None,
            None,
            0,
            ChatLaunch {
                resume: None,
                bypass: false,
                hook_command: None,
                attachments: &[attachment.clone()],
            },
        )
        .unwrap();
        assert!(
            codex
                .windows(2)
                .any(|pair| pair == ["-i", "/private/tmp/diagram.png"])
        );
        let opencode = chat_agent_command(
            "opencode",
            "look",
            None,
            None,
            0,
            ChatLaunch {
                resume: None,
                bypass: false,
                hook_command: None,
                attachments: &[attachment],
            },
        )
        .unwrap();
        assert!(
            opencode
                .windows(2)
                .any(|pair| pair == ["-f", "/private/tmp/diagram.png"])
        );
    }

    #[test]
    fn model_and_effort_flags_land_for_backends_that_advertise_them() {
        let claude = agent_command(
            "claude",
            "do it",
            Some("sonnet"),
            Some("high"),
            DEFAULT_BUDGET_SECONDS,
        )
        .unwrap();
        let at_model = claude.iter().position(|a| a == "--model").unwrap();
        assert_eq!(claude[at_model + 1], "sonnet");
        let at_effort = claude.iter().position(|a| a == "--effort").unwrap();
        assert_eq!(claude[at_effort + 1], "high");

        // A backend without the flags must not silently swallow them; the
        // shell ignores both because the client never offers a picker for it.
        let shell = agent_command(
            "sh",
            "ls",
            Some("sonnet"),
            Some("high"),
            DEFAULT_BUDGET_SECONDS,
        )
        .unwrap();
        assert!(!shell.iter().any(|a| a == "--model" || a == "--effort"));
    }

    #[test]
    fn interactive_command_is_a_tty_not_a_print_session() {
        let claude =
            interactive_agent_command("claude", "do it", Some("sonnet"), Some("high")).unwrap();
        assert_eq!(claude.first().map(String::as_str), Some("claude"));
        assert!(claude.iter().any(|a| a == "--dangerously-skip-permissions"));
        assert!(!claude.iter().any(|a| a == "-p" || a == "--print"));
        assert!(!claude.iter().any(|a| a == "stream-json"));
        assert!(claude.iter().any(|a| a == "do it"));

        let agy =
            interactive_agent_command("agy", "do it", Some("gemini-3.6-flash-high"), None).unwrap();
        assert!(!agy.iter().any(|a| a == "--print"));
        assert!(agy.iter().any(|a| a == "--dangerously-skip-permissions"));
        assert!(
            agy.windows(2)
                .any(|w| w == ["--prompt-interactive", "do it"])
        );

        let next =
            interactive_agent_command("opencode2", "do it", Some("opencode/foo"), None).unwrap();
        assert_eq!(next, vec!["opencode2", "--auto", "--prompt", "do it"]);

        let oc = interactive_agent_command("opencode", "do it", Some("opencode/foo"), Some("high"))
            .unwrap();
        assert_eq!(
            oc,
            vec![
                "opencode",
                "run",
                "-i",
                "--auto",
                "--model",
                "opencode/foo",
                "--variant",
                "high",
                "--",
                "do it"
            ]
        );

        assert!(interactive_agent_command("nope", "do it", None, None).is_err());
        assert!(interactive_agent_command("claude", "   ", None, None).is_err());
    }

    #[test]
    fn backends_include_opencode2() {
        let ids: Vec<String> = backends()
            .into_iter()
            .filter_map(|v| v.get("id")?.as_str().map(str::to_string))
            .collect();
        assert!(ids.contains(&"opencode".into()));
        assert!(ids.contains(&"opencode2".into()));
    }

    /// Register `dir` in the shared registry and return its id.
    ///
    /// The registry is process-wide, so this adds rather than replaces. Tests
    /// use their own temp folders, which keeps them independent of each other.
    fn sh_workspace(dir: &Path) -> String {
        let mut registry = crate::workspaces::write();
        registry.add(dir, now_ms()).unwrap().id
    }

    /// The same script in whichever shell the platform has. Kept next to the
    /// tests rather than reusing `shell_argv`, so a fixture cannot pass by
    /// agreeing with the code it is checking.
    fn test_shell_command(unix: &str, windows: &str) -> (String, Vec<String>) {
        // Both are always passed, only one of them ever runs.
        let _ = (unix, windows);
        #[cfg(unix)]
        {
            let _ = windows;
            ("/bin/sh".into(), vec!["-c".into(), unix.into()])
        }
        #[cfg(windows)]
        {
            ("cmd.exe".into(), vec!["/C".into(), windows.into()])
        }
    }

    #[test]
    fn a_run_drains_into_a_transcript_and_records_the_outcome() {
        let dir = temp_dir("run");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        let run_id = "run-test";
        let transcript_path = dir.join("runs").join("run-test.txt");
        let run = RunRecord {
            id: run_id.into(),
            job_id: "j".into(),
            name: "echo".into(),
            backend: "sh".into(),
            workspace_id: "w".into(),
            started_at_ms: now_ms(),
            ended_at_ms: None,
            exit_code: None,
            status: "running".into(),
            transcript_path: transcript_path.display().to_string(),
            pty_id: None,
            parent_run_id: None,
        };
        store.push_run(run).unwrap();

        let (command, args) = test_shell_command("printf hello", "echo hello");
        let info = tokenstat_pty::manager()
            .spawn(&tokenstat_pty::Spawn {
                command,
                args,
                cwd: dir.clone(),
                workspace_id: None,
                hidden: false,
                rows: 24,
                cols: 80,
                no_color: false,
                dark: None,
                environment: Vec::new(),
            })
            .unwrap();
        let pty_id = info.id.clone();
        // A budget long enough for a shell to start and print, short enough
        // that a run which never ends fails the test quickly instead of
        // holding the suite for the whole allowance.
        store.drain(&pty_id, &transcript_path, 10, run_id, "sh", true);

        let record = store
            .runs()
            .iter()
            .find(|r| r.id == run_id)
            .unwrap()
            .clone();
        let (text, _) = store.transcript(run_id, 0).unwrap();
        // The transcript is quoted on failure: a run recorded as stopped or
        // failed is far easier to explain when the terminal's own words are in
        // the message, and this test has only ever failed where nobody can
        // attach a debugger.
        assert_eq!(
            record.status, "ok",
            "exit code {:?}, transcript {text:?}",
            record.exit_code
        );
        assert!(text.contains("hello"), "transcript holds the output");
        assert!(transcript_path.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn finishing_a_run_persists_its_final_status() {
        let dir = temp_dir("persist");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::at(dir.join("jobs.json"));
        store
            .push_run(RunRecord {
                id: "run-persist".into(),
                job_id: "j".into(),
                name: "persist".into(),
                backend: "sh".into(),
                workspace_id: "w".into(),
                started_at_ms: now_ms(),
                ended_at_ms: None,
                exit_code: None,
                status: "running".into(),
                transcript_path: dir.join("run.txt").display().to_string(),
                pty_id: None,
                parent_run_id: None,
            })
            .unwrap();
        store.finish_run("run-persist", Some(0), "ok");
        let saved = std::fs::read_to_string(dir.join("runs").join("runs.json")).unwrap();
        assert!(saved.contains("\"status\": \"ok\""));
        assert!(saved.contains("\"endedAtMs\""));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_budget_kills_a_long_running_run() {
        let dir = temp_dir("run");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        let run_id = "run-budget";
        let transcript_path = dir.join("runs").join("run-budget.txt");
        let run = RunRecord {
            id: run_id.into(),
            job_id: "j".into(),
            name: "sleep".into(),
            backend: "sh".into(),
            workspace_id: "w".into(),
            started_at_ms: now_ms(),
            ended_at_ms: None,
            exit_code: None,
            status: "running".into(),
            transcript_path: transcript_path.display().to_string(),
            pty_id: None,
            parent_run_id: None,
        };
        store.push_run(run).unwrap();

        let (command, args) = test_shell_command("sleep 30", "ping -n 31 127.0.0.1 > nul");
        let info = tokenstat_pty::manager()
            .spawn(&tokenstat_pty::Spawn {
                command,
                args,
                cwd: dir.clone(),
                workspace_id: None,
                hidden: false,
                rows: 24,
                cols: 80,
                no_color: false,
                dark: None,
                environment: Vec::new(),
            })
            .unwrap();
        let pty_id = info.id.clone();
        store.drain(&pty_id, &transcript_path, 1, run_id, "sh", true);

        let record = store
            .runs()
            .iter()
            .find(|r| r.id == run_id)
            .unwrap()
            .clone();
        assert_eq!(record.status, "stopped", "budget stopped the run");
        assert!(
            record.ended_at_ms.is_some(),
            "the stopped run has an end time"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_scheduler_runs_only_due_jobs() {
        let dir = temp_dir("sched");
        std::fs::create_dir_all(&dir).unwrap();
        let workspace_id = sh_workspace(&dir);
        let store = Arc::new(Store::at(dir.join("jobs.json")));

        // A job due long ago on the harmless shell backend, enabled. Seeded
        // directly because `create` would recompute the schedule.
        let mut due = job("due", ScheduleSpec::default(), 30);
        due.workspace_id = workspace_id.clone();
        due.backend = "sh".into();
        due.prompt = if cfg!(windows) {
            "exit 0".into()
        } else {
            "true".into()
        };
        due.enabled = true;
        due.next_run_at_ms = Some(now_ms() - 60_000);
        store.seed(due);

        let mut never = job("never", ScheduleSpec::default(), 30);
        never.workspace_id = workspace_id;
        never.enabled = true;
        never.next_run_at_ms = Some(now_ms() + 60_000);
        store.seed(never);

        store.run_due();
        let jobs = store.list();
        let due = jobs.iter().find(|j| j.id == "due").unwrap();
        assert!(due.last_run_at_ms.is_some(), "the due job ran");
        let never = jobs.iter().find(|j| j.id == "never").unwrap();
        assert!(never.last_run_at_ms.is_none(), "the future job did not run");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_grok_shaped_transcript_is_readable_and_capped() {
        let dir = temp_dir("readable");
        std::fs::create_dir_all(dir.join("runs")).unwrap();
        let store = Store::at(dir.join("jobs.json"));
        let raw_path = dir.join("runs").join("run-grok.txt");
        let raw = concat!(
            "{\"type\":\"thought\",\"data\":\"nope\"}\n",
            "{\"type\":\"text\",\"data\":\"hello from grok\"}\n",
            "{\"type\":\"end\",\"stopReason\":\"end_turn\"}\n",
        );
        std::fs::write(&raw_path, raw).unwrap();
        let mut parser = crate::transcript::Parser::new("grok");
        let mut readable = parser.push(raw.as_bytes());
        readable.push_str(&parser.finish());
        std::fs::write(crate::transcript::readable_path(&raw_path), &readable).unwrap();
        store
            .push_run(RunRecord {
                id: "run-grok".into(),
                job_id: "j".into(),
                name: "g".into(),
                backend: "grok".into(),
                workspace_id: "w".into(),
                started_at_ms: now_ms(),
                ended_at_ms: None,
                exit_code: Some(0),
                status: "ok".into(),
                transcript_path: raw_path.display().to_string(),
                pty_id: None,
                parent_run_id: None,
            })
            .unwrap();
        let (text, next) = store.transcript("run-grok", 0).unwrap();
        assert!(text.contains("hello from grok"));
        assert!(!text.contains("thought"));
        assert!(!text.contains("end_turn"));
        assert!(next as usize <= crate::transcript::REPLY_CAP);
        assert!(next as usize >= text.len());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_raw_only_grok_run_is_parsed_on_read() {
        let dir = temp_dir("raw-only");
        std::fs::create_dir_all(dir.join("runs")).unwrap();
        let store = Store::at(dir.join("jobs.json"));
        let raw_path = dir.join("runs").join("run-old.txt");
        std::fs::write(
            &raw_path,
            concat!(
                "{\"type\":\"available_commands\",\"tools\":[\"read_file\"]}\n",
                "{\"type\":\"thought\",\"data\":\"planning\"}\n",
                "{\"type\":\"text\",\"data\":\"I'll start\"}\n",
            ),
        )
        .unwrap();
        store
            .push_run(RunRecord {
                id: "run-old".into(),
                job_id: "j".into(),
                name: "Release".into(),
                backend: "grok".into(),
                workspace_id: "w".into(),
                started_at_ms: now_ms(),
                ended_at_ms: Some(now_ms()),
                exit_code: None,
                status: "interrupted".into(),
                transcript_path: raw_path.display().to_string(),
                pty_id: None,
                parent_run_id: None,
            })
            .unwrap();
        let (text, _) = store.transcript("run-old", 0).unwrap();
        assert_eq!(text, "I'll start");
        assert!(!text.contains('{'));
        assert!(crate::transcript::readable_path(&raw_path).is_file());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_readable_that_is_still_ndjson_is_rebuilt() {
        let dir = temp_dir("ndjson-readable");
        std::fs::create_dir_all(dir.join("runs")).unwrap();
        let store = Store::at(dir.join("jobs.json"));
        let raw_path = dir.join("runs").join("run-stale.txt");
        let raw = "{\"type\":\"text\",\"data\":\"hello\"}\n";
        std::fs::write(&raw_path, raw).unwrap();
        std::fs::write(crate::transcript::readable_path(&raw_path), raw).unwrap();
        store
            .push_run(RunRecord {
                id: "run-stale".into(),
                job_id: "j".into(),
                name: "Release".into(),
                backend: "grok".into(),
                workspace_id: "w".into(),
                started_at_ms: now_ms(),
                ended_at_ms: Some(now_ms()),
                exit_code: Some(0),
                status: "ok".into(),
                transcript_path: raw_path.display().to_string(),
                pty_id: None,
                parent_run_id: None,
            })
            .unwrap();
        let (text, _) = store.transcript("run-stale", 0).unwrap();
        assert_eq!(text, "hello");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn queue_config_defaults_and_persists() {
        let dir = temp_dir("queue");
        let store = Store::at(dir.join("automations.json"));
        let q = store.queue_config();
        assert_eq!(q.default_budget_seconds, DEFAULT_BUDGET_SECONDS);
        assert_eq!(q.max_concurrent, DEFAULT_MAX_CONCURRENT);
        store
            .set_queue_config(QueueConfig {
                default_budget_seconds: 0,
                max_concurrent: 4,
            })
            .unwrap();
        let body = std::fs::read_to_string(dir.join("automations.json")).unwrap();
        assert!(body.contains("\"defaultBudgetSeconds\": 0"));
        assert!(body.contains("\"maxConcurrent\": 4"));
        let parsed: QueueConfig = serde_json::from_str(r#"{"defaultBudgetSeconds":0}"#).unwrap();
        assert_eq!(parsed.max_concurrent, DEFAULT_MAX_CONCURRENT);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn raising_the_cap_starts_a_waiter() {
        let dir = temp_dir("queue-pump");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        store
            .set_queue_config(QueueConfig {
                default_budget_seconds: 30,
                max_concurrent: 1,
            })
            .unwrap();
        let workspace_id = sh_workspace(&dir);
        let make = |id: &str| Automation {
            id: id.into(),
            name: id.into(),
            backend: "sh".into(),
            model: None,
            effort: None,
            workspace_id: workspace_id.clone(),
            prompt: "sleep 8".into(),
            schedule: ScheduleSpec::default(),
            budget_seconds: 15,
            enabled: false,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
        };
        let first = store.run_adhoc(make("a")).unwrap();
        let second = store.run_adhoc(make("b")).unwrap();
        assert_eq!(first.status, "running");
        assert_eq!(second.status, "queued");
        store
            .apply_queue_config(QueueConfig {
                default_budget_seconds: 30,
                max_concurrent: 2,
            })
            .unwrap();
        let second_now = store
            .runs()
            .into_iter()
            .find(|r| r.id == second.id)
            .unwrap();
        assert_eq!(second_now.status, "running");
        let _ = store.kill_run(&first.id);
        let _ = store.kill_run(&second.id);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn killing_a_queued_run_does_not_start_it() {
        let dir = temp_dir("queue-kill");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        store
            .set_queue_config(QueueConfig {
                default_budget_seconds: 30,
                max_concurrent: 1,
            })
            .unwrap();
        let workspace_id = sh_workspace(&dir);
        let make = |id: &str| Automation {
            id: id.into(),
            name: id.into(),
            backend: "sh".into(),
            model: None,
            effort: None,
            workspace_id: workspace_id.clone(),
            prompt: "sleep 8".into(),
            schedule: ScheduleSpec::default(),
            budget_seconds: 15,
            enabled: false,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
        };
        let first = store.run_adhoc(make("a")).unwrap();
        let second = store.run_adhoc(make("b")).unwrap();
        assert_eq!(second.status, "queued");
        store.kill_run(&second.id).unwrap();
        store.pump();
        let second_now = store
            .runs()
            .into_iter()
            .find(|r| r.id == second.id)
            .unwrap();
        assert_eq!(second_now.status, "stopped");
        assert_eq!(second_now.pty_id, None);
        let _ = store.kill_run(&first.id);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn update_run_does_not_revive_a_finished_row() {
        let dir = temp_dir("no-revive");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::at(dir.join("jobs.json"));
        store
            .push_run(RunRecord {
                id: "run-done".into(),
                job_id: "j".into(),
                name: "done".into(),
                backend: "sh".into(),
                workspace_id: "w".into(),
                started_at_ms: now_ms(),
                ended_at_ms: Some(now_ms()),
                exit_code: Some(0),
                status: "ok".into(),
                transcript_path: dir.join("run.txt").display().to_string(),
                pty_id: None,
                parent_run_id: None,
            })
            .unwrap();
        store
            .update_run(RunRecord {
                id: "run-done".into(),
                job_id: "j".into(),
                name: "done".into(),
                backend: "sh".into(),
                workspace_id: "w".into(),
                started_at_ms: now_ms(),
                ended_at_ms: None,
                exit_code: None,
                status: "running".into(),
                transcript_path: dir.join("run.txt").display().to_string(),
                pty_id: Some("pty-late".into()),
                parent_run_id: None,
            })
            .unwrap();
        let row = store
            .runs()
            .into_iter()
            .find(|r| r.id == "run-done")
            .unwrap();
        assert_eq!(row.status, "ok");
        assert_eq!(row.pty_id, None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_fast_exit_is_not_left_running() {
        let dir = temp_dir("fast-exit");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        let workspace_id = sh_workspace(&dir);
        let job = Automation {
            id: "fast".into(),
            name: "fast".into(),
            backend: "sh".into(),
            model: None,
            effort: None,
            workspace_id,
            prompt: if cfg!(windows) {
                "exit 0".into()
            } else {
                "true".into()
            },
            schedule: ScheduleSpec::default(),
            budget_seconds: 15,
            enabled: false,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
        };
        let run = store.run_adhoc(job).unwrap();
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            let row = store.runs().into_iter().find(|r| r.id == run.id).unwrap();
            if row.status != "running" && row.status != "queued" {
                assert_eq!(row.status, "ok", "fast exit left as {}", row.status);
                break;
            }
            assert!(Instant::now() < deadline, "fast exit still {}", row.status);
            std::thread::sleep(Duration::from_millis(40));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn start_now_does_not_release_a_slot_it_never_took() {
        let dir = temp_dir("start-now-slot");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        store
            .set_queue_config(QueueConfig {
                default_budget_seconds: 30,
                max_concurrent: 1,
            })
            .unwrap();
        assert!(store.try_take_slot());
        assert_eq!(store.active_slots(), 1);
        let workspace_id = sh_workspace(&dir);
        let job = store
            .create(Automation {
                id: "nested".into(),
                name: "nested".into(),
                backend: "sh".into(),
                model: None,
                effort: None,
                workspace_id,
                prompt: if cfg!(windows) {
                    "exit 0".into()
                } else {
                    "true".into()
                },
                schedule: ScheduleSpec::default(),
                budget_seconds: 15,
                enabled: false,
                last_run_at_ms: None,
                next_run_at_ms: None,
                last_run_id: None,
            })
            .unwrap();
        let run = store.start_now(&job.id, None, None).unwrap();
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            let row = store.get_run(&run.id).unwrap();
            if row.status != "running" && row.status != "queued" {
                assert_eq!(row.status, "ok", "nested run left as {}", row.status);
                break;
            }
            assert!(Instant::now() < deadline, "nested run still {}", row.status);
            std::thread::sleep(Duration::from_millis(40));
        }
        assert_eq!(store.active_slots(), 1);
        store.release_slot();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn start_now_uses_the_prompt_override() {
        let dir = temp_dir("start-now-override");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        let workspace_id = sh_workspace(&dir);
        let job = store
            .create(Automation {
                id: "over".into(),
                name: "over".into(),
                backend: "sh".into(),
                model: None,
                effort: None,
                workspace_id,
                prompt: if cfg!(windows) {
                    "echo STORED".into()
                } else {
                    "printf STORED".into()
                },
                schedule: ScheduleSpec::default(),
                budget_seconds: 15,
                enabled: false,
                last_run_at_ms: None,
                next_run_at_ms: None,
                last_run_id: None,
            })
            .unwrap();
        let run = store
            .start_now(
                &job.id,
                Some(if cfg!(windows) {
                    "echo OVERRIDE"
                } else {
                    "printf OVERRIDE"
                }),
                None,
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            let row = store.get_run(&run.id).unwrap();
            if row.status != "running" && row.status != "queued" {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "override run still {}",
                row.status
            );
            std::thread::sleep(Duration::from_millis(40));
        }
        let (text, _) = store.transcript(&run.id, 0).unwrap();
        assert!(
            text.contains("OVERRIDE"),
            "override missing from transcript: {text:?}"
        );
        assert!(
            !text.contains("STORED"),
            "stored prompt still ran: {text:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
