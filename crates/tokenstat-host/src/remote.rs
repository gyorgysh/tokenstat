// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Serving other machines, and reaching them.
//!
//! # Both directions live here
//!
//! Serving turns this daemon into something another machine can ask questions
//! of. Reaching turns it into the thing that asks. A front end only ever talks
//! to its own local daemon: to look at another machine it calls `remote.call`
//! here, and this forwards. That is why the Mac app needs no handshake code,
//! and why an iPad client will not either.
//!
//! # Serving is off until somebody turns it on
//!
//! Binding a port is not a default. A remote client can spawn processes and
//! write files, which is a larger permission than the commit button, so the
//! daemon listens only after the user says to, and serves only peers a person
//! approved. See `docs/remote-transport.md`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
#[cfg(feature = "local-host")]
use tokenstat_identity::Trust;
use tokenstat_identity::{MachineIdentity, PeerStore, public_key_from_hex};
use tokenstat_remote::{Refused, authorize_with};
use tokenstat_sync::profile::ProfileError;

use crate::session::Session;

/// A response is bounded so a peer cannot ask this end to allocate without
/// limit. 64 MB is far above any real answer (the largest is a file's text)
/// and far below anything that hurts.
const MAX_MESSAGE: usize = 64 * 1024 * 1024;

// MARK: - Settings

/// What the user chose about remote reach. Persisted, because a daemon under
/// launchd restarts and must come back the way they left it, not the way it
/// ships.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteSettings {
    /// Off by default: remote reach is the one switch, and it is a decision.
    #[serde(default)]
    pub tunnel: bool,
    #[serde(default = "default_tunnel_endpoint")]
    pub tunnel_endpoint: String,
}

fn default_tunnel_endpoint() -> String {
    "wss://tunnel.tokenstat.ai".into()
}

impl Default for RemoteSettings {
    fn default() -> Self {
        Self {
            tunnel: false,
            tunnel_endpoint: default_tunnel_endpoint(),
        }
    }
}

/// Beside the machine key rather than in the data directory generally.
///
/// Whether this machine serves is part of *which machine this is*, so it
/// follows `TOKENSTAT_IDENTITY_DIR` along with the key. Without that, two
/// daemons on one computer share one setting and the second one to start
/// silently contradicts the first.
fn settings_path() -> Result<std::path::PathBuf, String> {
    Ok(tokenstat_identity::identity_dir()
        .map_err(|e| e.to_string())?
        .join("remote.json"))
}

pub fn load_settings() -> RemoteSettings {
    // A settings file that will not parse must not stop the daemon starting,
    // and the safe reading of an unreadable file is "not serving".
    settings_path()
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save_settings(settings: &RemoteSettings) -> Result<(), String> {
    let path = settings_path()?;
    let text = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))
}

fn tunnel_running() -> &'static AtomicBool {
    static RUNNING: AtomicBool = AtomicBool::new(false);
    &RUNNING
}

/// The one multiplexed tunnel session the daemon keeps, if remote reach is on.
fn tunnel_session() -> &'static Mutex<Option<Arc<tokenstat_remote::tunnel::TunnelSession>>> {
    static SESSION: OnceLock<Mutex<Option<Arc<tokenstat_remote::tunnel::TunnelSession>>>> =
        OnceLock::new();
    SESSION.get_or_init(|| Mutex::new(None))
}

/// What the tunnel is doing right now, for the screen that reports it.
///
/// `remote.status` reports the user's *setting* and, separately, what is
/// actually true. The tunnel is the one place the two can differ for a while
/// (DENIED for the plan, a bad token, an endpoint that is down), and a screen
/// that showed only the toggle would invite somebody to press Connect against
/// a listener that is not there.
#[derive(Debug, Clone, Default)]
pub struct TunnelState {
    /// The daemon is holding a live socket on the tunnel right now.
    pub connected: bool,
    /// Why the last attempt failed, when it did.
    pub error: Option<String>,
    /// The account directory has this machine's key and name. Registration is
    /// what lets a same-account machine dial this one, so "on the tunnel but
    /// not in the directory" is a real state worth showing.
    pub registered: bool,
}

fn tunnel_state() -> &'static Mutex<TunnelState> {
    static STATE: OnceLock<Mutex<TunnelState>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(TunnelState::default()))
}

fn set_tunnel_state(update: impl FnOnce(&mut TunnelState)) {
    if let Ok(mut state) = tunnel_state().lock() {
        update(&mut state);
    }
}

/// The session a peer will be answered from.
///
/// On a Mac with `local-host`, only the host daemon registers one. The
/// in-process bridge deliberately does not, so `remote.serve` fails with words
/// rather than opening a tunnel owned by a window: a machine other machines
/// depend on must not stop serving because somebody quit an app.
///
/// On a phone (`local-host` off) there is no daemon. The process *is* the host
/// for the client role, so [`session_for_serving`] opens a client session when
/// none is registered yet. That is what lets Workspaces turn the tunnel on and
/// dial a Mac.
fn registered_session() -> &'static Mutex<Option<Arc<Mutex<Session>>>> {
    static SESSION: OnceLock<Mutex<Option<Arc<Mutex<Session>>>>> = OnceLock::new();
    SESSION.get_or_init(|| Mutex::new(None))
}

/// Called by the daemon once, before it serves anything.
pub fn register_session(session: Arc<Mutex<Session>>) {
    if let Ok(mut guard) = registered_session().lock() {
        *guard = Some(session);
    }
}

