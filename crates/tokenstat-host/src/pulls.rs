//! Pull-request connection methods for registered workspaces.
//!
//! The authorization secret stays in this process while the UI shows only the
//! short device code. A paired client may inspect a workspace's availability,
//! but it cannot start, poll, replace, or remove credentials on this machine.

use std::sync::{Mutex, OnceLock, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Params {
    workspace_id: String,
    host: String,
    token: String,
}

fn pending() -> &'static Mutex<Option<tokenstat_sync::forge::DeviceLogin>> {
    static PENDING: OnceLock<Mutex<Option<tokenstat_sync::forge::DeviceLogin>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(None))
}

fn with_pending<T>(
    work: impl FnOnce(&mut Option<tokenstat_sync::forge::DeviceLogin>) -> Result<T, String>,
) -> Result<T, String> {
    let mut guard = pending().lock().unwrap_or_else(PoisonError::into_inner);
    work(&mut guard)
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("pulls.") {
        return None;
    }
    Some(call_inner(method, params))
}

fn call_inner(method: &str, params: &str) -> Result<Value, String> {
    let p: Params = serde_json::from_str(params.trim()).map_err(|error| error.to_string())?;
    match method {
        "pulls.availability" => availability(&p.workspace_id),
        "pulls.signIn" => {
            local_credentials_only()?;
            let host = host_or_default(&p.host);
            let login = tokenstat_sync::forge::device_start(host).map_err(|e| e.to_string())?;
            let value = json!({
                "host": login.host,
                "userCode": login.user_code,
                "openUrl": login.verification_uri,
                "expiresIn": login.expires_in,
                "interval": login.interval,
            });
            with_pending(|pending| {
                *pending = Some(login);
                Ok(())
            })?;
            Ok(value)
        }
        "pulls.signInPoll" => {
            local_credentials_only()?;
            let login = with_pending(|pending| {
                pending
                    .clone()
                    .ok_or_else(|| "no pull-request connection is in progress".into())
            })?;
            match tokenstat_sync::forge::device_poll(&login).map_err(|e| e.to_string())? {
                tokenstat_sync::forge::DeviceStatus::Pending { interval } => {
                    Ok(json!({"state": "pending", "interval": interval}))
                }
                tokenstat_sync::forge::DeviceStatus::Confirmed(credential) => {
                    with_pending(|pending| {
                        *pending = None;
                        Ok(())
                    })?;
                    Ok(json!({
                        "state": "confirmed",
                        "source": credential.source(),
                    }))
                }
            }
        }
        "pulls.cancelSignIn" => {
            local_credentials_only()?;
            with_pending(|pending| {
                *pending = None;
                Ok(())
            })?;
            Ok(json!({"cancelled": true}))
        }
        "pulls.signOut" => {
            local_credentials_only()?;
            tokenstat_sync::forge::sign_out(host_or_default(&p.host)).map_err(|e| e.to_string())?;
            Ok(json!({"signedOut": true}))
        }
        "pulls.setToken" => {
            local_credentials_only()?;
            tokenstat_sync::forge::set_token(host_or_default(&p.host), &p.token)
                .map_err(|e| e.to_string())?;
            Ok(json!({"stored": true}))
        }
        other => Err(format!("unknown pull-request method: {other}")),
    }
}

fn availability(workspace_id: &str) -> Result<Value, String> {
    if workspace_id.trim().is_empty() {
        return Err("pulls.availability needs workspaceId".into());
    }
    let workspace = crate::workspaces::folder(workspace_id)?;
    if !tokenstat_workspace::git::status(&workspace.path).is_repo {
        return Ok(json!({"state": "notRepository"}));
    }
    let Some(remote) = tokenstat_workspace::git::remote(&workspace.path) else {
        return Ok(json!({"state": "noRemote"}));
    };
    let repo = tokenstat_sync::forge::Repo {
        host: remote.host,
        owner: remote.owner,
        repo: remote.repo,
    };
    let mut value = serde_json::to_value(
        tokenstat_sync::forge::availability(&repo).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    if let Value::Object(ref mut fields) = value {
        fields.insert("host".into(), json!(repo.host));
        fields.insert("owner".into(), json!(repo.owner));
        fields.insert("repo".into(), json!(repo.repo));
    }
    Ok(value)
}

fn host_or_default(host: &str) -> &str {
    if host.trim().is_empty() {
        "github.com"
    } else {
        host
    }
}

fn local_credentials_only() -> Result<(), String> {
    crate::request_context::refuse_remote("pull-request connection settings")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_github_without_rewriting_enterprise_hosts() {
        assert_eq!(host_or_default(""), "github.com");
        assert_eq!(host_or_default("git.example.com"), "git.example.com");
    }
}
