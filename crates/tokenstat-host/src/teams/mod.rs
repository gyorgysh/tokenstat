// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Organization management belongs to the person signed in on this device.
//! Teammate chat requests use their own scoped entry point; they never borrow
//! this machine's account credential or its personal workspace policy.

mod directory;
use crate::account_session::AccountSnapshot;
use crate::error::DispatchError;
use serde_json::{Value, json};
use tokenstat_sync::teams::{TeamClient, TeamError};

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
            directory::Request::PrepareAuthorization => prepare_authorization(&owner, &client),
            directory::Request::Directory(operation) => directory::perform(&client, operation),
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
            let mut value = serialize(capabilities)?;
            value["ready"] = json!(ready);
            value["needsDeviceRegistration"] = json!(false);
            Ok(value)
        }
        Err(TeamError::Rejected { code, .. }) if code == "device_required" => Ok(
            json!({"enabled":true,"ready":false,"needsDeviceRegistration":true,"authorizationRequired":true,"version":1}),
        ),
        Err(TeamError::Unsupported) => Ok(json!({"enabled":false,"ready":false,"version":0})),
        Err(error) => Err(api_error(error)),
    }
}
fn prepare_authorization(
    owner: &AccountSnapshot,
    client: &TeamClient,
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
fn api_error(error: TeamError) -> DispatchError {
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
