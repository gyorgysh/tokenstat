// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{current_team_scope, load_settings, session_for_serving, team_reach, tunnel_lifecycle};
use crate::lease_clock::Deadline;
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
/// An Ask answers once its agent has started, which can take a login shell.
const ASK_RESPONSE_TIME: Duration = Duration::from_secs(90);

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CommentInput {
    pub text: String,
    pub client_message_id: String,
    pub client_message_created_at_ms: i64,
}
impl CommentInput {
    pub(crate) fn valid_id(id: &str) -> bool {
        !id.is_empty()
            && id.len() <= 128
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
    }
    pub(crate) fn validate(&self) -> Result<(), DispatchError> {
        if self.text.trim().is_empty()
            || self.text.len() > 8192
            || !Self::valid_id(&self.client_message_id)
            || self.client_message_created_at_ms <= 0
            || !serde_json::to_vec(self).is_ok_and(|bytes| bytes.len() <= 14 * 1024)
        {
            return Err(DispatchError::new(
                "invalid_comment",
                "Enter a shorter comment and try again.",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) enum ReadMethod {
    #[serde(rename = "team.protocol")]
    Protocol,
    #[serde(rename = "team.checkout.info")]
    CheckoutInfo,
    #[serde(rename = "team.chat.catalog")]
    ChatCatalog,
    #[serde(rename = "team.chat.details")]
    ChatDetails,
    #[serde(rename = "team.chat.events")]
    ChatEvents,
    #[serde(rename = "team.chat.receipt")]
    ChatReceipt,
    #[serde(rename = "team.lanes")]
    Lanes,
    /// One file the shared history shows, from the publishing computer.
    #[serde(rename = "team.chat.attachment")]
    ChatAttachment,
}
impl ReadMethod {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::Protocol => "team.protocol",
            Self::CheckoutInfo => "team.checkout.info",
            Self::ChatCatalog => "team.chat.catalog",
            Self::ChatDetails => "team.chat.details",
            Self::ChatEvents => "team.chat.events",
            Self::ChatReceipt => "team.chat.receipt",
            Self::Lanes => "team.lanes",
            Self::ChatAttachment => "team.chat.attachment",
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) client_message_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) attachment: Option<String>,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum PageDirection {
    Older,
    Newer,
}
impl ReadParams {
    pub(crate) fn validate(&self, method: ReadMethod, share: Option<&str>) -> bool {
        if method != ReadMethod::ChatReceipt && self.client_message_id.is_some()
            || method != ReadMethod::ChatAttachment && self.attachment.is_some()
        {
            return false;
        }
        match method {
            ReadMethod::Protocol | ReadMethod::CheckoutInfo | ReadMethod::Lanes => {
                self.cursor.is_none() && self.limit.is_none() && self.direction.is_none()
            }
            ReadMethod::ChatCatalog => {
                share.is_none()
                    && self.direction.is_none()
                    && self.limit.is_none_or(|limit| (1..=100).contains(&limit))
                    && self.cursor.as_ref().is_none_or(|cursor| {
                        cursor.len() <= 180 && cursor.starts_with("v1:catalog:")
                    })
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
            ReadMethod::ChatAttachment => {
                share.is_some()
                    && self.cursor.is_none()
                    && self.limit.is_none()
                    && self.direction.is_none()
                    && self.attachment.as_deref().is_some_and(|id| {
                        !id.is_empty()
                            && id.len() <= 128
                            && id.bytes().all(|b| {
                                b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.')
                            })
                    })
            }
            ReadMethod::ChatReceipt => {
                share.is_some()
                    && self.cursor.is_none()
                    && self.limit.is_none()
                    && self.direction.is_none()
                    && self
                        .client_message_id
                        .as_deref()
                        .is_some_and(CommentInput::valid_id)
            }
        }
    }
    #[cfg(any(test, feature = "local-host"))]
    pub(crate) fn catalog_offset(&self, checkout: &str) -> Result<u32, DispatchError> {
        let Some(cursor) = self.cursor.as_deref() else {
            return Ok(0);
        };
        cursor
            .strip_prefix(&format!("v1:catalog:{checkout}:"))
            .filter(|value| {
                !value.is_empty()
                    && value.len() <= 5
                    && value.bytes().all(|byte| byte.is_ascii_digit())
            })
            .and_then(|value| value.parse::<u32>().ok())
            .filter(|offset| *offset <= 10000)
            .ok_or_else(|| api_error(TeamError::InvalidRequest))
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
        "The computer sharing this project is not reachable right now. It needs to be on, with tokenstat open.",
    )
}
/// This device could not hold its own connection to the relay.
fn relay_unreachable() -> DispatchError {
    DispatchError::new(
        "team_relay_unreachable",
        "This device could not reach the tokenstat relay. Check the connection and try again.",
    )
}
/// The relay answered the team channel with a refusal or never paired it.
/// Its reason codes are stable and say which side to look at, so they are
/// kept rather than folded into one sentence that fits every failure.
fn relay_refused(reason: &str) -> DispatchError {
    if reason.contains("no_such_peer") {
        return unavailable();
    }
    if reason.contains("did not pair") {
        return DispatchError::new(
            "team_relay_timeout",
            "The relay did not answer this team connection in time. Try again shortly.",
        );
    }
    let code = reason
        .rsplit(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .find(|part| !part.is_empty())
        .unwrap_or("unknown");
    DispatchError::new(
        "team_relay_refused",
        format!("The relay refused this team connection ({code})."),
    )
}
/// The sharing computer was reached but did not accept the connection.
fn host_refused() -> DispatchError {
    DispatchError::new(
        "team_host_refused",
        "The computer sharing this project did not accept the connection. Update tokenstat there and try again.",
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

enum Transport {
    // The physical publisher still obtains and validates the same signed
    // read proof. There is no socket to pair back to itself.
    Local,
    Relay(Box<Relay>),
}
#[derive(Clone, Copy)]
enum Purpose {
    Read,
    Comment,
    Run,
}

/// The only methods an Ask connection may send. Each needs the Run capability.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
pub(crate) enum AskMethod {
    #[serde(rename = "team.chat.ask.review")]
    Review,
    #[serde(rename = "team.chat.ask")]
    Send,
    #[serde(rename = "team.chat.ask.stop")]
    Stop,
    #[serde(rename = "team.chat.ask.status")]
    Status,
    #[serde(rename = "team.lanes.land")]
    Land,
    #[serde(rename = "team.lanes.discard")]
    Discard,
    /// Start a fresh shared chat on the publishing computer. The only Ask
    /// method sent without a share, because the share does not exist yet.
    #[serde(rename = "team.chat.new")]
    New,
}
impl AskMethod {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::Review => "team.chat.ask.review",
            Self::Send => "team.chat.ask",
            Self::Stop => "team.chat.ask.stop",
            Self::Status => "team.chat.ask.status",
            Self::Land => "team.lanes.land",
            Self::Discard => "team.lanes.discard",
            Self::New => "team.chat.new",
        }
    }
}
struct Relay {
    connection: Connection,
    channel: TeamChannelHandle,
    tunnel: tunnel_lifecycle::OwnedTunnel,
    _reach: team_reach::Demand,
}

// The private fields prevent construction without the verified account proof.
// A different computer additionally requires the pinned Noise/Team channel.
pub(crate) struct Link {
    transport: Transport,
    owner: AccountSnapshot,
    client: Arc<TeamClient>,
    request: RequestTicket,
    repository: String,
    identity: MachineIdentity,
    proof: TeamConnectionProof,
    deadline: Instant,
    continuous_deadline: Deadline,
    next_id: u64,
}
impl Link {
    pub(crate) fn connect(
        owner: AccountSnapshot,
        client: Arc<TeamClient>,
        request: RequestTicket,
        repository: String,
        expected_key: tokenstat_identity::PublicKey,
    ) -> Result<Self, DispatchError> {
        Self::connect_for(
            owner,
            client,
            request,
            repository,
            expected_key,
            Purpose::Read,
        )
    }
    pub(crate) fn connect_comment(
        owner: AccountSnapshot,
        client: Arc<TeamClient>,
        request: RequestTicket,
        repository: String,
        expected_key: tokenstat_identity::PublicKey,
    ) -> Result<Self, DispatchError> {
        Self::connect_for(
            owner,
            client,
            request,
            repository,
            expected_key,
            Purpose::Comment,
        )
    }
    pub(crate) fn connect_run(
        owner: AccountSnapshot,
        client: Arc<TeamClient>,
        request: RequestTicket,
        repository: String,
        expected_key: tokenstat_identity::PublicKey,
    ) -> Result<Self, DispatchError> {
        Self::connect_for(
            owner,
            client,
            request,
            repository,
            expected_key,
            Purpose::Run,
        )
    }
    fn connect_for(
        owner: AccountSnapshot,
        client: Arc<TeamClient>,
        request: RequestTicket,
        repository: String,
        expected_key: tokenstat_identity::PublicKey,
        purpose: Purpose,
    ) -> Result<Self, DispatchError> {
        owner
            .ensure_current()
            .map_err(|_| api_error(TeamError::AccountChanged))?;
        let expected = match purpose {
            Purpose::Read => vec![TeamCapability::Read],
            Purpose::Comment => vec![TeamCapability::Read, TeamCapability::Comment],
            Purpose::Run => vec![TeamCapability::Read, TeamCapability::Run],
        };
        if request.capabilities != expected
            || matches!(purpose, Purpose::Comment) && request.share_id.is_none()
        {
            return Err(api_error(TeamError::InvalidRequest));
        }
        let identity = MachineIdentity::load()
            .map_err(|_| unavailable())?
            .ok_or_else(unavailable)?;
        if identity.public_key() != expected_key {
            return Err(api_error(TeamError::AccountChanged));
        }
        let admission = Deadline::capture(Duration::from_secs(60)).ok_or_else(unavailable)?;
        let proof = client
            .connection_proof(&request, &repository, &identity.public_key())
            .map_err(api_error)?;
        let deadline = deadline(&proof)?;
        let continuous_deadline = admission.clipped(
            Deadline::capture(deadline.saturating_duration_since(Instant::now()))
                .ok_or_else(unavailable)?,
        );
        if proof.ticket().claims().iss != client.origin() {
            return Err(invalid());
        }
        let transport = if proof.host_key() == &identity.public_key() {
            Transport::Local
        } else {
            if !load_settings().relay_fallback {
                return Err(DispatchError::new(
                    "relay_disabled",
                    "This device uses direct connections only. Remote shared work needs the relay until a direct Team route is available.",
                ));
            }
            let scope =
                current_team_scope(&owner).map_err(|_| api_error(TeamError::AccountChanged))?;
            if scope.key != identity.public_key() {
                return Err(api_error(TeamError::AccountChanged));
            }
            let reach = team_reach::acquire(scope).map_err(|_| unavailable())?;
            let tunnel = crate::account_session::with_snapshot(Some(owner.clone()), || {
                tunnel_lifecycle::ensure(session_for_serving()?, &load_settings(), false)
            })
            .map_err(|_| unavailable())?
            .ok_or_else(unavailable)?;
            // Socket creation is asynchronous. An initial Team open must wait
            // for READY rather than racing the writer's first registration.
            let ready_deadline = (Instant::now() + Duration::from_secs(10)).min(deadline);
            let socket = tunnel.socket().map_err(|_| relay_unreachable())?;
            while !socket.status().connected {
                tunnel.ensure_current().map_err(|_| relay_unreachable())?;
                if Instant::now() >= ready_deadline || continuous_deadline.remaining().is_none() {
                    return Err(relay_unreachable());
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            let transport = socket
                .open_team_channel(*proof.host_key(), proof.ticket().ticket())
                .map_err(|error| relay_refused(&error.to_string()))?;
            let channel = transport.team_authorization().ok_or_else(invalid)?;
            let connection =
                handshake_initiator_bounded(Box::new(transport), &identity, *proof.host_key())
                    .map_err(|_| host_refused())?;
            Transport::Relay(Box::new(Relay {
                connection,
                channel,
                tunnel,
                _reach: reach,
            }))
        };
        let mut link = Self {
            transport,
            owner,
            client,
            request,
            repository,
            identity,
            proof,
            deadline,
            continuous_deadline,
            next_id: 1,
        };
        link.ensure_current()?;
        let protocol = link.call(ReadMethod::Protocol, &ReadParams::default())?;
        link.verify_protocol(&protocol)?;
        if matches!(purpose, Purpose::Comment)
            && (protocol["comments"] != true
                || protocol["protocolVersion"]
                    .as_str()
                    .and_then(|v| v.parse::<u32>().ok())
                    .is_none_or(|v| v < 46))
        {
            return Err(DispatchError::new(
                "team_host_update_required",
                "Update tokenstat on the publishing computer to comment.",
            ));
        }
        if matches!(purpose, Purpose::Run)
            && protocol["protocolVersion"]
                .as_str()
                .and_then(|v| v.parse::<u32>().ok())
                .is_none_or(|v| {
                    v < if link.request.share_id.is_some() {
                        47
                    } else {
                        48
                    }
                })
        {
            return Err(DispatchError::new(
                "team_host_update_required",
                "Update tokenstat on the publishing computer to ask its agent.",
            ));
        }
        Ok(link)
    }

    pub(crate) fn ensure_current(&self) -> Result<(), DispatchError> {
        self.owner
            .ensure_current()
            .map_err(|_| api_error(TeamError::AccountChanged))?;
        self.client.ensure_current().map_err(api_error)?;
        if let Transport::Relay(relay) = &self.transport {
            relay.tunnel.ensure_current().map_err(|_| unavailable())?;
        }
        if Instant::now() >= self.deadline
            || self.proof.ticket().claims().exp <= wall()
            || self.continuous_deadline.remaining().is_none()
        {
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
        if matches!(&self.transport, Transport::Local) {
            let result = crate::teams::loopback_read(
                &self.client,
                &self.proof,
                &self.identity.public_key(),
                self.deadline,
                self.continuous_deadline,
                method,
                params,
            );
            self.ensure_current()?;
            return result;
        }
        let Transport::Relay(relay) = &mut self.transport else {
            return Err(invalid());
        };
        let id = self.next_id;
        self.next_id = self.next_id.checked_add(1).ok_or_else(invalid)?;
        let request = serde_json::to_vec(&json!({"id":id,"method":method.wire(),"params":params}))
            .map_err(|_| invalid())?;
        relay.connection.send(&request).map_err(|_| unavailable())?;
        let time = RESPONSE_TIME
            .min(self.deadline.saturating_duration_since(Instant::now()))
            .min(
                self.continuous_deadline
                    .remaining()
                    .ok_or_else(unavailable)?,
            );
        let bytes = relay
            .connection
            .receive_bounded(RESPONSE_LIMIT, time)
            .map_err(|_| unavailable())?;
        self.ensure_current()?;
        reply(&bytes, id)
    }

    pub(crate) fn renew(&mut self) -> Result<(), DispatchError> {
        self.ensure_current()?;
        let admission = Deadline::capture(Duration::from_secs(60)).ok_or_else(unavailable)?;
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
            || current.share_revision != previous.share_revision
            || current.grant != previous.grant
            || current.cap != previous.cap
            || current.epoch < previous.epoch
            || current.revision < previous.revision
            || current.iat < previous.iat
            || current.exp < previous.exp
        {
            return Err(api_error(TeamError::AccountChanged));
        }
        let next_deadline = deadline(&next)?;
        let next_continuous_deadline = admission.clipped(
            Deadline::capture(next_deadline.saturating_duration_since(Instant::now()))
                .ok_or_else(unavailable)?,
        );
        // A slow validation or suspended host cannot revive an already
        // expired connection. Closed reads may establish a fresh connection.
        self.ensure_current()?;
        if let Transport::Relay(relay) = &self.transport {
            relay
                .channel
                .renew(next.ticket().ticket())
                .map_err(|_| unavailable())?;
            relay.tunnel.ensure_current().map_err(|_| unavailable())?;
        }
        self.ensure_current()?;
        self.proof = next;
        self.deadline = next_deadline;
        self.continuous_deadline = next_continuous_deadline;
        // A relay ACK updates the host's channel ticket. Local and remote
        // reads both validate the replacement through the scoped boundary.
        let protocol = self.call(ReadMethod::Protocol, &ReadParams::default())?;
        self.verify_protocol(&protocol)
    }
    /// One attempt only. After bytes might have reached the host, a missing
    /// response means delivery is unknown; callers check their own receipt.
    pub(crate) fn comment(&mut self, input: &CommentInput) -> Result<Value, DispatchError> {
        input.validate()?;
        self.ensure_current()?;
        if self.request.capabilities != [TeamCapability::Read, TeamCapability::Comment]
            || self.request.share_id.is_none()
        {
            return Err(api_error(TeamError::InvalidRequest));
        }
        if matches!(&self.transport, Transport::Local) {
            let result = crate::teams::loopback_comment(
                &self.client,
                &self.proof,
                &self.identity.public_key(),
                self.deadline,
                self.continuous_deadline,
                input,
            );
            self.ensure_current()?;
            return result;
        }
        let Transport::Relay(relay) = &mut self.transport else {
            return Err(invalid());
        };
        let id = self.next_id;
        self.next_id = self.next_id.checked_add(1).ok_or_else(invalid)?;
        let bytes =
            serde_json::to_vec(&json!({"id":id,"method":"team.chat.comment","params":input}))
                .map_err(|_| invalid())?;
        if bytes.len() > 16 * 1024 {
            return Err(api_error(TeamError::InvalidRequest));
        }
        let unknown = || {
            DispatchError::delivery_unknown(
                "Comment delivery could not be verified. Keep your draft and check the chat before sending again.",
            )
        };
        relay.connection.send(&bytes).map_err(|_| unknown())?;
        let time = RESPONSE_TIME
            .min(self.deadline.saturating_duration_since(Instant::now()))
            .min(
                self.continuous_deadline
                    .remaining()
                    .ok_or_else(unavailable)?,
            );
        let response = relay
            .connection
            .receive_bounded(RESPONSE_LIMIT, time)
            .map_err(|_| unknown())?;
        self.ensure_current()?;
        reply(&response, id)
    }

    /// One attempt only, like a comment. A lost reply to Send means the Ask
    /// may have started: the caller reads the chat before asking again.
    pub(crate) fn ask(
        &mut self,
        method: AskMethod,
        params: &Value,
    ) -> Result<Value, DispatchError> {
        self.ensure_current()?;
        // A new chat has no share yet. Every other Ask is about one share.
        if self.request.capabilities != [TeamCapability::Read, TeamCapability::Run]
            || self.request.share_id.is_none() != (method == AskMethod::New)
        {
            return Err(api_error(TeamError::InvalidRequest));
        }
        let body = serde_json::to_string(params).map_err(|_| invalid())?;
        if body.len() > 16 * 1024 {
            return Err(api_error(TeamError::InvalidRequest));
        }
        if matches!(&self.transport, Transport::Local) {
            let result = crate::teams::loopback_ask(
                &self.client,
                &self.proof,
                &self.identity.public_key(),
                self.deadline,
                self.continuous_deadline,
                method,
                &body,
            );
            self.ensure_current()?;
            return result;
        }
        let Transport::Relay(relay) = &mut self.transport else {
            return Err(invalid());
        };
        let id = self.next_id;
        self.next_id = self.next_id.checked_add(1).ok_or_else(invalid)?;
        let bytes = serde_json::to_vec(&json!({"id":id,"method":method.wire(),"params":params}))
            .map_err(|_| invalid())?;
        let unknown = || {
            DispatchError::delivery_unknown(
                "The publishing computer did not answer. Check the chat before asking again.",
            )
        };
        relay.connection.send(&bytes).map_err(|_| unknown())?;
        let time = ASK_RESPONSE_TIME
            .min(self.deadline.saturating_duration_since(Instant::now()))
            .min(
                self.continuous_deadline
                    .remaining()
                    .ok_or_else(unavailable)?,
            );
        let response = relay
            .connection
            .receive_bounded(RESPONSE_LIMIT, time)
            .map_err(|_| unknown())?;
        self.ensure_current()?;
        reply(&response, id)
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
        if let Transport::Relay(relay) = &mut self.transport {
            relay.connection.close();
        }
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
    fn catalogs_require_a_broad_scope_and_their_cursors_cannot_select_another_checkout() {
        let mut params = ReadParams::default();
        assert!(params.validate(ReadMethod::ChatCatalog, None));
        assert!(!params.validate(ReadMethod::ChatCatalog, Some("share_fixture")));
        assert_eq!(params.catalog_offset("checkout_fixture").unwrap(), 0);
        for cursor in [
            "v1:share_fixture:5",
            "v1:catalog:checkout_other:1",
            "v1:catalog:checkout_fixture:10001",
            "v1:catalog:checkout_fixture:-1",
            "v1:catalog:checkout_fixture:NaN",
            "v1:catalog:checkout_fixture:",
        ] {
            params.cursor = Some(cursor.into());
            assert!(params.catalog_offset("checkout_fixture").is_err());
        }
        params.cursor = Some("v1:catalog:checkout_fixture:10".into());
        assert_eq!(params.catalog_offset("checkout_fixture").unwrap(), 10);
        assert!(!params.validate(ReadMethod::ChatEvents, Some("share_fixture")));
        params.direction = Some(PageDirection::Older);
        assert!(!params.validate(ReadMethod::ChatCatalog, None));
        params.direction = None;
        params.limit = Some(101);
        assert!(!params.validate(ReadMethod::ChatCatalog, None));
    }

    #[test]
    fn attachment_reads_name_one_shared_file() {
        let file = |id: &str| ReadParams {
            attachment: Some(id.into()),
            ..ReadParams::default()
        };
        assert!(file("att_1.png").validate(ReadMethod::ChatAttachment, Some("share_fixture")));
        assert!(!file("att_1.png").validate(ReadMethod::ChatAttachment, None));
        assert!(!file("../secret").validate(ReadMethod::ChatAttachment, Some("share_fixture")));
        assert!(!file("").validate(ReadMethod::ChatAttachment, Some("share_fixture")));
        assert!(!file("att_1").validate(ReadMethod::ChatEvents, Some("share_fixture")));
        assert!(!ReadParams::default().validate(ReadMethod::ChatAttachment, Some("share_fixture")));
    }
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
