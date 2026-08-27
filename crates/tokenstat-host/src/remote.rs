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

use std::collections::{BTreeSet, HashMap};
#[cfg(feature = "local-host")]
use std::net::UdpSocket;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Once, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
#[cfg(feature = "local-host")]
use tokenstat_identity::Trust;
use tokenstat_identity::{MachineIdentity, PeerStore, public_key_from_hex};
use tokenstat_remote::{Refused, authorize_with};
use tokenstat_sync::profile::ProfileError;

use crate::session::Session;
use tokenstat_remote::tunnel::ChannelPurpose;

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

#[cfg(feature = "local-host")]
fn direct_running() -> &'static AtomicBool {
    static RUNNING: AtomicBool = AtomicBool::new(false);
    &RUNNING
}

/// Port held by the direct listener, or zero while it is not listening.
///
/// The old implementation advertised 7878 even when its bind had failed. The
/// candidate contract reports only a socket the accept loop actually owns.
#[cfg(feature = "local-host")]
fn direct_port() -> &'static AtomicUsize {
    static PORT: AtomicUsize = AtomicUsize::new(0);
    &PORT
}

#[cfg(feature = "local-host")]
fn direct_generation() -> &'static AtomicUsize {
    static GENERATION: AtomicUsize = AtomicUsize::new(0);
    &GENERATION
}

#[cfg(feature = "local-host")]
#[derive(Clone)]
struct DirectMapping {
    generation: usize,
    address: SocketAddr,
}

#[cfg(feature = "local-host")]
fn direct_mapping() -> &'static Mutex<Option<DirectMapping>> {
    static MAPPING: OnceLock<Mutex<Option<DirectMapping>>> = OnceLock::new();
    MAPPING.get_or_init(|| Mutex::new(None))
}

/// One address an authenticated peer may try for the direct Noise connection.
/// An address is never authority: the pinned key still has to complete the
/// handshake before the candidate is accepted or remembered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DirectCandidate {
    pub kind: String,
    pub address: String,
    pub priority: u16,
}

/// Candidates recently offered by each peer over an authenticated connection.
/// They are deliberately memory-only. A candidate becomes durable only after
/// connecting and presenting the peer's pinned Noise key.
fn offered_direct_candidates() -> &'static Mutex<HashMap<String, Vec<DirectCandidate>>> {
    static CANDIDATES: OnceLock<Mutex<HashMap<String, Vec<DirectCandidate>>>> = OnceLock::new();
    CANDIDATES.get_or_init(|| Mutex::new(HashMap::new()))
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
    #[cfg(feature = "local-host")]
    start_direct_if_enabled();
}

#[cfg(feature = "local-host")]
fn start_direct_if_enabled() {
    if tunnel_paused().load(Ordering::Acquire) {
        return;
    }
    if !load_settings().tunnel || direct_running().swap(true, Ordering::AcqRel) {
        return;
    }
    std::thread::spawn(|| {
        await_direct_stopped();
        let identity = match MachineIdentity::load_or_create() {
            Ok(value) => value,
            Err(_) => {
                direct_running().store(false, Ordering::Release);
                return;
            }
        };
        // Keep 7878 for compatibility with old invites, but a port conflict is
        // not a reason to lose direct reach. Every new candidate includes the
        // actual port this listener obtained.
        let server = match tokenstat_remote::Server::bind("0.0.0.0:7878", &identity) {
            Ok(value) => value,
            Err(preferred_error) => match tokenstat_remote::Server::bind("0.0.0.0:0", &identity) {
                Ok(value) => value,
                Err(fallback_error) => {
                    eprintln!(
                        "remote: direct listener unavailable on 7878 ({preferred_error}) or a free port ({fallback_error})"
                    );
                    direct_running().store(false, Ordering::Release);
                    return;
                }
            },
        };
        let port = server
            .local_address()
            .ok()
            .and_then(|address| address.parse::<SocketAddr>().ok())
            .map_or(0, |address| usize::from(address.port()));
        direct_port().store(port, Ordering::Release);
        let _ = server.set_nonblocking(true);
        direct_bound().store(true, Ordering::Release);
        let generation = direct_generation().fetch_add(1, Ordering::AcqRel) + 1;
        if port != 0 {
            start_direct_mapping(generation, port as u16);
        }
        while direct_running().load(Ordering::Acquire) {
            match server.accept() {
                Ok(Ok(connection)) => {
                    if let Ok(session) = session_for_serving() {
                        std::thread::spawn(move || serve_peer(connection, &session));
                    }
                }
                Ok(Err(refused)) => report(&refused),
                Err(tokenstat_remote::RemoteError::Io(error))
                    if error.kind() == std::io::ErrorKind::WouldBlock =>
                {
                    std::thread::sleep(Duration::from_millis(100))
                }
                Err(error) => {
                    eprintln!("remote: direct accept failed: {error}");
                    break;
                }
            }
        }
        drop(server);
        direct_bound().store(false, Ordering::Release);
        direct_port().store(0, Ordering::Release);
        direct_running().store(false, Ordering::Release);
    });
}

#[cfg(feature = "local-host")]
fn stop_direct() {
    direct_running().store(false, Ordering::Release);
    direct_generation().fetch_add(1, Ordering::AcqRel);
    if let Ok(mut mapping) = direct_mapping().lock() {
        *mapping = None;
    }
}

/// Wait for the accept loop to let go of port 7878 before binding it again.
///
/// The loop polls the flag every 100 ms, so a pause and a resume close
/// together (a lid closed and opened, the app quit and reopened) used to race:
/// the replacement bound while the old thread still owned the socket, failed
/// with "address in use", and both threads then exited leaving no listener at
/// all. Bounded, because waiting forever for a thread that has already died
/// would be worse than trying the bind.
#[cfg(feature = "local-host")]
fn await_direct_stopped() {
    for _ in 0..20 {
        if !direct_bound().load(Ordering::Acquire) {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Whether the accept loop still holds the listening socket.
#[cfg(feature = "local-host")]
fn direct_bound() -> &'static AtomicBool {
    static BOUND: std::sync::OnceLock<AtomicBool> = std::sync::OnceLock::new();
    BOUND.get_or_init(|| AtomicBool::new(false))
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
    /// When the relay stops accepting it, as a wall-clock instant in
    /// milliseconds since the epoch. `None` for the legacy login bearer, which
    /// does not expire.
    ///
    /// **Wall clock, not [`Instant`], and that is the whole point.** On macOS
    /// `Instant` stops advancing while the machine is asleep, and so does
    /// `thread::sleep`. The relay expires a credential on a calendar. A laptop
    /// that slept eight hours of a twelve hour credential used to believe it
    /// still had most of the term left, so nothing refreshed, the socket was
    /// denied `token_expired`, and the machine read as offline until somebody
    /// noticed. The two clocks have to be the same clock.
    expires_at_ms: Option<i64>,
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
                match held.expires_at_ms {
                    None => return Ok((held.token.clone(), None)),
                    Some(at) => {
                        if let Some(left) = seconds_left(at)
                            && left > CREDENTIAL_REFRESH_MARGIN.as_secs()
                        {
                            return Ok((held.token.clone(), Some(left)));
                        }
                    }
                }
            }
        }
    }
    mint_hello_token()
}

/// Seconds of wall clock between now and `at_ms`, or `None` once it is past.
fn seconds_left(at_ms: i64) -> Option<u64> {
    let left_ms = at_ms - jiff::Timestamp::now().as_millisecond();
    (left_ms > 0).then_some((left_ms / 1000) as u64)
}

/// When the relay will stop accepting a freshly minted credential.
///
/// The absolute time the account issued is preferred over `expires_in`,
/// because it is the value the relay itself compares against and it survives a
/// slow mint. `expires_in` is the fallback for a response whose timestamp will
/// not parse, which is a server contract change rather than something a client
/// should fall over on.
fn credential_deadline_ms(token: &tokenstat_sync::profile::TunnelToken) -> i64 {
    token
        .expires_at
        .parse::<jiff::Timestamp>()
        .map(|at| at.as_millisecond())
        .unwrap_or_else(|_| {
            (jiff::Timestamp::now() + Duration::from_secs(token.expires_in)).as_millisecond()
        })
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
    // Phones (no local-host) register as clients so they do not upload usage.
    // They still use a device slot. Macs remain hosts.
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
            // A mint only succeeds for a registered machine, so a renewal that
            // skipped registration (best-effort after the first mint) still
            // means the machine is on the account directory.
            set_tunnel_state(|state| state.registered = true);
            let deadline = credential_deadline_ms(&tok);
            hold_credential(&tok.token, Some(deadline));
            // The lifetime the caller schedules from is measured against the
            // deadline rather than taken from `expires_in`, so a mint that took
            // ten seconds does not hand back a half-life ten seconds too long.
            Ok((tok.token, Some(seconds_left(deadline).unwrap_or(0))))
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

fn hold_credential(token: &str, expires_at_ms: Option<i64>) {
    if let Ok(mut guard) = held_credential().lock() {
        *guard = Some(HeldCredential {
            token: token.to_string(),
            expires_at_ms,
        });
    }
}

fn clear_held_credential() {
    if let Ok(mut guard) = held_credential().lock() {
        *guard = None;
    }
}

/// Serializes tunnel start so two callers cannot both create a session.
///
/// Without it, a retry tick and a connectivity nudge arriving in the same
/// window both pass the `tunnel_running` guard (one finds the flag set but no
/// session yet, clears it, and re-arms) and both spawn an inbound thread; the
/// second `take_inbound()` would panic and take the daemon down. A caller that
/// waits here then re-checks and sees the finished session instead.
static STARTING: Mutex<()> = Mutex::new(());

fn tunnel_paused() -> &'static AtomicBool {
    static PAUSED: AtomicBool = AtomicBool::new(false);
    &PAUSED
}

