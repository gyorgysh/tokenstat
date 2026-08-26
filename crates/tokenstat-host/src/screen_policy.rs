// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Explicit per-device screen permissions and short-lived capabilities.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenPermission {
    pub peer_id: String,
    pub view: bool,
    pub control: bool,
}
#[derive(Default, Deserialize, Serialize)]
struct Store {
    permissions: Vec<ScreenPermission>,
}
struct Capability {
    peer_id: String,
    control: bool,
    expires_at: u64,
}
fn capabilities() -> &'static Mutex<HashMap<String, Capability>> {
    static V: OnceLock<Mutex<HashMap<String, Capability>>> = OnceLock::new();
    V.get_or_init(|| Mutex::new(HashMap::new()))
}
fn path() -> Result<PathBuf, String> {
    tokenstat_identity::identity_dir()
        .map(|p| p.join("screen-policy.json"))
        .map_err(|e| e.to_string())
}
fn load() -> Result<Store, String> {
    match fs::read(path()?) {
        Ok(v) => serde_json::from_slice(&v).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Store::default()),
        Err(e) => Err(e.to_string()),
    }
}
fn save(store: &Store) -> Result<(), String> {
    let path = path()?;
    fs::create_dir_all(path.parent().ok_or("invalid policy path")?).map_err(|e| e.to_string())?;
    let temp = path.with_extension("tmp");
    fs::write(
        &temp,
        serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    fs::rename(temp, path).map_err(|e| e.to_string())
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn legend(tier: &str) -> Result<(), String> {
    if tier == "legend" {
        Ok(())
    } else {
        Err("Screen access requires the Legend plan".into())
    }
}

fn verify_legend_account() -> Result<(), String> {
    let status = tokenstat_sync::sync_status(None).map_err(|e| e.to_string())?;
    legend(status.tier.as_deref().unwrap_or(""))
}

pub(crate) fn verify_view_peer(peer_id: &str) -> Result<(), String> {
    verify_legend_account()?;
    let permission = load()?
        .permissions
        .into_iter()
        .find(|value| value.peer_id == peer_id)
        .ok_or("This device has not been allowed to view the screen")?;
    if permission.view {
        Ok(())
    } else {
        Err("This device does not have screen access".into())
    }
}

pub(crate) fn verify_transfer_peer(peer_id: &str) -> Result<(), String> {
    verify_legend_account()?;
    let permission = load()?
        .permissions
        .into_iter()
        .find(|value| value.peer_id == peer_id)
        .ok_or("This device has not been allowed to transfer files")?;
    if permission.control {
        Ok(())
    } else {
        Err("File transfer needs screen control".into())
    }
}
fn token_hash(token: &[u8]) -> String {
    Sha256::digest(token)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Verify a capability against the peer authenticated by the Noise session.
/// Callers must obtain `peer_id` from the transport, never from request JSON.
pub(crate) fn verify_capability(peer_id: &str, token: &str, control: bool) -> Result<(), String> {
    verify_legend_account()?;
    let permission = load()?
        .permissions
        .into_iter()
        .find(|value| value.peer_id == peer_id)
        .ok_or("This device no longer has screen access")?;
    if !permission.view || (control && !permission.control) {
        return Err("This device no longer has the requested screen permission".into());
    }
    let mut held = capabilities()
        .lock()
        .map_err(|_| "capability lock poisoned")?;
    held.retain(|_, value| value.expires_at >= now());
    let cap = held
        .get(token)
        .ok_or("screen capability is invalid or expired")?;
    if cap.peer_id != peer_id || (control && !cap.control) {
        return Err("screen capability does not grant this request".into());
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetParams {
    peer_id: String,
    view: bool,
    control: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IssueParams {
    peer_id: String,
    control: bool,
    #[serde(default)]
    _tier: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerifyParams {
    peer_id: String,
    token: String,
    control: bool,
}

/// A live session, and a capability that grants the answer being asked for.
///
/// Host-side only: a device that cannot capture a screen has no session to
/// name, and answers `screen.control.set` as the unknown method it is.
#[cfg(feature = "local-host")]
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlParams {
    session_id: String,
    capability: String,
    control: bool,
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("screen.") {
        return None;
    }
    Some((|| match method {
        "screen.policy.list" => {
            if crate::request_context::remote_peer().is_some() {
                return Err("screen policy settings are local-only".into());
            }
            Ok(serde_json::to_value(load()?.permissions).map_err(|e| e.to_string())?)
        }
        "screen.policy.set" => {
            if crate::request_context::remote_peer().is_some() {
                return Err("screen policy settings are local-only".into());
            }
            let p: SetParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            if p.control && !p.view {
                return Err("control permission requires view permission".into());
            }
            let mut store = load()?;
            store.permissions.retain(|v| v.peer_id != p.peer_id);
            store.permissions.push(ScreenPermission {
                peer_id: p.peer_id.clone(),
                view: p.view,
                control: p.control,
            });
            save(&store)?;
            capabilities()
                .lock()
                .map_err(|_| "capability lock poisoned")?
                .retain(|_, capability| capability.peer_id != p.peer_id);
            #[cfg(feature = "local-host")]
            crate::screen_runtime::revoke_peer(&p.peer_id, p.view, p.control)?;
            Ok(json!({"saved":true}))
        }
        "screen.access.request" => {
            if crate::request_context::remote_peer().is_some() {
                return Err("screen access requests are sent from the requesting device".into());
            }
            let sent = tokenstat_sync::push::notify(tokenstat_sync::push::Reason::ScreenAccess)
                .map_err(|e| e.to_string())?;
            Ok(json!({"sent": sent.devices, "enabled": sent.enabled, "signedIn": sent.signed_in}))
        }
        "screen.capability.issue" => {
            let p: IssueParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            verify_legend_account()?;
            if let Some(authenticated) = crate::request_context::remote_peer()
                && authenticated != p.peer_id
            {
                return Err(
                    "a screen capability may be issued only to the authenticated device".into(),
                );
            }
            let permission = load()?
                .permissions
                .into_iter()
                .find(|v| v.peer_id == p.peer_id)
                .ok_or("This device has not been allowed to view the screen")?;
            if !permission.view || (p.control && !permission.control) {
                return Err("This device does not have the requested screen permission".into());
            }
            let mut raw = [0u8; 32];
            rand::rng().fill_bytes(&mut raw);
            let token = token_hash(&raw);
            let expires_at = now() + 300;
            capabilities()
                .lock()
                .map_err(|_| "capability lock poisoned")?
                .insert(
                    token.clone(),
                    Capability {
                        peer_id: p.peer_id,
                        control: p.control,
                        expires_at,
                    },
                );
            Ok(json!({"token":token,"expiresAt":expires_at,"control":p.control}))
        }
        "screen.capability.verify" => {
            let p: VerifyParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let peer = match crate::request_context::remote_peer() {
                Some(authenticated) if authenticated != p.peer_id => {
                    return Err("screen capability verify must use the authenticated device".into());
                }
                Some(authenticated) => authenticated,
                None => p.peer_id,
            };
            verify_capability(&peer, &p.token, p.control)?;
            Ok(json!({"allowed":true}))
        }
        // Hand the mouse over, or take it back, on a session that is already
        // running. The alternative was reopening the stream, which the relay
        // refuses while the old channel is still closing. See
        // `screen_runtime::set_control`.
        #[cfg(feature = "local-host")]
        "screen.control.set" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("screen control must arrive over an authenticated remote connection")?;
            let p: ControlParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            verify_capability(&peer, &p.capability, p.control)?;
            crate::screen_runtime::set_control(&p.session_id, &peer, p.control)?;
            Ok(json!({"control":p.control}))
        }
        "screen.direct.candidate" => direct_candidate(),
        _ => Err(format!("unknown screen method: {method}")),
    })())
}

fn direct_candidate() -> Result<Value, String> {
    let peer = crate::request_context::remote_peer()
        .ok_or("direct candidate must be requested by an authenticated peer")?;
    verify_view_peer(&peer)?;
    #[cfg(feature = "local-host")]
    {
        let output = std::process::Command::new("hostname")
            .output()
            .map_err(|error| error.to_string())?;
        let mut host = String::from_utf8(output.stdout).map_err(|error| error.to_string())?;
        host = host.trim().trim_end_matches(".local").to_string();
        if host.is_empty()
            || !host
                .bytes()
                .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'-' | b'.'))
        {
            return Err("this host has no usable local-network name".into());
        }
        Ok(json!({"address":format!("{host}.local:7878")}))
    }
    #[cfg(not(feature = "local-host"))]
    Err("this device does not accept direct screen connections".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legend_and_explicit_permission_are_both_required() {
        assert!(legend("patron").is_err());
        assert!(legend("legend").is_ok());
        let p = ScreenPermission {
            peer_id: "phone".into(),
            view: true,
            control: false,
        };
        assert!(p.view);
        assert!(!p.control);
    }
    #[test]
    fn tokens_are_random_and_hashed() {
        let mut a = [0u8; 32];
        rand::rng().fill_bytes(&mut a);
        let mut b = [0u8; 32];
        rand::rng().fill_bytes(&mut b);
        assert_ne!(token_hash(&a), token_hash(&b));
        assert_eq!(token_hash(&a).len(), 64);
    }

    #[test]
    fn a_remote_peer_cannot_change_its_own_policy() {
        crate::request_context::with_remote_peer("phone", || {
            assert!(call("screen.policy.list", "{}").unwrap().is_err());
            assert!(
                call(
                    "screen.policy.set",
                    r#"{"peerId":"phone","view":true,"control":true}"#
                )
                .unwrap()
                .is_err()
            );
        });
    }

    #[test]
    fn a_remote_peer_cannot_verify_a_capability_as_somebody_else() {
        crate::request_context::with_remote_peer("phone", || {
            let refused = call(
                "screen.capability.verify",
                r#"{"peerId":"other","token":"abc","control":true}"#,
            )
            .unwrap()
            .expect_err("must refuse a mismatched peer");
            assert!(refused.contains("authenticated device"), "{refused}");
        });
    }
}
