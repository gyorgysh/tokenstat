// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{current_team_scope, load_settings, session_for_serving, team_reach, tunnel_lifecycle};
use crate::{account_session::AccountSnapshot, error::DispatchError, teams::api_error};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokenstat_identity::MachineIdentity;
use tokenstat_remote::{Connection, handshake_initiator_bounded, tunnel::TeamChannelHandle};
use tokenstat_sync::teams::{
    RequestTicket, TeamCapability, TeamClient, TeamConnectionProof, TeamError,
};

// A canonical transcript record may be 4 MiB. Keep a hard transport cap while
// allowing that record and JSON framing to reach the existing renderer intact.
const RESPONSE_LIMIT: usize = 8 * 1024 * 1024;
const RESPONSE_TIME: Duration = Duration::from_secs(15);

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) enum ReadMethod {
    #[serde(rename = "team.protocol")]
    Protocol,
    #[serde(rename = "team.checkout.info")]
    CheckoutInfo,
    #[serde(rename = "team.chat.details")]
    ChatDetails,
    #[serde(rename = "team.chat.events")]
    ChatEvents,
}
impl ReadMethod {
    fn wire(self) -> &'static str {
        match self {
            Self::Protocol => "team.protocol",
            Self::CheckoutInfo => "team.checkout.info",
            Self::ChatDetails => "team.chat.details",
            Self::ChatEvents => "team.chat.events",
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReadParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) direction: Option<PageDirection>,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum PageDirection {
    Older,
    Newer,
}
impl ReadParams {
    pub(crate) fn validate(&self, method: ReadMethod, share: Option<&str>) -> bool {
        match method {
            ReadMethod::Protocol | ReadMethod::CheckoutInfo => {
                self.cursor.is_none() && self.limit.is_none() && self.direction.is_none()
            }
            ReadMethod::ChatDetails => {
                share.is_some()
                    && self.cursor.is_none()
                    && self.limit.is_none()
                    && self.direction.is_none()
            }
            ReadMethod::ChatEvents => {
                share.is_some()
                    && self.limit.is_none_or(|limit| (1..=100).contains(&limit))
                    && self.after(share.unwrap_or_default()).is_ok()
            }
        }
    }
    pub(crate) fn after(&self, share: &str) -> Result<Option<u64>, DispatchError> {
        self.cursor
            .as_deref()
            .map(|cursor| {
                let prefix = format!("v1:{share}:");
                cursor
                    .strip_prefix(&prefix)
                    .filter(|value| {
                        !value.is_empty()
                            && value.len() <= 20
                            && value.bytes().all(|b| b.is_ascii_digit())
                    })
                    .and_then(|value| value.parse::<u64>().ok())
                    .ok_or_else(|| api_error(TeamError::InvalidRequest))
            })
            .transpose()
    }
}

pub(crate) fn unavailable() -> DispatchError {
    DispatchError::new(
        "team_connection_unavailable",
        "This shared checkout could not be reached. Refresh and try again.",
    )
}
fn invalid() -> DispatchError {
    DispatchError::new(
        "team_connection_invalid",
        "The shared checkout returned an unexpected response. Connect again.",
    )
}
fn wall() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |value| value.as_secs())
}
fn deadline(proof: &TeamConnectionProof) -> Result<Instant, DispatchError> {
    let seconds = proof.ticket().lease_seconds(wall());
    if seconds == 0 {
        return Err(unavailable());
    }
    Ok(Instant::now() + Duration::from_secs(seconds))
}

