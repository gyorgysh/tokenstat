//! Full-screen interactive client.
//!
//! Takes over the terminal (alternate screen, raw mode) the way agent CLIs do.
//! Tabs switch reports, Summary opens with headline stats already drawn, and
//! the command field filters slash-command help as you type. On open, if the
//! archive has not been scanned in the last ten minutes, a scan runs before
//! the first interactive frame settles. Logic stays in `tokenstat-core`. This
//! module is layout and input only.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use jiff::tz::TimeZone;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Tabs};
use ratatui::{Frame, Terminal};
use tokenstat_core::{
    Bucket, EquivalentValue, GroupBy, PriceTable, Query, Reconciliation, Store, Totals, UsageBlock,
};

use crate::ui::{self, ACCENT_RGB, SECONDARY_RGB};

const ACCENT: Color = Color::Rgb(ACCENT_RGB.0, ACCENT_RGB.1, ACCENT_RGB.2);
const SECONDARY: Color = Color::Rgb(SECONDARY_RGB.0, SECONDARY_RGB.1, SECONDARY_RGB.2);
const MUTED: Color = Color::DarkGray;
const SELECTED: Color = Color::White;

/// One slash command the prompt can run or complete.
struct CommandDef {
    name: &'static str,
    aliases: &'static [&'static str],
    about: &'static str,
}

