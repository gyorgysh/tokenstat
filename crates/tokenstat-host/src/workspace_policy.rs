// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Which devices may reach the work on this machine.
//!
//! Being approved is not the same as being let in. Any device on the account
//! is auto-approved on first contact with the tunnel: `remote::serve_peer`
//! hands `authorize_with` an `auto_approve` hook that says yes to anything the
//! account directory knows. That was fine while a peer could only read
//! aggregate numbers. It is not fine now, because an approved peer can read
//! and write every file in a registered folder, commit and push it, spawn a
//! shell with `pty.spawn`, run every automation and workflow, and open a
//! socket to this machine's own loopback.
//!
//! So there is a second, explicit grant, and nothing is grandfathered into it.
//! Typing a pairing code is a person saying yes to one device by name, and
//! that still grants this. Appearing on the account does not.
//!
//! Deliberately the same shape as `screen_policy`: a per-device grant, a
//! request that arrives over the tunnel carrying the peer from the transport,
//! and an answer given by whoever is at the machine. The two share the request
//! record, its staleness window and its pruning, so one person answering two
//! kinds of question answers them the same way.

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::access_audit::{self, Authority};
use crate::screen_policy::{PENDING_TTL, PendingRequest, now_secs, prune_pending};

/// Pending requests this machine will hold at once.
///
/// A compromised account device can call `workspace.access.ask` on every host
/// the account owns. Without a cap that is a way to fill somebody's disk and
/// their notification list from a device that has no grant at all.
const MAX_PENDING: usize = 32;
/// Asks one device may make in an hour before it is told to wait.
const MAX_ASKS_PER_HOUR: u32 = 5;
/// Codes one device may try in an hour, whatever it does to a single code.
const MAX_REDEEMS_PER_HOUR: u32 = 10;
/// Wrong guesses that retire the live code.
///
/// Eight characters from a 32-symbol alphabet is 40 bits, which is plenty
/// against five guesses and nothing at all against a million. The lockout is
/// what carries the security here, not the length.
const MAX_INVITE_ATTEMPTS: u32 = 5;
const HOUR: u64 = 60 * 60;

#[derive(Default, Deserialize, Serialize)]
struct Store {
    /// Peer keys, as hex, that may reach the work here.
    #[serde(default)]
    allowed: Vec<String>,
    #[serde(default)]
    pending: Vec<PendingRequest>,
    /// The one live invite, or none. Minting a second retires the first, so a
    /// code left on a screen an hour ago cannot be the one that works.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    invite: Option<Invite>,
    /// Recent asks and redemption attempts, per device, for the rate limits.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    attempts: Vec<Attempt>,
}

