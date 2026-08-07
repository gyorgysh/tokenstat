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
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokenstat_identity::{MachineIdentity, PeerStore, Trust, public_key_from_hex};
use tokenstat_remote::{DEFAULT_PORT, Refused, Server, authorize};

use crate::session::Session;

/// A response is bounded so a peer cannot ask this end to allocate without
/// limit. 64 MB is far above any real answer (the largest is a file's text)
/// and far below anything that hurts.
const MAX_MESSAGE: usize = 64 * 1024 * 1024;

// MARK: - Settings

/// What the user chose about serving. Persisted, because a daemon under
/// launchd restarts and must come back the way they left it, not the way it
/// ships.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteSettings {
    /// Off by default. The whole design rests on this being a decision.
    #[serde(default)]
    pub serving: bool,
    #[serde(default = "default_port")]
    pub port: u16,
    /// Off by default because a tunnel carries terminal output and file data.
    #[serde(default)]
    pub tunnel: bool,
    #[serde(default = "default_tunnel_endpoint")]
    pub tunnel_endpoint: String,
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

fn default_tunnel_endpoint() -> String {
    "wss://tunnel.tokenstat.ai".into()
}

impl Default for RemoteSettings {
    fn default() -> Self {
        Self {
            serving: false,
            port: DEFAULT_PORT,
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

// MARK: - The listener

struct Listening {
    address: String,
    stop: Arc<AtomicBool>,
}

#[cfg(target_os = "macos")]
mod bonjour {
    use std::ffi::c_void;
    use std::os::fd::RawFd;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    type DNSServiceRef = *mut c_void;
    type DNSServiceErrorType = i32;
    type DNSServiceFlags = u32;

    const K_DNS_SERVICE_ERR_NO_ERROR: DNSServiceErrorType = 0;
    const K_DNS_SERVICE_FLAGS_NONE: DNSServiceFlags = 0;
    const K_DNS_SERVICE_INTERFACE_INDEX_ANY: u32 = 0;
    const POLLIN: i16 = 0x0001;

    #[repr(C)]
    struct PollFd {
        fd: RawFd,
        events: i16,
        revents: i16,
    }

    type RegisterCallback = unsafe extern "C" fn(
        DNSServiceRef,
        DNSServiceFlags,
        DNSServiceErrorType,
        *const i8,
        *const i8,
        *const i8,
        *mut c_void,
    );

    unsafe extern "C" {
        fn DNSServiceRegister(
            service_ref: *mut DNSServiceRef,
            flags: DNSServiceFlags,
            interface_index: u32,
            name: *const i8,
            reg_type: *const i8,
            domain: *const i8,
            host: *const i8,
            port: u16,
            txt_len: u16,
            txt_record: *const u8,
            callback: Option<RegisterCallback>,
            context: *mut c_void,
        ) -> DNSServiceErrorType;
        fn DNSServiceRefSockFD(service_ref: DNSServiceRef) -> RawFd;
        fn DNSServiceProcessResult(service_ref: DNSServiceRef) -> DNSServiceErrorType;
        fn DNSServiceRefDeallocate(service_ref: DNSServiceRef);
        fn poll(fds: *mut PollFd, count: usize, timeout: i32) -> i32;
    }

    /// Owns the DNS-SD connection and removes the service when dropped.
    pub(super) struct Advertisement {
        stop: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    // Registration errors are handled by the daemon's DNS-SD connection thread.
    unsafe extern "C" fn registered(
        _service: DNSServiceRef,
        _flags: DNSServiceFlags,
        _error: DNSServiceErrorType,
        _name: *const i8,
        _reg_type: *const i8,
        _domain: *const i8,
        _context: *mut c_void,
    ) {
    }

    pub(super) fn advertise(
        port: u16,
        key: &str,
        fingerprint: &str,
        words: &str,
        label: &str,
        serving: bool,
    ) -> Result<Advertisement, String> {
        let txt = txt_record(key, fingerprint, words, label, serving)?;
        let service_type = b"_tokenstat._tcp\0";
        let mut service = std::ptr::null_mut();
        let error = unsafe {
            DNSServiceRegister(
                &mut service,
                K_DNS_SERVICE_FLAGS_NONE,
                K_DNS_SERVICE_INTERFACE_INDEX_ANY,
                std::ptr::null(),
                service_type.as_ptr().cast(),
                std::ptr::null(),
                std::ptr::null(),
                port.to_be(),
                txt.len() as u16,
                txt.as_ptr(),
                Some(registered),
                std::ptr::null_mut(),
            )
        };
        if error != K_DNS_SERVICE_ERR_NO_ERROR || service.is_null() {
            return Err(format!("DNSServiceRegister failed with error {error}"));
        }

        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        // Raw pointers do not carry a useful Rust ownership story across the
        // thread boundary. The DNS-SD reference remains owned by that thread.
        let service = service as usize;
        let thread = std::thread::spawn(move || {
            let service = service as DNSServiceRef;
            let fd = unsafe { DNSServiceRefSockFD(service) };
            while !thread_stop.load(Ordering::Relaxed) {
                if fd < 0 {
                    break;
                }
                let mut poll_fd = PollFd {
                    fd,
                    events: POLLIN,
                    revents: 0,
                };
                // The timeout gives Drop a bounded path to DNSServiceRefDeallocate.
                let ready = unsafe { poll(&mut poll_fd, 1, 100) };
                if thread_stop.load(Ordering::Relaxed) {
                    break;
                }
                if ready <= 0 || poll_fd.revents & POLLIN == 0 {
                    continue;
                }
                let result = unsafe { DNSServiceProcessResult(service) };
                if result != K_DNS_SERVICE_ERR_NO_ERROR {
                    break;
                }
            }
            unsafe { DNSServiceRefDeallocate(service) };
        });

        Ok(Advertisement {
            stop,
            thread: Some(thread),
        })
    }

    fn txt_record(
        key: &str,
        fingerprint: &str,
        words: &str,
        label: &str,
        serving: bool,
    ) -> Result<Vec<u8>, String> {
        let mut record = Vec::new();
        // The words travel with the advertisement so a machine found nearby can
        // be named the same way on both screens without the finder having to
        // hash anything.
        for (name, value) in [
            ("key", key),
            ("fingerprint", fingerprint),
            ("words", words),
            ("label", label),
            ("serving", if serving { "1" } else { "0" }),
        ] {
            let entry = format!("{name}={value}");
            if entry.len() > u8::MAX as usize {
                return Err(format!("Bonjour TXT entry {name} is too long"));
            }
            record.push(entry.len() as u8);
            record.extend_from_slice(entry.as_bytes());
        }
        Ok(record)
    }

    impl Drop for Advertisement {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn txt_record_contains_the_identity_fields() {
            let record = txt_record("key", "fingerprint", "words", "label", true).unwrap();
            assert_eq!(
                record,
                b"\x07key=key\x17fingerprint=fingerprint\x0bwords=words\x0blabel=label\x09serving=1"
            );
        }

        #[test]
        fn dns_service_port_is_encoded_in_network_order() {
            assert_eq!(1234u16.to_be_bytes(), [4, 210]);
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod bonjour {
    pub(super) struct Advertisement;

    pub(super) fn advertise(
        _port: u16,
        _key: &str,
        _fingerprint: &str,
        _words: &str,
        _label: &str,
        _serving: bool,
    ) -> Result<Advertisement, String> {
        Ok(Advertisement)
    }
}

fn listening() -> &'static Mutex<Option<Listening>> {
    static LISTENING: OnceLock<Mutex<Option<Listening>>> = OnceLock::new();
    LISTENING.get_or_init(|| Mutex::new(None))
}

/// The currently registered Bonjour advertisement, whether or not the daemon
/// is serving. The daemon advertises whenever it runs so machines show up on
/// nearby screens immediately; the `serving` flag in the record is what tells
/// the other side whether Connect can work yet.
fn advertisement_slot() -> &'static Mutex<Option<bonjour::Advertisement>> {
    static SLOT: OnceLock<Mutex<Option<bonjour::Advertisement>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

fn set_advertisement(advertisement: Option<bonjour::Advertisement>) {
    if let Ok(mut slot) = advertisement_slot().lock() {
        *slot = advertisement;
    }
}

fn tunnel_running() -> &'static AtomicBool {
    static RUNNING: AtomicBool = AtomicBool::new(false);
    &RUNNING
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
/// Registered by the daemon, and by nothing else. The in-process bridge inside
/// the app deliberately never registers one, so `remote.serve` there fails with
/// words rather than opening a port owned by a window: a machine other machines
/// depend on must not stop serving because somebody quit an app.
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
    registered_session()
        .lock()
        .map_err(|e| e.to_string())?
        .clone()
        .ok_or_else(|| {
            "serving other machines needs the tokenstat host daemon. \
             Install it with scripts/install-host-agent.sh."
                .to_string()
        })
}

/// Start serving, if the user turned it on. Called once at daemon start.
pub fn start_if_enabled(session: Arc<Mutex<Session>>) {
    register_session(Arc::clone(&session));
    let settings = load_settings();
    if settings.serving {
        if let Err(e) = start(Arc::clone(&session), settings.port) {
            // Not fatal. A machine whose port is taken still has to serve its own
            // window, and the Machines screen will show that serving is off.
            eprintln!("remote: could not listen on port {}: {e}", settings.port);
        }
    } else {
        // Advertise anyway, marked as not serving. Finding machines is the
        // point of the screen, and a list that stays empty until every other
        // machine happens to be linking reads as broken. The flag stops a
        // Connect from being offered against a daemon that would refuse it.
        if let Ok(identity) = MachineIdentity::load_or_create() {
            match bonjour::advertise(
                0,
                &identity.public_key_hex(),
                &identity.fingerprint(),
                &tokenstat_identity::key_words(&identity.public_key()),
                &tokenstat_identity::machine_label(),
                false,
            ) {
                Ok(advertisement) => set_advertisement(Some(advertisement)),
                Err(e) => eprintln!("remote: could not advertise over Bonjour: {e}"),
            }
        }
    }
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

fn start_tunnel_if_enabled(session: Arc<Mutex<Session>>, settings: &RemoteSettings) {
    if !settings.tunnel {
        return;
    }
    if tunnel_running()
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }
    let endpoint = settings.tunnel_endpoint.clone();
    let registered_settings = settings.clone();
    let token = match account_token() {
        Ok(token) => token,
        Err(error) => {
            eprintln!("remote: tunnel is enabled but unavailable: {error}");
            tunnel_running().store(false, Ordering::Release);
            return;
        }
    };
    let identity = match MachineIdentity::load_or_create() {
        Ok(identity) => identity,
        Err(error) => {
            eprintln!("remote: tunnel identity unavailable: {error}");
            tunnel_running().store(false, Ordering::Release);
            return;
        }
    };
    std::thread::spawn(move || {
        register_with_account(&registered_settings);
        while tunnel_running().load(Ordering::Acquire) {
            match tokenstat_remote::tunnel::listen(&endpoint, &identity, &token) {
                Ok(connection) => {
                    set_tunnel_state(|state| {
                        state.connected = true;
                        state.error = None;
                    });
                    // The account directory may have missed this machine while
                    // it was away; a reconnect is the moment to make sure the
                    // other screens see it. Cheap, and a failure only lowers
                    // the `registered` flag rather than dropping the socket.
                    register_with_account(&registered_settings);
                    match authorize(connection, "tunnel") {
                        // Served inline, not on a spawned thread like the TCP
                        // accept loop. The tunnel gives a machine one socket;
                        // pairing it with a peer is what that socket *is*, so
                        // re-listening before the session ends would open a
                        // second socket for the same key and be denied
                        // key_already_live by the relay. The loop comes back
                        // to `listen` only after this session is over.
                        Ok(connection) => serve_peer(connection, &session),
                        Err(refused) => report(&refused),
                    }
                }
                Err(error) => {
                    set_tunnel_state(|state| {
                        state.connected = false;
                        state.error = Some(error.to_string());
                    });
                    eprintln!("remote: tunnel connection failed: {error}");
                    std::thread::sleep(std::time::Duration::from_secs(5));
                }
            }
        }
        tunnel_running().store(false, Ordering::Release);
    });
}

fn stop_tunnel() {
    tunnel_running().store(false, Ordering::Release);
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
        tokenstat_sync::profile::register_machine_identity(
            None,
            &machine_id,
            &identity.public_key_hex(),
            &tokenstat_identity::machine_label(),
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
/// the other screens. A no-op when remote reach is off.
pub(crate) fn register_if_tunnel_enabled() {
    let settings = load_settings();
    if !settings.tunnel {
        return;
    }
    std::thread::spawn(move || register_with_account(&settings));
}

/// Bind the preferred port, or any free one.
///
/// A port in use is not a reason to stop serving. Nothing about this protocol
/// needs a fixed number: machines on the network learn the port from the
/// advertisement, and a machine reached from elsewhere learns it from the
/// pairing code, so the port is a detail the software carries rather than a
/// setting a person maintains. Refusing to start because 7878 was taken made
/// somebody debug a port conflict to use their own two computers.
///
/// The preference is still tried first, so a person who did open a port in
/// their router keeps getting the one they opened.
fn bind_any(preferred: u16, identity: &MachineIdentity) -> Result<Server, String> {
    match Server::bind(&format!("0.0.0.0:{preferred}"), identity) {
        Ok(server) => Ok(server),
        Err(first) => {
            // Port 0 asks the operating system for whatever is free, which is
            // what every peer-to-peer application does and the reason they do
            // not have port settings.
            Server::bind("0.0.0.0:0", identity).map_err(|any| {
                format!(
                    "could not listen on port {preferred} ({first}), nor on any free port: {any}"
                )
            })
        }
    }
}

/// Bind and accept in a background thread.
pub fn start(session: Arc<Mutex<Session>>, port: u16) -> Result<String, String> {
    let mut guard = listening().lock().map_err(|e| e.to_string())?;
    if let Some(existing) = guard.as_ref() {
        return Ok(existing.address.clone());
    }

    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    // All interfaces, because the point is another machine. Which machines may
    // then be served is the peer store's question, not the bind address's: an
    // address is not an authorization and treating it as one is how "it is only
    // on the LAN" becomes a security model.
    let server = bind_any(port, &identity)?;
    let address = server.local_address().map_err(|e| e.to_string())?;
    let advertised_port = address
        .rsplit(':')
        .next()
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| format!("could not determine the listener port from {address}"))?;
    let advertisement = bonjour::advertise(
        advertised_port,
        &identity.public_key_hex(),
        &identity.fingerprint(),
        &tokenstat_identity::key_words(&identity.public_key()),
        &tokenstat_identity::machine_label(),
        true,
    )
    .map_err(|e| format!("could not advertise over Bonjour: {e}"))?;
    set_advertisement(Some(advertisement));

    let stop = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&stop);
    std::thread::spawn(move || {
        loop {
            match server.accept() {
                Ok(Ok(connection)) => {
                    if flag.load(Ordering::Relaxed) {
                        break;
                    }
                    let session = Arc::clone(&session);
                    // One thread per peer, for the same reason the unix socket
                    // uses one: a peer running a scan must not stop another
                    // peer connecting.
                    std::thread::spawn(move || serve_peer(connection, &session));
                }
                Ok(Err(refused)) => {
                    if flag.load(Ordering::Relaxed) {
                        break;
                    }
                    report(&refused);
                }
                Err(e) => {
                    if flag.load(Ordering::Relaxed) {
                        break;
                    }
                    eprintln!("remote: accept failed: {e}");
                }
            }
        }
    });

    *guard = Some(Listening {
        address: address.clone(),
        stop,
    });
    Ok(address)
}

/// Advertise this machine again, under whatever it is now called.
///
/// The name goes into the Bonjour record at the moment serving starts, so a
/// machine renamed while it is serving would keep introducing itself as the old
/// one on every nearby screen. Only the advertisement is replaced: the listener,
/// the port and the key are untouched, so nothing that is connected notices.
///
/// A no-op when not serving, because there is then nothing advertising a stale
/// name.
pub(crate) fn readvertise() -> Result<(), String> {
    let mut guard = listening().lock().map_err(|e| e.to_string())?;
    let Some(current) = guard.as_mut() else {
        return Ok(());
    };
    let Some(port) = current
        .address
        .rsplit(':')
        .next()
        .and_then(|value| value.parse::<u16>().ok())
    else {
        return Ok(());
    };
    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let fresh = bonjour::advertise(
        port,
        &identity.public_key_hex(),
        &identity.fingerprint(),
        &tokenstat_identity::key_words(&identity.public_key()),
        &tokenstat_identity::machine_label(),
        true,
    )
    .map_err(|e| format!("could not advertise over Bonjour: {e}"))?;
    set_advertisement(Some(fresh));
    Ok(())
}

/// Stop serving. The accept loop is blocked in `accept`, so it is woken by a
/// connection from this process rather than by a signal: there is no portable
/// way to interrupt a blocking accept, and a listener dropped underneath a
/// thread is worse than one that is asked to leave.
pub fn stop() -> Result<(), String> {
    let mut guard = listening().lock().map_err(|e| e.to_string())?;
    let Some(current) = guard.take() else {
        return Ok(());
    };
    set_advertisement(None);
    current.stop.store(true, Ordering::Relaxed);
    // The bind address is 0.0.0.0; connect to the loopback on the same port.
    if let Some(port) = current.address.rsplit(':').next() {
        let _ = TcpStream::connect(format!("127.0.0.1:{port}"));
    }
    Ok(())
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
    let address = peer.address.clone();
    let label = peer.label.clone();
    drop(store);

    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    match address.as_deref() {
        Some(address) => match tokenstat_remote::dial(address, &identity, Some(key), &label) {
            Ok(connection) => Ok(connection),
            Err(direct_error) => tunnel_dial(&settings(), key, &identity, &label, direct_error),
        },
        None => tunnel_dial(&settings(), key, &identity, &label, "no direct address"),
    }
}

fn settings() -> RemoteSettings {
    load_settings()
}

/// Peers this machine may dial right now: approved, and reachable either
/// directly (an address on the record) or through the tunnel when remote reach
/// is on. The same rule the app's sidebar applies, so sweeps like `pty.list`
/// that want "all the machines" see exactly the machines they can reach.
pub(crate) fn reachable_peers() -> Vec<String> {
    let Ok(store) = PeerStore::load() else {
        return Vec::new();
    };
    let tunnel = load_settings().tunnel;
    store
        .list()
        .into_iter()
        .filter(|peer| {
            peer.trust == Trust::Approved
                && (!peer.address.as_deref().unwrap_or_default().is_empty() || tunnel)
        })
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
    let token = account_token()?;
    // The target's listener can be mid-reconnect (its daemon restarted, or it
    // just finished serving another session), which the relay answers with
    // NOPEER, or the pairing can drop before the answer arrives. All of those
    // are transient, so a few short retries ride over them instead of showing
    // a failure that resolved itself a second later.
    let mut last = String::new();
    for attempt in 0..3 {
        match tokenstat_remote::tunnel::dial(
            &settings.tunnel_endpoint,
            peer,
            identity,
            Some(peer),
            &token,
        ) {
            Ok(connection) => return Ok(connection),
            Err(error) => {
                last = error.to_string();
                let retryable = last.contains("NOPEER")
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

fn status() -> Result<Value, String> {
    let settings = load_settings();
    let address = listening()
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().map(|l| l.address.clone()));
    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let tunnel_state = tunnel_state().lock().map_err(|e| e.to_string())?.clone();
    Ok(json!({
        // What the user chose, and what is actually true. They differ when a
        // port is taken, and a screen that showed only the setting would say
        // "serving" about a daemon that is not.
        "serving": settings.serving,
        "tunnel": settings.tunnel,
        // What the tunnel is actually doing: the toggle can be on while the
        // daemon is being refused (plan gate, revoked token, endpoint down),
        // and a screen that cannot tell the difference will offer a Connect
        // that can never work.
        "tunnelOnline": tunnel_state.connected,
        "tunnelRegistered": tunnel_state.registered,
        "tunnelError": tunnel_state.error,
        "listening": address.is_some(),
        // The port actually bound, which is not always the one asked for: a
        // taken port falls back to any free one rather than refusing to serve.
        // Reporting the preference here would have the details panel name a
        // port nothing is listening on.
        "port": address
            .as_ref()
            .and_then(|a| a.rsplit(':').next())
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(settings.port),
        "address": address,
        "key": identity.public_key_hex(),
        "fingerprint": identity.fingerprint(),
        // The check a person will actually perform. See
        // `tokenstat_identity::key_words`: same key, said in a way somebody
        // reads aloud instead of skimming.
        "words": tokenstat_identity::key_words(&identity.public_key()),
        "label": tokenstat_identity::machine_label(),
    }))
}

fn serve(params: &str) -> Result<Value, String> {
    let p: ServeParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let mut settings = load_settings();
    if let Some(port) = p.port {
        settings.port = port;
    }
    if let Some(tunnel) = p.tunnel {
        settings.tunnel = tunnel;
    }
    if let Some(endpoint) = p.tunnel_endpoint {
        settings.tunnel_endpoint = endpoint;
    }
    settings.serving = p.enable;
    save_settings(&settings)?;
    if p.tunnel == Some(false) {
        stop_tunnel();
    }

    if p.enable {
        // Restart rather than ignore, so changing the port takes effect now
        // instead of at the next daemon start.
        stop()?;
        let address = start(session_for_serving()?, settings.port)?;
        if settings.tunnel {
            start_tunnel_if_enabled(session_for_serving()?, &settings);
        }
        Ok(json!({"serving": true, "tunnel": settings.tunnel, "address": address}))
    } else {
        stop()?;
        if p.tunnel == Some(true) {
            start_tunnel_if_enabled(session_for_serving()?, &settings);
        }
        Ok(json!({"serving": false, "tunnel": settings.tunnel, "address": Value::Null}))
    }
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

    /// A port conflict is somebody else's software, not a reason to stop
    /// somebody using their own two computers.
    #[test]
    fn a_taken_port_falls_back_to_a_free_one() {
        let identity = MachineIdentity::from_secret([9u8; 32]);
        let squatter = std::net::TcpListener::bind("0.0.0.0:0").expect("a port to squat on");
        let taken = squatter.local_addr().expect("its address").port();

        let server = bind_any(taken, &identity).expect("bound somewhere");
        let bound: u16 = server
            .local_address()
            .expect("an address")
            .rsplit(':')
            .next()
            .and_then(|p| p.parse().ok())
            .expect("a port");
        assert_ne!(bound, taken, "the taken port cannot be the one bound");
        assert_ne!(bound, 0, "a real port, not the ask-for-any placeholder");
    }

    #[test]
    fn the_preferred_port_is_still_preferred_when_it_is_free() {
        let identity = MachineIdentity::from_secret([9u8; 32]);
        // A port is only known to be free for as long as nobody else takes it,
        // and the other tests in this binary are asking the operating system
        // for free ports at the same time. Losing that race says nothing about
        // `bind_any`, so it is retried rather than reported as a failure.
        for attempt in 1..=8 {
            let free = {
                let probe = std::net::TcpListener::bind("0.0.0.0:0").expect("a probe");
                probe.local_addr().expect("its address").port()
            };
            let server = bind_any(free, &identity).expect("bound");
            let address = server.local_address().expect("address");
            if address.ends_with(&format!(":{free}")) {
                return;
            }
            assert!(
                attempt < 8,
                "never got the preferred port, last was {address}"
            );
        }
    }

    #[test]
    fn serving_is_off_unless_a_file_says_otherwise() {
        assert!(!RemoteSettings::default().serving);
        assert_eq!(RemoteSettings::default().port, DEFAULT_PORT);
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
}