const COMMANDS: &[CommandDef] = &[
    CommandDef {
        name: "summary",
        aliases: &["overview", "s"],
        about: "Headline stats and activity grid",
    },
    CommandDef {
        name: "daily",
        aliases: &["d"],
        about: "Usage per day",
    },
    CommandDef {
        name: "weekly",
        aliases: &["w"],
        about: "Usage per ISO week",
    },
    CommandDef {
        name: "monthly",
        aliases: &["m"],
        about: "Usage per month",
    },
    CommandDef {
        name: "models",
        aliases: &[],
        about: "Usage per model",
    },
    CommandDef {
        name: "projects",
        aliases: &["p"],
        about: "Usage per project",
    },
    CommandDef {
        name: "sessions",
        aliases: &[],
        about: "Busiest sessions",
    },
    CommandDef {
        name: "blocks",
        aliases: &["b"],
        about: "Five-hour usage windows",
    },
    CommandDef {
        name: "heatmap",
        aliases: &[],
        about: "Activity heatmap (also: tokenstat heatmap)",
    },
    CommandDef {
        name: "wrapped",
        aliases: &[],
        about: "Year-in-review (also: tokenstat wrapped)",
    },
    CommandDef {
        name: "doctor",
        aliases: &[],
        about: "Archive health check",
    },
    CommandDef {
        name: "scan",
        aliases: &[],
        about: "Read new data into the archive",
    },
    CommandDef {
        name: "export",
        aliases: &[],
        about: "Export is a one-shot CLI command (tokenstat export)",
    },
    CommandDef {
        name: "setup",
        aliases: &["start", "onboard"],
        about: "Getting started: scan local logs, then link tokenstat.ai",
    },
    CommandDef {
        name: "login",
        aliases: &[],
        about: "Link this machine to tokenstat.ai (device login wizard)",
    },
    CommandDef {
        name: "logout",
        aliases: &[],
        about: "Forget the tokenstat.ai sync token for a host",
    },
    CommandDef {
        name: "sync",
        aliases: &[],
        about: "Upload sealed aggregates to tokenstat.ai",
    },
    CommandDef {
        name: "auth",
        aliases: &[],
        about: "Vendor tokens: auth cursor|antigravity (auto keychain)",
    },
    CommandDef {
        name: "fetch",
        aliases: &[],
        about: "Fetch Cursor/Antigravity usage (shell: tokenstat fetch)",
    },
    CommandDef {
        name: "filter",
        aliases: &["f"],
        about: "Filter tabs: --model --project --since --until --last N · clear",
    },
    CommandDef {
        name: "budget",
        aliases: &[],
        about: "Show list-rate budget status (set via tokenstat budget)",
    },
    CommandDef {
        name: "sort",
        aliases: &[],
        about: "Toggle newest/oldest first on Daily and Monthly",
    },
    CommandDef {
        name: "help",
        aliases: &["h", "?"],
        about: "List available commands",
    },
    CommandDef {
        name: "quit",
        aliases: &["exit", "q"],
        about: "Leave the interactive client",
    },
];

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
    models: Vec<Bucket>,
    days: Vec<Bucket>,
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
    /// Host flag to pass to device login after leaving the alternate screen.
    pending_login_host: Option<Option<String>>,
    /// After login succeeds, run a sync against this host.
    pending_sync_host: Option<String>,
    /// Summary tab: show every model row instead of the top preview.
    summary_models_expanded: bool,
    /// Cached sync hint for the status bar (offline, from local config).
    sync_hint: Option<String>,
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
        loop {
            terminal.draw(|f| draw(f, &mut app))?;
            if event::poll(Duration::from_millis(200))? {
                handle_event(&mut app, event::read()?)?;
            }
            if let Some(host) = app.pending_login_host.take() {
                run_login_outside_tui(&mut terminal, &mut app, host.as_deref())?;
            }
            if let Some(host) = app.pending_sync_host.take() {
                run_sync_inline(&mut app, Some(host.as_str()))?;
            }
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

impl App {
    fn load(db_path: &Path, tz: &TimeZone) -> Result<Self> {
        let store = Store::open(db_path).context("opening the tokenstat archive")?;
        let mut app = Self {
            db_path: db_path.to_path_buf(),
            tz: tz.clone(),
            tab: Tab::Summary,
            input: String::new(),
            cursor: 0,
            suggest_idx: 0,
            scroll: 0,
            status: "type / for commands · ↑↓ history · /filter · m expands models · s sorts · ← → tabs · q quits"
                .into(),
            should_quit: false,
            empty: true,
            totals: Totals::default(),
            models: Vec::new(),
            days: Vec::new(),
            weeks: Vec::new(),
            months: Vec::new(),
            projects: Vec::new(),
            sessions: Vec::new(),
            blocks: Vec::new(),
            filter: Query::default(),
            chrono_newest_first: true,
            peak_hour: None,
            confidence: Vec::new(),
            last_scan: None,
            reconciliation: None,
            history: Vec::new(),
            history_idx: None,
            wizard: None,
            pending_login_host: None,
            pending_sync_host: None,
            summary_models_expanded: false,
            sync_hint: None,
        };
        app.reload(&store)?;
        app.refresh_sync_hint();
        Ok(app)
    }

    /// Re-read local sync pacing for the status bar without a network call.
    fn refresh_sync_hint(&mut self) {
        self.sync_hint = tokenstat_sync::scheduling_info(None)
            .ok()
            .filter(|i| i.logged_in)
            .map(|i| format_sync_hint(&i));
    }

    fn reload(&mut self, store: &Store) -> Result<()> {
        let q = self.filter.clone();
        self.totals = store.totals(&q)?;
        self.empty = self.totals.events == 0;
        self.reconciliation = tokenstat_core::reconcile(store)?;
        if self.empty {
            self.models.clear();
            self.days.clear();
            self.weeks.clear();
            self.months.clear();
            self.projects.clear();
            self.sessions.clear();
            self.blocks.clear();
            self.peak_hour = None;
            self.confidence.clear();
            self.last_scan = store.meta("last_scan_ms")?;
            if filter_active(&self.filter) {
                self.status = "Nothing in this filter. Type /filter clear.".into();
            } else {
                self.status = "Archive empty. Type /setup to get started, or /scan.".into();
            }
            return Ok(());
        }
        self.models = store.report(GroupBy::Model, &q)?;
        self.days = store.report(GroupBy::Day, &q)?;
        self.weeks = store.report(GroupBy::Week, &q)?;
        self.months = rollup_months(&self.days);
        self.projects = store.report(GroupBy::Project, &q)?;
        let mut sessions = store.report(GroupBy::Session, &q)?;
        sessions.truncate(40);
        self.sessions = sessions;
        let now_ms = jiff::Timestamp::now().as_millisecond();
        self.blocks = store.blocks(&q, now_ms)?;
        self.peak_hour = store.peak_hour()?;
        self.confidence = store.confidence_breakdown()?;
        self.last_scan = store.meta("last_scan_ms")?;
        Ok(())
    }

    fn run_scan(&mut self, reset: bool) -> Result<()> {
        self.status = "Scanning…".into();
        let mut store = Store::open(&self.db_path)?;
        if reset {
            store.clear_events()?;
            store.clear_watermarks()?;
        }
        let report = tokenstat_core::scan(&mut store, &self.tz)?;
        self.reload(&store)?;
        self.status = format!(
            "Scanned {} of {} files · {} new · {}ms",
            report.files_read, report.files_found, report.events_new, report.elapsed_ms
        );
        Ok(())
    }

    /// Install the hourly scan LaunchAgent / systemd unit / Windows task.
    fn install_scan_schedule(&mut self) -> Result<()> {
        use crate::schedule::{Unit, install};

        let home = directories::BaseDirs::new()
            .map(|d| d.home_dir().to_path_buf())
            .context("locating your home directory")?;
        let exe = crate::schedule::preferred_executable();
        install(&home, Unit::Scan, &exe, Unit::Scan.default_interval())?;
        self.status = "Installed hourly scan schedule".into();
        Ok(())
    }

    fn install_linked_schedules(&mut self, host_flag: Option<&str>) -> Result<()> {
        let home = directories::BaseDirs::new()
            .map(|d| d.home_dir().to_path_buf())
            .context("locating your home directory")?;
        let exe = crate::schedule::preferred_executable();
        let linked = crate::schedule::install_linked_units(&home, &exe, host_flag)?;
        if linked.sync.is_some() {
            let mins = linked.sync_interval_secs.unwrap_or(3600) / 60;
            self.status = format!("Installed sync every {mins} min");
        }
        if linked.update.is_some() {
            self.status = "Installed daily update schedule".into();
        }
        Ok(())
    }

    /// Whether the command palette should be drawn above the input.
    fn showing_suggestions(&self) -> bool {
        // Keep the catalog out of the way while browsing tabs. As soon as the
        // user types, filter and show name + description prominently.
        let trimmed = self.input.trim();
        !trimmed.is_empty() && !trimmed.contains(' ')
    }

    fn filtered_commands(&self) -> Vec<&'static CommandDef> {
        let needle = self
            .input
            .trim()
            .trim_start_matches('/')
            .to_ascii_lowercase();
        // Once the user has typed a space they are editing args, so hide the list.
        if self.input.contains(' ') {
            return Vec::new();
        }
        if needle.is_empty() {
            return COMMANDS.iter().collect();
        }
        COMMANDS
            .iter()
            .filter(|c| {
                c.name.starts_with(&needle)
                    || c.aliases.iter().any(|a| a.starts_with(needle.as_str()))
            })
            .collect()
    }

    fn clamp_suggest(&mut self) {
        let n = self.filtered_commands().len();
        if n == 0 {
            self.suggest_idx = 0;
        } else {
            self.suggest_idx = self.suggest_idx.min(n - 1);
        }
    }

    fn apply_suggestion(&mut self) {
        let cmds = self.filtered_commands();
        if let Some(cmd) = cmds.get(self.suggest_idx) {
            self.input = format!("/{}", cmd.name);
            self.cursor = self.input.len();
            self.suggest_idx = 0;
        }
    }

    fn submit_input(&mut self) -> Result<()> {
        // If the typed text is only a prefix, accept the highlighted suggestion.
        let cmds = self.filtered_commands();
        if !self.input.contains(' ')
            && let Some(cmd) = cmds.get(self.suggest_idx)
        {
            let typed = self.input.trim().trim_start_matches('/');
            if typed != cmd.name && !cmd.aliases.contains(&typed) {
                self.input = format!("/{}", cmd.name);
                self.cursor = self.input.len();
            }
        }

        let raw = self.input.trim().to_string();
        self.input.clear();
        self.cursor = 0;
        self.suggest_idx = 0;
        self.history_idx = None;
        if raw.is_empty() {
            return Ok(());
        }
        if self.history.last().map(String::as_str) != Some(raw.as_str()) {
            self.history.push(raw.clone());
            if self.history.len() > 50 {
                self.history.remove(0);
            }
        }
        let (cmd, args) = split_cmd(&raw);
        match cmd {
            "help" | "h" | "?" => {
                self.status =
                    "↑↓ pick · Tab complete · Enter run · /scan /summary /daily /models /quit"
                        .into();
            }
            "summary" | "overview" | "s" => {
                self.tab = Tab::Summary;
                self.scroll = 0;
                self.status = "Summary".into();
            }
            "daily" | "d" => {
                self.tab = Tab::Daily;
                self.scroll = 0;
                self.status = "Daily".into();
            }
            "weekly" | "w" => {
                self.tab = Tab::Weekly;
                self.scroll = 0;
                self.status = "Weekly".into();
            }
            "monthly" | "m" => {
                self.tab = Tab::Monthly;
                self.scroll = 0;
                self.status = "Monthly".into();
            }
            "models" => {
                self.tab = Tab::Models;
                self.scroll = 0;
                self.status = "Models".into();
            }
            "projects" | "p" => {
                self.tab = Tab::Projects;
                self.scroll = 0;
                self.status = "Projects".into();
            }
            "sessions" => {
                self.tab = Tab::Sessions;
                self.scroll = 0;
                self.status = "Sessions".into();
            }
            "blocks" | "b" => {
                self.tab = Tab::Blocks;
                self.scroll = 0;
                self.status = "Blocks".into();
            }
            "heatmap" => {
                self.tab = Tab::Summary;
                self.scroll = 0;
                self.status = "Heatmap is on the Summary tab".into();
            }
            "wrapped" => {
                self.status = "Year review from the shell: tokenstat wrapped [--year YYYY]".into();
            }
            "doctor" => {
                self.tab = Tab::Doctor;
                self.scroll = 0;
                self.status = "Doctor".into();
            }
            "filter" | "f" => {
                self.apply_filter_args(&args)?;
            }
            "budget" => {
                let store = Store::open(&self.db_path)?;
                let prices = PriceTable::load();
                match tokenstat_core::budget_status(&store, &self.tz, &prices) {
                    Ok(st) => {
                        let mut parts = Vec::new();
                        parts.push(format!("today {}", crate::ui::usd(st.today_usd)));
                        if let Some(lim) = st.limits.daily_usd {
                            parts.push(format!(
                                "daily {:.0}% of {}",
                                st.today_ratio().unwrap_or(0.0) * 100.0,
                                crate::ui::usd(lim)
                            ));
                        }
                        parts.push(format!("month {}", crate::ui::usd(st.month_usd)));
                        if let Some(lim) = st.limits.monthly_usd {
                            parts.push(format!(
                                "monthly {:.0}% of {}",
                                st.month_ratio().unwrap_or(0.0) * 100.0,
                                crate::ui::usd(lim)
                            ));
                        }
                        self.status =
                            format!("{}  (list-rate equivalent, not billed)", parts.join(" · "));
                    }
                    Err(e) => self.status = format!("budget: {e}"),
                }
            }
            "sort" => self.toggle_chrono_sort(),
            "scan" => {
                let reset = args.contains(&"--reset");
                self.run_scan(reset)?;
            }
            "export" => {
                self.status =
                    "Export from the shell: tokenstat export --format csv --out usage.csv".into();
            }
            "auth" => {
                self.status =
                    "Cursor/Antigravity: tokenstat fetch (auto keychain) or auth <vendor>".into();
            }
            "fetch" => {
                self.status = "Fetch from the shell: tokenstat fetch   (30m cache)".into();
            }
            "setup" | "start" | "onboard" => {
                self.wizard = Some(Wizard::Setup {
                    step: SetupStep::Welcome,
                    selected: 0,
                });
                self.status = "Getting started".into();
            }
            "login" => {
                if let Some(flag) = host_flag_from_args(&args) {
                    self.pending_login_host = Some(Some(flag));
                    self.status = "Opening browser for device login…".into();
                } else {
                    self.wizard = Some(Wizard::LoginHost { selected: 0 });
                    self.status = "Choose a host, then confirm in the browser".into();
                }
            }
            "logout" => {
                let flag = host_flag_from_args(&args);
                match tokenstat_sync::logout(flag.as_deref()) {
                    Ok(host) => {
                        self.refresh_sync_hint();
                        self.status = format!("Logged out · cleared token for {host}");
                    }
                    Err(e) => self.status = format!("logout: {e}"),
                }
            }
            "sync" => {
                if args.contains(&"--dry-run") {
                    self.status =
                        "Dry-run from the shell: tokenstat sync --dry-run [--host sandbox]".into();
                } else if args.contains(&"--status") {
                    let flag = host_flag_from_args(&args);
                    match tokenstat_sync::sync_status(flag.as_deref()) {
                        Ok(st) => {
                            self.status = format!(
                                "@{} · {} · last {}",
                                st.handle.as_deref().unwrap_or("-"),
                                st.host,
                                st.last_sync_at.as_deref().unwrap_or("-")
                            );
                        }
                        Err(e) => self.status = format!("sync status: {e}"),
                    }
                } else {
                    let flag = host_flag_from_args(&args);
                    run_sync_inline(self, flag.as_deref())?;
                }
            }
            "quit" | "exit" | "q" => self.should_quit = true,
            other => {
                self.status = format!("Unknown command: {other}. Type / for the list");
            }
        }
        Ok(())
    }

    fn history_prev(&mut self) {
        if self.history.is_empty() {
            return;
        }
        let next = match self.history_idx {
            None => self.history.len() - 1,
            Some(0) => 0,
            Some(i) => i - 1,
        };
        self.history_idx = Some(next);
        self.input = self.history[next].clone();
        self.cursor = self.input.len();
        self.suggest_idx = 0;
    }

    fn history_next(&mut self) {
        let Some(i) = self.history_idx else {
            return;
        };
        if i + 1 >= self.history.len() {
            self.history_idx = None;
            self.input.clear();
            self.cursor = 0;
        } else {
            self.history_idx = Some(i + 1);
            self.input = self.history[i + 1].clone();
            self.cursor = self.input.len();
        }
        self.suggest_idx = 0;
    }

    fn toggle_chrono_sort(&mut self) {
        self.chrono_newest_first = !self.chrono_newest_first;
        self.scroll = 0;
        self.status = if self.chrono_newest_first {
            "Newest first".into()
        } else {
            "Oldest first".into()
        };
    }

    fn apply_filter_args(&mut self, args: &[&str]) -> Result<()> {
        if args.is_empty() || args.iter().any(|a| *a == "clear" || *a == "--clear") {
            self.filter = Query::default();
            let store = Store::open(&self.db_path)?;
            self.reload(&store)?;
            self.status = "Filter cleared".into();
            return Ok(());
        }
        let mut q = self.filter.clone();
        let mut i = 0;
        while i < args.len() {
            match args[i] {
                "--model" | "-m" => {
                    i += 1;
                    q.model = args.get(i).map(|s| (*s).to_string());
                }
                "--project" | "-p" => {
                    i += 1;
                    q.project = args.get(i).map(|s| (*s).to_string());
                }
                "--since" => {
                    i += 1;
                    q.since = args.get(i).map(|s| (*s).to_string());
                }
                "--until" => {
                    i += 1;
                    q.until = args.get(i).map(|s| (*s).to_string());
                }
                "--last" => {
                    i += 1;
                    let n: i64 = args
                        .get(i)
                        .ok_or_else(|| anyhow::anyhow!("--last needs a day count"))?
                        .parse()
                        .context("--last must be a number")?;
                    let today = jiff::Timestamp::now().to_zoned(self.tz.clone()).date();
                    let since = today
                        .checked_sub(jiff::Span::new().days(n - 1))
                        .context("invalid --last span")?;
                    q.since = Some(since.to_string());
                    q.until = Some(today.to_string());
                }
                other => {
                    self.status = format!("Unknown filter flag: {other}");
                    return Ok(());
                }
            }
            i += 1;
        }
        self.filter = q;
        let store = Store::open(&self.db_path)?;
        self.reload(&store)?;
        self.scroll = 0;
        self.status = format!("Filter: {}", describe_filter(&self.filter));
        Ok(())
    }

    fn insert_char(&mut self, c: char) {
        self.input.insert(self.cursor, c);
        self.cursor += c.len_utf8();
        self.suggest_idx = 0;
        self.clamp_suggest();
    }

    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let prev = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        self.input.replace_range(prev..self.cursor, "");
        self.cursor = prev;
        self.suggest_idx = 0;
        self.clamp_suggest();
    }

    fn move_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
    }

    fn move_right(&mut self) {
        if self.cursor >= self.input.len() {
            return;
        }
        let next = self.input[self.cursor..]
            .chars()
            .next()
            .map(|c| self.cursor + c.len_utf8())
            .unwrap_or(self.input.len());
        self.cursor = next;
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

fn handle_event(app: &mut App, ev: Event) -> Result<()> {
    match ev {
        Event::Key(key) if key.kind == KeyEventKind::Press => {
            if app.wizard.is_some() {
                return handle_wizard_key(app, key.code, key.modifiers);
            }

            let suggesting = app.showing_suggestions() && !app.filtered_commands().is_empty();

            // When the palette is open, ↑↓ pick a command instead of scrolling.
            if suggesting {
                match key.code {
                    KeyCode::Up => {
                        if app.suggest_idx > 0 {
                            app.suggest_idx -= 1;
                        }
                        return Ok(());
                    }
                    KeyCode::Down => {
                        let n = app.filtered_commands().len();
                        if n > 0 && app.suggest_idx + 1 < n {
                            app.suggest_idx += 1;
                        }
                        return Ok(());
                    }
                    KeyCode::Tab => {
                        app.apply_suggestion();
                        return Ok(());
                    }
                    _ => {}
                }
            }

            // Global shortcuts when the input is empty.
            if app.input.is_empty() {
                match key.code {
                    KeyCode::Char('q') if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.should_quit = true;
                        return Ok(());
                    }
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.should_quit = true;
                        return Ok(());
                    }
                    KeyCode::Right if !suggesting => {
                        app.tab = app.tab.next();
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::Left if !suggesting => {
                        app.tab = app.tab.prev();
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::BackTab => {
                        app.tab = app.tab.prev();
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::PageUp => {
                        app.scroll = app.scroll.saturating_sub(5);
                        return Ok(());
                    }
                    KeyCode::PageDown => {
                        app.scroll = app.scroll.saturating_add(5);
                        return Ok(());
                    }
                    KeyCode::Up => {
                        if !app.history.is_empty() {
                            app.history_prev();
                            return Ok(());
                        }
                        app.scroll = app.scroll.saturating_sub(1);
                        return Ok(());
                    }
                    KeyCode::Down => {
                        if app.history_idx.is_some() {
                            app.history_next();
                            return Ok(());
                        }
                        app.scroll = app.scroll.saturating_add(1);
                        return Ok(());
                    }
                    KeyCode::Char(c @ '1'..='9') => {
                        app.tab = Tab::from_index((c as u8 - b'1') as usize);
                        app.scroll = 0;
                        return Ok(());
                    }
                    KeyCode::Char('s') => {
                        if app.tab.is_chrono() {
                            app.toggle_chrono_sort();
                        } else {
                            app.status =
                                "s sorts Daily/Weekly/Monthly. Switch to one of those tabs first."
                                    .into();
                        }
                        return Ok(());
                    }
                    KeyCode::Char('m') => {
                        if app.tab == Tab::Summary {
                            app.summary_models_expanded = !app.summary_models_expanded;
                            app.scroll = 0;
                            app.status = if app.summary_models_expanded {
                                "Showing all models · m collapses".into()
                            } else {
                                "Showing top models · m expands · dollar total stays below".into()
                            };
                        } else {
                            app.status =
                                "m expands the model list on Summary. Switch to that tab first."
                                    .into();
                        }
                        return Ok(());
                    }
                    _ => {}
                }
            } else if !suggesting {
                // With text in the field and no palette, ↑↓ walk command history.
                match key.code {
                    KeyCode::Up => {
                        app.history_prev();
                        return Ok(());
                    }
                    KeyCode::Down => {
                        app.history_next();
                        return Ok(());
                    }
                    _ => {}
                }
            }

            match key.code {
                KeyCode::Esc => {
                    if app.input.is_empty() {
                        app.should_quit = true;
                    } else {
                        app.input.clear();
                        app.cursor = 0;
                        app.suggest_idx = 0;
                    }
                }
                KeyCode::Enter => app.submit_input()?,
                KeyCode::Backspace => app.backspace(),
                KeyCode::Left => app.move_left(),
                KeyCode::Right => app.move_right(),
                KeyCode::Home => app.cursor = 0,
                KeyCode::End => app.cursor = app.input.len(),
                KeyCode::Char(c) => {
                    if key.modifiers.contains(KeyModifiers::CONTROL) && c == 'c' {
                        app.should_quit = true;
                    } else if !key.modifiers.contains(KeyModifiers::CONTROL)
                        && !key.modifiers.contains(KeyModifiers::ALT)
                    {
                        app.insert_char(c);
                    }
                }
                _ => {}
            }
        }
        Event::Resize(_, _) => {}
        _ => {}
    }
    Ok(())
}

fn handle_wizard_key(app: &mut App, code: KeyCode, modifiers: KeyModifiers) -> Result<()> {
    if modifiers.contains(KeyModifiers::CONTROL) && matches!(code, KeyCode::Char('c')) {
        app.should_quit = true;
        return Ok(());
    }

    let Some(wizard) = app.wizard.as_mut() else {
        return Ok(());
    };

    match code {
        KeyCode::Esc => {
            app.wizard = None;
            app.status = "Cancelled".into();
            return Ok(());
        }
        KeyCode::Up => {
            let selected = wizard_selected_mut(wizard);
            if *selected > 0 {
                *selected -= 1;
            }
            return Ok(());
        }
        KeyCode::Down => {
            let n = wizard_option_count(wizard);
            let selected = wizard_selected_mut(wizard);
            if n > 0 && *selected + 1 < n {
                *selected += 1;
            }
            return Ok(());
        }
        KeyCode::Enter => {}
        _ => return Ok(()),
    }

    // Enter: take the wizard so we can mutate app freely.
    let Some(wizard) = app.wizard.take() else {
        return Ok(());
    };
    match wizard {
        Wizard::LoginHost { selected } => {
            let pending = LOGIN_HOSTS
                .get(selected)
                .map(|(_, _, flag)| flag.map(str::to_string));
            if let Some(host_flag) = pending {
                app.pending_login_host = Some(host_flag);
                app.status = "Opening browser for device login…".into();
            } else {
                app.status = "Invalid host choice".into();
            }
        }
        Wizard::AfterLogin {
            handle,
            host,
            selected,
        } => {
            if selected == 0 {
                app.pending_sync_host = Some(host.clone());
                app.status = format!("Syncing as @{handle}…");
            } else {
                app.status = format!("Logged in as @{handle} · sync later with /sync");
            }
        }
        Wizard::Setup { step, selected } => match step {
            SetupStep::Welcome => {
                if selected == 0 {
                    app.wizard = Some(Wizard::Setup {
                        step: SetupStep::ScanOffer,
                        selected: 0,
                    });
                    app.status = "Scan local agent logs into the archive?".into();
                } else {
                    app.status = "Skipped setup. Type /setup anytime.".into();
                }
            }
            SetupStep::ScanOffer => {
                if selected == 0 {
                    app.run_scan(false)?;
                }
                app.wizard = Some(Wizard::Setup {
                    step: SetupStep::ScheduleOffer,
                    selected: 0,
                });
                app.status = "Install an hourly scan so log cleanup cannot erase history?".into();
            }
            SetupStep::ScheduleOffer => {
                if selected == 0 {
                    match app.install_scan_schedule() {
                        Ok(()) => {}
                        Err(e) => app.status = format!("Schedule install failed: {e}"),
                    }
                } else {
                    app.status = "Skipped schedule. Run tokenstat schedule --install later.".into();
                }
                app.wizard = Some(Wizard::Setup {
                    step: SetupStep::LoginOffer,
                    selected: 0,
                });
            }
            SetupStep::LoginOffer => {
                if selected == 0 {
                    app.wizard = Some(Wizard::LoginHost { selected: 0 });
                    app.status = "Choose a host, then confirm in the browser".into();
                } else {
                    app.status =
                        "Setup done locally. Type /login when you want a public profile.".into();
                }
            }
        },
    }
    Ok(())
}

fn wizard_selected_mut(wizard: &mut Wizard) -> &mut usize {
    match wizard {
        Wizard::LoginHost { selected }
        | Wizard::AfterLogin { selected, .. }
        | Wizard::Setup { selected, .. } => selected,
    }
}

fn wizard_option_count(wizard: &Wizard) -> usize {
    match wizard {
        Wizard::LoginHost { .. } => LOGIN_HOSTS.len(),
        Wizard::AfterLogin { .. } => AFTER_LOGIN_ACTIONS.len(),
        Wizard::Setup { step, .. } => match step {
            SetupStep::Welcome => SETUP_WELCOME.len(),
            SetupStep::ScanOffer => 2,
            SetupStep::ScheduleOffer => 2,
            SetupStep::LoginOffer => 2,
        },
    }
}

fn draw(f: &mut Frame<'_>, app: &mut App) {
    let area = f.area();
    // Thin chrome: tabs, flexible data, one input line, one status line.
    // Suggestions overlay the bottom of the data pane so they do not steal
    // permanent vertical space.
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(3),
            Constraint::Length(1),
            Constraint::Length(1),
        ])
        .split(area);

    draw_tabs(f, chunks[0], app);
    draw_body(f, chunks[1], app);
    if app.wizard.is_none() {
        draw_suggestions_overlay(f, chunks[1], app);
    }
    draw_input(f, chunks[2], app);
    draw_status(f, chunks[3], app);
    if app.wizard.is_some() {
        draw_wizard(f, area, app);
    }
}

