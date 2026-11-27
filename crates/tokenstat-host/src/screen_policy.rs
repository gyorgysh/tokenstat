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
///
/// Shared with `workspace_policy`, because a person answers both kinds of
/// request the same way and two different staleness windows would be two
/// different behaviours for one action.
pub(crate) const PENDING_TTL: u64 = 15 * 60;

const REVIEW_DEMO_ACCOUNT_ID: &str = "u_5ce664fd625c5ea13f51f5d2";

#[cfg_attr(not(unix), allow(dead_code))]
const REVIEW_DEMO_USER: &str = "appreview";

#[cfg(unix)]
fn on_review_machine() -> bool {
    let mut size = 16 * 1024;
    loop {
        let mut buf = vec![0 as libc::c_char; size];
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut found: *mut libc::passwd = std::ptr::null_mut();
        let rc = unsafe {
            libc::getpwuid_r(
                libc::geteuid(),
                &mut pwd,
                buf.as_mut_ptr(),
                buf.len(),
                &mut found,
            )
        };
        if rc == libc::ERANGE && size < 256 * 1024 {
            size *= 2;
            continue;
        }
        if rc != 0 || found.is_null() || pwd.pw_name.is_null() {
            return false;
        }
        let name = unsafe { std::ffi::CStr::from_ptr(pwd.pw_name) };
        return name
            .to_str()
            .map(|n| n == REVIEW_DEMO_USER)
            .unwrap_or(false);
    }
}

#[cfg(not(unix))]
fn on_review_machine() -> bool {
    false
}

#[derive(Default, Deserialize, Serialize)]
struct Store {
    permissions: Vec<ScreenPermission>,
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
    load_at(&path()?)
}

fn load_at(path: &std::path::Path) -> Result<Store, String> {
    let mut store: Store = match fs::read(path) {
        Ok(v) => serde_json::from_slice(&v).map_err(|e| e.to_string())?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Store::default(),
        Err(e) => return Err(e.to_string()),
    };

    prune(&mut store, now());
    Ok(store)
}

fn prune(store: &mut Store, now: u64) {
    prune_pending(&mut store.pending, now);
}

/// Drop requests nobody answered in time. Shared, for the same reason the TTL
/// is.
pub(crate) fn prune_pending(pending: &mut Vec<PendingRequest>, now: u64) {
    pending.retain(|request| request.expires_at > now);
}

/// Seconds since the epoch, shared so both policies stamp requests the same.
pub(crate) fn now_secs() -> u64 {
    now()
}

fn update_store<T>(edit: impl FnOnce(&mut Store) -> T) -> Result<T, String> {
    update_store_at(&path()?, edit)
}

fn update_store_at<T>(
    path: &std::path::Path,
    edit: impl FnOnce(&mut Store) -> T,
) -> Result<T, String> {
    static WRITES: Mutex<()> = Mutex::new(());
    let _write = WRITES.lock().map_err(|_| "screen policy lock poisoned")?;
    let mut store = load_at(path)?;
    let result = edit(&mut store);
    save_at(path, &store)?;
    #[cfg(feature = "local-host")]
    invalidate_stream_cache();
    Ok(result)
}

fn save_at(path: &std::path::Path, store: &Store) -> Result<(), String> {
    let data = serde_json::to_string_pretty(store).map_err(|e| e.to_string())?;
    tokenstat_sync::snapshot::write_private_atomically(path, &data).map_err(|e| e.to_string())
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
        Err("Screen access requires the Elite plan".into())
    }
}

fn verify_legend_account() -> Result<tokenstat_sync::profile::StatusResult, String> {
    let status = tokenstat_sync::sync_status(None).map_err(|e| e.to_string())?;
    legend(status.tier.as_deref().unwrap_or(""))?;
    Ok(status)
}