#[derive(Deserialize, Serialize)]
struct Invite {
    /// SHA-256 of the code, hex. The code itself is shown once, at the console
    /// that minted it, and is never written down anywhere.
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
    let mut store: Store = match fs::read(path()?) {
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
    store.attempts.retain(|attempt| attempt.at + HOUR > now);
    Ok(store)
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

/// Crockford's alphabet: no I, L, O or U, so nothing in a code can be misread
/// as something else when it is copied off one screen and typed into another.
const CODE_ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

fn mint_code() -> Result<String, String> {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
    // 32 divides 256, so the mask is uniform and there is nothing to reject.
    let code: String = bytes
        .iter()
        .map(|byte| CODE_ALPHABET[(byte & 0x1f) as usize] as char)
        .collect();
    Ok(format!("{}-{}", &code[..4], &code[4..]))
}

/// Accept the code as a person would type it, and no more than that.
fn normalize_code(value: &str) -> Result<String, String> {
    let code: String = value
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| match c.to_ascii_uppercase() {
            // The four letters the alphabet leaves out, folded back onto the
            // symbols they are mistaken for.
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

/// Equal without telling a caller how far it got.
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
    fs::create_dir_all(path.parent().ok_or("invalid policy path")?).map_err(|e| e.to_string())?;
    let temp = path.with_extension("tmp");
    // The invite hash is a password-equivalent oracle (40 bits). The file must
    // never be world-readable, even briefly: create with 0600 before writing.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        use std::io::Write;
        file.write_all(&serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    }
    #[cfg(not(unix))]
    {
        fs::write(
            &temp,
            serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o600));
    }
    fs::rename(&temp, &path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
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
pub(crate) fn is_allowed(peer_id: &str) -> bool {
    allowed_now().is_some_and(|allowed| allowed.contains(peer_id))
}

type AllowedCached = Mutex<Option<(Option<SystemTime>, std::sync::Arc<HashSet<String>>)>>;

fn allowed_cache() -> &'static AllowedCached {
    static CACHE: OnceLock<AllowedCached> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// Drop the cached grant set, so a revocation in the same mtime tick is still
/// seen. `save` calls this on every write; mtime granularity alone cannot be
/// trusted on coarse filesystems.
fn invalidate_allowed_cache() {
    if let Ok(mut guard) = allowed_cache().lock() {
        *guard = None;
    }
}

fn allowed_now() -> Option<std::sync::Arc<HashSet<String>>> {
    let cache = allowed_cache();

    let path = path().ok()?;
    // A file that is not there yet has no grants in it, and a clock that will
    // not answer means re-reading, which is correct and merely slower.
    let stamp = fs::metadata(&path).and_then(|m| m.modified()).ok();
    if let Ok(guard) = cache.lock()
        && let Some((seen, allowed)) = guard.as_ref()
        && *seen == stamp
        && stamp.is_some()
    {
        return Some(std::sync::Arc::clone(allowed));
    }

    let allowed = std::sync::Arc::new(load().ok()?.allowed.into_iter().collect::<HashSet<_>>());
    if let Ok(mut guard) = cache.lock() {
        *guard = Some((stamp, std::sync::Arc::clone(&allowed)));
    }
    Some(allowed)
}

/// Let a device in, or shut it out.
///
/// Called by the toggle in Devices, by answering a request, and by approving a
/// device with a pairing code, which is the one place approval and this grant
/// are the same act.
pub(crate) fn set_allowed(peer_id: &str, allow: bool) -> Result<(), String> {
    set_allowed_by(peer_id, allow, Authority::Console)
}

static MUTATION: Mutex<()> = Mutex::new(());

pub(crate) fn set_allowed_by(peer_id: &str, allow: bool, by: Authority) -> Result<(), String> {
    // Label resolved outside the lock; the locked helper falls back to the
    // cache-only lookup if none was supplied.
    let label = crate::remote::account_peer_label_hex(peer_id);
    set_allowed_by_with_label(peer_id, allow, by, label)
}

fn set_allowed_by_with_label(
    peer_id: &str,
    allow: bool,
    by: Authority,
    label: Option<String>,
) -> Result<(), String> {
    let _guard = MUTATION
        .lock()
        .map_err(|_| "Workspace access lock is unavailable")?;
    set_allowed_locked_with_label(peer_id, allow, by, label)
}

/// Same as below, but with a label resolved outside the
/// mutation lock. Network I/O must never run while `MUTATION` is held.
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
    // Answered either way. A device told no does not keep standing in the
    // queue, and one told yes has nothing left to ask.
    store.pending.retain(|request| request.peer_id != peer_id);
    save(&store)?;
    if already != allow {
        // Best-effort label: fall back to the cache-only lookup if the caller
        // did not resolve one outside the lock.
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
    // A device that cannot get in still has to be able to ask.
    if method.starts_with("workspace.access.") {
        return false;
    }
    match method {
        m if m.starts_with("workspace.") => true,
        // Browsing a machine's directories and making a folder on it are the
        // work, exactly like opening a file in one.
        m if m.starts_with("fs.") => true,
        // What is set up here, and why it is unhappy. Both name this machine's
        // own folders and log lines, so both need the grant.
        "host.provisionStatus" | "host.logs" => true,
        m if m.starts_with("pulls.") => true,
        m if m.starts_with("pty.") => true,
        m if m.starts_with("workflow.") => true,
        m if m.starts_with("automation.") => true,
        m if m.starts_with("chat.") => true,
        m if m.starts_with("todo.") => true,
        m if m.starts_with("launcher.") => true,
        m if m.starts_with("harness.") => true,
        m if m.starts_with("proxy.") => true,
        // The screen has its own grant, and a screen stream must not need this
        // one as well: watching a desktop and opening its files are different
        // questions with different answers.
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
    /// Which door a local caller used, for the record. See `Authority`.
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
    // Read-only methods never take the mutation lock. Holding it across a
    // network fetch (account directory) stalled every other access call for
    // the HTTP timeout, and reads do not mutate.
    match method {
        // Asked before anything is loaded, so a device that is not allowed can
        // draw the screen that says so and offer to ask. The alternative was
        // reading it off a failure, and `remote.call` flattens a peer's error
        // to its message and drops the code, so that would have meant matching
        // on a sentence.
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
        // The record, for the console and for the machine's page in the app.
        // Local only: it names every device that was ever let in here.
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
        // Over the tunnel the device is already on, with the peer taken from
        // the connection rather than from the params. A device naming somebody
        // else would be a device asking on their behalf.
        "workspace.access.ask" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("a request must arrive from the device asking")?;
            // Resolve outside the mutation lock: this may fetch the account
            // directory over HTTP, and holding MUTATION across that stalls
            // every other access call for the timeout.
            let label = crate::remote::account_peer_label_hex(&peer);
            let review_demo = crate::screen_policy::signed_into_review_demo();
            let _guard = MUTATION
                .lock()
                .map_err(|_| "Workspace access lock is unavailable")?;
            // Nothing to read. Workspace access is one grant with no half to
            // ask for, and the peer comes from the connection, so a device has
            // nothing it could usefully say here.
            let mut store = load()?;
            if store.allowed.iter().any(|held| held == &peer) {
                return Ok(json!({"pending": false, "granted": true}));
            }
            let asked_at = now_secs();
            // A device that has already asked five times this hour is told to
            // wait. It keeps whatever request it has standing, so this costs
            // it nothing it had not already got.
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
                // Workspace access is one grant. There is no half of it to
                // ask for, so the field the screen request uses for mouse and
                // keyboard is always false here.
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

            // The same exception the screen carries, and for the same reason:
            // App Review signs into the website's demo account on a fresh
            // iPhone and presses Connect, and nobody at Apple has the Mac it
            // is asking. A request that can never be answered is a feature
            // that cannot be tested.
            //
            // Recorded first and upgraded after. The demo check above ran
            // outside the lock because it can hit the network; a device whose
            // ask was lost to a hung lookup has no way to know it should ask
            // again, so the request is stored before this branch.
            //
            // Four things have to hold and a user can set none of them: the
            // account is `REVIEW_DEMO_ACCOUNT_ID`, compiled in rather than
            // taken from the answer; the server says the round is open; the
            // device is already approved, which `serve_peer` checks before
            // dispatch is reached; and the grant is an ordinary row, listed
            // and revocable in Devices and gone the moment the round closes.
            if review_demo {
                let _guard = MUTATION
                    .lock()
                    .map_err(|_| "Workspace access lock is unavailable")?;
                set_allowed_locked_with_label(&peer, true, Authority::Console, label)?;
                return Ok(json!({"pending": false, "granted": true, "reviewDemo": true}));
            }
            Ok(json!({"pending": true}))
        }
        // Answering a request and moving the toggle in Devices are the same
        // act, so they are the same method.
        "workspace.access.set" => {
            crate::request_context::refuse_remote("workspace access settings")?;
            let p: SetParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let by = Authority::parse(p.via.as_deref())?;
            // Resolve outside the lock; the audit label is best-effort.
            let label = crate::remote::account_peer_label_hex(&p.peer_id);
            let _guard = MUTATION
                .lock()
                .map_err(|_| "Workspace access lock is unavailable")?;
            set_allowed_locked_with_label(&p.peer_id, p.allow, by, label)?;
            Ok(json!({"saved": true}))
        }

        // Mint the code that lets a device this machine has never seen in.
        //
        // Local only, because the code *is* the authority: whoever can run
        // this could read the folders with `cat` regardless. It never touches
        // tokenstat.ai, which is what keeps the server unable to let itself
        // in: only the hash is stored, and the redemption is checked here.
        "workspace.access.invite" => {
            crate::request_context::refuse_remote("workspace access invites")?;
            let code = mint_code()?;
            let _guard = MUTATION
                .lock()
                .map_err(|_| "Workspace access lock is unavailable")?;
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

        // The other end of that code, and the only method a device which is
        // not allowed can call to change anything. Everything protecting it is
        // here: it must arrive from a device, that device must already be on
        // the account, the code is single use, five wrong guesses retire it,
        // and a device may only try so many in an hour.
        "workspace.access.redeem" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("a code is redeemed by the device being let in")?;
            let p: RedeemParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let code = normalize_code(&p.code);
            // The code lets a device you own in. It does not let a stranger
            // in, so the redeeming device has to be one the account knows.
            // Resolved before the lock: this is the network fetch that must
            // never run while MUTATION is held.
            let label = crate::remote::account_peer_label_hex(&peer);
            let now = now_secs();
            let _guard = MUTATION
                .lock()
                .map_err(|_| "Workspace access lock is unavailable")?;
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
                // Expired and wrong have to read differently, or somebody
                // retypes a code that was right until a moment ago, forever.
                return Err(
                    "There is no code waiting on this machine. Run `tokenstat host access invite` on it for a new one."
                        .into(),
                );
            };
            if !same_hash(&invite.hash, &hash_code(&code)) {
                invite.tries += 1;
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
            // Consumed on the first success, whether or not this device was
            // already allowed, so a code cannot be used twice. Consuming under
            // the lock is what makes concurrent redemptions single-use; the
            // grant below takes the lock again and cannot double-consume.
            store.invite = None;
            save(&store)?;
            let label_clone = label.clone();
            drop(_guard);
            access_audit::record(
                "invite redeemed",
                Some(&peer),
                label_clone.as_deref(),
                Authority::Invite,
            );
            set_allowed_by_with_label(&peer, true, Authority::Invite, label)?;
            Ok(json!({"granted": true}))
        }
        _ => Err(format!("unknown workspace access method: {method}")),
    })())
}

#[cfg(test)]
mod tests {
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

    /// Seed the directory before every redemption that has to reach the code.
    ///
    /// A lookup that misses refetches once, and on a machine that is really
    /// signed in that fetch replaces the seeded directory with the real one.
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
    fn a_code_reads_the_way_it_was_typed() {
        let code = mint_code().unwrap();
        assert_eq!(code.len(), 9, "{code}");
        assert_eq!(&code[4..5], "-");
        let plain = code.replace('-', "");
        assert_eq!(normalize_code(&code).unwrap(), plain);
        // Lower case, spaces and the four letters the alphabet leaves out.
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

            // A device the account does not know never reaches the code, so it
            // cannot burn somebody else's attempts either.
            let refused = redeem(&stranger, &code).unwrap_err();
            assert!(refused.contains("not on the account"), "{refused}");
            assert!(load().unwrap().invite.is_some(), "the code must survive");

            account_holds(&mine, "iPhone");
            assert_eq!(redeem(&mine, &code).unwrap(), json!({"granted": true}));
            let store = load().unwrap();
            assert!(store.allowed.contains(&mine));
            assert!(store.invite.is_none(), "a code is consumed on first use");

            // Single use, and the copy on the screen is now worth nothing.
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
            // The right code is worth nothing once the code is retired.
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
            // Each mint gives it five more guesses, and the per-device ceiling
            // is what stops it walking through code after code.
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
            }
            let refused = crate::request_context::with_remote_peer(&asker, || {
                call("workspace.access.ask", "{}").unwrap().unwrap_err()
            });
            assert!(refused.contains("asked several times"), "{refused}");
        });
    }

    #[test]
    fn the_log_records_who_did_it_and_nothing_else() {
        crate::test_identity::isolated(|| {
            let mine = peer_key("78");
            account_holds(&mine, "iPhone");
            let code = invite_code();
            redeem(&mine, &code).unwrap();
            set_allowed_by(&mine, false, Authority::Console).unwrap();
            let entries = call("workspace.access.log", "{}").unwrap().unwrap();
            let events: Vec<&str> = entries
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|entry| entry["event"].as_str())
                .collect();
            // Newest first.
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
            "pty.spawn",
            "pty.write",
            "workflow.run",
            "automation.run",
            "todo.create",
            "launcher.install",
            "harness.config.set",
            "proxy.listen",
            "fs.browse",
            "fs.mkdir",
            "host.provisionStatus",
            "host.logs",
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
        // The screen carries its own grant. Needing both would mean somebody
        // who allowed a phone to watch this desktop had also, silently, to
        // allow it to open every file.
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
        // The exception is the website's demo account during an open review
        // round, and the test environment is signed into no account at all.
        // A lookup that cannot answer has to read as "not the demo account"
        // rather than as a yes: this is the one path that hands a device the
        // work on a machine without a person saying so.
        assert!(!crate::screen_policy::signed_into_review_demo());
    }

    #[test]
    fn a_refusal_names_the_request_it_is_answering() {
        // No grant exists in the test environment, so anything gated is
        // refused, and the envelope has to carry the id back or the caller
        // never matches the answer to its question.
        let line = r#"{"id":7,"method":"pty.spawn","params":{}}"#;
        let refusal = refuse_unpermitted(line, "phone").expect("must refuse");
        let value: Value = serde_json::from_str(&refusal).unwrap();
        assert_eq!(value["id"], 7);
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "workspace_not_allowed");
        // Ungated methods are answered, not refused.
        assert!(refuse_unpermitted(r#"{"id":8,"method":"info"}"#, "phone").is_none());
    }
}
