// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! The machines this one has agreed to talk to.
//!
//! Two rules shape everything here, both from `docs/remote-transport.md`.
//!
//! **A key is pinned on first use and never silently replaced.** The account
//! can act as a directory, and a directory that hands out keys can hand out the
//! wrong one. Pinning means the worst a bad directory achieves is a connection
//! that stops working and says why, rather than one somebody is reading.
//!
//! **Nothing is trusted until a person says so.** A peer that connects for the
//! first time lands here as [`Trust::Pending`] and is refused until someone
//! approves it. A remote client can spawn processes and write files, so this is
//! a larger permission than the commit button, not a smaller one.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::{IdentityError, PublicKey, fingerprint, hex, identity_dir, public_key_from_hex};

/// Whether a peer may be talked to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Trust {
    /// Seen, not yet allowed. The only state a new peer can arrive in.
    Pending,
    /// A person approved it.
    Approved,
    /// A person withdrew approval. Kept rather than deleted, so the same key
    /// coming back is recognised as the one that was turned away instead of
    /// arriving as a fresh stranger.
    Revoked,
}

/// One machine, as known to this one.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Peer {
    /// Public key as hex. The identity, and the map key.
    pub key: String,
    /// What to call it. Advisory and changeable: a label is not identity.
    pub label: String,
    pub trust: Trust,
    /// Last address it was reached at or seen from, `host:port`. A hint for
    /// dialling, never a credential: an address proves nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    /// RFC 3339, from the machine's own clock.
    pub first_seen: String,
    pub last_seen: String,
}

impl Peer {
    /// The short form to show beside the name.
    pub fn fingerprint(&self) -> String {
        match public_key_from_hex(&self.key) {
            Ok(key) => fingerprint(&key),
            // A stored key that will not parse cannot be talked to anyway. The
            // caller shows this, so it has to be readable rather than empty.
            Err(_) => "unreadable".into(),
        }
    }

    /// The same key as two words, which is the comparison a person makes.
    pub fn words(&self) -> String {
        match public_key_from_hex(&self.key) {
            Ok(key) => crate::key_words(&key),
            Err(_) => "unreadable".into(),
        }
    }
}

/// Every peer, on disk.
///
/// Small enough to rewrite whole. Contention is not a concern: approvals
/// happen at human speed.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct PeerStore {
    #[serde(default)]
    peers: BTreeMap<String, Peer>,
}

impl PeerStore {
    /// The store, re-read only when the file has actually changed.
    ///
    /// Exists because approval has to be checked **per request** and not only
    /// per connection. Connections are held open and pooled, so a check that
    /// happened once at the handshake would leave a revoked machine connected
    /// and answered for as long as it kept the socket, which is indefinitely.
    /// Revocation has to mean the next request, not the next reconnect.
    ///
    /// One `stat` per request rather than one read and parse. A terminal polls
    /// for output continuously, so the difference is the difference between a
    /// check that is affordable and one somebody removes later.
    pub fn cached() -> Result<Arc<Self>, IdentityError> {
        /// The last read, and the file stamp it was read at.
        type Cached = Mutex<Option<(SystemTime, Arc<PeerStore>)>>;
        static CACHE: OnceLock<Cached> = OnceLock::new();
        let cache = CACHE.get_or_init(|| Mutex::new(None));

        let path = store_path()?;
        // A store that does not exist yet has no peers, and a clock that will
        // not answer means re-reading, which is correct and merely slower.
        let stamp = std::fs::metadata(&path).and_then(|m| m.modified()).ok();

        if let Ok(guard) = cache.lock()
            && let Some((seen, store)) = guard.as_ref()
            && Some(*seen) == stamp
        {
            return Ok(Arc::clone(store));
        }

        let store = Arc::new(Self::load()?);
        if let (Ok(mut guard), Some(stamp)) = (cache.lock(), stamp) {
            *guard = Some((stamp, Arc::clone(&store)));
        }
        Ok(store)
    }

    pub fn load() -> Result<Self, IdentityError> {
        let path = store_path()?;
        if !path.exists() {
            return Ok(Self::default());
        }
        let text = std::fs::read_to_string(&path).map_err(|e| IdentityError::Io {
            path: path.display().to_string(),
            source: e,
        })?;
        // A corrupt file must not lock the user out of their own machines, but
        // it also must not silently discard approvals. Treated as empty here
        // and left on disk, so an approval has to be given again and the
        // evidence is still there to look at.
        Ok(serde_json::from_str(&text).unwrap_or_default())
    }

    pub fn save(&self) -> Result<(), IdentityError> {
        let path = store_path()?;
        let text = serde_json::to_string_pretty(self).map_err(|e| IdentityError::Io {
            path: path.display().to_string(),
            source: std::io::Error::other(e),
        })?;
        std::fs::write(&path, text).map_err(|e| IdentityError::Io {
            path: path.display().to_string(),
            source: e,
        })?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }

