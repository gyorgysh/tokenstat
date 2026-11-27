// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::session::Session;

const UNLINKED_CHECK_INTERVAL: Duration = Duration::from_secs(60);
const SYNC_CHECK_INTERVAL: Duration = Duration::from_secs(15);

/// Keep aggregate sync alive while the desktop helper is running.
///
/// Check the shared deadline even when a CLI timer is installed: a schedule
/// file does not establish that the timer ran. The shared sync lock and cursor
/// serialize uploads across the app, host daemon, and CLI.
pub fn start(session: Arc<Mutex<Session>>) {
    let scan_session = Arc::clone(&session);

    std::thread::spawn(move || {
        loop {
            if tokenstat_sync::scheduled_network_allowed() {
                scan_archive(&scan_session);
            }
            std::thread::sleep(UNLINKED_CHECK_INTERVAL);
        }
    });
    let maintenance_session = Arc::clone(&session);

    std::thread::spawn(move || {
        let mut last_maintenance: Option<std::time::Instant> = None;
        loop {
            if tokenstat_sync::scheduled_network_allowed()
                && last_maintenance.is_none_or(|at| at.elapsed() >= PRICING_REFRESH_INTERVAL)
            {
                refresh_pricing(&maintenance_session);
                last_maintenance = Some(std::time::Instant::now());
            }
            post_limits();
            fetch_remote_usage(&maintenance_session);
            std::thread::sleep(UNLINKED_CHECK_INTERVAL);
        }
    });
    std::thread::spawn(move || {
        loop {
            if tokenstat_sync::scheduled_network_allowed() {
                run_once(&session);
            }
            std::thread::sleep(sync_interval());
        }
    });
}

fn post_limits() {
    if !tokenstat_sync::scheduled_network_allowed() {
        return;
    }
    if !limits_pass_is_due(Duration::from_secs(300)) {
        return;
    }
    crate::dispatch::refresh_plan_limits();
}

const PRICING_REFRESH_INTERVAL: Duration = Duration::from_secs(60 * 60);

fn limits_pass_is_due(interval: Duration) -> bool {
    use std::sync::OnceLock;
    static LAST: OnceLock<Mutex<Option<std::time::Instant>>> = OnceLock::new();
    let cell = LAST.get_or_init(|| Mutex::new(None));
    let Ok(mut last) = cell.lock() else {
        return false;
    };
    match *last {
        Some(at) if at.elapsed() < interval => false,
        _ => {
            *last = Some(std::time::Instant::now());
            true
        }
    }
}

fn refresh_pricing(session: &Mutex<Session>) {
    if !tokenstat_sync::scheduled_network_allowed() {
        return;
    }
    match tokenstat_sync::pricing::refresh(false) {
        Ok(refreshed) => {
            if let Ok(mut guard) = session.lock() {
                crate::pricing::reload(&mut guard);
            }
            if !refreshed.large_moves.is_empty() {
                let why = if refreshed.accepted_stale {
                    "local book was older than a day"
                } else {
                    "force"
                };
                eprintln!(
                    "pricing: accepted {} large rate move(s) ({why}); effective from {}",
                    refreshed.large_moves.len(),
                    refreshed.effective_from
                );
            }
        }
        Err(error) => eprintln!("pricing: refresh failed: {error}"),
    }
}

fn sync_interval() -> Duration {
    let Ok(info) = tokenstat_sync::scheduling_info(None) else {
        return UNLINKED_CHECK_INTERVAL;
    };
    if !info.logged_in {
        return UNLINKED_CHECK_INTERVAL;
    }

    SYNC_CHECK_INTERVAL
}

