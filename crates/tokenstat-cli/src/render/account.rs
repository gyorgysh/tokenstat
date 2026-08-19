use anstream::println;
use anyhow::Result;
use tokenstat_core::Store;

use crate::ui::{self, BOLD, DIM, accent, good, warn};

/// Report remote fetch outcomes after scan or `tokenstat fetch`.
pub fn fetch_reports(reports: &[tokenstat_sync::FetchReport], json: bool) -> Result<()> {
    if json {
        print!("[");
        for (i, r) in reports.iter().enumerate() {
            if i > 0 {
                print!(",");
            }
            print!(
                r#"{{"vendor":"{}","events":{},"from_cache":{},"skipped_no_token":{},"message":{}}}"#,
                r.vendor,
                r.events,
                r.from_cache,
                r.skipped_no_token,
                r.message
                    .as_deref()
                    .map(|s| format!("\"{}\"", s.replace('"', "\\\"")))
                    .unwrap_or_else(|| "null".into()),
            );
        }
        println!("]");
        return Ok(());
    }
    for r in reports {
        if r.skipped_no_token {
            println!(
                "  {DIM}{}: {DIM:#}{}",
                r.vendor,
                r.message.as_deref().unwrap_or("no token")
            );
            continue;
        }
        // Antigravity may report quota and/or IDE sync with zero new events.
        if r.events == 0 {
            if let Some(msg) = &r.message {
                if msg.contains("quota") || msg.contains("IDE") {
                    let g = good();
                    println!("  {g}{}{g:#}: {msg}", r.vendor);
                    continue;
                }
                let w = warn();
                println!("  {w}{}: {msg}{w:#}", r.vendor);
                continue;
            }
        }
        let src = if r.from_cache { "cache" } else { "network" };
        let g = good();
        let extra = r
            .message
            .as_deref()
            .map(|m| format!("  {DIM}({m}){DIM:#}"))
            .unwrap_or_default();
        println!(
            "  {g}{}{g:#}: {} events from {src}{extra}",
            r.vendor,
            ui::exact(r.events as u64)
        );
    }
    println!();
    Ok(())
}

/// `tokenstat auth` for Cursor / Antigravity session tokens.
pub fn auth(
    vendor: Option<&str>,
    token: Option<&str>,
    logout: bool,
    status: bool,
    json: bool,
) -> Result<()> {
    if status {
        let rows = tokenstat_sync::creds::status()?;
        if json {
            print!("[");
            for (i, s) in rows.iter().enumerate() {
                if i > 0 {
                    print!(",");
                }
                let source = match s.source {
                    Some(tokenstat_sync::creds::TokenSource::Env) => "\"env\"",
                    Some(tokenstat_sync::creds::TokenSource::Stored) => "\"stored\"",
                    Some(tokenstat_sync::creds::TokenSource::Discovered) => "\"discovered\"",
                    None => "null",
                };
                print!(
                    r#"{{"vendor":"{}","present":{},"source":{}}}"#,
                    s.vendor, s.present, source
                );
            }
            println!("]");
            return Ok(());
        }
        println!();
        println!(
            "  {BOLD}Vendor auth{BOLD:#}  {DIM}(tokenstat.ai login is separate, later){DIM:#}"
        );
        for s in rows {
            let state = match s.source {
                Some(tokenstat_sync::creds::TokenSource::Env) => "env override",
                Some(tokenstat_sync::creds::TokenSource::Stored) => "stored",
                Some(tokenstat_sync::creds::TokenSource::Discovered) => {
                    "discovered from app keychain"
                }
                None => "no token",
            };
            println!("  {DIM}{}{DIM:#}  {state}", s.vendor);
        }
        println!();
        println!("  {DIM}Cursor / Antigravity: sign in to the app, then tokenstat fetch.{DIM:#}");
        println!("  {DIM}Optional paste still works: tokenstat auth cursor --token …{DIM:#}");
        println!();
        return Ok(());
    }

    let vendor_name = vendor.ok_or_else(|| {
        anyhow::anyhow!("vendor required: cursor or antigravity (or pass --status)")
    })?;
    let vendor = match vendor_name.to_ascii_lowercase().as_str() {
        "cursor" => tokenstat_sync::Vendor::Cursor,
        "antigravity" | "anti" => tokenstat_sync::Vendor::Antigravity,
        other => anyhow::bail!("unknown vendor {other:?}, use cursor or antigravity"),
    };

    if logout {
        match vendor {
            tokenstat_sync::Vendor::Cursor => tokenstat_sync::cursor::logout()?,
            tokenstat_sync::Vendor::Antigravity => tokenstat_sync::antigravity::logout()?,
        }
        println!("  cleared {} token", vendor.as_str());
        return Ok(());
    }

    let (path, how) = match token {
        Some(t) if !t.trim().is_empty() => {
            let path = match vendor {
                tokenstat_sync::Vendor::Cursor => tokenstat_sync::cursor::auth(t)?,
                tokenstat_sync::Vendor::Antigravity => tokenstat_sync::antigravity::auth(t)?,
            };
            (path, "stored")
        }
        Some(_) => anyhow::bail!("empty token"),
        None => {
            // Convenience: pull whatever the vendor app already left locally.
            let (path, source) = match vendor {
                tokenstat_sync::Vendor::Cursor => tokenstat_sync::cursor::auth_auto()?,
                tokenstat_sync::Vendor::Antigravity => tokenstat_sync::antigravity::auth_auto()?,
            };
            let how = match source {
                tokenstat_sync::creds::TokenSource::Discovered => "discovered from app keychain",
                tokenstat_sync::creds::TokenSource::Env => "env",
                tokenstat_sync::creds::TokenSource::Stored => "stored",
            };
            (path, how)
        }
    };

    let g = good();
    println!(
        "  {g}{} {g:#}{} token → {}",
        how,
        vendor.as_str(),
        path.display()
    );
    println!("  {DIM}Local only. Never synced to tokenstat.ai.{DIM:#}");
    println!("  {DIM}Run tokenstat fetch  (or scan) to pull usage.{DIM:#}");
    println!();
    Ok(())
}

