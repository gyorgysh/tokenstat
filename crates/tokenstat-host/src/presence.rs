// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Who is looking at a conversation right now.
//!
//! A push exists to reach somebody who is not watching. The host cannot see
//! that on its own: it knows a turn ended, not that the person is reading the
//! reply as it lands. So the clients say, and this is where they say it.
//!
//! The Mac app already worked this out for its own banners (`UserPresence`):
//! app in front, window really on screen, and somebody at the keyboard in the
//! last few minutes. The phone knows the same about itself. Either one holding
//! a lease here is enough to keep a push from going out about that
//! conversation, which is what stops the phone in your hand buzzing about the
//! reply on its own screen.
//!
//! # A lease, not a flag
//!
//! Claims expire. An app that is force-quit, crashes, or loses its connection
//! must not leave an account permanently silent, and there is no close event
//! that can be trusted to arrive. So a client re-states its claim on a timer
//! and the claim dies on its own if the timer stops. The failure direction is
//! deliberate: forget to renew and notifications come back, never the reverse.
//!
//! # What is stored
//!
//! A conversation id and a deadline. No device name, no person, no text, and
//! nothing that is written down or leaves this machine. Presence is consulted
//! here and never travels: the push body stays a fixed reason and a machine
//! id, which is the whole guarantee.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// How long one claim stands without being renewed.
///
/// Long enough that a client renewing every ten seconds survives a missed beat
/// or a slow request, short enough that walking away from a Mac starts letting
/// notifications through again before the person is out of the building.
const LEASE: Duration = Duration::from_secs(30);

/// Conversation id to the moment its claim runs out.
fn claims() -> &'static Mutex<HashMap<String, Instant>> {
    static CLAIMS: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
    CLAIMS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock() -> std::sync::MutexGuard<'static, HashMap<String, Instant>> {
    claims().lock().unwrap_or_else(PoisonError::into_inner)
}

/// Somebody is watching this conversation, as of now.
///
/// Expired claims are dropped on the way past. Nothing else sweeps this map,
/// and without that a machine that has held a thousand conversations over a
/// week would keep a thousand dead deadlines.
pub fn claim(conversation_id: &str) {
    if conversation_id.is_empty() {
        return;
    }
    let now = Instant::now();
    let mut claims = lock();
    claims.retain(|_, until| *until > now);
    claims.insert(conversation_id.to_string(), now + LEASE);
}

/// Nobody is watching this conversation any more.
///
/// An explicit release, for a client that knows it is leaving the screen. It
/// is an optimisation, not the mechanism: the lease is what makes this correct
/// when no release ever arrives.
pub fn release(conversation_id: &str) {
    lock().remove(conversation_id);
}

/// Whether a live claim stands for this conversation.
pub fn is_watched(conversation_id: &str) -> bool {
    lock()
        .get(conversation_id)
        .is_some_and(|until| *until > Instant::now())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_claim_stands_and_a_release_ends_it() {
        claim("chat-a");
        assert!(is_watched("chat-a"));
        assert!(!is_watched("chat-b"));
        release("chat-a");
        assert!(!is_watched("chat-a"));
    }

    /// The whole point of the lease. A client that stops renewing must stop
    /// suppressing, with nothing having to notice that it went away.
    #[test]
    fn a_claim_that_is_not_renewed_expires() {
        claim("chat-expiring");
        lock().insert(
            "chat-expiring".to_string(),
            Instant::now() - Duration::from_secs(1),
        );
        assert!(!is_watched("chat-expiring"));
    }

    #[test]
    fn an_empty_id_claims_nothing() {
        claim("");
        assert!(!is_watched(""));
    }

    /// Dead claims do not accumulate: a machine holds one entry per
    /// conversation somebody is actually looking at.
    #[test]
    fn expired_claims_are_swept_by_the_next_one() {
        release("kept");
        lock().insert("stale".to_string(), Instant::now() - Duration::from_secs(1));
        claim("kept");
        assert!(!lock().contains_key("stale"));
    }
}