// The private fields prevent construction without the verified account proof,
// exact host Noise pin and separately admitted Team channel.
pub(crate) struct Link {
    connection: Connection,
    channel: TeamChannelHandle,
    tunnel: tunnel_lifecycle::OwnedTunnel,
    owner: AccountSnapshot,
    client: Arc<TeamClient>,
    request: RequestTicket,
    repository: String,
    identity: MachineIdentity,
    proof: TeamConnectionProof,
    deadline: Instant,
    next_id: u64,
    _reach: team_reach::Demand,
}
impl Link {
    pub(crate) fn connect(
        owner: AccountSnapshot,
        client: Arc<TeamClient>,
        request: RequestTicket,
        repository: String,
        expected_key: tokenstat_identity::PublicKey,
    ) -> Result<Self, DispatchError> {
        owner
            .ensure_current()
            .map_err(|_| api_error(TeamError::AccountChanged))?;
        if request.capabilities != [TeamCapability::Read] {
            return Err(api_error(TeamError::InvalidRequest));
        }
        let identity = MachineIdentity::load()
            .map_err(|_| unavailable())?
            .ok_or_else(unavailable)?;
        if identity.public_key() != expected_key {
            return Err(api_error(TeamError::AccountChanged));
        }
        let proof = client
            .connection_proof(&request, &repository, &identity.public_key())
            .map_err(api_error)?;
        let deadline = deadline(&proof)?;
        if proof.ticket().claims().iss != client.origin() {
            return Err(invalid());
        }
        let scope = current_team_scope(&owner).map_err(|_| api_error(TeamError::AccountChanged))?;
        if scope.key != identity.public_key() {
            return Err(api_error(TeamError::AccountChanged));
        }
        let reach = team_reach::acquire(scope).map_err(|_| unavailable())?;
        let tunnel = crate::account_session::with_snapshot(Some(owner.clone()), || {
            tunnel_lifecycle::ensure(session_for_serving()?, &load_settings(), false)
        })
        .map_err(|_| unavailable())?
        .ok_or_else(unavailable)?;
        // Socket creation is asynchronous. An initial Team open must wait for
        // READY, rather than racing the writer's first registration.
        let ready_deadline = (Instant::now() + Duration::from_secs(10)).min(deadline);
        let socket = tunnel.socket().map_err(|_| unavailable())?;
        while !socket.status().connected {
            tunnel.ensure_current().map_err(|_| unavailable())?;
            if Instant::now() >= ready_deadline {
                return Err(unavailable());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let transport = socket
            .open_team_channel(*proof.host_key(), proof.ticket().ticket())
            .map_err(|_| unavailable())?;
        let channel = transport.team_authorization().ok_or_else(invalid)?;
        let connection =
            handshake_initiator_bounded(Box::new(transport), &identity, *proof.host_key())
                .map_err(|_| unavailable())?;
        let mut link = Self {
            connection,
            channel,
            tunnel,
            owner,
            client,
            request,
            repository,
            identity,
            proof,
            deadline,
            next_id: 1,
            _reach: reach,
        };
        link.ensure_current()?;
        let protocol = link.call(ReadMethod::Protocol, &ReadParams::default())?;
        link.verify_protocol(&protocol)?;
        Ok(link)
    }

    pub(crate) fn ensure_current(&self) -> Result<(), DispatchError> {
        self.owner
            .ensure_current()
            .map_err(|_| api_error(TeamError::AccountChanged))?;
        self.client.ensure_current().map_err(api_error)?;
        self.tunnel.ensure_current().map_err(|_| unavailable())?;
        if Instant::now() >= self.deadline || self.proof.ticket().claims().exp <= wall() {
            return Err(unavailable());
        }
        Ok(())
    }

    pub(crate) fn call(
        &mut self,
        method: ReadMethod,
        params: &ReadParams,
    ) -> Result<Value, DispatchError> {
        self.ensure_current()?;
        if !params.validate(method, self.request.share_id.as_deref()) {
            return Err(api_error(TeamError::InvalidRequest));
        }
        let id = self.next_id;
        self.next_id = self.next_id.checked_add(1).ok_or_else(invalid)?;
        let request = serde_json::to_vec(&json!({"id":id,"method":method.wire(),"params":params}))
            .map_err(|_| invalid())?;
        self.connection.send(&request).map_err(|_| unavailable())?;
        let time = RESPONSE_TIME.min(self.deadline.saturating_duration_since(Instant::now()));
        let bytes = self
            .connection
            .receive_bounded(RESPONSE_LIMIT, time)
            .map_err(|_| unavailable())?;
        self.ensure_current()?;
        reply(&bytes, id)
    }

    pub(crate) fn renew(&mut self) -> Result<(), DispatchError> {
        self.ensure_current()?;
        let next = self
            .client
            .connection_proof(&self.request, &self.repository, &self.identity.public_key())
            .map_err(api_error)?;
        let previous = self.proof.ticket().claims();
        let current = next.ticket().claims();
        if next.host_key() != self.proof.host_key()
            || current.token != previous.token
            || current.consent != previous.consent
            || current.publisher != previous.publisher
            || current.sub != previous.sub
            || current.device != previous.device
            || current.org != previous.org
            || current.repository != previous.repository
            || current.checkout != previous.checkout
            || current.share != previous.share
            || current.cap != previous.cap
            || current.epoch < previous.epoch
            || current.revision < previous.revision
            || current.iat < previous.iat
            || current.exp < previous.exp
        {
            return Err(api_error(TeamError::AccountChanged));
        }
        let next_deadline = deadline(&next)?;
        self.channel
            .renew(next.ticket().ticket())
            .map_err(|_| unavailable())?;
        self.tunnel.ensure_current().map_err(|_| unavailable())?;
        self.proof = next;
        self.deadline = next_deadline;
        // The relay ACK updates the host's channel ticket. This request makes
        // its authorization gate observe that ticket before the old deadline.
        let protocol = self.call(ReadMethod::Protocol, &ReadParams::default())?;
        self.verify_protocol(&protocol)
    }

    fn verify_protocol(&self, value: &Value) -> Result<(), DispatchError> {
        if value["version"] != 1
            || value["issuer"].as_str() != Some(self.client.origin())
            || value["organizationId"].as_str() != Some(self.request.organization_id.as_str())
            || value["repositoryId"].as_str() != Some(self.repository.as_str())
            || value["checkoutId"].as_str() != Some(self.request.checkout_id.as_str())
        {
            return Err(invalid());
        }
        if value["protocolVersion"]
            .as_str()
            .and_then(|version| version.parse::<u32>().ok())
            .is_none_or(|version| {
                version
                    < if self.request.share_id.is_some() {
                        42
                    } else {
                        41
                    }
            })
            || self.request.share_id.is_some() && value["sharedChats"] != true
        {
            return Err(DispatchError::new(
                "team_host_update_required",
                "Update tokenstat on the publishing computer to connect to this checkout.",
            ));
        }
        Ok(())
    }
}
impl Drop for Link {
    fn drop(&mut self) {
        self.connection.close();
    }
}

fn reply(bytes: &[u8], expected_id: u64) -> Result<Value, DispatchError> {
    let mut value: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    if value["id"].as_u64() != Some(expected_id) {
        return Err(invalid());
    }
    match value["ok"].as_bool() {
        Some(true) if value.get("result").is_some() && value.get("error").is_none() => {
            Ok(value["result"].take())
        }
        Some(false) if value.get("result").is_none() => {
            let code = value["error"]["code"]
                .as_str()
                .filter(|code| {
                    !code.is_empty()
                        && code.len() <= 64
                        && code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                })
                .ok_or_else(invalid)?;
            Err(DispatchError::new(
                code,
                "Team access changed or this checkout is unavailable. Refresh and try again.",
            ))
        }
        _ => Err(invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replies_cannot_cross_request_ids_or_inject_unbounded_server_messages() {
        assert_eq!(
            reply(br#"{"id":7,"ok":true,"result":{"state":"available"}}"#, 7).unwrap()["state"],
            "available"
        );
        for bytes in [
            br#"{"id":8,"ok":true,"result":{}}"#.as_slice(),
            br#"{"id":7,"ok":true,"result":{},"error":{}}"#,
            br#"{"id":7,"ok":false,"error":{"code":["forbidden"]}}"#,
        ] {
            assert!(reply(bytes, 7).is_err());
        }
        let error = reply(br#"{"id":7,"ok":false,"error":{"code":"forbidden","message":"PRIVATE SERVER DIAGNOSTIC"}}"#,7).unwrap_err();
        assert_eq!(error.code, "forbidden");
        assert!(!error.message.contains("PRIVATE"));
    }
}
