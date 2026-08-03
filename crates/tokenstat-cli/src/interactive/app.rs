use std::path::Path;

use anyhow::{Context, Result};
use jiff::tz::TimeZone;
use tokenstat_core::{GroupBy, Query, Store, Totals};

use super::*;

impl App {
    pub(super) fn load(db_path: &Path, tz: &TimeZone) -> Result<Self> {
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
            detail: None,
            pending_login_host: None,
            pending_sync_host: None,
            summary_models_expanded: false,
            sync_hint: None,
            pending_sync: None,
            prices: PriceTable::load_with_catalog(),
            dirty: true,
        };
        app.reload(&store)?;
        app.refresh_sync_hint();
        Ok(app)
    }

    /// Re-read local sync pacing for the status bar without a network call.
    pub(super) fn refresh_sync_hint(&mut self) {
        self.sync_hint = tokenstat_sync::scheduling_info(None)
            .ok()
            .filter(|i| i.logged_in)
            .map(|i| format_sync_hint(&i));
    }

    pub(super) fn reload(&mut self, store: &Store) -> Result<()> {
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

    pub(super) fn run_scan(&mut self, reset: bool) -> Result<()> {
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
    pub(super) fn install_scan_schedule(&mut self) -> Result<()> {
        use crate::schedule::{Unit, install};

        let home = directories::BaseDirs::new()
            .map(|d| d.home_dir().to_path_buf())
            .context("locating your home directory")?;
        let exe = crate::schedule::preferred_executable();
        install(&home, Unit::Scan, &exe, Unit::Scan.default_interval())?;
        self.status = "Installed hourly scan schedule".into();
        Ok(())
    }

    pub(super) fn install_linked_schedules(&mut self, host_flag: Option<&str>) -> Result<()> {
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
    pub(super) fn showing_suggestions(&self) -> bool {
        // Keep the catalog out of the way while browsing tabs. As soon as the
        // user types, filter and show name + description prominently.
        let trimmed = self.input.trim();
        !trimmed.is_empty() && !trimmed.contains(' ')
    }

    pub(super) fn filtered_commands(&self) -> Vec<&'static CommandDef> {
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

    pub(super) fn clamp_suggest(&mut self) {
        let n = self.filtered_commands().len();
        if n == 0 {
            self.suggest_idx = 0;
        } else {
            self.suggest_idx = self.suggest_idx.min(n - 1);
        }
    }

    pub(super) fn apply_suggestion(&mut self) {
        let cmds = self.filtered_commands();
        if let Some(cmd) = cmds.get(self.suggest_idx) {
            self.input = format!("/{}", cmd.name);
            self.cursor = self.input.len();
            self.suggest_idx = 0;
        }
    }

    pub(super) fn submit_input(&mut self) -> Result<()> {
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
                self.open_detail(DetailKind::Heatmap)?;
            }
            "wrapped" => {
                let year = args
                    .first()
                    .and_then(|s| s.parse::<i32>().ok())
                    .unwrap_or_else(|| {
                        i32::from(
                            jiff::Timestamp::now()
                                .to_zoned(self.tz.clone())
                                .date()
                                .year(),
                        )
                    });
                self.open_detail(DetailKind::Wrapped { year })?;
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
                self.open_detail(DetailKind::Budget)?;
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
                    start_sync(self, flag.as_deref());
                }
            }
            "quit" | "exit" | "q" => self.should_quit = true,
            other => {
                self.status = format!("Unknown command: {other}. Type / for the list");
            }
        }
        Ok(())
    }

    pub(super) fn history_prev(&mut self) {
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

    pub(super) fn history_next(&mut self) {
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

    pub(super) fn toggle_chrono_sort(&mut self) {
        self.chrono_newest_first = !self.chrono_newest_first;
        self.scroll = 0;
        self.status = if self.chrono_newest_first {
            "Newest first".into()
        } else {
            "Oldest first".into()
        };
    }

    pub(super) fn apply_filter_args(&mut self, args: &[&str]) -> Result<()> {
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

    /// Open a read-only report window (heatmap / wrapped / budget). Contents
    /// are computed once here; the draw loop only renders and scrolls them.
    pub(super) fn open_detail(&mut self, kind: DetailKind) -> Result<()> {
        self.wizard = None;
        let store = Store::open(&self.db_path)?;
        let (width, lines) = match kind {
            DetailKind::Heatmap => {
                let width = crossterm::terminal::size()
                    .map(|(w, _)| w)
                    .unwrap_or(120)
                    .min(110);
                (width, heatmap_detail_lines(self, width))
            }
            DetailKind::Wrapped { year } => {
                let lines = wrapped_detail_lines(&store, &self.tz, &self.prices, year, 80)?;
                (80, lines)
            }
            DetailKind::Budget => {
                let lines = budget_detail_lines(&store, &self.tz, &self.prices)?;
                (72, lines)
            }
        };
        self.detail = Some(Detail {
            lines,
            width,
            scroll: 0,
        });
        Ok(())
    }

    pub(super) fn insert_char(&mut self, c: char) {
        self.input.insert(self.cursor, c);
        self.cursor += c.len_utf8();
        self.suggest_idx = 0;
        self.clamp_suggest();
    }

    pub(super) fn backspace(&mut self) {
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

    pub(super) fn move_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
    }

    pub(super) fn move_right(&mut self) {
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