fn session_for_serving() -> Result<Arc<Mutex<Session>>, String> {
    if let Some(session) = registered_session()
        .lock()
        .map_err(|e| e.to_string())?
        .clone()
    {
        return Ok(session);
    }

    // Phone / iPad: no hostd, no unix socket. A client session is enough to
    // hold the tunnel for outbound dials; inbound is limited to what a client
    // build can answer, which is intentional.
    #[cfg(not(feature = "local-host"))]
    {
        let session = Arc::new(Mutex::new(Session::open_client(None)?));
        register_session(Arc::clone(&session));
        // Tail expression: on a client build the block below is compiled out
        // and this is the end of the function.
        Ok(session)
    }

    #[cfg(feature = "local-host")]
    {
        Err("serving other machines needs the tokenstat host daemon. \
             Install it with scripts/install-host-agent.sh."
            .to_string())
    }
}

/// Start serving, if the user turned it on. Called once at daemon start.
pub fn start_if_enabled(session: Arc<Mutex<Session>>) {
    register_session(Arc::clone(&session));
    let settings = load_settings();
    // Remote reach is one switch and one transport: the tunnel. Everything
    // between machines rides it, so there is nothing to bind or advertise.
    start_tunnel_if_enabled(session, &settings);
}

fn account_token() -> Result<String, String> {
    let host = tokenstat_sync::config::load()
        .ok()
        .and_then(|config| config.sync.host)
        .unwrap_or_else(|| "https://tokenstat.ai".into());
    tokenstat_sync::keychain::load_token(&host)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "sign in to tokenstat.ai before enabling remote reach".into())
}

/// The HELLO credential in hand, and when it stops being usable.
struct HeldCredential {
    token: String,
    /// Local deadline. `None` for the legacy login bearer, which does not expire.
    expires_at: Option<Instant>,
}

fn held_credential() -> &'static Mutex<Option<HeldCredential>> {
    static HELD: OnceLock<Mutex<Option<HeldCredential>>> = OnceLock::new();
    HELD.get_or_init(|| Mutex::new(None))
}

/// Mint again once a credential is inside this much of its expiry.
const CREDENTIAL_REFRESH_MARGIN: Duration = Duration::from_secs(600);

/// The HELLO credential, minting one only when there is a reason to.
///
/// `force` is for a credential the relay refused: mint whatever the cache says.
/// Otherwise a token still comfortably inside its term is reused. Every
/// `remote.tunnel` request used to mint, and a phone sends one each time it
/// opens a host or pulls to refresh, so the machine spent its hourly mint
/// budget replacing a credential that was working. It also handed the relay a
/// moving target: each new token superseded the one the live socket was about
/// to reconnect with.
fn tunnel_hello_token(force: bool) -> Result<(String, Option<u64>), String> {
    if !force {
        if let Ok(guard) = held_credential().lock() {
            if let Some(held) = guard.as_ref() {
                // The lifetime left, not None: the caller schedules the refresh
                // loop from what comes back, and a cache hit that said "no
                // expiry" would start a tunnel nothing ever refreshed.
                match held.expires_at {
                    None => return Ok((held.token.clone(), None)),
                    Some(at) => {
                        if let Some(left) = at.checked_duration_since(Instant::now()) {
                            if left > CREDENTIAL_REFRESH_MARGIN {
                                return Ok((held.token.clone(), Some(left.as_secs())));
                            }
                        }
                    }
                }
            }
        }
    }
    mint_hello_token()
}

/// Register the machine on the account directory, then mint a short-lived
/// tunnel:connect token for HELLO.
///
/// The long-lived login bearer is used only against an account host that has
/// no mint route at all. The relay refuses it otherwise, and falling back on a
/// plan or registration refusal would turn a message the user can act on
/// ("register this machine", "remote reach is a paid feature") into a generic
/// tunnel denial minutes later.
///
/// Registration is mandatory on the first mint of a process and best-effort
/// afterwards: a transient 5xx (or a captive-portal redirect) on the register
/// route must not turn a renewal the account can already serve into "tunnel
/// unavailable". The one refusal registration cannot fix is a mint answering
/// `machine_not_registered`, which drives a single re-register before the
/// second attempt.
fn mint_hello_token() -> Result<(String, Option<u64>), String> {
    let machine_id = tokenstat_sync::config::ensure_machine_id().map_err(|e| e.to_string())?;
    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let first = !REGISTERED_THIS_PROCESS.swap(true, Ordering::AcqRel);
    mint_hello_token_impl(
        &machine_id,
        &identity,
        first,
        |mid, ident, kind| {
            tokenstat_sync::profile::register_machine_identity_kind(
                None,
                mid,
                &ident.public_key_hex(),
                &tokenstat_identity::machine_label(),
                kind,
            )
            .map_err(|e| e.to_string())
        },
        |mid| tokenstat_sync::profile::mint_tunnel_token(None, mid),
    )
}

/// Has this process already tried to register the machine with the account?
///
/// Not "is it registered": the flag stays set even when the first attempt
/// failed, because the first attempt being mandatory is about not *skipping*
/// the call, and the mint + re-register path below repairs a machine the
/// account does not know.
static REGISTERED_THIS_PROCESS: AtomicBool = AtomicBool::new(false);

fn mint_hello_token_impl(
    machine_id: &str,
    identity: &MachineIdentity,
    first: bool,
    mut register: impl FnMut(&str, &MachineIdentity, &str) -> Result<(), String>,
    mut mint: impl FnMut(&str) -> Result<tokenstat_sync::profile::TunnelToken, ProfileError>,
) -> Result<(String, Option<u64>), String> {
    // Phones (no local-host) register as clients so they do not burn a host
    // machine slot. Macs remain hosts.
    #[cfg(feature = "local-host")]
    let kind = "host";
    #[cfg(not(feature = "local-host"))]
    let kind = "client";
    if first {
        register(machine_id, identity, kind)?;
        set_tunnel_state(|state| state.registered = true);
    }

    let mut minted = mint(machine_id);
    if matches!(minted, Err(ProfileError::MachineNotRegistered)) {
        // The account stopped knowing this machine (unlinked, re-registered
        // elsewhere). One registration retry is the whole fix: it re-publishes
        // the key the mint binds to. More than one is the same answer to the
        // same question.
        register(machine_id, identity, kind)?;
        set_tunnel_state(|state| state.registered = true);
        minted = mint(machine_id);
    }

    match minted {
        Ok(tok) => {
            hold_credential(&tok.token, Some(tok.expires_in));
            Ok((tok.token, Some(tok.expires_in)))
        }
        Err(ProfileError::Unsupported(reason)) => {
            // An account host from before tunnel tokens still accepts the sync
            // bearer on HELLO, if its relay has the legacy path open.
            eprintln!("remote: {reason}; falling back to the login bearer");
            let legacy = account_token()?;
            hold_credential(&legacy, None);
            Ok((legacy, None))
        }
        Err(error) => Err(format!("could not mint a tunnel credential: {error}")),
    }
}