/// Drop the tunnel socket without writing the user's switch off.
///
/// Used when hosting is paused (lid closed, app gone). `remote.json` stays
/// as the user left it, so opening the lid or the app brings the tunnel back.
/// The LAN listener stops too: pausing only the tunnel left port 7878 up for
/// an approved peer on the same network.
pub(crate) fn pause_tunnel() {
    tunnel_paused().store(true, Ordering::Release);
    stop_tunnel();
    #[cfg(feature = "local-host")]
    stop_direct();
}

/// Start the tunnel again if the user still has remote reach on.
pub(crate) fn resume_tunnel_if_enabled() {
    tunnel_paused().store(false, Ordering::Release);
    let settings = load_settings();
    if !settings.tunnel {
        return;
    }
    if let Ok(session) = session_for_serving() {
        start_tunnel_if_enabled(session, &settings);
    }
    #[cfg(feature = "local-host")]
    start_direct_if_enabled();
}

fn start_tunnel_if_enabled(session: Arc<Mutex<Session>>, settings: &RemoteSettings) {
    if !settings.tunnel || tunnel_paused().load(Ordering::Acquire) {
        return;
    }
    // Hold the whole start, network mints included. A second caller blocks
    // here and then re-checks, so at most one session is ever created.
    let _starting = STARTING.lock().unwrap_or_else(|e| e.into_inner());
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
                    // A later successful mint must not leave a previous
                    // plan-refusal sitting in `tunnelError`. The panel
                    // reads that field even when the socket is up.
                    set_tunnel_state(|state| state.error = None);
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
            state.error = Some(error.clone());
        });
        tunnel_running().store(false, Ordering::Release);
        if !is_permanent_start_error(&error) {
            retry_start_later(Arc::clone(&session));
        }
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
                state.error = Some(error.clone());
            });
            tunnel_running().store(false, Ordering::Release);
            // A daemon that starts before the network is up, or while the
            // account host is having a minute, used to stay off until somebody
            // opened Machines and toggled the switch. Remote reach is meant to
            // be the state of the machine, not the state of the last attempt.
            if !is_permanent_start_error(&error) {
                retry_start_later(session);
            }
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
                        Ok(token)
                    }
                    Err(error) => {
                        set_tunnel_state(|state| state.error = Some(error.clone()));
                        // Handed back as well as recorded: the supervisor puts
                        // it into the refusal it reports, so the panel says
                        // what the account actually answered instead of
                        // restating the relay's symptom.
                        Err(error)
                    }
                }));
                *guard = Some(session.clone());
                session
            }
        }
    };
    // The mint is the plan gate. Once it succeeds the previous refusal is
    // stale, even before the first inbound channel or READY lands.
    set_tunnel_state(|state| state.error = None);
    // Refresh the short-lived token at half-life so HELLO never races expiry.
    if let Some(ttl) = expires_in {
        let refresh_tunnel = Arc::clone(&tunnel);
        std::thread::spawn(move || tunnel_token_refresh_loop(refresh_tunnel, ttl));
    }
    std::thread::spawn(move || {
        // Inbound channels: the relay dialled us. Each is a fresh Noise
        // handshake over the channel, answered exactly like a direct TCP
        // connection, so the approval rule cannot tell the transports apart.
        // `None` here means another loop already took the receiver; a start
        // that lost a race must not spawn a second one (or panic).
        let Some(inbound) = tunnel.take_inbound() else {
            return;
        };
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
fn is_permanent_start_error(error: &str) -> bool {
    let lower = error.to_lowercase();
    // Plan refusals stay off the tight retry loop so a free account does
    // not mint every ten seconds. They are not permanent across an
    // entitlement change: `nudge` and `reconsider_plan` try again.
    lower.contains("sign in") || is_plan_start_error(error) || lower.contains("device limit")
}

/// The account host refused a mint because this plan cannot open a tunnel.
fn is_plan_start_error(error: &str) -> bool {
    let lower = error.to_lowercase();
    lower.contains("paid-plan")
        || lower.contains("not on this plan")
        || lower.contains("not_on_this_plan")
        || lower.contains("no longer includes remote")
}

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
            if !settings.tunnel || tunnel_paused().load(Ordering::Acquire) {
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
        // Waited out against the calendar, not by counting one-second sleeps.
        // Neither `thread::sleep` nor `Instant` advances while a Mac is
        // asleep, so the old count reached its half-life after that many
        // *awake* seconds while the relay had been expiring the credential the
        // whole time. A laptop that sleeps every night got denied
        // `token_expired` before anything here thought a refresh was due.
        let wake_at_ms =
            (jiff::Timestamp::now() + Duration::from_secs(sleep_secs)).as_millisecond();
        while jiff::Timestamp::now().as_millisecond() < wake_at_ms
            && tunnel_running().load(Ordering::Acquire)
        {
            std::thread::sleep(Duration::from_secs(1));
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

pub(crate) fn stop_tunnel() {
    tunnel_running().store(false, Ordering::Release);
    clear_held_credential();
    // The next start may be a different account, and a directory from the last
    // one would label its machines.
    clear_account_directory();
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

/// Publish this client's key and name to the account directory. A refresh of
/// an already-linked phone does not use a second slot.
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

/// The account's machine directory, and when it was fetched.
///
/// Cached because [`account_peer_label`] runs inside the inbound handshake,
/// once per channel the relay dials. Without this, every dial from a phone
/// paid an HTTP round trip to the account host before the connection could be
/// authorized, so a slow account host read to the user as a slow tunnel, and a
/// phone opening a host or pulling to refresh spent one directory fetch per
/// screen. The directory changes when somebody adds or renames a device, which
/// is not something the handshake path has to see within the second.
struct Directory {
    /// Wall clock, so a machine that slept does not treat an overnight cache
    /// as fresh. Same reason the tunnel credential is measured this way.
    fetched_at_ms: i64,
    machines: Vec<Value>,
}

fn account_directory() -> &'static Mutex<Option<Directory>> {
    static CACHE: OnceLock<Mutex<Option<Directory>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

const DIRECTORY_TTL_MS: i64 = 60_000;
/// A device the cache has never seen may have registered since it was filled,
/// so a miss is allowed to refetch. Bounded, because a peer that is not on the
/// account at all is exactly what an unwanted dial looks like, and each one
/// must not be able to make this machine call out.
const DIRECTORY_MISS_REFETCH_MS: i64 = 10_000;

fn last_directory_miss() -> &'static Mutex<i64> {
    static AT: OnceLock<Mutex<i64>> = OnceLock::new();
    AT.get_or_init(|| Mutex::new(0))
}

/// The machine list, from cache unless it is older than the TTL.
fn account_machines(force: bool) -> Vec<Value> {
    let now = jiff::Timestamp::now().as_millisecond();
    if !force
        && let Ok(guard) = account_directory().lock()
        && let Some(held) = guard.as_ref()
        && now - held.fetched_at_ms < DIRECTORY_TTL_MS
    {
        return held.machines.clone();
    }
    let Ok(status) = tokenstat_sync::sync_status(None) else {
        // Keep whatever is held: an account host having a minute must not turn
        // every same-account device into an unknown one.
        return account_directory()
            .lock()
            .ok()
            .and_then(|guard| guard.as_ref().map(|held| held.machines.clone()))
            .unwrap_or_default();
    };
    if let Ok(mut guard) = account_directory().lock() {
        *guard = Some(Directory {
            fetched_at_ms: now,
            machines: status.machines.clone(),
        });
    }
    status.machines
}

/// Forget the cached directory. Called when remote reach stops, because the
/// next start may be a different account.
fn clear_account_directory() {
    if let Ok(mut guard) = account_directory().lock() {
        *guard = None;
    }
}

/// Same-account devices on `/me` are approved without a second tap. The phone
/// and Mac already share the login, and requiring Machines then Approve for
/// that is noise. Revoked peers never reach this path (authorize keeps them
/// revoked).
fn account_peer_label(peer: &tokenstat_identity::PublicKey) -> Option<String> {
    account_peer_label_hex(&tokenstat_identity::hex(peer))
}

/// The same lookup for callers that already hold the key as hex.
///
/// Everything past the handshake speaks hex: `request_context::remote_peer`
/// hands one out, and re-parsing it into a `PublicKey` only to print it back
/// would be a round trip through bytes for nothing.
pub(crate) fn account_peer_label_hex(want: &str) -> Option<String> {
    let fetched_at = directory_fetched_at_ms();
    if let Some(label) = label_for(&account_machines(false), want) {
        return Some(label);
    }
    // Not in what we hold. A device that registered since the cache was filled
    // is the ordinary reason, so refetch once, rate limited.
    //
    // Unless the call above already went to the network, which it does when
    // the held copy was past its TTL. Asking again would be two round trips
    // inside one handshake for the same answer.
    if directory_fetched_at_ms() != fetched_at {
        return None;
    }
    let now = jiff::Timestamp::now().as_millisecond();
    let may_refetch = last_directory_miss().lock().is_ok_and(|mut at| {
        let due = now - *at > DIRECTORY_MISS_REFETCH_MS;
        if due {
            *at = now;
        }
        due
    });
    if !may_refetch {
        return None;
    }
    label_for(&account_machines(true), want)
}

/// When the held directory was last filled, or 0 when nothing is held. Used to
/// tell a cache hit from a fetch without threading a flag out of
/// [`account_machines`].
fn directory_fetched_at_ms() -> i64 {
    account_directory()
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().map(|held| held.fetched_at_ms))
        .unwrap_or(0)
}

/// This peer's display name, from a machine directory already in hand.
fn label_for(machines: &[Value], want: &str) -> Option<String> {
    for machine in machines {
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
        if !key.eq_ignore_ascii_case(want) {
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
/// The body is `server::respond`, unchanged, plus a keep-awake hook that
/// looks at the method name. That is the entire point of the design: this
/// transport adds a handshake and a frame, and asks the same dispatch the
/// same way. A method cannot exist here and be missing over the socket,
/// because neither transport knows what a method is.
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
    let response = respond_remote(&line, session, &tokenstat_identity::hex(&peer));
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
        let response = respond_remote(&line, session, &tokenstat_identity::hex(&peer));
        if connection.send(response.as_bytes()).is_err() {
            return;
        }
    }
}

/// Same dispatch as the unix socket, plus the inbound-work sleep assertion.
///
/// The method table is still only in `dispatch`. This is the one place a
/// remote request is known to be inbound, which is the only time the Mac
/// should stay awake for a closed app.
fn respond_remote(line: &str, session: &Mutex<Session>, peer: &str) -> String {
    if crate::host_policy::should_refuse_inbound(line) {
        return crate::host_policy::refuse_inbound(line);
    }
    crate::keep_awake::note_inbound(line);
    crate::request_context::with_remote_peer(peer, || crate::server::respond(line, session))
}

// MARK: - Reaching another machine

/// Connections held open per peer, keyed by public key hex.
///
/// A handshake is three round trips and a Diffie-Hellman, which is far too much
/// to pay per call when a remote terminal polls for output. Held open and
/// reused, exactly like the unix socket pool on the client side.
fn pool() -> &'static Mutex<HashMap<String, Vec<Idle>>> {
    static POOL: OnceLock<Mutex<HashMap<String, Vec<Idle>>>> = OnceLock::new();
    static REAPER: Once = Once::new();
    let pool = POOL.get_or_init(|| Mutex::new(HashMap::new()));
    REAPER.call_once(|| {
        if thread::Builder::new()
            .name("pool-reaper".into())
            .spawn(|| {
                loop {
                    thread::sleep(REAP_INTERVAL);
                    if let Ok(mut map) = pool.lock() {
                        reap(&mut map);
                    }
                }
            })
            .is_err()
        {
            // The walk also happens on every checkout and checkin, so a
            // process where the thread could not start still reaps whenever
            // it has traffic; only a machine idle in both senses keeps the
            // sockets.
        }
    });
    pool
}

/// How often the reaper wakes to close pooled connections nobody is using.
const REAP_INTERVAL: Duration = Duration::from_secs(15);

/// A connection waiting to be used again, and when it stopped being used.
///
/// The timestamp is the whole point. Without it a pooled connection was held
/// open for the life of the process: four per peer, a map key for every peer
/// ever dialled, and nothing anywhere that ever closed one. That is not a leak
/// in the sense of a lost handle, and it is still a descriptor count that only
/// goes up, which is the same thing to a process that has run out of them.
struct Idle {
    connection: tokenstat_remote::Connection,
    since: Instant,
}

const MAX_IDLE_PER_PEER: usize = 4;

/// How long a connection may sit unused before it is closed.
///
/// A handshake is three round trips and a Diffie-Hellman, so the pool has to
/// outlast the gap between a terminal's polls, which is milliseconds, and the
/// gap between somebody's glances at a screen, which is seconds. A minute
/// covers both with room to spare and is far shorter than the hours a machine
/// sits with the app open and nothing to say.
const POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

/// The safety valve on connections to one peer at once.
///
/// Not a queue: a burst of legitimate calls is normal and waiting for a slot
/// would be a deadlock waiting for a reason. This is far above anything the
/// app does on purpose, so tripping it means something is looping, and being
/// told that is better than the process running out of descriptors and
/// reporting it against whichever file lost the race. See `open_files`.
const MAX_LIVE_PER_PEER: usize = 64;

/// Connections dialled and not yet finished with, for the ceiling above and
/// for `info`.
fn live() -> &'static Mutex<HashMap<String, usize>> {
    static LIVE: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    LIVE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Total live peer connections, read without taking the map's lock.
static LIVE_TOTAL: AtomicUsize = AtomicUsize::new(0);

/// Holds one peer's slot for as long as the caller holds this.
///
/// An RAII guard rather than a matching decrement at every exit, because
/// `call_peer` has six of them and a counter that leaks on one path is worse
/// than no counter at all.
pub(crate) struct LiveSlot {
    peer: String,
}

impl LiveSlot {
    fn take(peer: &str) -> Result<Self, String> {
        let mut held = live()
            .lock()
            .map_err(|_| "peer connection count poisoned")?;
        let count = held.entry(peer.to_string()).or_insert(0);
        if *count >= MAX_LIVE_PER_PEER {
            return Err(format!(
                "already {count} connections open to that machine; something is retrying without stopping"
            ));
        }
        *count += 1;
        LIVE_TOTAL.fetch_add(1, Ordering::Relaxed);
        Ok(Self {
            peer: peer.to_string(),
        })
    }
}

impl Drop for LiveSlot {
    fn drop(&mut self) {
        LIVE_TOTAL.fetch_sub(1, Ordering::Relaxed);
        if let Ok(mut held) = live().lock()
            && let Some(count) = held.get_mut(&self.peer)
        {
            *count = count.saturating_sub(1);
            if *count == 0 {
                held.remove(&self.peer);
            }
        }
    }
}

/// What the peer-call path is holding open, for `info` and for a bug report.
///
/// Returns (calls in flight, connections idle in the pool). Streams own their
/// connection for the life of a session and are counted by the registry that
/// owns them, not here: this is the path that can loop, and so the one whose
/// number says whether something is looping.
pub fn connection_counts() -> (usize, usize) {
    let idle = pool()
        .lock()
        .map(|held| held.values().map(Vec::len).sum())
        .unwrap_or(0);
    (LIVE_TOTAL.load(Ordering::Relaxed), idle)
}

/// How long the first `no_such_peer` is remembered, and the ceiling the
/// doubling stops at.
///
/// The floor used to be 15 seconds while the app re-dialled a failed peer
/// every 30, so the cache expired before every single retry and suppressed
/// nothing: a machine that had been off for an hour still cost the relay a
/// channel open twice a minute. The floor now outlasts that retry, and a peer
/// that stays absent is asked less and less often.
///
/// The ceiling is two minutes rather than something larger because this is
/// also how long a machine that just woke up stays invisible. `remote.nudge`
/// clears the whole cache, and the app nudges on wake and when connectivity
/// comes back, so the ceiling is the worst case for a machine nobody told us
/// about rather than the normal one.
const UNREACHABLE_FLOOR_MS: i64 = 45_000;
const UNREACHABLE_CEILING_MS: i64 = 120_000;
/// After a local path change, the first few `no_such_peer` answers are the
/// far machine reconnecting, not proof it is gone. Suppressing on those
/// would hide it for 45s–2min while the phone retries at 1/2/4s.
const ABSENCE_GRACE_MS: i64 = 15_000;

/// One peer's absence: when it was last answered `no_such_peer`, and how many
/// times in a row.
#[derive(Clone, Copy)]
struct Absence {
    /// Wall clock, for the same reason the tunnel credential is measured that
    /// way: `Instant` stops advancing while a Mac is asleep, so an absence
    /// recorded before the lid closed would still read as fresh hours later
    /// and hide a peer that had been back the whole time.
    since_ms: i64,
    strikes: u32,
}

impl Absence {
    /// How long this absence is trusted before the peer is dialled again.
    ///
    /// The first miss is worth nothing. A dial can land in the moment between
    /// a peer's daemon starting and its HELLO registering, and the relay only
    /// holds an open for a key it saw recently, so a machine that has been off
    /// for a while genuinely answers `no_such_peer` once on the way back.
    /// Suppressing on that one answer would hide it until the wait ran out.
    /// Suppressing from the second confirms it is really gone and still spares
    /// the relay everything after that.
    fn suppresses(&self) -> bool {
        self.strikes > 0 && self.age_ms() < self.ttl_ms()
    }

    fn age_ms(&self) -> i64 {
        jiff::Timestamp::now().as_millisecond() - self.since_ms
    }

    /// Doubling from the floor, capped, so a machine that has been off all day
    /// is asked once every couple of minutes rather than twice a minute.
    fn ttl_ms(&self) -> i64 {
        let doubled = UNREACHABLE_FLOOR_MS.saturating_mul(1i64 << self.strikes.min(3));
        doubled.min(UNREACHABLE_CEILING_MS)
    }

    /// Worth remembering at all. A confirmed absence that is long past its
    /// wait, and a first miss that nothing followed up, are both just noise in
    /// the map.
    fn worth_keeping(&self) -> bool {
        self.age_ms() < UNREACHABLE_CEILING_MS
    }
}

/// Peers the relay has told us are not on the tunnel, remembered briefly.
///
/// The app reconciles remote workspaces on a timer, and every poll used to
/// dial the peer again. For a machine whose tunnel was off or whose daemon
/// was down, that meant a fresh `no_such_peer` channel open per poll on the relay.
/// Inside the TTL the dial fails fast instead, with the same words, without
/// another round trip.
struct Unreachable {
    cache: HashMap<String, Absence>,
    /// Wall clock until which `no_such_peer` is not recorded. A local path
    /// change starts this so the far machine's reconnect is not a 45s floor.
    grace_until_ms: i64,
}

fn unreachable() -> &'static Mutex<Unreachable> {
    static STATE: OnceLock<Mutex<Unreachable>> = OnceLock::new();
    STATE.get_or_init(|| {
        Mutex::new(Unreachable {
            cache: HashMap::new(),
            grace_until_ms: 0,
        })
    })
}

fn begin_absence_grace() {
    if let Ok(mut state) = unreachable().lock() {
        state.grace_until_ms = jiff::Timestamp::now().as_millisecond() + ABSENCE_GRACE_MS;
    }
}

fn note_unreachable_locked(state: &mut Unreachable, peer_hex: &str) {
    if jiff::Timestamp::now().as_millisecond() < state.grace_until_ms {
        return;
    }
    // A strike only counts against an absence still inside its window. A
    // peer that was missing an hour ago and is missing again now is not on
    // its second consecutive miss, it is on its first.
    let strikes = state
        .cache
        .get(peer_hex)
        .filter(|previous| previous.worth_keeping())
        .map_or(0, |previous| previous.strikes.saturating_add(1));
    state.cache.insert(
        peer_hex.to_string(),
        Absence {
            since_ms: jiff::Timestamp::now().as_millisecond(),
            strikes,
        },
    );
}

/// Remember that the relay says this peer is not on the tunnel, and lengthen
/// the wait if it has said so before.
fn note_unreachable(peer_hex: &str) {
    if let Ok(mut state) = unreachable().lock() {
        note_unreachable_locked(&mut state, peer_hex);
    }
}

/// Forget a peer's absence. A dial that connected is proof it is back, and the
/// next failure should start from the floor rather than from where the last
/// outage left off.
fn clear_unreachable(peer_hex: &str) {
    if let Ok(mut state) = unreachable().lock() {
        state.cache.remove(peer_hex);
    }
}

/// Forget every absence. `remote.nudge` means the ground truth just changed
/// (the network came back, the machine woke), so what the relay said about a
/// peer thirty seconds ago is no longer worth trusting.
fn clear_all_unreachable() {
    if let Ok(mut state) = unreachable().lock() {
        state.cache.clear();
    }
    // The network just changed, so a LAN that was not there a moment ago may
    // be there now. Whatever was learned about direct routes was learned on
    // the old path.
    if let Ok(mut misses) = direct_misses().lock() {
        misses.clear();
    }
    if let Ok(mut offered) = offered_direct_candidates().lock() {
        offered.clear();
    }
}

/// Addresses this host can honestly offer for a direct connection right now.
///
/// Literal addresses come first because they do not depend on multicast DNS.
/// The `.local` name remains as a compatibility candidate, not the only bet.
#[cfg(feature = "local-host")]
pub(crate) fn direct_candidates() -> Vec<DirectCandidate> {
    let port = direct_port().load(Ordering::Acquire) as u16;
    if port == 0 || !direct_bound().load(Ordering::Acquire) {
        return Vec::new();
    }

    let mut candidates = local_ipv4_addresses()
        .into_iter()
        .map(|address| DirectCandidate {
            kind: "lan".into(),
            address: SocketAddr::from((address, port)).to_string(),
            priority: 100,
        })
        .collect::<Vec<_>>();

    let generation = direct_generation().load(Ordering::Acquire);
    if let Some(mapping) = direct_mapping()
        .lock()
        .ok()
        .and_then(|mapping| mapping.clone())
        .filter(|mapping| mapping.generation == generation)
    {
        candidates.push(DirectCandidate {
            kind: "mapped".into(),
            address: mapping.address.to_string(),
            priority: 80,
        });
    }

    if let Some(host) = local_mdns_hostname() {
        candidates.push(DirectCandidate {
            kind: "mdns".into(),
            address: format!("{host}.local:{port}"),
            priority: 50,
        });
    }
    candidates
}

#[cfg(not(feature = "local-host"))]
pub(crate) fn direct_candidates() -> Vec<DirectCandidate> {
    Vec::new()
}

/// Active, non-loopback IPv4 interface addresses. The listener is IPv4 today,
/// so advertising IPv6 before it owns an IPv6 socket would be a false promise.
#[cfg(all(feature = "local-host", unix))]
fn local_ipv4_addresses() -> Vec<Ipv4Addr> {
    let mut found = BTreeSet::new();
    let mut first = std::ptr::null_mut();
    // SAFETY: `getifaddrs` initializes `first` on success. Every node and
    // address is read only while the returned list is alive, and the one
    // matching `freeifaddrs` call runs before returning.
    unsafe {
        if libc::getifaddrs(&mut first) != 0 {
            return Vec::new();
        }
        let mut current = first;
        while !current.is_null() {
            let interface = &*current;
            let flags = interface.ifa_flags as u32;
            if !interface.ifa_addr.is_null()
                && flags & libc::IFF_UP as u32 != 0
                && flags & libc::IFF_LOOPBACK as u32 == 0
                && (*interface.ifa_addr).sa_family as i32 == libc::AF_INET
            {
                let address = &*(interface.ifa_addr as *const libc::sockaddr_in);
                let ip = Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr));
                if usable_direct_ipv4(ip) {
                    found.insert(ip);
                }
            }
            current = interface.ifa_next;
        }
        libc::freeifaddrs(first);
    }
    if let Some(preferred) = preferred_route_ipv4()
        && usable_direct_ipv4(preferred)
    {
        found.insert(preferred);
    }
    found.into_iter().collect()
}

