// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted.

//! Desktop-owned background sync when the CLI has no active schedule.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::session::Session;

const UNLINKED_CHECK_INTERVAL: Duration = Duration::from_secs(60);
const DEFAULT_SYNC_INTERVAL: Duration = Duration::from_secs(60 * 60);

/// Keep aggregate sync alive while the desktop helper is running.
///
/// The CLI remains the owner when its platform scheduler entry exists. Both
/// paths also share the sync lock in `tokenstat-sync`, so a manually triggered
/// sync cannot overlap either scheduler.
pub fn start(session: Arc<Mutex<Session>>) {
    std::thread::spawn(move || {
        loop {
            if !tokenstat_sync::cli_sync_schedule_active() {
                run_once(&session);
            }
            std::thread::sleep(sync_interval());
        }
    });
}

fn sync_interval() -> Duration {
    let Ok(info) = tokenstat_sync::scheduling_info(None) else {
        return UNLINKED_CHECK_INTERVAL;
    };
    if !info.logged_in {
        return UNLINKED_CHECK_INTERVAL;
    }
    info.min_interval
        .map(Duration::from_secs)
        .unwrap_or(DEFAULT_SYNC_INTERVAL)
        .max(UNLINKED_CHECK_INTERVAL)
}

fn run_once(session: &Mutex<Session>) {
    let Ok(guard) = session.lock() else {
        return;
    };
    let tz = guard.engine.timezone().iana_name().map(str::to_string);
    let result = tokenstat_sync::sync_scheduled_now(
        guard.engine.store(),
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
            // The account just changed, so the cached grid is stale by
            // definition. Dropping it here is what makes a machine that has
            // only just uploaded appear on Home without a wait.
            crate::account_activity::invalidate();
        }
        Ok(tokenstat_sync::ScheduledOutcome::NotLoggedIn)
        | Ok(tokenstat_sync::ScheduledOutcome::Held { .. }) => {}
        Ok(tokenstat_sync::ScheduledOutcome::Deferred { reason }) => {
            eprintln!("sync: deferred: {reason}");
        }
        Err(error) => eprintln!("sync: scheduled run failed: {error}"),
    }
}
