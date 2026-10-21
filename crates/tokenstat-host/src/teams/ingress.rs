// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use crate::{Session, account_session::AccountSnapshot};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tokenstat_identity::MachineIdentity;
use tokenstat_remote::tunnel::{ChannelTransport, TeamChannelHandle};

static ACTIVE: AtomicUsize = AtomicUsize::new(0);
const MAX_CONNECTIONS: usize = 64;
struct Permit<'a>(&'a AtomicUsize);
impl Drop for Permit<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Release);
    }
}
fn reserve(counter: &AtomicUsize, limit: usize) -> Option<Permit<'_>> {
    counter
        .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            if count < limit { Some(count + 1) } else { None }
        })
        .ok()
        .map(|_| Permit(counter))
}

pub(crate) fn accept(
    transport: ChannelTransport,
    channel: TeamChannelHandle,
    owner: AccountSnapshot,
    identity: MachineIdentity,
    session: Arc<Mutex<Session>>,
) {
    let Some(permit) = reserve(&ACTIVE, MAX_CONNECTIONS) else {
        return;
    };
    // A partial Team handshake must not block the relay's personal accept
    // loop. The permit remains held through serving and every failure path.
    let _ = std::thread::Builder::new()
        .name("team-peer".into())
        .spawn(move || {
            let _permit = permit;
            let Ok(connection) =
                tokenstat_remote::handshake_responder_bounded(Box::new(transport), &identity)
            else {
                return;
            };
            super::serve(connection, channel, owner, identity.public_key(), &session);
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_full_team_ingress_refuses_more_work_and_releases_slots_on_every_exit() {
        let counter = AtomicUsize::new(0);
        let first = reserve(&counter, 2).unwrap();
        let second = reserve(&counter, 2).unwrap();
        assert!(reserve(&counter, 2).is_none());
        drop(first);
        let replacement = reserve(&counter, 2).unwrap();
        assert!(reserve(&counter, 2).is_none());
        drop((second, replacement));
        assert_eq!(counter.load(Ordering::Acquire), 0);
    }
}