/// A portable fallback for platforms where interface enumeration has not been
/// wired to the native API yet. The mDNS candidate still participates there.
#[cfg(all(feature = "local-host", not(unix)))]
fn local_ipv4_addresses() -> Vec<Ipv4Addr> {
    preferred_route_ipv4()
        .filter(|address| usable_direct_ipv4(*address))
        .into_iter()
        .collect()
}

#[cfg(feature = "local-host")]
fn preferred_route_ipv4() -> Option<Ipv4Addr> {
    // UDP connect chooses a route but sends no packet. This gives Windows and
    // other non-Unix hosts at least the address of their active interface,
    // and covers Unix systems whose interface enumeration was restricted.
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("1.1.1.1:443").ok()?;
    match socket.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(address) => Some(address),
        std::net::IpAddr::V6(_) => None,
    }
}

/// Ask an UPnP IGD router for a leased public TCP mapping. This is an
/// optimisation under Remote Reach, never a replacement for authentication:
/// the public socket still enters the same Noise responder and peer approval.
#[cfg(feature = "local-host")]
fn start_direct_mapping(generation: usize, port: u16) {
    const LEASE_SECS: u32 = 3_600;
    const RENEW_AFTER: Duration = Duration::from_secs(1_800);
    if let Err(error) = std::thread::Builder::new()
        .name("direct-mapping".into())
        .spawn(move || {
            // The renewer is the only thing keeping this mapping honest; if
            // it dies mid-renewal, advertising must stop along with it.
            struct LiveLease(usize);
            impl Drop for LiveLease {
                fn drop(&mut self) {
                    if let Ok(mut mapping) = direct_mapping().lock()
                        && mapping
                            .as_ref()
                            .is_some_and(|mapping| mapping.generation == self.0)
                    {
                        *mapping = None;
                    }
                }
            }
            let _lease = LiveLease(generation);
            let Some(local_ip) = preferred_route_ipv4() else {
                return;
            };
            let local = SocketAddr::from((local_ip, port));
            let gateway = match igd_next::search_gateway(Default::default()) {
                Ok(gateway) => gateway,
                Err(_) => return,
            };
            let external = match gateway.get_any_address(
                igd_next::PortMappingProtocol::TCP,
                local,
                LEASE_SECS,
                "tokenstat direct connection",
            ) {
                Ok(address) if usable_public_address(address) => address,
                Ok(address) => {
                    let _ = gateway.remove_port(igd_next::PortMappingProtocol::TCP, address.port());
                    return;
                }
                Err(_) => return,
            };
            if direct_generation().load(Ordering::Acquire) != generation
                || !direct_running().load(Ordering::Acquire)
            {
                let _ = gateway.remove_port(igd_next::PortMappingProtocol::TCP, external.port());
                return;
            }
            if let Ok(mut mapping) = direct_mapping().lock() {
                *mapping = Some(DirectMapping {
                    generation,
                    address: external,
                });
            }

            let mut renewed_at = Instant::now();
            while direct_generation().load(Ordering::Acquire) == generation
                && direct_running().load(Ordering::Acquire)
            {
                std::thread::sleep(Duration::from_secs(1));
                if renewed_at.elapsed() < RENEW_AFTER {
                    continue;
                }
                if gateway
                    .add_port(
                        igd_next::PortMappingProtocol::TCP,
                        external.port(),
                        local,
                        LEASE_SECS,
                        "tokenstat direct connection",
                    )
                    .is_err()
                {
                    break;
                }
                renewed_at = Instant::now();
            }
            if let Ok(mut mapping) = direct_mapping().lock()
                && mapping
                    .as_ref()
                    .is_some_and(|mapping| mapping.generation == generation)
            {
                *mapping = None;
            }
            // A listener restart while this thread sat between one-second polls
            // may have obtained the very same external port again. Give a
            // replacement a moment to publish itself, then only take the lease
            // down when nothing newer advertises that port.
            if direct_generation().load(Ordering::Acquire) != generation {
                std::thread::sleep(Duration::from_secs(3));
            }
            let reused = direct_mapping()
                .lock()
                .ok()
                .and_then(|mapping| mapping.clone())
                .is_some_and(|mapping| {
                    mapping.generation != generation && mapping.address.port() == external.port()
                });
            if !reused {
                let _ = gateway.remove_port(igd_next::PortMappingProtocol::TCP, external.port());
            }
        })
    {
        eprintln!("remote: could not start direct mapping: {error}");
    }
}