    /// Newest contact first, which is the order somebody approving a peer they
    /// just plugged in wants to read.
    pub fn list(&self) -> Vec<Peer> {
        let mut peers: Vec<Peer> = self.peers.values().cloned().collect();
        peers.sort_by(|a, b| b.last_seen.cmp(&a.last_seen));
        peers
    }

    pub fn get(&self, key: &PublicKey) -> Option<&Peer> {
        self.peers.get(&hex(key))
    }

    /// May this peer be served?
    ///
    /// The only question the transport asks. Unknown is not approved, which is
    /// what makes "off until somebody says yes" the default rather than a
    /// setting.
    pub fn is_approved(&self, key: &PublicKey) -> bool {
        self.get(key).is_some_and(|p| p.trust == Trust::Approved)
    }

    /// Record a peer that just made contact, and say whether it may proceed.
    ///
    /// **Never promotes.** A peer already known keeps whatever trust it has,
    /// including `Revoked`: reconnecting is not an argument. A peer not known
    /// is written down as pending, so it shows up in the interface to be
    /// approved instead of being invisible until somebody guesses it tried.
    pub fn seen(
        &mut self,
        key: &PublicKey,
        label: &str,
        address: Option<&str>,
        now: &str,
    ) -> Trust {
        let id = hex(key);
        match self.peers.get_mut(&id) {
            Some(peer) => {
                peer.last_seen = now.to_string();
                if let Some(address) = address {
                    peer.address = Some(address.to_string());
                }
                // The label follows the peer, since a machine renamed on one
                // side should not read as a different machine on the other.
                if !label.is_empty() {
                    peer.label = label.to_string();
                }
                peer.trust
            }
            None => {
                self.peers.insert(
                    id,
                    Peer {
                        key: hex(key),
                        label: if label.is_empty() {
                            "unnamed machine".into()
                        } else {
                            label.into()
                        },
                        trust: Trust::Pending,
                        address: address.map(str::to_string),
                        first_seen: now.to_string(),
                        last_seen: now.to_string(),
                    },
                );
                Trust::Pending
            }
        }
    }

    /// Pin a key somebody typed or picked from the directory.
    ///
    /// Approved outright, because entering a fingerprint by hand *is* the
    /// approval. Returns an error rather than overwriting when the key differs
    /// from one already pinned under a peer somebody meant to keep: see
    /// [`PeerStore::pin`] for why that is refused and not merged.
    pub fn add_approved(
        &mut self,
        key: &PublicKey,
        label: &str,
        address: Option<&str>,
        now: &str,
    ) -> Peer {
        let id = hex(key);
        let peer = self.peers.entry(id).or_insert_with(|| Peer {
            key: hex(key),
            label: label.to_string(),
            trust: Trust::Approved,
            address: address.map(str::to_string),
            first_seen: now.to_string(),
            last_seen: now.to_string(),
        });
        peer.trust = Trust::Approved;
        peer.last_seen = now.to_string();
        if !label.is_empty() {
            peer.label = label.to_string();
        }
        if address.is_some() {
            peer.address = address.map(str::to_string);
        }
        peer.clone()
    }

    /// Check a key against what was pinned for this peer.
    ///
    /// The whole point of the design, in four lines. A changed key is refused
    /// and reported, never accepted quietly, because "the directory gave me a
    /// different key today" and "somebody is standing in the middle" look
    /// exactly the same from here.
    pub fn pin(&self, expected_label: &str, offered: &PublicKey) -> Result<(), PinFailure> {
        match self.peers.values().find(|p| p.label == expected_label) {
            None => Ok(()),
            Some(peer) if peer.key == hex(offered) => Ok(()),
            Some(peer) => Err(PinFailure {
                label: peer.label.clone(),
                pinned: peer.fingerprint(),
                offered: fingerprint(offered),
            }),
        }
    }

    pub fn approve(&mut self, key: &PublicKey) -> bool {
        match self.peers.get_mut(&hex(key)) {
            Some(peer) => {
                peer.trust = Trust::Approved;
                true
            }
            None => false,
        }
    }

    /// Withdraw approval. The record stays, so the key is remembered as one
    /// that was turned away rather than arriving fresh next time.
    pub fn revoke(&mut self, key: &PublicKey) -> bool {
        match self.peers.get_mut(&hex(key)) {
            Some(peer) => {
                peer.trust = Trust::Revoked;
                true
            }
            None => false,
        }
    }

    /// Forget a peer entirely. Distinct from revoking: this one comes back as
    /// a stranger, which is what somebody decommissioning a machine wants.
    pub fn forget(&mut self, key: &PublicKey) -> bool {
        self.peers.remove(&hex(key)).is_some()
    }
}