/// Local permission check for every stream read/write; no account requests.
///
/// Hot path (every frame/tick): served from a 1s in-memory mirror of the
/// grants so live streams do not do file I/O per frame. `set_permission`
/// invalidates the mirror on write. A failed refresh denies access rather than
/// retaining grants whose current state cannot be checked. Only the grant row is rechecked
/// here — Legend-tier revocation is enforced at capability issue, not per
/// frame, by design.
#[cfg(feature = "local-host")]
pub(crate) fn stream_allowed(peer: &str, control: bool) -> bool {
    if let Ok(guard) = stream_cache().lock()
        && let Some(entry) = guard.as_ref()
        && entry.at.elapsed() < std::time::Duration::from_secs(1)
    {
        return entry
            .grants
            .iter()
            .any(|(id, view, ctrl)| id == peer && *view && (!control || *ctrl));
    }

    let Ok(mut guard) = stream_cache().lock() else {
        return false;
    };
    let grants: Option<Vec<(String, bool, bool)>> = load().ok().map(|store| {
        store
            .permissions
            .into_iter()
            .map(|grant| (grant.peer_id, grant.view, grant.control))
            .collect()
    });
    match grants {
        Some(grants) => {
            let allowed = grants
                .iter()
                .any(|(id, view, ctrl)| id == peer && *view && (!control || *ctrl));
            *guard = Some(StreamCacheEntry {
                at: std::time::Instant::now(),
                grants,
            });
            allowed
        }
        None => {
            *guard = None;
            false
        }
    }
}

#[cfg(feature = "local-host")]
struct StreamCacheEntry {
    at: std::time::Instant,
    grants: Vec<(String, bool, bool)>,
}

#[cfg(feature = "local-host")]
fn stream_cache() -> &'static Mutex<Option<StreamCacheEntry>> {
    static CACHE: OnceLock<Mutex<Option<StreamCacheEntry>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

