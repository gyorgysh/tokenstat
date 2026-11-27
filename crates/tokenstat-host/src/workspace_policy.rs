// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Which devices may reach the work on this machine.

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

static ALLOWED_GENERATION: AtomicU64 = AtomicU64::new(0);
use std::time::{Duration, Instant, SystemTime};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::access_audit::{self, Authority};
use crate::screen_policy::{PENDING_TTL, PendingRequest, now_secs, prune_pending};

const MAX_PENDING: usize = 32;
const MAX_ASKS_PER_HOUR: u32 = 5;
const MAX_REDEEMS_PER_HOUR: u32 = 10;
const MAX_INVITE_ATTEMPTS: u32 = 5;
const HOUR: u64 = 60 * 60;

#[derive(Default, Deserialize, Serialize)]
struct Store {
    #[serde(default)]
    allowed: Vec<String>,
    #[serde(default)]
    pending: Vec<PendingRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    invite: Option<Invite>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    attempts: Vec<Attempt>,
}

#[derive(Deserialize, Serialize)]
struct Invite {
    hash: String,
    expires_at: u64,
    #[serde(default)]
    tries: u32,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Attempt {
    peer_id: String,
    kind: String,
    at: u64,
}

fn path() -> Result<PathBuf, String> {
    tokenstat_identity::identity_dir()
        .map(|p| p.join("workspace-policy.json"))
        .map_err(|e| e.to_string())
}

fn load() -> Result<Store, String> {
    let mut store: Store = match read_policy(&path()?) {
        Ok(v) => serde_json::from_slice(&v).map_err(|e| e.to_string())?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Store::default(),
        Err(e) => return Err(e.to_string()),
    };
    let now = now_secs();
    prune_pending(&mut store.pending, now);
    if store
        .invite
        .as_ref()
        .is_some_and(|invite| invite.expires_at <= now)
    {
        store.invite = None;
    }
    store
        .attempts
        .retain(|attempt| attempt.at.saturating_add(HOUR) > now);
    Ok(store)
}

fn read_policy(path: &std::path::Path) -> std::io::Result<Vec<u8>> {
    use std::io::Read;
    const LIMIT: u64 = 8 * 1024 * 1024;
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > LIMIT {
        return Err(std::io::Error::other(
            "Workspace access policy is not a bounded regular file",
        ));
    }
    let mut bytes = Vec::new();
    file.take(LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > LIMIT {
        return Err(std::io::Error::other(
            "Workspace access policy is too large",
        ));
    }
    Ok(bytes)
}

impl Store {
    fn recent(&self, peer_id: &str, kind: &str) -> u32 {
        self.attempts
            .iter()
            .filter(|attempt| attempt.peer_id == peer_id && attempt.kind == kind)
            .count() as u32
    }

    fn note(&mut self, peer_id: &str, kind: &str, now: u64) {
        self.attempts.push(Attempt {
            peer_id: peer_id.to_owned(),
            kind: kind.to_owned(),
            at: now,
        });
    }
}

const CODE_ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

fn mint_code() -> Result<String, String> {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;

    let code: String = bytes
        .iter()
        .map(|byte| CODE_ALPHABET[(byte & 0x1f) as usize] as char)
        .collect();
    Ok(format!("{}-{}", &code[..4], &code[4..]))
}

fn normalize_code(value: &str) -> Result<String, String> {
    let code: String = value
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| match c.to_ascii_uppercase() {
            'I' | 'L' => '1',
            'O' => '0',
            'U' => 'V',
            other => other,
        })
        .collect();
    if code.len() != 8 || !code.bytes().all(|byte| CODE_ALPHABET.contains(&byte)) {
        return Err("That is not a code from this machine. It is eight letters and digits.".into());
    }
    Ok(code)
}

fn hash_code(code: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(code.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn same_hash(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

fn save(store: &Store) -> Result<(), String> {
    let path = path()?;
    let body = serde_json::to_string_pretty(store).map_err(|error| error.to_string())?;
    tokenstat_sync::snapshot::write_private_atomically(&path, &body)
        .map_err(|error| error.to_string())?;
    invalidate_allowed_cache();
    Ok(())
}

/// Whether one device may reach the work here.
///
/// Cached against the file's own timestamp, the way `PeerStore::cached` is and
/// for the same reason: this is asked on every gated request, and a phone with
/// a terminal open polls `pty.read` several times a second. A file stamp is far
/// cheaper than a read and a parse, and keying on it means a grant somebody
/// just took away still means the next request rather than the next minute.
/// The length and [`ALLOWED_CACHE_MAX_AGE`] guard the cross-process case, where
/// another process's write can land in the same filesystem stamp tick.
pub(crate) fn is_allowed(peer_id: &str) -> bool {
    allowed_now().is_some_and(|allowed| allowed.contains(peer_id))
}

/// Revalidate an authenticated request at a work acceptance boundary. Cached
/// tunnel admission can predate a lock wait or an expensive launch preparation.
#[cfg(feature = "local-host")]
pub(crate) fn require_current_access() -> Result<(), crate::error::DispatchError> {
    let Some(peer) = crate::request_context::remote_peer() else {
        return Ok(());
    };
    let approved = tokenstat_identity::public_key_from_hex(&peer)
        .ok()
        .is_some_and(|key| {
            tokenstat_identity::PeerStore::load().is_ok_and(|store| store.is_approved(&key))
        });
    if !approved {
        return Err(crate::error::DispatchError::new(
            "not_approved",
            "This computer no longer approves this device.",
        ));
    }

    if !load().is_ok_and(|store| store.allowed.contains(&peer)) {
        return Err(crate::error::DispatchError::new(
            "workspace_not_allowed",
            "This device no longer has access to work on this computer.",
        ));
    }
    Ok(())
}

const ALLOWED_CACHE_MAX_AGE: Duration = Duration::from_secs(2);

type AllowedCached = Mutex<
    Option<(
        Option<SystemTime>,
        u64,
        Instant,
        std::sync::Arc<HashSet<String>>,
    )>,
>;

fn allowed_cache() -> &'static AllowedCached {
    static CACHE: OnceLock<AllowedCached> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

fn invalidate_allowed_cache() {
    if let Ok(mut guard) = allowed_cache().lock() {
        ALLOWED_GENERATION.fetch_add(1, Ordering::AcqRel);
        *guard = None;
    }
}

fn allowed_now() -> Option<std::sync::Arc<HashSet<String>>> {
    let cache = allowed_cache();
    let generation = ALLOWED_GENERATION.load(Ordering::Acquire);

    let path = path().ok()?;

    let (stamp, len) = match fs::metadata(&path) {
        Ok(meta) => (meta.modified().ok(), meta.len()),
        Err(_) => (None, 0),
    };
    if let Ok(guard) = cache.lock()
        && let Some((seen, seen_len, read_at, allowed)) = guard.as_ref()
        && *seen == stamp
        && *seen_len == len
        && stamp.is_some()
        && read_at.elapsed() < ALLOWED_CACHE_MAX_AGE
    {
        return Some(std::sync::Arc::clone(allowed));
    }

    let allowed = std::sync::Arc::new(load().ok()?.allowed.into_iter().collect::<HashSet<_>>());
    if let Ok(mut guard) = cache.lock() {
        if ALLOWED_GENERATION.load(Ordering::Acquire) != generation {
            return None;
        }
        *guard = Some((stamp, len, Instant::now(), std::sync::Arc::clone(&allowed)));
    }
    Some(allowed)
}

static MUTATION: Mutex<()> = Mutex::new(());

fn mutation_lock() -> Result<crate::identity_storage::Guard, String> {
    crate::identity_storage::lock("workspace-policy.lock", &MUTATION)
}

/// Let a device in, or shut it out.
///
/// Called by the toggle in Devices, by answering a request, and by pairing,
/// which grants the work alongside the trust. The label is best-effort from
/// the held directory, never a fetch: pairing runs on every phone connect,
/// and a stalled fetch would stall the connect on an audit line.
pub(crate) fn set_allowed_by_with_label(
    peer_id: &str,
    allow: bool,
    by: Authority,
    label: Option<String>,
) -> Result<(), String> {
    let _guard = mutation_lock()?;
    set_allowed_locked_with_label(peer_id, allow, by, label)
}

fn set_allowed_locked_with_label(
    peer_id: &str,
    allow: bool,
    by: Authority,
    label: Option<String>,
) -> Result<(), String> {
    let mut store = load()?;
    let already = store.allowed.iter().any(|held| held == peer_id);
    store.allowed.retain(|held| held != peer_id);
    if allow {
        store.allowed.push(peer_id.to_string());
    }

    store.pending.retain(|request| request.peer_id != peer_id);
    save(&store)?;
    if already != allow {
        let owned;
        let resolved = match label {
            Some(label) => Some(label),
            None => {
                owned = crate::remote::account_peer_label_hex_cached(peer_id);
                owned.clone()
            }
        };
        access_audit::record(
            if allow { "granted" } else { "revoked" },
            Some(peer_id),
            resolved.as_deref(),
            by,
        );
    }
    Ok(())
}

/// Read the counts without the local-only guard, for `host.provisionStatus`.
///
/// The numbers, never the keys: a device that is allowed here may see that two
/// devices are, and answering a pending request stays a thing done at the
/// machine.
pub(crate) fn counts() -> Result<(usize, usize), String> {
    let store = load()?;
    Ok((store.allowed.len(), store.pending.len()))
}

/// Whether a method reaches the work on this machine.
///
/// Pure, and tested, because the whole guarantee is this list. Reporting is
/// deliberately outside it: reading how many tokens a machine spent is what
/// the product is for, it is aggregate, and gating it would make a phone that
/// cannot open a folder also unable to draw a heatmap.
pub(crate) fn needs_access(method: &str, stream_kind: Option<&str>) -> bool {
    if method.starts_with("workspace.access.") {
        return false;
    }
    match method {
        m if m.starts_with("workspace.") => true,

        m if m.starts_with("fs.") => true,

        "host.provisionStatus" | "host.logs" => true,

        "host.updateCheck" | "host.updateApply" | "host.liveWork" => true,
        m if m.starts_with("pulls.") => true,
        m if m.starts_with("pty.") => true,
        m if m.starts_with("workflow.") => true,
        m if m.starts_with("automation.") => true,
        m if m.starts_with("chat.") => true,

        "app.watching" => true,
        "work.overview"
        | "work.search"
        | "work.continuity.get"
        | "work.continuity.put"
        | "work.continuity.attachments" => true,
        m if m.starts_with("todo.") => true,
        m if m.starts_with("launcher.") => true,
        "profiles.list" => true,
        m if m.starts_with("harness.") => true,
        m if m.starts_with("proxy.") => true,

        "stream.open" => matches!(stream_kind, Some("pty.subscribe" | "proxy")),
        _ => false,
    }
}

/// A refusal envelope when this peer may not do what it asked, or `None`.
///
/// The shape `host_policy::refuse_inbound` uses, so the serve path has one
/// kind of "no" rather than two.
pub(crate) fn refuse_unpermitted(line: &str, peer: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    let method = value.get("method").and_then(Value::as_str)?;
    let kind = value
        .get("params")
        .and_then(|params| params.get("kind"))
        .and_then(Value::as_str);
    if !needs_access(method, kind) || is_allowed(peer) {
        return None;
    }
    let id = value.get("id").cloned().unwrap_or(Value::Null);
    Some(
        json!({
            "id": id,
            "ok": false,
            "error": {
                "code": "workspace_not_allowed",
                "message": "This computer has not let this device open its work yet.",
            }
        })
        .to_string(),
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetParams {
    peer_id: String,
    allow: bool,
    #[serde(default)]
    via: Option<String>,
}

#[derive(Deserialize)]
struct RedeemParams {
    code: String,
}

#[derive(Default, Deserialize)]
struct LogParams {
    #[serde(default)]
    limit: Option<usize>,
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("workspace.access.") {
        return None;
    }

    match method {
        "workspace.access.check" => {
            let peer = match crate::request_context::remote_peer() {
                Some(peer) => peer,
                None => return Some(Err("only a device can ask whether it is allowed".into())),
            };
            return Some(Ok(json!({"allowed": is_allowed(&peer)})));
        }
        "workspace.access.pending" => {
            return Some((|| {
                crate::request_context::refuse_remote("workspace access requests")?;
                serde_json::to_value(load()?.pending).map_err(|e| e.to_string())
            })());
        }
        "workspace.access.list" => {
            return Some((|| {
                crate::request_context::refuse_remote("workspace access settings")?;
                serde_json::to_value(load()?.allowed).map_err(|e| e.to_string())
            })());
        }

        "workspace.access.log" => {
            return Some((|| {
                crate::request_context::refuse_remote("the workspace access log")?;
                let p: LogParams = serde_json::from_str(params).unwrap_or_default();
                Ok(Value::Array(access_audit::read(
                    p.limit.unwrap_or(100).min(1000),
                )?))
            })());
        }
        _ => {}
    }
    Some((|| match method {
        "workspace.access.ask" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("a request must arrive from the device asking")?;

            let label = crate::remote::account_peer_label_hex(&peer);
            let review_demo = crate::screen_policy::signed_into_review_demo();
            let _guard = mutation_lock()?;

            let mut store = load()?;
            if store.allowed.iter().any(|held| held == &peer) {
                return Ok(json!({"pending": false, "granted": true}));
            }

            if store.pending.iter().any(|request| request.peer_id == peer) {
                if review_demo {
                    drop(store);
                    set_allowed_locked_with_label(&peer, true, Authority::Console, label)?;
                    return Ok(json!({"pending": false, "granted": true, "reviewDemo": true}));
                }
                return Ok(json!({"pending": true}));
            }
            let asked_at = now_secs();

            if store.recent(&peer, "ask") >= MAX_ASKS_PER_HOUR {
                return Err(
                    "This device has asked several times already. Wait an hour, or let it in from the machine."
                        .into(),
                );
            }
            store.pending.retain(|request| request.peer_id != peer);
            if store.pending.len() >= MAX_PENDING {
                return Err(
                    "This machine is already holding as many requests as it will keep. Answer some of them first."
                        .into(),
                );
            }
            store.note(&peer, "ask", asked_at);
            store.pending.push(PendingRequest {
                label: label.clone(),
                peer_id: peer.clone(),

                control: false,
                asked_at,
                expires_at: asked_at + PENDING_TTL,
            });
            save(&store)?;
            drop(_guard);
            access_audit::record(
                "requested",
                Some(&peer),
                label.as_deref(),
                Authority::Console,
            );

            if review_demo {
                let _guard = mutation_lock()?;
                set_allowed_locked_with_label(&peer, true, Authority::Console, label)?;
                return Ok(json!({"pending": false, "granted": true, "reviewDemo": true}));
            }
            Ok(json!({"pending": true}))
        }

        "workspace.access.set" => {
            crate::request_context::refuse_remote("workspace access settings")?;
            let p: SetParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let by = Authority::parse(p.via.as_deref())?;

            let label = crate::remote::account_peer_label_hex(&p.peer_id);
            let _guard = mutation_lock()?;
            set_allowed_locked_with_label(&p.peer_id, p.allow, by, label)?;
            Ok(json!({"saved": true}))
        }

        "workspace.access.invite" => {
            crate::request_context::refuse_remote("workspace access invites")?;
            let code = mint_code()?;
            let _guard = mutation_lock()?;
            let mut store = load()?;
            let replaced = store.invite.is_some();
            let expires_at = now_secs() + PENDING_TTL;
            store.invite = Some(Invite {
                hash: hash_code(&code.replace('-', "")),
                expires_at,
                tries: 0,
            });
            save(&store)?;
            drop(_guard);
            if replaced {
                access_audit::record("invite retired", None, None, Authority::Console);
            }
            access_audit::record("invite minted", None, None, Authority::Console);
            Ok(json!({"code": code, "expiresAt": expires_at, "expiresIn": PENDING_TTL}))
        }

        "workspace.access.redeem" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("a code is redeemed by the device being let in")?;
            let p: RedeemParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let code = normalize_code(&p.code);

            let label = crate::remote::account_peer_label_hex(&peer);
            let now = now_secs();
            let _guard = mutation_lock()?;
            let mut store = load()?;
            if store.recent(&peer, "redeem") >= MAX_REDEEMS_PER_HOUR {
                return Err(
                    "Too many codes have been tried from this device. Wait an hour.".into(),
                );
            }
            store.note(&peer, "redeem", now);
            let code = match code {
                Ok(code) => code,
                Err(message) => {
                    save(&store)?;
                    return Err(message);
                }
            };
            if label.is_none() {
                save(&store)?;
                drop(_guard);
                access_audit::record("refused", Some(&peer), None, Authority::Invite);
                return Err(
                    "This device is not on the account this machine belongs to. Sign in with the same account first."
                        .into(),
                );
            }
            let Some(invite) = store.invite.as_mut() else {
                save(&store)?;

                return Err(
                    "There is no code waiting on this machine. Run `tokenstat host access invite` on it for a new one."
                        .into(),
                );
            };
            if !same_hash(&invite.hash, &hash_code(&code)) {
                invite.tries = invite.tries.saturating_add(1);
                let retired = invite.tries >= MAX_INVITE_ATTEMPTS;
                if retired {
                    store.invite = None;
                }
                save(&store)?;
                let label_clone = label.clone();
                drop(_guard);
                access_audit::record(
                    "refused",
                    Some(&peer),
                    label_clone.as_deref(),
                    Authority::Invite,
                );
                if retired {
                    access_audit::record("invite retired", None, None, Authority::Invite);
                    return Err(
                        "That code is not right, and it has now been retired. Mint a new one on the machine."
                            .into(),
                    );
                }
                return Err("That code is not right. Check it and try again.".into());
            }

            store.invite = None;
            let already = store.allowed.contains(&peer);
            if !already {
                store.allowed.push(peer.clone());
            }
            store.pending.retain(|request| request.peer_id != peer);

            save(&store)?;
            if !already {
                access_audit::record("granted", Some(&peer), label.as_deref(), Authority::Invite);
            }
            let label_clone = label.clone();
            drop(_guard);
            access_audit::record(
                "invite redeemed",
                Some(&peer),
                label_clone.as_deref(),
                Authority::Invite,
            );
            Ok(json!({"granted": true}))
        }
        _ => Err(format!("unknown workspace access method: {method}")),
    })())
}

#[cfg(test)]
mod tests {
    #[test]
    fn independent_processes_preserve_grants_and_audit_records() {
        let root = tempfile::tempdir().unwrap();

        let log = root.path().join("workspace-access.log");
        let history = (0..4000)
            .map(|n| format!("{{\"event\":\"old-{n}\"}}\n"))
            .collect::<String>();
        std::fs::write(&log, history).unwrap();
        let mut children: Vec<_> = (0..4)
            .map(|worker| {
                std::process::Command::new(std::env::current_exe().unwrap())
                    .args([
                        "--exact",
                        "workspace_policy::tests::identity_writer_child",
                        "--ignored",
                    ])
                    .env("TOKENSTAT_IDENTITY_DIR", root.path())
                    .env("TOKENSTAT_TEST_IDENTITY_WRITER", worker.to_string())
                    .stdout(std::process::Stdio::null())
                    .spawn()
                    .unwrap()
            })
            .collect();
        for child in &mut children {
            assert!(child.wait().unwrap().success());
        }
        let policy: serde_json::Value = serde_json::from_slice(
            &std::fs::read(root.path().join("workspace-policy.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(policy["allowed"].as_array().unwrap().len(), 80);
        let log = std::fs::read_to_string(log).unwrap();
        let records: Vec<serde_json::Value> = log
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        for n in 1..=80 {
            let peer = format!("{n:064x}");
            assert!(
                policy["allowed"]
                    .as_array()
                    .unwrap()
                    .contains(&serde_json::json!(peer))
            );
            assert_eq!(
                records
                    .iter()
                    .filter(|record| record["event"] == "granted" && record["device"] == peer)
                    .count(),
                1
            );
        }
        assert_eq!(
            records
                .iter()
                .filter(|record| record["event"] == "requested")
                .count(),
            80
        );
        assert!(records.len() <= 4000);
    }

    #[test]
    #[ignore = "private identity writer launched by the parent regression"]
    fn identity_writer_child() {
        let worker: usize = std::env::var("TOKENSTAT_TEST_IDENTITY_WRITER")
            .unwrap()
            .parse()
            .unwrap();
        for index in 1..=20 {
            let peer = format!("{:064x}", worker * 20 + index);
            super::set_allowed_by_with_label(
                &peer,
                true,
                crate::access_audit::Authority::Console,
                Some("Test device".into()),
            )
            .unwrap();
            crate::access_audit::record(
                "requested",
                Some(&peer),
                None,
                crate::access_audit::Authority::Console,
            );
        }
    }

    #[cfg(feature = "local-host")]
    #[test]
    fn handoff_obeys_authenticated_author_and_revoked_access() {
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "workspace_policy::tests::handoff_authenticated_context_child",
                "--ignored",
            ])
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }

    #[cfg(feature = "local-host")]
    #[test]
    #[ignore = "runs in an isolated process through the parent test"]
    fn handoff_authenticated_context_child() {
        let root = tempfile::tempdir().unwrap();
        tokenstat_paths::configure_mobile(root.path().join("data"), root.path().join("cache"))
            .unwrap();
        unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", root.path().join("identity")) };
        fn local(method: &str, params: serde_json::Value) -> serde_json::Value {
            serde_json::from_str(
                &crate::dispatch::call_sessionless(method, &params.to_string()).unwrap(),
            )
            .unwrap()
        }
        fn remote(peer: &str, method: &str, params: serde_json::Value) -> serde_json::Value {
            crate::request_context::with_remote_peer(peer, || local(method, params))
        }
        let folder = root.path().join("project");
        std::fs::create_dir(&folder).unwrap();
        let workspace = local("workspace.add", serde_json::json!({"path": folder}));
        assert_eq!(workspace["ok"], true);
        let workspace_id = workspace["result"]["id"].as_str().unwrap();
        let chat = local(
            "chat.create",
            serde_json::json!({"workspaceId": workspace_id, "backend": "codex", "personaId": ""}),
        );
        assert_eq!(chat["ok"], true);
        let reference = serde_json::json!({"workspaceId": workspace_id, "conversationId": chat["result"]["id"]});
        let phone = "01".repeat(32);
        let tablet = "02".repeat(32);
        let mut request = reference.clone();
        request["handoff"] = serde_json::json!({"requestId": "share-phone", "expectedRevision": 0, "deviceName": "Phone", "draft": {"text": "Phone draft", "attachmentIds": []}});
        assert_eq!(
            remote(&phone, "work.continuity.get", reference.clone())["ok"],
            false
        );
        assert_eq!(
            remote(&phone, "work.continuity.put", request.clone())["ok"],
            false
        );

        super::save(&super::Store {
            allowed: vec![phone.clone(), tablet.clone()],
            ..Default::default()
        })
        .unwrap();
        super::invalidate_allowed_cache();
        let saved = remote(&phone, "work.continuity.put", request.clone());
        assert_eq!(saved["ok"], true, "{saved}");
        assert_eq!(saved["result"]["handoff"]["deviceId"], phone);
        let read = remote(&tablet, "work.continuity.get", reference.clone());
        assert_eq!(read["result"]["handoff"], saved["result"]["handoff"]);
        request["handoff"]["requestId"] = serde_json::json!("share-tablet");
        request["handoff"]["draft"]["text"] = serde_json::json!("Tablet draft");
        let conflict = remote(&tablet, "work.continuity.put", request.clone());
        assert_eq!(conflict["result"]["status"], "conflict");
        assert_eq!(conflict["result"]["current"], saved["result"]["handoff"]);
        super::save(&super::Store {
            allowed: vec![phone.clone()],
            ..Default::default()
        })
        .unwrap();
        super::invalidate_allowed_cache();
        request["handoff"]["expectedRevision"] = serde_json::json!(1);
        assert_eq!(remote(&tablet, "work.continuity.put", request)["ok"], false);
        assert_eq!(
            remote(&tablet, "work.continuity.get", reference.clone())["ok"],
            false
        );
        let mut metadata = reference.clone();
        metadata["attachmentIds"] = serde_json::json!([]);
        assert_eq!(
            remote(&tablet, "work.continuity.attachments", metadata)["ok"],
            false
        );
        assert_eq!(
            remote(&phone, "work.continuity.get", reference)["result"]["handoff"],
            saved["result"]["handoff"]
        );
    }

    use super::*;

    fn peer_key(byte: &str) -> String {
        byte.repeat(32)
    }

    fn invite_code() -> String {
        call("workspace.access.invite", "{}")
            .unwrap()
            .expect("the console may always mint a code")["code"]
            .as_str()
            .expect("a code")
            .to_owned()
    }

    fn account_holds(peer: &str, label: &str) {
        crate::remote::seed_account_directory(vec![
            json!({"public_identity": peer, "label": label}),
        ]);
    }

    fn redeem(peer: &str, code: &str) -> Result<Value, String> {
        crate::request_context::with_remote_peer(peer, || {
            call(
                "workspace.access.redeem",
                &serde_json::to_string(&json!({"code": code})).unwrap(),
            )
            .unwrap()
        })
    }

    #[test]
    fn concurrent_redemptions_consume_an_invite_once() {
        crate::test_identity::isolated(|| {
            let peer = peer_key("aa");
            account_holds(&peer, "phone");
            let code = invite_code();
            let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
            let attempts: Vec<_> = (0..2)
                .map(|_| {
                    let peer = peer.clone();
                    let code = code.clone();
                    let barrier = barrier.clone();
                    std::thread::spawn(move || {
                        barrier.wait();
                        redeem(&peer, &code).is_ok()
                    })
                })
                .collect();
            let successes = attempts
                .into_iter()
                .map(|task| usize::from(task.join().unwrap()))
                .sum::<usize>();
            assert_eq!(successes, 1);
            assert!(is_allowed(&peer));
        });
    }

    #[test]
    fn unreadable_policy_types_fail_closed_and_extreme_attempt_dates_do_not_wrap() {
        crate::test_identity::isolated(|| {
            save(&Store {
                attempts: vec![Attempt {
                    peer_id: "peer".into(),
                    kind: "ask".into(),
                    at: u64::MAX,
                }],
                ..Default::default()
            })
            .unwrap();
            assert_eq!(load().unwrap().attempts.len(), 1);
            fs::remove_file(path().unwrap()).unwrap();
            fs::create_dir(path().unwrap()).unwrap();
            assert!(load().is_err());
            assert!(!is_allowed("peer"));
        });
    }

    #[test]
    fn a_code_reads_the_way_it_was_typed() {
        let code = mint_code().unwrap();
        assert_eq!(code.len(), 9, "{code}");
        assert_eq!(&code[4..5], "-");
        let plain = code.replace('-', "");
        assert_eq!(normalize_code(&code).unwrap(), plain);

        assert_eq!(
            normalize_code("io1l 23-45").unwrap(),
            normalize_code("101123 45").unwrap()
        );
        assert_eq!(normalize_code("uvwx-yz23").unwrap(), "VVWXYZ23");
        for bad in ["", "WXYZ-123", "WXYZ-12345", "WXYZ-12!4"] {
            assert!(normalize_code(bad).is_err(), "{bad} was accepted");
        }
        assert!(same_hash(&hash_code("ABCD2345"), &hash_code("ABCD2345")));
        assert!(!same_hash(&hash_code("ABCD2345"), &hash_code("ABCD2346")));
        assert!(!same_hash("short", &hash_code("ABCD2345")));
    }

    #[test]
    fn only_the_console_mints_and_only_a_device_redeems() {
        crate::test_identity::isolated(|| {
            let refused = crate::request_context::with_remote_peer(&peer_key("aa"), || {
                call("workspace.access.invite", "{}").unwrap().unwrap_err()
            });
            assert!(refused.contains("local-only"), "{refused}");
            let refused = call("workspace.access.redeem", r#"{"code":"ABCD2345"}"#)
                .unwrap()
                .unwrap_err();
            assert!(refused.contains("device being let in"), "{refused}");
            let refused = crate::request_context::with_remote_peer(&peer_key("aa"), || {
                call("workspace.access.log", "{}").unwrap().unwrap_err()
            });
            assert!(refused.contains("local-only"), "{refused}");
        });
    }

    #[test]
    fn a_code_lets_a_device_you_own_in_and_never_a_stranger() {
        crate::test_identity::isolated(|| {
            let mine = peer_key("ab");
            let stranger = peer_key("cd");
            account_holds(&mine, "iPhone");
            let code = invite_code();

            let refused = redeem(&stranger, &code).unwrap_err();
            assert!(refused.contains("not on the account"), "{refused}");
            assert!(load().unwrap().invite.is_some(), "the code must survive");

            account_holds(&mine, "iPhone");
            assert_eq!(redeem(&mine, &code).unwrap(), json!({"granted": true}));
            let store = load().unwrap();
            assert!(store.allowed.contains(&mine));
            assert!(store.invite.is_none(), "a code is consumed on first use");

            account_holds(&mine, "iPhone");
            let refused = redeem(&mine, &code).unwrap_err();
            assert!(refused.contains("no code waiting"), "{refused}");
        });
    }

    #[test]
    fn five_wrong_guesses_retire_the_code() {
        crate::test_identity::isolated(|| {
            let mine = peer_key("ef");
            account_holds(&mine, "iPad");
            let code = invite_code();
            let wrong = if code.starts_with('2') {
                "3333-3333"
            } else {
                "2222-2222"
            };
            for attempt in 1..MAX_INVITE_ATTEMPTS {
                account_holds(&mine, "iPad");
                let refused = redeem(&mine, wrong).unwrap_err();
                assert!(
                    refused.contains("not right"),
                    "attempt {attempt}: {refused}"
                );
                assert!(
                    refused.contains("try again"),
                    "attempt {attempt}: {refused}"
                );
            }
            account_holds(&mine, "iPad");
            let refused = redeem(&mine, wrong).unwrap_err();
            assert!(refused.contains("retired"), "{refused}");
            assert!(load().unwrap().invite.is_none());
            assert!(
                redeem(&mine, &code)
                    .unwrap_err()
                    .contains("no code waiting")
            );
            assert!(!load().unwrap().allowed.contains(&mine));
        });
    }

    #[test]
    fn minting_a_second_code_retires_the_first() {
        crate::test_identity::isolated(|| {
            let mine = peer_key("12");
            account_holds(&mine, "Mac");
            let first = invite_code();
            let second = invite_code();
            assert_ne!(first, second);
            account_holds(&mine, "Mac");
            assert!(redeem(&mine, &first).unwrap_err().contains("not right"));
            account_holds(&mine, "Mac");
            assert!(redeem(&mine, &second).is_ok());
        });
    }

    #[test]
    fn a_device_cannot_grind_codes_or_fill_the_queue() {
        crate::test_identity::isolated(|| {
            let mine = peer_key("34");
            account_holds(&mine, "Phone");

            for _ in 0..MAX_REDEEMS_PER_HOUR {
                let _ = invite_code();
                account_holds(&mine, "Phone");
                let _ = redeem(&mine, "2222-2222");
            }
            account_holds(&mine, "Phone");
            let refused = redeem(&mine, "2222-2222").unwrap_err();
            assert!(refused.contains("Too many codes"), "{refused}");

            let asker = peer_key("56");
            account_holds(&asker, "Phone");
            for _ in 0..MAX_ASKS_PER_HOUR {
                assert!(
                    crate::request_context::with_remote_peer(&asker, || call(
                        "workspace.access.ask",
                        "{}"
                    )
                    .unwrap())
                    .is_ok()
                );

                let mut store = load().unwrap();
                store.pending.clear();
                save(&store).unwrap();
            }
            let refused = crate::request_context::with_remote_peer(&asker, || {
                call("workspace.access.ask", "{}").unwrap().unwrap_err()
            });
            assert!(refused.contains("asked several times"), "{refused}");
        });
    }

    #[test]
    fn repeated_ask_keeps_the_pending_request_and_hourly_budget() {
        crate::test_identity::isolated(|| {
            let peer = peer_key("57");
            account_holds(&peer, "Phone");
            let ask = || {
                crate::request_context::with_remote_peer(&peer, || {
                    call("workspace.access.ask", "{}").unwrap().unwrap()
                })
            };
            assert_eq!(ask()["pending"], true);
            let first = load().unwrap();
            assert_eq!(first.pending.len(), 1);
            assert_eq!(first.recent(&peer, "ask"), 1);
            for _ in 0..MAX_ASKS_PER_HOUR + 1 {
                assert_eq!(ask()["pending"], true);
            }
            let after = load().unwrap();
            assert_eq!(after.pending.len(), 1);
            assert_eq!(after.pending[0].asked_at, first.pending[0].asked_at);
            assert_eq!(after.recent(&peer, "ask"), 1);
        });
    }

    #[test]
    fn the_log_records_who_did_it_and_nothing_else() {
        crate::test_identity::isolated(|| {
            let mine = peer_key("78");
            account_holds(&mine, "iPhone");
            let code = invite_code();
            redeem(&mine, &code).unwrap();
            set_allowed_by_with_label(&mine, false, Authority::Console, None).unwrap();
            let entries = call("workspace.access.log", "{}").unwrap().unwrap();
            let events: Vec<&str> = entries
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|entry| entry["event"].as_str())
                .collect();
            assert_eq!(events.first(), Some(&"revoked"));
            assert!(events.contains(&"granted"));
            assert!(events.contains(&"invite redeemed"));
            assert!(events.contains(&"invite minted"));
            let granted = entries
                .as_array()
                .unwrap()
                .iter()
                .find(|entry| entry["event"] == "granted")
                .unwrap();
            assert_eq!(granted["by"], "invite");
            assert_eq!(granted["device"], mine);
            assert_eq!(granted["label"], "iPhone");
        });
    }

    #[test]
    fn everything_that_touches_the_work_is_gated() {
        for method in [
            "workspace.read",
            "workspace.write",
            "workspace.push",
            "workspace.commitReview",
            "workspace.commitReviewDiff",
            "workspace.commitSelected",
            "workspace.commitReceipt",
            "workspace.commitRecover",
            "workspace.pushReview",
            "workspace.pushReviewed",
            "workspace.pushReceipt",
            "workspace.pushRecover",
            "workspace.pullReview",
            "workspace.pullReviewed",
            "workspace.lfsSetup",
            "pulls.branch",
            "pulls.listPage",
            "pty.spawn",
            "pty.write",
            "workflow.run",
            "automation.run",
            "automation.edit",
            "automation.createOnce",
            "automation.creationReceipt",
            "automation.runOnce",
            "automation.runReceipt",
            "todo.create",
            "todo.createOnce",
            "todo.creationReceipt",
            "todo.edit",
            "todo.delete",
            "todo.get",
            "todo.runTask",
            "todo.runReceipt",
            "todo.stopTask",
            "launcher.install",
            "launcher.reinstall",
            "harness.config.set",
            "proxy.listen",
            "app.watching",
            "fs.browse",
            "fs.mkdir",
            "host.provisionStatus",
            "host.logs",
            "host.updateCheck",
            "host.updateApply",
            "host.liveWork",
            "work.overview",
            "work.search",
            "work.continuity.get",
            "work.continuity.put",
            "work.continuity.attachments",
        ] {
            assert!(needs_access(method, None), "{method} must be gated");
        }
        assert!(needs_access("stream.open", Some("pty.subscribe")));
        assert!(needs_access("stream.open", Some("proxy")));
    }

    #[test]
    fn reporting_and_the_screen_are_not_gated_by_this() {
        for method in [
            "activity.calendar",
            "activity.day",
            "report.split",
            "usage.limits",
            "blocks.active",
            "host.stats",
            "host.policy",
            "info",
            "highlight.syntax",
            "screen.capability.issue",
        ] {
            assert!(!needs_access(method, None), "{method} must stay open");
        }

        assert!(!needs_access("stream.open", Some("screen.video")));
    }

    #[test]
    fn a_device_that_is_not_allowed_can_still_ask() {
        assert!(!needs_access("workspace.access.ask", None));
        assert!(!needs_access("workspace.access.check", None));
    }

    #[test]
    fn only_the_asking_device_may_ask_and_only_the_host_may_answer() {
        let refused = call("workspace.access.ask", "{}")
            .unwrap()
            .expect_err("a local caller has no device to ask for");
        assert!(refused.contains("device asking"), "{refused}");

        crate::request_context::with_remote_peer("phone", || {
            for method in [
                "workspace.access.pending",
                "workspace.access.list",
                "workspace.access.set",
            ] {
                let refused = call(method, r#"{"peerId":"phone","allow":true}"#)
                    .unwrap()
                    .expect_err("a device must not answer its own request");
                assert!(refused.contains("local-only"), "{refused}");
            }
        });
    }

    #[test]
    fn an_ordinary_account_never_reaches_the_automatic_grant() {
        assert!(!crate::screen_policy::signed_into_review_demo());
    }

    #[test]
    fn a_refusal_names_the_request_it_is_answering() {
        let line = r#"{"id":7,"method":"pty.spawn","params":{}}"#;
        let refusal = refuse_unpermitted(line, "phone").expect("must refuse");
        let value: Value = serde_json::from_str(&refusal).unwrap();
        assert_eq!(value["id"], 7);
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "workspace_not_allowed");

        assert!(refuse_unpermitted(r#"{"id":8,"method":"info"}"#, "phone").is_none());
    }
}