fn hold_credential(token: &str, expires_in: Option<u64>) {
    if let Ok(mut guard) = held_credential().lock() {
        *guard = Some(HeldCredential {
            token: token.to_string(),
            expires_at: expires_in.map(|secs| Instant::now() + Duration::from_secs(secs)),
        });
    }
}

fn start_tunnel_if_enabled(session: Arc<Mutex<Session>>, settings: &RemoteSettings) {
    if !settings.tunnel {
        return;
    }
    // Already live: refresh HELLO and leave the supervisor alone.
    if tunnel_running().load(Ordering::Acquire) {
        if let Ok(guard) = tunnel_session().lock() {
            if guard.is_some() {
                // The held credential, minted again only when it is close to
                // expiry. The live socket is already registered, so this is
                // about what the next reconnect will carry.
                if let Ok((hello_token, _)) = tunnel_hello_token(false) {
                    if let Some(existing) = guard.as_ref() {
                        existing.set_token(&hello_token);
                    }
                }
                return;
            }
        }
        // Marked running but no session: fall through and rebuild.
        tunnel_running().store(false, Ordering::Release);
    }
    if tunnel_running()
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }
    let endpoint = settings.tunnel_endpoint.clone();
    // Confirm login before starting the supervisor. Mint happens below so the
    // HELLO secret is tunnel-scoped when the server supports it.
    if let Err(error) = account_token() {
        eprintln!("remote: tunnel is enabled but unavailable: {error}");
        set_tunnel_state(|state| {
            state.connected = false;
            state.error = Some(error);
        });
        tunnel_running().store(false, Ordering::Release);
        retry_start_later(Arc::clone(&session));
        return;
    }
    let identity = match MachineIdentity::load_or_create() {
        Ok(identity) => identity,
        Err(error) => {
            eprintln!("remote: tunnel identity unavailable: {error}");
            tunnel_running().store(false, Ordering::Release);
            return;
        }
    };
    let (hello_token, expires_in) = match tunnel_hello_token(false) {
        Ok(pair) => pair,
        Err(error) => {
            eprintln!("remote: tunnel is enabled but unavailable: {error}");
            // The panel shows `error`, so a refusal the user can act on has to
            // land there rather than only in the daemon's log.
            set_tunnel_state(|state| {
                state.registered = false;
                state.connected = false;
                state.error = Some(error);
            });
            tunnel_running().store(false, Ordering::Release);
            // A daemon that starts before the network is up, or while the
            // account host is having a minute, used to stay off until somebody
            // opened Machines and toggled the switch. Remote reach is meant to
            // be the state of the machine, not the state of the last attempt.
            retry_start_later(session);
            return;
        }
    };
    // One persistent, multiplexed socket for the daemon's lifetime. It is
    // created here and reused by every dial, and the supervisor inside it
    // reconnects with backoff when the relay drops.
    let tunnel = {
        let mut guard = match tunnel_session().lock() {
            Ok(guard) => guard,
            Err(e) => {
                eprintln!("remote: tunnel state unavailable: {e}");
                tunnel_running().store(false, Ordering::Release);
                return;
            }
        };
        match guard.as_ref() {
            Some(existing) => {
                // Already running: refresh the HELLO secret if we just minted.
                existing.set_token(&hello_token);
                existing.clone()
            }
            None => {
                let session = tokenstat_remote::tunnel::TunnelSession::spawn(
                    &endpoint,
                    &identity,
                    &hello_token,
                );
                // The repair for a refused credential, handed to the
                // supervisor so it can fix itself between two reconnects
                // instead of waiting for somebody to toggle a switch.
                // The relay refused what we hold, so this one must mint.
                session.set_renew(Box::new(|| match tunnel_hello_token(true) {
                    Ok((token, _)) => {
                        set_tunnel_state(|state| state.error = None);
                        Some(token)
                    }
                    Err(error) => {
                        set_tunnel_state(|state| state.error = Some(error));
                        None
                    }
                }));
                *guard = Some(session.clone());
                session
            }
        }
    };
    // Refresh the short-lived token at half-life so HELLO never races expiry.
    if let Some(ttl) = expires_in {
        let refresh_tunnel = Arc::clone(&tunnel);
        std::thread::spawn(move || tunnel_token_refresh_loop(refresh_tunnel, ttl));
    }
    std::thread::spawn(move || {
        // Inbound channels: the relay dialled us. Each is a fresh Noise
        // handshake over the channel, answered exactly like a direct TCP
        // connection, so the approval rule cannot tell the transports apart.
        let inbound = tunnel.take_inbound();
        while tunnel_running().load(Ordering::Acquire) {
            let state = match inbound.recv() {
                Ok(state) => state,
                Err(_) => break,
            };
            let transport = tokenstat_remote::tunnel::ChannelTransport::from_inbound(
                Arc::clone(&tunnel),
                state,
            );
            match tokenstat_remote::handshake_responder(Box::new(transport), &identity) {
                Ok(connection) => {
                    set_tunnel_state(|state| {
                        state.connected = true;
                        state.error = None;
                    });
                    match authorize_with(connection, "tunnel", Some(&account_peer_label)) {
                        Ok(connection) => {
                            let peer_session = Arc::clone(&session);
                            std::thread::spawn(move || serve_peer(connection, &peer_session));
                        }
                        Err(refused) => report(&refused),
                    }
                }
                Err(error) => eprintln!("remote: inbound tunnel handshake failed: {error}"),
            }
        }
        tunnel_running().store(false, Ordering::Release);
    });
}

