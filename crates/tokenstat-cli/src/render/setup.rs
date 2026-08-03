use std::path::Path;

use anstream::println;
use anyhow::{Context, Result};
use tokenstat_core::{Query, Store};

use super::reference::fetch_reference_data;
use super::*;
use crate::ui::{self, BOLD, DIM, accent, good};

pub struct SetupOptions<'a> {
    pub yes: bool,
    pub code: Option<&'a str>,
    pub local_only: bool,
    pub no_schedule: bool,
    pub host: Option<&'a str>,
    pub json: bool,
}

/// Ask a yes/no question, defaulting to yes.
///
/// Running `setup` is itself the request, so the default is yes and a non-tty
/// proceeds rather than skipping: piping this into a shell is how install scripts
/// call it, and a no-op would make the command useless there. The prompt exists to
/// give someone at a keyboard a chance to decline a step, not to re-ask whether
/// they meant to run the command they just ran.
fn confirm(question: &str, assume_yes: bool) -> bool {
    use std::io::{IsTerminal, Write};
    if assume_yes || !std::io::stdin().is_terminal() {
        return true;
    }
    let a = accent();
    print!("  {question} {a}[Y/n]{a:#} ");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line).is_err() {
        return true;
    }
    !matches!(line.trim().to_ascii_lowercase().as_str(), "n" | "no")
}

