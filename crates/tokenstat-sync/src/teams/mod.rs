// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Opt-in Teams metadata client. A request captures its account origin and
//! credential; late responses from a previous sign-in are retired. Repository
//! paths, branch state and chat content have no place in these API requests.

mod connection;
mod host_execution;
mod host_runs;
mod model;
pub use connection::TeamConnectionProof;
pub use host_runs::HostRunAuthority;
pub use model::*;

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use reqwest::blocking::Client;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderValue};
use reqwest::{Method, Url};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use tokenstat_identity::teams::{TeamKeyResponse, TrustedTeamKeys, VerifiedTeamTicket};
use zeroize::Zeroizing;

use crate::{keychain, profile};
const RESPONSE_LIMIT: usize = 1024 * 1024;
const REQUEST_LIMIT: usize = 10 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TeamError {
    #[error("Sign in to use Teams.")]
    NotSignedIn,
    #[error("The account changed. Open Teams again.")]
    AccountChanged,
    #[error("Couldn't reach Teams. Try again shortly.")]
    Network,
    #[error("The Teams server returned an invalid response.")]
    InvalidResponse,
    #[error("Check the Teams request and try again.")]
    InvalidRequest,
    #[error("Teams is not available on this account server.")]
    Unsupported,
    #[error("{message}")]
    Rejected {
        status: u16,
        code: String,
        message: String,
    },
}

#[derive(Clone)]
struct Authentication {
    origin: String,
    bearer: Zeroizing<String>,
}
fn authentication() -> Result<Authentication, TeamError> {
    let origin = profile::resolve_api_host(None).map_err(|_| TeamError::InvalidRequest)?;
    let bearer = keychain::load_token(&origin)
        .map_err(|_| TeamError::NotSignedIn)?
        .ok_or(TeamError::NotSignedIn)?;
    Ok(Authentication {
        origin,
        bearer: Zeroizing::new(bearer),
    })
}
struct WireRequest {
    method: Method,
    url: Url,
    authorization: HeaderValue,
    body: Option<Vec<u8>>,
}
trait TeamWire: Send + Sync {
    fn send(&self, request: WireRequest) -> Result<(u16, Vec<u8>), TeamError>;
}
struct HttpWire(Client);
impl TeamWire for HttpWire {
    fn send(&self, request: WireRequest) -> Result<(u16, Vec<u8>), TeamError> {
        let mut builder = self
            .0
            .request(request.method, request.url)
            .header(AUTHORIZATION, request.authorization);
        if let Some(body) = request.body {
            builder = builder.header(CONTENT_TYPE, "application/json").body(body);
        }
        let response = builder.send().map_err(|_| TeamError::Network)?;
        let status = response.status().as_u16();
        if response
            .content_length()
            .is_some_and(|n| n > RESPONSE_LIMIT as u64)
        {
            return Err(TeamError::InvalidResponse);
        }
        let mut body = Vec::new();
        response
            .take((RESPONSE_LIMIT + 1) as u64)
            .read_to_end(&mut body)
            .map_err(|_| TeamError::Network)?;
        if body.len() > RESPONSE_LIMIT {
            return Err(TeamError::InvalidResponse);
        }
        Ok((status, body))
    }
}

