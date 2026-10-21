// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Separate authority for an accepted, host-owned run. Verification pins the
//! original signed initiator, share and grant; it does not admit a new turn.

use super::{
    JS_MAX_INTEGER, MAX_TICKET_BYTES, TeamCapability, TeamTicketError, TrustedTeamKeys,
    VerifiedTeamTicket, lower_hex, valid_id,
};
use serde::Deserialize;
use std::fmt;

pub const RUN_LEASE_PREFIX: &str = "ts-team-run-v1";
pub const RUN_LEASE_AUDIENCE: &str = "tokenstat-teams-run-host-v1";
pub const MAX_RUN_LEASE_SECONDS: u64 = 30;

#[derive(Clone, Deserialize)]
#[serde(try_from = "String")]
pub struct TeamRunLease(String);
impl TryFrom<String> for TeamRunLease {
    type Error = TeamTicketError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > MAX_TICKET_BYTES
            || !value.starts_with("ts-team-run-v1.")
            || !value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return Err(TeamTicketError::Invalid);
        }
        Ok(Self(value))
    }
}
impl fmt::Debug for TeamRunLease {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TeamRunLease([redacted])")
    }
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamRunClaims {
    pub v: u32,
    pub iss: String,
    pub aud: String,
    pub run: String,
    pub sub: String,
    pub device: String,
    pub org: String,
    pub repository: String,
    pub checkout: String,
    pub share: String,
    pub host: String,
    pub publisher: String,
    pub grant: String,
    pub revision: u64,
    pub iat: u64,
    pub exp: u64,
}

pub struct TeamRunBinding<'a> {
    pub run: &'a str,
    /// The original verified Run ticket, retained after that viewing ticket
    /// expires. Current authority comes from this run's short host-only lease.
    pub initiator: &'a VerifiedTeamTicket,
}

#[derive(Clone)]
pub struct VerifiedTeamRunLease {
    claims: TeamRunClaims,
}
impl fmt::Debug for VerifiedTeamRunLease {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("VerifiedTeamRunLease([redacted])")
    }
}
impl VerifiedTeamRunLease {
    pub fn claims(&self) -> &TeamRunClaims {
        &self.claims
    }
    pub fn lease_seconds(&self, now: u64) -> u64 {
        self.claims
            .exp
            .saturating_sub(now)
            .min(MAX_RUN_LEASE_SECONDS)
    }
}
impl TrustedTeamKeys {
    pub fn verify_run_lease(
        &self,
        lease: &TeamRunLease,
        binding: &TeamRunBinding<'_>,
        now: u64,
    ) -> Result<VerifiedTeamRunLease, TeamTicketError> {
        // Rotation may introduce a new signer during an accepted run. Only
        // this condition permits a bounded key refresh from the pinned origin.
        let parts: Vec<_> = lease.0.split('.').collect();
        if parts.len() == 4
            && parts[0] == RUN_LEASE_PREFIX
            && lower_hex(parts[1], 24)
            && !self.keys.contains_key(parts[1])
        {
            return Err(TeamTicketError::UntrustedAuthority);
        }
        let payload = self.verified_payload(&lease.0, RUN_LEASE_PREFIX)?;
        let c: TeamRunClaims =
            serde_json::from_slice(&payload).map_err(|_| TeamTicketError::Invalid)?;
        if c.v != 1
            || c.iss != self.issuer
            || c.aud != RUN_LEASE_AUDIENCE
            || !c
                .run
                .strip_prefix("runlease_")
                .is_some_and(|id| lower_hex(id, 32))
            || !c
                .grant
                .strip_prefix("grant_")
                .is_some_and(|id| lower_hex(id, 32))
            || !c
                .share
                .strip_prefix("share_")
                .is_some_and(|id| lower_hex(id, 32))
            || ![&c.sub, &c.org, &c.repository, &c.checkout, &c.publisher]
                .iter()
                .all(|id| valid_id(id))
            || !lower_hex(&c.device, 64)
            || !lower_hex(&c.host, 64)
            || ![c.revision, c.iat, c.exp]
                .iter()
                .all(|n| *n <= JS_MAX_INTEGER)
            || c.revision == 0
            || c.iat > now.saturating_add(5)
            || c.exp <= c.iat
            || c.exp - c.iat > MAX_RUN_LEASE_SECONDS
        {
            return Err(TeamTicketError::Invalid);
        }
        if c.exp <= now {
            return Err(TeamTicketError::Expired);
        }
        let actor = binding.initiator.claims();
        if actor.iss != self.issuer
            || !actor.cap.contains(&TeamCapability::Run)
            || c.run != binding.run
            || c.sub != actor.sub
            || c.device != actor.device
            || c.org != actor.org
            || c.repository != actor.repository
            || c.checkout != actor.checkout
            || Some(&c.share) != actor.share.as_ref()
            || c.host != actor.host
            || c.publisher != actor.publisher
            || Some(&c.grant) != actor.grant.as_ref()
        {
            return Err(TeamTicketError::BindingMismatch);
        }
        Ok(VerifiedTeamRunLease { claims: c })
    }
}

#[cfg(test)]
mod tests;
