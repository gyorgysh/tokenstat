//! Full-screen interactive client.
//!
//! Takes over the terminal (alternate screen, raw mode) the way agent CLIs do.
//! Tabs switch reports, Summary opens with headline stats already drawn, and
//! the command field filters slash-command help as you type. On open, if the
//! archive has not been scanned in the last ten minutes, a scan runs before
//! the first interactive frame settles. Logic stays in `tokenstat-core`. This
//! module is layout and input only.
//!
//! Split along the loop it runs: [`app`] loads and holds state, [`events`]
//! turns key presses into state changes, [`draw`] lays out the frame, and
//! [`panels`] renders each tab's body into lines. [`commands`] is the slash
//! command table. This file keeps the shared types those four agree on.

mod app;
mod commands;
mod draw;
mod events;
mod panels;

use commands::*;
use draw::*;
use events::*;
use panels::*;

use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result};
use crossterm::event::{self};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use jiff::tz::TimeZone;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::style::Color;
use ratatui::text::Line;
use ratatui::widgets::BorderType;
use tokenstat_core::{Bucket, PriceTable, Query, Reconciliation, Totals, UsageBlock};

use crate::ui::{self, ACCENT_RGB, SECONDARY_RGB};

// macOS Terminal's DarkGray is almost black on its default dark-blue profile.
// Normal gray keeps secondary labels readable without competing with data.
const MUTED: Color = Color::Gray;
const SELECTED: Color = Color::White;

/// Deep violet used for panel borders: present, but never competing with data.
const BORDER_RGB: (u8, u8, u8) = (0x3D, 0x2A, 0x55);

/// A brand colour as a ratatui colour, degraded to what the terminal supports.
///
/// ratatui will happily emit a truecolor escape to a terminal that cannot show
/// one, so the same resolution the one-shot renderer does has to happen here.
fn brand(rgb: (u8, u8, u8)) -> Color {
    let (r, g, b) = rgb;
    match ui::rgb(r, g, b) {
        anstyle::Color::Rgb(c) => Color::Rgb(c.0, c.1, c.2),
        anstyle::Color::Ansi256(c) => Color::Indexed(c.0),
        anstyle::Color::Ansi(c) => ansi_to_ratatui(c),
    }
}

fn ansi_to_ratatui(c: anstyle::AnsiColor) -> Color {
    use anstyle::AnsiColor as A;
    match c {
        A::Black => Color::Black,
        A::Red => Color::Red,
        A::Green => Color::Green,
        A::Yellow => Color::Yellow,
        A::Blue => Color::Blue,
        A::Magenta => Color::Magenta,
        A::Cyan => Color::Cyan,
        A::White => Color::Gray,
        A::BrightBlack => Color::DarkGray,
        A::BrightRed => Color::LightRed,
        A::BrightGreen => Color::LightGreen,
        A::BrightYellow => Color::LightYellow,
        A::BrightBlue => Color::LightBlue,
        A::BrightMagenta => Color::LightMagenta,
        A::BrightCyan => Color::LightCyan,
        A::BrightWhite => Color::White,
    }
}

fn accent() -> Color {
    brand(ACCENT_RGB)
}

fn secondary() -> Color {
    brand(SECONDARY_RGB)
}

fn border() -> Color {
    brand(BORDER_RGB)
}

/// Rounded where the terminal can draw it, square where it cannot.
fn border_type() -> BorderType {
    if ui::caps().unicode {
        BorderType::Rounded
    } else {
        BorderType::Plain
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Summary,
    Daily,
    Weekly,
    Monthly,
    Models,
    Projects,
    Sessions,
    Blocks,
    Doctor,
}

impl Tab {
    const ALL: [Tab; 9] = [
        Tab::Summary,
        Tab::Daily,
        Tab::Weekly,
        Tab::Monthly,
        Tab::Models,
        Tab::Projects,
        Tab::Sessions,
        Tab::Blocks,
        Tab::Doctor,
    ];

    fn title(self) -> &'static str {
        match self {
            Tab::Summary => "Summary",
            Tab::Daily => "Daily",
            Tab::Weekly => "Weekly",
            Tab::Monthly => "Monthly",
            Tab::Models => "Models",
            Tab::Projects => "Projects",
            Tab::Sessions => "Sessions",
            Tab::Blocks => "Blocks",
            Tab::Doctor => "Doctor",
        }
    }

    fn index(self) -> usize {
        Self::ALL.iter().position(|t| *t == self).unwrap_or(0)
    }

    fn from_index(i: usize) -> Tab {
        Self::ALL[i % Self::ALL.len()]
    }

    fn next(self) -> Tab {
        Self::from_index(self.index() + 1)
    }

    fn prev(self) -> Tab {
        let i = self.index();
        Self::from_index(if i == 0 { Self::ALL.len() - 1 } else { i - 1 })
    }

    fn is_chrono(self) -> bool {
        matches!(self, Tab::Daily | Tab::Weekly | Tab::Monthly)
    }
}

