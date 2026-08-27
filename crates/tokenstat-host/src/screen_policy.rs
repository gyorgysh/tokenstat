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
/// A device that has asked to see this screen and is waiting for an answer.
///
/// Kept on disk beside the grants rather than in memory, so a request made
/// while the owner was away survives the app being quit and is still there
/// when they come back. Expiry is what keeps that from becoming a pile: a
/// question nobody answered in fifteen minutes is stale, and the device can
/// ask again.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingRequest {
    pub peer_id: String,
    /// The name the account carries for that device, when it knows one. A
    /// public key is not something anybody can recognise their own phone by.
    #[serde(default)]
    pub label: Option<String>,
    /// Whether mouse and keyboard were asked for as well as the picture.
    pub control: bool,
    pub asked_at: u64,
    pub expires_at: u64,
}

/// How long an unanswered request stands.
const PENDING_TTL: u64 = 15 * 60;

#[derive(Default, Deserialize, Serialize)]
struct Store {
    permissions: Vec<ScreenPermission>,
    /// Absent in every file written before requests existed, which is why it
    /// defaults rather than being required.
    #[serde(default)]
    pending: Vec<PendingRequest>,
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
    let mut store: Store = match fs::read(path()?) {
        Ok(v) => serde_json::from_slice(&v).map_err(|e| e.to_string())?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Store::default(),
        Err(e) => return Err(e.to_string()),
    };
    // Pruned on the way in rather than on a timer. Every path that cares about
    // a request reads the store first, so there is no moment where an expired
    // one can be seen, and nothing has to be woken up to sweep.
    prune(&mut store, now());
    Ok(store)
}

fn prune(store: &mut Store, now: u64) {
    store.pending.retain(|request| request.expires_at > now);
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
/// What a device asks for. No peer id: that comes from the transport, and a
/// field here would be a device naming somebody else.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AskParams {
    #[serde(default)]
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

/// Write one device's grant, and make the change take effect now.
///
/// Every path that changes a permission goes through here: the toggles in
/// Devices, and answering a request. Held capabilities are dropped and a live
/// session is cut back or ended, because a grant somebody just narrowed has to
/// mean the next frame, not the next reconnect.
fn set_permission(peer_id: &str, view: bool, control: bool) -> Result<(), String> {
    if control && !view {
        return Err("control permission requires view permission".into());
    }
    let mut store = load()?;
    store.permissions.retain(|v| v.peer_id != peer_id);
    store.permissions.push(ScreenPermission {
        peer_id: peer_id.to_string(),
        view,
        control,
    });
    save(&store)?;
    capabilities()
        .lock()
        .map_err(|_| "capability lock poisoned")?
        .retain(|_, capability| capability.peer_id != peer_id);
    #[cfg(feature = "local-host")]
    crate::screen_runtime::revoke_peer(peer_id, view, control)?;
    Ok(())
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
            set_permission(&p.peer_id, p.view, p.control)?;
            Ok(json!({"saved":true}))
        }
        // The device asking, over the tunnel it is already connected on.
        //
        // The push below is a nudge and never was the mechanism: a
        // notification carries a reason and a machine id by design, never the
        // id of the device that asked, and the Mac app does not register for
        // push at all. So the question travels the one channel that can carry
        // it, and the peer it names comes from the transport rather than from
        // the params, the same rule `screen.capability.issue` follows.
        "screen.access.ask" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("a screen access request must arrive from the device asking")?;
            let p: AskParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let mut store = load()?;
            if let Some(held) = store.permissions.iter().find(|v| v.peer_id == peer)
                && held.view
                && (!p.control || held.control)
            {
                return Ok(json!({"pending": false, "granted": true}));
            }
            let asked_at = now();
            store.pending.retain(|request| request.peer_id != peer);
            store.pending.push(PendingRequest {
                label: crate::remote::account_peer_label_hex(&peer),
                peer_id: peer,
                control: p.control,
                asked_at,
                expires_at: asked_at + PENDING_TTL,
            });
            save(&store)?;
            Ok(json!({"pending": true}))
        }
        "screen.access.pending" => {
            if crate::request_context::remote_peer().is_some() {
                return Err("screen access requests are answered on the host".into());
            }
            Ok(serde_json::to_value(load()?.pending).map_err(|e| e.to_string())?)
        }
        // The answer, from the person at this machine. Deny is view false and
        // control false, which is the same call: refusing and revoking are the
        // same state, and a request that is answered stops standing either way.
        "screen.access.answer" => {
            if crate::request_context::remote_peer().is_some() {
                return Err("screen access requests are answered on the host".into());
            }
            let p: SetParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            set_permission(&p.peer_id, p.view, p.control)?;
            let mut store = load()?;
            store.pending.retain(|request| request.peer_id != p.peer_id);
            save(&store)?;
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
        "screen.direct.candidates" => direct_candidates(),
        // Kept for peers from before candidate lists. New callers never rely
        // on this one-address contract.
        "screen.direct.candidate" => direct_candidate(),
        _ => Err(format!("unknown screen method: {method}")),
    })())
}

fn direct_candidate() -> Result<Value, String> {
    let candidates = verified_direct_candidates()?;
    let address = candidates
        .first()
        .map(|candidate| candidate.address.as_str())
        .ok_or("this host has no direct address available")?;
    Ok(json!({"address":address}))
}

fn direct_candidates() -> Result<Value, String> {
    Ok(json!({"candidates":verified_direct_candidates()?}))
}

fn verified_direct_candidates() -> Result<Vec<crate::remote::DirectCandidate>, String> {
    let peer = crate::request_context::remote_peer()
        .ok_or("direct candidate must be requested by an authenticated peer")?;
    verify_view_peer(&peer)?;
    let candidates = crate::remote::direct_candidates();
    if candidates.is_empty() {
        Err("this device does not currently accept direct screen connections".into())
    } else {
        Ok(candidates)
    }
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
    fn only_the_asking_device_may_ask_and_only_the_host_may_answer() {
        // No transport, so nobody is asking: a local caller cannot queue a
        // request in some other device's name.
        let refused = call("screen.access.ask", r#"{"control":true}"#)
            .unwrap()
            .expect_err("a local caller has no device to ask for");
        assert!(refused.contains("device asking"), "{refused}");

        crate::request_context::with_remote_peer("phone", || {
            for method in ["screen.access.pending", "screen.access.answer"] {
                let refused = call(method, r#"{"peerId":"phone","view":true,"control":true}"#)
                    .unwrap()
                    .expect_err("a device must not answer its own request");
                assert!(refused.contains("answered on the host"), "{refused}");
            }
        });
    }

    #[test]
    fn control_without_view_is_refused_before_anything_is_written() {
        let refused = call(
            "screen.policy.set",
            r#"{"peerId":"phone","view":false,"control":true}"#,
        )
        .unwrap()
        .expect_err("control needs view");
        assert!(refused.contains("requires view"), "{refused}");
    }

    #[test]
    fn an_unanswered_request_stops_standing_once_it_expires() {
        let request = |peer: &str, expires_at: u64| PendingRequest {
            peer_id: peer.into(),
            label: None,
            control: false,
            asked_at: 0,
            expires_at,
        };
        let mut store = Store {
            permissions: vec![],
            pending: vec![request("stale", 100), request("fresh", 300)],
        };
        prune(&mut store, 200);
        assert_eq!(store.pending.len(), 1);
        assert_eq!(store.pending[0].peer_id, "fresh");
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
