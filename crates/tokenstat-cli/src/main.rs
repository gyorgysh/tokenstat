// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! tokenstat command line front end.
//!
//! Argument parsing and output formatting only. Collection, deduplication, and
//! aggregation belong in `tokenstat-core`.

#![forbid(unsafe_code)]

mod interactive;
mod render;
mod schedule;
mod ui;

use std::io::IsTerminal;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use tokenstat_core::{GroupBy, Query, Store};

#[derive(Parser)]
#[command(
    name = "tokenstat",
    version,
    about = "tokenstat.ai: unified token usage stats for AI coding agents",
    long_about = "tokenstat.ai reads the session logs your AI tools already write, deduplicates them,\n\
                  and reports what you actually used.\n\n\
                  Counters stay on your machine unless you opt into sync.",
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Timezone for daily bucketing, for example Europe/Budapest
    #[arg(long, global = true, value_name = "TZ")]
    tz: Option<String>,

    /// Database location
    #[arg(long, global = true, value_name = "PATH")]
    db: Option<std::path::PathBuf>,

    /// Emit JSON instead of a table
    #[arg(long, global = true)]
    json: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Set everything up in one pass: scan, schedule, and optionally an account
    ///
    /// Safe to run again at any time. Each step reports what is already done and
    /// skips it, so this is also the answer to "did that work?".
    Setup {
        /// Take the default for every prompt (yes to scheduling, no to anything
        /// that needs a code you have not given). For install scripts and CI.
        #[arg(long, short = 'y')]
        yes: bool,
        /// Pairing code from tokenstat.ai/link, to connect an account as part of
        /// the run instead of being asked
        #[arg(long, value_name = "WXYZ-1234")]
        code: Option<String>,
        /// Skip the account step entirely
        #[arg(long)]
        local_only: bool,
        /// Skip installing the hourly scan schedule
        #[arg(long)]
        no_schedule: bool,
        /// API origin for the account step: `sandbox`, `prod`, or a URL
        #[arg(long, value_name = "URL|sandbox|prod")]
        host: Option<String>,
    },
    /// Read new data from your tools into the local archive
    Scan {
        /// Discard existing events and rebuild from scratch
        #[arg(long)]
        reset: bool,
    },
    /// Usage per day
    Daily(Window),
    /// Usage per ISO week
    Weekly(Window),
    /// Usage per month
    Monthly(Window),
    /// Usage per model
    Models {
        #[command(flatten)]
        window: Window,
        /// Add what the catalog knows: publisher, context window, capabilities,
        /// and public benchmark scores. Needs `tokenstat catalog --refresh`.
        #[arg(long)]
        detail: bool,
    },
    /// Usage per project
    Projects(Window),
    /// Usage per session, busiest first
    Sessions {
        #[command(flatten)]
        window: Window,
        /// How many sessions to show
        #[arg(long, default_value_t = 20)]
        top: usize,
    },
    /// Headline numbers and an activity grid
    #[command(visible_alias = "overview")]
    Summary(Window),
    /// GitHub-style activity heatmap
    Heatmap(Window),
    /// Year-in-review retrospective from the local archive
    Wrapped {
        /// Calendar year (defaults to the current local year)
        #[arg(long, value_name = "YYYY")]
        year: Option<i32>,
    },
    /// Full-screen interactive client
    ///
    /// Takes over the terminal with tabs for each report, headline stats on
    /// open, and a command field for /scan, /login, and friends.
    Interactive,
    /// One line for a shell prompt or editor status bar
    ///
    /// Reads the archive only. It never scans, so it stays fast enough to run
    /// on every prompt, and it prints nothing rather than an error if there is
    /// no data yet.
    Statusline {
        /// Placeholders: {today}, {month}, {today_value}, {month_value},
        /// {today_in_out}, {month_in_out}, {stale}
        #[arg(long, default_value = "{today} today · {month} this month")]
        format: String,
        /// Append a marker when the archive was last scanned longer ago than
        /// this many seconds. 0 disables the check. When stale, a background
        /// `tokenstat scan` is started behind a lock (statusline itself stays
        /// archive-only and never waits on the network).
        #[arg(long, default_value_t = 900)]
        max_age: u64,
    },
    /// Set up automatic scanning, so history is not lost to log cleanup
    ///
    /// Prints the scheduler entry by default. Nothing is written unless you
    /// pass --install. Re-running --install repairs a previous install: refreshes
    /// paths and intervals, and removes sync/update entries that no longer belong.
    Schedule {
        /// Write and activate the scheduler entry for this platform
        #[arg(long)]
        install: bool,
        /// How often to scan, in minutes
        #[arg(long, default_value_t = 60)]
        every: u64,
        /// How often to sync, in minutes. Defaults to your plan's interval.
        #[arg(long, value_name = "MINUTES")]
        sync_every: Option<u64>,
        /// Only schedule scanning, even when an account is linked
        #[arg(long)]
        no_sync: bool,
    },
    /// Check the archive and report anything suspicious
    Doctor,
    /// Usage in 5 hour blocks (Claude-style rate-limit windows)
    Blocks(Window),
    /// Write events to CSV or JSON (counters and ids only)
    Export {
        #[command(flatten)]
        window: Window,
        /// csv or json
        #[arg(long, default_value = "csv")]
        format: String,
        /// Write to this path instead of stdout
        #[arg(long, value_name = "PATH")]
        out: Option<std::path::PathBuf>,
    },
    /// MCP server over stdio (local archive only)
    Mcp,
    /// Discover or store a vendor token for Cursor / Antigravity fetches
    ///
    /// This is not tokenstat.ai login. With no `--token`, tokenstat reads the
    /// credential the vendor app already left in the OS keychain (local only).
    /// Pass `--token` to paste a session cookie instead.
    Auth {
        /// cursor or antigravity (optional with --status)
        vendor: Option<String>,
        /// Optional paste. If omitted, discover from the vendor app keychain.
        #[arg(long)]
        token: Option<String>,
        /// Forget the stored token
        #[arg(long)]
        logout: bool,
        /// Show whether tokens are available (no secrets printed)
        #[arg(long)]
        status: bool,
    },
    /// Fetch Cursor usage and Antigravity IDE/quota into the archive (30m cache)
    Fetch {
        /// Ignore the cache and hit the network
        #[arg(long)]
        force: bool,
    },
    /// List-rate price book from tokenstat.ai's local snapshot
    Pricing {
        /// Download a fresh snapshot into the local data directory
        #[arg(long)]
        refresh: bool,
        /// Accept rate moves greater than 50% vs the prior snapshot
        #[arg(long)]
        force: bool,
    },
    /// Model catalog from tokenstat.ai's local snapshot
    ///
    /// Publisher, context window, capabilities, and public benchmark scores for
    /// the models in your archive. Also supplies a marked estimate for models
    /// the list-rate book has never heard of, so they stop showing a dash.
    Catalog {
        /// Download fresh catalog and plans snapshots into the data directory
        #[arg(long)]
        refresh: bool,
    },
    /// Subscription plans from tokenstat.ai's local snapshot
    ///
    /// Product prices, not API list rates, shown next to what your own usage
    /// would have cost per token. Refresh them with `tokenstat catalog --refresh`.
    Plans {
        /// Only plans from this vendor, for example `anthropic`
        #[arg(long)]
        vendor: Option<String>,
    },
    /// Soft spend caps against list-rate equivalent value
    ///
    /// Budgets are advisory. Plan usage still shows as list-rate equivalent,
    /// never as money charged. With no flags, prints today's and this month's
    /// status. Use `--daily` / `--monthly` to set caps, or `--clear` to remove.
    Budget {
        /// Daily cap in USD list-rate equivalent
        #[arg(long, value_name = "USD")]
        daily: Option<f64>,
        /// Monthly cap in USD list-rate equivalent
        #[arg(long, value_name = "USD")]
        monthly: Option<f64>,
        /// Remove all budget caps
        #[arg(long)]
        clear: bool,
    },
    /// Check GitHub Releases and optionally replace this binary
    ///
    /// Verifies SHA-256 against the release `SHA256SUMS`, then runs the
    /// downloaded binary and checks its version before letting it replace this
    /// one. If the new binary cannot run from its final path, the previous one is
    /// put back. Refuses to overwrite cargo or system installs. With no flags,
    /// downloads and applies when a newer version exists. Use `--check` to only
    /// report.
    Update {
        /// Report only; do not download
        #[arg(long)]
        check: bool,
        /// Apply even when automatic updates are off (same as a plain `update`)
        #[arg(long)]
        yes: bool,
        /// Turn automatic daily updates on or off (default on; `--auto off` opts
        /// out and removes the daily schedule entry)
        #[arg(long, value_name = "on|off")]
        auto: Option<String>,
        /// Run as a background job: wait a spread-out delay, skip when the user
        /// opted out, and stay quiet about it
        #[arg(long)]
        scheduled: bool,
    },
    /// Link this machine to a tokenstat.ai account (device login)
    Login {
        /// API origin: `sandbox`, `prod`, or an absolute http(s) URL
        #[arg(long, value_name = "URL|sandbox|prod")]
        host: Option<String>,
        /// Redeem a pairing code from tokenstat.ai/link instead of opening a
        /// browser. The site shows the whole line to paste.
        #[arg(long, value_name = "WXYZ-1234")]
        code: Option<String>,
    },
    /// Forget the tokenstat.ai sync token for a host (no server call)
    Logout {
        #[arg(long, value_name = "URL|sandbox|prod")]
        host: Option<String>,
    },
    /// Upload aggregate day × source × model counts to tokenstat.ai
    ///
    /// Opt in only. Payload is counters, public model ids, and salted project
    /// digests. Sessions, paths, and prompts stay on the machine.
    Sync {
        #[arg(long, value_name = "URL|sandbox|prod")]
        host: Option<String>,
        /// Allow the server to accept a replace that would drop data
        #[arg(long)]
        prune: bool,
        /// Inclusive window `YYYY-MM-DD..YYYY-MM-DD`
        #[arg(long, value_name = "FROM..TO")]
        window: Option<String>,
        /// Print account status (`GET /api/v1/me`) instead of uploading
        #[arg(long)]
        status: bool,
        /// Print the canonical JSON payload and exit without uploading
        #[arg(long)]
        dry_run: bool,
        /// Run as a background job: wait a short spread-out delay, skip the run
        /// when the plan's interval has not elapsed, and stay quiet about both.
        #[arg(long)]
        scheduled: bool,
    },
}

