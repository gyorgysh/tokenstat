// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.
//! Who is looking at a conversation right now.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

const LEASE: Duration = Duration::from_secs(30);

fn claims() -> &'static Mutex<HashMap<String, HashMap<String, Instant>>> {
    static CLAIMS: OnceLock<Mutex<HashMap<String, HashMap<String, Instant>>>> = OnceLock::new();
    CLAIMS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock() -> std::sync::MutexGuard<'static, HashMap<String, HashMap<String, Instant>>> {
    claims().lock().unwrap_or_else(PoisonError::into_inner)
}

fn sweep(claims: &mut HashMap<String, HashMap<String, Instant>>, now: Instant) {
    claims.retain(|_, watchers| {
        watchers.retain(|_, until| *until > now);
        !watchers.is_empty()
    });
}

/// Somebody is watching this conversation, as of now.
///
/// Expired claims are dropped on the way past. Nothing else sweeps this map,
/// and without that a machine that has held a thousand conversations over a
/// week would keep a thousand dead deadlines.
pub fn claim(conversation_id: &str, watcher_id: &str) {
    if conversation_id.is_empty() {
        return;
    }
    let now = Instant::now();
    let mut claims = lock();
    sweep(&mut claims, now);
    claims
        .entry(conversation_id.to_string())
        .or_default()
        .insert(watcher_id.to_string(), now + LEASE);
}

/// Nobody is watching this conversation any more.
///
/// An explicit release, for a client that knows it is leaving the screen. It
/// is an optimisation, not the mechanism: the lease is what makes this correct
/// when no release ever arrives.
pub fn release(conversation_id: &str, watcher_id: &str) {
    let mut claims = lock();
    if let Some(watchers) = claims.get_mut(conversation_id) {
        watchers.remove(watcher_id);
        if watchers.is_empty() {
            claims.remove(conversation_id);
        }
    }
}

/// Whether a live claim stands for this conversation.
#[cfg_attr(not(feature = "local-host"), allow(dead_code))]
pub fn is_watched(conversation_id: &str) -> bool {
    let now = Instant::now();
    let mut claims = lock();
    sweep(&mut claims, now);
    claims.contains_key(conversation_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_claim_stands_and_a_release_ends_it() {
        claim("chat-a", "device-a");
        assert!(is_watched("chat-a"));
        assert!(!is_watched("chat-b"));
        release("chat-a", "device-a");
        assert!(!is_watched("chat-a"));
    }

    #[test]
    fn one_device_leaving_does_not_revoke_another_devices_lease() {
        claim("chat-shared", "device-a");
        claim("chat-shared", "device-b");
        release("chat-shared", "device-a");
        assert!(is_watched("chat-shared"));
        release("chat-shared", "device-b");
        assert!(!is_watched("chat-shared"));
    }

    #[test]
    fn a_claim_that_is_not_renewed_expires() {
        claim("chat-expiring", "device-a");
        lock().insert(
            "chat-expiring".to_string(),
            HashMap::from([(
                "device-a".to_string(),
                Instant::now() - Duration::from_secs(1),
            )]),
        );
        assert!(!is_watched("chat-expiring"));
    }

    #[test]
    fn an_empty_id_claims_nothing() {
        claim("", "device-a");
        assert!(!is_watched(""));
    }

    #[test]
    fn expired_claims_are_swept_by_the_next_one() {
        release("kept", "device-a");
        lock().insert(
            "stale".to_string(),
            HashMap::from([(
                "device-a".to_string(),
                Instant::now() - Duration::from_secs(1),
            )]),
        );
        claim("kept", "device-a");
        assert!(!lock().contains_key("stale"));
    }
}
