// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! tokenstat command line front end.
//!
//! Argument parsing and output formatting only. Collection, deduplication, and
//! aggregation belong in `tokenstat-core`.

// `unsafe_code` is denied crate-wide; the interactive client is the one place
// that allows it locally, for the libc signal handlers that restore a terminal.
#![deny(unsafe_code)]

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod host_command;
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod host_enroll;
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod host_install;
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod host_rpc;
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod host_service;
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

    #[arg(long, global = true, value_name = "TZ")]
    tz: Option<String>,

    #[arg(long, global = true, value_name = "PATH")]
    db: Option<std::path::PathBuf>,

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
        #[arg(long, short = 'y')]
        yes: bool,
        #[arg(long, value_name = "WXYZ-1234")]
        code: Option<String>,
        #[arg(long, conflicts_with = "code")]
        local_only: bool,
        #[arg(long)]
        no_schedule: bool,
        #[arg(long, value_name = "URL|sandbox|prod")]
        host: Option<String>,
    },
    /// Read new data from your tools into the local archive
    Scan {
        #[arg(long)]
        reset: bool,
        #[arg(long, hide = true)]
        scheduled: bool,
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
        #[arg(long)]
        detail: bool,
    },
    /// Usage per project
    Projects(Window),
    /// Usage per session, busiest first
    Sessions {
        #[command(flatten)]
        window: Window,
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
        #[arg(long, default_value = "{today} today · {month} this month")]
        format: String,
        #[arg(long, default_value_t = 900)]
        max_age: u64,
    },
    /// Set up automatic scanning, so history is not lost to log cleanup
    ///
    /// Prints the scheduler entry by default. Nothing is written unless you
    /// pass --install. Re-running --install repairs a previous install: refreshes
    /// paths and intervals, and removes sync/update entries that no longer belong.
    Schedule {
        #[arg(long)]
        install: bool,
        #[arg(long, default_value_t = 60)]
        every: u64,
        #[arg(long, value_name = "MINUTES")]
        sync_every: Option<u64>,
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
        #[arg(long, default_value = "csv")]
        format: String,
        #[arg(long, value_name = "PATH")]
        out: Option<std::path::PathBuf>,
    },
    /// Validate and emit an interactive chart for a chat reply, without reading the archive
    Chart {
        #[arg(conflicts_with_all = ["schema", "examples"])]
        input: Option<std::path::PathBuf>,
        #[arg(long, conflicts_with = "examples")]
        schema: bool,
        #[arg(long)]
        examples: bool,
    },
    /// MCP server over stdio (local archive only)
    Mcp,
    /// Discover or store the vendor token for Cursor fetches
    ///
    /// This is not tokenstat.ai login. With no `--token`, tokenstat reads the
    /// credential the vendor app already left in the OS keychain (local only).
    /// Pass `--token` to paste a session cookie instead.
    Auth {
        vendor: Option<String>,
        #[arg(long)]
        token: Option<String>,
        #[arg(long, conflicts_with = "token")]
        logout: bool,
        #[arg(long, conflicts_with_all = ["vendor", "token", "logout"])]
        status: bool,
    },
    /// Fetch Cursor usage and Antigravity IDE/quota into the archive (30m cache)
    Fetch {
        #[arg(long)]
        force: bool,
    },
    /// List-rate price book from tokenstat.ai's local snapshot
    Pricing {
        #[arg(long)]
        refresh: bool,
        #[arg(long, requires = "refresh")]
        force: bool,
    },
    /// Model catalog from tokenstat.ai's local snapshot
    ///
    /// Publisher, context window, capabilities, and public benchmark scores for
    /// the models in your archive. Also supplies a marked estimate for models
    /// the list-rate book has never heard of, so they stop showing a dash.
    Catalog {
        #[arg(long)]
        refresh: bool,
    },
    /// Subscription plans from tokenstat.ai's local snapshot
    ///
    /// Product prices, not API list rates, shown next to what your own usage
    /// would have cost per token. Refresh them with `tokenstat catalog --refresh`.
    Plans {
        #[arg(long)]
        vendor: Option<String>,
    },
    /// Soft spend caps against list-rate equivalent value
    ///
    /// Budgets are advisory. Plan usage still shows as list-rate equivalent,
    /// never as money charged. With no flags, prints today's and this month's
    /// status. Use `--daily` / `--monthly` to set caps, or `--clear` to remove.
    Budget {
        #[arg(long, value_name = "USD")]
        daily: Option<f64>,
        #[arg(long, value_name = "USD")]
        monthly: Option<f64>,
        #[arg(long, conflicts_with_all = ["daily", "monthly"])]
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
        #[arg(long)]
        check: bool,
        #[arg(
            long,
            value_name = "on|off",
            value_parser = clap::builder::PossibleValuesParser::new(["on", "off"]),
            conflicts_with_all = ["check", "scheduled"]
        )]
        auto: Option<String>,
        #[arg(long, conflicts_with = "check")]
        scheduled: bool,
    },
    /// Link this machine to a tokenstat.ai account (device login)
    Login {
        #[arg(long, value_name = "URL|sandbox|prod")]
        host: Option<String>,
        #[arg(long, value_name = "WXYZ-1234")]
        code: Option<String>,
    },
    /// Show or set what this machine is called on the account
    ///
    /// A device list of unnamed rows is a list nobody can act on, and a
    /// headless install has no app to rename itself from. With no flags this
    /// prints the name, the platform and the machine id. `--name` writes the
    /// name locally and, when this machine is signed in, on the account.
    Device {
        #[arg(long, value_name = "NAME")]
        name: Option<String>,
        #[arg(long, conflicts_with = "name")]
        clear: bool,
        #[arg(long, value_name = "URL|sandbox|prod")]
        host: Option<String>,
    },
    /// Install and manage the always-on backend for remote workspaces
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    Host(host_command::HostArgs),
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
        #[arg(long)]
        prune: bool,
        #[arg(long, value_name = "FROM..TO")]
        window: Option<String>,
        #[arg(long, conflicts_with_all = ["prune", "window", "dry_run", "scheduled"])]
        status: bool,
        #[arg(long)]
        dry_run: bool,
        #[arg(long, conflicts_with_all = ["prune", "dry_run"])]
        scheduled: bool,
    },
}