#[derive(clap::Args, Clone, Default)]
struct Window {
    /// Earliest date to include, YYYY-MM-DD
    #[arg(long, value_name = "DATE")]
    since: Option<String>,
    /// Latest date to include, YYYY-MM-DD
    #[arg(long, value_name = "DATE")]
    until: Option<String>,
    /// Only this model
    #[arg(long)]
    model: Option<String>,
    /// Only this project
    #[arg(long)]
    project: Option<String>,
    /// Only the last N days
    #[arg(long, value_name = "N", conflicts_with = "since")]
    last: Option<u32>,
}

impl Window {
    fn to_query(&self, tz: &jiff::tz::TimeZone) -> Query {
        let since = match (self.last, &self.since) {
            (Some(n), _) => {
                let today = jiff::Timestamp::now().to_zoned(tz.clone()).date();
                today
                    .checked_sub(jiff::Span::new().days(i64::from(n) - 1))
                    .ok()
                    .map(|d| d.to_string())
            }
            (None, s) => s.clone(),
        };
        Query {
            since,
            until: self.until.clone(),
            model: self.model.clone(),
            project: self.project.clone(),
            billing: None,
            limit: None,
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let tz = tokenstat_core::timezone(cli.tz.as_deref())?;
    let db_path = match &cli.db {
        Some(p) => p.clone(),
        None => Store::default_path().context("locating the tokenstat data directory")?,
    };

    // Bare `tokenstat` enters the interactive client on a TTY. Piped, scripted,
    // or `--json` use gets the one-shot summary, so machine-readable output
    // never takes over the terminal.
    let command = cli.command.unwrap_or_else(|| {
        if !cli.json && std::io::stdin().is_terminal() && std::io::stdout().is_terminal() {
            Command::Interactive
        } else {
            Command::Summary(Window::default())
        }
    });

    // Scan owns the write path, everything else only reads.
    if let Command::Setup {
        yes,
        ref code,
        local_only,
        no_schedule,
        ref host,
    } = command
    {
        return render::setup(
            &db_path,
            &tz,
            render::SetupOptions {
                yes,
                code: code.as_deref(),
                local_only,
                no_schedule,
                host: host.as_deref(),
                json: cli.json,
            },
        );
    }

    if let Command::Scan { reset } = command {
        let mut store = Store::open(&db_path)?;
        if reset {
            store.clear_events()?;
            store.clear_watermarks()?;
        }
        let report = tokenstat_core::scan(&mut store, &tz)?;
        render::scan_report(&report, cli.json)?;
        // Cursor and Antigravity IDE/quota use a 30 minute cache. IDE sync only
        // works while the Antigravity app is open. Soft-fails per vendor.
        match tokenstat_sync::fetch_remotes(&mut store, &tz, false) {
            Ok(remote) => render::fetch_reports(&remote, cli.json)?,
            Err(e) => {
                eprintln!("  remote fetch: {e}");
            }
        }
        // Soft update check (24h TTL). Applies when auto-update is on (default).
        render::maybe_notify_update(cli.json);
        return Ok(());
    }

    if let Command::Fetch { force } = command {
        let mut store = Store::open(&db_path)?;
        let remote = tokenstat_sync::fetch_remotes(&mut store, &tz, force)?;
        render::fetch_reports(&remote, cli.json)?;
        return Ok(());
    }

    if let Command::Mcp = command {
        return tokenstat_mcp::serve();
    }

    if let Command::Pricing { refresh, force } = command {
        return render::pricing(refresh, force, cli.json);
    }

    if let Command::Catalog { refresh } = command {
        return render::catalog(refresh, cli.json);
    }

    if let Command::Plans { ref vendor } = command {
        let store = Store::open(&db_path)?;
        return render::plans(&store, &tz, vendor.as_deref(), cli.json);
    }

    if let Command::Budget {
        daily,
        monthly,
        clear,
    } = command
    {
        let store = Store::open(&db_path)?;
        return render::budget(&store, &tz, daily, monthly, clear, cli.json);
    }

    if let Command::Update {
        check,
        yes,
        ref auto,
        scheduled,
    } = command
    {
        if let Some(auto) = auto {
            return render::update_auto(auto, cli.json);
        }
        if scheduled {
            return render::self_update_scheduled(cli.json);
        }
        return render::self_update(check, yes, cli.json);
    }

    if let Command::Auth {
        vendor,
        token,
        logout,
        status,
    } = &command
    {
        return render::auth(
            vendor.as_deref(),
            token.as_deref(),
            *logout,
            *status,
            cli.json,
        );
    }

    if let Command::Login { host, code } = &command {
        if let Some(code) = code {
            return render::profile_login_code(host.as_deref(), code, cli.json);
        }
        return render::profile_login(host.as_deref(), cli.json);
    }

    if let Command::Logout { host } = &command {
        return render::profile_logout(host.as_deref(), cli.json);
    }

    if let Command::Sync {
        host,
        prune,
        window,
        status,
        dry_run,
        scheduled,
    } = &command
    {
        if *status {
            return render::profile_sync_status(host.as_deref(), cli.json);
        }
        if *scheduled {
            let store = match Store::open(&db_path) {
                Ok(s) => s,
                Err(e) if e.is_busy() => {
                    if cli.json {
                        println!(r#"{{"skipped":"deferred","reason":"archive busy"}}"#);
                    } else {
                        println!("archive busy, will retry next run");
                    }
                    return Ok(());
                }
                Err(e) => return Err(e.into()),
            };
            return render::profile_sync_scheduled(
                &store,
                host.as_deref(),
                window.as_deref(),
                cli.tz.as_deref(),
                cli.json,
            );
        }
        let store = Store::open(&db_path)?;
        return render::profile_sync(
            &store,
            host.as_deref(),
            *prune,
            window.as_deref(),
            *dry_run,
            cli.tz.as_deref(),
            cli.json,
        );
    }

    // A statusline must never break a shell prompt. Any failure, including a
    // missing database on a fresh install, exits quietly with no output.
    if let Command::Statusline { format, max_age } = &command {
        if let Ok(store) = Store::open(&db_path) {
            let _ = render::statusline(&store, &tz, format, *max_age);
        }
        return Ok(());
    }

    if let Command::Schedule {
        install,
        every,
        sync_every,
        no_sync,
    } = &command
    {
        return render::schedule(*install, *every, *sync_every, *no_sync);
    }

    if let Command::Interactive = command {
        if cli.json {
            // `--json interactive` must stay machine-readable, never take over
            // the TTY. Same path as bare `tokenstat --json`.
            let store = Store::open(&db_path)?;
            let totals = store.totals(&Query::default())?;
            if totals.events == 0 {
                render::empty_archive(true)?;
                return Ok(());
            }
            return render::overview(&store, &tz, &Query::default(), true);
        }
        return interactive::run(&db_path, &tz);
    }

    let store = Store::open(&db_path)?;

    // Doctor always runs, including on an empty archive, so a fresh install
    // still gets source coverage and a clear next step.
    if let Command::Doctor = command {
        return render::doctor(&store, &db_path, cli.json);
    }

    let totals = store.totals(&Query::default())?;
    if totals.events == 0 {
        render::empty_archive(cli.json)?;
        return Ok(());
    }

    match command {
        Command::Setup { .. }
        | Command::Scan { .. }
        | Command::Interactive
        | Command::Doctor
        | Command::Fetch { .. }
        | Command::Auth { .. }
        | Command::Pricing { .. }
        | Command::Catalog { .. }
        | Command::Plans { .. }
        | Command::Budget { .. }
        | Command::Update { .. }
        | Command::Login { .. }
        | Command::Logout { .. }
        | Command::Sync { .. }
        | Command::Mcp => unreachable!("handled above"),
        Command::Daily(w) => {
            render::grouped(&store, GroupBy::Day, &w.to_query(&tz), "Date", cli.json)?
        }
        Command::Weekly(w) => {
            render::grouped(&store, GroupBy::Week, &w.to_query(&tz), "Week", cli.json)?
        }
        Command::Monthly(w) => render::monthly(&store, &w.to_query(&tz), cli.json)?,
        Command::Models { window, detail } => {
            let q = window.to_query(&tz);
            if detail {
                render::models_detail(&store, &q, cli.json)?
            } else {
                render::grouped(&store, GroupBy::Model, &q, "Model", cli.json)?
            }
        }
        Command::Projects(w) => render::grouped(
            &store,
            GroupBy::Project,
            &w.to_query(&tz),
            "Project",
            cli.json,
        )?,
        Command::Sessions { window, top } => {
            render::sessions(&store, &window.to_query(&tz), top, cli.json)?
        }
        Command::Summary(w) => render::overview(&store, &tz, &w.to_query(&tz), cli.json)?,
        Command::Heatmap(w) => render::heatmap(&store, &tz, &w.to_query(&tz), cli.json)?,
        Command::Wrapped { year } => render::wrapped(&store, &tz, year, cli.json)?,
        Command::Blocks(w) => render::blocks(&store, &w.to_query(&tz), cli.json)?,
        Command::Export {
            window,
            format,
            out,
        } => render::export(
            &store,
            &window.to_query(&tz),
            &format,
            out.as_deref(),
            cli.json,
        )?,
        Command::Statusline { .. } | Command::Schedule { .. } => unreachable!("handled above"),
    }
    Ok(())
}
