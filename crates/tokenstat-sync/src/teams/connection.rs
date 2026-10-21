// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{Checkout, ConnectionTicket, RequestTicket, TeamClient, TeamError};
use tokenstat_identity::{
    PublicKey, hex, public_key_from_hex,
    teams::{TeamTicketBinding, TrustedTeamKeys, VerifiedTeamTicket},
};

/// A destination resolved by the account server and bound to its signed
/// ticket. No caller-supplied host address, publisher or actor becomes trusted.
/// Open a separate Team channel; the host still checks current access before
/// serving scoped requests. This proof never admits a personal connection.
#[derive(Clone)]
pub struct TeamConnectionProof {
    checkout: Checkout,
    ticket: VerifiedTeamTicket,
    host_key: PublicKey,
}
impl std::fmt::Debug for TeamConnectionProof {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("TeamConnectionProof([redacted])")
    }
}
impl TeamConnectionProof {
    pub fn checkout(&self) -> &Checkout {
        &self.checkout
    }
    pub fn ticket(&self) -> &VerifiedTeamTicket {
        &self.ticket
    }
    pub fn host_key(&self) -> &PublicKey {
        &self.host_key
    }
}
impl TeamClient {
    pub fn connection_proof(
        &self,
        request: &RequestTicket,
        repository: &str,
        device_key: &PublicKey,
    ) -> Result<TeamConnectionProof, TeamError> {
        self.connection_proof_at(request, repository, device_key, || {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |now| now.as_secs())
        })
    }
    pub(super) fn connection_proof_at(
        &self,
        request: &RequestTicket,
        repository: &str,
        device_key: &PublicKey,
        clock: impl FnOnce() -> u64,
    ) -> Result<TeamConnectionProof, TeamError> {
        let capabilities = self.capabilities()?;
        if !capabilities.enabled
            || capabilities.version != 1
            || !capabilities
                .features
                .iter()
                .any(|feature| feature == "scoped-connections")
        {
            return Err(TeamError::Unsupported);
        }
        if !capabilities.ready() {
            return Err(TeamError::Rejected {
                status: 403,
                code: "teams_authorization_required".into(),
                message: "Enable Teams for this device in your account settings.".into(),
            });
        }
        if capabilities.device_key.as_deref() != Some(hex(device_key).as_str()) {
            return Err(TeamError::InvalidResponse);
        }
        let actor = capabilities
            .actor_id
            .as_deref()
            .ok_or(TeamError::InvalidResponse)?;
        let checkout = self
            .checkout(&request.organization_id, &request.checkout_id)?
            .checkout;
        let keys = self.verification_keys()?;
        let reply = self.connection_ticket(request)?;
        let proof = verify(
            &keys,
            reply,
            checkout,
            Expected {
                request,
                repository,
                actor,
                device_key,
            },
            clock(),
        )?;
        self.ensure_current()?;
        Ok(proof)
    }
}
struct Expected<'a> {
    request: &'a RequestTicket,
    repository: &'a str,
    actor: &'a str,
    device_key: &'a PublicKey,
}
fn verify(
    keys: &TrustedTeamKeys,
    reply: ConnectionTicket,
    checkout: Checkout,
    expected: Expected<'_>,
    now: u64,
) -> Result<TeamConnectionProof, TeamError> {
    let request = expected.request;
    if checkout.id != request.checkout_id
        || checkout.organization_id != request.organization_id
        || checkout.repository_id != expected.repository
        || reply.host_key != checkout.host_key
        || reply.capabilities != request.capabilities
    {
        return Err(TeamError::InvalidResponse);
    }
    let host_key =
        public_key_from_hex(&checkout.host_key).map_err(|_| TeamError::InvalidResponse)?;
    if hex(&host_key) != checkout.host_key {
        return Err(TeamError::InvalidResponse);
    }
    let ticket = keys
        .verify(
            &reply.ticket,
            &TeamTicketBinding {
                device_key: expected.device_key,
                host_key: &host_key,
                publisher_id: &checkout.publisher_id,
                actor_id: Some(expected.actor),
            },
            now,
        )
        .map_err(|_| TeamError::InvalidResponse)?;
    let claims = ticket.claims();
    let expires: jiff::Timestamp = reply
        .expires_at
        .parse()
        .map_err(|_| TeamError::InvalidResponse)?;
    if claims.org != request.organization_id
        || claims.repository != expected.repository
        || claims.checkout != request.checkout_id
        || claims.share != request.share_id
        || claims.cap != request.capabilities
        || claims.revision < checkout.revision
        || expires.as_second() != claims.exp as i64
    {
        return Err(TeamError::InvalidResponse);
    }
    Ok(TeamConnectionProof {
        checkout,
        ticket,
        host_key,
    })
}