/// One command that gets someone from "installed" to "it is working".
///
/// The steps already existed as separate commands, which is the problem: nothing
/// told you the order, that scanning early matters, or that syncing is a thing you
/// opt into. Re-runnable, and each step says when it has nothing to do, so this is
/// also a reasonable answer to "is my setup right?".
///
/// One question, at the start, then it gets on with it. Asking before every step
/// turned a setup command into an interrogation where the answer was always going
/// to be yes: running `setup` IS the decision. `--yes` skips even that question.
pub fn setup(db_path: &Path, tz: &jiff::tz::TimeZone, opts: SetupOptions<'_>) -> Result<()> {
    use crate::schedule::Unit;

    let g = good();
    let a = accent();
    if !opts.json {
        println!();
        println!("  {BOLD}Setting up tokenstat{BOLD:#}");
        println!(
            "  {DIM}Three things: read the logs your AI tools already write, install an{DIM:#}"
        );
        println!(
            "  {DIM}hourly scan so log cleanup cannot take your history, and connect a{DIM:#}"
        );
        println!(
            "  {DIM}tokenstat.ai account (a browser opens for that; --local-only skips it).{DIM:#}"
        );
        println!();
    }
    if !confirm("Go ahead?", opts.yes) {
        if !opts.json {
            println!();
            println!("  {DIM}Stopped. Nothing was changed.{DIM:#}");
            println!();
        }
        return Ok(());
    }
    if !opts.json {
        println!();
    }

    // 1. Scan. First because it is the thing with a deadline: Claude Code deletes
    // transcripts after 30 days, so every day spent deciding costs history.
    let mut store = Store::open(db_path)?;
    let report = tokenstat_core::scan(&mut store, tz)?;
    if !opts.json {
        println!("  {g}1{g:#} Read your existing logs");
    }
    scan_report(&report, opts.json)?;

    let totals = store.totals(&Query::default())?;
    if !opts.json {
        if totals.events == 0 {
            println!("  {DIM}No usage found yet. That is normal on a machine that has not{DIM:#}");
            println!("  {DIM}run an AI coding tool. Run this again once it has.{DIM:#}");
        } else {
            println!(
                "  {DIM}{} events across {} active days are now archived{DIM:#}",
                ui::exact(totals.events),
                ui::exact(totals.days)
            );
        }
    }

    // Prices, still inside step 1: without them every dollar column is a dash,
    // and a first run that reports no cost at all reads as a broken install.
    // Soft-failing is deliberate. An offline machine should still finish setup
    // with a working archive, and both snapshots can be fetched later.
    fetch_reference_data(opts.json);
    if !opts.json {
        println!();
    }

    // 2. Schedule. The whole point of the archive is that it outlives the logs.
    let scheduled = if opts.no_schedule {
        if !opts.json {
            println!("  {g}2{g:#} Keep it current");
            println!("  {DIM}skipped schedule (--no-schedule){DIM:#}");
            println!();
        }
        false
    } else {
        if !opts.json {
            println!("  {g}2{g:#} Keep it current");
            println!(
                "  {DIM}A scheduled scan is what stops the next cleanup losing a month.{DIM:#}"
            );
        }
        // No second question: the one at the top covered it.
        // Scan only here so a failed login still leaves the archive catching up.
        // After the account step we run `repair`, which refreshes every unit and
        // drops a stale sync/update left by an older install.
        let installed = {
            let home = directories::BaseDirs::new()
                .map(|d| d.home_dir().to_path_buf())
                .context("locating your home directory")?;
            let exe = crate::schedule::preferred_executable();
            match crate::schedule::install(&home, Unit::Scan, &exe, Unit::Scan.default_interval()) {
                Ok(_) => {
                    if !opts.json {
                        println!("  {g}installed{g:#} hourly scan");
                    }
                    true
                }
                Err(e) => {
                    if !opts.json {
                        println!("  {DIM}could not install the schedule: {e}{DIM:#}");
                        println!("  {DIM}run later with: tokenstat schedule --install{DIM:#}");
                    }
                    false
                }
            }
        };
        if !opts.json {
            println!();
        }
        installed
    };

    // 3. Account. Connecting one is a large part of why this command exists, so it
    // offers to do it rather than printing two commands and stopping. A pairing
    // code does it without a browser; otherwise the device flow runs here.
    let mut connected = false;
    if !opts.local_only {
        let info = tokenstat_sync::scheduling_info(opts.host).ok();
        let already = info.as_ref().is_some_and(|i| i.logged_in);
        if !opts.json {
            println!("  {g}3{g:#} Connect an account (optional)");
        }
        if already {
            connected = true;
            if !opts.json {
                println!(
                    "  {DIM}already connected for {}{DIM:#}",
                    info.as_ref()
                        .map(|i| i.host.as_str())
                        .unwrap_or("this host")
                );
            }
        } else if let Some(code) = opts.code {
            match tokenstat_sync::login_with_code(opts.host, code) {
                Ok(res) => {
                    connected = true;
                    if !opts.json {
                        println!("  {g}connected{g:#} as {BOLD}@{}{BOLD:#}", res.handle);
                    }
                }
                Err(e) => {
                    if !opts.json {
                        println!("  {DIM}pairing failed: {e}{DIM:#}");
                    }
                }
            }
        } else {
            // The device flow needs a browser and a person, so it is offered only
            // where both can exist. Starting it into a pipe would leave the process
            // waiting fifteen minutes for an approval nobody is there to give.
            let interactive = std::io::IsTerminal::is_terminal(&std::io::stdin());
            if !opts.json {
                println!("  {DIM}Counters only, and nothing is published until you ask.{DIM:#}");
            }
            if interactive {
                match tokenstat_sync::login(opts.host) {
                    Ok(res) => {
                        connected = true;
                        println!("  {g}connected{g:#} as {BOLD}@{}{BOLD:#}", res.handle);
                    }
                    Err(e) => {
                        println!("  {DIM}not connected: {e}{DIM:#}");
                        println!("  {DIM}try again later with: tokenstat login{DIM:#}");
                    }
                }
            } else if !opts.json {
                println!("  {DIM}Two ways in, whenever you want one:{DIM:#}");
                println!(
                    "    {a}tokenstat login{a:#}                    {DIM}opens a browser{DIM:#}"
                );
                println!(
                    "    {a}tokenstat setup --code WXYZ-1234{a:#}   {DIM}code from tokenstat.ai/link{DIM:#}"
                );
            }
        }
        if !opts.json {
            println!();
        }
    }

    // 4. Repair the full schedule layout, then first sync when there is an account.
    // Re-running setup / the website installer refreshes paths and intervals.
    // Sync is only installed when linked; if not linked yet, an existing sync
    // unit is left alone so logout does not undo install-and-forget.
    let mut sync_scheduled = false;
    if !opts.no_schedule {
        let home = directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf());
        let exe = crate::schedule::preferred_executable();
        if let Some(home) = home {
            let sync_interval = tokenstat_sync::scheduling_info(opts.host)
                .ok()
                .and_then(|i| i.min_interval)
                .unwrap_or_else(|| Unit::Sync.default_interval());
            let want_update = tokenstat_sync::auto_apply_enabled();
            let sync_action = if connected {
                crate::schedule::SyncAction::Install(sync_interval)
            } else {
                crate::schedule::SyncAction::Keep
            };
            match crate::schedule::repair(
                &home,
                &exe,
                Unit::Scan.default_interval(),
                sync_action,
                want_update,
            ) {
                Ok(report) => {
                    sync_scheduled = report.sync.is_some();
                    if !opts.json {
                        if let Some(secs) = report.sync_interval_secs {
                            println!(
                                "  {g}installed{g:#} sync every {} min {DIM}(+ up to {}s jitter){DIM:#}",
                                secs / 60,
                                tokenstat_sync::JITTER_WINDOW_SECS
                            );
                        }
                        if report.update.is_some() {
                            println!("  {g}installed{g:#} daily update check");
                        } else if report.update_removed {
                            println!("  {g}removed{g:#} stale update schedule");
                        }
                        if sync_scheduled || report.update_removed {
                            println!();
                        }
                    }
                }
                Err(e) => {
                    if !opts.json {
                        println!("  {DIM}could not repair schedule: {e}{DIM:#}");
                        println!("  {DIM}run later with: tokenstat schedule --install{DIM:#}");
                        println!();
                    }
                }
            }
        }
    }

    if connected && totals.events > 0 {
        match tokenstat_sync::sync(
            &store,
            tokenstat_sync::SyncOptions {
                host_flag: opts.host,
                prune: false,
                window: None,
                dry_run: false,
                tz_name: None,
            },
        ) {
            Ok(res) => {
                if !opts.json {
                    println!("  {g}4{g:#} Sent the first window");
                    println!(
                        "  {DIM}{} rows, {}..{}{DIM:#}",
                        ui::exact(res.rows),
                        res.window.from,
                        res.window.to
                    );
                    println!();
                }
            }
            Err(e) => {
                if !opts.json {
                    println!("  {g}4{g:#} First sync");
                    println!("  {DIM}not sent: {e}{DIM:#}");
                    println!();
                }
            }
        }
    }

    if opts.json {
        println!(
            r#"{{"events":{},"active_days":{},"scheduled":{},"connected":{}}}"#,
            totals.events, totals.days, scheduled, connected
        );
        return Ok(());
    }

    println!("  {BOLD}Done.{BOLD:#} Try {a}tokenstat{a:#} for the full-screen view,");
    println!("  or {a}tokenstat summary{a:#} for one screen of numbers.");
    if connected {
        if sync_scheduled {
            println!("  {DIM}Your account updates on its own from here.{DIM:#}");
        } else {
            println!(
                "  {DIM}To keep the profile current: {DIM:#}{a}tokenstat schedule --install{a:#}"
            );
        }
    }
    println!();
    Ok(())
}