#[derive(clap::Args, Clone, Default)]
struct Window {
    #[arg(long, value_name = "DATE")]
    since: Option<String>,
    #[arg(long, value_name = "DATE")]
    until: Option<String>,
    #[arg(long)]
    model: Option<String>,
    #[arg(long)]
    project: Option<String>,
    #[arg(long, value_name = "N", conflicts_with_all = ["since", "until"], value_parser = parse_last)]
    last: Option<u32>,
}

fn parse_last(s: &str) -> Result<u32, String> {
    let n: u32 = s
        .parse()
        .map_err(|_| format!("invalid value {s:?} for --last: expected a positive integer"))?;
    if n == 0 {
        return Err("--last must be > 0".to_string());
    }
    Ok(n)
}

impl Window {
    fn to_query(&self, tz: &jiff::tz::TimeZone) -> Result<Query> {
        let since = match (self.last, &self.since) {
            (Some(n), _) => {
                let today = jiff::Timestamp::now().to_zoned_datetime(tz.clone()).date();
                Some(
                    today
                        .checked_sub(jiff::Span::new().try_days(i64::from(n) - 1)?)
                        .context("--last exceeds the supported date range")?
                        .to_string(),
                )
            }
            (None, s) => s.clone(),
        };
        Ok(Query {
            since,
            until: self.until.clone(),
            model: self.model.clone(),
            project: self.project.clone(),
            billing: None,
            limit: None,
        })
    }
}