/// Debug is absent so account credentials cannot enter diagnostics.
#[derive(Clone)]
pub struct TeamClient {
    authentication: Arc<Authentication>,
    wire: Arc<dyn TeamWire>,
    current: Arc<dyn Fn() -> Result<Authentication, TeamError> + Send + Sync>,
}
impl TeamClient {
    pub fn capture() -> Result<Self, TeamError> {
        let captured = authentication()?;
        let wire = crate::http::client_builder()
            .timeout(Duration::from_secs(15))
            .connect_timeout(Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| TeamError::Network)?;
        let client = Self {
            authentication: Arc::new(captured),
            wire: Arc::new(HttpWire(wire)),
            current: Arc::new(authentication),
        };
        client.ensure_current()?;
        Ok(client)
    }
    pub fn origin(&self) -> &str {
        &self.authentication.origin
    }
    pub fn with_retirement_guard(
        mut self,
        guard: impl Fn() -> Result<(), TeamError> + Send + Sync + 'static,
    ) -> Self {
        let current = self.current.clone();
        self.current = Arc::new(move || {
            guard()?;
            let result = current()?;
            guard()?;
            Ok(result)
        });
        self
    }
    pub fn ensure_current(&self) -> Result<(), TeamError> {
        let current = (self.current)()?;
        if current.origin != self.authentication.origin
            || current.bearer != self.authentication.bearer
        {
            return Err(TeamError::AccountChanged);
        }
        Ok(())
    }
    fn request<T: DeserializeOwned>(
        &self,
        method: Method,
        segments: &[&str],
        body: Option<Value>,
        page: Option<Page>,
    ) -> Result<T, TeamError> {
        self.request_query(method, segments, body, page, None)
    }
    fn request_query<T: DeserializeOwned>(
        &self,
        method: Method,
        segments: &[&str],
        body: Option<Value>,
        page: Option<Page>,
        query: Option<(&str, &str)>,
    ) -> Result<T, TeamError> {
        self.ensure_current()?;
        let mut url = Url::parse(self.origin()).map_err(|_| TeamError::InvalidRequest)?;
        {
            let mut path = url
                .path_segments_mut()
                .map_err(|_| TeamError::InvalidRequest)?;
            path.clear().push("api").push("v1");
            for segment in segments {
                if segment.is_empty()
                    || segment.len() > 128
                    || !segment
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
                {
                    return Err(TeamError::InvalidRequest);
                }
                path.push(segment);
            }
        }
        if let Some(page) = page {
            page.validate()?;
            url.query_pairs_mut()
                .append_pair("limit", &page.limit.to_string())
                .append_pair("offset", &page.offset.to_string());
        }
        if let Some((key, value)) = query {
            url.query_pairs_mut().append_pair(key, value);
        }
        let mut authorization =
            HeaderValue::from_str(&format!("Bearer {}", self.authentication.bearer.as_str()))
                .map_err(|_| TeamError::NotSignedIn)?;
        authorization.set_sensitive(true);
        let body = body
            .map(|value| serde_json::to_vec(&value).map_err(|_| TeamError::InvalidRequest))
            .transpose()?;
        if body.as_ref().is_some_and(|body| body.len() > REQUEST_LIMIT) {
            return Err(TeamError::InvalidRequest);
        }
        let response = self.wire.send(WireRequest {
            method,
            url,
            authorization,
            body,
        });
        self.ensure_current()?;
        let (status, bytes) = response?;
        if bytes.len() > RESPONSE_LIMIT {
            return Err(TeamError::InvalidResponse);
        }
        if matches!(status, 404 | 405) && segments == ["teams", "capabilities"] {
            return Err(TeamError::Unsupported);
        }
        if !(200..300).contains(&status) {
            return Err(refusal(status, &bytes));
        }
        serde_json::from_slice(&bytes).map_err(|_| TeamError::InvalidResponse)
    }
    pub fn capabilities(&self) -> Result<Capabilities, TeamError> {
        self.request(Method::GET, &["teams", "capabilities"], None, None)
    }
    pub fn authorization_url(&self, value: &Capabilities) -> Result<String, TeamError> {
        let path = value
            .authorization_path
            .as_deref()
            .ok_or(TeamError::InvalidResponse)?;
        let id = path
            .strip_prefix("/settings/teams/devices/")
            .ok_or(TeamError::InvalidResponse)?;
        if id.is_empty() || id.len() > 128 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(TeamError::InvalidResponse);
        }
        Ok(format!("{}{path}", self.origin()))
    }
    pub fn verification_keys(&self) -> Result<TrustedTeamKeys, TeamError> {
        let response: TeamKeyResponse =
            self.request(Method::GET, &["teams", "keys"], None, None)?;
        TrustedTeamKeys::from_response(response, self.origin())
            .map_err(|_| TeamError::InvalidResponse)
    }
    pub fn organizations(&self, page: Page) -> Result<Organizations, TeamError> {
        self.request(Method::GET, &["organizations"], None, Some(page))
    }
    pub fn organization(&self, org: &str) -> Result<OrganizationDetails, TeamError> {
        self.request(Method::GET, &["organizations", org], None, None)
    }
    pub fn create_organization(
        &self,
        input: &CreateOrganization,
    ) -> Result<OrganizationDetails, TeamError> {
        self.request(Method::POST, &["organizations"], Some(value(input)?), None)
    }
    pub fn rename_organization(
        &self,
        org: &str,
        input: &Rename,
    ) -> Result<OrganizationDetails, TeamError> {
        self.request(
            Method::PATCH,
            &["organizations", org],
            Some(value(input)?),
            None,
        )
    }
    pub fn delete_organization(
        &self,
        org: &str,
        input: &DeleteOrganization,
    ) -> Result<Deleted, TeamError> {
        self.request(
            Method::DELETE,
            &["organizations", org],
            Some(value(input)?),
            None,
        )
    }
    pub fn members(&self, org: &str, page: Page) -> Result<Members, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "members"],
            None,
            Some(page),
        )
    }
    /// Foreground app activity; never called by a background host heartbeat.
    pub fn app_presence(&self, active: bool) -> Result<Value, TeamError> {
        self.request(
            Method::POST,
            &["teams", "presence"],
            Some(serde_json::json!({"active": active})),
            None,
        )
    }
    pub fn change_member_role(
        &self,
        org: &str,
        user: &str,
        input: &ChangeMemberRole,
    ) -> Result<MemberRoleReply, TeamError> {
        self.request(
            Method::PATCH,
            &["organizations", org, "members", user],
            Some(value(input)?),
            None,
        )
    }
    pub fn remove_member(
        &self,
        org: &str,
        user: &str,
        input: Revision,
    ) -> Result<Removed, TeamError> {
        self.request(
            Method::DELETE,
            &["organizations", org, "members", user],
            Some(value(&input)?),
            None,
        )
    }
    pub fn transfer_ownership(
        &self,
        org: &str,
        input: &TransferOwnership,
    ) -> Result<TransferPending, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "ownership"],
            Some(value(input)?),
            None,
        )
    }
    pub fn accept_ownership(
        &self,
        org: &str,
        input: OwnershipApproval,
    ) -> Result<OrganizationDetails, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "ownership", "accept"],
            Some(value(&input)?),
            None,
        )
    }
    pub fn cancel_ownership(
        &self,
        org: &str,
        input: OwnershipApproval,
    ) -> Result<Value, TeamError> {
        self.request(
            Method::DELETE,
            &["organizations", org, "ownership"],
            Some(value(&input)?),
            None,
        )
    }
    pub fn repositories(&self, org: &str, page: Page) -> Result<Repositories, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "repositories"],
            None,
            Some(page),
        )
    }
    pub fn create_repository(&self, org: &str, name: &str) -> Result<RepositoryReply, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "repositories"],
            Some(json!({"name":name})),
            None,
        )
    }
    pub fn rename_repository(
        &self,
        org: &str,
        repo: &str,
        input: &Rename,
    ) -> Result<RepositoryReply, TeamError> {
        self.request(
            Method::PATCH,
            &["organizations", org, "repositories", repo],
            Some(value(input)?),
            None,
        )
    }
    pub fn repository_members(
        &self,
        org: &str,
        repo: &str,
        page: Page,
    ) -> Result<RepositoryMembers, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "repositories", repo, "members"],
            None,
            Some(page),
        )
    }
    pub fn repository_access(
        &self,
        org: &str,
        repo: &str,
        user: &str,
        input: &ChangeRepositoryAccess,
    ) -> Result<RepositoryAccessReply, TeamError> {
        self.request(
            Method::PUT,
            &["organizations", org, "repositories", repo, "members", user],
            Some(value(input)?),
            None,
        )
    }
    pub fn invitations(&self, org: &str, page: Page) -> Result<Invitations, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "invitations"],
            None,
            Some(page),
        )
    }
    pub fn invite(&self, org: &str, input: &InviteMember) -> Result<InvitationCreated, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "invitations"],
            Some(value(input)?),
            None,
        )
    }
    pub fn renew_invitation(
        &self,
        org: &str,
        invite: &str,
        input: Revision,
    ) -> Result<InvitationCreated, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "invitations", invite, "renew"],
            Some(value(&input)?),
            None,
        )
    }
    pub fn revoke_invitation(
        &self,
        org: &str,
        invite: &str,
        input: Revision,
    ) -> Result<InvitationReply, TeamError> {
        self.request(
            Method::DELETE,
            &["organizations", org, "invitations", invite],
            Some(value(&input)?),
            None,
        )
    }
    pub fn inbox(&self, page: Page) -> Result<Invitations, TeamError> {
        self.request(Method::GET, &["teams", "invitations"], None, Some(page))
    }
    pub fn invitation(&self, invite: &str) -> Result<InvitationPreview, TeamError> {
        self.request(Method::GET, &["teams", "invitations", invite], None, None)
    }
    pub fn accept_invitation(&self, invite: &str) -> Result<Joined, TeamError> {
        self.request(
            Method::POST,
            &["teams", "invitations", invite, "accept"],
            Some(json!({})),
            None,
        )
    }
    pub fn checkouts(&self, org: &str, repo: &str, page: Page) -> Result<Checkouts, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "repositories", repo, "checkouts"],
            None,
            Some(page),
        )
    }
    pub fn checkout(&self, org: &str, checkout: &str) -> Result<CheckoutReply, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "checkouts", checkout],
            None,
            None,
        )
    }
    pub fn publish_checkout(
        &self,
        org: &str,
        repo: &str,
        reference: &str,
    ) -> Result<CheckoutReply, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "repositories", repo, "checkouts"],
            Some(json!({"id":reference})),
            None,
        )
    }
    /// Tell the account service this checkout's repository target moved,
    /// so members' hosts catch up. Carries no commit, branch or path.
    pub fn checkout_moved(&self, org: &str, checkout: &str) -> Result<Value, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "checkouts", checkout, "moved"],
            Some(json!({})),
            None,
        )
    }
    /// How often each repository this person can read has moved, for a
    /// host catching up after being offline.
    pub fn my_moves(&self) -> Result<Value, TeamError> {
        let mut moves = Vec::new();
        let mut after = String::new();
        // The server returns up to 1,000 rows per page. Bound requests as well
        // as rows so a stream of tiny pages cannot monopolize host catch-up.
        for _ in 0..128 {
            let page: Value = self.request_query(
                Method::GET,
                &["teams", "moves"],
                None,
                None,
                (!after.is_empty()).then_some(("after", after.as_str())),
            )?;
            let rows = page["moves"].as_array().ok_or(TeamError::InvalidResponse)?;
            if rows.len() > 1000 || moves.len() + rows.len() > 100_000 {
                return Err(TeamError::InvalidResponse);
            }
            let mut last = after.clone();
            for row in rows {
                let id = row["repositoryId"]
                    .as_str()
                    .ok_or(TeamError::InvalidResponse)?;
                let sequence = row["sequence"]
                    .as_u64()
                    .filter(|sequence| *sequence > 0)
                    .ok_or(TeamError::InvalidResponse)?;
                if !id.strip_prefix("repo_").is_some_and(|suffix| {
                    suffix.len() == 32
                        && suffix
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                }) || id <= last.as_str()
                {
                    return Err(TeamError::InvalidResponse);
                }
                last = id.into();
                // Keep only the bounded protocol metadata. Unknown response
                // fields must not accumulate up to a megabyte for every row.
                moves.push(json!({"repositoryId": id, "sequence": sequence}));
            }
            match page.get("nextCursor") {
                None | Some(Value::Null) => return Ok(json!({ "moves": moves })),
                Some(Value::String(cursor))
                    if !rows.is_empty() && cursor == &last && cursor > &after =>
                {
                    after = cursor.clone();
                }
                _ => return Err(TeamError::InvalidResponse),
            }
        }
        Err(TeamError::InvalidResponse)
    }
    pub fn withdraw_checkout(
        &self,
        org: &str,
        checkout: &str,
        input: Revision,
    ) -> Result<Withdrawn, TeamError> {
        self.request(
            Method::DELETE,
            &["organizations", org, "checkouts", checkout],
            Some(value(&input)?),
            None,
        )
    }
    /// Retire the exact reference even if its publication request timed out
    /// before a row was observable. Zero explicitly means "not yet present";
    /// the server reserves a terminal ref under this repository and device.
    pub fn withdraw_checkout_reference(
        &self,
        org: &str,
        repository: &str,
        checkout: &str,
        expected_revision: u64,
    ) -> Result<Withdrawn, TeamError> {
        self.request(
            Method::DELETE,
            &["organizations", org, "checkouts", checkout],
            Some(
                serde_json::json!({"repositoryId":repository,"expectedRevision":expected_revision}),
            ),
            None,
        )
    }
    pub fn execution_grants(
        &self,
        org: &str,
        checkout: &str,
    ) -> Result<ExecutionGrants, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "checkouts", checkout, "execution"],
            None,
            None,
        )
    }
    pub fn checkout_publication(
        &self,
        org: &str,
        checkout: &str,
    ) -> Result<CheckoutReply, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "checkouts", checkout, "publication"],
            None,
            None,
        )
    }
    pub fn set_execution_grant(
        &self,
        org: &str,
        checkout: &str,
        input: &SetExecutionGrant,
    ) -> Result<ExecutionReply, TeamError> {
        if input.allow {
            return host_execution::grant(self, org, checkout, input);
        }
        self.request(
            Method::PUT,
            &["organizations", org, "checkouts", checkout, "execution"],
            Some(value(input)?),
            None,
        )
    }
    pub fn set_execution_policy(
        &self,
        org: &str,
        checkout: &str,
        input: &SetExecutionPolicy,
    ) -> Result<ExecutionPolicyReply, TeamError> {
        host_execution::policy(self, org, checkout, input)
    }
    pub fn member_devices(
        &self,
        org: &str,
        checkout: &str,
        user: &str,
    ) -> Result<MemberDevices, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "checkouts", checkout, "devices", user],
            None,
            None,
        )
    }
    pub fn shared_chats(
        &self,
        org: &str,
        checkout: &str,
        page: Page,
    ) -> Result<SharedChats, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "checkouts", checkout, "shares"],
            None,
            Some(page),
        )
    }
    pub fn publish_chat(
        &self,
        org: &str,
        checkout: &str,
        reference: &str,
        confirmed: bool,
    ) -> Result<SharedChatReply, TeamError> {
        self.request(
            Method::POST,
            &["organizations", org, "checkouts", checkout, "shares"],
            Some(json!({"id":reference,"confirmHistory":confirmed})),
            None,
        )
    }
    pub fn withdraw_chat(
        &self,
        org: &str,
        checkout: &str,
        share: &str,
        input: Revision,
    ) -> Result<Withdrawn, TeamError> {
        self.request(
            Method::DELETE,
            &["organizations", org, "checkouts", checkout, "shares", share],
            Some(value(&input)?),
            None,
        )
    }
    pub fn chat_publication(
        &self,
        org: &str,
        checkout: &str,
        share: &str,
    ) -> Result<SharedChatReply, TeamError> {
        self.request(
            Method::GET,
            &[
                "organizations",
                org,
                "checkouts",
                checkout,
                "shares",
                share,
                "publication",
            ],
            None,
            None,
        )
    }
    pub fn activity(&self, org: &str, page: Page) -> Result<Activity, TeamError> {
        self.request(
            Method::GET,
            &["organizations", org, "activity"],
            None,
            Some(page),
        )
    }
    pub fn connection_ticket(&self, input: &RequestTicket) -> Result<ConnectionTicket, TeamError> {
        self.request(
            Method::POST,
            &["teams", "tickets"],
            Some(value(input)?),
            None,
        )
    }
    pub fn validate_connection(
        &self,
        ticket: &VerifiedTeamTicket,
    ) -> Result<TeamPrincipal, TeamError> {
        let c = ticket.claims();
        if c.iss != self.origin() {
            return Err(TeamError::InvalidResponse);
        }
        let reply: PrincipalReply = self.request(
            Method::POST,
            &["teams", "validate"],
            Some(
                json!({"ticket":ticket.ticket().wire_value(),"actorId":c.sub,"deviceKey":c.device}),
            ),
            None,
        )?;
        let p = reply.principal;
        let expires: jiff::Timestamp = p
            .expires_at
            .parse()
            .map_err(|_| TeamError::InvalidResponse)?;
        if p.person.id != c.sub
            || p.device_key != c.device
            || p.organization_id != c.org
            || p.repository_id != c.repository
            || p.checkout_id != c.checkout
            || p.host_key != c.host
            || p.publisher_id != c.publisher
            || p.share_id != c.share
            || p.grant_id != c.grant
            || p.epoch != c.epoch
            || p.capabilities != c.cap
            || expires.as_second() != c.exp as i64
            || (p.role == RepositoryRole::Viewer
                && p.capabilities
                    .iter()
                    .any(|cap| *cap != TeamCapability::Read))
        {
            return Err(TeamError::InvalidResponse);
        }
        Ok(p)
    }
}
fn value<T: Serialize>(input: &T) -> Result<Value, TeamError> {
    serde_json::to_value(input).map_err(|_| TeamError::InvalidRequest)
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Page {
    pub limit: u32,
    pub offset: u32,
}
impl Default for Page {
    fn default() -> Self {
        Self {
            limit: 20,
            offset: 0,
        }
    }
}
impl Page {
    pub fn validate(self) -> Result<(), TeamError> {
        if self.limit == 0 || self.limit > 100 || self.offset > 10000 {
            Err(TeamError::InvalidRequest)
        } else {
            Ok(())
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositoryReply {
    pub repository: Repository,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InvitationReply {
    pub invitation: Invitation,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckoutReply {
    pub checkout: Checkout,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SharedChatReply {
    pub share: SharedChat,
}
#[derive(Deserialize)]
struct PrincipalReply {
    principal: TeamPrincipal,
}

#[derive(Deserialize)]
struct ErrorBody {
    error: String,
    message: Option<String>,
}
fn refusal(status: u16, bytes: &[u8]) -> TeamError {
    if let Ok(body) = serde_json::from_slice::<ErrorBody>(bytes)
        && !body.error.is_empty()
        && body.error.len() <= 64
        && body
            .error
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b == b'_')
    {
        let message = body
            .message
            .filter(|m| !m.is_empty() && m.len() <= 400 && !m.chars().any(char::is_control))
            .unwrap_or_else(|| "The Teams request was refused. Refresh and try again.".into());
        return TeamError::Rejected {
            status,
            code: body.error,
            message,
        };
    }
    TeamError::InvalidResponse
}

impl Capabilities {
    pub fn ready(&self) -> bool {
        self.enabled
            && self.actor_id.as_ref().is_some_and(|id| !id.is_empty())
            && self.version == 1
            && !self.authorization_required
            && ["teams:read", "teams:manage", "teams:connect"]
                .iter()
                .all(|s| self.scopes.iter().any(|v| v == s))
    }
}

#[cfg(test)]
mod tests;