/// Modal flow for `/login` (and `/setup`) inside the interactive client.
enum Wizard {
    /// Pick API host before device login.
    LoginHost { selected: usize },
    /// After a successful login: offer sync or done.
    AfterLogin {
        handle: String,
        host: String,
        selected: usize,
    },
    /// Getting-started: scan → login → sync.
    Setup { step: SetupStep, selected: usize },
}

/// A read-only report window (heatmap, wrapped, budget) drawn over the current
/// tab. The tab bar has no room for these, so they open as a popup and close
/// with Esc. Contents are computed once at open; arrows scroll.
struct Detail {
    lines: Vec<Line<'static>>,
    /// Preferred popup width, clamped to the frame at draw time.
    width: u16,
    scroll: u16,
}

/// What kind of report a [`Detail`] window shows.
enum DetailKind {
    Heatmap,
    Wrapped { year: i32 },
    Budget,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SetupStep {
    Welcome,
    ScanOffer,
    ScheduleOffer,
    LoginOffer,
}

const LOGIN_HOSTS: &[(&str, &str, Option<&str>)] = &[
    ("tokenstat.ai (prod)", "Default public host", Some("prod")),
    (
        "Use saved / env host",
        "TOKENSTAT_API_BASE or config sync.host",
        None,
    ),
];

const AFTER_LOGIN_ACTIONS: &[(&str, &str)] = &[
    ("Sync now", "Upload sealed aggregates to this host"),
    ("Done", "Stay in the client; sync later with /sync"),
];

const SETUP_WELCOME: &[(&str, &str)] = &[
    (
        "Continue",
        "Scan local logs, install an hourly schedule, then link tokenstat.ai",
    ),
    ("Skip", "Close the wizard"),
];

struct App {
    db_path: PathBuf,
    tz: TimeZone,
    tab: Tab,
    input: String,
    cursor: usize,
    /// Index into the current filtered suggestion list.
    suggest_idx: usize,
    scroll: u16,
    status: String,
    should_quit: bool,
    empty: bool,
    totals: Totals,
    /// Days a vendor recorded work for that the archive cannot measure. Counted
    /// into "Active days" and drawn on every grid: the day happened, only its
    /// tokens are unknown.
    days_unmeasured: Vec<String>,
    models: Vec<Bucket>,
    days: Vec<Bucket>,
    /// `(YYYY-MM-DD, microdollars)` for the heatmap. The grid ramps on spend,
    /// so it needs the day x model split that `days` has already flattened.
    day_cost: Vec<(String, u64)>,
    weeks: Vec<Bucket>,
    months: Vec<Bucket>,
    projects: Vec<Bucket>,
    sessions: Vec<Bucket>,
    blocks: Vec<UsageBlock>,
    /// Active report filter (model / project / date window).
    filter: Query,
    /// Date tabs default to newest first so recent days are on screen without
    /// scrolling. One-shot `tokenstat daily` stays oldest→newest so the
    /// response ends on today.
    chrono_newest_first: bool,
    peak_hour: Option<u8>,
    confidence: Vec<(String, u64)>,
    last_scan: Option<String>,
    reconciliation: Option<Reconciliation>,
    /// Previous slash commands for ↑/↓ recall when the palette is closed.
    history: Vec<String>,
    history_idx: Option<usize>,
    /// Active modal wizard, if any.
    wizard: Option<Wizard>,
    /// Open report window (heatmap / wrapped / budget), if any.
    detail: Option<Detail>,
    /// Host flag to pass to device login after leaving the alternate screen.
    pending_login_host: Option<Option<String>>,
    /// After login succeeds, run a sync against this host.
    pending_sync_host: Option<String>,
    /// Summary tab: show every model row instead of the top preview.
    summary_models_expanded: bool,
    /// Cached sync hint for the status bar (offline, from local config).
    sync_hint: Option<String>,
    /// Result channel for a `/sync` running on a worker thread. The UI never
    /// blocks on the network, so a dead link cannot freeze the client.
    pending_sync: Option<std::sync::mpsc::Receiver<Result<tokenstat_sync::SyncResult, String>>>,
    /// Loaded once, shared by every frame. Reading the price book and the
    /// catalog from disk on every draw is the single biggest per-frame cost.
    prices: PriceTable,
    /// Set when anything visible changed. The client repaints only when this is
    /// set or the clock ticked over a minute, never on a fixed interval.
    dirty: bool,
}

/// How many model rows the Summary tab shows before asking for expand.
const SUMMARY_MODEL_PREVIEW: usize = 10;

/// Rescan when opening the interactive client if the archive is this old.
///
/// People open `tokenstat` to see current usage, not to remember a separate
/// `scan` step. Ten minutes matches the Patron sync floor: denser than the
/// free/supporter intervals, short enough that a coding session still refreshes
/// on the next open.
const AUTO_SCAN_MAX_AGE: Duration = Duration::from_secs(10 * 60);

/// Enter alternate screen, run until quit, then restore the terminal.
///
/// Mouse capture is intentionally off. Capturing the mouse leaves some
/// embedded terminals (notably Cursor's) unable to deliver keys, so the UI
/// looks frozen until the shell SIGKILLs the process (`zsh: killed`).
pub fn run(db_path: &Path, tz: &TimeZone) -> Result<()> {
    enable_raw_mode().context("enabling raw mode")?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen).context("entering alternate screen")?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend).context("creating terminal")?;

    // Always leave the user's terminal usable, even on panic or early error.
    let _guard = TerminalGuard;
    let panic_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_terminal();
        panic_hook(info);
    }));

    let result = (|| {
        let mut app = App::load(db_path, tz)?;
        // Fresh numbers on open: if nobody has scanned for a while (or ever),
        // do it before the first interactive frame settles. Draw once first so
        // a long scan shows "Updating archive…" instead of a blank screen.
        if archive_needs_scan(app.last_scan.as_deref(), AUTO_SCAN_MAX_AGE) {
            app.status = "Updating archive…".into();
            terminal.draw(|f| draw(f, &mut app))?;
            if let Err(e) = app.run_scan(false) {
                app.status = format!("Auto-scan failed: {e}");
            }
        }
        if app.empty && app.wizard.is_none() && !filter_active(&app.filter) {
            app.wizard = Some(Wizard::Setup {
                step: SetupStep::Welcome,
                selected: 0,
            });
            app.status = "Archive empty. Continue setup, or Esc to browse.".into();
        }
        let mut last_minute = epoch_minutes();
        loop {
            // Idle is the common case, and repainting the whole frame on a
            // timer burns CPU for no visible change. Draw only when a key
            // press changed something, or the wall clock ticked over a minute
            // (Blocks and Doctor render minute-granular ages).
            let now_minute = epoch_minutes();
            if app.dirty || now_minute != last_minute {
                terminal.draw(|f| draw(f, &mut app))?;
                last_minute = now_minute;
                app.dirty = false;
            }
            if event::poll(Duration::from_millis(200))? {
                app.dirty = true;
                handle_event(&mut app, event::read()?)?;
            }
            if let Some(host) = app.pending_login_host.take() {
                run_login_outside_tui(&mut terminal, &mut app, host.as_deref())?;
                app.dirty = true;
            }
            if let Some(host) = app.pending_sync_host.take() {
                start_sync(&mut app, Some(host.as_str()));
            }
            poll_sync_result(&mut app);
            if app.should_quit {
                break;
            }
        }
        Ok(())
    })();

    drop(_guard);
    result
}