fn main() -> Result<()> {
    #[cfg(target_os = "macos")]
    if let Some(code) = tokenstat_sync::quiet_keychain::serve_if_requested() {
        std::process::exit(code.into());
    }
    let cli = Cli::parse();
    if let Some(Command::Chart {
        input,
        schema,
        examples,
    }) = &cli.command
    {
        use std::io::Read;
        let value = if *schema {
            tokenstat_core::chart::schema()
        } else if *examples {
            tokenstat_core::chart::examples()
        } else {
            let mut source = String::new();
            let input = input
                .as_deref()
                .context("Pass a chart JSON file, - for stdin, --schema or --examples")?;
            let reader: Box<dyn Read> = if input == std::path::Path::new("-") {
                Box::new(std::io::stdin())
            } else {
                Box::new(std::fs::File::open(input).context("opening chart JSON")?)
            };
            reader
                .take((tokenstat_core::chart::MAX_BYTES + 1) as u64)
                .read_to_string(&mut source)
                .context("reading chart JSON")?;
            let chart = tokenstat_core::chart::Chart::parse(&source).map_err(anyhow::Error::msg)?;
            if !cli.json {
                println!("{}", chart.fence().map_err(anyhow::Error::msg)?);
                return Ok(());
            }
            serde_json::to_value(chart)?
        };
        println!("{}", serde_json::to_string_pretty(&value)?);
        return Ok(());
    }
    let tz = tokenstat_core::timezone(cli.tz.as_deref())?;
    let db_path = match &cli.db {
        Some(p) => p.clone(),
        None => Store::default_path().context("locating the tokenstat data directory")?,
    };

    let command = cli.command.unwrap_or_else(|| {
        if !cli.json && std::io::stdin().is_terminal() && std::io::stdout().is_terminal() {
            Command::Interactive
        } else {
            Command::Summary(Window::default())
        }
    });

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

    if let Command::Scan { reset, scheduled } = command {
        if scheduled && !tokenstat_sync::scheduled_network_allowed() {
            if cli.json {
                println!(r#"{{"skipped":"asleep"}}"#);
            }
            return Ok(());
        }
        let mut store = Store::open(&db_path)?;
        let report = tokenstat_core::scan_with_reset(&mut store, &tz, reset)?;
        let mut json_report = render::scan_report_value(&report);
        if !cli.json {
            render::scan_report(&report, false)?;
        }
        if !scheduled || tokenstat_sync::scheduled_network_allowed() {
            match tokenstat_sync::fetch_remotes(&mut store, &tz, false) {
                Ok(remote) => {
                    if cli.json {
                        json_report["remote"] = render::fetch_report_values(&remote);
                    } else {
                        render::fetch_reports(&remote, false)?;
                    }
                }
                Err(e) => {
                    if cli.json {
                        json_report["remote_error"] = serde_json::json!(e.to_string());
                    } else {
                        eprintln!("  remote fetch: {e}");
                    }
                }
            }
        }
        if cli.json {
            println!("{json_report}");
        }
        if !scheduled || tokenstat_sync::scheduled_network_allowed() {
            render::maybe_notify_update(cli.json);
        }
        return Ok(());
    }

    if let Command::Fetch { force } = command {
        let mut store = Store::open(&db_path)?;
        let remote = tokenstat_sync::fetch_remotes(&mut store, &tz, force)?;
        render::fetch_reports(&remote, cli.json)?;
        return Ok(());
    }

    if let Command::Mcp = command {
        return tokenstat_mcp::serve(Some(&db_path));
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
        return render::self_update(check, cli.json);
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

    if let Command::Device { name, clear, host } = &command {
        return render::device(host.as_deref(), name.as_deref(), *clear, cli.json);
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
            let mut store = match Store::open(&db_path) {
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
            if tokenstat_sync::scheduled_network_allowed() {
                tokenstat_core::scan_if_stale(&mut store, &tz, tokenstat_core::AUTO_SCAN_INTERVAL)?;
                if !tokenstat_core::archive_is_fresh(&store, tokenstat_core::AUTO_SCAN_INTERVAL)? {
                    if cli.json {
                        println!(r#"{{"skipped":"deferred","reason":"archive scan in progress"}}"#);
                    } else {
                        println!("archive scan in progress, will retry next run");
                    }
                    return Ok(());
                }
            }
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

    if let Command::Statusline { format, max_age } = &command {
        if let Ok(store) = Store::open(&db_path) {
            let _ = render::statusline(&store, &tz, format, *max_age, &db_path, cli.tz.as_deref());
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
        return render::schedule(*install, *every, *sync_every, *no_sync, cli.json);
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    if let Command::Host(args) = &command {
        return host_command::run(args, cli.json);
    }

    if let Command::Interactive = command {
        if cli.json {
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

    if let Command::Doctor = command {
        return render::doctor(&store, &db_path, cli.json);
    }

    let totals = store.totals(&Query::default())?;
    if totals.events == 0 && !matches!(command, Command::Export { .. }) {
        render::empty_archive(cli.json)?;
        return Ok(());
    }

    match command {
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        Command::Host(_) => unreachable!("handled above"),
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
        | Command::Device { .. }
        | Command::Sync { .. }
        | Command::Chart { .. }
        | Command::Mcp => unreachable!("handled above"),
        Command::Daily(w) => {
            render::grouped(&store, GroupBy::Day, &w.to_query(&tz)?, "Date", cli.json)?
        }
        Command::Weekly(w) => {
            render::grouped(&store, GroupBy::Week, &w.to_query(&tz)?, "Week", cli.json)?
        }
        Command::Monthly(w) => render::monthly(&store, &w.to_query(&tz)?, cli.json)?,
        Command::Models { window, detail } => {
            let q = window.to_query(&tz)?;
            if detail {
                render::models_detail(&store, &q, cli.json)?
            } else {
                render::grouped(&store, GroupBy::Model, &q, "Model", cli.json)?
            }
        }
        Command::Projects(w) => render::grouped(
            &store,
            GroupBy::Project,
            &w.to_query(&tz)?,
            "Project",
            cli.json,
        )?,
        Command::Sessions { window, top } => {
            render::sessions(&store, &window.to_query(&tz)?, top, cli.json)?
        }
        Command::Summary(w) => render::overview(&store, &tz, &w.to_query(&tz)?, cli.json)?,
        Command::Heatmap(w) => render::heatmap(&store, &tz, &w.to_query(&tz)?, cli.json)?,
        Command::Wrapped { year } => render::wrapped(&store, &tz, year, cli.json)?,
        Command::Blocks(w) => render::blocks(&store, &tz, &w.to_query(&tz)?, cli.json)?,
        Command::Export {
            window,
            format,
            out,
        } => render::export(
            &store,
            &window.to_query(&tz)?,
            &format,
            out.as_deref(),
            cli.json,
        )?,
        Command::Statusline { .. } | Command::Schedule { .. } => unreachable!("handled above"),
    }
    Ok(())
}

#[cfg(test)]
mod cli_tests {
    use super::*;

    fn parse<I, T>(args: I) -> Result<Cli, clap::Error>
    where
        I: IntoIterator<Item = T>,
        T: Into<std::ffi::OsString> + Clone,
    {
        Cli::try_parse_from(args)
    }

    fn rejects<I, T>(args: I) -> String
    where
        I: IntoIterator<Item = T>,
        T: Into<std::ffi::OsString> + Clone,
    {
        match parse(args) {
            Ok(_) => panic!("expected parse to fail"),
            Err(e) => e.to_string(),
        }
    }

    #[test]
    fn last_defines_its_own_window() {
        assert!(parse(["tokenstat", "daily", "--last", "7"]).is_ok());
        for flag in ["--since", "--until"] {
            let err = rejects(["tokenstat", "daily", "--last", "7", flag, "2026-09-01"]);
            assert!(
                err.contains("cannot be used with"),
                "unexpected error for {flag}: {err}"
            );
        }
    }

    #[test]
    fn ignored_flag_combinations_fail_at_parse() {
        for args in [
            vec!["tokenstat", "pricing", "--force"],
            vec!["tokenstat", "budget", "--clear", "--daily", "5"],
            vec!["tokenstat", "device", "--clear", "--name", "x"],
            vec!["tokenstat", "auth", "--status", "--token", "x"],
            vec!["tokenstat", "auth", "cursor", "--logout", "--token", "x"],
            vec!["tokenstat", "update", "--auto", "on", "--check"],
            vec!["tokenstat", "update", "--scheduled", "--check"],
            vec!["tokenstat", "setup", "--local-only", "--code", "X"],
            vec![
                "tokenstat",
                "sync",
                "--status",
                "--window",
                "2026-01-01..2026-02-01",
            ],
            vec!["tokenstat", "sync", "--scheduled", "--prune"],
        ] {
            let err = rejects(args.clone());
            assert!(
                err.contains("cannot be used with") || err.contains("required arguments"),
                "unexpected error for {args:?}: {err}"
            );
        }
    }

    #[test]
    fn update_takes_only_on_or_off_for_auto_and_no_yes() {
        assert!(parse(["tokenstat", "update", "--auto", "on"]).is_ok());
        assert!(parse(["tokenstat", "update", "--auto", "off"]).is_ok());
        let err = rejects(["tokenstat", "update", "--auto", "maybe"]);
        assert!(err.contains("invalid value"), "unexpected error: {err}");
        let err = rejects(["tokenstat", "update", "--yes"]);
        assert!(
            err.contains("unexpected argument"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn oversized_last_is_an_error_instead_of_panicking_or_removing_the_filter() {
        let window = Window {
            last: Some(u32::MAX),
            ..Window::default()
        };
        assert!(window.to_query(&jiff::tz::TimeZone::UTC).is_err());
    }
}