/// Check or apply a self-update from GitHub Releases.
/// Device-login against tokenstat.ai (or sandbox).
pub fn profile_login(host: Option<&str>, json: bool) -> Result<()> {
    let result = tokenstat_sync::login(host).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(
            r#"{{"host":"{}","handle":"{}","machine":"{}","schema_min_v":{},"schema_max_v":{}}}"#,
            result.host, result.handle, result.machine, result.schema_min_v, result.schema_max_v
        );
        return Ok(());
    }
    let g = good();
    println!();
    println!("  {g}logged in{g:#} as {BOLD}@{}{BOLD:#}", result.handle);
    println!("  {DIM}host{DIM:#}     {}", result.host);
    println!("  {DIM}machine{DIM:#}  {}", result.machine);
    println!(
        "  {DIM}schema{DIM:#}   [{}, {}]",
        result.schema_min_v, result.schema_max_v
    );
    println!("  {DIM}token stored under credentials/sync/ for this host{DIM:#}");
    println!();
    maybe_install_linked_schedules(host, false);
    let a = accent();
    println!("  Next: {a}tokenstat sync{a:#}");
    println!();
    Ok(())
}

/// Redeem a pairing code from the website. No browser, no polling.
pub fn profile_login_code(host: Option<&str>, code: &str, json: bool) -> Result<()> {
    let result = tokenstat_sync::login_with_code(host, code).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(
            r#"{{"host":"{}","handle":"{}","machine":"{}","schema_min_v":{},"schema_max_v":{}}}"#,
            result.host, result.handle, result.machine, result.schema_min_v, result.schema_max_v
        );
        return Ok(());
    }
    let g = good();
    println!();
    println!("  {g}connected{g:#} as {BOLD}@{}{BOLD:#}", result.handle);
    println!("  {DIM}host{DIM:#}     {}", result.host);
    println!("  {DIM}machine{DIM:#}  {}", result.machine);
    println!("  {DIM}token stored under credentials/sync/ for this host{DIM:#}");
    println!();
    maybe_install_linked_schedules(host, false);
    let a = accent();
    println!("  Next: {a}tokenstat sync{a:#}");
    println!();
    Ok(())
}

/// Best-effort sync (and auto-update) schedule after linking an account.
///
/// Goes through `repair` so a re-login also refreshes the scan entry and drops
/// a stale update unit when auto-apply is off.
fn maybe_install_linked_schedules(host: Option<&str>, quiet: bool) {
    let Some(home) = directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf()) else {
        return;
    };
    let exe = crate::schedule::preferred_executable();
    let info = match tokenstat_sync::scheduling_info(host) {
        Ok(i) if i.logged_in => i,
        _ => return,
    };
    let sync_interval = info
        .min_interval
        .unwrap_or_else(|| crate::schedule::Unit::Sync.default_interval());
    let want_update = tokenstat_sync::auto_apply_enabled();
    match crate::schedule::repair(
        &home,
        &exe,
        crate::schedule::Unit::Scan.default_interval(),
        crate::schedule::SyncAction::Install(sync_interval),
        want_update,
    ) {
        Ok(report) => {
            if quiet {
                return;
            }
            let g = good();
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
        }
        Err(e) => {
            if !quiet {
                println!("  {DIM}could not install sync schedule: {e}{DIM:#}");
                println!("  {DIM}run later with: tokenstat schedule --install{DIM:#}");
            }
        }
    }
}