#[cfg(feature = "local-host")]
fn usable_public_address(address: SocketAddr) -> bool {
    match address.ip() {
        std::net::IpAddr::V4(ip) => {
            let octets = ip.octets();
            usable_direct_ipv4(ip)
                && octets[0] != 0
                && !ip.is_private()
                && !(octets[0] == 100 && (64..=127).contains(&octets[1]))
                && !(octets[0] == 192 && octets[1] == 0 && octets[2] <= 2)
                && !(octets[0] == 198 && (18..=19).contains(&octets[1]))
                && !(octets[0] == 198 && octets[1] == 51 && octets[2] == 100)
                && !(octets[0] == 203 && octets[1] == 0 && octets[2] == 113)
                && octets[0] < 240
        }
        // The listener is IPv4. Do not advertise an address it does not own.
        std::net::IpAddr::V6(_) => false,
    }
}

#[cfg(feature = "local-host")]
fn usable_direct_ipv4(ip: Ipv4Addr) -> bool {
    !ip.is_unspecified()
        && !ip.is_loopback()
        && !ip.is_link_local()
        && !ip.is_multicast()
        && ip != Ipv4Addr::BROADCAST
}

#[cfg(feature = "local-host")]
fn local_mdns_hostname() -> Option<String> {
    // Status polls call this often; a hostname does not change within one
    // daemon's lifetime often enough to justify asking every time.
    static HOSTNAME: OnceLock<Option<String>> = OnceLock::new();
    HOSTNAME.get_or_init(local_hostname).clone()
}