fn draw_tabs(f: &mut Frame<'_>, area: Rect, app: &App) {
    let titles: Vec<Line<'_>> = Tab::ALL
        .iter()
        .map(|t| Line::from(Span::raw(format!(" {} ", t.title()))))
        .collect();
    let tabs = Tabs::new(titles)
        .select(app.tab.index())
        .block(Block::default().borders(Borders::ALL).title(Span::styled(
            " tokenstat.ai ",
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        )))
        .style(Style::default().fg(MUTED))
        .highlight_style(
            Style::default()
                .fg(Color::Black)
                .bg(ACCENT)
                .add_modifier(Modifier::BOLD),
        )
        .divider(Span::raw("│"));
    f.render_widget(tabs, area);
}

fn draw_body(f: &mut Frame<'_>, area: Rect, app: &App) {
    let filter_note = if filter_active(&app.filter) {
        format!(" · filter {}", describe_filter(&app.filter))
    } else {
        String::new()
    };
    let title = match app.tab {
        Tab::Summary => {
            if app.summary_models_expanded {
                format!(" Headline · m collapses models{filter_note} ")
            } else {
                format!(" Headline · m expands models{filter_note} ")
            }
        }
        Tab::Daily => {
            if app.chrono_newest_first {
                format!(" Per day · newest first · s to flip{filter_note} ")
            } else {
                format!(" Per day · oldest first · s to flip{filter_note} ")
            }
        }
        Tab::Weekly => {
            if app.chrono_newest_first {
                format!(" Per week · newest first · s to flip{filter_note} ")
            } else {
                format!(" Per week · oldest first · s to flip{filter_note} ")
            }
        }
        Tab::Monthly => {
            if app.chrono_newest_first {
                format!(" Per month · newest first · s to flip{filter_note} ")
            } else {
                format!(" Per month · oldest first · s to flip{filter_note} ")
            }
        }
        Tab::Models => format!(" Per model{filter_note} "),
        Tab::Projects => format!(" Per project{filter_note} "),
        Tab::Sessions => format!(" Busiest sessions{filter_note} "),
        Tab::Blocks => format!(" 5 hour windows{filter_note} "),
        Tab::Doctor => " Archive health ".to_string(),
    };
    let block = Block::default()
        .borders(Borders::LEFT | Borders::RIGHT | Borders::TOP)
        .border_style(Style::default().fg(Color::Rgb(0x3D, 0x2A, 0x55)))
        .title(Span::styled(
            title,
            Style::default().fg(SECONDARY).add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(area);
    f.render_widget(block, area);

    let lines = if app.empty && app.tab != Tab::Doctor {
        if filter_active(&app.filter) {
            filtered_empty_lines()
        } else {
            empty_archive_lines()
        }
    } else {
        match app.tab {
            Tab::Summary => summary_lines(app, inner.width),
            Tab::Daily => table_lines(
                &chrono_ordered(&app.days, app.chrono_newest_first),
                "Date",
                false,
            ),
            Tab::Weekly => table_lines(
                &chrono_ordered(&app.weeks, app.chrono_newest_first),
                "Week",
                false,
            ),
            Tab::Monthly => table_lines(
                &chrono_ordered(&app.months, app.chrono_newest_first),
                "Month",
                false,
            ),
            Tab::Models => table_lines(&app.models, "Model", true),
            Tab::Projects => table_lines(&app.projects, "Project", false),
            Tab::Sessions => table_lines(&app.sessions, "Session", false),
            Tab::Blocks => block_lines(app),
            Tab::Doctor => doctor_lines(app),
        }
    };

    // Leave room at the bottom of the pane when the palette is open so rows
    // are not permanently covered without a way to scroll past them.
    let reserve = suggestion_height(app, inner.height);
    let view_height = inner.height.saturating_sub(reserve);
    let scroll = app.scroll.min(lines.len().saturating_sub(1) as u16);
    let para = Paragraph::new(lines)
        .scroll((scroll, 0))
        .style(Style::default());
    let view = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: view_height.max(1),
    };
    f.render_widget(para, view);
}

fn suggestion_height(app: &App, available: u16) -> u16 {
    if !app.showing_suggestions() {
        return 0;
    }
    let n = app.filtered_commands().len() as u16;
    if n == 0 {
        return 0;
    }
    // Cap so a tall catalog never eats the whole pane.
    n.min(available.saturating_sub(4).min(8)).saturating_add(1) // +1 separator
}

fn draw_suggestions_overlay(f: &mut Frame<'_>, body: Rect, app: &App) {
    if !app.showing_suggestions() {
        return;
    }
    let cmds = app.filtered_commands();
    if cmds.is_empty() {
        return;
    }

    let inner = Rect {
        x: body.x.saturating_add(1),
        y: body.y.saturating_add(1),
        width: body.width.saturating_sub(2),
        height: body.height.saturating_sub(1),
    };
    let height = suggestion_height(app, inner.height);
    if height == 0 || inner.width == 0 {
        return;
    }

    let area = Rect {
        x: inner.x,
        y: inner.y + inner.height.saturating_sub(height),
        width: inner.width,
        height,
    };
    f.render_widget(Clear, area);

    let mut lines: Vec<Line<'static>> = Vec::new();
    // Top rule, then command rows. Selected row is bright; others are muted.
    lines.push(Line::from(Span::styled(
        "─".repeat(area.width as usize),
        Style::default().fg(MUTED),
    )));

    let visible = height.saturating_sub(1) as usize;
    let start = app
        .suggest_idx
        .saturating_sub(visible.saturating_sub(1))
        .min(cmds.len().saturating_sub(visible));
    for (offset, cmd) in cmds.iter().skip(start).take(visible).enumerate() {
        let i = start + offset;
        let selected = i == app.suggest_idx;
        let name = format!("/{}", cmd.name);
        let style = if selected {
            Style::default().fg(SELECTED).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(MUTED)
        };
        let about_style = if selected {
            Style::default().fg(ACCENT)
        } else {
            Style::default().fg(MUTED)
        };
        lines.push(Line::from(vec![
            Span::styled(format!("  {:<12}", name), style),
            Span::styled(cmd.about.to_string(), about_style),
        ]));
    }

    f.render_widget(Paragraph::new(lines), area);
}

fn draw_input(f: &mut Frame<'_>, area: Rect, app: &App) {
    f.render_widget(Clear, area);
    let prompt = "❯ ";
    let display = Line::from(vec![
        Span::styled(
            prompt,
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ),
        Span::raw(app.input.clone()),
    ]);
    f.render_widget(Paragraph::new(display), area);

    let prefix = app.input[..app.cursor].chars().count() as u16;
    let x = area.x.saturating_add(2).saturating_add(prefix);
    if x < area.x + area.width {
        f.set_cursor_position(Position { x, y: area.y });
    }
}

fn draw_status(f: &mut Frame<'_>, area: Rect, app: &App) {
    let hint = if app.showing_suggestions() && !app.filtered_commands().is_empty() {
        "↑↓ select · Tab complete · Enter run · Esc clear".to_string()
    } else if let Some(sync) = &app.sync_hint {
        if app.status.starts_with("type /") {
            format!("{sync}  ·  {}", app.status)
        } else {
            app.status.clone()
        }
    } else {
        app.status.clone()
    };
    let version = format!("v{}", tokenstat_core::VERSION);
    let ver_w = version.chars().count() as u16;
    // Leave room for the version on the right so it stays put while status text
    // changes length. Truncate the hint rather than colliding with the version.
    let hint_budget = area.width.saturating_sub(ver_w.saturating_add(3)) as usize;
    let hint = if hint.chars().count() > hint_budget {
        let mut cut = hint
            .chars()
            .take(hint_budget.saturating_sub(1))
            .collect::<String>();
        cut.push('…');
        cut
    } else {
        hint
    };
    let hint_len = hint.chars().count() as u16;
    let pad = area.width.saturating_sub(1 + hint_len + ver_w + 1) as usize;
    let line = Line::from(vec![
        Span::styled(" ", Style::default()),
        Span::styled(hint, Style::default().fg(MUTED)),
        Span::raw(" ".repeat(pad)),
        Span::styled(version, Style::default().fg(MUTED)),
        Span::raw(" "),
    ]);
    f.render_widget(Paragraph::new(line), area);
}

fn summary_lines(app: &App, width: u16) -> Vec<Line<'static>> {
    let c = &app.totals.counters;
    let in_out = c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0);
    let cache_write = c.cache_write_5m.unwrap_or(0) + c.cache_write_1h.unwrap_or(0);
    let mut lines = Vec::new();

    lines.push(Line::from(vec![
        Span::styled(format!("{:<16}", "Sessions"), Style::default().fg(MUTED)),
        Span::styled(format!("{:<16}", "Requests"), Style::default().fg(MUTED)),
        Span::styled(
            format!("{:<16}", "Input + output"),
            Style::default().fg(MUTED),
        ),
        Span::styled(format!("{:<16}", "Active days"), Style::default().fg(MUTED)),
    ]));
    lines.push(Line::from(vec![
        Span::styled(
            format!("{:<16}", ui::exact(app.totals.sessions)),
            Style::default()
                .fg(intensity_color(0.55))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", ui::exact(app.totals.events)),
            Style::default()
                .fg(intensity_color(0.7))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", ui::tokens(in_out)),
            Style::default()
                .fg(intensity_color(0.85))
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{:<16}", ui::exact(app.totals.days)),
            Style::default()
                .fg(intensity_color(0.45))
                .add_modifier(Modifier::BOLD),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        format!(
            "cache read {}  ·  cache write {}  ·  {} counting cache",
            ui::tokens(c.cache_read.unwrap_or(0)),
            ui::tokens(cache_write),
            ui::tokens(c.total()),
        ),
        Style::default().fg(MUTED),
    )));

    if let (Some(first), Some(last)) = (&app.totals.first_date, &app.totals.last_date) {
        let peak = app
            .peak_hour
            .map(|h| format!("  ·  peak hour {h:02}:00"))
            .unwrap_or_default();
        lines.push(Line::from(Span::styled(
            format!("{first} to {last}{peak}"),
            Style::default().fg(MUTED),
        )));
    }

    if !app.days.is_empty() {
        lines.push(Line::from(""));
        let pairs: Vec<(String, u64)> = app
            .days
            .iter()
            .map(|d| {
                let c = &d.counters;
                (
                    d.key.clone(),
                    c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0),
                )
            })
            .collect();
        // Purple→cyan heat: idle cells stay muted, hot days peak in cyan so
        // the grid sits with the electric purple chrome instead of fighting it.
        let weeks = usize::from(width)
            .saturating_sub(4 + ui::HEAT_GUTTER)
            .div_ceil(ui::HEAT_COL)
            .clamp(8, 53);
        let today = jiff::Timestamp::now().to_zoned(app.tz.clone()).date();
        if let Some(cal) = ui::heat_calendar(&pairs, weeks, today) {
            lines.push(Line::from(Span::styled(
                cal.header(),
                Style::default().fg(MUTED),
            )));
            for (r, row) in cal.rows.iter().enumerate() {
                let mut spans = vec![Span::styled(
                    ui::pad_right(ui::HeatCalendar::row_label(r), ui::HEAT_GUTTER),
                    Style::default().fg(MUTED),
                )];
                for cell in row {
                    match cell {
                        None => spans.push(Span::raw("  ")),
                        Some(c) => {
                            let (cr, cg, cb) = ui::heat_rgb(c.level);
                            spans.push(Span::styled(
                                ui::HEAT_CELL,
                                Style::default().fg(Color::Rgb(cr, cg, cb)),
                            ));
                            spans.push(Span::raw(" "));
                        }
                    }
                }
                lines.push(Line::from(spans));
            }
            if let Some(b) = cal.busiest {
                lines.push(Line::from(Span::styled(
                    format!(
                        "{}busiest {} ({})  ·  streak {} days, best {}",
                        " ".repeat(ui::HEAT_GUTTER),
                        b.date,
                        ui::tokens(b.value),
                        cal.streak_current,
                        cal.streak_best,
                    ),
                    Style::default().fg(MUTED),
                )));
            }
        }
    }

    if !app.models.is_empty() {
        lines.push(Line::from(""));
        let grand: u64 = app
            .models
            .iter()
            .map(|m| m.counters.total())
            .sum::<u64>()
            .max(1);
        let prices = PriceTable::load();
        let w = app
            .models
            .iter()
            .map(|m| {
                tokenstat_core::display_usage_model_id(&m.key)
                    .chars()
                    .count()
            })
            .max()
            .unwrap_or(10)
            .clamp(8, 53);
        lines.push(Line::from(Span::styled(
            format!(
                "{}  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}",
                ui::pad_right("Model", w),
                "input",
                "output",
                "cache",
                "total",
                "price",
            ),
            Style::default().fg(MUTED),
        )));

        let hidden = app.models.len().saturating_sub(SUMMARY_MODEL_PREVIEW);
        let show_all = app.summary_models_expanded || hidden == 0;
        let visible = if show_all {
            app.models.as_slice()
        } else {
            &app.models[..SUMMARY_MODEL_PREVIEW]
        };
        for m in visible {
            let share = m.counters.total() as f64 / grand as f64;
            let c = &m.counters;
            let lookup = tokenstat_core::display_usage_model_id(&m.key);
            let value = EquivalentValue::price(&prices, &lookup, c)
                .map(|v| {
                    let body = ui::usd(v.dollars());
                    if prices.is_estimate(&lookup) && v.dollars() > 0.0 {
                        format!("~{body}")
                    } else {
                        body
                    }
                })
                .unwrap_or_else(|| "-".to_string());
            let total = {
                let t = ui::tokens(c.total());
                if c.has_unknown() { format!("{t}+") } else { t }
            };
            lines.push(Line::from(vec![
                Span::raw(format!(
                    "{}  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}  ",
                    ui::pad_right(&lookup, w),
                    opt_cell(c.input_fresh),
                    opt_cell(c.output),
                    opt_cell(c.cache_read),
                    total,
                    value,
                )),
                Span::styled(
                    format!("{:.1}%", share * 100.0),
                    Style::default().fg(intensity_color(share)),
                ),
            ]));
        }
        if !show_all {
            lines.push(Line::from(Span::styled(
                format!("m expands {hidden} more · Models tab for the full list"),
                Style::default().fg(ACCENT),
            )));
        } else if hidden > 0 {
            lines.push(Line::from(Span::styled(
                "m collapses to the top 10 · Models tab for the same list",
                Style::default().fg(MUTED),
            )));
        }

        // Dollar total always follows the (possibly truncated) list so the
        // headline "how much in total" stays on screen when collapsed.
        let total_value: EquivalentValue = app
            .models
            .iter()
            .filter_map(|m| {
                EquivalentValue::price(
                    &prices,
                    &tokenstat_core::display_usage_model_id(&m.key),
                    &m.counters,
                )
            })
            .sum();
        lines.push(Line::from(""));
        lines.push(Line::from(vec![
            Span::styled(
                ui::usd(total_value.dollars()),
                Style::default()
                    .fg(intensity_color(0.9))
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                " if this had been billed per token",
                Style::default().fg(MUTED),
            ),
        ]));
        lines.push(Line::from(Span::styled(
            "List-rate equivalent only. Plan usage is not money charged; metered API usage may have been.",
            Style::default().fg(MUTED),
        )));
        if app
            .models
            .iter()
            .any(|m| prices.is_estimate(&tokenstat_core::display_usage_model_id(&m.key)))
        {
            lines.push(Line::from(Span::styled(
                "~ values are estimates (Cursor Auto at Composer 2.5 list rates as a floor).",
                Style::default().fg(MUTED),
            )));
        }
        if prices.is_empty() {
            lines.push(Line::from(Span::styled(
                "No local price book yet. Run: tokenstat pricing --refresh",
                Style::default().fg(MUTED),
            )));
        }
    }

    lines
}