/// A peer offered a key that is not the one pinned for it.
#[derive(Debug, Clone)]
pub struct PinFailure {
    pub label: String,
    pub pinned: String,
    pub offered: String,
}

impl std::fmt::Display for PinFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} offered the key {} but {} was pinned for it. \
             Refusing to connect. Either the machine was reinstalled, in which \
             case forget it here and pair it again, or something is answering \
             in its place.",
            self.label, self.offered, self.pinned
        )
    }
}

fn store_path() -> Result<PathBuf, IdentityError> {
    Ok(identity_dir()?.join("peers.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(n: u8) -> PublicKey {
        // Any 32 bytes: these never have to verify a signature, only be
        // distinct and stable.
        [n; 32]
    }

    #[test]
    fn an_unknown_peer_is_not_approved() {
        let store = PeerStore::default();
        assert!(!store.is_approved(&key(1)));
    }

    #[test]
    fn first_contact_is_pending_and_recorded() {
        let mut store = PeerStore::default();
        assert_eq!(
            store.seen(
                &key(1),
                "laptop",
                Some("10.0.0.2:7878"),
                "2026-08-04T10:00:00Z"
            ),
            Trust::Pending
        );
        assert!(!store.is_approved(&key(1)), "pending is not approved");
        let peer = store.get(&key(1)).expect("recorded");
        assert_eq!(peer.label, "laptop");
        assert_eq!(peer.address.as_deref(), Some("10.0.0.2:7878"));
    }

    /// The one that matters. A peer that keeps knocking must not talk its way
    /// in, and a revoked peer reconnecting is exactly what that looks like.
    #[test]
    fn reconnecting_never_promotes_a_peer() {
        let mut store = PeerStore::default();
        store.seen(&key(1), "laptop", None, "2026-08-04T10:00:00Z");
        store.approve(&key(1));
        store.revoke(&key(1));

        for _ in 0..5 {
            assert_eq!(
                store.seen(&key(1), "laptop", None, "2026-08-04T11:00:00Z"),
                Trust::Revoked
            );
        }
        assert!(!store.is_approved(&key(1)));
    }

    #[test]
    fn approval_and_revocation_move_one_peer_only() {
        let mut store = PeerStore::default();
        store.seen(&key(1), "a", None, "2026-08-04T10:00:00Z");
        store.seen(&key(2), "b", None, "2026-08-04T10:00:00Z");
        store.approve(&key(1));
        assert!(store.is_approved(&key(1)));
        assert!(!store.is_approved(&key(2)));
    }

    #[test]
    fn approving_a_peer_that_was_never_seen_does_nothing() {
        let mut store = PeerStore::default();
        assert!(!store.approve(&key(9)));
        assert!(!store.is_approved(&key(9)));
    }

    /// Pairing by hand is the path that works with the hosted service switched
    /// off, so it has to be the one that needs no prior contact.
    #[test]
    fn a_typed_key_is_approved_without_ever_having_connected() {
        let mut store = PeerStore::default();
        store.add_approved(&key(3), "desk", None, "2026-08-04T10:00:00Z");
        assert!(store.is_approved(&key(3)));
    }

    #[test]
    fn a_changed_key_for_a_known_peer_is_refused() {
        let mut store = PeerStore::default();
        store.add_approved(&key(1), "laptop", None, "2026-08-04T10:00:00Z");

        assert!(store.pin("laptop", &key(1)).is_ok());
        let failure = store.pin("laptop", &key(2)).expect_err("must refuse");
        // The message is the product here: it has to tell somebody which of
        // the two explanations to go and check.
        let words = failure.to_string();
        assert!(words.contains("reinstalled"), "{words}");
        assert!(words.contains("in its place"), "{words}");
    }

    #[test]
    fn a_peer_nobody_knows_pins_nothing() {
        let store = PeerStore::default();
        assert!(store.pin("stranger", &key(1)).is_ok());
    }

    #[test]
    fn forgetting_and_revoking_are_different() {
        let mut store = PeerStore::default();
        store.add_approved(&key(1), "a", None, "2026-08-04T10:00:00Z");
        store.revoke(&key(1));
        assert!(store.get(&key(1)).is_some(), "revoked is remembered");

        store.forget(&key(1));
        assert!(store.get(&key(1)).is_none(), "forgotten is gone");
        // And so it arrives as a stranger rather than as a refusal.
        assert_eq!(
            store.seen(&key(1), "a", None, "2026-08-04T12:00:00Z"),
            Trust::Pending
        );
    }

    #[test]
    fn the_list_reads_newest_contact_first() {
        let mut store = PeerStore::default();
        store.seen(&key(1), "old", None, "2026-08-01T10:00:00Z");
        store.seen(&key(2), "new", None, "2026-08-04T10:00:00Z");
        let listed = store.list();
        assert_eq!(listed[0].label, "new");
        assert_eq!(listed[1].label, "old");
    }
}