/// Keep trying to bring remote reach up, in the background, until it is up or
/// the user turns it off.
///
/// One retry thread at a time. The delay doubles from ten seconds to one
/// minute: a laptop opening its lid, a network coming back, or an account host
/// that was briefly down all resolve inside that window without anybody
/// visiting a settings screen. The ceiling is a minute rather than five,
/// because what it bounds is how long a machine reads as offline after the
/// thing that was wrong stopped being wrong. One attempt a minute is nothing
/// to an account host, and five minutes of "offline" is a long time to somebody
/// looking at their own laptop.
fn retry_start_later(session: Arc<Mutex<Session>>) {
    static RETRYING: AtomicBool = AtomicBool::new(false);
    if RETRYING.swap(true, Ordering::AcqRel) {
        return;
    }
    std::thread::spawn(move || {
        let mut delay = Duration::from_secs(10);
        loop {
            std::thread::sleep(delay);
            let settings = load_settings();
            if !settings.tunnel {
                break;
            }
            if tunnel_running().load(Ordering::Acquire) {
                break;
            }
            start_tunnel_if_enabled(Arc::clone(&session), &settings);
            if tunnel_running().load(Ordering::Acquire) {
                break;
            }
            delay = (delay * 2).min(Duration::from_secs(60));
        }
        RETRYING.store(false, Ordering::Release);
    });
}

/// Doubling retry delay for a failed mint, one minute up to fifteen.
fn next_retry(previous: Option<u64>) -> u64 {
    match previous {
        None => 60,
        Some(secs) => (secs * 2).min(900),
    }
}

/// Re-mint the tunnel token before it expires and push it into the session.
fn tunnel_token_refresh_loop(
    tunnel: Arc<tokenstat_remote::tunnel::TunnelSession>,
    initial_ttl_secs: u64,
) {
    let mut ttl = initial_ttl_secs.max(300);
    // Set after a failed mint. Retrying at half-life again would put the next
    // attempt exactly at expiry, so a single hiccup would drop remote reach
    // until the daemon restarts. Back off from a minute to a quarter-hour.
    let mut retry_secs: Option<u64> = None;
    while tunnel_running().load(Ordering::Acquire) {
        // Refresh at half-life, never sooner than 2 minutes (local testing TTLs).
        let sleep_secs = retry_secs.unwrap_or((ttl / 2).max(120));
        let mut waited = 0u64;
        while waited < sleep_secs && tunnel_running().load(Ordering::Acquire) {
            std::thread::sleep(Duration::from_secs(1));
            waited += 1;
        }
        if !tunnel_running().load(Ordering::Acquire) {
            return;
        }
        // Through the same door every other caller uses, so the held
        // credential is the one the socket carries. A refresh that minted
        // behind the cache would leave the next `remote.tunnel` request
        // handing the relay a token this loop had already superseded.
        match tunnel_hello_token(true) {
            Ok((token, expires_in)) => {
                tunnel.set_token(&token);
                ttl = expires_in.unwrap_or(ttl).max(300);
                retry_secs = None;
                set_tunnel_state(|state| state.error = None);
            }
            Err(e) => {
                eprintln!("remote: tunnel token refresh failed: {e}");
                set_tunnel_state(|state| {
                    state.error = Some(format!("tunnel credential renewal failed: {e}"));
                });
                retry_secs = Some(next_retry(retry_secs));
            }
        }
    }
}

fn stop_tunnel() {
    tunnel_running().store(false, Ordering::Release);
    if let Some(session) = tunnel_session()
        .lock()
        .ok()
        .and_then(|mut guard| guard.take())
    {
        session.shutdown();
    }
    set_tunnel_state(|state| {
        state.connected = false;
        state.error = None;
        state.registered = false;
    });
}

/// Put this machine's key and name on the account directory, when remote reach
/// is on. Called when the tunnel comes up and after a rename; it is the
/// opt-in part of "reach machines from anywhere", so a plain sync never
/// triggers it.
fn register_with_account(settings: &RemoteSettings) {
    if !settings.tunnel {
        return;
    }
    let outcome = (|| -> Result<(), String> {
        let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
        let machine_id = tokenstat_sync::config::ensure_machine_id().map_err(|e| e.to_string())?;
        #[cfg(feature = "local-host")]
        let kind = "host";
        #[cfg(not(feature = "local-host"))]
        let kind = "client";
        tokenstat_sync::profile::register_machine_identity_kind(
            None,
            &machine_id,
            &identity.public_key_hex(),
            &tokenstat_identity::machine_label(),
            kind,
        )
        .map_err(|e| e.to_string())
    })();
    match outcome {
        Ok(()) => set_tunnel_state(|state| state.registered = true),
        Err(error) => {
            set_tunnel_state(|state| state.registered = false);
            eprintln!("remote: could not register with the account directory: {error}");
        }
    }
}

/// Re-register after a rename, so the account directory shows the new name on
/// the other screens.
///
/// A host publishes itself only when remote reach is on: that switch is what
/// puts a computer in the directory, and a rename must not put it there
/// behind the user's back. A client has no such switch. It is in the directory
/// from the moment it signed in, so a phone that skipped this would sit in
/// everybody else's device list as "iPhone" for good.
pub(crate) fn register_if_tunnel_enabled() {
    let settings = load_settings();
    if settings.tunnel {
        std::thread::spawn(move || register_with_account(&settings));
    } else {
        #[cfg(not(feature = "local-host"))]
        std::thread::spawn(register_client_identity);
    }
}

