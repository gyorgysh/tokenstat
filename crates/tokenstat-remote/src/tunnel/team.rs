// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Versioned, bounded Team channel control. Tickets remain unverified until
//! the host checks its own account authority and the authenticated Noise peer.

use super::*;
use serde::{Deserialize, Serialize};

pub(super) const CH_TEAM_OPEN: u8 = 6;
const CH_TEAM_OPENED: u8 = 7;
const CH_TEAM_RENEW: u8 = 8;
const CH_TEAM_RENEWED: u8 = 9;
const MAX_TEAM_CONTROL: usize = 4608;
pub(super) const MAX_BUFFER: usize = 2 * 1024 * 1024;

pub(super) struct TeamChannel {
    target: Option<PublicKey>,
    control: Mutex<Control>,
}
struct Control {
    ticket: TeamTicket,
    pending: Option<TeamTicket>,
    renewals: u64,
}
impl TeamChannel {
    pub(super) fn new(ticket: TeamTicket, target: Option<PublicKey>) -> Self {
        Self {
            target,
            control: Mutex::new(Control {
                ticket,
                pending: None,
                renewals: 0,
            }),
        }
    }
}

/// A revocable handle to one Team channel. It never carries a personal-peer
/// approval. Background runs use separate host authority, not this connection.
#[derive(Clone)]
pub struct TeamChannelHandle {
    session: Arc<TunnelSession>,
    state: Arc<ChannelState>,
}
impl std::fmt::Debug for TeamChannelHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("TeamChannelHandle([redacted])")
    }
}
impl TeamChannelHandle {
    pub(super) fn new(session: Arc<TunnelSession>, state: Arc<ChannelState>) -> Self {
        Self { session, state }
    }
    /// Read the latest unverified ticket only while its channel is live.
    pub fn ticket(&self) -> Result<TeamTicket, RemoteError> {
        let inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.eof || inner.error.is_some() {
            return Err(RemoteError::Closed);
        }
        let team = self.state.team.as_ref().ok_or(RemoteError::Closed)?;
        Ok(team
            .control
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .ticket
            .clone())
    }
    /// The opener renews through the relay, which acknowledges to both ends.
    /// Failed renewal closes only this channel, never the tunnel or other work.
    pub fn renew(&self, ticket: &TeamTicket) -> Result<(), RemoteError> {
        self.ticket()?;
        let team = self.state.team.as_ref().ok_or(RemoteError::Closed)?;
        let target = team.target.ok_or_else(|| {
            RemoteError::Tunnel("only the Team channel opener can renew it".into())
        })?;
        let payload = open_payload(&target, ticket)?;
        let renewal = {
            let mut control = team.control.lock().unwrap_or_else(|e| e.into_inner());
            if control.pending.is_some() {
                return Err(RemoteError::Tunnel(
                    "Team renewal is already pending".into(),
                ));
            }
            control.pending = Some(ticket.clone());
            control.renewals
        };
        if let Err(error) = self
            .session
            .send_channel_frame(CH_TEAM_RENEW, self.state.id, &payload)
        {
            retire(&self.session, &self.state);
            return Err(error);
        }
        let deadline = Instant::now() + OPEN_TIMEOUT;
        let mut inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if inner.eof || inner.error.is_some() {
                return Err(RemoteError::Closed);
            }
            if team
                .control
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .renewals
                != renewal
            {
                return Ok(());
            }
            if Instant::now() >= deadline {
                break;
            }
            let (guard, _) = self
                .state
                .cond
                .wait_timeout(inner, Duration::from_millis(20))
                .unwrap_or_else(|e| e.into_inner());
            inner = guard;
        }
        drop(inner);
        retire(&self.session, &self.state);
        Err(RemoteError::Tunnel(
            "Team channel renewal was not confirmed".into(),
        ))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Open<'a> {
    v: u8,
    host_key: String,
    ticket: &'a str,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Acknowledgement {
    v: u8,
    ticket: TeamTicket,
}
pub(super) fn open_payload(
    target: &PublicKey,
    ticket: &TeamTicket,
) -> Result<Vec<u8>, RemoteError> {
    let bytes = serde_json::to_vec(&Open {
        v: 1,
        host_key: hex(target),
        ticket: ticket.wire_value(),
    })
    .map_err(|_| RemoteError::Tunnel("invalid Team admission".into()))?;
    if bytes.len() > MAX_TEAM_CONTROL {
        return Err(RemoteError::Tunnel("Team admission is too large".into()));
    }
    Ok(bytes)
}
fn acknowledgement(bytes: &[u8]) -> Option<TeamTicket> {
    if bytes.is_empty() || bytes.len() > MAX_TEAM_CONTROL {
        return None;
    }
    let value: Acknowledgement = serde_json::from_slice(bytes).ok()?;
    (value.v == 1).then_some(value.ticket)
}
pub(super) fn matches_open(state: &ChannelState, ticket: Option<&TeamTicket>) -> bool {
    match (&state.team, ticket) {
        (None, None) => true,
        (Some(team), Some(ticket)) => {
            team.control
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .ticket
                .wire_value()
                == ticket.wire_value()
        }
        _ => false,
    }
}
fn retire(session: &TunnelSession, state: &Arc<ChannelState>) {
    {
        let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.error = Some("Team channel authorization ended".into());
        inner.buffer.clear();
        state.cond.notify_all();
    }
    if session.forget_channel(state) {
        let _ = session.queue_channel_frame(CH_CLOSE, state.id, &[], false);
    }
}
pub(super) fn dispatch(session: &Arc<TunnelSession>, op: u8, id: u32, payload: &[u8]) -> bool {
    if !matches!(op, CH_TEAM_OPENED | CH_TEAM_RENEWED) {
        return false;
    }
    let state = session
        .channels
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&id)
        .cloned();
    let Some(ticket) = acknowledgement(payload) else {
        if let Some(state) = state.filter(|state| state.team.is_some()) {
            retire(session, &state);
        }
        return true;
    };
    if op == CH_TEAM_OPENED {
        opened(session, id, Some(ticket));
        return true;
    }
    if let Some(state) = state {
        let Some(team) = &state.team else {
            return true;
        };
        let inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.eof || inner.error.is_some() {
            return true;
        }
        let mut control = team.control.lock().unwrap_or_else(|e| e.into_inner());
        if team.target.is_some()
            && control
                .pending
                .as_ref()
                .is_none_or(|pending| pending.wire_value() != ticket.wire_value())
        {
            drop(control);
            drop(inner);
            retire(session, &state);
            return true;
        }
        control.ticket = ticket;
        control.pending = None;
        control.renewals = control.renewals.wrapping_add(1);
        state.cond.notify_all();
    }
    true
}