/// Show, or install, the scheduler entry that keeps the archive current.
pub fn schedule(
    install: bool,
    every_mins: u64,
    sync_every_mins: Option<u64>,
    no_sync: bool,
) -> Result<()> {
    use crate::schedule::{self as sched, Platform, Unit};

    let exe = sched::preferred_executable();
    let interval = every_mins.max(1) * 60;
    let platform = Platform::detect();

    // The sync unit is only worth installing for an account, and its cadence is
    // the plan's, not a number the user should have to know. An explicit
    // --sync-every still wins, for testing against a sandbox.
    let info = tokenstat_sync::scheduling_info(None).ok();
    let want_sync = !no_sync && info.as_ref().is_some_and(|i| i.logged_in);
    let sync_interval = match sync_every_mins {
        Some(m) => m.max(1) * 60,
        None => info
            .as_ref()
            .and_then(|i| i.min_interval)
            .unwrap_or_else(|| Unit::Sync.default_interval()),
    };
    // Default on. Opt out with `tokenstat update --auto off` (removes the unit).
    let want_update = tokenstat_sync::auto_apply_enabled();
    let update_interval = Unit::Update.default_interval();

    if install {
        let home = directories::BaseDirs::new()
            .map(|d| d.home_dir().to_path_buf())
            .context("locating your home directory")?;
        let g = good();
        println!();

        if want_update {
            // Scheduler does not inherit TOKENSTAT_AUTO_UPDATE. Persist on so the
            // daily unit matches what we are about to install.
            if tokenstat_sync::config::load()
                .ok()
                .and_then(|c| c.update.auto)
                != Some(true)
            {
                let _ = tokenstat_sync::config::set_update_auto(true);
            }
        }

        let sync_action = if want_sync {
            sched::SyncAction::Install(sync_interval)
        } else if no_sync {
            sched::SyncAction::Remove
        } else {
            // Not linked: leave an existing sync unit alone so logout does not
            // undo install-and-forget. It will no-op until the next login.
            sched::SyncAction::Keep
        };
        let report = sched::repair(&home, &exe, interval, sync_action, want_update)?;

        if let Some(report) = &report.scan {
            println!("  {g}Installed{g:#} scan every {every_mins} min");
            for path in &report.paths {
                println!("  {DIM}{}{DIM:#}", path.display());
            }
            if let Some(hint) = &report.hint {
                println!("  {DIM}{hint}{DIM:#}");
            }
        }

        if let Some(report) = &report.sync {
            println!();
            println!(
                "  {g}Installed{g:#} sync every {} min {DIM}(+ up to {}s jitter){DIM:#}",
                sync_interval / 60,
                tokenstat_sync::JITTER_WINDOW_SECS
            );
            for path in &report.paths {
                println!("  {DIM}{}{DIM:#}", path.display());
            }
            if let Some(hint) = &report.hint {
                println!("  {DIM}{hint}{DIM:#}");
            }
        } else if report.sync_removed {
            println!();
            println!("  {g}Removed{g:#} sync schedule (--no-sync)");
        } else if !no_sync {
            println!();
            println!("  {DIM}No account linked, so nothing is uploaded yet.{DIM:#}");
            println!(
                "  {DIM}An existing sync schedule is left in place. Run: tokenstat login{DIM:#}"
            );
        } else {
            println!();
            println!("  {DIM}Sync schedule skipped (--no-sync).{DIM:#}");
        }

        if let Some(report) = &report.update {
            println!();
            println!("  {g}Installed{g:#} daily update check");
            for path in &report.paths {
                println!("  {DIM}{}{DIM:#}", path.display());
            }
            if let Some(hint) = &report.hint {
                println!("  {DIM}{hint}{DIM:#}");
            }
        } else if report.update_removed {
            println!();
            println!("  {g}Removed{g:#} stale update schedule");
        } else {
            println!();
            println!("  {DIM}Automatic updates are off, so no update entry was installed.{DIM:#}");
            println!("  {DIM}Turn them on with: tokenstat update --auto on{DIM:#}");
        }
        println!();
        return Ok(());
    }

    println!();
    println!("  {BOLD}Keep your history from disappearing{BOLD:#}");
    println!();
    println!("  {DIM}Claude Code deletes its transcripts after 30 days by default.{DIM:#}");
    println!("  {DIM}Anything not scanned before then is gone from this machine.{DIM:#}");
    println!("  {DIM}tokenstat keeps whatever it has already read.{DIM:#}");
    println!();

    print_unit(platform, Unit::Scan, &exe, interval);
    if want_sync {
        println!();
        println!("  {BOLD}Keep the profile current too{BOLD:#}");
        println!();
        println!("  {DIM}A second entry, because syncing is metered by your plan and{DIM:#}");
        println!("  {DIM}scanning is not. It waits its turn and skips a run the server{DIM:#}");
        println!("  {DIM}would refuse, so nothing here has to be tuned.{DIM:#}");
        println!();
        print_unit(platform, Unit::Sync, &exe, sync_interval);
    }
    if want_update {
        println!();
        println!("  {BOLD}And check for a new release once a day{BOLD:#}");
        println!();
        println!("  {DIM}Automatic updates are on. This entry downloads a newer{DIM:#}");
        println!("  {DIM}release, checks its checksum, then runs it and confirms its{DIM:#}");
        println!("  {DIM}version before it replaces this binary. If the new one cannot{DIM:#}");
        println!("  {DIM}run, the old one goes back.{DIM:#}");
        println!();
        print_unit(platform, Unit::Update, &exe, update_interval);
    }
    println!();
    Ok(())
}