#[cfg(feature = "local-host")]
fn local_hostname() -> Option<String> {
    #[cfg(unix)]
    {
        let mut buffer = [0u8; 256];
        if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } != 0 {
            return None;
        }
        let end = buffer
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(buffer.len());
        mdns_hostname(&String::from_utf8_lossy(&buffer[..end]))
    }
    #[cfg(not(unix))]
    {
        let output = std::process::Command::new("hostname").output().ok()?;
        let host = String::from_utf8(output.stdout).ok()?;
        mdns_hostname(&host)
    }
}

#[cfg(feature = "local-host")]
fn mdns_hostname(raw: &str) -> Option<String> {
    let host = raw.trim().trim_end_matches(".local").to_string();
    (!host.is_empty()
        && host
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'-' | b'.')))
    .then_some(host)
}

/// Hold an authenticated peer's hints until the next dial. Invalid and
/// excessive entries are ignored so a peer cannot turn one response into an
/// unbounded number of connection attempts.
pub(crate) fn offer_direct_candidates(peer_hex: &str, candidates: Vec<DirectCandidate>) {
    const MAX_CANDIDATES: usize = 8;
    let mut candidates = candidates
        .into_iter()
        .filter(|candidate| {
            !candidate.address.trim().is_empty()
                && candidate.address.len() <= 255
                && direct_candidate_address_is_usable(&candidate.address)
        })
        .collect::<Vec<_>>();
    // Rank before capping, so a crowded list keeps its best routes instead of
    // whichever eight arrived first.
    candidates.sort_by_key(|candidate| std::cmp::Reverse(candidate.priority));
    let mut seen = BTreeSet::new();
    candidates.retain(|candidate| seen.insert(candidate.address.clone()));
    candidates.truncate(MAX_CANDIDATES);
    if let Ok(mut offered) = offered_direct_candidates().lock() {
        if candidates.is_empty() {
            offered.remove(peer_hex);
        } else {
            offered.insert(peer_hex.to_string(), candidates);
            // These describe the current network, learned after the old miss.
            clear_direct_miss(peer_hex);
        }
    }
}

/// Whether a candidate address may be dialled at all. Runs on everything an
/// authenticated peer offers, because a hint is not proof: a literal address
/// must be routeable to another machine, and a name must look like one. The
/// pinned Noise handshake remains the real gate; this only keeps a hint from
/// pointing sockets at this machine's own loopback or link-local space.
fn direct_candidate_address_is_usable(address: &str) -> bool {
    if let Ok(socket) = address.parse::<SocketAddr>() {
        return match socket.ip() {
            std::net::IpAddr::V4(ip) => {
                !(ip.is_unspecified()
                    || ip.is_loopback()
                    || ip.is_link_local()
                    || ip.is_multicast()
                    || ip == Ipv4Addr::BROADCAST)
            }
            std::net::IpAddr::V6(ip) => {
                !(ip.is_unspecified() || ip.is_loopback() || ip.is_multicast())
            }
        };
    }
    // Names reach here only when the string is not a bare socket literal,
    // which is exactly how `.local` candidates look.
    let Some((host, port)) = address.rsplit_once(':') else {
        return false;
    };
    host != "localhost"
        && !host.is_empty()
        && host
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.'))
        && port.parse::<u16>().is_ok()
}

fn candidates_for_peer(peer_hex: &str, remembered: Option<&str>) -> Vec<DirectCandidate> {
    let mut candidates = offered_direct_candidates()
        .lock()
        .ok()
        .and_then(|offered| offered.get(peer_hex).cloned())
        .unwrap_or_default();
    if let Some(address) = remembered
        && !candidates
            .iter()
            .any(|candidate| candidate.address == address)
    {
        candidates.push(DirectCandidate {
            kind: "remembered".into(),
            address: address.to_string(),
            priority: 110,
        });
    }
    candidates.sort_by_key(|candidate| std::cmp::Reverse(candidate.priority));
    candidates
}

/// How long a direct address is left alone after it failed.
///
/// A minute at first, doubling, capped. The remembered address is a
/// `<host>.local` name, which is exactly right on the LAN it was learned on
/// and worthless anywhere else, and it is tried first on every dial of every
/// purpose. Off that LAN each dial paid a DNS lookup and up to a two second
/// connect before the relay was asked, on calls that happen on timers.
const DIRECT_MISS_FLOOR_MS: i64 = 60_000;
const DIRECT_MISS_CEILING_MS: i64 = 600_000;

#[derive(Clone, Copy)]
struct DirectMiss {
    since_ms: i64,
    strikes: u32,
}

impl DirectMiss {
    fn age_ms(&self) -> i64 {
        jiff::Timestamp::now().as_millisecond() - self.since_ms
    }

    fn ttl_ms(&self) -> i64 {
        DIRECT_MISS_FLOOR_MS
            .saturating_mul(1i64 << self.strikes.min(4))
            .min(DIRECT_MISS_CEILING_MS)
    }

    /// Skip the direct attempt for now. Unlike an absence, the first miss
    /// counts: nothing is hidden by skipping it, because the relay is asked
    /// either way and answers for the same machine.
    fn suppresses(&self) -> bool {
        self.age_ms() < self.ttl_ms()
    }
}

/// Peers whose remembered direct address did not answer, and when.
fn direct_misses() -> &'static Mutex<HashMap<String, DirectMiss>> {
    static STATE: OnceLock<Mutex<HashMap<String, DirectMiss>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Whether the direct address is worth a try right now.
fn direct_is_worth_trying(peer_hex: &str) -> bool {
    let Ok(mut misses) = direct_misses().lock() else {
        return true;
    };
    misses.retain(|_, miss| miss.age_ms() < DIRECT_MISS_CEILING_MS);
    !misses.get(peer_hex).is_some_and(DirectMiss::suppresses)
}

fn note_direct_miss(peer_hex: &str) {
    if let Ok(mut misses) = direct_misses().lock() {
        let strikes = misses
            .get(peer_hex)
            .filter(|miss| miss.age_ms() < DIRECT_MISS_CEILING_MS)
            .map_or(0, |miss| miss.strikes.saturating_add(1));
        misses.insert(
            peer_hex.to_string(),
            DirectMiss {
                since_ms: jiff::Timestamp::now().as_millisecond(),
                strikes,
            },
        );
    }
}

fn clear_direct_miss(peer_hex: &str) {
    if let Ok(mut misses) = direct_misses().lock() {
        misses.remove(peer_hex);
    }
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
    // Held for the whole call, pooled connection included: a connection taken
    // out of the pool is as live as a freshly dialled one while it is in use.
    let _slot = LiveSlot::take(peer_hex)?;

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
    // Through the labelled one rather than beside it. The screen and stream
    // call sites are behind platform gates, so on a build where those compile
    // out the labelled dial had no callers at all and the Linux lint job
    // rejected it as dead. Routing the unlabelled case through it keeps one
    // path for every platform and means the label is the only difference.
    dial_peer_as(peer_hex, ChannelPurpose::Unknown)
}

/// The same dial, saying what the connection is for.
///
/// The label reaches the relay on the channel open. It is what lets a desktop
/// stream be metered and capped without touching a shell, so the call sites
/// that know which they are saying it is the whole point.
pub(crate) fn dial_peer_as(
    peer_hex: &str,
    purpose: ChannelPurpose,
) -> Result<tokenstat_remote::Connection, String> {
    dial_peer_for(peer_hex, purpose).map(|value| value.0)
}

/// Dial, and say which route answered and what the connection is for.
///
/// There is no purposeless variant of this any more. A channel that does not
/// name itself is metered as `unknown` and capped by nothing, which is the
/// right answer for an old client and the wrong one for a call site in this
/// binary that simply forgot.
pub(crate) fn dial_peer_for(
    peer_hex: &str,
    purpose: ChannelPurpose,
) -> Result<(tokenstat_remote::Connection, &'static str), String> {
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
    let address = peer.address.clone();
    drop(store);

    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let peer_hex = tokenstat_identity::hex(&key);
    let candidates = candidates_for_peer(&peer_hex, address.as_deref());
    let direct = if !direct_is_worth_trying(&peer_hex) {
        Err("the direct candidates did not answer recently".into())
    } else {
        dial_direct_candidates(&peer_hex, candidates, &identity, key, &label)
    };
    match direct {
        Ok((connection, address)) => {
            clear_direct_miss(&peer_hex);
            // Persistence follows proof: TCP connected and the pinned key
            // completed Noise. Merely advertising a candidate never writes it.
            let _ = remember_direct_address(&peer_hex, &address);
            Ok((connection, "direct"))
        }
        Err(error) => {
            if !candidates_for_peer(&peer_hex, address.as_deref()).is_empty() {
                note_direct_miss(&peer_hex);
            }
            tunnel_dial(&settings(), key, &identity, &label, purpose, error)
                .map(|connection| (connection, "relay"))
        }
    }
}