/// True when `last_scan_ms` is missing or older than `max_age`.
fn archive_needs_scan(last_scan_ms: Option<&str>, max_age: Duration) -> bool {
    let Some(raw) = last_scan_ms else {
        return true;
    };
    let Ok(ms) = raw.parse::<i64>() else {
        return true;
    };
    let age_ms = (jiff::Timestamp::now().as_millisecond() - ms).max(0) as u64;
    age_ms >= max_age.as_millis() as u64
}

/// Restores cooked mode and the primary screen. Idempotent enough for Drop and
/// the panic hook to both call it.
fn restore_terminal() {
    let _ = disable_raw_mode();
    let mut stdout = io::stdout();
    let _ = execute!(stdout, LeaveAlternateScreen, crossterm::cursor::Show);
}

struct TerminalGuard;

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        restore_terminal();
    }
}
fn rollup_months(days: &[Bucket]) -> Vec<Bucket> {
    let mut months: Vec<Bucket> = Vec::new();
    for d in days {
        let key = d.key.get(..7).unwrap_or(&d.key).to_string();
        match months.last_mut() {
            Some(m) if m.key == key => {
                m.counters.accumulate(&d.counters);
                m.events += d.events;
            }
            _ => months.push(Bucket {
                key,
                counters: d.counters,
                events: d.events,
                sessions: 0,
            }),
        }
    }
    months
}