#[cfg(feature = "local-host")]
fn invalidate_stream_cache() {
    if let Ok(mut guard) = stream_cache().lock() {
        *guard = None;
    }
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

#[cfg(feature = "local-host")]
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlParams {
    session_id: String,
    capability: String,
    control: bool,
}

#[cfg(feature = "local-host")]
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QualityParams {
    session_id: String,
    capability: String,
    quality: String,
}

fn is_review_demo(status: &tokenstat_sync::profile::StatusResult) -> bool {
    account_is_review_demo(status) && on_review_machine()
}

fn account_is_review_demo(status: &tokenstat_sync::profile::StatusResult) -> bool {
    status.review_demo && status.account_id.as_deref() == Some(REVIEW_DEMO_ACCOUNT_ID)
}

/// The same question without the plan check, for a grant that is not Legend's.
///
/// Watching a screen is Legend and asks `verify_legend_account` anyway. Opening
/// the work is not, so `workspace_policy` needs the account fact on its own
/// rather than one welded to a tier it does not require.
///
/// Anything other than a positive answer is a no: not signed in, no network for
/// a moment, an older server that does not name the account. The exception is
/// worth nothing next to granting by accident.
pub(crate) fn signed_into_review_demo() -> bool {
    tokenstat_sync::sync_status(None)
        .map(|status| is_review_demo(&status))
        .unwrap_or(false)
}

fn set_permission(peer_id: &str, view: bool, control: bool) -> Result<(), String> {
    if control && !view {
        return Err("control permission requires view permission".into());
    }
    update_store(|store| {
        store.permissions.retain(|v| v.peer_id != peer_id);
        store.permissions.push(ScreenPermission {
            peer_id: peer_id.to_string(),
            view,
            control,
        });
        store.pending.retain(|request| request.peer_id != peer_id);
    })?;
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

        "screen.access.ask" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("a screen access request must arrive from the device asking")?;
            let p: AskParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let label = crate::remote::account_peer_label_hex(&peer);
            let granted =
                update_store(|store| {
                    if store.permissions.iter().any(|held| {
                        held.peer_id == peer && held.view && (!p.control || held.control)
                    }) {
                        return true;
                    }

                    if store
                        .pending
                        .iter()
                        .any(|request| request.peer_id == peer && (request.control || !p.control))
                    {
                        return false;
                    }
                    let asked_at = now();
                    store.pending.retain(|request| request.peer_id != peer);
                    store.pending.push(PendingRequest {
                        label,
                        peer_id: peer.clone(),
                        control: p.control,
                        asked_at,
                        expires_at: asked_at + PENDING_TTL,
                    });
                    false
                })?;
            if granted {
                return Ok(json!({"pending": false, "granted": true}));
            }

            let review_demo = verify_legend_account()
                .map(|status| is_review_demo(&status))
                .unwrap_or(false);
            if review_demo {
                set_permission(&peer, true, p.control)?;
                return Ok(json!({"pending": false, "granted": true, "reviewDemo": true}));
            }
            Ok(json!({"pending": true}))
        }
        "screen.access.pending" => {
            if crate::request_context::remote_peer().is_some() {
                return Err("screen access requests are answered on the host".into());
            }
            Ok(serde_json::to_value(load()?.pending).map_err(|e| e.to_string())?)
        }

        "screen.access.answer" => {
            if crate::request_context::remote_peer().is_some() {
                return Err("screen access requests are answered on the host".into());
            }
            let p: SetParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            set_permission(&p.peer_id, p.view, p.control)?;
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

        #[cfg(feature = "local-host")]
        "screen.control.set" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("screen control must arrive over an authenticated remote connection")?;
            let p: ControlParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            verify_capability(&peer, &p.capability, p.control)?;
            crate::screen_runtime::set_control(&p.session_id, &peer, p.control)?;
            Ok(json!({"control":p.control}))
        }

        #[cfg(feature = "local-host")]
        "screen.quality.set" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("screen quality must arrive over an authenticated remote connection")?;
            let p: QualityParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            verify_capability(&peer, &p.capability, false)?;
            crate::screen_runtime::set_quality(&p.session_id, &peer, &p.quality)?;
            Ok(json!({"quality": p.quality}))
        }
        "screen.direct.candidates" => direct_candidates(),

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
    fn concurrent_policy_edits_preserve_every_devices_answer() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("policy.json");
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(16));
        std::thread::scope(|scope| {
            for index in 0..16 {
                let barrier = barrier.clone();
                let path = &path;
                scope.spawn(move || {
                    barrier.wait();
                    update_store_at(path, |store| {
                        std::thread::sleep(std::time::Duration::from_millis(1));
                        store.permissions.push(ScreenPermission {
                            peer_id: format!("peer-{index}"),
                            view: index % 2 == 0,
                            control: false,
                        });
                    })
                    .unwrap();
                });
            }
        });
        let store = load_at(&path).unwrap();
        assert_eq!(store.permissions.len(), 16);
        for index in 0..16 {
            let permission = store
                .permissions
                .iter()
                .find(|p| p.peer_id == format!("peer-{index}"))
                .unwrap();
            assert_eq!(permission.view, index % 2 == 0);
        }
    }

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
    fn the_automatic_grant_needs_the_flag_and_the_compiled_in_account() {
        let status =
            |account: Option<&str>, review_demo: bool| tokenstat_sync::profile::StatusResult {
                host: String::new(),
                handle: None,
                tier: Some("legend".into()),
                last_sync_at: None,
                machines: vec![],
                schema_min_v: None,
                schema_max_v: None,
                schema_current: None,
                account_id: account.map(str::to_string),
                review_demo,
                raw: serde_json::Value::Null,
            };

        assert!(!account_is_review_demo(&status(
            Some("u_someone_else"),
            true
        )));

        assert!(!account_is_review_demo(&status(
            Some(REVIEW_DEMO_ACCOUNT_ID),
            false
        )));

        assert!(!account_is_review_demo(&status(None, true)));
        assert!(account_is_review_demo(&status(
            Some(REVIEW_DEMO_ACCOUNT_ID),
            true
        )));

        assert!(
            !on_review_machine(),
            "a test host is not the review machine"
        );
        assert!(!is_review_demo(&status(Some(REVIEW_DEMO_ACCOUNT_ID), true)));
    }

    #[test]
    fn a_request_that_says_nothing_is_not_asking_for_the_mouse() {
        let quiet: AskParams = serde_json::from_str("{}").unwrap();
        assert!(!quiet.control);
        let asked: AskParams = serde_json::from_str(r#"{"control":true}"#).unwrap();
        assert!(asked.control);
    }

    #[test]
    fn repeated_screen_request_keeps_the_host_question_until_access_expands() {
        crate::test_identity::isolated(|| {
            let peer = "58".repeat(32);
            let ask = |control| {
                crate::request_context::with_remote_peer(&peer, || {
                    call(
                        "screen.access.ask",
                        if control { r#"{"control":true}"# } else { "{}" },
                    )
                    .unwrap()
                    .unwrap()
                })
            };
            assert_eq!(ask(false)["pending"], true);
            let first = load().unwrap();
            assert_eq!(first.pending.len(), 1);
            for _ in 0..3 {
                assert_eq!(ask(false)["pending"], true);
            }
            let repeated = load().unwrap();
            assert_eq!(repeated.pending.len(), 1);
            assert_eq!(repeated.pending[0].asked_at, first.pending[0].asked_at);
            assert!(!repeated.pending[0].control);
            assert_eq!(ask(true)["pending"], true);
            let expanded = load().unwrap();
            assert_eq!(expanded.pending.len(), 1);
            assert!(expanded.pending[0].control);
            assert_eq!(ask(false)["pending"], true);
            assert!(load().unwrap().pending[0].control);
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