/// Publish this client's key and name to the account directory. Clients do not
/// take a host slot, so this is safe to do whenever the name changes.
#[cfg(not(feature = "local-host"))]
fn register_client_identity() {
    let outcome = (|| -> Result<(), String> {
        let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
        let machine_id = tokenstat_sync::config::ensure_machine_id().map_err(|e| e.to_string())?;
        tokenstat_sync::profile::register_machine_identity_kind(
            None,
            &machine_id,
            &identity.public_key_hex(),
            &tokenstat_identity::machine_label(),
            "client",
        )
        .map_err(|e| e.to_string())
    })();
    if let Err(error) = outcome {
        // Not fatal and not shown: an unnamed phone still works, and the next
        // sign-in or connect registers it again.
        eprintln!("remote: could not publish this device's name: {error}");
    }
}

/// Same-account devices on `/me` are approved without a second tap. The phone
/// and Mac already share the login; requiring Machines → Approve for that is
/// noise. Revoked peers never reach this path (authorize keeps them revoked).
fn account_peer_label(peer: &tokenstat_identity::PublicKey) -> Option<String> {
    let want = tokenstat_identity::hex(peer);
    let status = tokenstat_sync::sync_status(None).ok()?;
    for machine in &status.machines {
        // `continue`, not `?`. One machine in the directory without a key (a
        // computer that only ever synced) would otherwise end the search for
        // every machine after it, and which ones those are depends on the
        // order the server happened to answer in.
        let Some(key) = machine
            .get("public_identity")
            .or_else(|| machine.get("identity"))
            .and_then(|v| v.as_str())
        else {
            continue;
        };
        if !key.eq_ignore_ascii_case(&want) {
            continue;
        }
        let label = machine
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let kind = machine
            .get("kind")
            .and_then(|v| v.as_str())
            .unwrap_or("host");
        if !label.is_empty() {
            return Some(label.to_string());
        }
        if kind == "client" {
            return Some("iPhone".into());
        }
        return Some("Account device".into());
    }
    None
}

fn report(refused: &Refused) {
    match refused {
        Refused::Unknown { fingerprint, label } => eprintln!(
            "remote: refused an unknown machine at {label}, fingerprint {fingerprint}. \
             It is now in the peer list waiting for approval."
        ),
        Refused::NotApproved { fingerprint } => {
            eprintln!("remote: refused {fingerprint}, which is not approved")
        }
        Refused::Handshake(e) => eprintln!("remote: handshake failed: {e}"),
    }
}

/// Answer one peer for as long as it stays connected.
///
/// The body is `server::respond`, unchanged. That is the entire point of the
/// design: this transport adds a handshake and a frame, and asks the same
/// dispatch the same way. A method cannot exist here and be missing over the
/// socket, because neither transport knows what a method is.
fn serve_peer(mut connection: tokenstat_remote::Connection, session: &Mutex<Session>) {
    let peer = connection.peer_key();
    // A machine cannot serve itself. A self-dial through the tunnel, or a
    // mistaken local pair that pinned this machine's own key, would otherwise
    // pass the approval check with its own store and answer itself.
    if MachineIdentity::load_or_create().is_ok_and(|identity| identity.public_key() == peer) {
        return;
    }

    // The first message decides what this connection is. A stream claim
    // (`{"stream": "<token>"}`) means the peer opened a reservation with
    // `stream.open` and is handing this connection to its pump; anything else
    // is a request and the connection joins the request/response loop.
    let first = match connection.receive(MAX_MESSAGE) {
        Ok(bytes) => bytes,
        // Includes the ordinary case of the peer hanging up.
        Err(_) => return,
    };
    // Only a build that can own a terminal can hand one over. Without
    // `local-host` there are no reservations, so a stream claim is just an
    // unrecognized first message and the connection carries on as a request.
    #[cfg(feature = "local-host")]
    if let Some(token) = crate::remote_stream::parse_handshake(&String::from_utf8_lossy(&first)) {
        // `accept` hands the connection to the pump, or closes it when the
        // token is not a live reservation: nobody gets a stream this machine
        // did not open for them. Either way this connection is spoken for.
        crate::remote_stream::accept(&token, connection);
        return;
    }

    // The same per-request approval check, on the first request and on every
    // request after it. Connections are held open and reused, so a peer
    // revoked while connected would otherwise keep being answered until it
    // chose to hang up. Revocation has to mean the next request.
    if !PeerStore::cached().is_ok_and(|store| store.is_approved(&peer)) {
        let _ = connection.send(
            br#"{"ok":false,"error":{"code":"not_approved","message":"That machine has withdrawn access."}}"#,
        );
        connection.close();
        return;
    }
    let line = String::from_utf8_lossy(&first).to_string();
    let response = crate::server::respond(&line, session);
    if connection.send(response.as_bytes()).is_err() {
        return;
    }
    loop {
        let request = match connection.receive(MAX_MESSAGE) {
            Ok(bytes) => bytes,
            Err(_) => return,
        };
        if !PeerStore::cached().is_ok_and(|store| store.is_approved(&peer)) {
            let _ = connection.send(
                br#"{"ok":false,"error":{"code":"not_approved","message":"That machine has withdrawn access."}}"#,
            );
            connection.close();
            return;
        }
        let line = String::from_utf8_lossy(&request).to_string();
        let response = crate::server::respond(&line, session);
        if connection.send(response.as_bytes()).is_err() {
            return;
        }
    }
}

// MARK: - Reaching another machine

