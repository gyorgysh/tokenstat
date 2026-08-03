use std::path::Path;

use anstream::println;
use anyhow::Result;
use tokenstat_core::{Counters, EquivalentValue, GroupBy, PriceTable, Query, ScanReport, Store};

use super::*;
use crate::ui::{self, BOLD, DIM, accent, good, warn};

pub fn empty_archive(json: bool) -> Result<()> {
    if json {
        println!(
            "{}",
            r#"{"events":0,"hint":"run: tokenstat scan","sources_on_disk":["claude_code","codex","grok","opencode","cline","antigravity","openclaw","zed","copilot"],"sources_remote":["cursor"],"sources_ide_sync":["antigravity"]}"#
        );
        return Ok(());
    }
    println!();
    println!("  {BOLD}No usage recorded yet.{BOLD:#}");
    println!();
    let a = accent();
    println!("  Run {a}tokenstat scan{a:#} to read your local logs.");
    println!("  Or open the interactive client with {a}tokenstat{a:#} and type {a}/scan{a:#}.");
    println!();
    println!(
        "  {DIM}On disk:{DIM:#} Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI"
    );
    println!("  {DIM}Remote:{DIM:#}   Cursor  {DIM}(tokenstat auth cursor){DIM:#}");
    println!("  {DIM}IDE sync:{DIM:#} Antigravity  {DIM}(open app, then tokenstat fetch){DIM:#}");
    println!();
    Ok(())
}

/// Filtered query matched nothing, but the archive itself may have data.
pub fn empty_range(json: bool) -> Result<()> {
    if json {
        println!(
            "{}",
            r#"{"rows":0,"hint":"widen --since/--until or drop filters"}"#
        );
        return Ok(());
    }
    println!();
    println!("  {DIM}Nothing in this range.{DIM:#}");
    println!("  {DIM}Try widening --since / --until, or drop --model / --project.{DIM:#}");
    println!();
    Ok(())
}

pub fn scan_report(r: &ScanReport, json: bool) -> Result<()> {
    if json {
        println!(
            r#"{{"files_found":{},"files_read":{},"rows_seen":{},"events_new":{},"duplicate_ratio":{:.4},"warnings":{},"elapsed_ms":{}}}"#,
            r.files_found,
            r.files_read,
            r.rows_seen,
            r.events_new,
            r.duplicate_ratio(),
            r.warnings.len(),
            r.elapsed_ms
        );
        return Ok(());
    }

    println!();
    let skipped = r.files_found.saturating_sub(r.files_read);
    println!(
        "  {BOLD}Scanned{BOLD:#} {} of {} files in {}",
        ui::exact(r.files_read),
        ui::exact(r.files_found),
        format_ms(r.elapsed_ms)
    );
    if skipped > 0 {
        println!(
            "  {DIM}{} unchanged since the last scan{DIM:#}",
            ui::exact(skipped)
        );
    }

    if r.rows_seen > 0 {
        println!(
            "  {} rows read, {} new",
            ui::exact(r.rows_seen),
            ui::exact(r.events_new)
        );
        let dup = r.duplicate_ratio();
        if dup > 0.01 {
            // Worth surfacing: it is the single biggest source of wrong numbers
            // in tools that key on the wrong field.
            println!(
                "  {DIM}{:.1}% were duplicates, collapsed by request id{DIM:#}",
                dup * 100.0
            );
        }
    }

    if r.events_recovered > 0 {
        let g = good();
        println!(
            "  {g}recovered {} days from Claude Code's rollup{g:#}  {DIM}({} entries){DIM:#}",
            r.days_recovered, r.events_recovered
        );
        println!("  {DIM}those transcripts were already deleted, the totals survive{DIM:#}");
    }

    if r.files_found == 0 {
        println!();
        println!("  {DIM}No supported tool logs found on this machine.{DIM:#}");
        println!(
            "  {DIM}On disk: Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI,{DIM:#}"
        );
        println!("  {DIM}OpenClaw, Zed, Copilot CLI. Then scan again.{DIM:#}");
        println!("  {DIM}Cursor keeps usage on its servers (tokenstat auth cursor).{DIM:#}");
        println!("  {DIM}Antigravity IDE needs the app open + tokenstat fetch.{DIM:#}");
    } else if r.rows_seen == 0 && r.events_recovered == 0 {
        println!();
        println!("  {DIM}Logs were found, but no new usage rows were readable.{DIM:#}");
        println!("  {DIM}Run tokenstat doctor for source coverage.{DIM:#}");
    }

    if !r.warnings.is_empty() {
        let w = warn();
        println!(
            "  {w}{} warnings{w:#}  {DIM}run: tokenstat doctor{DIM:#}",
            r.warnings.len()
        );
    }
    println!();
    Ok(())
}

