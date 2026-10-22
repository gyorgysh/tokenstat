// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Organization management belongs to the person signed in on this device.
//! Teammate chat requests use their own scoped entry point; they never borrow
//! this machine's account credential or its personal workspace policy.

mod authorization;
#[cfg(feature = "local-host")]
mod catalog;
#[cfg(feature = "local-host")]
mod chats;
mod connections;
mod directory;
#[cfg(feature = "local-host")]
mod guardian;
mod ingress;
#[cfg(feature = "local-host")]
mod lanes;
#[cfg(feature = "local-host")]
mod local_sharing;
#[cfg(feature = "local-host")]
mod provider;
#[cfg(feature = "local-host")]
mod publications;
#[cfg(feature = "local-host")]
mod recovery;
#[cfg(feature = "local-host")]
mod run_home;
#[cfg(feature = "local-host")]
mod runs;
mod scoped;
#[cfg(feature = "local-host")]
mod scoped_chats;
#[cfg(feature = "local-host")]
mod scoped_comments;
#[cfg(feature = "local-host")]
mod scoped_runs;
#[cfg(feature = "local-host")]
pub(crate) use guardian::main as guardian_main;
#[cfg(feature = "local-host")]
mod scoped_source;
#[cfg(feature = "local-host")]
mod sharing;
use crate::account_session::AccountSnapshot;
use crate::error::DispatchError;
pub(crate) use authorization::AuthorizedTeamPrincipal;
pub(crate) use ingress::accept as accept_channel;
use serde_json::{Value, json};
use tokenstat_sync::teams::{TeamClient, TeamError};

pub(crate) fn scoped_call(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    scoped::call(method, params)
}
/// A typed read on the physical publisher uses identical principal checks and
/// scoped dispatch. It never enters personal RPC or accepts a guest path.
pub(crate) fn loopback_read(
    client: &TeamClient,
    proof: &tokenstat_sync::teams::TeamConnectionProof,
    device: &tokenstat_identity::PublicKey,
    deadline: std::time::Instant,
    lease: crate::lease_clock::Deadline,
    method: crate::remote::TeamReadMethod,
    params: &crate::remote::TeamReadParams,
) -> Result<Value, DispatchError> {
    let principal = AuthorizedTeamPrincipal::loopback(client, proof, device, deadline, lease)?;
    let body = serde_json::to_string(params).map_err(|_| api_error(TeamError::InvalidRequest))?;
    let value = crate::request_context::with_team_principal(principal.clone(), || {
        scoped::call(method.wire(), &body).ok_or_else(|| api_error(TeamError::InvalidRequest))?
    })?;
    principal.ensure_live()?;
    client.ensure_current().map_err(api_error)?;
    Ok(value)
}
/// Listen for teammates' landings on the relay connection. Each one is
/// handled on its own thread so the tunnel never waits on git.
pub fn install_sync() {
    #[cfg(feature = "local-host")]
    tokenstat_remote::tunnel::on_team_moved(|repository| {
        let repository = repository.to_string();
        let _ = std::thread::Builder::new()
            .name("team-caught-up".into())
            .spawn(move || lanes::caught_up(&repository));
    });
}

/// Whether this host lets a shared chat start its agent at all.
fn agent_runs_ready() -> bool {
    #[cfg(feature = "local-host")]
    {
        scoped_runs::execution_ready()
    }
    #[cfg(not(feature = "local-host"))]
    {
        false
    }
}
/// The physical publisher asking its own agent. Same scoped boundary as a
/// teammate's relay request, without a socket back to itself.
pub(crate) fn loopback_ask(
    client: &TeamClient,
    proof: &tokenstat_sync::teams::TeamConnectionProof,
    device: &tokenstat_identity::PublicKey,
    deadline: std::time::Instant,
    lease: crate::lease_clock::Deadline,
    method: crate::remote::TeamAskMethod,
    params: &str,
) -> Result<Value, DispatchError> {
    let principal = AuthorizedTeamPrincipal::loopback(client, proof, device, deadline, lease)?;
    let value = crate::request_context::with_team_principal(principal.clone(), || {
        scoped::call(method.wire(), params).ok_or_else(|| api_error(TeamError::InvalidRequest))?
    })?;
    client.ensure_current().map_err(api_error)?;
    Ok(value)
}
pub(crate) fn loopback_comment(
    client: &TeamClient,
    proof: &tokenstat_sync::teams::TeamConnectionProof,
    device: &tokenstat_identity::PublicKey,
    deadline: std::time::Instant,
    lease: crate::lease_clock::Deadline,
    input: &crate::remote::TeamCommentInput,
) -> Result<Value, DispatchError> {
    #[cfg(feature = "local-host")]
    {
        let principal = AuthorizedTeamPrincipal::loopback(client, proof, device, deadline, lease)?;
        let result = scoped_comments::send(&principal, input)?;
        principal.ensure_live()?;
        client.ensure_current().map_err(api_error)?;
        Ok(result)
    }
    #[cfg(not(feature = "local-host"))]
    {
        let _ = (client, proof, device, deadline, lease, input);
        Err(DispatchError::new(
            "host_required",
            "Open this chat on its publishing computer.",
        ))
    }
}
pub(crate) fn local_sharing_call(
    method: &str,
    params: &str,
) -> Option<Result<Value, DispatchError>> {
    #[cfg(feature = "local-host")]
    {
        local_sharing::call(method, params)
            .or_else(|| recovery::call(method, params))
            .or_else(|| lanes::call(method, params))
    }
    #[cfg(not(feature = "local-host"))]
    {
        let _ = (method, params);
        None
    }
}