/// Connections held open per peer, keyed by public key hex.
///
/// A handshake is three round trips and a Diffie-Hellman, which is far too much
/// to pay per call when a remote terminal polls for output. Held open and
/// reused, exactly like the unix socket pool on the client side.
fn pool() -> &'static Mutex<HashMap<String, Vec<tokenstat_remote::Connection>>> {
    static POOL: OnceLock<Mutex<HashMap<String, Vec<tokenstat_remote::Connection>>>> =
        OnceLock::new();
    POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

const MAX_IDLE_PER_PEER: usize = 4;

/// How long a peer that answered a dial with `no_such_peer` is remembered.
const UNREACHABLE_TTL: Duration = Duration::from_secs(15);

/// Peers the relay has told us are not on the tunnel, remembered briefly.
///
/// The app reconciles remote workspaces every few seconds, and every poll
/// used to dial the peer again; for a machine whose tunnel was off or whose
/// daemon was down, that meant a fresh `no_such_peer` channel open per poll
/// on the relay. During the TTL the dial fails fast instead, with the same
/// words, without another round trip.
fn unreachable_peers() -> &'static Mutex<HashMap<String, Instant>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Call a peer and return its answer's result, unwrapped from the peer's
/// envelope. The shared form of `remote.call` and the pty forwarding in
/// dispatch: a failure on the far machine is a failure here, not a success
/// carrying a failure, and the caller must never see a second envelope where
/// a result belongs.
pub(crate) fn call_peer_result(
    peer_hex: &str,
    method: &str,
    params: &str,
) -> Result<Value, String> {
    let answer = call_peer(peer_hex, method, params)?;
    let value: Value = serde_json::from_str(&answer).map_err(|e| e.to_string())?;
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        let message = value
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("the other machine rejected the call without saying why");
        return Err(message.to_string());
    }
    Ok(value.get("result").cloned().unwrap_or(Value::Null))
}

/// Forward one call to a peer and return its envelope verbatim.
///
/// Verbatim matters: the answer a peer gives is already the shape every front
/// end decodes, so re-wrapping it here would create a second envelope format
/// that only remote calls use.
pub fn call_peer(peer_hex: &str, method: &str, params: &str) -> Result<String, String> {
    let request = json!({"id": 0, "method": method, "params": parse_params(params)}).to_string();

    // One retry on a pooled connection, for a peer daemon that restarted. A
    // fresh connection failing is a real failure and is reported.
    if let Some(mut pooled) = checkout(peer_hex)
        && let Ok(answer) = round_trip(&mut pooled, request.as_bytes())
    {
        checkin(peer_hex, pooled);
        return Ok(answer);
    }

    let mut fresh = dial_peer(peer_hex)?;
    let answer = round_trip(&mut fresh, request.as_bytes());
    // A freshly dialled connection that closes before the first answer usually
    // means the far daemon was just replacing its listener, the same reconnect
    // window `tunnel_dial` retries through. One redial rides over it; anything
    // more is a real failure and should be reported as one.
    if answer
        .as_ref()
        .is_err_and(|e| matches!(e, tokenstat_remote::RemoteError::Closed))
        && let Ok(mut connection) = dial_peer(peer_hex)
        && let Ok(second) = round_trip(&mut connection, request.as_bytes())
    {
        checkin(peer_hex, connection);
        return Ok(second);
    }
    let answer = answer.map_err(|e| e.to_string())?;
    checkin(peer_hex, fresh);
    Ok(answer)
}

/// Open a fresh, authenticated connection to a peer: direct when the record
/// has an address, through the tunnel otherwise. The same ladder `call_peer`
/// climbs, exposed so a stream can claim its own connection.
pub(crate) fn dial_peer(peer_hex: &str) -> Result<tokenstat_remote::Connection, String> {
    let key = public_key_from_hex(peer_hex).map_err(|e| e.to_string())?;
    let store = PeerStore::load().map_err(|e| e.to_string())?;
    let peer = store
        .get(&key)
        .ok_or("that machine is not in this one's peer list")?;
    // Refused here as well as by the far end. Calling a revoked peer would
    // otherwise dial, handshake, and be turned away, which is slower and reads
    // as a network problem rather than as the decision it is.
    if !store.is_approved(&key) {
        return Err(format!(
            "{} is not approved on this machine, so nothing is sent to it",
            peer.label
        ));
    }
    let label = peer.label.clone();
    drop(store);

    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    // One transport: the tunnel. Direct dialing depended on the other
    // machine's network, ports and NAT, which is exactly the class of failure
    // this product stopped trying to solve. The address on the peer record is
    // ignored.
    tunnel_dial(&settings(), key, &identity, &label, "no direct address")
}

fn settings() -> RemoteSettings {
    load_settings()
}

/// Peers this machine may dial right now: approved, with remote reach on. The
/// same rule the app's sidebar applies, so sweeps like `pty.list` that want
/// "all the machines" see exactly the machines they can reach.
///
/// Only the terminal sweeps ask for this, and those are the local half.
#[cfg(feature = "local-host")]
pub(crate) fn reachable_peers() -> Vec<String> {
    let Ok(store) = PeerStore::load() else {
        return Vec::new();
    };
    store
        .list()
        .into_iter()
        .filter(|peer| peer.trust == Trust::Approved && load_settings().tunnel)
        .map(|peer| peer.key)
        .collect()
}