fn format_ms(ms: u128) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else {
        format!("{:.1}s", ms as f64 / 1000.0)
    }
}

/// Shared table for any grouping: label, bar, split counters, total.
///
/// Day (and month) rows stay oldest→newest so a long one-shot print ends on
/// the most recent day. The interactive client reverses that on screen.
pub fn doctor(store: &Store, db_path: &Path, json: bool) -> Result<()> {
    let totals = store.totals(&Query::default())?;
    let confidence = store.confidence_breakdown()?;
    let last_scan = store.meta("last_scan_ms")?;

    if json {
        let conf: Vec<String> = confidence
            .iter()
            .map(|(k, v)| format!(r#"{{"level":"{k}","events":{v}}}"#))
            .collect();
        println!(
            r#"{{"db":"{}","events":{},"confidence":[{}]}}"#,
            db_path.display(),
            totals.events,
            conf.join(",")
        );
        return Ok(());
    }

    println!();
    println!("  {BOLD}Archive{BOLD:#}");
    println!("  {DIM}path{DIM:#}     {}", db_path.display());
    println!("  {DIM}events{DIM:#}   {}", ui::exact(totals.events));
    if let (Some(a), Some(b)) = (&totals.first_date, &totals.last_date) {
        println!(
            "  {DIM}range{DIM:#}    {a} to {b} ({} active days)",
            totals.days
        );
    }
    match last_scan.as_deref().and_then(|s| s.parse::<i64>().ok()) {
        Some(ms) => {
            let age = (jiff::Timestamp::now().as_millisecond() - ms).max(0) / 1000;
            println!("  {DIM}scanned{DIM:#}  {} ago", format_age(age));
        }
        None => println!("  {DIM}scanned{DIM:#}  never"),
    }

    println!();
    println!("  {BOLD}Confidence{BOLD:#}");
    if confidence.is_empty() {
        println!("  {DIM}No events yet, so there is nothing to score.{DIM:#}");
    } else {
        for (level, count) in &confidence {
            let share = *count as f64 / totals.events.max(1) as f64;
            let style = if level == "exact" { good() } else { warn() };
            println!(
                "  {}  {style}{}{style:#}  {}  {:.1}%",
                ui::pad_right(level, 9),
                ui::pad_right(&ui::bar(share, 20), 20),
                ui::pad_left(&ui::exact(*count), 9),
                share * 100.0,
            );
        }
        println!();
        println!("  {DIM}exact means the provider assigned a request id that survives a{DIM:#}");
        println!("  {DIM}session resume, so duplicates collapse reliably.{DIM:#}");
    }

    if let Some(rec) = tokenstat_core::reconcile(store)? {
        println!();
        println!("  {BOLD}Against Claude Code's own rollup{BOLD:#}");
        println!(
            "  {DIM}it reports{DIM:#}   {} input + output over {} sessions",
            ui::tokens(rec.vendor_in_out),
            ui::exact(rec.vendor_sessions)
        );
        println!(
            "  {DIM}archive has{DIM:#}  {} input + output over {} sessions",
            ui::tokens(rec.archive_in_out),
            ui::exact(rec.archive_sessions)
        );

        if totals.events == 0 {
            println!();
            let a = accent();
            println!(
                "  Archive is empty. Run {a}tokenstat scan{a:#} to import what is still on disk."
            );
            println!(
                "  {DIM}Claude's rollup can recover pruned transcript days once you scan.{DIM:#}"
            );
        } else if rec.is_significant() {
            let w = warn();
            println!();
            println!(
                "  {w}{} ({:.0}%) is no longer recoverable from your transcripts.{w:#}",
                ui::tokens(rec.missing()),
                rec.missing_ratio() * 100.0
            );
            if let (Some(v), Some(a)) = (&rec.vendor_first_date, &rec.archive_first_date) {
                println!("  {DIM}your history starts {v}, surviving transcripts start {a}{DIM:#}");
            }
            println!();
            println!(
                "  {DIM}Claude Code deletes transcripts after cleanupPeriodDays (30 by{DIM:#}"
            );
            println!(
                "  {DIM}default). tokenstat keeps what it has already read, so scanning{DIM:#}"
            );
            println!("  {DIM}regularly from now on stops the gap from growing.{DIM:#}");
        } else if rec.ahead() > 0 {
            // Normal and healthy: transcripts are current, the rollup is
            // recomputed periodically and lags behind.
            println!();
            let g = good();
            println!(
                "  {g}archive is complete{g:#}, and {} ahead of the rollup",
                ui::tokens(rec.ahead())
            );
            if let Some(d) = &rec.vendor_last_computed {
                println!("  {DIM}the rollup was last recomputed on {d}{DIM:#}");
            }
        } else {
            println!();
            let g = good();
            println!("  {g}archive agrees with the rollup{g:#}");
        }
    }

    println!();
    println!("  {BOLD}Sources{BOLD:#}");
    println!(
        "  {DIM}on disk{DIM:#}   Claude Code, Codex, Grok, OpenCode, Cline, Antigravity CLI, OpenClaw, Zed, Copilot CLI"
    );
    println!("  {DIM}remote{DIM:#}    Cursor  {DIM}(auth + 30m cached fetch){DIM:#}");
    println!("  {DIM}IDE sync{DIM:#}  Antigravity  {DIM}(open app, then tokenstat fetch){DIM:#}");
    if let Ok(rows) = tokenstat_sync::creds::status() {
        for s in rows {
            let state = if s.present {
                "token stored"
            } else {
                "no token"
            };
            println!("  {DIM}auth {}{DIM:#}  {state}", s.vendor);
        }
    }
    if let Some(q) = tokenstat_sync::antigravity::stored_quota(store) {
        println!();
        println!(
            "  {BOLD}Antigravity quota{BOLD:#}  {DIM}plan remaining, separate from token events{DIM:#}"
        );
        println!("  {DIM}status{DIM:#}   {}", q.summary_line());
        for m in q.models.iter().take(8) {
            let pct = match m.remaining_fraction {
                Some(f) => format!("{:>3}% left", (f * 100.0).round() as i64),
                None => "  n/a      ".into(),
            };
            let reset = m.reset_time.as_deref().unwrap_or("-");
            println!("  {DIM}{:<22}{DIM:#} {pct}  reset {reset}", m.display_name);
        }
    }
    let cli_home = directories::BaseDirs::new().map(|b| b.home_dir().to_path_buf());
    if let Some(home) = cli_home {
        let cli = home
            .join(".gemini")
            .join("antigravity-cli")
            .join("conversations");
        let cache = tokenstat_core::sources::antigravity_cache::cache_dir();
        println!();
        println!("  {BOLD}Antigravity coverage{BOLD:#}");
        if cli.is_dir() {
            let n = tokenstat_core::sources::antigravity_cli::shards(&cli).len();
            println!("  {DIM}CLI DBs{DIM:#}   {n} conversation files (offline scan)");
        } else {
            println!("  {DIM}CLI DBs{DIM:#}   not installed");
        }
        match cache {
            Some(dir) if dir.is_dir() => {
                let n = tokenstat_core::sources::antigravity_cache::shards(&dir).len();
                println!("  {DIM}IDE cache{DIM:#} {n} synced sessions");
            }
            _ => println!(
                "  {DIM}IDE cache{DIM:#} empty  {DIM}(open Antigravity, then tokenstat fetch){DIM:#}"
            ),
        }
    }
    println!();
    Ok(())
}

/// Show or refresh the local list-rate price book.
/// One line for a shell prompt.
///
/// Every failure path here is silent. A statusline that prints an error, or
/// worse blocks, on every prompt is worse than one that prints nothing, so the
/// caller ignores the result and this never scans the filesystem.
pub fn statusline(
    store: &Store,
    tz: &jiff::tz::TimeZone,
    format: &str,
    max_age_secs: u64,
) -> Result<()> {
    let today = jiff::Timestamp::now().to_zoned(tz.clone()).date();
    let month_start = today.first_of_month();
    let today_s = today.to_string();
    let month_s = month_start.to_string();
    let (day, month) = store.statusline_snapshot(&today_s, &month_s)?;

    let prices = PriceTable::load_with_catalog();
    // Sum list-rate value per model so a multi-model day is not priced as
    // Sonnet-5. Still an approximation of value, never a charge.
    let value = |since: &str, until: &str| -> String {
        let q = Query {
            since: Some(since.to_string()),
            until: Some(until.to_string()),
            ..Query::default()
        };
        let Ok(rows) = store.report(GroupBy::Model, &q) else {
            return String::new();
        };
        let mut total = 0.0;
        let mut any = false;
        for r in rows {
            if let Some(v) = EquivalentValue::price(&prices, &model_label(&r.key), &r.counters) {
                total += v.dollars();
                any = true;
            }
        }
        if any { ui::usd(total) } else { String::new() }
    };
    let in_out = |c: &Counters| ui::tokens(c.input_fresh.unwrap_or(0) + c.output.unwrap_or(0));

    let stale = match max_age_secs {
        0 => String::new(),
        limit => match store
            .meta("last_scan_ms")
            .ok()
            .flatten()
            .and_then(|s| s.parse::<i64>().ok())
        {
            Some(ms) => {
                let age = (jiff::Timestamp::now().as_millisecond() - ms).max(0) / 1000;
                if age as u64 > limit {
                    // Kick a background scan so the next prompt is fresher.
                    // Never wait here: the statusline must stay archive-only.
                    spawn_background_scan();
                    "*".into()
                } else {
                    String::new()
                }
            }
            None => {
                spawn_background_scan();
                "*".into()
            }
        },
    };

    let line = format
        .replace("{today}", &ui::tokens(day.total()))
        .replace("{month}", &ui::tokens(month.total()))
        .replace("{today_in_out}", &in_out(&day))
        .replace("{month_in_out}", &in_out(&month))
        .replace("{today_value}", &value(&today_s, &today_s))
        .replace("{month_value}", &value(&month_s, &today_s))
        .replace("{stale}", &stale);

    // Plain stdout, not anstream: a prompt supplies its own colour and a
    // stray reset sequence would bleed into the shell.
    println!("{line}");
    Ok(())
}

/// Start `tokenstat scan` in the background if no other refresh holds the lock.
///
/// Failures are silent: a statusline must never print errors or block.
fn spawn_background_scan() {
    let Ok(dirs) = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .ok_or(())
        .map(|d| d.data_dir().to_path_buf())
    else {
        return;
    };
    let lock_path = dirs.join("scan.lock");
    let _ = std::fs::create_dir_all(&dirs);

    // Try to create the lock exclusively. If it already exists and is fresh,
    // another refresh is in flight or finished recently.
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
    {
        Ok(f) => {
            let _ = f.set_len(0);
            drop(f);
        }
        Err(_) => {
            // Stale lock older than 10 minutes: steal it. Fresher: skip.
            if let Ok(meta) = std::fs::metadata(&lock_path) {
                if let Ok(modified) = meta.modified() {
                    if modified
                        .elapsed()
                        .map(|a| a.as_secs() < 600)
                        .unwrap_or(true)
                    {
                        return;
                    }
                }
            }
            let _ = std::fs::remove_file(&lock_path);
            if std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&lock_path)
                .is_err()
            {
                return;
            }
        }
    }

    let Ok(exe) = std::env::current_exe() else {
        let _ = std::fs::remove_file(&lock_path);
        return;
    };

    #[cfg(unix)]
    {
        let mut cmd = std::process::Command::new(exe);
        cmd.arg("scan")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        // Lock file mtime prevents a stampede for up to 10 minutes.
        let _ = cmd.spawn();
    }
    #[cfg(not(unix))]
    {
        let _ = std::process::Command::new(exe)
            .arg("scan")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}