pub(crate) fn restore_remote_reach(
    owner: &AccountSnapshot,
    identity: &tokenstat_identity::MachineIdentity,
) -> Result<(), DispatchError> {
    #[cfg(feature = "local-host")]
    {
        sharing::restore_remote_reach(owner, identity)
    }
    #[cfg(not(feature = "local-host"))]
    {
        let _ = (owner, identity);
        Ok(())
    }
}

pub(crate) fn serve(
    mut connection: tokenstat_remote::Connection,
    channel: tokenstat_remote::tunnel::TeamChannelHandle,
    owner: AccountSnapshot,
    host: tokenstat_identity::PublicKey,
    session: &std::sync::Mutex<crate::Session>,
) {
    let Ok(mut authorization) =
        authorization::Authorization::capture(&owner, connection.peer_key(), host, channel)
    else {
        connection.close();
        return;
    };
    while let Ok(bytes) = connection.receive_bounded(16 * 1024, std::time::Duration::from_secs(60))
    {
        let Ok(line) = std::str::from_utf8(&bytes) else {
            break;
        };
        let Ok(principal) = authorization.authorize() else {
            break;
        };
        let response = crate::request_context::with_team_principal(principal, || {
            crate::server::respond(line, session)
        });
        if authorization.ensure_live().is_err() {
            break;
        }
        if connection.send(response.as_bytes()).is_err() {
            break;
        }
    }
    connection.close();
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    if !method.starts_with("teams.") {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("Team account methods")
            .map_err(|message| DispatchError::new("local_only", message))?;
        let parsed = directory::parse(method, params)?;
        let body: Value = serde_json::from_str(params).map_err(|_| {
            DispatchError::new("invalid_request", "Check the Teams request and try again.")
        })?;
        if !body
            .get("_accountSession")
            .and_then(Value::as_str)
            .is_some_and(|id| !id.is_empty())
        {
            return Err(api_error(TeamError::AccountChanged));
        }
        let owner = AccountSnapshot::for_request(params)
            .map_err(changed)?
            .ok_or_else(|| api_error(TeamError::AccountChanged))?;
        let client = client(&owner)?;
        let result = match parsed {
            directory::Request::Capabilities => capabilities(&client),
            directory::Request::AuthorizationPreview => authorization_preview(),
            directory::Request::PrepareAuthorization {
                expected_device_key,
            } => prepare_authorization(&owner, &client, &expected_device_key),
            directory::Request::Directory(operation) => directory::perform(&client, operation),
            directory::Request::Connection(request) => {
                connections::perform(&owner, client.clone(), request)
            }
            directory::Request::Comment(request) => {
                connections::comment(&owner, client.clone(), request)
            }
            directory::Request::Ask(request) => connections::ask(&owner, client.clone(), request),
            #[cfg(feature = "local-host")]
            directory::Request::Sharing(request) => sharing::perform(&owner, &client, request),
            #[cfg(feature = "local-host")]
            directory::Request::Chat(request) => chats::perform(&owner, &client, request),
        };
        owner.ensure_current().map_err(changed)?;
        client.ensure_current().map_err(api_error)?;
        result
    })())
}
fn client(owner: &AccountSnapshot) -> Result<TeamClient, DispatchError> {
    let guard = owner.clone();
    let client = TeamClient::capture()
        .map_err(api_error)?
        .with_retirement_guard(move || {
            guard
                .ensure_current()
                .map_err(|_| TeamError::AccountChanged)
        });
    owner.ensure_current().map_err(changed)?;
    Ok(client)
}
fn capabilities(client: &TeamClient) -> Result<Value, DispatchError> {
    match client.capabilities() {
        Ok(capabilities) => {
            let ready = capabilities.ready();
            let can_publish = cfg!(feature = "local-host")
                && capabilities
                    .features
                    .iter()
                    .any(|feature| feature == "checkout-publication");
            let can_connect = ready
                && capabilities
                    .features
                    .iter()
                    .any(|feature| feature == "scoped-connections");
            let can_publish_chats = can_publish
                && can_connect
                && capabilities
                    .features
                    .iter()
                    .any(|feature| feature == "chat-publication");
            let mut value = serialize(capabilities)?;
            value["ready"] = json!(ready);
            value["needsDeviceRegistration"] = json!(false);
            value["canPublishCheckouts"] = json!(can_publish);
            value["canConnectCheckouts"] = json!(can_connect);
            value["canPublishChats"] = json!(can_publish_chats);
            Ok(value)
        }
        Err(TeamError::Rejected { code, .. }) if code == "device_required" => Ok(
            json!({"enabled":true,"ready":false,"needsDeviceRegistration":true,"authorizationRequired":true,"version":1}),
        ),
        Err(TeamError::Unsupported) => Ok(json!({"enabled":false,"ready":false,"version":0})),
        Err(error) => Err(api_error(error)),
    }
}
fn authorization_preview() -> Result<Value, DispatchError> {
    let identity = tokenstat_identity::MachineIdentity::load_or_create().map_err(|_| {
        DispatchError::new(
            "identity_unavailable",
            "This device's connection key is unavailable.",
        )
    })?;
    Ok(
        json!({"deviceKey":identity.public_key_hex(),"deviceName":tokenstat_identity::machine_label()}),
    )
}
fn prepare_authorization(
    owner: &AccountSnapshot,
    client: &TeamClient,
    expected_device_key: &str,
) -> Result<Value, DispatchError> {
    let status = capabilities(client)?;
    if status["enabled"] != true {
        return Err(DispatchError::new(
            "teams_unavailable",
            "Teams is not available on this account server.",
        ));
    }
    owner.ensure_current().map_err(changed)?;
    let identity = tokenstat_identity::MachineIdentity::load_or_create().map_err(|_| {
        DispatchError::new(
            "identity_unavailable",
            "This device's connection key is unavailable.",
        )
    })?;
    if identity.public_key_hex() != expected_device_key {
        return Err(DispatchError::new(
            "device_changed",
            "This device's connection key changed. Review the device again.",
        ));
    }
    let machine = tokenstat_sync::config::ensure_machine_id().map_err(|_| {
        DispatchError::new(
            "identity_unavailable",
            "This device's account reference is unavailable.",
        )
    })?;
    let account = owner
        .client
        .as_ref()
        .ok_or_else(|| api_error(TeamError::NotSignedIn))?;
    account
        .register_machine(
            &machine,
            &identity.public_key_hex(),
            &tokenstat_identity::machine_label(),
            if cfg!(feature = "local-host") {
                "host"
            } else {
                "client"
            },
        )
        .map_err(|_| {
            DispatchError::new(
                "device_registration_failed",
                "Couldn't register this device. Check your account's device limit and try again.",
            )
        })?;
    owner.ensure_current().map_err(changed)?;
    let status = client.capabilities().map_err(api_error)?;
    let url = client.authorization_url(&status).map_err(api_error)?;
    Ok(
        json!({"authorizationURL":url,"deviceKey":identity.public_key_hex(),"deviceName":tokenstat_identity::machine_label()}),
    )
}
fn serialize<T: serde::Serialize>(value: T) -> Result<Value, DispatchError> {
    serde_json::to_value(value).map_err(|_| {
        DispatchError::new(
            "teams_invalid_response",
            "The Teams response could not be read.",
        )
    })
}
fn changed(_message: String) -> DispatchError {
    api_error(TeamError::AccountChanged)
}
pub(crate) fn api_error(error: TeamError) -> DispatchError {
    let code = match &error {
        TeamError::Rejected { code, .. } => code.as_str(),
        TeamError::NotSignedIn => "auth",
        TeamError::AccountChanged => "account_changed",
        TeamError::InvalidRequest => "invalid_request",
        TeamError::InvalidResponse => "teams_invalid_response",
        TeamError::Network => "teams_unreachable",
        TeamError::Unsupported => "teams_unavailable",
    };
    DispatchError::new(code, error.to_string())
}