fn tunnel_dial(
    settings: &RemoteSettings,
    peer: tokenstat_identity::PublicKey,
    identity: &MachineIdentity,
    label: &str,
    direct_error: impl std::fmt::Display,
) -> Result<tokenstat_remote::Connection, String> {
    if !settings.tunnel {
        return Err(format!("could not reach {label} directly: {direct_error}"));
    }
    let peer_hex = tokenstat_identity::hex(&peer);
    if unreachable_peers()
        .lock()
        .ok()
        .and_then(|mut cache| {
            cache.retain(|_, seen| seen.elapsed() < UNREACHABLE_TTL);
            cache.get(&peer_hex).map(|seen| seen.elapsed())
        })
        .is_some()
    {
        return Err(format!(
            "could not reach {label} directly ({direct_error}) or through the tunnel: \
             the relay says it is not on the tunnel right now"
        ));
    }
    // Signed in is a precondition for the session's HELLO; the multiplexed
    // session itself was started when remote reach turned on.
    let _ = account_token()?;
    let tunnel = tunnel_session()
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .ok_or("remote reach is on but the tunnel session is not running")?;
    // The target's relay socket can be mid-reconnect (its daemon restarted),
    // which the relay answers with an ERROR channel, or the pairing can drop
    // before the answer arrives. All of those are transient, so a few short
    // retries ride over them instead of showing a failure that resolved
    // itself a second later.
    let mut last = String::new();
    for attempt in 0..3 {
        match tunnel.open_channel(peer).and_then(|channel| {
            tokenstat_remote::handshake_initiator(Box::new(channel), identity, Some(peer), label)
        }) {
            Ok(connection) => return Ok(connection),
            Err(error) => {
                last = error.to_string();
                if last.contains("no_such_peer") {
                    if let Ok(mut cache) = unreachable_peers().lock() {
                        cache.insert(peer_hex.clone(), Instant::now());
                    }
                }
                let retryable = last.contains("no_such_peer")
                    || last.contains("not connected")
                    || last.contains("closed")
                    || last.contains("failed to fill whole buffer");
                if !retryable || attempt == 2 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(200 * (attempt + 1)));
            }
        }
    }
    Err(format!(
        "could not reach {label} directly ({direct_error}) or through the tunnel: {last}"
    ))
}

fn round_trip(
    connection: &mut tokenstat_remote::Connection,
    request: &[u8],
) -> Result<String, tokenstat_remote::RemoteError> {
    connection.send(request)?;
    let answer = connection.receive(MAX_MESSAGE)?;
    Ok(String::from_utf8_lossy(&answer).to_string())
}

fn checkout(peer: &str) -> Option<tokenstat_remote::Connection> {
    pool().lock().ok()?.get_mut(peer)?.pop()
}

fn checkin(peer: &str, connection: tokenstat_remote::Connection) {
    if let Ok(mut map) = pool().lock() {
        let idle = map.entry(peer.to_string()).or_default();
        if idle.len() < MAX_IDLE_PER_PEER {
            idle.push(connection);
        }
    }
}

/// The unix socket sends `params` as a JSON value; so does this. An empty
/// string is `{}` rather than an error, matching `dispatch::parse`.
fn parse_params(params: &str) -> Value {
    let trimmed = params.trim();
    if trimmed.is_empty() {
        return json!({});
    }
    serde_json::from_str(trimmed).unwrap_or_else(|_| json!({}))
}

// MARK: - Dispatch methods

