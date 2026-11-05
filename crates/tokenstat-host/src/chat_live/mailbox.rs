// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Poll filesystem mailboxes by elapsed time rather than streamed event count.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const INTERVAL: Duration = Duration::from_millis(5);

pub(super) struct Poll {
    next: Instant,
}

impl Poll {
    pub(super) fn new() -> Self {
        Self {
            next: Instant::now(),
        }
    }

    pub(super) fn due(&mut self) -> bool {
        self.due_at(Instant::now())
    }

    fn due_at(&mut self, now: Instant) -> bool {
        if now < self.next {
            return false;
        }
        // A delayed poll performs one check, without replaying missed ticks.
        self.next = now + INTERVAL;
        true
    }
}

pub(super) struct Stop {
    path: PathBuf,
    poll: Poll,
    requested: bool,
}

impl Stop {
    pub(super) fn new(directory: &Path) -> Self {
        Self {
            path: directory.join("stop"),
            poll: Poll::new(),
            requested: false,
        }
    }

    pub(super) fn requested(&mut self) -> bool {
        self.requested_at(Instant::now())
    }

    fn requested_at(&mut self, now: Instant) -> bool {
        if self.requested {
            return true;
        }
        // Signals remain immediate, including between filesystem probes.
        if super::stop_signalled() || (self.poll.due_at(now) && self.path.is_file()) {
            self.requested = true;
        }
        self.requested
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn busy_polling_is_bounded_and_a_delayed_poll_does_not_replay_missed_ticks() {
        let mut poll = Poll::new();
        let now = Instant::now();
        assert!(poll.due_at(now));
        for micros in 0..5_000 {
            assert!(!poll.due_at(now + Duration::from_micros(micros)));
        }
        assert!(poll.due_at(now + INTERVAL));
        assert!(poll.due_at(now + Duration::from_secs(60)));
        assert!(!poll.due_at(now + Duration::from_secs(60)));
    }

    #[test]
    fn a_stop_arriving_between_probes_is_observed_and_stays_requested() {
        let root = tempfile::tempdir().unwrap();
        let mut stop = Stop::new(root.path());
        let now = Instant::now();
        assert!(!stop.requested_at(now));
        std::fs::write(root.path().join("stop"), "").unwrap();
        assert!(!stop.requested_at(now + INTERVAL / 2));
        assert!(stop.requested_at(now + INTERVAL));
        std::fs::remove_file(root.path().join("stop")).unwrap();
        assert!(stop.requested_at(now + INTERVAL * 2));
    }

    #[test]
    fn an_existing_stop_is_observed_on_the_first_probe() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("stop"), "").unwrap();
        assert!(Stop::new(root.path()).requested());
    }
}