fn chrono_ordered(rows: &[Bucket], newest_first: bool) -> Vec<Bucket> {
    if newest_first {
        rows.iter().rev().cloned().collect()
    } else {
        rows.to_vec()
    }
}

fn empty_archive_lines() -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(Span::styled(
            "No usage recorded yet.",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "Type /setup for guided scan + schedule, or /scan to read logs now.",
            Style::default().fg(MUTED),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "On disk: Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI",
            Style::default().fg(MUTED),
        )),
        Line::from(Span::styled(
            "Remote: Cursor (tokenstat auth cursor)",
            Style::default().fg(MUTED),
        )),
        Line::from(Span::styled(
            "IDE sync: Antigravity (open app, then tokenstat fetch)",
            Style::default().fg(MUTED),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "Doctor still works on an empty archive: switch with → or /doctor.",
            Style::default().fg(MUTED),
        )),
    ]
}

fn filtered_empty_lines() -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(Span::styled(
            "Nothing matches this filter.",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "Type /filter clear, or widen --since / --model / --project.",
            Style::default().fg(MUTED),
        )),
    ]
}

fn table_lines(rows: &[Bucket], label: &str, price_as_model: bool) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    if rows.is_empty() {
        lines.push(Line::from(Span::styled(
            "Nothing in this range.",
            Style::default().fg(MUTED),
        )));
        lines.push(Line::from(Span::styled(
            "Try another tab, or /scan if the archive looks stale.",
            Style::default().fg(MUTED),
        )));
        return lines;
    }

    let key_w = rows
        .iter()
        .map(|r| {
            if price_as_model {
                tokenstat_core::display_usage_model_id(&r.key)
                    .chars()
                    .count()
            } else {
                r.key.chars().count()
            }
        })
        .max()
        .unwrap_or(8)
        // Dates need the full YYYY-MM-DD width. The old upper clamp alone was
        // fine, but pad used to elide exact-fit strings.
        .clamp(label.len().max(10), 36);
    let max = rows
        .iter()
        .map(|r| r.counters.total())
        .max()
        .unwrap_or(1)
        .max(1);
    let prices = PriceTable::load();

    lines.push(Line::from(Span::styled(
        format!(
            "{}  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}",
            ui::pad_right(label, key_w),
            "input",
            "output",
            "cache",
            "total",
            "value",
        ),
        Style::default().fg(MUTED),
    )));

    let mut any_estimate = false;
    for r in rows {
        let c = &r.counters;
        let frac = c.total() as f64 / max as f64;
        let total = {
            let t = ui::tokens(c.total());
            if c.has_unknown() { format!("{t}+") } else { t }
        };
        let key_label = if price_as_model {
            tokenstat_core::display_usage_model_id(&r.key)
        } else {
            r.key.clone()
        };
        let value = if price_as_model {
            EquivalentValue::price(&prices, &key_label, c)
                .map(|v| {
                    if prices.is_estimate(&key_label) && v.dollars() > 0.0 {
                        any_estimate = true;
                        format!("~{}", ui::usd(v.dollars()))
                    } else {
                        ui::usd(v.dollars())
                    }
                })
                .unwrap_or_else(|| "-".to_string())
        } else {
            "-".to_string()
        };
        let mut row = vec![Span::raw(format!(
            "{}  {:>8}  {:>8}  {:>8}  {:>9}  {:>8}  ",
            ui::pad_right(&key_label, key_w),
            opt_cell(c.input_fresh),
            opt_cell(c.output),
            opt_cell(c.cache_read),
            total,
            value,
        ))];
        row.extend(faded_bar_spans(frac, 12));
        lines.push(Line::from(row));
    }
    if price_as_model {
        lines.push(Line::from(Span::styled(
            "value = list-rate equivalent, not billed dollars",
            Style::default().fg(MUTED),
        )));
        if any_estimate {
            lines.push(Line::from(Span::styled(
                "~ values are estimates (Cursor Auto at Composer 2.5 list rates as a floor).",
                Style::default().fg(MUTED),
            )));
        }
    }
    lines
}