/// Print the scheduler entry for one unit, for a user who would rather install
/// it themselves than have a tool write to their machine.
fn print_unit(
    platform: crate::schedule::Platform,
    unit: crate::schedule::Unit,
    exe: &str,
    interval: u64,
) {
    use crate::schedule::{self as sched, Platform};

    let label = unit.label();
    match platform {
        Platform::Launchd => {
            let home = directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf());
            let path = home
                .as_ref()
                .map(|h| sched::launchd_path(h, unit).display().to_string())
                .unwrap_or_else(|| format!("~/Library/LaunchAgents/{label}.plist"));
            let log = home
                .as_ref()
                .map(|h| sched::launchd_log_path(h, unit).display().to_string())
                .unwrap_or_else(|| format!("~/Library/Logs/{label}.log"));
            println!("  Save this as {path}");
            println!("  {DIM}or run: tokenstat schedule --install{DIM:#}");
            println!();
            for line in sched::launchd_plist(unit, exe, interval, &log).lines() {
                println!("  {line}");
            }
            println!();
            println!("  Then: launchctl load -w {path}");
        }
        Platform::SystemdUser => {
            let (service, timer) = sched::systemd_units(unit, exe, interval);
            println!("  ~/.config/systemd/user/{label}.service");
            println!();
            for line in service.lines() {
                println!("  {line}");
            }
            println!("  ~/.config/systemd/user/{label}.timer");
            println!();
            for line in timer.lines() {
                println!("  {line}");
            }
            println!("  Then: systemctl --user enable --now {label}.timer");
            println!("  {DIM}or run: tokenstat schedule --install{DIM:#}");
        }
        Platform::WindowsTaskScheduler => {
            println!("  Run this once, in a terminal:");
            println!();
            println!("  {}", sched::windows_command(unit, exe, interval));
            println!();
            println!("  {DIM}or run: tokenstat schedule --install{DIM:#}");
        }
    }
}
