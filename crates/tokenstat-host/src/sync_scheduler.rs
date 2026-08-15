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
        // Fresh installs have no CLI and no price book, and the Home screen
        // would otherwise read as all-zero values until the first hourly pass.
        // Refresh once up front; a machine offline right now keeps its last
        // known book and retries with the schedule.
        if tokenstat_sync::scheduled_network_allowed() {
            refresh_pricing(&session);
            post_limits();
        }
        loop {
            if tokenstat_sync::scheduled_network_allowed() {
                if !tokenstat_sync::cli_sync_schedule_active() {
                    run_once(&session);
                }
                refresh_pricing(&session);
                post_limits();
            }
            std::thread::sleep(sync_interval());
        }
    });
}

/// Put this machine's plan-limit readings on the account, if the user asked
/// for that.
///
/// It used to ride `usage.limits`, which only runs when a front end asks. So
/// the phone's copy was as old as the last time somebody opened Home or
/// Insights **on the Mac**, and a Mac that was working all day without its
/// window in front never posted at all. The whole point of the setting is that
/// the phone can see the numbers while the Mac is asleep, which cannot depend
/// on somebody having looked at the Mac first.
///
/// Off unless the setting is on. This runs the same vendor pass `usage.limits`
/// runs, and that pass posts, so a scheduled refresh and a person opening
/// Insights take the identical path and cannot disagree about what was sent.
/// Quiet on failure: a machine that is offline keeps whatever the account
/// already has, and the next pass retries.
///
/// Two gates beyond the switch, because this pass is five vendor APIs and not
/// a local read. Signed out there is nowhere to post to, so the whole pass is
/// wasted work against somebody else's rate limit. And its own interval, which
/// the sync loop's cannot be: that one drops to a minute whenever the machine
/// is unlinked or the server asks for it, and a vendor sweep every minute is
/// how an account gets itself throttled.
fn post_limits() {
    if !tokenstat_sync::scheduled_network_allowed() {
        return;
    }
    if !tokenstat_sync::config::limits_sync_enabled() {
        return;
    }
    // Posting needs the login credential. Without one the vendor reads have
    // nowhere to go, and the switch being on is a statement of intent for when
    // the machine is signed in again, not a licence to keep polling.
    if !tokenstat_sync::scheduling_info(None).is_ok_and(|info| info.logged_in) {
        return;
    }
    if !limits_pass_is_due() {
        return;
    }
    crate::dispatch::refresh_plan_limits();
}

/// How often the vendors are asked, whatever the sync loop is doing.
///
/// A quota window moves over hours, so an hour is already finer than the thing
/// being measured, and a person who wants the number now opens Insights, which
/// runs the pass on the spot.
const LIMITS_REFRESH_INTERVAL: Duration = Duration::from_secs(60 * 60);

fn limits_pass_is_due() -> bool {
    use std::sync::OnceLock;
    static LAST: OnceLock<Mutex<Option<std::time::Instant>>> = OnceLock::new();
    let cell = LAST.get_or_init(|| Mutex::new(None));
    let Ok(mut last) = cell.lock() else {
        return false;
    };
    match *last {
        Some(at) if at.elapsed() < LIMITS_REFRESH_INTERVAL => false,
        _ => {
            *last = Some(std::time::Instant::now());
            true
        }
    }
}

/// Fetch the hosted list-rate snapshot and write it where the core reads it.
///
/// Quiet on success. A failure is the machine being offline or the feed being
/// down: the previous book (or the built-in estimate rates) keeps values
/// readable, and the next pass retries.
fn refresh_pricing(session: &Mutex<Session>) {
    if !tokenstat_sync::scheduled_network_allowed() {
        return;
    }
    match tokenstat_sync::pricing::refresh(false) {
        Ok(refreshed) => {
            // The fetch wrote a new file; the session still prices from the
            // book it opened with. Reload it, or every report keeps pricing
            // against the empty book a fresh install opened with.
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
    info.min_interval
        .map(Duration::from_secs)
        .unwrap_or(DEFAULT_SYNC_INTERVAL)
        .max(UNLINKED_CHECK_INTERVAL)
}

fn run_once(session: &Mutex<Session>) {
    if !tokenstat_sync::scheduled_network_allowed() {
        return;
    }
    // Snapshot path and timezone under the lock, then open a separate Store for
    // the HTTP phase. Holding Session across the upload freezes Home/Insights.
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
    // Nothing to upload. A host with no archive of its own is a client, and a
    // client has no usage to sync.
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
            // The account just changed, so the cached grid is stale by
            // definition. Dropping it here is what makes a machine that has
            // only just uploaded appear on Home without a wait.
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