fn split_cmd(raw: &str) -> (&str, Vec<&str>) {
    let trimmed = raw.trim().trim_start_matches('/');
    let mut parts = trimmed.split_whitespace();
    let cmd = parts.next().unwrap_or("");
    (cmd, parts.collect())
}

fn filter_active(q: &Query) -> bool {
    q.since.is_some() || q.until.is_some() || q.model.is_some() || q.project.is_some()
}

fn describe_filter(q: &Query) -> String {
    let mut parts = Vec::new();
    if let Some(m) = &q.model {
        parts.push(format!("model={m}"));
    }
    if let Some(p) = &q.project {
        parts.push(format!("project={p}"));
    }
    if let Some(s) = &q.since {
        parts.push(format!("since={s}"));
    }
    if let Some(u) = &q.until {
        parts.push(format!("until={u}"));
    }
    if parts.is_empty() {
        "none".into()
    } else {
        parts.join(" ")
    }
}
fn chrono_ordered(rows: &[Bucket], newest_first: bool) -> Vec<Bucket> {
    if newest_first {
        rows.iter().rev().cloned().collect()
    } else {
        rows.to_vec()
    }
}
fn opt_cell(v: Option<u64>) -> String {
    match v {
        Some(n) => ui::tokens(n),
        None => "-".to_string(),
    }
}

/// Parse `/login sandbox`, `/sync --host prod`, or a bare URL from slash args.
fn host_flag_from_args(args: &[&str]) -> Option<String> {
    let mut i = 0;
    while i < args.len() {
        let a = args[i];
        if a == "--host" {
            return args.get(i + 1).map(|s| (*s).to_string());
        }
        if let Some(rest) = a.strip_prefix("--host=") {
            return Some(rest.to_string());
        }
        if matches!(a, "sandbox" | "prod") || a.starts_with("http://") || a.starts_with("https://")
        {
            return Some(a.to_string());
        }
        i += 1;
    }
    None
}
fn format_age_secs(secs: i64) -> String {
    match secs {
        s if s < 60 => format!("{s}s"),
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

/// Epoch minutes, the tick rate of the minute-granular clock text on screen.
fn epoch_minutes() -> i64 {
    jiff::Timestamp::now().as_second() / 60
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_date_like_keys_get_a_trend_line() {
        assert!(looks_like_a_period("2026-08-03"));
        assert!(looks_like_a_period("2026-W31"));
        assert!(looks_like_a_period("2026-08"));
        // Projects and sessions share the renderer, and ordering them by key
        // would draw a trend out of something with no time axis.
        assert!(!looks_like_a_period("tokenstat"));
        assert!(!looks_like_a_period("claude-opus-5"));
        assert!(!looks_like_a_period("ses_0001"));
        assert!(!looks_like_a_period(""));
    }

    #[test]
    fn a_missing_last_scan_needs_a_refresh() {
        assert!(archive_needs_scan(None, AUTO_SCAN_MAX_AGE));
        assert!(archive_needs_scan(Some("not-a-number"), AUTO_SCAN_MAX_AGE));
    }

    #[test]
    fn a_fresh_scan_is_left_alone() {
        let now = jiff::Timestamp::now().as_millisecond().to_string();
        assert!(!archive_needs_scan(Some(&now), AUTO_SCAN_MAX_AGE));
    }

    #[test]
    fn an_old_scan_triggers_a_refresh() {
        // Fifteen minutes ago, past the ten-minute threshold.
        let old = (jiff::Timestamp::now().as_millisecond() - 15 * 60 * 1000).to_string();
        assert!(archive_needs_scan(Some(&old), AUTO_SCAN_MAX_AGE));
    }
}
