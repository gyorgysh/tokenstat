// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted.

//! Background sync coordinated with the CLI through the shared cursor and lock.

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
    let maintenance_session = Arc::clone(&session);
    // Slow pricing/vendor requests must not postpone an upload deadline.
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
/// The remembered account-plan interval paces vendor reads. Keep a five-minute
/// floor and an hourly fallback until the server has established the cadence.
/// Slow vendor calls stay on maintenance's thread, away from upload deadlines.
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
    let Ok(info) = tokenstat_sync::scheduling_info(None) else {
        return;
    };
    if !info.logged_in {
        return;
    }
    if !limits_pass_is_due(limits_refresh_interval(info.min_interval)) {
        return;
    }
    crate::dispatch::refresh_plan_limits();
}

const PRICING_REFRESH_INTERVAL: Duration = Duration::from_secs(60 * 60);

fn limits_refresh_interval(plan_interval: Option<u64>) -> Duration {
    Duration::from_secs(
        plan_interval
            .filter(|seconds| *seconds > 0)
            .unwrap_or(3600)
            .max(300),
    )
}

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
    // The upload path enforces the server's deadline. Polling that deadline
    // avoids sleeping another full interval after a held or failed attempt.
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

fn sync_due(next: Option<&str>, now: jiff::Timestamp) -> bool {
    next.and_then(|s| s.parse::<jiff::Timestamp>().ok())
        .is_none_or(|next| now >= next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_follow_account_plan_without_rapid_polling() {
        assert_eq!(limits_refresh_interval(Some(300)), Duration::from_secs(300));
        assert_eq!(limits_refresh_interval(Some(900)), Duration::from_secs(900));
        assert_eq!(
            limits_refresh_interval(Some(86400)),
            Duration::from_secs(86400)
        );
        assert_eq!(limits_refresh_interval(Some(60)), Duration::from_secs(300));
        assert_eq!(limits_refresh_interval(Some(0)), Duration::from_secs(3600));
        assert_eq!(limits_refresh_interval(None), Duration::from_secs(3600));
    }

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