/// A horizontal bar that fades along its length and scales with `fraction`.
///
/// Quiet rows stay deep violet. Strong rows run purple into cyan at the tip,
/// so rank is visible without reading the number.
fn faded_bar_spans(fraction: f64, width: usize) -> Vec<Span<'static>> {
    let filled = ui::bar(fraction, width);
    let n = filled.chars().count();
    let mut spans = Vec::with_capacity(width);
    if n == 0 {
        spans.push(Span::styled(" ".repeat(width), Style::default().fg(MUTED)));
        return spans;
    }
    for (i, ch) in filled.chars().enumerate() {
        // Blend overall magnitude with position along the bar so the tip is
        // always the brightest part of that row.
        let along = (i as f64 + 1.0) / n as f64;
        let t = (fraction.powf(0.55) * 0.4 + along * 0.6).clamp(0.0, 1.0);
        let (r, g, b) = ui::intensity_rgb(t);
        spans.push(Span::styled(
            ch.to_string(),
            Style::default().fg(Color::Rgb(r, g, b)),
        ));
    }
    let pad = width.saturating_sub(n);
    if pad > 0 {
        spans.push(Span::styled(" ".repeat(pad), Style::default().fg(MUTED)));
    }
    spans
}

fn intensity_color(t: f64) -> Color {
    let (r, g, b) = ui::intensity_rgb(t.clamp(0.0, 1.0));
    Color::Rgb(r, g, b)
}