/// Try every candidate concurrently and take the first one that authenticates.
/// The result includes the winning address so only proven routes reach disk.
fn dial_direct_candidates(
    peer_hex: &str,
    candidates: Vec<DirectCandidate>,
    identity: &MachineIdentity,
    key: tokenstat_identity::PublicKey,
    label: &str,
) -> Result<(tokenstat_remote::Connection, String), String> {
    const ATTEMPT_TIMEOUT: Duration = Duration::from_millis(900);
    const RACE_TIMEOUT: Duration = Duration::from_millis(1_100);
    // Screen again at the dial, so even a remembered address written by an
    // older build or a stale offer cannot send a socket somewhere private.
    let mut candidates = candidates;
    candidates.retain(|candidate| direct_candidate_address_is_usable(&candidate.address));
    if candidates.is_empty() {
        return Err("no direct address".into());
    }

    let (send, receive) = std::sync::mpsc::channel();
    let secret = identity.secret_bytes();
    let attempts = candidates.len();
    for candidate in candidates {
        let send = send.clone();
        let label = label.to_string();
        std::thread::spawn(move || {
            let identity = MachineIdentity::from_secret(secret);
            let result = tokenstat_remote::dial_with_timeout(
                &candidate.address,
                &identity,
                Some(key),
                &label,
                ATTEMPT_TIMEOUT,
            );
            let _ = send.send((candidate.address, result));
        });
    }
    drop(send);

    let deadline = Instant::now() + RACE_TIMEOUT;
    let mut errors = Vec::new();
    for _ in 0..attempts {
        let Some(left) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        match receive.recv_timeout(left) {
            Ok((address, Ok(connection))) => return Ok((connection, address)),
            Ok((address, Err(error))) => errors.push(format!("{address}: {error}")),
            Err(_) => break,
        }
    }
    if errors.is_empty() {
        Err(format!(
            "no direct candidate for {peer_hex} answered in time"
        ))
    } else {
        Err(errors.join("; "))
    }
}

pub(crate) fn remember_direct_address(peer_hex: &str, address: &str) -> Result<(), String> {
    let key = public_key_from_hex(peer_hex).map_err(|e| e.to_string())?;
    let mut store = PeerStore::load().map_err(|e| e.to_string())?;
    let peer = store
        .get(&key)
        .ok_or("that machine is not in this one's peer list")?
        .clone();
    if !store.is_approved(&key) {
        return Err("that machine is not approved".into());
    }
    store.add_approved(
        &key,
        &peer.label,
        Some(address),
        &jiff::Timestamp::now().to_string(),
    );
    store.save().map_err(|e| e.to_string())
}

fn settings() -> RemoteSettings {
    load_settings()
}

/// Whether the multiplexed tunnel socket is up right now.
///
/// `pty.list` uses this to skip dialling peers while the network is gone or
/// the supervisor is still reconnecting. Waiting on those dials is what made
/// the host silent for ten seconds after a path change.
#[cfg(feature = "local-host")]
pub(crate) fn tunnel_is_connected() -> bool {
    tunnel_session()
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().map(|session| session.status().connected))
        .unwrap_or(false)
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
    purpose: ChannelPurpose,
    direct_error: impl std::fmt::Display,
) -> Result<tokenstat_remote::Connection, String> {
    if !settings.tunnel {
        return Err(format!("could not reach {label} directly: {direct_error}"));
    }
    let peer_hex = tokenstat_identity::hex(&peer);
    if unreachable()
        .lock()
        .ok()
        .and_then(|mut state| {
            state.cache.retain(|_, absence| absence.worth_keeping());
            state.cache.get(&peer_hex).copied()
        })
        .is_some_and(|absence| absence.suppresses())
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
    // A whole-ladder budget, not three independent tries. Each attempt can
    // spend ten seconds waiting for the relay to pair the channel and another
    // ten on the handshake, so three of them plus the sleeps between is a
    // minute of one thread and one of the app's connections for a machine that
    // is asleep. The retries exist for a peer whose daemon is mid-restart,
    // which comes back in a second or two, so a short overall budget keeps
    // what they are for and drops what they cost.
    let started = std::time::Instant::now();
    let mut last = String::new();
    for attempt in 0..3 {
        if attempt > 0 && started.elapsed() >= DIAL_BUDGET {
            break;
        }
        match tunnel.open_channel(peer, purpose).and_then(|channel| {
            tokenstat_remote::handshake_initiator(Box::new(channel), identity, Some(peer), label)
        }) {
            Ok(connection) => {
                clear_unreachable(&peer_hex);
                return Ok(connection);
            }
            Err(error) => {
                last = error.to_string();
                // `no_such_peer` is the relay's settled answer, not a race it
                // lost. The relay already holds an open for a key that was
                // live recently, precisely so a dial arriving mid-reconnect
                // waits rather than fails, so by the time this end hears
                // `no_such_peer` the reconnect window has already been sat
                // out. Retrying spends two more channel opens to be told the
                // same thing twice more, which is most of what a machine that
                // is simply switched off costs the relay.
                if last.contains("no_such_peer") {
                    note_unreachable(&peer_hex);
                    break;
                }
                let Some(pause) = dial_retry_pause(&last, attempt) else {
                    break;
                };
                std::thread::sleep(pause);
            }
        }
    }
    Err(format!(
        "could not reach {label} directly ({direct_error}) or through the tunnel: {last}"
    ))
}

/// How long a peer may say nothing before a forwarded call gives up.
///
/// Not a deadline on the answer: the budget resets as the frame arrives, so a
/// peer that is slow but talking is never cut off. It is there for the peer
/// that has stopped talking altogether, which on a Mac means the lid closed.
/// The relay only notices that when its keepalive fails, and until then this
/// end would hold a thread, a connection and one of the app's pool slots on a
/// machine that is asleep. Shorter than the app's own patience, so the person
/// gets "could not reach that machine" rather than a socket that went quiet.
const ANSWER_IDLE: Duration = Duration::from_secs(45);

/// How long the retry ladder in `tunnel_dial` keeps trying. See there.
const DIAL_BUDGET: Duration = Duration::from_secs(12);

/// How long to wait before dialling again, or `None` to give up.
///
/// `screen_already_open` is a teardown that has not landed yet, not a settled
/// no. The relay allows one screen channel per account, so a session being
/// replaced holds the slot until its CH_CLOSE arrives, and the viewer's dial
/// can beat it there by a second. Failing on that answer is what used to send
/// the app into its own reconnect ladder and turn one late close into a storm,
/// so it waits longer than the transport blips do: those come back inside a
/// couple of hundred milliseconds, a teardown crossing the relay does not.
fn dial_retry_pause(last: &str, attempt: u32) -> Option<Duration> {
    let handover = last.contains("screen_already_open");
    let retryable = handover
        || last.contains("not connected")
        || last.contains("closed")
        || last.contains("failed to fill whole buffer");
    if !retryable || attempt >= 2 {
        return None;
    }
    Some(Duration::from_millis(if handover {
        750
    } else {
        200 * u64::from(attempt + 1)
    }))
}

fn round_trip(
    connection: &mut tokenstat_remote::Connection,
    request: &[u8],
) -> Result<String, tokenstat_remote::RemoteError> {
    connection.send(request)?;
    let answer = connection.receive_within(MAX_MESSAGE, ANSWER_IDLE)?;
    Ok(String::from_utf8_lossy(&answer).to_string())
}

fn checkout(peer: &str) -> Option<tokenstat_remote::Connection> {
    let mut map = pool().lock().ok()?;
    reap(&mut map);
    // Not `get_mut(peer)?`: a peer nobody has dialled yet would return before
    // the empty keys the reap above left behind were dropped.
    let taken = map
        .get_mut(peer)
        .and_then(Vec::pop)
        .map(|idle| idle.connection);
    map.retain(|_, idle| !idle.is_empty());
    taken
}

fn checkin(peer: &str, connection: tokenstat_remote::Connection) {
    if let Ok(mut map) = pool().lock() {
        reap(&mut map);
        let idle = map.entry(peer.to_string()).or_default();
        if idle.len() < MAX_IDLE_PER_PEER {
            idle.push(Idle {
                connection,
                since: Instant::now(),
            });
        }
    }
}