/// Answer a `remote.*` method, or `None` when it is not one.
///
/// Sessionless, like the machine methods: none of these read the archive, and
/// `remote.call` forwarding a request must not queue behind a local scan when
/// the remote machine is idle.
pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "remote.status" => status(),
        "remote.serve" => serve(params),
        "remote.call" => forward(params),
        "remote.nudge" => nudge(),
        _ => return None,
    })
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ServeParams {
    enable: bool,
    port: Option<u16>,
    tunnel: Option<bool>,
    tunnel_endpoint: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ForwardParams {
    /// The peer's public key as hex. Not a label: a label is advisory and two
    /// machines may share one.
    peer: String,
    method: String,
    params: Value,
}

/// Wake the tunnel after the network comes back or the machine wakes from
/// sleep.
///
/// The supervisor sizes its reconnect backoff for a network that may still be
/// dead. A connectivity restore means it is not, so the next reconnect should
/// not wait out the rest of that backoff. When no session is live, this tries
/// the same start a retry tick would, now rather than later.
fn nudge() -> Result<Value, String> {
    if let Some(session) = tunnel_session().lock().ok().and_then(|guard| guard.clone()) {
        session.nudge();
        return Ok(json!({"nudged": true}));
    }
    let settings = load_settings();
    if settings.tunnel
        && let Ok(session) = session_for_serving()
    {
        start_tunnel_if_enabled(session, &settings);
    }
    Ok(json!({"nudged": true}))
}

fn status() -> Result<Value, String> {
    let settings = load_settings();
    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let mut tunnel_state = tunnel_state().lock().map_err(|e| e.to_string())?.clone();
    // The session knows the truth about the socket: `tunnel_state` is only
    // updated on inbound traffic, so a machine nobody has dialled yet would
    // otherwise report "not connected" while its socket is up. Merge the
    // live status over it.
    if let Some(session) = tunnel_session().lock().ok().and_then(|guard| guard.clone()) {
        let live = session.status();
        tunnel_state.connected = live.connected;
        if let Some(error) = live.error {
            tunnel_state.error = Some(error);
        }
    }
    Ok(json!({
        // What the user chose, and what is actually true. They differ while
        // the tunnel is being refused, and a screen that showed only the
        // toggle would invite a Connect that can never work.
        "tunnel": settings.tunnel,
        // What the tunnel is actually doing: the toggle can be on while the
        // daemon is being refused (plan gate, revoked token, endpoint down),
        // and a screen that cannot tell the difference will offer a Connect
        // that can never work.
        "tunnelOnline": tunnel_state.connected,
        "tunnelRegistered": tunnel_state.registered,
        "tunnelError": tunnel_state.error,
        "key": identity.public_key_hex(),
        "fingerprint": identity.fingerprint(),
        // The check a person will actually perform. See
        // `tokenstat_identity::key_words`: same key, said in a way somebody
        // reads aloud instead of skimming.
        "words": tokenstat_identity::key_words(&identity.public_key()),
        "label": tokenstat_identity::machine_label(),
    }))
}

fn validate_tunnel_endpoint(raw: &str) -> Result<String, String> {
    let s = raw.trim().trim_end_matches('/');
    let (scheme, rest) = s
        .split_once("://")
        .ok_or_else(|| format!("tunnel endpoint must be a wss:// URL (got {raw})"))?;
    let scheme = scheme.to_ascii_lowercase();
    let hostport = rest.split('/').next().unwrap_or(rest);
    let host = hostport
        .trim_start_matches('[')
        .split(']')
        .next()
        .unwrap_or(hostport)
        .split(':')
        .next()
        .unwrap_or(hostport)
        .to_ascii_lowercase();
    let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0";
    match scheme.as_str() {
        "wss" => Ok(s.to_string()),
        "ws" if loopback => Ok(s.to_string()),
        "ws" => Err("ws:// is only allowed for localhost tunnel endpoints; use wss://".into()),
        _ => Err(format!(
            "tunnel endpoint must use wss:// (got scheme {scheme})"
        )),
    }
}

fn serve(params: &str) -> Result<Value, String> {
    let p: ServeParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let mut settings = load_settings();
    if let Some(tunnel) = p.tunnel {
        settings.tunnel = tunnel;
    }
    if let Some(endpoint) = p.tunnel_endpoint {
        settings.tunnel_endpoint = validate_tunnel_endpoint(&endpoint)?;
    }
    save_settings(&settings)?;
    if p.tunnel == Some(false) {
        stop_tunnel();
    }
    if settings.tunnel {
        start_tunnel_if_enabled(session_for_serving()?, &settings);
    }
    Ok(json!({"tunnel": settings.tunnel}))
}

fn forward(params: &str) -> Result<Value, String> {
    let p: ForwardParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    if p.peer.is_empty() || p.method.is_empty() {
        return Err("remote.call needs a peer and a method".into());
    }
    // `remote.call` reaching another machine's `remote.call` would let one
    // approved peer use this machine as a hop to a third it was never
    // approved by. Trust is not transitive, and this is the line where that
    // would stop being true.
    if p.method.starts_with("remote.") {
        return Err("a remote call cannot ask a peer to make another remote call".into());
    }

    call_peer_result(&p.peer, &p.method, &p.params.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_reach_is_off_unless_a_file_says_otherwise() {
        assert!(!RemoteSettings::default().tunnel);
        assert_eq!(
            RemoteSettings::default().tunnel_endpoint,
            "wss://tunnel.tokenstat.ai"
        );
    }

    /// Trust is not transitive. An approved peer must not be able to use this
    /// machine as a hop to a third one that never approved it.
    #[test]
    fn a_remote_call_cannot_chain_through_a_peer() {
        let params = json!({"peer": "ab".repeat(32), "method": "remote.call", "params": {}});
        let refused = forward(&params.to_string()).expect_err("must refuse");
        assert!(refused.contains("another remote call"), "{refused}");
    }

    #[test]
    fn a_call_needs_both_a_peer_and_a_method() {
        assert!(forward(&json!({"method": "info"}).to_string()).is_err());
        assert!(forward(&json!({"peer": "ab".repeat(32)}).to_string()).is_err());
    }

    #[test]
    fn empty_params_are_an_empty_object() {
        assert_eq!(parse_params(""), json!({}));
        assert_eq!(parse_params("  "), json!({}));
        assert_eq!(parse_params(r#"{"a":1}"#), json!({"a": 1}));
    }

    fn test_identity() -> MachineIdentity {
        MachineIdentity::from_secret([7u8; 32])
    }

    fn test_token() -> tokenstat_sync::profile::TunnelToken {
        tokenstat_sync::profile::TunnelToken {
            token: "tsk_deadbeef_secret".into(),
            expires_at: "2030-01-01T00:00:00.000Z".into(),
            expires_in: 43_200,
            machine: "m_0123456789abcdef".into(),
        }
    }

    /// A transient registration failure must not block a renewal the account
    /// can already serve. That is the P0 hardening: a 5xx on the register
    /// route used to read as "tunnel unavailable" until the next retry.
    #[test]
    fn a_registration_hiccup_does_not_block_a_renewal() {
        let (token, expires) = mint_hello_token_impl(
            "m_0123456789abcdef",
            &test_identity(),
            // Not the first mint of a process: the account already knows the
            // machine, so registration is best-effort.
            false,
            |_, _, _| Err("the register route 500'd".into()),
            |_| Ok(test_token()),
        )
        .expect("a renewal must survive a register hiccup");
        assert_eq!(token, "tsk_deadbeef_secret");
        assert_eq!(expires, Some(43_200));
    }

    /// Registration stays mandatory on the first mint of a process: a machine
    /// the account has never seen must not get a token that binds nothing.
    #[test]
    fn registration_still_gates_the_first_mint() {
        let err = mint_hello_token_impl(
            "m_0123456789abcdef",
            &test_identity(),
            true,
            |_, _, _| Err("no account host reachable".into()),
            |_| Ok(test_token()),
        )
        .expect_err("the first mint must not skip registration");
        assert!(err.contains("no account host"), "{err}");
    }

    /// A mint refusal that says the machine is not registered drives one
    /// re-register, then a second mint. That is the repair the refusal names.
    #[test]
    fn a_not_registered_refusal_re_registers_then_mints() {
        let mut registers = 0;
        let mut mints = 0;
        let (token, _) = mint_hello_token_impl(
            "m_0123456789abcdef",
            &test_identity(),
            false,
            |_, _, _| {
                registers += 1;
                Ok(())
            },
            |_| {
                mints += 1;
                if mints == 1 {
                    Err(ProfileError::MachineNotRegistered)
                } else {
                    Ok(test_token())
                }
            },
        )
        .expect("one re-register fixes a machine the account forgot");
        assert_eq!(token, "tsk_deadbeef_secret");
        assert_eq!(registers, 1);
        assert_eq!(mints, 2);
    }
}