/// Offline sync line for the status bar: host, plan interval, next allowed time.
fn format_sync_hint(info: &tokenstat_sync::SchedulingInfo) -> String {
    let mut parts = vec![format!("linked · {}", info.host)];
    if let Some(until) = &info.next_allowed_at {
        if let Ok(until_ts) = until.parse::<jiff::Timestamp>() {
            let now = jiff::Timestamp::now();
            if until_ts > now {
                let secs = (until_ts - now).get_seconds().max(0);
                let mins = (secs + 59) / 60;
                parts.push(format!("next sync in ~{mins} min"));
            } else {
                parts.push("sync ready".into());
            }
        } else {
            parts.push(format!("next sync after {until}"));
        }
    } else if let Some(interval) = info.min_interval {
        parts.push(format!("every {} min", interval / 60));
    }
    parts.join(" · ")
}

fn block_lines(app: &App) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    if app.blocks.is_empty() {
        lines.push(Line::from(Span::styled(
            "No 5 hour blocks yet.",
            Style::default().fg(MUTED),
        )));
        return lines;
    }

    let now_ms = jiff::Timestamp::now().as_millisecond();
    let max = app
        .blocks
        .iter()
        .map(|b| b.counters.total())
        .max()
        .unwrap_or(1)
        .max(1);

    lines.push(Line::from(Span::styled(
        format!(
            "{:<22}  {:>8}  {:>8}  {:>9}  {}",
            "Block", "events", "in+out", "total", "status"
        ),
        Style::default().fg(MUTED),
    )));

    for b in app.blocks.iter().rev().take(40) {
        let start = match jiff::Timestamp::from_millisecond(b.start_ms) {
            Ok(ts) => format!("{}", ts.to_zoned(app.tz.clone()).strftime("%Y-%m-%d %H:%M")),
            Err(_) => b.start_ms.to_string(),
        };
        let c = &b.counters;
        let in_out = c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0);
        let total = {
            let t = ui::tokens(c.total());
            if c.has_unknown() { format!("{t}+") } else { t }
        };
        let status = if b.active {
            let left = ((b.end_ms - now_ms).max(0) / 60_000) as u64;
            format!("active · {left}m left")
        } else {
            "closed".into()
        };
        let frac = c.total() as f64 / max as f64;
        let mut row = vec![Span::styled(
            format!(
                "{:<22}  {:>8}  {:>8}  {:>9}  {:<18}  ",
                start,
                ui::exact(b.events),
                ui::tokens(in_out),
                total,
                status,
            ),
            if b.active {
                Style::default().fg(ACCENT)
            } else {
                Style::default()
            },
        )];
        row.extend(faded_bar_spans(frac, 12));
        lines.push(Line::from(row));
    }
    lines
}