fn run_once(session: &Mutex<Session>) {
    if !tokenstat_sync::scheduled_network_allowed() {
        return;
    }
    let Ok(info) = tokenstat_sync::scheduling_info(None) else {
        return;
    };
    if !info.logged_in || !sync_due(info.next_allowed_at.as_deref(), jiff::Timestamp::now()) {
        return;
    }

    if !scan_archive(session) {
        return;
    }

    let snapshot = {
        let Ok(guard) = session.lock() else {
            return;
        };
        guard.engine().ok().map(|engine| {
            (
                engine.timezone().iana_name().map(str::to_string),
                engine.db_path().to_path_buf(),
            )
        })
    };
    let Some((tz, db_path)) = snapshot else {
        return;
    };
    let store = match tokenstat_core::Store::open(&db_path) {
        Ok(store) => store,
        Err(error) => {
            eprintln!("sync: could not open archive: {error}");
            return;
        }
    };
    let result = tokenstat_sync::sync_scheduled_now(
        &store,
        tokenstat_sync::SyncOptions {
            host_flag: None,
            prune: false,
            window: None,
            dry_run: false,
            tz_name: tz.as_deref(),
        },
    );
    match result {
        Ok(tokenstat_sync::ScheduledOutcome::Synced(_)) => {
            crate::account_activity::invalidate();
        }
        Ok(tokenstat_sync::ScheduledOutcome::NotLoggedIn)
        | Ok(tokenstat_sync::ScheduledOutcome::Held { .. })
        | Ok(tokenstat_sync::ScheduledOutcome::Asleep) => {}
        Ok(tokenstat_sync::ScheduledOutcome::Deferred { reason }) => {
            eprintln!("sync: deferred: {reason}");
        }
        Err(error) => eprintln!("sync: scheduled run failed: {error}"),
    }
}

fn fetch_remote_usage(session: &Mutex<Session>) {
    if !tokenstat_sync::scheduled_network_allowed() {
        return;
    }
    let snapshot = session.lock().ok().and_then(|guard| {
        guard
            .engine()
            .ok()
            .map(|engine| (engine.db_path().to_path_buf(), engine.timezone().clone()))
    });
    let Some((db_path, tz)) = snapshot else {
        return;
    };
    let mut store = match tokenstat_core::Store::open(&db_path) {
        Ok(store) => store,
        Err(error) => {
            eprintln!("fetch: archive unavailable, retrying next minute: {error}");
            return;
        }
    };
    match tokenstat_sync::fetch_remotes(&mut store, &tz, false) {
        Ok(reports) => {
            for report in reports
                .iter()
                .filter(|r| r.failed || (r.events > 0 && !r.from_cache))
            {
                eprintln!(
                    "fetch: {} events={} failed={} {}",
                    report.vendor,
                    report.events,
                    report.failed,
                    report.message.as_deref().unwrap_or("")
                );
            }
        }
        Err(error) => eprintln!("fetch: remote usage failed, retrying next minute: {error}"),
    }
}

fn scan_archive(session: &Mutex<Session>) -> bool {
    let snapshot = session.lock().ok().and_then(|guard| {
        guard
            .engine()
            .ok()
            .map(|engine| (engine.db_path().to_path_buf(), engine.timezone().clone()))
    });
    let Some((db_path, tz)) = snapshot else {
        return false;
    };
    let result = tokenstat_core::Store::open(&db_path).and_then(|mut store| {
        let report =
            tokenstat_core::scan_if_stale(&mut store, &tz, tokenstat_core::AUTO_SCAN_INTERVAL)?;
        Ok((
            report,
            tokenstat_core::archive_is_fresh(&store, tokenstat_core::AUTO_SCAN_INTERVAL)?,
        ))
    });
    match result {
        Ok((Some(ref report), _)) => eprintln!(
            "scan: automatic pass files={} new={} elapsed_ms={}",
            report.files_read, report.events_new, report.elapsed_ms
        ),
        Ok((None, _)) => {}
        Err(ref error) => eprintln!("scan: automatic pass failed, retrying next minute: {error}"),
    }
    result.is_ok_and(|(_, fresh)| fresh)
}

fn sync_due(next: Option<&str>, now: jiff::Timestamp) -> bool {
    next.and_then(|s| s.parse::<jiff::Timestamp>().ok())
        .is_none_or(|next| now >= next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_deadline_controls_sync_instead_of_cli_installation() {
        let now = "2026-09-12T12:05:00Z".parse().unwrap();
        assert!(!sync_due(Some("2026-09-12T12:05:01Z"), now));
        assert!(sync_due(Some("2026-09-12T12:05:00Z"), now));
        assert!(sync_due(Some("2026-09-12T12:00:00Z"), now));
        assert!(sync_due(None, now));
        assert!(sync_due(Some("invalid"), now));
    }
}
