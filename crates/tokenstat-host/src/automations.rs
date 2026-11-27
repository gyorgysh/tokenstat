// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Daemon-owned agent jobs: a backend, a prompt, a schedule, and a budget.

use std::collections::{BTreeMap, HashSet, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::transcript::{self, Parser};

use serde::{Deserialize, Serialize};

mod receipts;
pub use receipts::{AutomationCreationOutcome, AutomationRunOutcome};

const RUNS_KEPT: usize = 100;

/// Default time limit for a new job or card, in seconds (180 minutes).
pub const DEFAULT_BUDGET_SECONDS: u64 = 180 * 60;

/// Default number of agent runs that may execute at once.
pub const DEFAULT_MAX_CONCURRENT: u32 = 2;

const TICK: Duration = Duration::from_secs(5);

const DRAIN_POLL: Duration = Duration::from_millis(20);

const DRAIN_TAIL: Duration = Duration::from_millis(300);

const EXIT_SETTLE: Duration = Duration::from_secs(2);

const WEEKDAYS_MASK: u8 = 0b0001_1111;

const MAX_INTERVAL_SECONDS: u64 = 365 * 24 * 60 * 60;

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
    /// Interval only. Seconds between runs, at least a minute and at most a
    /// year.
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
                } else if self.every_seconds > MAX_INTERVAL_SECONDS {
                    Err("an interval must be at most a year".into())
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

    /// The next time this fires on this process's clock, or None for a once job.
    pub fn next_run_ms(&self, from: i64) -> Option<i64> {
        self.next_run_ms_in(from, jiff::tz::TimeZone::system())
    }

    /// The next time this fires in `tz`. Wall-clock kinds use that zone's civil
    /// time, including its daylight-saving transitions. Interval jobs ignore it.
    pub fn next_run_ms_in(&self, from: i64, tz: jiff::tz::TimeZone) -> Option<i64> {
        match self.kind {
            ScheduleKind::Once => None,
            ScheduleKind::Interval => {
                let step = i64::try_from(self.every_seconds).ok()?.checked_mul(1000)?;
                from.checked_add(step)
            }
            ScheduleKind::Daily => next_wall_clock(from, self.hour, self.minute, None, tz),
            ScheduleKind::Weekdays | ScheduleKind::Weekly | ScheduleKind::Custom => {
                let mask = self.day_mask();
                if mask == 0 {
                    return None;
                }
                next_wall_clock(from, self.hour, self.minute, Some(mask), tz)
            }
        }
    }
}

fn next_wall_clock(
    from_ms: i64,
    hour: u8,
    minute: u8,
    day_mask: Option<u8>,
    tz: jiff::tz::TimeZone,
) -> Option<i64> {
    use jiff::civil::DateTime;

    let from = jiff::Timestamp::from_millisecond(from_ms).ok()?;
    let zoned = from.to_zoned_datetime(tz.clone());
    let mut day = zoned.date();
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
            let z = dt.to_zoned_datetime(tz.clone()).ok()?;
            let ms = z.timestamp().as_millisecond();
            if ms > from_ms {
                return Some(ms);
            }
        }
        day = day.tomorrow().ok()?;
    }
    None
}

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
    agent_command_in(backend, prompt, model, effort, budget_seconds, None)
}

pub(crate) struct AgentRunCommand {
    pub(crate) argv: Vec<String>,
    pub(crate) environment: Vec<(String, String)>,
}

/// Build an agent's command for a run that may use a local model: the
/// model name the CLI expects, its local flags, and the environment that
/// points it at LM Studio or Ollama. The same setup chat turns use.
pub(crate) fn with_local_model(
    backend: &str,
    model: Option<&str>,
    build: impl FnOnce(Option<&str>) -> Result<Vec<String>, String>,
) -> Result<AgentRunCommand, String> {
    let run = crate::chat::turn_model(backend, model)?;
    let mut argv = build(run.cli.as_deref())?;
    if !run.leading_args.is_empty() && !argv.is_empty() {
        argv.splice(1..1, run.leading_args.iter().cloned());
    }
    Ok(AgentRunCommand {
        argv,
        environment: run.environment,
    })
}