fn doctor_lines(app: &App) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    lines.push(Line::from(vec![
        Span::styled("Database  ", Style::default().fg(MUTED)),
        Span::raw(app.db_path.display().to_string()),
    ]));
    lines.push(Line::from(vec![
        Span::styled("Events    ", Style::default().fg(MUTED)),
        Span::raw(ui::exact(app.totals.events)),
    ]));
    if let Some(ms) = &app.last_scan {
        let shown = ms
            .parse::<i64>()
            .map(|ts| {
                let age = (jiff::Timestamp::now().as_millisecond() - ts).max(0) / 1000;
                format!("{} ago", format_age_secs(age))
            })
            .unwrap_or_else(|_| ms.clone());
        lines.push(Line::from(vec![
            Span::styled("Last scan ", Style::default().fg(MUTED)),
            Span::raw(shown),
        ]));
    }
    if filter_active(&app.filter) {
        lines.push(Line::from(vec![
            Span::styled("Filter    ", Style::default().fg(MUTED)),
            Span::raw(describe_filter(&app.filter)),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "Confidence",
        Style::default().add_modifier(Modifier::BOLD),
    )));
    if app.confidence.is_empty() {
        lines.push(Line::from(Span::styled(
            "No confidence breakdown yet.",
            Style::default().fg(MUTED),
        )));
    } else {
        for (level, count) in &app.confidence {
            lines.push(Line::from(format!("  {:<16} {}", level, ui::exact(*count))));
        }
    }
    if let Some(rec) = &app.reconciliation {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "Against Claude Code's own rollup",
            Style::default().add_modifier(Modifier::BOLD),
        )));
        lines.push(Line::from(format!(
            "  vendor    {} in+out · {} sessions",
            ui::tokens(rec.vendor_in_out),
            ui::exact(rec.vendor_sessions)
        )));
        lines.push(Line::from(format!(
            "  archive   {} in+out · {} sessions",
            ui::tokens(rec.archive_in_out),
            ui::exact(rec.archive_sessions)
        )));
        if rec.is_significant() {
            lines.push(Line::from(Span::styled(
                format!(
                    "  {} ({:.0}%) missing from surviving transcripts",
                    ui::tokens(rec.missing()),
                    rec.missing_ratio() * 100.0
                ),
                Style::default().fg(Color::Yellow),
            )));
        } else if rec.ahead() > 0 {
            lines.push(Line::from(Span::styled(
                format!(
                    "  archive complete, {} ahead of the rollup",
                    ui::tokens(rec.ahead())
                ),
                Style::default().fg(Color::Green),
            )));
        } else {
            lines.push(Line::from(Span::styled(
                "  archive agrees with the rollup",
                Style::default().fg(Color::Green),
            )));
        }
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "Sources",
        Style::default().add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::from(vec![
        Span::styled("on disk     ", Style::default().fg(MUTED)),
        Span::raw(
            "Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI",
        ),
    ]));
    lines.push(Line::from(vec![
        Span::styled("not local   ", Style::default().fg(MUTED)),
        Span::raw("Cursor (auth) · Antigravity IDE (open app + fetch)"),
    ]));
    lines.push(Line::from(Span::styled(
        "Type /setup to scan, schedule, and link · /sync uploads aggregates",
        Style::default().fg(SECONDARY),
    )));
    if app.empty && !filter_active(&app.filter) {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "Archive is empty. Type /setup or /scan to populate it.",
            Style::default().fg(SECONDARY),
        )));
    }
    lines
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