/// Drop the sync token for a host. No server call.
///
/// Leaves the sync schedule in place: `sync --scheduled` exits quietly without
/// a token, and the next `tokenstat login` starts uploading again without
/// another `schedule --install`.
pub fn profile_logout(host: Option<&str>, json: bool) -> Result<()> {
    let host = tokenstat_sync::logout(host).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!(r#"{{"host":"{host}","logged_out":true}}"#);
        return Ok(());
    }
    println!();
    println!("  cleared sync token for {host}");
    println!("  {DIM}sync schedule left in place (resumes after login){DIM:#}");
    println!();
    Ok(())
}

/// `GET /api/v1/me`.
pub fn profile_sync_status(host: Option<&str>, json: bool) -> Result<()> {
    let st = tokenstat_sync::sync_status(host).map_err(|e| anyhow::anyhow!("{e}"))?;
    if json {
        println!("{}", st.raw);
        return Ok(());
    }
    println!();
    println!("  {BOLD}tokenstat.ai{BOLD:#}");
    println!("  {DIM}host{DIM:#}      {}", st.host);
    println!(
        "  {DIM}handle{DIM:#}    {}",
        st.handle.as_deref().unwrap_or("-")
    );
    println!(
        "  {DIM}tier{DIM:#}      {}",
        st.tier.as_deref().unwrap_or("-")
    );
    println!(
        "  {DIM}last sync{DIM:#} {}",
        st.last_sync_at.as_deref().unwrap_or("-")
    );
    if let (Some(min_v), Some(max_v)) = (st.schema_min_v, st.schema_max_v) {
        let current = st
            .schema_current
            .map(|c| c.to_string())
            .unwrap_or_else(|| "-".into());
        println!("  {DIM}schema{DIM:#}   [{min_v}, {max_v}]  current {current}");
    }
    if st.machines.is_empty() {
        println!("  {DIM}machines{DIM:#}  (none yet)");
    } else {
        println!("  {DIM}machines{DIM:#}  {}", st.machines.len());
        for m in &st.machines {
            let id = m.get("id").and_then(|v| v.as_str()).unwrap_or("?");
            let label = m.get("label").and_then(|v| v.as_str()).unwrap_or("");
            let last = m
                .get("last_sync_at")
                .and_then(|v| v.as_str())
                .unwrap_or("-");
            if label.is_empty() {
                println!("    {id}  last {last}");
            } else {
                println!("    {id} ({label})  last {last}");
            }
        }
    }
    println!();
    Ok(())
}

/// `tokenstat device`: what this machine is called, and what it is.
///
/// A name is worth having because a device list with three unnamed rows is a
/// list nobody can act on. The CLI needs its own way to set one: a headless
/// Linux install has no app, and the name it publishes at login is the
/// hostname, which is often a string a hosting provider chose.
///
/// The name is written locally, the same file the app writes, and pushed to
/// the account when this machine is signed in. Blank clears it and the
/// system's own name comes back.
pub fn device(host: Option<&str>, name: Option<&str>, clear: bool, json: bool) -> Result<()> {
    if clear || name.is_some() {
        let wanted = if clear { "" } else { name.unwrap_or("").trim() };
        tokenstat_identity::set_machine_label(wanted).map_err(|e| anyhow::anyhow!("{e}"))?;
        // And on the account, when there is one. Not being signed in is not a
        // failure to name a machine: the local name is what travels to a
        // paired peer either way, so that case says nothing at all.
        let machine =
            tokenstat_sync::config::ensure_machine_id().map_err(|e| anyhow::anyhow!("{e}"))?;
        if let Err(e) = tokenstat_sync::rename_machine(host, &machine, wanted)
            && !e.is_unauthenticated()
        {
            eprintln!("  {DIM}named on this machine; the account was not updated: {e}{DIM:#}");
        }
    }

    let label = tokenstat_identity::machine_label();
    let chosen = tokenstat_identity::machine_label_is_chosen();
    let platform = tokenstat_identity::platform();
    let machine = tokenstat_sync::config::ensure_machine_id().unwrap_or_default();

    if json {
        println!(
            "{}",
            serde_json::json!({
                "name": label,
                "chosen": chosen,
                "machine": machine,
                "platform": platform.pretty(),
                "os": platform.os,
                "arch": platform.arch,
            })
        );
        return Ok(());
    }

    println!();
    println!("  {BOLD}{label}{BOLD:#}");
    println!("  {DIM}what{DIM:#}     {}", platform.pretty());
    println!("  {DIM}machine{DIM:#}  {machine}");
    if chosen {
        println!("  {DIM}named on this machine (tokenstat device --clear undoes it){DIM:#}");
    } else {
        println!("  {DIM}the system's own name (tokenstat device --name \"…\" changes it){DIM:#}");
    }
    println!();
    Ok(())
}

