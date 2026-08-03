use anstream::println;
use anyhow::{Context, Result};

use crate::ui::{DIM, accent, good};

pub fn self_update(check_only: bool, _yes: bool, json: bool) -> Result<()> {
    if check_only {
        let c = tokenstat_sync::check_latest().map_err(|e| anyhow::anyhow!("{e}"))?;
        if json {
            println!(
                r#"{{"current":"{}","latest":"{}","newer":{},"target":"{}","url":"{}"}}"#,
                c.current,
                c.latest,
                c.newer,
                tokenstat_sync::current_target(),
                c.html_url
            );
            return Ok(());
        }
        println!();
        println!("  {DIM}current{DIM:#}  {}", c.current);
        if c.latest.is_empty() {
            println!("  {DIM}latest{DIM:#}   (no GitHub release yet)");
        } else {
            println!("  {DIM}latest{DIM:#}   {}", c.latest);
        }
        println!(
            "  {DIM}target{DIM:#}   {}",
            tokenstat_sync::current_target()
        );
        if c.newer {
            let a = accent();
            println!();
            println!("  Update available. Run {a}tokenstat update{a:#}");
            println!("  {}", c.html_url);
        } else if !c.latest.is_empty() {
            let g = good();
            println!("  {g}up to date{g:#}");
        }
        println!();
        return Ok(());
    }

    let report = tokenstat_sync::apply_update().map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(
            r#"{{"from":"{}","to":"{}","path":"{}"}}"#,
            report.from,
            report.to,
            report.path.display()
        );
        return Ok(());
    }
    let g = good();
    println!();
    println!(
        "  {g}updated{g:#} {} → {}  {}",
        report.from,
        report.to,
        report.path.display()
    );
    println!("  {DIM}re-run the command in a new shell if this process looks odd{DIM:#}");
    println!();
    Ok(())
}

/// `update` as run by the scheduler.
///
/// Quiet by design, and never a failure the user has to act on: a background job
/// that could not reach GitHub today is not news, and the binary in place still
/// works. Only an error that means "the update was attempted and something is now
/// worth knowing" reaches the exit code.
pub fn self_update_scheduled(json: bool) -> Result<()> {
    match tokenstat_sync::scheduled_update() {
        Ok(tokenstat_sync::ScheduledUpdate::Disabled) => {
            if json {
                println!(r#"{{"skipped":"auto_update_off"}}"#);
            } else {
                println!("automatic updates are off, nothing to do");
            }
            Ok(())
        }
        Ok(tokenstat_sync::ScheduledUpdate::UpToDate(v)) => {
            if json {
                println!(r#"{{"up_to_date":"{v}"}}"#);
            } else {
                println!("up to date ({v})");
            }
            Ok(())
        }
        Ok(tokenstat_sync::ScheduledUpdate::NotOurs { latest, path }) => {
            // Not an error: a package manager owns this install, and saying so
            // once a day in a log is more useful than failing.
            if json {
                println!(
                    r#"{{"skipped":"not_ours","latest":"{latest}","path":"{}"}}"#,
                    path.display()
                );
            } else {
                println!(
                    "{latest} is available, but {} was installed by a package manager; \
                     update it there",
                    path.display()
                );
            }
            Ok(())
        }
        Ok(tokenstat_sync::ScheduledUpdate::Applied(r)) => {
            if json {
                println!(
                    r#"{{"from":"{}","to":"{}","path":"{}"}}"#,
                    r.from,
                    r.to,
                    r.path.display()
                );
            } else {
                println!("updated {} → {}", r.from, r.to);
            }
            Ok(())
        }
        Err(err) => {
            // Printed, not returned: a failed check must not make the scheduler
            // treat the unit as broken, and the previous binary is still in place
            // either way.
            if json {
                let msg = err
                    .to_string()
                    .replace('\\', "\\\\")
                    .replace('"', "\\\"")
                    .replace('\n', " ");
                println!(r#"{{"error":"{msg}"}}"#);
            } else {
                eprintln!("update check failed: {err}");
            }
            Ok(())
        }
    }
}

/// Turn automatic updates on or off, and install or remove the daily entry.
pub fn update_auto(value: &str, json: bool) -> Result<()> {
    let on = match value.trim().to_ascii_lowercase().as_str() {
        "on" | "1" | "true" | "yes" => true,
        "off" | "0" | "false" | "no" => false,
        other => anyhow::bail!("expected --auto on or --auto off, got {other}"),
    };
    tokenstat_sync::config::set_update_auto(on).map_err(|e| anyhow::anyhow!("{e}"))?;

    let home = directories::BaseDirs::new()
        .map(|d| d.home_dir().to_path_buf())
        .context("locating your home directory")?;
    let exe = crate::schedule::preferred_executable();
    let schedule_touched = if on {
        crate::schedule::install(
            &home,
            crate::schedule::Unit::Update,
            &exe,
            crate::schedule::Unit::Update.default_interval(),
        )
        .map(|_| true)
        .unwrap_or(false)
    } else {
        crate::schedule::uninstall(&home, crate::schedule::Unit::Update)
            .map(|r| r.removed)
            .unwrap_or(false)
    };

    if json {
        println!(r#"{{"auto_update":{on},"schedule_updated":{schedule_touched}}}"#);
        return Ok(());
    }
    let g = good();
    println!();
    if on {
        println!("  {g}automatic updates on{g:#}");
        println!("  {DIM}A newer release is downloaded, its checksum checked, and the{DIM:#}");
        println!("  {DIM}binary run and version-checked before it replaces this one.{DIM:#}");
        if schedule_touched {
            println!("  {g}installed{g:#} daily update schedule");
        } else {
            println!("  {DIM}Schedule the daily check with: tokenstat schedule --install{DIM:#}");
        }
    } else {
        println!("  {g}automatic updates off{g:#}");
        println!("  {DIM}tokenstat update still works when you run it yourself.{DIM:#}");
        if schedule_touched {
            println!("  {g}removed{g:#} daily update schedule");
        }
    }
    println!();
    Ok(())
}

/// Soft update check used after scan. Never fails the caller.
pub fn maybe_notify_update(json: bool) {
    if json {
        return;
    }
    let auto = tokenstat_sync::auto_apply_enabled();
    match tokenstat_sync::maybe_auto_update(auto) {
        Ok(Some(tokenstat_sync::UpdateOutcome::Available(c))) => {
            let a = accent();
            eprintln!(
                "  {DIM}update{DIM:#}  v{} available  {a}tokenstat update{a:#}  {}",
                c.latest, c.html_url
            );
        }
        Ok(Some(tokenstat_sync::UpdateOutcome::Applied(r))) => {
            let g = good();
            eprintln!("  {g}updated{g:#} {} → {}", r.from, r.to);
        }
        _ => {}
    }
}