fn draw_wizard(f: &mut Frame<'_>, area: Rect, app: &App) {
    let Some(wizard) = &app.wizard else {
        return;
    };

    let (title, subtitle, options, step_label) = match wizard {
        Wizard::LoginHost { .. } => (
            " Link tokenstat.ai ",
            "Choose where to sign in. A browser opens with a one-time code.".into(),
            LOGIN_HOSTS
                .iter()
                .map(|(label, about, _)| (*label, *about))
                .collect(),
            None,
        ),
        Wizard::AfterLogin { handle, host, .. } => (
            " Logged in ",
            format!("@{handle} on {host}"),
            AFTER_LOGIN_ACTIONS.to_vec(),
            None,
        ),
        Wizard::Setup { step, .. } => match step {
            SetupStep::Welcome => (
                " Welcome to tokenstat ",
                "Everything stays on this machine until you sync aggregates.".into(),
                SETUP_WELCOME.to_vec(),
                Some((1, 4)),
            ),
            SetupStep::ScanOffer => (
                " Scan local logs ",
                "Read agent session counters into the local archive.".into(),
                vec![
                    ("Scan now", "Discover installed tools and import usage"),
                    ("Skip", "Continue without scanning"),
                ],
                Some((2, 4)),
            ),
            SetupStep::ScheduleOffer => (
                " Keep it current ",
                "Claude Code deletes transcripts after 30 days. A timer prevents that.".into(),
                vec![
                    ("Install hourly scan", "Writes the platform scheduler entry"),
                    ("Skip", "You can run tokenstat schedule --install later"),
                ],
                Some((3, 4)),
            ),
            SetupStep::LoginOffer => (
                " Public profile ",
                "Optional. Only sealed aggregates are eligible for sync.".into(),
                vec![
                    ("Log in", "Device login to tokenstat.ai"),
                    ("Skip", "Stay local for now"),
                ],
                Some((4, 4)),
            ),
        },
    };

    let selected = match wizard {
        Wizard::LoginHost { selected }
        | Wizard::AfterLogin { selected, .. }
        | Wizard::Setup { selected, .. } => *selected,
    };

    let height = (5 + options.len() as u16 + 2).min(area.height.saturating_sub(2));
    let width = area.width.saturating_sub(4).min(72).max(40.min(area.width));
    let popup = centered_rect(width, height, area);
    f.render_widget(Clear, popup);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ))
        .border_style(Style::default().fg(ACCENT));
    let inner = block.inner(popup);
    f.render_widget(block, popup);

    let mut lines: Vec<Line<'static>> = Vec::new();
    if let Some((step, total)) = step_label {
        lines.push(Line::from(Span::styled(
            format!("Step {step} of {total}"),
            Style::default().fg(SECONDARY),
        )));
        lines.push(Line::from(""));
    }
    lines.push(Line::from(Span::styled(
        subtitle,
        Style::default().fg(MUTED),
    )));
    lines.push(Line::from(""));
    for (i, (label, about)) in options.iter().enumerate() {
        let on = i == selected;
        let marker = if on { "› " } else { "  " };
        let label_style = if on {
            Style::default().fg(SELECTED).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(MUTED)
        };
        let about_style = if on {
            Style::default().fg(SECONDARY)
        } else {
            Style::default().fg(MUTED)
        };
        lines.push(Line::from(vec![
            Span::styled(format!("{marker}{label}"), label_style),
            Span::raw("  "),
            Span::styled((*about).to_string(), about_style),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "↑↓ select · Enter confirm · Esc cancel",
        Style::default().fg(MUTED),
    )));

    f.render_widget(Paragraph::new(lines), inner);
}

fn centered_rect(width: u16, height: u16, area: Rect) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    Rect {
        x: area.x + (area.width.saturating_sub(width)) / 2,
        y: area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    }
}

/// Leave the alternate screen so device login can print the code and wait.
fn run_login_outside_tui(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
    host_flag: Option<&str>,
) -> Result<()> {
    disable_raw_mode().context("leaving raw mode for login")?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        crossterm::cursor::Show
    )
    .context("leaving alternate screen for login")?;

    println!();
    println!("  Linking this machine to tokenstat.ai…");
    println!();

    let outcome = tokenstat_sync::login(host_flag);

    println!();
    print!("  Press Enter to return to tokenstat…");
    let _ = io::stdout().flush();
    let mut line = String::new();
    let _ = io::stdin().read_line(&mut line);

    execute!(
        terminal.backend_mut(),
        EnterAlternateScreen,
        crossterm::cursor::Hide
    )
    .context("re-entering alternate screen after login")?;
    enable_raw_mode().context("re-enabling raw mode after login")?;
    terminal.clear().context("clearing terminal after login")?;

    match outcome {
        Ok(result) => {
            app.refresh_sync_hint();
            // Same as CLI login: sync only runs on a schedule once linked.
            let _ = app.install_linked_schedules(host_flag);
            app.status = format!("Logged in as @{} · {}", result.handle, result.host);
            app.wizard = Some(Wizard::AfterLogin {
                handle: result.handle,
                host: result.host,
                selected: 0,
            });
        }
        Err(e) => {
            app.wizard = None;
            app.status = format!("Login failed: {e}");
        }
    }
    Ok(())
}

fn run_sync_inline(app: &mut App, host_flag: Option<&str>) -> Result<()> {
    app.status = "Syncing…".into();
    let store = Store::open(&app.db_path).context("opening archive for sync")?;
    match tokenstat_sync::sync(
        &store,
        tokenstat_sync::SyncOptions {
            host_flag,
            prune: false,
            window: None,
            dry_run: false,
            tz_name: None,
        },
    ) {
        Ok(result) => {
            app.refresh_sync_hint();
            app.status = format!(
                "Synced {} rows to {} · {}..{}",
                result.rows, result.host, result.window.from, result.window.to
            );
        }
        Err(e) => {
            app.status = format!("sync: {e}");
        }
    }
    Ok(())
}

fn format_age_secs(secs: i64) -> String {
    match secs {
        s if s < 60 => format!("{s}s"),
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
