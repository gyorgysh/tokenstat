// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Identity attached to the request currently entering dispatch.
//!
//! Unix-socket and in-process calls have no remote peer. The encrypted remote
//! transport installs its authenticated static key for exactly the duration of
//! one dispatch call, so authorization code never trusts a peer id from JSON.

use std::cell::RefCell;

thread_local! {
    static REMOTE_PEER: RefCell<Option<String>> = const { RefCell::new(None) };
}

pub(crate) fn remote_peer() -> Option<String> {
    REMOTE_PEER.with(|peer| peer.borrow().clone())
}

/// Methods that decrypt vault material, open SSH sessions, or change this
/// machine's serving policy belong to the local owner. An approved peer is
/// not that owner.
pub(crate) fn refuse_remote(what: &str) -> Result<(), String> {
    if remote_peer().is_some() {
        Err(format!("{what} are local-only"))
    } else {
        Ok(())
    }
}

pub(crate) fn with_remote_peer<T>(peer: &str, work: impl FnOnce() -> T) -> T {
    struct Restore(Option<String>);
    impl Drop for Restore {
        fn drop(&mut self) {
            REMOTE_PEER.with(|peer| *peer.borrow_mut() = self.0.take());
        }
    }

    let previous = REMOTE_PEER.with(|slot| slot.borrow_mut().replace(peer.to_string()));
    let _restore = Restore(previous);
    work()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_is_scoped_and_restored_when_nested() {
        assert_eq!(remote_peer(), None);
        with_remote_peer("a", || {
            assert_eq!(remote_peer().as_deref(), Some("a"));
            with_remote_peer("b", || assert_eq!(remote_peer().as_deref(), Some("b")));
            assert_eq!(remote_peer().as_deref(), Some("a"));
        });
        assert_eq!(remote_peer(), None);
    }
}