/// Upload (or dry-run) the sealed sync payload.
pub fn profile_sync(
    store: &Store,
    host: Option<&str>,
    prune: bool,
    window: Option<&str>,
    dry_run: bool,
    tz_name: Option<&str>,
    json: bool,
) -> Result<()> {
    let result = tokenstat_sync::sync(
        store,
        tokenstat_sync::SyncOptions {
            host_flag: host,
            prune,
            window,
            dry_run,
            tz_name,
        },
    )
    .map_err(|e| anyhow::anyhow!("{e}"))?;

    if dry_run {
        // Canonical JSON already printed by the sync client.
        return Ok(());
    }

    if json {
        println!(
            r#"{{"host":"{}","from":"{}","to":"{}","rows":{},"idempotency_key":"{}","prune":{}}}"#,
            result.host,
            result.window.from,
            result.window.to,
            result.rows,
            result.idempotency_key,
            prune
        );
        return Ok(());
    }

    let g = good();
    println!();
    println!(
        "  {g}synced{g:#} {} rows  {}..{}",
        ui::exact(result.rows),
        result.window.from,
        result.window.to
    );
    println!("  {DIM}host{DIM:#}  {}", result.host);
    if prune {
        println!("  {DIM}prune{DIM:#} true");
    }
    println!();
    Ok(())
}

/// `sync` as run by the scheduler.
///
/// A background job has no one to read it, so the boring outcomes (no account,
/// not due yet, archive busy, brief network blip) print a single line and exit
/// 0. Only a durable failure is loud, because that is the one worth finding in
/// the log.
pub fn profile_sync_scheduled(
    store: &Store,
    host: Option<&str>,
    window: Option<&str>,
    tz_name: Option<&str>,
    json: bool,
) -> Result<()> {
    let outcome = tokenstat_sync::sync_scheduled(
        store,
        tokenstat_sync::SyncOptions {
            host_flag: host,
            prune: false,
            window,
            dry_run: false,
            tz_name,
        },
    )
    .map_err(|e| anyhow::anyhow!("{e}"))?;

    match outcome {
        tokenstat_sync::ScheduledOutcome::NotLoggedIn => {
            if json {
                println!(r#"{{"skipped":"not_logged_in"}}"#);
            } else {
                println!("no account linked for this host, nothing to sync");
            }
            Ok(())
        }
        tokenstat_sync::ScheduledOutcome::Held { until } => {
            let until = until.unwrap_or_else(|| "later".into());
            if json {
                println!(r#"{{"skipped":"rate_limited","next_allowed_at":"{until}"}}"#);
            } else {
                println!("not due yet, next sync allowed at {until}");
            }
            Ok(())
        }
        tokenstat_sync::ScheduledOutcome::Deferred { reason } => {
            if json {
                let escaped = reason.replace('\\', "\\\\").replace('"', "\\\"");
                println!(r#"{{"skipped":"deferred","reason":"{escaped}"}}"#);
            } else if reason.contains("database is locked")
                || reason.contains("database is busy")
                || reason.contains("database error")
            {
                println!("archive busy, will retry next run");
            } else if reason.contains("schema fetch failed") || reason.contains("error sending") {
                println!("schema unreachable, will retry next run");
            } else {
                println!("sync deferred, will retry next run: {reason}");
            }
            Ok(())
        }
        tokenstat_sync::ScheduledOutcome::Asleep => {
            if json {
                println!(r#"{{"skipped":"asleep"}}"#);
            } else {
                println!("Mac is asleep, will retry on a later run");
            }
            Ok(())
        }
        tokenstat_sync::ScheduledOutcome::Synced(result) => {
            if json {
                println!(
                    r#"{{"host":"{}","from":"{}","to":"{}","rows":{},"idempotency_key":"{}"}}"#,
                    result.host,
                    result.window.from,
                    result.window.to,
                    result.rows,
                    result.idempotency_key
                );
            } else {
                println!(
                    "synced {} rows {}..{}",
                    result.rows, result.window.from, result.window.to
                );
            }
            Ok(())
        }
    }
}