pub(crate) fn agent_command_in(
    backend: &str,
    prompt: &str,
    model: Option<&str>,
    effort: Option<&str>,
    budget_seconds: u64,
    directory: Option<&Path>,
) -> Result<Vec<String>, String> {
    let p = prompt.trim();
    if p.is_empty() {
        return Err("an automation needs a prompt".into());
    }

    let model = crate::agent_models::sanitize_cli_model(backend, model);
    let model = model.as_deref();
    let effort = crate::agent_models::sanitize_cli_effort(effort);
    let effort = effort.as_deref();
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
                    "--verbose",
                    "--include-partial-messages",
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
            if let Some(e) = effort {
                args.extend(["-c".into(), format!("model_reasoning_effort={e}")]);
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
        "muse" => {
            args.extend(["muse", "exec", "--json"].map(str::to_string));
            if let Some(m) = model {
                args.extend(["--model", m].map(str::to_string));
            }
            if let Some(e) = effort {
                args.extend(["--reasoning-effort", e].map(str::to_string));
            }

            args.extend(["--yolo", "--", p].map(str::to_string));
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
                    "--force",
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

            let timeout = agy_print_timeout(budget_seconds);
            args.extend(
                [
                    "--print",
                    p,
                    "--output-format",
                    "stream-json",
                    "--print-timeout",
                    timeout.as_str(),
                    "--dangerously-skip-permissions",
                ]
                .map(str::to_string),
            );
        }
        "opencode" | "opencode2" => {
            args.push(backend.into());
            args.extend(["run", "--auto", "--format", "json"].map(str::to_string));
            let generation = crate::opencode_cli::require_generation(backend)?;
            if generation == crate::opencode_cli::Generation::V2 {
                args.extend(["--standalone", "--thinking"].map(str::to_string));
            }
            args.extend(crate::opencode_cli::model_arguments(
                backend, generation, model, effort, directory,
            ));
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
    /// `plan` or `execute`. Plan uses a native CLI flag where the backend has
    /// one. Backends without a flag keep their existing prompt path.
    pub mode: &'a str,
    /// Absolute path of this daemon, which is also the gate hook. `None` in
    /// Bypass, where nothing is asked. `chat_gate` turns it into a runnable,
    /// shell-quoted command line: the path contains a space on every Mac, and
    /// building that line by interpolation is what left Standard mode unable
    /// to stop a single tool call.
    pub hook_helper: Option<&'a Path>,
    /// The conversation's standing rules: its persona brief and how to hand a
    /// file back. Delivered through a backend's own system-prompt flag where
    /// one exists, and prepended to the turn in a tagged block where one does
    /// not. Never glued to the person's sentence unwrapped: see `chat_turn`
    /// for why an agent answered the plumbing instead of the ask.
    pub system_append: Option<&'a str>,
    /// Agy discovers hooks from each supplied workspace. The private root goes
    /// first; the person's workspace remains last, preserving its normal cwd.
    pub agy_customization_dir: Option<&'a Path>,
    /// A private Cursor plugin holding the gate's hooks, loaded with
    /// `--plugin-dir` so nothing is written to `~/.cursor` or the workspace.
    pub cursor_plugin_dir: Option<&'a Path>,
    /// Grok's documented rules are its Standard-mode contract. Unmatched calls
    /// fall through to `dontAsk`, which denies in a headless turn.
    pub grok_allow_rules: &'a [String],
    pub attachments: &'a [std::path::PathBuf],
}

/// A one-turn text transform configured without write-capable agent modes.
///
/// Persona drafting used to reuse [`agent_command`], whose contract is an
/// unattended automation and therefore deliberately bypasses every backend's
/// permission layer. A temporary cwd is not a sandbox: an agent can still
/// walk out of it and edit the repository or somebody's home directory. Use
/// the chat command's plan/read-only path instead, with no approval hook and
/// no attachments, so every supported backend either gets its native
/// non-writing mode or runs headlessly without auto-approval.
pub fn persona_draft_command(
    backend: &str,
    prompt: &str,
    budget_seconds: u64,
) -> Result<Vec<String>, String> {
    if backend == "sh" {
        return Err("pick an agent to write the draft".into());
    }
    chat_agent_command(
        backend,
        prompt,
        None,
        None,
        budget_seconds,
        ChatLaunch {
            resume: None,
            bypass: false,
            mode: "plan",
            hook_helper: None,
            system_append: None,
            agy_customization_dir: None,
            cursor_plugin_dir: None,
            grok_allow_rules: &[],
            attachments: &[],
        },
    )
}

fn command_word_positions(argv: &[String]) -> Vec<usize> {
    let mut positions = Vec::new();
    let mut index = 1;
    while index < argv.len() {
        positions.push(index);
        let argument = argv[index].as_str();
        if argument == "--" {
            break;
        }

        index += if matches!(
            argument,
            "--model"
                | "--effort"
                | "--reasoning-effort"
                | "--variant"
                | "-c"
                | "--output-format"
                | "--format"
                | "--print-timeout"
                | "--permission-mode"
                | "-p"
                | "--print"
                | "--single"
                | "--prompt-interactive"
                | "--prompt"
                | "--append-system-prompt"
                | "--rules"
                | "--settings"
                | "--disallowedTools"
                | "--allow"
                | "--sandbox"
                | "--mode"
                | "--plugin-dir"
                | "--add-dir"
                | "--resume"
                | "--conversation"
                | "--session-id"
                | "-s"
                | "-i"
                | "-f"
                | "resume"
        ) {
            2
        } else {
            1
        };
    }
    positions
}

fn command_word_at(argv: &[String], word: &str) -> Option<usize> {
    command_word_positions(argv)
        .into_iter()
        .find(|&index| argv[index] == word)
}

fn remove_cli_options(argv: &mut Vec<String>, options: &[&str]) {
    for index in command_word_positions(argv).into_iter().rev() {
        if options.contains(&argv[index].as_str()) {
            let count = if argv[index] == "--permission-mode" {
                2
            } else {
                1
            };
            argv.drain(index..(index + count).min(argv.len()));
        }
    }
}

fn headless_flag_at(argv: &[String]) -> usize {
    command_word_positions(argv)
        .into_iter()
        .find(|&index| {
            matches!(
                argv[index].as_str(),
                "-p" | "--print" | "--single" | "--prompt-interactive" | "--"
            )
        })
        .unwrap_or(argv.len())
}

fn insert_flags(argv: &mut Vec<String>, flags: impl IntoIterator<Item = String>) {
    let at = headless_flag_at(argv);
    argv.splice(at..at, flags);
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
    chat_agent_command_in(backend, prompt, model, effort, budget_seconds, launch, None)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn chat_agent_command_in(
    backend: &str,
    prompt: &str,
    model: Option<&str>,
    effort: Option<&str>,
    budget_seconds: u64,
    launch: ChatLaunch<'_>,
    directory: Option<&Path>,
) -> Result<Vec<String>, String> {
    let plan = launch.mode == "plan";

    let mut instructions = String::new();

    if plan && matches!(backend, "codex" | "opencode" | "opencode2" | "muse") {
        instructions.push_str(
            "Plan mode: inspect and reason only. Do not modify files, run commands that change state, or perform external side effects. Return a proposed plan instead.",
        );
    }

    if !crate::chat_turn::accepts_system_prompt(backend)
        && let Some(standing) = launch
            .system_append
            .map(str::trim)
            .filter(|t| !t.is_empty())
    {
        if !instructions.is_empty() {
            instructions.push_str("\n\n");
        }
        instructions.push_str(standing);
    }
    let composed = crate::chat_turn::as_prompt_prefix(&instructions, prompt);
    let prompt = composed.as_str();

    let cursor_default = matches!(backend, "cursor")
        && model
            .map(|value| value.trim().is_empty() || value.trim() == "auto")
            .unwrap_or(true);
    let model = if cursor_default { Some("auto") } else { model };
    let mut argv = agent_command_in(backend, prompt, model, effort, budget_seconds, directory)?;
    if backend == "muse" && (!launch.bypass || plan) {
        if let Some(index) = command_word_at(&argv, "--yolo") {
            argv.remove(index);
        }
        if plan {
            let at = headless_flag_at(&argv);
            argv.splice(at..at, ["--disable-write".into(), "--disable-shell".into()]);
        }
    }

    let agy_gated = backend == "agy" && !plan && launch.hook_helper.is_some();

    let cursor_gated = backend == "cursor"
        && !plan
        && launch.hook_helper.is_some()
        && launch.cursor_plugin_dir.is_some();
    if (!launch.bypass || plan) && !agy_gated && !cursor_gated {
        match backend {
            "claude" | "agy" => remove_cli_options(&mut argv, &["--dangerously-skip-permissions"]),
            "codex" => {
                remove_cli_options(&mut argv, &["--dangerously-bypass-approvals-and-sandbox"])
            }
            "cursor" => remove_cli_options(&mut argv, &["--trust", "--force"]),
            "opencode" | "opencode2" => remove_cli_options(&mut argv, &["--auto"]),
            _ => {}
        }
    }
    let mut extra = Vec::new();
    if plan && matches!(backend, "opencode" | "opencode2") {
        extra.extend(["--agent".into(), "plan".into()]);
    }
    if backend == "grok" {
        remove_cli_options(
            &mut argv,
            &["--permission-mode", "--always-approve", "--yolo"],
        );

        let permission = if plan {
            "plan"
        } else if launch.bypass || launch.hook_helper.is_some() {
            "bypassPermissions"
        } else {
            "dontAsk"
        };
        extra.extend(["--permission-mode".into(), permission.into()]);
        if plan && (launch.bypass || launch.hook_helper.is_some()) {
            extra.push("--always-approve".into());
        }

        if !launch.bypass && !plan {
            for rule in launch.grok_allow_rules {
                extra.extend(["--allow".into(), rule.clone()]);
            }
        }
    }

    if let Some(standing) = launch
        .system_append
        .map(str::trim)
        .filter(|t| !t.is_empty())
    {
        match backend {
            "claude" => extra.extend(["--append-system-prompt".into(), standing.into()]),
            "grok" => extra.extend(["--rules".into(), standing.into()]),
            _ => {}
        }
    }

    if backend == "claude" {
        extra.extend(["--disallowedTools".into(), "AskUserQuestion".into()]);
    }
    if plan {
        match backend {
            "claude" => extra.extend(["--permission-mode".into(), "plan".into()]),
            "codex" => extra.extend(["--sandbox".into(), "read-only".into()]),
            "cursor" => extra.push("--plan".into()),
            "agy" => extra.extend(["--mode".into(), "plan".into()]),
            _ => {}
        }
    }
    if backend == "claude"
        && !launch.bypass
        && let Some(helper) = launch.hook_helper
    {
        insert_flags(
            &mut argv,
            [
                "--settings".into(),
                crate::chat_gate::claude_settings(helper),
            ],
        );
    }
    if backend == "codex" && !launch.bypass && launch.hook_helper.is_some() {
        let at = command_word_at(&argv, "exec").unwrap_or(argv.len());
        argv.splice(at + 1..at + 1, ["--dangerously-bypass-hook-trust".into()]);
        if !plan {
            extra.extend(["--sandbox".into(), "workspace-write".into()]);
        }
    }
    if cursor_gated
        && !launch.bypass
        && let Some(directory) = launch.cursor_plugin_dir
    {
        insert_flags(
            &mut argv,
            ["--plugin-dir".into(), directory.display().to_string()],
        );
    }
    if backend == "agy"
        && !launch.bypass
        && let Some(directory) = launch.agy_customization_dir
    {
        insert_flags(
            &mut argv,
            ["--add-dir".into(), directory.display().to_string()],
        );
    }

    if crate::chat_turn::accepts_attachment_flags(backend) {
        let flag = if backend == "codex" { "-i" } else { "-f" };
        let at = command_word_at(&argv, "--").unwrap_or(argv.len());
        let flags = launch
            .attachments
            .iter()
            .filter(|path| crate::chat_turn::native_attachment(backend, path))
            .flat_map(|path| [flag.to_string(), path.display().to_string()]);
        argv.splice(at..at, flags);
    }
    if let Some(token) = launch.resume.filter(|token| !token.trim().is_empty()) {
        match backend {
            "claude" | "grok" | "cursor" => {
                extra.extend(["--resume".into(), token.into()]);
            }
            "codex" => {
                if let Some(at) = command_word_at(&argv, "exec") {
                    argv.splice(at + 1..at + 1, ["resume".into(), token.into()]);
                }
            }
            "agy" => extra.extend(["--conversation".into(), token.into()]),
            "opencode" | "opencode2" => {
                if let Some(at) = command_word_at(&argv, "run") {
                    argv.splice(at + 1..at + 1, ["-s".into(), token.into()]);
                }
            }
            "muse" => extra.extend(["--session-id".into(), token.into()]),
            "sh" => return Err("shell conversations cannot be resumed".into()),
            _ => {}
        }
    }
    if !extra.is_empty() {
        insert_flags(&mut argv, extra);
    }
    if backend == "codex"
        && launch.resume.is_some_and(|token| !token.trim().is_empty())
        && let Some(exec) = command_word_at(&argv, "exec")
    {
        if let Some(at) = command_word_at(&argv, "--sandbox")
            && let Some(value) = argv.get(at + 1).cloned()
        {
            argv.drain(at..=at + 1);
            let exec = command_word_at(&argv, "exec").unwrap_or(exec);
            argv.splice(exec + 1..exec + 1, ["--sandbox".into(), value]);
        }
        if let Some(at) = command_word_at(&argv, "--dangerously-bypass-hook-trust") {
            argv.remove(at);
            let exec = command_word_at(&argv, "exec").unwrap_or(exec);
            argv.splice(
                exec + 1..exec + 1,
                ["--dangerously-bypass-hook-trust".into()],
            );
        }
    }
    Ok(argv)
}

/// Argv for an interactive TTY. Same backends as [`agent_command`], without
/// print or stream-json flags. Interactive task runs keep a run record and
/// transcript, but no time budget, while the person can watch the host PTY.
pub fn interactive_agent_command(
    backend: &str,
    prompt: &str,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<Vec<String>, String> {
    interactive_agent_command_in(backend, prompt, model, effort, None)
}

pub(crate) fn interactive_agent_command_in(
    backend: &str,
    prompt: &str,
    model: Option<&str>,
    effort: Option<&str>,
    directory: Option<&Path>,
) -> Result<Vec<String>, String> {
    let p = prompt.trim();
    if p.is_empty() {
        return Err("an interactive run needs a prompt".into());
    }

    let model = crate::agent_models::sanitize_cli_model(backend, model);
    let model = model.as_deref();
    let effort = crate::agent_models::sanitize_cli_effort(effort);
    let effort = effort.as_deref();
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
            if let Some(e) = effort {
                args.extend(["-c".into(), format!("model_reasoning_effort={e}")]);
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
        "muse" => {
            args.push("muse".into());
            if let Some(m) = model {
                args.extend(["--model", m].map(str::to_string));
            }
            if let Some(e) = effort {
                args.extend(["--reasoning-effort", e].map(str::to_string));
            }
            args.extend(["--yolo", p].map(str::to_string));
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

            args.extend(
                ["--dangerously-skip-permissions", "--prompt-interactive", p].map(str::to_string),
            );
        }
        "opencode" | "opencode2" => {
            let generation = crate::opencode_cli::require_generation(backend)?;
            if generation == crate::opencode_cli::Generation::V2 {
                args.extend([backend, "mini", "--standalone"].map(str::to_string));
                args.extend(crate::opencode_cli::model_arguments(
                    backend, generation, model, effort, directory,
                ));
                args.extend(["--prompt", p].map(str::to_string));
                return Ok(args);
            }

            args.push(backend.into());
            args.extend(["run", "-i", "--auto"].map(str::to_string));
            args.extend(crate::opencode_cli::model_arguments(
                backend, generation, model, effort, directory,
            ));
            args.extend(["--", p].map(str::to_string));
        }
        other => return Err(format!("unknown backend {other}")),
    }
    Ok(args)
}

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

pub(crate) struct BackendSpec {
    pub id: &'static str,
    pub label: &'static str,
    pub command: &'static str,
    pub executable: &'static str,
    pub efforts: &'static [&'static str],
}

const BACKENDS: &[BackendSpec] = &[
    BackendSpec {
        id: "sh",
        executable: "sh",
        label: "Shell",
        command: "sh -c \"…\"",
        efforts: &[],
    },
    BackendSpec {
        id: "claude",
        executable: "claude",
        label: "Claude",
        command: "claude -p \"…\"",
        efforts: &["low", "medium", "high", "xhigh", "max"],
    },
    BackendSpec {
        id: "codex",
        executable: "codex",
        label: "Codex",
        command: "codex exec … -- \"…\"",
        efforts: &["low", "medium", "high", "xhigh", "max"],
    },
    BackendSpec {
        id: "muse",
        executable: "muse",
        label: "Muse",
        command: "muse exec --json …",
        efforts: &["minimal", "low", "medium", "high", "xhigh", "max", "ultra"],
    },
    BackendSpec {
        id: "grok",
        executable: "grok",
        label: "Grok",
        command: "grok -p \"…\"",
        efforts: &["low", "medium", "high"],
    },
    BackendSpec {
        id: "cursor",
        executable: "cursor-agent",
        label: "Cursor",
        command: "cursor-agent -p …",
        efforts: &[],
    },
    BackendSpec {
        id: "agy",
        executable: "agy",
        label: "Antigravity",
        command: "agy --print \"…\"",
        efforts: &[],
    },
    BackendSpec {
        id: "opencode",
        executable: "opencode",
        label: "OpenCode",
        command: "opencode run \"…\"",
        efforts: &["minimal", "medium", "high", "max"],
    },
    BackendSpec {
        id: "opencode2",
        executable: "opencode2",
        label: "OpenCode 2",
        command: "opencode2 run \"…\"",
        efforts: &["minimal", "medium", "high", "max"],
    },
];

pub(crate) fn agent_backends() -> impl Iterator<Item = &'static BackendSpec> {
    BACKENDS.iter().filter(|backend| backend.id != "sh")
}

/// The backends a client can choose from, in picker order.
///
/// `models` are taken from the installed CLI when it can list them
/// (`grok models`, `cursor-agent models`, `agy models`, `opencode models`).
/// Otherwise the curated list in `agent_models::fallback_for` applies:
/// Claude has no list command (`--help` documents aliases, and those stay
/// the contract) and neither does Muse. A backend with an empty list gets
/// no model picker. Effort values are still the flags each CLI's `--help`
/// names. `force` is somebody pressing Refresh in the picker: probe the
/// CLIs now and wait, instead of serving the cache while a background pass
/// catches up.
/// The name a person reads for an agent, such as "Claude".
pub(crate) fn backend_label(id: &str) -> &str {
    BACKENDS
        .iter()
        .find(|backend| backend.id == id)
        .map_or(id, |backend| backend.label)
}

pub fn backends(force: bool) -> Vec<serde_json::Value> {
    if force {
        crate::agent_models::refresh_now();
    } else {
        crate::agent_models::refresh();
    }
    BACKENDS.iter().map(|backend| {
        let models = crate::agent_models::for_backend(backend.id, crate::agent_models::fallback_for(backend.id));
        serde_json::json!({"id": backend.id, "label": backend.label, "command": backend.command, "models": models, "efforts": backend.efforts})
    }).collect()
}

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
    /// Monotonic within this job. User-facing mutations advance it. Run
    /// metadata (`last_run_*`) does not, so a live run cannot collide with
    /// an editor that did not change the job.
    #[serde(default)]
    pub revision: u64,
}

fn advance_revision(job: &mut Automation) -> Result<(), String> {
    if job.revision == u64::MAX {
        return Err("This job's revision cannot be advanced.".into());
    }
    job.revision += 1;
    Ok(())
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
    /// Interactive terminal output, rather than the backend's headless format.
    #[serde(default)]
    pub interactive: bool,
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

/// What `automation.queue` returns. Timezone is this process's scheduler clock,
/// not a stored setting, so it is never written into automations.json.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueStatus {
    pub default_budget_seconds: u64,
    pub max_concurrent: u32,
    pub timezone: String,
}

impl From<QueueConfig> for QueueStatus {
    fn from(config: QueueConfig) -> Self {
        Self {
            default_budget_seconds: config.default_budget_seconds,
            max_concurrent: config.max_concurrent,
            timezone: scheduler_timezone(),
        }
    }
}

/// IANA name of the zone wall-clock jobs fire in, or `unknown` when the
/// process clock has no name.
pub fn scheduler_timezone() -> String {
    jiff::tz::TimeZone::system()
        .iana_name()
        .unwrap_or("unknown")
        .to_string()
}

struct Pending {
    interactive: bool,
    job: Automation,
    run_id: String,
    transcript_path: PathBuf,
    parent_run_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct JobsFile {
    #[serde(default)]
    jobs: Vec<Automation>,
    #[serde(default)]
    queue: QueueConfig,
    #[serde(default)]
    creations: BTreeMap<String, receipts::CreationReceipt>,
    #[serde(default)]
    launches: BTreeMap<String, receipts::LaunchReceipt>,
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
    runs_error: Mutex<Option<String>>,
    jobs_error: Mutex<Option<String>>,
    queue: Mutex<QueueConfig>,
    creations: Mutex<BTreeMap<String, receipts::CreationReceipt>>,
    launches: Mutex<BTreeMap<String, receipts::LaunchReceipt>>,
    waiting: Mutex<VecDeque<Pending>>,
    active: Mutex<u32>,
    killed: Mutex<HashSet<String>>,
}

pub fn shared() -> Arc<Store> {
    static STORE: std::sync::OnceLock<Arc<Store>> = std::sync::OnceLock::new();
    Arc::clone(STORE.get_or_init(|| Arc::new(Store::load())))
}

fn load_jobs_file(path: &Path) -> (JobsFile, Option<String>) {
    let loaded = match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice::<JobsFile>(&bytes).map_err(|error| error.to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(JobsFile::default()),
        Err(error) => Err(error.to_string()),
    };
    match loaded {
        Ok(file) => (file, None),
        Err(error) => (
            JobsFile::default(),
            Some(format!(
                "The saved jobs could not be read. Their contents have been preserved. Restart the host after restoring access: {error}"
            )),
        ),
    }
}

fn load_runs_file(path: &Path) -> (Vec<RunRecord>, Option<String>) {
    let loaded = match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice::<RunsFile>(&bytes).map_err(|error| error.to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(RunsFile::default()),
        Err(error) => Err(error.to_string()),
    };
    match loaded {
        Ok(file) => (file.runs, None),
        Err(error) => (
            Vec::new(),
            Some(format!(
                "The saved run history could not be read. Restore access and restart the host before running work: {error}"
            )),
        ),
    }
}

impl Store {
    #[cfg(test)]
    fn at(path: PathBuf) -> Store {
        let parent = path.parent().unwrap_or(&path);
        let runs_dir = parent.join("runs");
        let runs_path = runs_dir.join("runs.json");
        let (runs, runs_error) = load_runs_file(&runs_path);
        Store {
            path,
            runs_path,
            runs_dir,
            jobs: Mutex::new(Vec::new()),
            runs: Mutex::new(runs),
            runs_error: Mutex::new(runs_error),
            jobs_error: Mutex::new(None),
            queue: Mutex::new(QueueConfig::default()),
            creations: Mutex::new(BTreeMap::new()),
            launches: Mutex::new(BTreeMap::new()),
            waiting: Mutex::new(VecDeque::new()),
            active: Mutex::new(0),
            killed: Mutex::new(HashSet::new()),
        }
    }

    #[cfg(test)]
    fn load_at(path: PathBuf) -> Store {
        let (file, jobs_error) = load_jobs_file(&path);
        let runs_dir = path.parent().unwrap_or(&path).join("runs");
        let runs_path = runs_dir.join("runs.json");
        let (runs, runs_error) = load_runs_file(&runs_path);
        Store {
            path,
            runs_path,
            runs_dir,
            jobs: Mutex::new(file.jobs),
            runs: Mutex::new(runs),
            runs_error: Mutex::new(runs_error),
            jobs_error: Mutex::new(jobs_error),
            queue: Mutex::new(file.queue),
            creations: Mutex::new(file.creations),
            launches: Mutex::new(file.launches),
            waiting: Mutex::new(VecDeque::new()),
            active: Mutex::new(0),
            killed: Mutex::new(HashSet::new()),
        }
    }

    pub fn load() -> Store {
        let dir = tokenstat_paths::data_dir().unwrap_or_else(|| PathBuf::from("."));
        let path = dir.join("automations.json");
        let (file, jobs_error) = load_jobs_file(&path);
        let runs_dir = dir.join("runs");
        let runs_path = runs_dir.join("runs.json");
        let (mut runs, runs_error) = load_runs_file(&runs_path);
        let mut recovered = false;
        for run in &mut runs {
            if matches!(run.status.as_str(), "starting" | "running" | "queued") {
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
            jobs: Mutex::new(file.jobs),
            runs: Mutex::new(runs),
            runs_error: Mutex::new(runs_error),
            jobs_error: Mutex::new(jobs_error),
            queue: Mutex::new(file.queue),
            creations: Mutex::new(file.creations),
            launches: Mutex::new(file.launches),
            waiting: Mutex::new(VecDeque::new()),
            active: Mutex::new(0),
            killed: Mutex::new(HashSet::new()),
        };
        if recovered {
            let _ = store.save_runs();
        }
        store
    }

    pub(super) fn ensure_jobs_available(&self) -> Result<(), String> {
        self.jobs_error
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map_or(Ok(()), |error| Err(error.clone()))
    }

    fn save(&self, jobs: &[Automation]) -> Result<(), String> {
        let queue = *self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let creations = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let launches = self.launches.lock().unwrap_or_else(PoisonError::into_inner);
        self.write_jobs(jobs, queue, &creations, &launches)
    }

    fn write_jobs(
        &self,
        jobs: &[Automation],
        queue: QueueConfig,
        creations: &BTreeMap<String, receipts::CreationReceipt>,
        launches: &BTreeMap<String, receipts::LaunchReceipt>,
    ) -> Result<(), String> {
        self.ensure_jobs_available()?;
        let body = serde_json::to_string_pretty(&JobsFile {
            jobs: jobs.to_vec(),
            queue,
            creations: creations.clone(),
            launches: launches.clone(),
        })
        .map_err(|e| e.to_string())?;
        write_atomic(&self.path, &body)
    }

    pub fn queue_config(&self) -> QueueConfig {
        *self.queue.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn queue_status(&self) -> QueueStatus {
        QueueStatus::from(self.queue_config())
    }

    pub fn set_queue_config(&self, mut next: QueueConfig) -> Result<QueueConfig, String> {
        next.max_concurrent = next.max_concurrent.min(32);
        let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let creations = self
            .creations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let launches = self.launches.lock().unwrap_or_else(PoisonError::into_inner);
        self.write_jobs(&jobs, next, &creations, &launches)?;
        *queue = next;
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

    pub(crate) fn ensure_runs_available(&self) -> Result<(), String> {
        self.runs_error
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map_or(Ok(()), |error| Err(error.clone()))
    }

    fn save_runs(&self) -> Result<(), String> {
        let runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        self.write_runs(&runs)
    }

    fn write_runs(&self, runs: &[RunRecord]) -> Result<(), String> {
        self.ensure_runs_available()?;
        let result = (|| -> Result<(), String> {
            std::fs::create_dir_all(&self.runs_dir).map_err(|e| e.to_string())?;
            let body = serde_json::to_vec_pretty(&RunsFile {
                runs: runs.to_vec(),
            })
            .map_err(|e| e.to_string())?;
            let mut temp =
                tempfile::NamedTempFile::new_in(&self.runs_dir).map_err(|e| e.to_string())?;
            temp.write_all(&body).map_err(|e| e.to_string())?;
            temp.as_file().sync_all().map_err(|e| e.to_string())?;
            temp.persist(&self.runs_path).map_err(|e| e.to_string())?;
            #[cfg(unix)]
            std::fs::File::open(&self.runs_dir)
                .and_then(|dir| dir.sync_all())
                .map_err(|e| e.to_string())?;
            Ok(())
        })();
        if let Err(error) = result {
            let message = format!(
                "The run history could not be saved reliably. Restart the host before starting more work: {error}"
            );
            *self
                .runs_error
                .lock()
                .unwrap_or_else(PoisonError::into_inner) = Some(message.clone());
            return Err(message);
        }
        Ok(())
    }

    pub fn list(&self) -> Vec<Automation> {
        self.jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn create(&self, mut job: Automation) -> Result<Automation, String> {
        self.ensure_jobs_available()?;
        validate(&job)?;
        job.schedule.validate()?;
        let mut live = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut jobs = live.clone();
        if jobs
            .iter()
            .any(|existing| existing.id == job.id && !job.id.is_empty())
        {
            return Err(format!("an automation with id {} already exists", job.id));
        }
        if is_auto_commit_name(&job.name)
            && let Some(idx) = jobs.iter().position(|existing| {
                existing.workspace_id == job.workspace_id && is_auto_commit_name(&existing.name)
            })
        {
            let id = jobs[idx].id.clone();
            let last_run_at_ms = jobs[idx].last_run_at_ms;
            let last_run_id = jobs[idx].last_run_id.clone();
            job.id = id;
            job.revision = jobs[idx].revision;
            job.last_run_at_ms = last_run_at_ms;
            job.last_run_id = last_run_id;
            if job.enabled {
                job.next_run_at_ms = job.schedule.next_run_ms(now_ms());
            } else {
                job.next_run_at_ms = None;
            }
            advance_revision(&mut job)?;
            jobs[idx] = job.clone();
            self.save(&jobs)?;
            *live = jobs;
            return Ok(job);
        }
        if job.id.is_empty() {
            job.id = format!("automation-{:032x}", rand::random::<u128>());
        }
        job.revision = 1;
        job.next_run_at_ms = if job.enabled {
            job.schedule.next_run_ms(now_ms())
        } else {
            None
        };
        job.last_run_at_ms = None;
        job.last_run_id = None;
        jobs.push(job.clone());
        self.save(&jobs)?;
        *live = jobs;
        Ok(job)
    }

    pub fn update(&self, job: Automation) -> Result<Automation, String> {
        self.put(job, None)
    }

    /// Checked replacement. A stale editor cannot overwrite a newer schedule
    /// or prompt. The live run already holds its own snapshot.
    pub fn edit(&self, job: Automation, expected_revision: u64) -> Result<Automation, String> {
        self.put(job, Some(expected_revision))
    }

    fn put(
        &self,
        mut job: Automation,
        expected_revision: Option<u64>,
    ) -> Result<Automation, String> {
        self.ensure_jobs_available()?;
        validate(&job)?;
        job.schedule.validate()?;
        let mut live = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut jobs = live.clone();
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
        if expected_revision.is_some_and(|expected| expected != current.revision) {
            return Err(
                "This job changed since you opened it. Compare the saved job before replacing it."
                    .into(),
            );
        }
        let last_run_at_ms = current.last_run_at_ms;
        let last_run_id = current.last_run_id.clone();
        job.revision = current.revision;
        job.last_run_at_ms = last_run_at_ms;
        job.last_run_id = last_run_id;

        if !job.enabled {
            job.next_run_at_ms = None;
        } else {
            job.next_run_at_ms = job.schedule.next_run_ms(now_ms());
        }
        advance_revision(&mut job)?;
        *current = job;
        let result = current.clone();
        self.save(&jobs)?;
        *live = jobs;
        Ok(result)
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<Automation, String> {
        self.ensure_jobs_available()?;
        let mut live = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut jobs = live.clone();
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
        advance_revision(job)?;
        let result = job.clone();
        self.save(&jobs)?;
        *live = jobs;
        Ok(result)
    }

    pub fn remove(&self, id: &str) -> Result<bool, String> {
        self.ensure_jobs_available()?;
        let mut live = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut jobs = live.clone();
        let old = jobs.len();
        jobs.retain(|job| job.id != id);
        let changed = old != jobs.len();
        if changed {
            self.save(&jobs)?;
            *live = jobs;
        }
        Ok(changed)
    }

    pub fn runs(&self) -> Vec<RunRecord> {
        self.runs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

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
        let _argv = agent_command_in(
            &snapshot.backend,
            &snapshot.prompt,
            snapshot.model.as_deref(),
            snapshot.effort.as_deref(),
            snapshot.budget_seconds,
            Some(&workspace.path),
        )?;
        let run_id = mint_run_id();
        let transcript_path = self.runs_dir.join(format!("{run_id}.txt"));
        let pending = Pending {
            interactive: false,
            job: snapshot.clone(),
            run_id: run_id.clone(),
            transcript_path,
            parent_run_id: parent_run_id.map(str::to_string),
        };
        self.push_run(RunRecord {
            id: run_id.clone(),
            job_id: snapshot.id.clone(),
            name: snapshot.name.clone(),
            backend: snapshot.backend.clone(),
            workspace_id: workspace.id.clone(),
            started_at_ms: now_ms(),
            ended_at_ms: None,
            exit_code: None,
            status: "starting".into(),
            transcript_path: pending.transcript_path.display().to_string(),
            pty_id: None,
            interactive: false,
            parent_run_id: pending.parent_run_id.clone(),
        })?;
        match self.spawn_pending(pending, workspace.id) {
            Ok((run, budget, writer)) => {
                let started = run.started_at_ms;
                let started_id = run.id.clone();
                let out =
                    self.persist_and_drain(run, budget, writer, |r| self.update_run(r), false)?;
                let _ = self.note_started(id, started, &started_id, false);
                Ok(out)
            }
            Err(e) => {
                self.finish_run(&run_id, None, "error");
                Err(e)
            }
        }
    }

    fn push_run(&self, run: RunRecord) -> Result<(), String> {
        let mut live = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        if live.iter().any(|existing| existing.id == run.id) {
            return Err(format!("a run with id {} already exists", run.id));
        }
        let mut runs = live.clone();
        runs.insert(0, run);
        let mut completed = 0;
        let mut evicted = Vec::new();
        runs.retain(|run| {
            if matches!(run.status.as_str(), "starting" | "running" | "queued") {
                return true;
            }
            completed += 1;
            if completed <= RUNS_KEPT {
                true
            } else {
                evicted.push(run.clone());
                false
            }
        });
        self.write_runs(&runs)?;
        let kept: HashSet<String> = runs.iter().map(|r| r.transcript_path.clone()).collect();
        *live = runs;
        drop(live);
        for old in &evicted {
            self.remove_run_files(old, &kept);
        }
        Ok(())
    }

    fn remove_run_files(&self, run: &RunRecord, kept: &HashSet<String>) {
        if matches!(run.status.as_str(), "running" | "queued") {
            return;
        }
        if kept.contains(&run.transcript_path) {
            return;
        }
        let raw = PathBuf::from(&run.transcript_path);
        if !raw.is_absolute() {
            return;
        }
        let Ok(root) = self.runs_dir.canonicalize() else {
            return;
        };
        let Some(parent) = raw.parent().and_then(|parent| parent.canonicalize().ok()) else {
            return;
        };
        if !parent.starts_with(&root) {
            return;
        }
        let _ = std::fs::remove_file(&raw);

        let readable = transcript::readable_path(&raw);
        if !readable.is_absolute() {
            return;
        }
        let contained = readable
            .parent()
            .and_then(|parent| parent.canonicalize().ok())
            .is_some_and(|resolved| resolved.starts_with(&root));
        if !contained {
            return;
        }
        let _ = std::fs::remove_file(readable);
    }

    /// The drain thread calls this when a run's process has exited.
    pub fn finish_run(&self, id: &str, exit_code: Option<i32>, status: &str) {
        let mut live = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut runs = live.clone();
        if let Some(run) = runs.iter_mut().find(|run| run.id == id) {
            run.exit_code = exit_code;
            run.status = status.to_string();
            run.ended_at_ms = Some(now_ms());
        }
        if self.write_runs(&runs).is_ok() {
            *live = runs;
        }
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
        let backend = if run.interactive {
            "sh".to_string()
        } else {
            run.backend.clone()
        };
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

        if (missing || (empty && !running))
            && let Some(text) = transcript::rematerialize(&raw, &backend, false)
        {
            return Ok(transcript::slice_reply(text.as_bytes(), offset));
        } else if !running
            && offset == 0
            && raw.is_file()
            && let Some(text) = transcript::rematerialize(&raw, &backend, true)
        {
            return Ok(transcript::slice_reply(text.as_bytes(), offset));
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
            if let Some(text) = transcript::rematerialize(&raw, &backend, true) {
                return Ok(transcript::slice_reply(text.as_bytes(), offset));
            }
            return Ok(("(No readable output)".into(), 0));
        }
        Ok(transcript::slice_reply(&bytes, offset))
    }

    /// Run a job that is not part of the stored list: the todo board's
    /// delegate path. Returns the run so the caller can link it to its card.
    /// Starts now when a slot is free, otherwise waits in the queue.
    pub fn run_adhoc(self: &Arc<Store>, job: Automation) -> Result<RunRecord, String> {
        self.run_task(job, mint_run_id(), false)
    }

    /// A task reserves its durable run ID before calling this. Interactive
    /// work opens immediately, as desktop terminals do, without a queue budget.
    pub(crate) fn run_task(
        self: &Arc<Store>,
        job: Automation,
        run_id: String,
        interactive: bool,
    ) -> Result<RunRecord, String> {
        self.ensure_runs_available()?;
        let workspace = crate::workspaces::folder(&job.workspace_id)?;
        with_local_model(&job.backend, job.model.as_deref(), |model| {
            if interactive {
                interactive_agent_command_in(
                    &job.backend,
                    &job.prompt,
                    model,
                    job.effort.as_deref(),
                    Some(&workspace.path),
                )
            } else {
                agent_command_in(
                    &job.backend,
                    &job.prompt,
                    model,
                    job.effort.as_deref(),
                    job.budget_seconds,
                    Some(&workspace.path),
                )
            }
        })?;
        let transcript_path = self.runs_dir.join(format!("{run_id}.txt"));
        let pending = Pending {
            interactive,
            job: job.clone(),
            run_id: run_id.clone(),
            transcript_path: transcript_path.clone(),
            parent_run_id: None,
        };
        let owns_slot = !interactive && self.try_take_slot();
        let queued = !interactive && !owns_slot;
        let run = RunRecord {
            id: run_id.clone(),
            job_id: job.id,
            name: job.name,
            backend: job.backend,
            workspace_id: workspace.id.clone(),
            started_at_ms: now_ms(),
            ended_at_ms: None,
            exit_code: None,
            status: if queued { "queued" } else { "starting" }.into(),
            transcript_path: transcript_path.display().to_string(),
            pty_id: None,
            parent_run_id: None,
            interactive,
        };

        if let Err(error) = self.push_run(run.clone()) {
            if owns_slot {
                self.release_slot();
            }
            return Err(error);
        }
        if queued {
            self.waiting
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push_back(pending);

            self.pump();
            return Ok(self.get_run(&run_id).unwrap_or(run));
        }
        let started =
            self.spawn_pending(pending, workspace.id)
                .and_then(|(run, budget, writer)| {
                    self.persist_and_drain(run, budget, writer, |r| self.update_run(r), owns_slot)
                });
        if let Err(error) = &started {
            if owns_slot {
                self.release_slot();
            }
            self.finish_run(
                &run_id,
                None,
                if self.is_killed(&run_id) {
                    "stopped"
                } else {
                    "error"
                },
            );
            let _ = std::fs::write(
                transcript::readable_path(&transcript_path),
                format!("Failed to start: {error}\n"),
            );
        }
        started
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
    ) -> Result<(RunRecord, u64, crate::workspace_writer::Guard), String> {
        self.ensure_runs_available()?;
        if self.is_killed(&pending.run_id) {
            return Err("stopped".into());
        }
        let workspace = crate::workspaces::folder(&pending.job.workspace_id)?;
        let mut writer = crate::workspace_writer::Guard::acquire(&workspace.path)
            .map_err(|error| error.to_string())?;
        let AgentRunCommand {
            argv,
            environment: local_environment,
        } = with_local_model(
            &pending.job.backend,
            pending.job.model.as_deref(),
            |model| {
                if pending.interactive {
                    interactive_agent_command_in(
                        &pending.job.backend,
                        &pending.job.prompt,
                        model,
                        pending.job.effort.as_deref(),
                        Some(&workspace.path),
                    )
                } else {
                    agent_command_in(
                        &pending.job.backend,
                        &pending.job.prompt,
                        model,
                        pending.job.effort.as_deref(),
                        pending.job.budget_seconds,
                        Some(&workspace.path),
                    )
                }
            },
        )?;
        writer.ensure_current().map_err(|error| error.to_string())?;
        let mut environment = crate::profiles::for_workspace_agent(
            &workspace.id,
            None,
            crate::chat::launcher_profile_id(&pending.job.backend),
        )?;
        let remove = crate::profiles::inherited_auth(&environment);
        environment.extend(local_environment);
        let info = writer
            .spawn_removing_env(
                &tokenstat_pty::Spawn {
                    command: crate::launcher::spawn_command(&argv[0]),
                    args: argv[1..].to_vec(),
                    cwd: workspace.path.clone(),
                    workspace_id: Some(workspace.id.clone()),
                    hidden: !pending.interactive,
                    rows: 24,
                    cols: 120,
                    no_color: false,
                    dark: None,
                    environment,
                },
                remove,
            )
            .map_err(|e| e.to_string())?;

        let run = RunRecord {
            interactive: pending.interactive,
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
        Ok((
            run,
            if pending.interactive {
                0
            } else {
                pending.job.budget_seconds
            },
            writer,
        ))
    }

    fn persist_and_drain(
        self: &Arc<Store>,
        run: RunRecord,
        budget: u64,
        writer: crate::workspace_writer::Guard,
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
        self.start_drain(&run, budget, writer, owns_slot);
        Ok(run)
    }

    fn start_drain(
        self: &Arc<Store>,
        run: &RunRecord,
        budget: u64,
        writer: crate::workspace_writer::Guard,
        owns_slot: bool,
    ) {
        let Some(pty_id) = run.pty_id.clone() else {
            return;
        };
        let transcript_path = PathBuf::from(&run.transcript_path);
        let run_id = run.id.clone();
        let backend = if run.interactive {
            "sh".to_string()
        } else {
            run.backend.clone()
        };
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
            drop(writer);
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
                Ok((run, budget, writer)) => {
                    if self
                        .persist_and_drain(run, budget, writer, |r| self.update_run(r), true)
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
        let mut live = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut runs = live.clone();
        if let Some(existing) = runs.iter_mut().find(|r| r.id == run.id) {
            if matches!(
                existing.status.as_str(),
                "ok" | "error" | "stopped" | "interrupted"
            ) {
                return Ok(());
            }
            *existing = run;
        } else {
            runs.insert(0, run);
        }
        self.write_runs(&runs)?;
        *live = runs;
        Ok(())
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
        let run = self.run_adhoc(snapshot.clone())?;

        let mut accepted = self
            .note_started(id, run.started_at_ms, &run.id, true)
            .ok()
            .flatten()
            .unwrap_or(snapshot);
        accepted.last_run_at_ms = Some(run.started_at_ms);
        accepted.last_run_id = Some(run.id);
        Ok(accepted)
    }

    fn note_started(
        &self,
        id: &str,
        started: i64,
        run_id: &str,
        advance_schedule: bool,
    ) -> Result<Option<Automation>, String> {
        let mut live = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut jobs = live.clone();
        let Some(job) = jobs.iter_mut().find(|job| job.id == id) else {
            return Ok(None);
        };
        job.last_run_at_ms = Some(started);
        job.last_run_id = Some(run_id.to_owned());
        if advance_schedule {
            job.next_run_at_ms = if job.enabled {
                job.schedule.next_run_ms(now_ms())
            } else {
                None
            };
        }
        let result = job.clone();
        self.save(&jobs)?;
        *live = jobs;
        Ok(Some(result))
    }

    /// Kill the pty behind a run, by its run id. The drain then records the
    /// run as stopped when the process is gone. A queued run is pulled off
    /// the wait list and marked stopped.
    pub fn kill_run(&self, run_id: &str) -> Result<(), String> {
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
        if matches!(status.as_str(), "starting" | "queued") {
            return Ok(());
        }
        if status != "running" {
            return Err("that run is not running".into());
        }
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
        let started = Instant::now();
        let budget = (budget_seconds != 0).then(|| Duration::from_secs(budget_seconds));
        let mut file = std::fs::File::create(path).ok();
        let readable_path = transcript::readable_path(path);

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
            if budget.is_some_and(|limit| started.elapsed() >= limit) {
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

    fn claim_due(&self, now: i64) -> Result<Vec<Automation>, String> {
        let mut live = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut jobs = live.clone();
        let mut due = Vec::new();
        for job in &mut jobs {
            if job.enabled && job.next_run_at_ms.is_some_and(|at| at <= now) {
                due.push(job.clone());
                job.next_run_at_ms = job.schedule.next_run_ms(now);
            }
        }
        if !due.is_empty() {
            self.save(&jobs)?;
            *live = jobs;
        }
        Ok(due)
    }

    pub fn run_due(self: &Arc<Store>) {
        let Ok(jobs) = self.claim_due(now_ms()) else {
            return;
        };
        for job in jobs {
            let id = job.id.clone();
            if let Ok(run) = self.run_adhoc(job) {
                let _ = self.note_started(&id, run.started_at_ms, &run.id, false);
            }
        }
    }
}

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

fn validate(job: &Automation) -> Result<(), String> {
    if job.name.trim().is_empty() {
        return Err("an automation needs a name".into());
    }
    if job.workspace_id.is_empty() {
        return Err("an automation needs a workspace".into());
    }

    Ok(())
}

/// Validate the complete task launch before its board claim is persisted.
pub(crate) fn validate_task_run(job: &Automation, interactive: bool) -> Result<(), String> {
    validate(job)?;
    let workspace = crate::workspaces::folder(&job.workspace_id)?;
    if interactive {
        interactive_agent_command_in(
            &job.backend,
            &job.prompt,
            job.model.as_deref(),
            job.effort.as_deref(),
            Some(&workspace.path),
        )?;
    } else {
        agent_command_in(
            &job.backend,
            &job.prompt,
            job.model.as_deref(),
            job.effort.as_deref(),
            job.budget_seconds,
            Some(&workspace.path),
        )?;
    }
    Ok(())
}

fn write_atomic(path: &Path, body: &str) -> Result<(), String> {
    tokenstat_sync::snapshot::write_private_atomically(path, body)
        .map_err(|error| error.to_string())
}

static RUN_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn mint_run_id() -> String {
    let sequence = RUN_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("run-{}-{sequence}", now_ms())
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

    #[test]
    fn every_agent_backend_is_told_how_to_keep_a_plan() {
        for spec in BACKENDS.iter().filter(|spec| spec.id != "sh") {
            assert!(
                crate::chat_plan::rule(spec.id)
                    .is_some_and(|rule| rule.contains(crate::chat_plan::FENCE)),
                "{} does not write the plan block",
                spec.id
            );
        }
    }

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
            revision: 0,
        }
    }

    #[test]
    fn failed_job_mutations_keep_memory_and_schedule_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("jobs.json");
        let store = Store::at(path.clone());
        let first = store
            .create(job("first", ScheduleSpec::default(), 60))
            .unwrap();
        let original_jobs = serde_json::to_value(store.list()).unwrap();
        let original_queue = serde_json::to_value(store.queue_config()).unwrap();
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        let mut edited = first.clone();
        edited.prompt = "must not apply".into();
        assert!(store.edit(edited, first.revision).is_err());
        assert!(store.set_enabled(&first.id, false).is_err());
        assert!(store.remove(&first.id).is_err());
        assert!(
            store
                .create(job("new", ScheduleSpec::default(), 60))
                .is_err()
        );
        assert!(
            store
                .set_queue_config(QueueConfig {
                    default_budget_seconds: 1,
                    max_concurrent: 7
                })
                .is_err()
        );
        assert!(
            store
                .note_started(&first.id, 123, "uncommitted", true)
                .is_err()
        );
        assert_eq!(serde_json::to_value(store.list()).unwrap(), original_jobs);
        assert_eq!(
            serde_json::to_value(store.queue_config()).unwrap(),
            original_queue
        );
    }

    #[test]
    fn concurrent_job_receipt_and_queue_writes_keep_every_saved_record() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("jobs.json");
        let store = Arc::new(Store::at(path.clone()));
        let handles: Vec<_> = (0..6)
            .map(|worker| {
                let store = store.clone();
                std::thread::spawn(move || {
                    for index in 0..8 {
                        if worker % 2 == 0 {
                            store.create(job("", ScheduleSpec::default(), 60)).unwrap();
                        } else {
                            store
                                .create_once(
                                    &format!("fixture-operation-{worker}-{index}"),
                                    job("", ScheduleSpec::default(), 60),
                                )
                                .unwrap();
                        }
                        store
                            .set_queue_config(QueueConfig {
                                default_budget_seconds: index,
                                max_concurrent: worker + 1,
                            })
                            .unwrap();
                    }
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        let current = store.list();
        assert_eq!(current.len(), 48);
        assert_eq!(
            current
                .iter()
                .map(|job| &job.id)
                .collect::<HashSet<_>>()
                .len(),
            48
        );
        let reopened = Store::load_at(path);
        assert_eq!(
            serde_json::to_value(reopened.list()).unwrap(),
            serde_json::to_value(current).unwrap()
        );
        assert_eq!(
            serde_json::to_value(reopened.queue_config()).unwrap(),
            serde_json::to_value(store.queue_config()).unwrap()
        );
        for worker in [1, 3, 5] {
            for index in 0..8 {
                assert!(
                    reopened
                        .creation_receipt(&format!("fixture-operation-{worker}-{index}"))
                        .unwrap()
                        .is_some()
                );
            }
        }
    }

    #[test]
    fn scheduler_claims_a_due_occurrence_once_and_only_after_persistence() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("jobs.json");
        let store = Arc::new(Store::at(path.clone()));
        let mut due = job("due", ScheduleSpec::default(), 60);
        due.next_run_at_ms = Some(100);
        store.seed(due.clone());
        std::fs::create_dir(&path).unwrap();
        assert!(store.claim_due(200).is_err());
        assert_eq!(store.list()[0].next_run_at_ms, Some(100));
        std::fs::remove_dir(&path).unwrap();
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let store = store.clone();
                std::thread::spawn(move || store.claim_due(200).unwrap().len())
            })
            .collect();
        assert_eq!(
            handles
                .into_iter()
                .map(|handle| handle.join().unwrap())
                .sum::<usize>(),
            1
        );
        assert_eq!(Store::load_at(path).list()[0].next_run_at_ms, None);
    }

    #[test]
    fn flag_shaped_prompts_models_and_resume_tokens_remain_opaque_values() {
        for (backend, prompt) in [
            ("claude", "--dangerously-skip-permissions"),
            ("grok", "bypassPermissions"),
            ("grok", "--permission-mode"),
            ("cursor", "--force"),
            ("codex", "--dangerously-bypass-approvals-and-sandbox"),
            ("muse", "--yolo"),
            ("opencode", "--auto"),
            ("opencode2", "--auto"),
            ("agy", "--dangerously-skip-permissions"),
        ] {
            let argv = chat_agent_command(
                backend,
                prompt,
                None,
                None,
                60,
                ChatLaunch {
                    resume: None,
                    bypass: false,
                    mode: "execute",
                    hook_helper: None,
                    system_append: None,
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap();
            let prompt_at = match backend {
                "claude" | "grok" => command_word_at(&argv, "-p").unwrap() + 1,
                "agy" => command_word_at(&argv, "--print").unwrap() + 1,
                _ => command_word_at(&argv, "--").unwrap() + 1,
            };
            assert_eq!(argv[prompt_at], prompt, "{backend}: {argv:?}");
        }
        let argv = chat_agent_command(
            "codex",
            "--dangerously-bypass-hook-trust",
            Some("exec"),
            None,
            60,
            ChatLaunch {
                resume: Some("--sandbox"),
                bypass: false,
                mode: "execute",
                hook_helper: Some(Path::new("helper")),
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(argv.windows(2).any(|pair| pair == ["--model", "exec"]));
        assert!(argv.windows(2).any(|pair| pair == ["resume", "--sandbox"]));
        assert_eq!(argv.last().unwrap(), "--dangerously-bypass-hook-trust");
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

    fn ny() -> jiff::tz::TimeZone {
        jiff::tz::TimeZone::get("America/New_York").unwrap()
    }

    #[test]
    fn a_daily_nine_stays_nine_across_spring_forward() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Daily,
            hour: 9,
            minute: 0,
            ..ScheduleSpec::default()
        };
        let from = 1_772_892_000_000;
        assert_eq!(s.next_run_ms_in(from, ny()), Some(1_772_974_800_000));
        let earlier = 1_772_888_400_000;
        assert_eq!(s.next_run_ms_in(earlier, ny()), Some(from));
        assert_ne!(
            s.next_run_ms_in(from, ny()),
            s.next_run_ms_in(from, jiff::tz::TimeZone::UTC),
            "the host zone owns the civil time, UTC does not"
        );
    }

    #[test]
    fn a_missing_civil_time_on_spring_forward_uses_compatible_offset() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Daily,
            hour: 2,
            minute: 30,
            ..ScheduleSpec::default()
        };
        let from = 1_772_949_600_000;
        let next = s.next_run_ms_in(from, ny()).unwrap();
        assert!(next > from);
        let zoned = jiff::Timestamp::from_millisecond(next)
            .unwrap()
            .to_zoned_datetime(ny());

        assert_eq!(zoned.date().to_string(), "2026-03-08");
        assert!(zoned.hour() >= 3);
    }

    #[test]
    fn a_folded_civil_time_on_fall_back_fires_once() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Daily,
            hour: 1,
            minute: 30,
            ..ScheduleSpec::default()
        };
        let from = 1_793_507_400_000;
        assert_eq!(s.next_run_ms_in(from, ny()), Some(1_793_511_000_000));
        let after_first = 1_793_511_000_000 + 1;
        assert_eq!(s.next_run_ms_in(after_first, ny()), Some(1_793_601_000_000));
    }

    #[test]
    fn a_weekly_monday_uses_the_named_zone() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Weekly,
            weekday: 0,
            hour: 9,
            minute: 0,
            ..ScheduleSpec::default()
        };
        let from = 1_789_315_200_000;
        assert_eq!(s.next_run_ms_in(from, ny()), Some(1_789_390_800_000));
    }

    #[test]
    fn an_interval_ignores_the_timezone() {
        let s = ScheduleSpec {
            kind: ScheduleKind::Interval,
            every_seconds: 120,
            ..ScheduleSpec::default()
        };
        assert_eq!(s.next_run_ms_in(1_000, ny()), Some(121_000));
        assert_eq!(
            s.next_run_ms_in(1_000, jiff::tz::TimeZone::UTC),
            Some(121_000)
        );
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
            "muse",
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

        let claude = agent_command("claude", "do it", None, None, DEFAULT_BUDGET_SECONDS).unwrap();
        assert!(claude.iter().any(|a| a == "--verbose"));
        assert!(claude.iter().any(|a| a == "--include-partial-messages"));
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
        let grok = backends(false)
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
    fn standing_rules_travel_beside_the_turn_not_inside_it() {
        let launch = |backend: &'static str| {
            chat_agent_command(
                backend,
                "Hey",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume: None,
                    bypass: true,
                    mode: "execute",
                    hook_helper: None,
                    system_append: Some("You explain Rust errors patiently."),
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap()
        };

        let claude = launch("claude");
        let flagged = claude
            .windows(2)
            .find(|pair| pair[0] == "--append-system-prompt")
            .map(|pair| pair[1].clone())
            .expect("claude takes standing rules on its own flag");
        assert_eq!(flagged, "You explain Rust errors patiently.");
        assert!(claude.iter().any(|arg| arg == "Hey"));

        let grok = launch("grok");
        assert!(
            grok.windows(2)
                .any(|pair| pair[0] == "--rules" && pair[1] == "You explain Rust errors patiently.")
        );

        let codex = launch("codex");
        let turn = codex.last().expect("codex puts the prompt last");
        assert!(turn.starts_with("<system-instructions>\nYou explain Rust errors patiently."));
        assert!(turn.ends_with("</system-instructions>\n\nHey"));
        assert!(!codex.iter().any(|arg| arg == "--append-system-prompt"));
    }

    #[test]
    fn cursor_keeps_force_only_beside_its_gate_plugin() {
        let plugin = std::path::PathBuf::from("/tmp/cursor-hook");
        let launch = |helper: Option<&'static str>, dir: Option<&Path>, mode: &'static str| {
            chat_agent_command(
                "cursor",
                "inspect this",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume: None,
                    bypass: false,
                    mode,
                    hook_helper: helper.map(Path::new),
                    system_append: None,
                    agy_customization_dir: None,
                    cursor_plugin_dir: dir,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap()
        };
        let has = |argv: &[String], flag: &str| argv.iter().any(|arg| arg == flag);

        let guarded = launch(Some("/tmp/tokenstat-hostd"), Some(&plugin), "execute");
        assert!(has(&guarded, "--force") && has(&guarded, "--trust"));
        let at = guarded
            .iter()
            .position(|arg| arg == "--plugin-dir")
            .expect("the gate plugin is loaded");
        assert_eq!(guarded[at + 1], plugin.display().to_string());
        let prompt_at = guarded.iter().position(|arg| arg == "--").unwrap();
        assert!(at < prompt_at, "flags go before the prompt separator");

        for ungated in [
            launch(None, None, "execute"),
            launch(Some("/tmp/tokenstat-hostd"), None, "execute"),
            launch(Some("/tmp/tokenstat-hostd"), Some(&plugin), "plan"),
        ] {
            assert!(!has(&ungated, "--force"), "{ungated:?}");
            assert!(!has(&ungated, "--plugin-dir"), "{ungated:?}");
        }
    }

    #[test]
    fn agy_keeps_its_own_gate_out_of_the_way_only_when_ours_is_installed() {
        let home = std::path::PathBuf::from("/tmp/agy-hook");
        let launch = |helper: Option<&'static str>, mode: &'static str| {
            chat_agent_command(
                "agy",
                "inspect this",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume: None,
                    bypass: false,
                    mode,
                    hook_helper: helper.map(Path::new),
                    system_append: None,
                    agy_customization_dir: Some(&home),
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap()
        };

        let guarded = launch(Some("/tmp/tokenstat-hostd"), "execute");
        assert!(
            guarded
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions"),
            "a guarded agy turn must not be auto-denied by agy's own headless rule"
        );
        assert!(
            guarded
                .windows(2)
                .any(|pair| pair[0] == "--add-dir" && pair[1] == home.display().to_string()),
            "the flag is only safe beside tokenstat's own hook"
        );

        let ungated = launch(None, "execute");
        assert!(
            !ungated
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions"),
            "without a hook there is no gate, so nothing may bypass agy's own"
        );

        let planning = launch(Some("/tmp/tokenstat-hostd"), "plan");
        assert!(
            !planning
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions"),
            "plan mode keeps agy's own restraint"
        );
    }

    #[test]
    fn grok_leaves_its_own_gate_open_only_when_ours_is_installed() {
        let launch = |helper: Option<&'static str>, mode: &'static str, bypass: bool| {
            chat_agent_command(
                "grok",
                "inspect this",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume: None,
                    bypass,
                    mode,
                    hook_helper: helper.map(Path::new),
                    system_append: None,
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap()
        };
        let mode_of = |argv: &[String]| {
            argv.windows(2)
                .find(|pair| pair[0] == "--permission-mode")
                .map(|pair| pair[1].clone())
                .expect("grok always carries a permission mode")
        };

        assert_eq!(
            mode_of(&launch(Some("/tmp/tokenstat-hostd"), "execute", false)),
            "bypassPermissions",
            "a guarded grok turn must not be cancelled by a prompt nobody can answer"
        );

        assert_eq!(mode_of(&launch(None, "execute", false)), "dontAsk");
        assert_eq!(mode_of(&launch(None, "plan", false)), "plan");
        assert!(
            !launch(None, "plan", false)
                .iter()
                .any(|arg| arg == "--always-approve"),
            "a plan turn with no gate must not auto-approve"
        );
        let planning = launch(Some("/tmp/tokenstat-hostd"), "plan", false);
        assert_eq!(
            mode_of(&planning),
            "plan",
            "plan mode keeps grok's edit gate"
        );
        assert!(
            planning.iter().any(|arg| arg == "--always-approve"),
            "a guarded plan turn must not cancel spawn_subagent: {planning:?}"
        );
        let bypassed_plan = launch(None, "plan", true);
        assert_eq!(mode_of(&bypassed_plan), "plan");
        assert!(
            bypassed_plan.iter().any(|arg| arg == "--always-approve"),
            "Bypass under plan still has to let non-edit tools run: {bypassed_plan:?}"
        );
    }

    #[test]
    fn a_claude_chat_cannot_reach_for_its_own_question_tool() {
        for (bypass, mode, resume) in [
            (false, "execute", None),
            (true, "execute", Some("s1")),
            (false, "plan", None),
        ] {
            let argv = chat_agent_command(
                "claude",
                "inspect this",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume,
                    bypass,
                    mode,
                    hook_helper: None,
                    system_append: Some("standing"),
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap();
            let at = argv
                .iter()
                .position(|arg| arg == "--disallowedTools")
                .unwrap();
            assert_eq!(argv[at + 1], "AskUserQuestion");

            assert!(argv[at + 2].starts_with('-'), "{argv:?}");
            assert!(at < argv.iter().position(|arg| arg == "-p").unwrap());
        }
        let codex = chat_agent_command(
            "codex",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(!codex.iter().any(|arg| arg == "--disallowedTools"));
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
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
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
                mode: "execute",
                hook_helper: Some(Path::new(
                    "/Applications/Tokenstat.app/Contents/Resources/tokenstat-hostd",
                )),
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
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
        assert!(settings.contains("PostToolUse"));
        assert!(settings.contains("hook claude post"));
        let codex = chat_agent_command(
            "codex",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            !codex
                .iter()
                .any(|arg| arg == "--dangerously-bypass-approvals-and-sandbox")
        );
        let muse = chat_agent_command(
            "muse",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            !muse.iter().any(|arg| arg == "--yolo"),
            "a non-bypass Muse chat must never inherit YOLO: {muse:?}"
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
                mode: "execute",
                hook_helper: Some(Path::new("/tmp/tokenstat-hostd")),
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
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
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            bypass
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions")
        );
        let agy_home = std::path::Path::new("/private/tmp/tokenstat-agy");
        let guarded_agy = chat_agent_command(
            "agy",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                mode: "execute",
                hook_helper: Some(Path::new("/tmp/tokenstat-hostd")),
                system_append: None,
                agy_customization_dir: Some(agy_home),
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            guarded_agy
                .windows(2)
                .any(|pair| pair == ["--add-dir", "/private/tmp/tokenstat-agy"])
        );
        let rules = vec!["Read".into(), "Bash(git status*)".into()];
        let grok = chat_agent_command(
            "grok",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &rules,
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--permission-mode", "dontAsk"])
        );
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--allow", "Bash(git status*)"])
        );
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--output-format", "streaming-json"]),
            "Standard grok must keep --output-format next to its value: {grok:?}"
        );
    }

    #[test]
    fn a_guarded_cursor_turn_keeps_neither_permission_flag() {
        let guarded = chat_agent_command(
            "cursor",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: false,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            !guarded
                .iter()
                .any(|arg| matches!(arg.as_str(), "--trust" | "--force")),
            "{guarded:?}"
        );
    }

    #[test]
    fn chat_bypass_retains_each_backends_unattended_permission_flag() {
        let launch = |backend: &str| {
            chat_agent_command(
                backend,
                "make the change",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume: Some("session-1"),
                    bypass: true,
                    mode: "execute",
                    hook_helper: None,
                    system_append: None,
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap()
        };
        for (backend, flag) in [
            ("claude", "--dangerously-skip-permissions"),
            ("codex", "--dangerously-bypass-approvals-and-sandbox"),
            ("muse", "--yolo"),
            ("cursor", "--trust"),
            ("cursor", "--force"),
            ("agy", "--dangerously-skip-permissions"),
            ("opencode", "--auto"),
            ("opencode2", "--auto"),
        ] {
            let argv = launch(backend);
            assert!(
                argv.iter().any(|arg| arg == flag),
                "{backend} Bypass lost {flag}: {argv:?}"
            );
        }
        let grok = launch("grok");
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--permission-mode", "bypassPermissions"]),
            "Grok Bypass must use bypassPermissions: {grok:?}"
        );
    }

    #[test]
    fn persona_drafts_never_inherit_automation_write_access() {
        for backend in [
            "claude",
            "codex",
            "grok",
            "cursor",
            "agy",
            "opencode",
            "opencode2",
        ] {
            let argv = persona_draft_command(backend, "Return one JSON object", 90).unwrap();
            for unsafe_flag in [
                "--dangerously-skip-permissions",
                "--dangerously-bypass-approvals-and-sandbox",
                "--trust",
                "--force",
                "--auto",
                "bypassPermissions",
                "--always-approve",
                "--yolo",
            ] {
                assert!(
                    !argv.iter().any(|argument| argument == unsafe_flag),
                    "{backend} draft retained {unsafe_flag}: {argv:?}"
                );
            }
        }

        let codex = persona_draft_command("codex", "draft", 90).unwrap();
        assert!(
            codex
                .windows(2)
                .any(|pair| pair == ["--sandbox", "read-only"])
        );
        let claude = persona_draft_command("claude", "draft", 90).unwrap();
        assert!(
            claude
                .windows(2)
                .any(|pair| pair == ["--permission-mode", "plan"])
        );
        let grok = persona_draft_command("grok", "draft", 90).unwrap();
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--permission-mode", "plan"])
        );
    }

    #[test]
    fn grok_resume_does_not_split_output_format() {
        let grok = chat_agent_command(
            "grok",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: Some("sess-1"),
                bypass: false,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--output-format", "streaming-json"]),
            "{grok:?}"
        );
        assert!(grok.windows(2).any(|pair| pair == ["--resume", "sess-1"]));
    }

    #[test]
    fn guarded_codex_execute_can_write_approved_workspace_files() {
        for resume in [None, Some("thread-1")] {
            for (mode, expected) in [("execute", "workspace-write"), ("plan", "read-only")] {
                let argv = chat_agent_command(
                    "codex",
                    "edit the requested file",
                    None,
                    None,
                    DEFAULT_BUDGET_SECONDS,
                    ChatLaunch {
                        resume,
                        bypass: false,
                        mode,
                        hook_helper: Some(Path::new("/tmp/tokenstat-hostd")),
                        system_append: None,
                        agy_customization_dir: None,
                        cursor_plugin_dir: None,
                        grok_allow_rules: &[],
                        attachments: &[],
                    },
                )
                .unwrap();
                assert!(
                    argv.windows(2).any(|pair| pair == ["--sandbox", expected]),
                    "{mode} must select its sandbox before starting a new or resumed thread: {argv:?}"
                );
                assert!(
                    !argv
                        .iter()
                        .any(|arg| arg == "--dangerously-bypass-approvals-and-sandbox")
                );
            }
        }
    }

    #[test]
    fn codex_resume_keeps_sandbox_on_exec_not_on_resume() {
        let codex = chat_agent_command(
            "codex",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: Some("thread-1"),
                bypass: false,
                mode: "plan",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        let exec = codex.iter().position(|arg| arg == "exec").unwrap();
        let resume = codex.iter().position(|arg| arg == "resume").unwrap();
        let sandbox = codex.iter().position(|arg| arg == "--sandbox").unwrap();
        assert!(exec < sandbox && sandbox < resume, "{codex:?}");
        assert_eq!(
            codex.get(sandbox + 1).map(String::as_str),
            Some("read-only")
        );
    }

    #[test]
    fn cursor_without_a_model_passes_auto() {
        let cursor = chat_agent_command(
            "cursor",
            "inspect this",
            None,
            None,
            DEFAULT_BUDGET_SECONDS,
            ChatLaunch {
                resume: None,
                bypass: true,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: &[],
            },
        )
        .unwrap();
        assert!(
            cursor.windows(2).any(|pair| pair == ["--model", "auto"]),
            "{cursor:?}"
        );
    }

    #[test]
    fn plan_mode_uses_native_flags() {
        let launch = |backend: &str| {
            chat_agent_command(
                backend,
                "inspect this",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume: None,
                    bypass: false,
                    mode: "plan",
                    hook_helper: None,
                    system_append: None,
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap()
        };
        let claude = launch("claude");
        assert!(
            claude
                .windows(2)
                .any(|pair| pair == ["--permission-mode", "plan"]),
            "{claude:?}"
        );
        let grok = launch("grok");
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--permission-mode", "plan"]),
            "{grok:?}"
        );
        assert!(
            grok.windows(2)
                .any(|pair| pair == ["--output-format", "streaming-json"]),
            "{grok:?}"
        );
        let cursor = launch("cursor");
        assert!(cursor.iter().any(|arg| arg == "--plan"), "{cursor:?}");
        let codex = launch("codex");
        assert!(
            codex
                .windows(2)
                .any(|pair| pair == ["--sandbox", "read-only"]),
            "{codex:?}"
        );
        assert!(
            codex.iter().any(|arg| arg.contains("Plan mode:")),
            "{codex:?}"
        );
        let opencode = launch("opencode");
        assert!(!opencode.iter().any(|arg| arg == "--auto"), "{opencode:?}");
        assert!(
            opencode.iter().any(|arg| arg.contains("Plan mode:")),
            "{opencode:?}"
        );
        let agy = launch("agy");
        assert!(
            agy.windows(2).any(|pair| pair == ["--mode", "plan"]),
            "{agy:?}"
        );
    }

    #[test]
    fn plan_mode_overrides_bypass_flags() {
        for backend in [
            "claude",
            "codex",
            "muse",
            "cursor",
            "agy",
            "opencode",
            "opencode2",
        ] {
            let argv = chat_agent_command(
                backend,
                "inspect this",
                None,
                None,
                DEFAULT_BUDGET_SECONDS,
                ChatLaunch {
                    resume: None,
                    bypass: true,
                    mode: "plan",
                    hook_helper: None,
                    system_append: None,
                    agy_customization_dir: None,
                    cursor_plugin_dir: None,
                    grok_allow_rules: &[],
                    attachments: &[],
                },
            )
            .unwrap();
            if matches!(backend, "opencode" | "opencode2") {
                assert!(argv.windows(2).any(|pair| pair == ["--agent", "plan"]));
            }
            assert!(
                !argv.iter().any(|arg| matches!(
                    arg.as_str(),
                    "--dangerously-skip-permissions"
                        | "--dangerously-bypass-approvals-and-sandbox"
                        | "--yolo"
                        | "--trust"
                        | "--auto"
                )),
                "{backend}: {argv:?}"
            );
        }
    }

    #[test]
    fn chat_uses_native_image_flags_when_a_backend_has_them() {
        let temp = tempfile::tempdir().unwrap();
        let attachment = temp.path().join("diagram.png");
        std::fs::write(&attachment, b"\x89PNG\r\n\x1a\n").unwrap();
        let codex = chat_agent_command(
            "codex",
            "look",
            None,
            None,
            0,
            ChatLaunch {
                resume: None,
                bypass: false,
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: std::slice::from_ref(&attachment),
            },
        )
        .unwrap();
        assert!(
            codex
                .windows(2)
                .any(|pair| pair == ["-i", attachment.to_str().unwrap()])
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
                mode: "execute",
                hook_helper: None,
                system_append: None,
                agy_customization_dir: None,
                cursor_plugin_dir: None,
                grok_allow_rules: &[],
                attachments: std::slice::from_ref(&attachment),
            },
        )
        .unwrap();
        assert!(
            opencode
                .windows(2)
                .any(|pair| pair == ["-f", attachment.to_str().unwrap()])
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

        let codex = agent_command(
            "codex",
            "do it",
            Some("gpt-5.6-luna"),
            Some("low"),
            DEFAULT_BUDGET_SECONDS,
        )
        .unwrap();
        let at_model = codex.iter().position(|a| a == "--model").unwrap();
        assert_eq!(codex[at_model + 1], "gpt-5.6-luna");
        let at_effort = codex.iter().position(|a| a == "-c").unwrap();
        assert_eq!(codex[at_effort + 1], "model_reasoning_effort=low");

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

        for backend in ["opencode", "opencode2"] {
            let argv =
                interactive_agent_command(backend, "do it", Some("opencode/foo"), Some("high"))
                    .unwrap();
            assert_eq!(argv[0], backend);
            assert!(!argv.iter().any(|arg| arg == "--format"));
            if argv[1] == "run" {
                assert!(argv.iter().any(|arg| arg == "--auto"));
                assert!(argv.iter().any(|arg| arg == "-i"));
                assert!(
                    argv.windows(2)
                        .any(|pair| pair == ["--model", "opencode/foo"])
                );
                assert!(argv.windows(2).any(|pair| pair == ["--variant", "high"]));
                assert_eq!(argv.last().unwrap(), "do it");
            } else {
                assert_eq!(argv[1], "mini");
                assert!(!argv.iter().any(|arg| arg == "--auto"));
                assert!(
                    argv.windows(2)
                        .any(|pair| pair == ["--model", "opencode/foo"])
                );
                assert_eq!(&argv[argv.len() - 2..], ["--prompt", "do it"]);
            }
        }

        assert!(interactive_agent_command("nope", "do it", None, None).is_err());
        assert!(interactive_agent_command("claude", "   ", None, None).is_err());
    }

    #[test]
    fn opencode_new_and_resumed_runs_keep_options_after_run_and_preserve_the_prompt() {
        const PROMPT: &str = "run --variant max --model other/model -- -s prompt";
        for backend in ["opencode", "opencode2"] {
            for resume in [None, Some("ses_012345abcdef0123456789abcd")] {
                let argv = chat_agent_command(
                    backend,
                    PROMPT,
                    Some("opencode/beam-free#max"),
                    None,
                    0,
                    ChatLaunch {
                        resume,
                        bypass: true,
                        mode: "execute",
                        hook_helper: None,
                        system_append: None,
                        agy_customization_dir: None,
                        cursor_plugin_dir: None,
                        grok_allow_rules: &[],
                        attachments: &[],
                    },
                )
                .unwrap();
                assert_eq!(argv[0], backend);
                assert_eq!(argv[1], "run");
                assert!(
                    argv.windows(2)
                        .any(|pair| pair == ["--model", "opencode/beam-free#max"])
                );
                assert!(!argv.iter().any(|arg| arg == "--variant"));
                assert_eq!(&argv[argv.len() - 2..], ["--", PROMPT]);
                if let Some(id) = resume {
                    assert_eq!(&argv[2..4], ["-s", id]);
                }
            }
        }
    }

    #[test]
    fn backends_include_opencode2() {
        let ids: Vec<String> = backends(false)
            .into_iter()
            .filter_map(|v| v.get("id")?.as_str().map(str::to_string))
            .collect();
        assert!(ids.contains(&"opencode".into()));
        assert!(ids.contains(&"opencode2".into()));
    }

    #[test]
    fn muse_fallback_includes_wonder_and_all_confirmed_spark_variants() {
        assert_eq!(
            crate::agent_models::fallback_for("muse"),
            &[
                "muse-wonder-1.0",
                "muse-spark-1.3",
                "muse-spark-1.3-contributor",
                "muse-spark-1.2",
                "muse-spark-1.2-contributor",
            ]
        );
    }

    #[test]
    fn claude_advertises_the_full_effort_ladder() {
        let claude = backends(false)
            .into_iter()
            .find(|v| v.get("id").and_then(|id| id.as_str()) == Some("claude"))
            .expect("claude backend is advertised");
        let efforts: Vec<String> = claude
            .get("efforts")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect();
        assert_eq!(efforts, ["low", "medium", "high", "xhigh", "max"]);
    }

    fn sh_workspace(dir: &Path) -> String {
        let mut registry = crate::workspaces::write();
        registry.add(dir, now_ms()).unwrap().id
    }

    fn test_shell_command(unix: &str, windows: &str) -> (String, Vec<String>) {
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
            interactive: false,
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
        store.drain(&pty_id, &transcript_path, u64::MAX, run_id, "sh", true);

        let record = store
            .runs()
            .iter()
            .find(|r| r.id == run_id)
            .unwrap()
            .clone();
        let (text, _) = store.transcript(run_id, 0).unwrap();
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
                interactive: false,
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
    fn unreadable_run_history_is_never_replaced_by_a_new_launch() {
        let dir = temp_dir("unreadable-runs");
        std::fs::create_dir_all(dir.join("runs")).unwrap();
        let runs_path = dir.join("runs").join("runs.json");
        std::fs::write(&runs_path, b"not valid json").unwrap();
        let store = Store::at(dir.join("jobs.json"));
        let error = store
            .push_run(RunRecord {
                interactive: false,
                id: "must-not-start".into(),
                job_id: "j".into(),
                name: "protected".into(),
                backend: "sh".into(),
                workspace_id: "w".into(),
                started_at_ms: now_ms(),
                ended_at_ms: None,
                exit_code: None,
                status: "starting".into(),
                transcript_path: dir.join("run.txt").display().to_string(),
                pty_id: None,
                parent_run_id: None,
            })
            .unwrap_err();
        assert!(error.contains("could not be read"), "{error}");
        assert_eq!(std::fs::read(&runs_path).unwrap(), b"not valid json");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn retention_never_evicts_an_active_run() {
        let dir = temp_dir("active-retention");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::at(dir.join("jobs.json"));
        let record = |id: String, status: &str| RunRecord {
            interactive: false,
            id,
            job_id: "j".into(),
            name: "retained".into(),
            backend: "sh".into(),
            workspace_id: "w".into(),
            started_at_ms: now_ms(),
            ended_at_ms: (status == "ok").then(now_ms),
            exit_code: (status == "ok").then_some(0),
            status: status.into(),
            transcript_path: dir.join("run.txt").display().to_string(),
            pty_id: None,
            parent_run_id: None,
        };
        store.push_run(record("active".into(), "running")).unwrap();
        for index in 0..=RUNS_KEPT {
            store
                .push_run(record(format!("done-{index}"), "ok"))
                .unwrap();
        }
        let runs = store.runs();
        assert!(runs.iter().any(|run| run.id == "active"));
        assert_eq!(
            runs.iter().filter(|run| run.status == "ok").count(),
            RUNS_KEPT
        );
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
            interactive: false,
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
                interactive: false,
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
                interactive: false,
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
                interactive: false,
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
        assert!(
            !body.contains("timezone"),
            "the scheduler zone is this process, not a saved field"
        );
        let parsed: QueueConfig = serde_json::from_str(r#"{"defaultBudgetSeconds":0}"#).unwrap();
        assert_eq!(parsed.max_concurrent, DEFAULT_MAX_CONCURRENT);
        let status = store.queue_status();
        assert_eq!(status.default_budget_seconds, 0);
        assert_eq!(status.max_concurrent, 4);
        assert!(!status.timezone.is_empty());
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
        let first_folder = dir.join("first");
        std::fs::create_dir_all(&first_folder).unwrap();
        let workspace_id = sh_workspace(&first_folder);
        let make = |id: &str| Automation {
            id: id.into(),
            name: id.into(),
            backend: "sh".into(),
            model: None,
            effort: None,
            workspace_id: workspace_id.clone(),
            prompt: if cfg!(windows) {
                "ping -n 9 127.0.0.1 > nul"
            } else {
                "sleep 8"
            }
            .into(),
            schedule: ScheduleSpec::default(),
            budget_seconds: 15,
            enabled: false,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
            revision: 0,
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
    fn another_operation_in_the_checkout_does_not_block_an_automation() {
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().join("workspace");
        std::fs::create_dir(&folder).unwrap();
        let store = Arc::new(Store::at(dir.path().join("jobs.json")));
        let workspace = sh_workspace(&folder);
        let mut request = job("writer-fixture", ScheduleSpec::default(), 5);
        request.backend = "sh".into();
        request.workspace_id = workspace;
        request.enabled = false;
        request.prompt = "echo fixture > ran.txt".into();
        let held = tokenstat_workspace::writer::Lease::acquire(&folder).unwrap();
        let run = store.run_adhoc(request).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while store.get_run(&run.id).unwrap().status == "running" {
            assert!(Instant::now() < deadline, "owned fixture did not finish");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(folder.join("ran.txt").exists());
        assert_eq!(store.get_run(&run.id).unwrap().status, "ok");
        held.ensure_current().unwrap();
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
            prompt: if cfg!(windows) {
                "ping -n 9 127.0.0.1 > nul"
            } else {
                "sleep 8"
            }
            .into(),
            schedule: ScheduleSpec::default(),
            budget_seconds: 15,
            enabled: false,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
            revision: 0,
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
                interactive: false,
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
                interactive: false,
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
            revision: 0,
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
                revision: 0,
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
                revision: 0,
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

    #[test]
    fn a_stale_edit_is_refused_and_legacy_update_still_advances_revision() {
        let dir = temp_dir("edit-revision");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::at(dir.join("jobs.json"));
        let created = store
            .create(job("daily", ScheduleSpec::default(), 60))
            .unwrap();
        assert_eq!(created.revision, 1);
        let mut next = created.clone();
        next.prompt = "first save".into();
        let saved = store.edit(next.clone(), created.revision).unwrap();
        assert_eq!(saved.revision, 2);
        assert_eq!(saved.prompt, "first save");
        next.prompt = "stale save".into();
        assert!(store.edit(next, created.revision).is_err());
        assert_eq!(store.list()[0].prompt, "first save");
        let mut legacy = saved.clone();
        legacy.prompt = "legacy overwrite".into();
        let updated = store.update(legacy).unwrap();
        assert_eq!(updated.revision, 3);
        assert!(store.edit(saved, 2).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn editing_a_live_job_does_not_rewrite_the_running_record() {
        let dir = temp_dir("edit-live");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        let workspace_id = sh_workspace(&dir);
        let created = store
            .create(Automation {
                id: "live".into(),
                name: "Original".into(),
                backend: "sh".into(),
                model: None,
                effort: None,
                workspace_id,
                prompt: if cfg!(windows) {
                    "ping -n 3 127.0.0.1 >nul".into()
                } else {
                    "sleep 1".into()
                },
                schedule: ScheduleSpec::default(),
                budget_seconds: 15,
                enabled: false,
                last_run_at_ms: None,
                next_run_at_ms: None,
                last_run_id: None,
                revision: 0,
            })
            .unwrap();
        let started = store.run_once(&created.id, "fixture-live-run-op").unwrap();
        assert_eq!(started.run.as_ref().unwrap().name, "Original");
        let mut renamed = created.clone();
        renamed.name = "Edited".into();
        renamed.prompt = "printf EDITED".into();
        let saved = store.edit(renamed, created.revision).unwrap();
        assert_eq!(saved.name, "Edited");
        let run = store.get_run(&started.run_id).unwrap();
        assert_eq!(run.name, "Original");
        assert!(
            matches!(
                run.status.as_str(),
                "running" | "starting" | "queued" | "ok"
            ),
            "live run status {}",
            run.status
        );
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let row = store.get_run(&started.run_id).unwrap();
            if row.status != "running" && row.status != "queued" && row.status != "starting" {
                break;
            }
            assert!(Instant::now() < deadline, "live run still {}", row.status);
            std::thread::sleep(Duration::from_millis(40));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn run_once_retries_the_same_run() {
        let dir = temp_dir("run-once");
        std::fs::create_dir_all(&dir).unwrap();
        let store = Arc::new(Store::at(dir.join("jobs.json")));
        let workspace_id = sh_workspace(&dir);
        let created = store
            .create(Automation {
                id: "once".into(),
                name: "Once".into(),
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
                revision: 0,
            })
            .unwrap();
        let first = store.run_once(&created.id, "fixture-run-once-op").unwrap();
        let again = store.run_once(&created.id, "fixture-run-once-op").unwrap();
        assert_eq!(first.run_id, again.run_id);
        assert_eq!(store.runs().len(), 1);
        assert!(store.run_once("other", "fixture-run-once-op").is_err());
        let receipt = store.run_receipt("fixture-run-once-op").unwrap().unwrap();
        assert_eq!(receipt.run_id, first.run_id);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