/// Close everything that has sat unused past the timeout, and forget any peer
/// left holding nothing.
///
/// Run both on a timer, so the last connections a session leaves behind are
/// closed even if nothing ever calls that peer again, and on the way past
/// each call, which keeps a burst of traffic from letting anything idle out
/// from under the next caller.
fn reap(map: &mut HashMap<String, Vec<Idle>>) {
    let now = Instant::now();
    for idle in map.values_mut() {
        // Dropping the connection closes it.
        idle.retain(|held| now.duration_since(held.since) < POOL_IDLE_TIMEOUT);
    }
    map.retain(|_, idle| !idle.is_empty());
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
        "remote.nudge" => nudge(params),
        "remote.reconsiderPlan" => reconsider_plan(),
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
struct NudgeParams {
    /// Drop a live socket and reconnect. A path change (Wi-Fi to cellular)
    /// leaves a socket that still looks fresh: the last ping was seconds ago
    /// on the old route.
    reconnect: bool,
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
fn nudge(params: &str) -> Result<Value, String> {
    let p: NudgeParams = if params.trim().is_empty() {
        NudgeParams::default()
    } else {
        serde_json::from_str(params.trim()).unwrap_or_default()
    };
    // What the relay said about a peer a minute ago was true of a network that
    // has since changed. Every absence is forgotten here so a machine that came
    // back with this one is dialled at once rather than waiting out a backoff
    // it earned while the network was down.
    clear_all_unreachable();
    begin_absence_grace();
    // Client builds have no pty list cache. The stream stack that owns it
    // is compiled out with `local-host`.
    #[cfg(feature = "local-host")]
    crate::remote_stream::invalidate_all_pty_lists();
    // A plan refusal is off the retry loop on purpose. Foreground, wake and
    // connectivity restore must still ask again: the account may have
    // become Patron since the last mint.
    let last_was_plan = tunnel_state()
        .lock()
        .ok()
        .and_then(|state| state.error.clone())
        .is_some_and(|error| is_plan_start_error(&error));
    if last_was_plan {
        return reconsider_plan();
    }
    if let Some(session) = tunnel_session().lock().ok().and_then(|guard| guard.clone()) {
        if p.reconnect {
            session.reconnect_now();
        } else {
            session.nudge();
        }
        return Ok(json!({"nudged": true, "reconnect": p.reconnect}));
    }
    let settings = load_settings();
    if settings.tunnel
        && let Ok(session) = session_for_serving()
    {
        start_tunnel_if_enabled(session, &settings);
    }
    Ok(json!({"nudged": true, "reconnect": p.reconnect}))
}

/// Re-check the plan gate after entitlement changes.
///
/// `not_on_this_plan` stops the start retry loop so a free account does not
/// hammer the mint. After a purchase (or after `/me` shows Patron) this is
/// the one call that remints and, if the user left the switch on, brings
/// the socket up without anybody flipping it.
fn reconsider_plan() -> Result<Value, String> {
    let settings = load_settings();
    if !settings.tunnel {
        return Ok(json!({"reconsidered": true, "tunnel": false}));
    }
    // Already READY: drop a leftover plan refusal and leave the mint alone.
    // Every app launch used to remint here, which spent the hourly budget
    // replacing a credential that was working.
    if let Some(session) = tunnel_session().lock().ok().and_then(|guard| guard.clone()) {
        if session.status().connected {
            set_tunnel_state(|state| {
                state.connected = true;
                state.error = None;
            });
            return Ok(json!({"reconsidered": true, "tunnel": true, "allowed": true}));
        }
    }
    match tunnel_hello_token(true) {
        Ok((hello_token, _)) => {
            set_tunnel_state(|state| state.error = None);
            if let Some(session) = tunnel_session().lock().ok().and_then(|guard| guard.clone()) {
                session.set_token(&hello_token);
                session.nudge();
            } else if let Ok(session) = session_for_serving() {
                start_tunnel_if_enabled(session, &settings);
            }
            Ok(json!({"reconsidered": true, "tunnel": true, "allowed": true}))
        }
        Err(error) => {
            set_tunnel_state(|state| {
                state.connected = false;
                state.error = Some(error.clone());
            });
            Ok(json!({
                "reconsidered": true,
                "tunnel": true,
                "allowed": false,
                "error": error,
            }))
        }
    }
}

/// Overlay the live socket onto the last recorded start/mint state.
///
/// A successful READY must drop a stale `not_on_this_plan` (or any other
/// leftover). Merging `live.error` only when it is set used to keep a plan
/// refusal on screen after the socket had already come up.
fn merge_live_tunnel_status(
    stored: &mut TunnelState,
    live: &tokenstat_remote::tunnel::TunnelStatus,
) {
    stored.connected = live.connected;
    if live.connected {
        stored.error = None;
    } else if let Some(error) = live.error.clone() {
        stored.error = Some(error);
    }
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
        merge_live_tunnel_status(&mut tunnel_state, &session.status());
    }
    let direct_candidates = direct_candidates();
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
        // Useful for an invite as well as diagnostics. These are addresses,
        // never credentials; the receiver still authenticates the key above.
        "directCandidates": direct_candidates,
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
    crate::request_context::refuse_remote("remote serving settings")?;
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
        #[cfg(feature = "local-host")]
        stop_direct();
    }
    if settings.tunnel {
        start_tunnel_if_enabled(session_for_serving()?, &settings);
        #[cfg(feature = "local-host")]
        start_direct_if_enabled();
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
    fn a_remote_peer_cannot_change_tunnel_settings() {
        crate::request_context::with_remote_peer("phone", || {
            let refused = serve(r#"{"tunnel":false}"#).expect_err("must refuse");
            assert!(refused.contains("local-only"), "{refused}");
        });
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

    /// A mint response shaped like a real one: `expires_at` and `expires_in`
    /// describe the same moment. They have to agree, because the deadline is
    /// read from the absolute time and the lifetime is derived back out of it.
    fn test_token() -> tokenstat_sync::profile::TunnelToken {
        let ttl = 43_200;
        tokenstat_sync::profile::TunnelToken {
            token: "tsk_deadbeef_secret".into(),
            expires_at: (jiff::Timestamp::now() + Duration::from_secs(ttl)).to_string(),
            expires_in: ttl,
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
        // A range, not the exact lifetime: what comes back is measured from
        // the deadline to now, so a slow mint legitimately reports a second or
        // two less than the token was issued for.
        let left = expires.expect("a minted credential expires");
        assert!((43_195..=43_200).contains(&left), "got {left}");
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

    #[test]
    fn signed_out_is_not_retried_as_a_network_blip() {
        assert!(is_permanent_start_error(
            "sign in to tokenstat.ai before enabling remote reach"
        ));
        assert!(is_permanent_start_error(
            "remote reach is a paid-plan feature"
        ));
        assert!(is_plan_start_error(
            "could not mint a tunnel credential: not_on_this_plan"
        ));
        assert!(!is_plan_start_error(
            "sign in to tokenstat.ai before enabling remote reach"
        ));
        assert!(!is_permanent_start_error("connection refused"));
    }

    #[test]
    fn a_ready_socket_drops_a_stale_plan_error() {
        let mut stored = TunnelState {
            connected: false,
            error: Some("could not mint a tunnel credential: not_on_this_plan".into()),
            registered: true,
        };
        merge_live_tunnel_status(
            &mut stored,
            &tokenstat_remote::tunnel::TunnelStatus {
                connected: true,
                error: None,
            },
        );
        assert!(stored.connected);
        assert_eq!(stored.error, None);

        stored.error = Some("stale".into());
        merge_live_tunnel_status(
            &mut stored,
            &tokenstat_remote::tunnel::TunnelStatus {
                connected: false,
                error: Some("connection refused".into()),
            },
        );
        assert!(!stored.connected);
        assert_eq!(stored.error.as_deref(), Some("connection refused"));
    }

    /// The floor has to outlast the app's own retry for the cache to suppress
    /// anything at all. It used to be shorter, so every scheduled re-dial found
    /// the entry expired and spent a channel open learning what the relay had
    /// already said.
    #[test]
    fn an_absence_outlasts_the_apps_retry_and_then_lengthens() {
        let now = jiff::Timestamp::now().as_millisecond();
        let first = Absence {
            since_ms: now,
            strikes: 0,
        };
        assert!(
            first.ttl_ms() >= 30_000,
            "the floor must outlast the 30s peer retry, got {}",
            first.ttl_ms()
        );
        let second = Absence {
            since_ms: now,
            strikes: 1,
        };
        assert!(second.ttl_ms() > first.ttl_ms());
    }

    /// A machine that has been off all day must not become invisible for
    /// longer than the ceiling: that is how long it stays missing after it
    /// comes back, for anybody who did not nudge.
    #[test]
    fn an_absence_never_grows_past_the_ceiling() {
        let now = jiff::Timestamp::now().as_millisecond();
        for strikes in [0u32, 1, 2, 3, 4, 40, u32::MAX] {
            let absence = Absence {
                since_ms: now,
                strikes,
            };
            assert!(
                absence.ttl_ms() <= UNREACHABLE_CEILING_MS,
                "{strikes} strikes gave {}",
                absence.ttl_ms()
            );
        }
    }

    /// The first `no_such_peer` buys nothing. A dial can land between a peer's
    /// daemon starting and its HELLO registering, and suppressing on that one
    /// answer hides a machine that is already back.
    #[test]
    fn one_miss_does_not_hide_a_peer_that_is_coming_back() {
        let now = jiff::Timestamp::now().as_millisecond();
        assert!(
            !Absence {
                since_ms: now,
                strikes: 0
            }
            .suppresses()
        );
        assert!(
            Absence {
                since_ms: now,
                strikes: 1
            }
            .suppresses()
        );
    }

    /// A confirmed absence stops suppressing once its wait is served, so a
    /// machine that came back is found again without anybody nudging.
    #[test]
    fn an_absence_expires() {
        let long_ago = jiff::Timestamp::now().as_millisecond() - UNREACHABLE_CEILING_MS - 1;
        let stale = Absence {
            since_ms: long_ago,
            strikes: 1,
        };
        assert!(!stale.suppresses());
        assert!(!stale.worth_keeping());
    }

    /// A dial that connected is proof the peer is back, so the next outage
    /// starts counting from the floor rather than from where the last one
    /// stopped.
    #[test]
    fn connecting_forgets_an_absence() {
        let peer = "cd".repeat(32);
        let mut state = unreachable().lock().unwrap();
        state.grace_until_ms = 0;
        state.cache.clear();
        note_unreachable_locked(&mut state, &peer);
        note_unreachable_locked(&mut state, &peer);
        assert!(state.cache[&peer].suppresses());
        state.cache.remove(&peer);
        assert!(!state.cache.contains_key(&peer));
        note_unreachable_locked(&mut state, &peer);
        assert_eq!(state.cache[&peer].strikes, 0, "a cleared peer starts over");
        state.cache.clear();
    }

    /// A local path change must not start the 45s floor on the first miss:
    /// that miss is the far machine reconnecting, and the phone retries at
    /// 1/2/4s inside this window.
    #[test]
    fn a_nudge_opens_a_grace_before_absences_count() {
        let peer = "ab".repeat(32);
        let mut state = unreachable().lock().unwrap();
        state.cache.clear();
        state.grace_until_ms = jiff::Timestamp::now().as_millisecond() + ABSENCE_GRACE_MS;
        note_unreachable_locked(&mut state, &peer);
        note_unreachable_locked(&mut state, &peer);
        assert!(
            !state.cache.contains_key(&peer),
            "grace swallows the first misses after a path change"
        );
        state.grace_until_ms = 0;
        note_unreachable_locked(&mut state, &peer);
        assert_eq!(state.cache[&peer].strikes, 0);
        state.cache.clear();
    }

    #[test]
    fn stopping_remote_reach_clears_the_held_credential() {
        let in_an_hour = (jiff::Timestamp::now() + Duration::from_secs(3600)).as_millisecond();
        hold_credential("tsk_old_account_secret", Some(in_an_hour));
        clear_held_credential();
        assert!(held_credential().lock().unwrap().is_none());
    }

    /// The deadline comes from the account's own absolute time, because that
    /// is the value the relay compares against. Deriving it from `expires_in`
    /// starts the clock when the answer arrived rather than when it was
    /// issued, which hands back a term slightly longer than the one the relay
    /// will honour.
    #[test]
    fn the_deadline_is_the_time_the_account_issued() {
        let token = tokenstat_sync::profile::TunnelToken {
            expires_at: "2030-01-01T00:00:00Z".into(),
            ..test_token()
        };
        let expected = "2030-01-01T00:00:00Z"
            .parse::<jiff::Timestamp>()
            .expect("a timestamp")
            .as_millisecond();
        assert_eq!(credential_deadline_ms(&token), expected);
    }

    /// A response whose timestamp will not parse is a server contract change,
    /// not a reason to leave the machine without remote reach. `expires_in`
    /// carries it.
    #[test]
    fn an_unparsable_expiry_falls_back_to_the_lifetime() {
        let token = tokenstat_sync::profile::TunnelToken {
            expires_at: "whenever".into(),
            expires_in: 600,
            ..test_token()
        };
        let left = seconds_left(credential_deadline_ms(&token)).expect("a live credential");
        assert!((595..=600).contains(&left), "got {left}");
    }

    /// A deadline that has passed is not "a very small amount of time left".
    /// Reporting seconds there would let a dead credential look refreshable.
    #[test]
    fn a_passed_deadline_has_no_time_left() {
        let a_minute_ago = jiff::Timestamp::now().as_millisecond() - 60_000;
        assert_eq!(seconds_left(a_minute_ago), None);
    }

    /// The reason this is measured on the calendar at all: a Mac that slept
    /// through most of a credential's term must read as nearly expired, not as
    /// nearly fresh. A held credential inside the refresh margin is re-minted
    /// rather than handed back.
    #[test]
    fn a_credential_inside_the_margin_is_not_reused() {
        let nearly_up = (jiff::Timestamp::now()
            + Duration::from_secs(CREDENTIAL_REFRESH_MARGIN.as_secs() / 2))
        .as_millisecond();
        assert!(
            seconds_left(nearly_up).is_some_and(|left| left <= CREDENTIAL_REFRESH_MARGIN.as_secs()),
            "a credential this close to expiry must not satisfy the cache check"
        );
        clear_held_credential();
    }

    #[test]
    fn a_screen_handover_is_retried_and_a_settled_refusal_is_not() {
        // The relay's answer while the previous channel is still closing.
        assert_eq!(
            dial_retry_pause("channel error: screen_already_open", 0),
            Some(Duration::from_millis(750)),
            "a handover has to wait for the old close to land"
        );
        // A transport blip comes back sooner than a teardown crosses the relay.
        assert_eq!(
            dial_retry_pause("tunnel not connected", 0),
            Some(Duration::from_millis(200))
        );
        // Nothing is retried past the ladder, and a refusal that means what it
        // says is not retried at all.
        assert_eq!(
            dial_retry_pause("channel error: screen_already_open", 2),
            None
        );
        assert_eq!(
            dial_retry_pause("channel error: over_monthly_limit", 0),
            None
        );
    }

    #[test]
    fn a_direct_address_that_missed_is_left_alone_and_a_success_forgives_it() {
        let peer = "direct-miss-test-peer";
        clear_direct_miss(peer);
        assert!(direct_is_worth_trying(peer), "an unknown peer is tried");
        note_direct_miss(peer);
        assert!(
            !direct_is_worth_trying(peer),
            "a remembered address that just failed must not be dialled on every call"
        );
        clear_direct_miss(peer);
        assert!(
            direct_is_worth_trying(peer),
            "a direct dial that worked forgives the misses before it"
        );
    }

    #[test]
    fn a_direct_miss_backs_off_but_stays_bounded() {
        let miss = DirectMiss {
            since_ms: jiff::Timestamp::now().as_millisecond(),
            strikes: 0,
        };
        assert_eq!(miss.ttl_ms(), DIRECT_MISS_FLOOR_MS);
        for strikes in 0..8u32 {
            let miss = DirectMiss {
                since_ms: jiff::Timestamp::now().as_millisecond(),
                strikes,
            };
            assert!(
                miss.ttl_ms() <= DIRECT_MISS_CEILING_MS,
                "{strikes} strikes gave {}",
                miss.ttl_ms()
            );
        }
    }

    #[test]
    fn direct_candidates_reject_addresses_that_cannot_reach_a_peer() {
        assert!(!usable_direct_ipv4(Ipv4Addr::UNSPECIFIED));
        assert!(!usable_direct_ipv4(Ipv4Addr::LOCALHOST));
        assert!(!usable_direct_ipv4(Ipv4Addr::new(169, 254, 4, 2)));
        assert!(!usable_direct_ipv4(Ipv4Addr::new(224, 0, 0, 1)));
        assert!(!usable_direct_ipv4(Ipv4Addr::BROADCAST));
        assert!(usable_direct_ipv4(Ipv4Addr::new(192, 168, 0, 102)));
        assert!(usable_direct_ipv4(Ipv4Addr::new(10, 2, 3, 4)));
    }

    #[test]
    fn router_mapping_candidates_must_be_public_ipv4() {
        let at = |octets| SocketAddr::from((Ipv4Addr::from(octets), 42_000));
        assert!(!usable_public_address(at([192, 168, 1, 2])));
        assert!(!usable_public_address(at([0, 1, 2, 3])));
        assert!(!usable_public_address(at([100, 64, 1, 2])));
        assert!(!usable_public_address(at([192, 0, 2, 1])));
        assert!(!usable_public_address(at([198, 18, 1, 1])));
        assert!(!usable_public_address(at([198, 51, 100, 1])));
        assert!(!usable_public_address(at([203, 0, 113, 1])));
        assert!(!usable_public_address(at([240, 0, 0, 1])));
        assert!(usable_public_address(at([8, 8, 8, 8])));
    }

    #[test]
    fn offered_candidates_are_bounded_deduplicated_and_prioritized() {
        let peer = "candidate-contract-test";
        let mut offered = (0..12)
            .map(|index| DirectCandidate {
                kind: "lan".into(),
                address: format!("192.168.1.{}:7878", index + 1),
                priority: index,
            })
            .collect::<Vec<_>>();
        offered.push(DirectCandidate {
            kind: "duplicate".into(),
            address: "192.168.1.1:7878".into(),
            priority: u16::MAX,
        });
        offer_direct_candidates(peer, offered);
        let candidates = candidates_for_peer(peer, None);
        assert_eq!(candidates.len(), 8, "one peer gets a bounded dial fanout");
        assert!(
            candidates
                .windows(2)
                .all(|pair| pair[0].priority >= pair[1].priority),
            "higher-priority routes are attempted first"
        );
        assert_eq!(
            candidates
                .iter()
                .filter(|candidate| candidate.address == "192.168.1.1:7878")
                .count(),
            1,
            "the same socket is never dialled twice"
        );
        offer_direct_candidates(peer, Vec::new());
    }

    #[test]
    fn offered_candidates_rank_before_the_cap() {
        let peer = "rank-before-cap-test";
        let mut offered = (0..9)
            .map(|index| DirectCandidate {
                kind: "lan".into(),
                address: format!("192.168.60.{}:7878", index + 1),
                priority: 0,
            })
            .collect::<Vec<_>>();
        offered.push(DirectCandidate {
            kind: "lan".into(),
            address: "192.168.60.99:7878".into(),
            priority: u16::MAX,
        });
        offer_direct_candidates(peer, offered);
        let candidates = candidates_for_peer(peer, None);
        assert_eq!(
            candidates.first().map(|best| best.address.as_str()),
            Some("192.168.60.99:7878"),
            "the best route survives even when it arrived last"
        );
        assert_eq!(candidates.len(), 8);
        offer_direct_candidates(peer, Vec::new());
    }

    #[test]
    fn offered_candidate_addresses_are_screened_before_any_dial() {
        let peer = "screened-offers-test";
        let rejected = [
            "127.0.0.1:8080",
            "169.254.169.254:80",
            "0.0.0.0:1",
            "[::1]:9000",
            "localhost:22",
            "not a host",
            ":500",
        ];
        let accepted = ["192.168.0.102:7878", "desk-mac.local:7878"];
        let offered = rejected
            .iter()
            .chain(accepted.iter())
            .map(|address| DirectCandidate {
                kind: "lan".into(),
                address: (*address).to_string(),
                priority: 10,
            })
            .collect();
        offer_direct_candidates(peer, offered);
        let candidates = candidates_for_peer(peer, None)
            .into_iter()
            .map(|candidate| candidate.address)
            .collect::<Vec<_>>();
        assert_eq!(
            candidates,
            vec!["192.168.0.102:7878", "desk-mac.local:7878"]
        );
        offer_direct_candidates(peer, Vec::new());
    }
}
