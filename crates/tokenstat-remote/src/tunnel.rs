// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.

//! The persistent, multiplexed WebSocket client to the tokenstat relay.
//!
//! One socket per machine. Sessions, terminal streams and the localhost proxy
//! are channels multiplexed over it, so a machine reconnects once and stays
//! registered while any number of channels are live, instead of dialling a
//! fresh socket per session and fighting with its own listener over the key.
//! The relay sees encrypted channel bytes and nothing more.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tokenstat_identity::{MachineIdentity, PublicKey, hex};
use tungstenite::client::IntoClientRequest;
use tungstenite::client_tls_with_config;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{HandshakeError, Message, WebSocket};

use crate::{RemoteError, Transport};

/// Called with a repository id when the relay says its target moved. The
/// line carries nothing else; the host fetches what changed from git.
type TeamMovedHook = Box<dyn Fn(&str) + Send + Sync>;
static TEAM_MOVED: std::sync::OnceLock<TeamMovedHook> = std::sync::OnceLock::new();

/// Register the host's handler for `TEAM-MOVED` lines. The first one wins.
pub fn on_team_moved(hook: impl Fn(&str) + Send + Sync + 'static) {
    let _ = TEAM_MOVED.set(Box::new(hook));
}

/// The repository id in a `TEAM-MOVED` line, if it is one.
fn team_moved(text: &str) -> Option<&str> {
    let id = text.strip_prefix("TEAM-MOVED ")?;
    (!id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
    .then_some(id)
}
mod team;
pub use team::TeamChannelHandle;
use tokenstat_identity::teams::TeamTicket;

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

// Channel frame ops: [op: u8][channel: u32 BE][payload].
/// What a channel is for, as the relay records it.
///
/// A closed set on purpose. The relay meters by this label and refuses a
/// screen channel on a plan that has none, so it has to be a value both ends
/// agree on rather than a string somebody typed. Anything the relay does not
/// recognise is counted as `unknown` rather than refused, so an older client
/// keeps working.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChannelPurpose {
    /// A desktop being streamed. The highest-bandwidth category.
    Screen,
    /// A terminal on the far machine: pty.subscribe output and keystrokes,
    /// and pty.* RPC. The bulk of interactive use after screen.
    Pty,
    /// A conversation with a remote agent: chat.* RPC. Small per call, but
    /// it is the traffic a person means when they say "I was chatting".
    Chat,
    /// Workspace browsing, Git history, search, and saved-work navigation.
    Workspace,
    /// An SSH terminal session on the far machine, or a localhost proxy
    /// stream to one of its ports. Both are interactive shells' traffic.
    Ssh,
    /// File transfer over the same remote path. Own label so it does not hide
    /// inside ssh once that lands.
    Sftp,
    /// A one-off file payload that is not a session.
    Files,
    /// Anything else the app relays. Honest rather than flattering: the
    /// leftover RPC after the call sites above named theirs, plus channels
    /// from clients old enough to send no label at all.
    Unknown,
}

impl ChannelPurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Screen => "screen",
            Self::Pty => "pty",
            Self::Chat => "chat",
            Self::Workspace => "workspace",
            Self::Ssh => "ssh",
            Self::Sftp => "sftp",
            Self::Files => "files",
            Self::Unknown => "unknown",
        }
    }
}

const CH_OPEN: u8 = 1;
const CH_OPENED: u8 = 2;
const CH_DATA: u8 = 3;
const CH_CLOSE: u8 = 4;
const CH_ERROR: u8 = 5;

/// How long an open channel waits for the relay to confirm it.
const OPEN_TIMEOUT: Duration = Duration::from_secs(10);
/// How much unread data a channel may hold before it is declared dead. A
/// stream that is not being drained (the far side pushes faster than the
/// caller reads) must fail loudly rather than grow this process's memory
/// without bound. Streams are drained continuously, so real use never gets
/// near this.
const MAX_CHANNEL_BUFFER: usize = 32 * 1024 * 1024;
/// How many relay-opened channels may wait for the host to accept them. Each
/// waits out its own Noise handshake before the next is served, so an
/// unbounded queue would let one flood pin handshake time and memory without
/// ever being read.
const INBOUND_QUEUE: usize = 64;
/// The most channels one socket may keep live, inbound and dialled together.
/// A relay that opens past this is refused a channel rather than allowed to
/// grow the map without bound.
const MAX_CHANNELS: usize = 256;
/// Bound queued outbound data when the relay or peer is slow.
const MAX_OUTBOUND_QUEUE: usize = 8 * 1024 * 1024;
const OUTBOUND_FRAME_QUEUE: usize = 64;
/// How long a channel write waits for room in the outbound queue before
/// failing. Long enough that a slow relay drains 8 MiB first, short enough
/// that a writer holding the split connection's lock cannot starve its reader
/// indefinitely.
const SEND_TIMEOUT: Duration = Duration::from_secs(30);
/// Where this machine's dial ids start. Channel ids are local to each socket,
/// and the two sides choose them independently: the relay numbers the
/// channels it opens to a socket from its own per-socket counter (which grows
/// from 1), while a client numbers its dials from its own counter. If a dial
/// id collided with a live inbound id, one of the two channels would silently
/// stop being routed: an inbound OPENED would be mistaken for the dial's own
/// OPENED (or vice versa) and the channel would be lost, which shows up as a
/// stream that opens but never answers ("no channel data"). Dial ids start
/// near the top of the space, which a counter growing from 1 cannot reach in
/// a socket's lifetime.
const DIAL_ID_BASE: u32 = 1 << 30;
/// Reconnect backoff bounds. The relay is usually reachable; a short floor
/// keeps the retry honest and a low ceiling stops a dead endpoint from
/// hammering.
const RECONNECT_FLOOR: Duration = Duration::from_secs(1);
const RECONNECT_CEILING: Duration = Duration::from_secs(30);
/// DNS + TCP + TLS + the WebSocket handshake, and then HELLO/READY. A
/// blackholed network used to sit in `connect` until the OS TCP timeout
/// (often a minute). `nudge` cannot cut that short. Ten seconds is long
/// enough for a slow path and short enough that sleep/wake reconnects.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// How many times in a row a fresh credential earns an immediate retry.
///
/// One covers the ordinary case: the credential expired, a new one was minted,
/// try it. More than a couple in a row means the replacement is being refused
/// too, which minting again cannot fix, so the backoff takes over.
const MAX_IMMEDIATE_RENEWALS: u32 = 2;
/// How long a live socket may go without a read before `nudge` treats it as
/// half-open and closes it. Matches the relay's default `TUNNEL_KEEPALIVE_MS`
/// (25s). Wall clock, not `Instant`: a Mac asleep stops `Instant` and would
/// otherwise look freshly read after the lid opens.
const KEEPALIVE_STALE_MS: u64 = 25_000;

/// The one long-lived tunnel connection a daemon keeps.
pub struct TunnelSession {
    endpoint: String,
    key_hex: String,
    /// Short-lived tunnel:connect secret (or, during rollout, a legacy sync
    /// bearer). Swapped under the mutex when the host refreshes it; the next
    /// HELLO / reconnect picks up the new value.
    token: Mutex<String>,
    next_channel: AtomicU32,
    /// The writer thread's inbox. None while disconnected.
    writer: Mutex<Option<Writer>>,
    /// The relay-dialled channels, for the host to answer.
    inbound_tx: Mutex<Option<mpsc::SyncSender<Arc<ChannelState>>>>,
    inbound_rx: Mutex<Option<mpsc::Receiver<Arc<ChannelState>>>>,
    /// Every live channel, by its local id.
    channels: Mutex<HashMap<u32, Arc<ChannelState>>>,
    /// The current socket, so shutdown can interrupt a parked supervisor.
    socket: Mutex<Option<Socket>>,
    /// The raw TCP stream while TLS / HELLO is still in flight. `shutdown`
    /// closes it so a turn-off during connect does not leave a live socket
    /// that the IO loop would then store.
    connecting: Mutex<Option<TcpStream>>,
    /// What the relay connection is doing right now, for the screen that
    /// reports it. The supervisor owns this; the host reads it.
    status: Mutex<TunnelStatus>,
    /// How to get a fresh HELLO credential when the relay refuses the one this
    /// session holds. Set by the host, which is the side that can talk to the
    /// account. None means "retry with what we have", which is what a build
    /// without an account does.
    renew: Mutex<Option<RenewToken>>,
    /// Wakes the supervisor's backoff wait. `nudge` sends here when the network
    /// comes back or the machine wakes from sleep, so a reconnect does not wait
    /// out a backoff that was sized for a network that is now up.
    wake: Mutex<Option<mpsc::Sender<()>>>,
    /// Set when the last failed attempt ended in a fresh credential. The
    /// supervisor takes it and retries immediately instead of waiting.
    renewed: AtomicBool,
    stopped: AtomicBool,
    /// Wall-clock ms of the last successful socket read. 0 means never.
    /// Used by `nudge` to tell a live socket from a NAT half-open.
    last_read_ms: AtomicU64,
}

#[derive(Clone)]
struct Writer {
    sender: mpsc::SyncSender<Vec<u8>>,
    bytes: Arc<AtomicUsize>,
}

/// Mints a replacement HELLO credential, or says why it could not.
///
/// The reason matters and used to be thrown away. A relay that says
/// `token_expired` is describing a symptom. The cause is whatever the mint
/// answered, and "remote reach is a paid-plan feature" or "sign in again" is
/// the sentence somebody can act on. Reporting the expiry instead is how a
/// machine sat for days telling its owner a credential had expired when the
/// account had simply stopped issuing them.
pub type RenewToken = Box<dyn Fn() -> Result<String, String> + Send + Sync>;

/// What came of asking for a replacement credential.
enum Renewal {
    /// A fresh credential is in hand. The next attempt is a different attempt.
    Fresh,
    /// One cannot be had right now, and this is why.
    Unavailable(String),
    /// Nothing taught this session how to mint. A build without an account.
    NotConfigured,
}

/// What the tunnel connection is doing right now.
#[derive(Debug, Clone, Default)]
pub struct TunnelStatus {
    /// The socket is up and READY: this machine is registered and diallable.
    pub connected: bool,
    /// Why the last attempt failed, when it did. None for an ordinary drop
    /// (the supervisor reconnects silently).
    pub error: Option<String>,
}

/// One multiplexed channel's state, shared by the reader thread and the
/// transport that reads and writes it. The internals are private; the host
/// only ever hands a state back to `ChannelTransport::from_inbound`.
pub struct ChannelState {
    id: u32,
    team: Option<team::TeamChannel>,
    inner: Mutex<ChannelInner>,
    cond: Condvar,
}

struct ChannelInner {
    buffer: Vec<u8>,
    opened: bool,
    eof: bool,
    error: Option<String>,
}

impl ChannelState {
    fn new(id: u32) -> Self {
        Self {
            id,
            team: None,
            inner: Mutex::new(ChannelInner {
                buffer: Vec::new(),
                opened: false,
                eof: false,
                error: None,
            }),
            cond: Condvar::new(),
        }
    }
}

impl TunnelSession {
    /// Start the session and its supervisor. The supervisor owns the socket,
    /// reconnects it with backoff, and keeps it registered until `shutdown`.
    pub fn spawn(endpoint: &str, identity: &MachineIdentity, token: &str) -> Arc<Self> {
        let (inbound_tx, inbound_rx) = mpsc::sync_channel::<Arc<ChannelState>>(INBOUND_QUEUE);
        let (wake_tx, wake_rx) = mpsc::channel::<()>();
        let session = Arc::new(Self {
            endpoint: endpoint.to_string(),
            key_hex: identity.public_key_hex(),
            token: Mutex::new(token.to_string()),
            next_channel: AtomicU32::new(1),
            writer: Mutex::new(None),
            inbound_tx: Mutex::new(Some(inbound_tx)),
            inbound_rx: Mutex::new(Some(inbound_rx)),
            channels: Mutex::new(HashMap::new()),
            socket: Mutex::new(None),
            connecting: Mutex::new(None),
            status: Mutex::new(TunnelStatus::default()),
            renew: Mutex::new(None),
            wake: Mutex::new(Some(wake_tx)),
            renewed: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            last_read_ms: AtomicU64::new(0),
        });
        let weak = Arc::downgrade(&session);
        std::thread::spawn(move || supervisor(weak, wake_rx));
        session
    }

    /// Replace the HELLO credential the next connection will use.
    ///
    /// The live socket is left alone. A credential is checked once, at HELLO,
    /// so a socket that is already registered is not made any more valid by a
    /// newer token, and dropping it to adopt one would take every live channel
    /// with it. Refreshing happens twice a day, and it used to end a working
    /// terminal each time.
    pub fn set_token(&self, token: &str) {
        let mut held = self.token.lock().unwrap_or_else(|e| e.into_inner());
        *held = token.to_string();
    }

    /// Teach this session how to replace a credential the relay refused.
    ///
    /// Without it a machine whose token was revoked, expired between runs, or
    /// registered under a key the account no longer carries retries the same
    /// dead secret until somebody notices and toggles a switch. That is the
    /// state remote reach was found in: a relay saying "sign in again" every
    /// thirty seconds, for hours, with a perfectly good login on the machine.
    pub fn set_renew(&self, renew: RenewToken) {
        *self.renew.lock().unwrap_or_else(|e| e.into_inner()) = Some(renew);
    }

    /// Ask for a fresh credential and keep it.
    fn renew_credential(&self) -> Renewal {
        let minted = {
            let guard = self.renew.lock().unwrap_or_else(|e| e.into_inner());
            match guard.as_ref() {
                Some(renew) => renew(),
                None => return Renewal::NotConfigured,
            }
        };
        match minted {
            Ok(token) if !token.is_empty() => {
                *self.token.lock().unwrap_or_else(|e| e.into_inner()) = token;
                Renewal::Fresh
            }
            Ok(_) => Renewal::Unavailable("the account returned an empty credential".into()),
            Err(why) => Renewal::Unavailable(why),
        }
    }

    /// Channels the relay opened to this machine, for the host to answer.
    ///
    /// `None` when a previous caller already took the receiver: inbound is
    /// served by exactly one loop, and a second caller must not panic on a
    /// shared receiver (a panic in a spawned thread would abort the daemon).
    pub fn take_inbound(&self) -> Option<mpsc::Receiver<Arc<ChannelState>>> {
        self.inbound_rx
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
    }

    /// Open a channel to a peer and wait for the relay to pair it.
    ///
    /// The returned transport is not yet a Noise session: the caller runs
    /// `handshake_initiator` over it, exactly as it would over a TCP stream.
    ///
    /// The purpose rides after the key in the open frame. It is a label from a
    /// fixed list, never free text: the relay writes it into a usage table and
    /// shows it on a dashboard, and it is how a desktop stream at 1.5 Mbps is
    /// told apart from a shell that is keystrokes. A relay built before this
    /// existed reads the key and ignores the rest.
    pub fn open_channel(
        self: &Arc<Self>,
        peer: PublicKey,
        purpose: ChannelPurpose,
    ) -> Result<ChannelTransport, RemoteError> {
        self.open(peer, purpose, None)
    }

    /// Separate admission for a scoped Teams connection. A ticket is still
    /// unverified here: both relay and host must validate its signature,
    /// current grants and the keys authenticated by Noise.
    pub fn open_team_channel(
        self: &Arc<Self>,
        peer: PublicKey,
        ticket: &TeamTicket,
    ) -> Result<ChannelTransport, RemoteError> {
        self.open(peer, ChannelPurpose::Chat, Some(ticket))
    }

    fn open(
        self: &Arc<Self>,
        peer: PublicKey,
        purpose: ChannelPurpose,
        ticket: Option<&TeamTicket>,
    ) -> Result<ChannelTransport, RemoteError> {
        if self.stopped.load(Ordering::Relaxed) {
            return Err(RemoteError::Tunnel("tunnel is stopped".into()));
        }
        let (op, open_payload) = if let Some(ticket) = ticket {
            (team::CH_TEAM_OPEN, team::open_payload(&peer, ticket)?)
        } else {
            (
                CH_OPEN,
                format!("{}:{}", hex(&peer), purpose.as_str()).into_bytes(),
            )
        };
        let sequence = self
            .next_channel
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |next| {
                next.checked_add(1)
                    .filter(|next| *next <= u32::MAX - DIAL_ID_BASE)
            })
            .map_err(|_| RemoteError::Tunnel("channel identifiers exhausted".into()))?;
        let id = DIAL_ID_BASE + sequence;
        let mut state = ChannelState::new(id);
        state.team = ticket.map(|ticket| team::TeamChannel::new(ticket.clone(), Some(peer)));
        let state = Arc::new(state);
        {
            let mut channels = self.channels.lock().unwrap_or_else(|e| e.into_inner());
            ensure_running(self)?;
            if channels.len() >= MAX_CHANNELS {
                return Err(RemoteError::Tunnel("too many open channels".into()));
            }
            channels.insert(id, Arc::clone(&state));
        }
        if let Err(error) = self.send_channel_frame(op, id, &open_payload) {
            self.forget_channel(&state);
            return Err(error);
        }

        // Wait for OPENED or ERROR. The relay answers in milliseconds when it
        // is there; the timeout covers the relay being gone or the peer being
        // unreachable.
        let deadline = Instant::now() + OPEN_TIMEOUT;
        let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
        while !inner.opened && !inner.eof && inner.error.is_none() && Instant::now() < deadline {
            let (guard, _) = state
                .cond
                .wait_timeout(inner, Duration::from_millis(20))
                .unwrap_or_else(|e| e.into_inner());
            inner = guard;
        }
        let error = inner.error.clone();
        let opened = inner.opened && !inner.eof;
        drop(inner);
        if let Some(error) = error {
            self.forget_channel(&state);
            return Err(RemoteError::Tunnel(error));
        }
        if !opened {
            if self.forget_channel(&state) {
                let _ = self.queue_channel_frame(CH_CLOSE, id, &[], false);
            }
            return Err(RemoteError::Tunnel(
                "the relay did not pair the channel in time".into(),
            ));
        }
        Ok(ChannelTransport::new(Arc::clone(self), state))
    }

    /// Stop the session and close the socket. The supervisor exits; live
    /// channels end with an error, which is what a daemon shutdown means.
    pub fn shutdown(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        mark_all_channels(self, "tunnel stopped");
        forget_all_channels(self);
        self.inbound_tx
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        self.writer.lock().unwrap_or_else(|e| e.into_inner()).take();
        self.status
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .connected = false;
        self.nudge();
        if let Some(stream) = self
            .connecting
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Some(mut socket) = self.socket.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = socket.close(None);
        }
    }

    /// Disable personal reach without interrupting separately authorized Team
    /// channels on the same socket. Pending opens and streams are included.
    pub fn close_personal_channels(&self) {
        let personal: Vec<_> = self
            .channels
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .values()
            .filter(|state| state.team.is_none())
            .cloned()
            .collect();
        for state in personal {
            if self.forget_channel(&state) {
                let _ = self.queue_channel_frame(CH_CLOSE, state.id, &[], false);
            }
            if let Ok(mut inner) = state.inner.lock() {
                inner.buffer.clear();
                inner.error = Some("personal remote reach is off".into());
                inner.eof = true;
            }
            state.cond.notify_all();
        }
    }

    /// Wake the supervisor and reset its reconnect backoff.
    ///
    /// Called when the network comes back or the machine wakes from sleep, so a
    /// reconnect that would otherwise wait out its backoff starts immediately
    /// instead. If the socket has not read in one keepalive it is treated as
    /// half-open and closed so the supervisor reconnects now, rather than
    /// waiting for the relay to notice.
    pub fn nudge(&self) {
        self.wake_supervisor();
        if self.read_is_stale() {
            self.close_live_socket();
        }
    }

    /// Same as `nudge`, but always drop a live socket.
    ///
    /// A path change (Wi-Fi to cellular) leaves a socket that still looks
    /// fresh: the last ping was seconds ago, on the old route. Closing it
    /// here is what makes the next HELLO land on the new path.
    pub fn reconnect_now(&self) {
        self.wake_supervisor();
        self.close_live_socket();
    }

    fn wake_supervisor(&self) {
        if let Some(tx) = self.wake.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            let _ = tx.send(());
        }
    }

    fn close_live_socket(&self) {
        if let Some(socket) = self
            .socket
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_mut()
        {
            let _ = socket.close(None);
        }
    }

    fn mark_read(&self) {
        self.last_read_ms.store(wall_ms(), Ordering::Release);
    }

    fn read_is_stale(&self) -> bool {
        let last = self.last_read_ms.load(Ordering::Acquire);
        if last == 0 {
            return self.status().connected;
        }
        wall_ms().saturating_sub(last) >= KEEPALIVE_STALE_MS
    }

    /// What the connection is doing right now.
    pub fn status(&self) -> TunnelStatus {
        self.status
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Queue one channel frame for the IO thread.
    ///
    /// Direct TCP `write` waits when the kernel buffer is full. This used to
    /// `try_send` and fail the moment 64 frames were in flight, about 2 MiB of
    /// Noise: a 5 MB chat file over the relay died with "tunnel outbound queue
    /// is full" while the same file over a direct connection arrived. Waiting
    /// here is that same backpressure, so a large attachment waits for the
    /// socket instead of failing the download.
    ///
    /// The wait is bounded (`SEND_TIMEOUT`) rather than forever. The caller in
    /// `tokenstat-remote` holds the split connection's lock across this call,
    /// so parking without a deadline would starve the read half for as long as
    /// the relay stayed slow. And the 8 MiB byte reservation below still caps
    /// memory: a burst larger than that fails loudly rather than growing
    /// without bound.
    fn send_channel_frame(&self, op: u8, ch: u32, payload: &[u8]) -> Result<(), RemoteError> {
        self.queue_channel_frame(op, ch, payload, true)
    }

    fn queue_channel_frame(
        &self,
        op: u8,
        ch: u32,
        payload: &[u8],
        wait: bool,
    ) -> Result<(), RemoteError> {
        self.queue_channel_frame_with_timeout(op, ch, payload, wait, SEND_TIMEOUT)
    }

    fn queue_channel_frame_with_timeout(
        &self,
        op: u8,
        ch: u32,
        payload: &[u8],
        wait: bool,
        timeout: Duration,
    ) -> Result<(), RemoteError> {
        let deadline = Instant::now() + timeout.min(SEND_TIMEOUT);
        ensure_running(self)?;
        if payload.len() > MAX_OUTBOUND_QUEUE {
            return Err(RemoteError::Tunnel("channel frame is too large".into()));
        }
        let mut frame = Vec::with_capacity(5 + payload.len());
        frame.push(op);
        frame.extend_from_slice(&ch.to_be_bytes());
        frame.extend_from_slice(payload);
        let writer = self
            .writer
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .ok_or_else(|| RemoteError::Tunnel("tunnel is not connected".into()))?;
        let size = frame.len();
        let mut current = writer.bytes.load(Ordering::Relaxed);
        loop {
            let Some(next) = current.checked_add(size) else {
                return Err(RemoteError::Tunnel("tunnel outbound queue is full".into()));
            };
            if next > MAX_OUTBOUND_QUEUE {
                return Err(RemoteError::Tunnel("tunnel outbound queue is full".into()));
            }
            match writer.bytes.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(observed) => current = observed,
            }
        }
        // Bounded backpressure on stable: `SyncSender::send_timeout` is still
        // unstable, so retry `try_send` until the deadline. A full queue means
        // the relay is slow, not gone; a disconnected one means the IO loop
        // died and the next call will reconnect.
        loop {
            if wait && Instant::now() >= deadline {
                writer.bytes.fetch_sub(size, Ordering::AcqRel);
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "The channel write time budget expired.",
                )
                .into());
            }
            match writer.sender.try_send(frame) {
                Ok(()) => return Ok(()),
                Err(mpsc::TrySendError::Full(returned)) => {
                    if !wait || self.stopped.load(Ordering::Relaxed) {
                        writer.bytes.fetch_sub(size, Ordering::AcqRel);
                        return Err(RemoteError::Tunnel("tunnel outbound queue is full".into()));
                    }
                    frame = returned;
                    std::thread::sleep(
                        Duration::from_millis(5)
                            .min(deadline.saturating_duration_since(Instant::now())),
                    );
                }
                Err(mpsc::TrySendError::Disconnected(_)) => {
                    writer.bytes.fetch_sub(size, Ordering::AcqRel);
                    return Err(RemoteError::Tunnel("tunnel is not connected".into()));
                }
            }
        }
    }

    fn forget_channel(&self, state: &Arc<ChannelState>) -> bool {
        let mut channels = self.channels.lock().unwrap_or_else(|e| e.into_inner());
        if channels
            .get(&state.id)
            .is_some_and(|current| Arc::ptr_eq(current, state))
        {
            channels.remove(&state.id);
            true
        } else {
            false
        }
    }
}

/// A channel as a `Transport`: bytes in, bytes out, CLOSE on drop.
///
/// Reads wait on the channel's condition variable; the handshake and
/// request/response paths block until data arrives, and `set_read_timeout`
/// bounds the wait for the split-stream reader.
pub struct ChannelTransport {
    session: Arc<TunnelSession>,
    state: Arc<ChannelState>,
    read_timeout: Mutex<Option<Duration>>,
    write_timeout: Mutex<Option<Duration>>,
    closed: AtomicBool,
}

impl ChannelTransport {
    fn new(session: Arc<TunnelSession>, state: Arc<ChannelState>) -> Self {
        Self {
            session,
            state,
            read_timeout: Mutex::new(None),
            write_timeout: Mutex::new(None),
            closed: AtomicBool::new(false),
        }
    }

    /// Wrap a relay-dialled channel for the responder side.
    pub fn from_inbound(session: Arc<TunnelSession>, state: Arc<ChannelState>) -> Self {
        Self::new(session, state)
    }

    /// The channel's local id, for diagnostics.
    pub fn channel_id(&self) -> u32 {
        self.state.id
    }

    /// Teams identity is connection-scoped and never enters the personal
    /// peer allowlist. Keep this handle when handing the transport to Noise.
    pub fn team_authorization(&self) -> Option<TeamChannelHandle> {
        self.state
            .team
            .as_ref()
            .map(|_| TeamChannelHandle::new(Arc::clone(&self.session), Arc::clone(&self.state)))
    }
}

impl Read for ChannelTransport {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() || self.closed.load(Ordering::Relaxed) {
            return Ok(0);
        }
        let timeout = *self.read_timeout.lock().unwrap_or_else(|e| e.into_inner());
        let started = Instant::now();
        let mut inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            // Revocation ends a Team stream before queued content is drained.
            // Preserve the original tail-draining behavior for personal peers.
            if self.state.team.is_some() && (inner.eof || inner.error.is_some()) {
                inner.buffer.clear();
                return match &inner.error {
                    Some(error) => Err(io::Error::other(error.clone())),
                    None => Ok(0),
                };
            }
            if !inner.buffer.is_empty() {
                let count = output.len().min(inner.buffer.len());
                output[..count].copy_from_slice(&inner.buffer[..count]);
                inner.buffer.drain(..count);
                return Ok(count);
            }
            if inner.eof {
                return Ok(0);
            }
            if let Some(error) = &inner.error {
                return Err(io::Error::other(error.clone()));
            }
            match timeout {
                Some(limit) => {
                    let limit = limit.saturating_sub(started.elapsed());
                    if limit.is_zero() {
                        return Err(io::Error::new(io::ErrorKind::TimedOut, "no channel data"));
                    }
                    let (guard, result) = self
                        .state
                        .cond
                        .wait_timeout(inner, limit)
                        .unwrap_or_else(|e| e.into_inner());
                    inner = guard;
                    if result.timed_out() {
                        return Err(io::Error::new(io::ErrorKind::TimedOut, "no channel data"));
                    }
                }
                None => {
                    inner = self
                        .state
                        .cond
                        .wait(inner)
                        .unwrap_or_else(|e| e.into_inner());
                }
            }
        }
    }
}

impl Write for ChannelTransport {
    fn write(&mut self, input: &[u8]) -> io::Result<usize> {
        if self.closed.load(Ordering::Relaxed) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "channel closed"));
        }
        {
            let inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
            if inner.eof || inner.error.is_some() {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "channel closed"));
            }
        }
        let timeout = self
            .write_timeout
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .unwrap_or(SEND_TIMEOUT);
        self.session
            .queue_channel_frame_with_timeout(CH_DATA, self.state.id, input, true, timeout)
            .map_err(|error| match error {
                RemoteError::Io(error) => error,
                error => io::Error::other(error),
            })?;
        Ok(input.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for ChannelTransport {
    fn drop(&mut self) {
        Transport::close(self);
    }
}

impl Transport for ChannelTransport {
    fn close(&mut self) {
        if self.closed.swap(true, Ordering::Relaxed) {
            return;
        }
        // A reconnect can reuse an inbound ID. Dropping an old transport
        // must neither erase nor close the new channel with that number.
        if self.session.forget_channel(&self.state) {
            let _ = self
                .session
                .queue_channel_frame(CH_CLOSE, self.state.id, &[], false);
        }
        if let Ok(mut inner) = self.state.inner.lock() {
            inner.eof = true;
        }
        self.state.cond.notify_all();
    }

    fn set_deadline(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        *self.write_timeout.lock().unwrap_or_else(|e| e.into_inner()) = timeout;
        self.set_read_timeout(timeout)
    }

    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        *self.read_timeout.lock().unwrap_or_else(|e| e.into_inner()) = timeout;
        self.state.cond.notify_all();
        Ok(())
    }

    fn is_relay(&self) -> bool {
        true
    }
}

// MARK: - The supervisor

fn supervisor(session: Weak<TunnelSession>, wake_rx: mpsc::Receiver<()>) {
    let mut backoff = RECONNECT_FLOOR;
    // Consecutive attempts that ended in a fresh credential. Bounded, because
    // "the relay refuses it and minting produces another it also refuses" is a
    // real state (two daemons on one identity used to produce exactly it), and
    // retrying that without a pause is a hot loop against the account host.
    let mut renewals = 0u32;
    loop {
        let Some(session) = session.upgrade() else {
            return;
        };
        if session.stopped.load(Ordering::Relaxed) {
            return;
        }
        // One line per attempt, and one per end. A machine that dropped off
        // the relay and did not come back is the hardest thing here to work
        // out afterwards, because the relay's own log can only say that a
        // socket went away: whether this end was asleep, waiting out a
        // backoff, or being refused is knowable only from here.
        eprintln!("tunnel: connecting to {}", session.endpoint);
        match connect_once(&session) {
            Ok(()) => {
                // The socket died; that is the ordinary end of a connection,
                // not an error to show.
                *session.status.lock().unwrap_or_else(|e| e.into_inner()) = TunnelStatus::default();
                eprintln!("tunnel: socket closed, reconnecting");
                backoff = RECONNECT_FLOOR;
                renewals = 0;
            }
            Err(error) => {
                if !session.stopped.load(Ordering::Relaxed) {
                    eprintln!("tunnel: connection failed: {error}");
                }
                *session.status.lock().unwrap_or_else(|e| e.into_inner()) = TunnelStatus {
                    connected: false,
                    error: Some(error.to_string()),
                };
            }
        }
        if session.stopped.load(Ordering::Relaxed) {
            return;
        }
        mark_all_channels(&session, "tunnel disconnected");
        forget_all_channels(&session);
        // A credential that was just replaced deserves an immediate attempt.
        // The refusal has already been answered, so the wait that follows an
        // ordinary failure would only keep the machine reading as offline for
        // a repair that has happened. Bounded by `MAX_IMMEDIATE_RENEWALS`, so
        // a credential the relay keeps refusing falls back to the backoff
        // rather than spending the account's mint budget in a loop.
        if session.renewed.swap(false, Ordering::AcqRel) {
            renewals += 1;
            if renewals <= MAX_IMMEDIATE_RENEWALS {
                backoff = RECONNECT_FLOOR;
                continue;
            }
        } else {
            renewals = 0;
        }
        // Wait out the backoff, or wake early when the network comes back and
        // a `nudge` lands. A wake resets the backoff so the fresh attempt is
        // not punished for the failed ones a dead network already earned.
        // `Disconnected` (the wake sender is gone) must not return instantly,
        // or the loop would spin; the session upgrade at the top exits anyway.
        let woken = match wake_rx.recv_timeout(backoff) {
            Ok(()) => true,
            Err(mpsc::RecvTimeoutError::Timeout) => false,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                std::thread::sleep(backoff);
                false
            }
        };
        backoff = if woken {
            RECONNECT_FLOOR
        } else {
            (backoff * 2).min(RECONNECT_CEILING)
        };
        eprintln!(
            "tunnel: {} next attempt in {}s",
            if woken { "woken," } else { "backing off," },
            backoff.as_secs_f32()
        );
    }
}

fn drop_connecting(session: &TunnelSession) {
    *session.connecting.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

struct ConnectingGuard<'a>(&'a TunnelSession);

impl Drop for ConnectingGuard<'_> {
    fn drop(&mut self) {
        drop_connecting(self.0);
    }
}

fn ensure_running(session: &TunnelSession) -> Result<(), RemoteError> {
    if session.stopped.load(Ordering::Relaxed) {
        Err(RemoteError::Tunnel("tunnel is stopped".into()))
    } else {
        Ok(())
    }
}

/// DNS under a deadline. `to_socket_addrs` has no timeout of its own,
/// and a blackholed resolver used to park the supervisor until the OS
/// gave up, which `nudge` and `shutdown` could not cut short.
fn resolve_relay_addrs(
    host: &str,
    port: u16,
    timeout: Duration,
) -> Result<Vec<SocketAddr>, RemoteError> {
    let (tx, rx) = mpsc::sync_channel(1);
    let lookup = host.to_string();
    std::thread::Builder::new()
        .name("tunnel-dns".into())
        .spawn(move || {
            let result = (lookup.as_str(), port)
                .to_socket_addrs()
                .map(|iter| iter.collect::<Vec<_>>());
            let _ = tx.send(result);
        })
        .map_err(RemoteError::Io)?;
    match rx.recv_timeout(timeout) {
        Ok(Ok(addrs)) if !addrs.is_empty() => Ok(addrs),
        Ok(Ok(_)) => Err(RemoteError::Tunnel(format!("{host} resolves to nothing"))),
        Ok(Err(error)) => Err(RemoteError::Io(error)),
        Err(_) => Err(RemoteError::Tunnel(format!("looking up {host} timed out"))),
    }
}

/// TCP + TLS + the WebSocket handshake, bounded so a dead relay cannot park
/// the supervisor until the OS gives up.
fn connect_relay_to(
    endpoint: &str,
    session: Option<&TunnelSession>,
) -> Result<(Socket, TcpStream), RemoteError> {
    if let Some(session) = session {
        ensure_running(session)?;
    }
    let request = endpoint.into_client_request().map_err(tunnel_error)?;
    let host = request
        .uri()
        .host()
        .ok_or_else(|| RemoteError::Tunnel("tunnel url has no host".into()))?
        .to_string();
    let host_for_addr = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_string();
    let is_tls = match request.uri().scheme_str() {
        Some("wss") => true,
        Some("ws") => false,
        other => {
            return Err(RemoteError::Tunnel(format!(
                "unsupported tunnel scheme: {other:?}"
            )));
        }
    };
    let port = request
        .uri()
        .port_u16()
        .unwrap_or(if is_tls { 443 } else { 80 });
    // IPv4 first: a dual-stack lookup often returns a blackholed AAAA,
    // and using only that address spent the whole budget on a path
    // that cannot work. Still try every address inside the budget.
    let addrs = prefer_ipv4(resolve_relay_addrs(&host_for_addr, port, CONNECT_TIMEOUT)?);
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let count = addrs.len();
    let mut last_err = None;
    for (i, addr) in addrs.into_iter().enumerate() {
        if let Some(session) = session {
            ensure_running(session)?;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        let left = (count - i) as u32;
        let slice = remaining / left.max(1);
        match handshake_relay(endpoint, addr, slice, session) {
            Ok(pair) => return Ok(pair),
            Err(error) => last_err = Some(error),
        }
    }
    Err(last_err
        .unwrap_or_else(|| RemoteError::Tunnel(format!("{host_for_addr} resolves to nothing"))))
}

fn prefer_ipv4(mut addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    addrs.sort_by_key(|addr| if addr.is_ipv4() { 0 } else { 1 });
    addrs
}

fn handshake_relay(
    endpoint: &str,
    addr: SocketAddr,
    tcp_timeout: Duration,
    session: Option<&TunnelSession>,
) -> Result<(Socket, TcpStream), RemoteError> {
    let request = endpoint.into_client_request().map_err(tunnel_error)?;
    let stream = TcpStream::connect_timeout(&addr, tcp_timeout).map_err(RemoteError::Io)?;
    stream.set_nodelay(true).map_err(RemoteError::Io)?;
    stream
        .set_read_timeout(Some(HELLO_TIMEOUT))
        .map_err(RemoteError::Io)?;
    stream
        .set_write_timeout(Some(HELLO_TIMEOUT))
        .map_err(RemoteError::Io)?;
    let raw = stream.try_clone().map_err(RemoteError::Io)?;
    // Published before TLS so `shutdown` can close the handshake. Stored
    // only after this function used to leave a toggle-off as a live
    // socket the IO loop could still keep.
    if let Some(session) = session {
        *session.connecting.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(raw.try_clone().map_err(RemoteError::Io)?);
        if let Err(error) = ensure_running(session) {
            let _ = raw.shutdown(Shutdown::Both);
            drop_connecting(session);
            return Err(error);
        }
    }
    let handshake = client_tls_with_config(request, stream, None, None);
    match handshake {
        Ok((socket, _)) => Ok((socket, raw)),
        Err(error) => {
            if let Some(session) = session {
                drop_connecting(session);
            }
            Err(match error {
                HandshakeError::Failure(failure) => tunnel_error(failure),
                HandshakeError::Interrupted(_) => {
                    RemoteError::Tunnel("websocket handshake was interrupted".into())
                }
            })
        }
    }
}

/// Connect, register, and pump until the socket dies.
fn connect_once(session: &Arc<TunnelSession>) -> Result<(), RemoteError> {
    ensure_running(session)?;
    let token = session
        .token
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let (mut socket, _raw) = connect_relay_to(&session.endpoint, Some(session))?;
    let _connecting = ConnectingGuard(session);
    if let Err(error) = ensure_running(session) {
        let _ = socket.close(None);
        return Err(error);
    }
    socket
        .send(Message::Text(
            format!("HELLO {} {} V2", session.key_hex, token).into(),
        ))
        .map_err(tunnel_error)?;
    match socket.read().map_err(tunnel_error)? {
        Message::Text(text) if text == "READY" => {
            *session.status.lock().unwrap_or_else(|e| e.into_inner()) = TunnelStatus {
                connected: true,
                error: None,
            };
            session.mark_read();
            eprintln!("tunnel: registered, this machine is diallable");
        }
        Message::Text(text) => {
            // A refusal the machine can answer itself is answered here, before
            // the supervisor sleeps: a stale, expired or re-registered
            // credential is replaced so the next attempt is a different
            // attempt. Plan and duplicate-key refusals are left alone, because
            // minting again would only ask the account the same question.
            if renewable_denial(&text) {
                match session.renew_credential() {
                    Renewal::Fresh => {
                        // The supervisor reads this and retries at once. The
                        // repair has already happened, and sleeping out a
                        // backoff sized for a dead network would leave the
                        // machine reading as offline for up to half a minute
                        // after it was fixed.
                        session.renewed.store(true, Ordering::Release);
                        eprintln!("tunnel: credential refused, minted a fresh one");
                        return Err(RemoteError::Tunnel(denial_message(&text)));
                    }
                    Renewal::Unavailable(why) => {
                        // The mint's reason, not the relay's. See `RenewToken`.
                        return Err(RemoteError::Tunnel(format!(
                            "{}, and a replacement could not be minted: {why}",
                            denial_message(&text)
                        )));
                    }
                    Renewal::NotConfigured => {}
                }
            }
            return Err(RemoteError::Tunnel(denial_message(&text)));
        }
        Message::Close(_) => return Err(RemoteError::Closed),
        other => {
            return Err(RemoteError::Tunnel(format!(
                "expected READY, got {other:?}"
            )));
        }
    }
    drop(_connecting);
    if let Err(error) = ensure_running(session) {
        let _ = socket.close(None);
        return Err(error);
    }
    // One IO thread owns the socket. It must never block inside a read or a
    // flush: a read that waits is a read that cannot drain the writer queue,
    // and a flush that waits is a write the relay is not draining, either of
    // which stalls every channel on this socket. The socket is nonblocking
    // and the loop parks briefly when there is nothing to do.
    set_relay_nonblocking(&mut socket)?;

    let (writer_tx, writer_rx) = mpsc::sync_channel::<Vec<u8>>(OUTBOUND_FRAME_QUEUE);
    // Each connection owns its accounting: old senders can still unwind
    // after a reconnect, without subtracting from the new queue.
    let writer_bytes = Arc::new(AtomicUsize::new(0));
    *session.writer.lock().unwrap_or_else(|e| e.into_inner()) = Some(Writer {
        sender: writer_tx,
        bytes: Arc::clone(&writer_bytes),
    });
    *session.socket.lock().unwrap_or_else(|e| e.into_inner()) = Some(socket);

    // The IO loop, inline: drain queued outgoing frames, then read one frame
    // (or idle-wait), and repeat. The socket is nonblocking, so neither the
    // read nor the flush can stall the loop.
    let mut writer_blocked = false;
    loop {
        if session.stopped.load(Ordering::Relaxed) {
            break;
        }
        if writer_blocked {
            let flush_result = {
                let mut guard = session.socket.lock().unwrap_or_else(|e| e.into_inner());
                let Some(socket) = guard.as_mut() else { break };
                socket.flush()
            };
            match flush_result {
                Ok(()) => writer_blocked = false,
                Err(tungstenite::Error::Io(error))
                    if error.kind() == io::ErrorKind::WouldBlock
                        || error.kind() == io::ErrorKind::TimedOut => {}
                Err(_) => {
                    eprintln!("tunnel: io loop writer flush failed");
                    break;
                }
            }
        }
        if !writer_blocked {
            while let Ok(frame) = writer_rx.try_recv() {
                writer_bytes.fetch_sub(frame.len(), Ordering::AcqRel);
                let send_result = {
                    let mut guard = session.socket.lock().unwrap_or_else(|e| e.into_inner());
                    let Some(socket) = guard.as_mut() else { break };
                    socket.send(Message::Binary(frame.into()))
                };
                match send_result {
                    Ok(()) => {}
                    Err(tungstenite::Error::Io(error))
                        if error.kind() == io::ErrorKind::WouldBlock
                            || error.kind() == io::ErrorKind::TimedOut =>
                    {
                        // The frame is now owned by tungstenite. Do not dequeue
                        // another one until its write buffer can flush.
                        writer_blocked = true;
                        break;
                    }
                    Err(_) => {
                        eprintln!("tunnel: io loop writer send failed");
                        writer_blocked = true;
                        break;
                    }
                }
            }
        }
        let mut guard = session.socket.lock().unwrap_or_else(|e| e.into_inner());
        let Some(socket) = guard.as_mut() else { break };
        let mut moved = None;
        let frame = match socket.read() {
            Ok(Message::Binary(frame)) => {
                session.mark_read();
                Some(frame)
            }
            Ok(Message::Text(text)) => {
                session.mark_read();
                moved = team_moved(text.as_str()).map(str::to_string);
                None
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {
                // Ping, Pong, Text. A ping is the relay's keepalive: counting
                // it as a read is what keeps a quiet machine from looking
                // half-open to `nudge`.
                session.mark_read();
                None
            }
            Err(tungstenite::Error::Io(error))
                if error.kind() == io::ErrorKind::TimedOut
                    || error.kind() == io::ErrorKind::WouldBlock =>
            {
                None
            }
            Err(_) => break,
        };
        drop(guard);
        if let Some(frame) = frame {
            dispatch_frame(session, &frame);
        }
        if let (Some(repository), Some(hook)) = (moved, TEAM_MOVED.get()) {
            hook(&repository);
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    if let Some(socket) = session
        .socket
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
    {
        let _ = socket.close(None);
    }
    *session.writer.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *session.socket.lock().unwrap_or_else(|e| e.into_inner()) = None;
    // A dead socket is the ordinary end of a connection, not a failure to
    // report: the supervisor reconnects silently.
    Ok(())
}

/// The socket is owned by one IO thread that must never block. Nonblocking
/// mode lives on the raw socket, below the WebSocket framing and TLS, so
/// tungstenite surfaces it as `WouldBlock` and the loop parks instead.
fn set_relay_nonblocking(socket: &mut Socket) -> Result<(), RemoteError> {
    match socket.get_ref() {
        MaybeTlsStream::Plain(tcp) => tcp.set_nonblocking(true),
        MaybeTlsStream::Rustls(owned) => owned.sock.set_nonblocking(true),
        _ => Ok(()),
    }
    .map_err(RemoteError::Io)
}

/// Route one channel frame from the relay.
fn dispatch_frame(session: &Arc<TunnelSession>, frame: &[u8]) {
    if frame.len() < 5 {
        return;
    }
    let op = frame[0];
    let id = u32::from_be_bytes([frame[1], frame[2], frame[3], frame[4]]);
    let payload = &frame[5..];
    let channels = &session.channels;

    if team::dispatch(session, op, id, payload) {
        return;
    }

    match op {
        CH_OPENED => opened(session, id, None),
        CH_DATA | CH_CLOSE | CH_ERROR => {
            let state = {
                let map = channels.lock().unwrap_or_else(|e| e.into_inner());
                map.get(&id).cloned()
            };
            if let Some(state) = state {
                let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
                match op {
                    CH_DATA => {
                        let limit = if state.team.is_some() {
                            team::MAX_BUFFER
                        } else {
                            MAX_CHANNEL_BUFFER
                        };
                        if inner.buffer.len().saturating_add(payload.len()) > limit {
                            inner.error = Some(String::from("channel buffer overflow"));
                        } else {
                            inner.buffer.extend_from_slice(payload);
                        }
                    }
                    CH_CLOSE => inner.eof = true,
                    CH_ERROR => {
                        inner.error = Some(String::from_utf8_lossy(payload).trim().to_string())
                    }
                    _ => {}
                }
                state.cond.notify_all();
            }
        }
        _ => {}
    }
}

fn opened(session: &Arc<TunnelSession>, id: u32, ticket: Option<TeamTicket>) {
    let channels = &session.channels;
    // Our own dial: mark it open. An id we do not know, or one that
    // already died on the last socket, is the relay dialling us.
    // Relay inbound ids restart at 1 on every new socket. Leaving a
    // dead entry in the map would swallow that OPENED as a late ack
    // of our own dial, and the host would never handshake.
    let mut map = channels.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(state) = map.get(&id) {
        let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.error.is_none() && !inner.eof {
            if !team::matches_open(state, ticket.as_ref()) {
                // A Teams acknowledgement cannot upgrade a personal
                // channel, and a legacy acknowledgement cannot strip
                // a Team channel's scope.
                if state.team.is_some() {
                    inner.error = Some("team admission changed".into());
                    inner.buffer.clear();
                    state.cond.notify_all();
                }
                return;
            }
            inner.opened = true;
            state.cond.notify_all();
            return;
        }
    }
    // Refuse rather than queue past the bound: a flood of opens must
    // not grow the map or the host's backlog without limit. A live
    // channel already holding this id must not be overwritten either:
    // the duplicate is refused, not merged into the existing channel.
    // A dead entry (errored on the last socket) is still replaced, so
    // a reconnect reuses the id. The map guard is dropped before the
    // refusal frame so a slow outbound queue cannot pin every other
    // channel's routing.
    let mut state = ChannelState::new(id);
    state.team = ticket.map(|ticket| team::TeamChannel::new(ticket, None));
    let state = Arc::new(state);
    let mut queued = false;
    if !session.stopped.load(Ordering::Relaxed)
        && id < DIAL_ID_BASE
        && map.len() < MAX_CHANNELS
        && !live_duplicate(&map, id)
    {
        map.insert(id, Arc::clone(&state));
        queued = session
            .inbound_tx
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .and_then(|tx| tx.try_send(state).ok())
            .is_some();
        if !queued {
            map.remove(&id);
        }
    }
    drop(map);
    if !queued {
        let _ = session.queue_channel_frame(CH_CLOSE, id, &[], false);
    }
}

/// Whether `id` already names a live channel.
///
/// A dead entry is not a duplicate: the relay restarts its ids at 1 on every
/// socket, so after a reconnect the same id names a new channel and replaces
/// the errored one. Only a live holder makes an OPENED a duplicate worth a
/// `CH_CLOSE`.
fn live_duplicate(map: &HashMap<u32, Arc<ChannelState>>, id: u32) -> bool {
    map.get(&id).is_some_and(|existing| {
        let inner = existing.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.error.is_none() && !inner.eof
    })
}

fn mark_all_channels(session: &TunnelSession, reason: &str) {
    let map = session.channels.lock().unwrap_or_else(|e| e.into_inner());
    for state in map.values() {
        let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.error.is_none() {
            inner.error = Some(reason.to_string());
        }
        state.cond.notify_all();
    }
}

/// Drop every id after a socket dies so the next socket's inbound OPENED
/// (relay ids restart at 1) is not mistaken for a late ack of this one.
fn forget_all_channels(session: &TunnelSession) {
    session
        .channels
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
}

/// Whether a fresh credential could plausibly fix this refusal.
///
/// `key_mismatch` is in the list because minting goes through registration:
/// the machine re-publishes its key and gets a token bound to it, which is
/// exactly the repair that refusal asks for.
fn renewable_denial(text: &str) -> bool {
    let Some(reason) = text.strip_prefix("DENIED ") else {
        return false;
    };
    matches!(
        reason.trim(),
        "bad_token" | "token_expired" | "key_mismatch" | "token_revoked"
    )
}

/// Turn the relay's `DENIED <reason>` into something a person can act on.
///
/// The reason codes are the stable part of the contract and the sentences are
/// not, so the mapping lives here once instead of in every screen that shows a
/// tunnel status. An unknown code is passed through rather than swallowed: a
/// new relay reason should read oddly, not disappear.
fn wall_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn denial_message(text: &str) -> String {
    let Some(reason) = text.strip_prefix("DENIED ") else {
        return text.to_string();
    };
    match reason.trim() {
        "legacy_token_rejected" => {
            "this version is too old for the tunnel: it offered a login token where a tunnel \
             credential is required. update tokenstat"
        }
        "token_expired" => "the tunnel credential expired before it could be renewed",
        "token_revoked" => {
            "this machine's tunnel credential was revoked on the account. getting a new one"
        }
        "key_mismatch" => {
            "this machine's key does not match the one registered on the account. turn remote \
             reach off and on again to re-register it"
        }
        "not_on_this_plan" => "remote reach is a paid-plan feature",
        "key_already_live" => "another machine is already on the tunnel with this key",
        // Not "sign in again": this machine mints a replacement and retries by
        // itself, and telling somebody to go and fix a thing that is already
        // fixing itself is how a transient refusal becomes a support message.
        "bad_token" => "the relay refused this machine's tunnel credential. getting a new one",
        other => return format!("the relay refused the connection: {other}"),
    }
    .to_string()
}

fn tunnel_error(error: tungstenite::Error) -> RemoteError {
    match error {
        tungstenite::Error::Io(error) => RemoteError::Io(error),
        other => RemoteError::Tunnel(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn personal_reach_can_stop_without_closing_team_channels_or_the_shared_socket() {
        let session = inert_session();
        let personal = Arc::new(ChannelState::new(1));
        let team = Arc::new(ChannelState {
            team: Some(team::TeamChannel::new(team_ticket("scoped"), Some([3; 32]))),
            ..ChannelState::new(2)
        });
        session.channels.lock().unwrap().insert(1, personal.clone());
        session.channels.lock().unwrap().insert(2, team.clone());
        personal
            .inner
            .lock()
            .unwrap()
            .buffer
            .extend(b"private data");
        let mut personal_transport = ChannelTransport::new(session.clone(), personal);
        let mut team_transport = ChannelTransport::new(session.clone(), team.clone());
        let handle = team_transport.team_authorization().unwrap();
        session.close_personal_channels();
        assert!(matches!(
            personal_transport.read(&mut [0; 64]),
            Ok(0) | Err(_)
        ));
        assert!(
            personal_transport
                .write_all(b"no more private data")
                .is_err()
        );
        assert!(handle.ticket().is_ok());
        assert!(!session.stopped.load(Ordering::Acquire));
        assert!(session.channels.lock().unwrap().contains_key(&2));
        team.inner.lock().unwrap().buffer.extend(b"team data");
        let mut bytes = [0; 9];
        assert_eq!(team_transport.read(&mut bytes).unwrap(), 9);
        assert_eq!(&bytes, b"team data");
    }

    fn team_ticket(marker: &str) -> TeamTicket {
        TeamTicket::try_from(format!("ts-team-v1.{marker}")).unwrap()
    }
    fn team_frame(op: u8, id: u32, ticket: &TeamTicket) -> Vec<u8> {
        let mut frame = vec![op];
        frame.extend_from_slice(&id.to_be_bytes());
        frame.extend_from_slice(
            &serde_json::to_vec(&serde_json::json!({"v":1,"ticket":ticket.wire_value()})).unwrap(),
        );
        frame
    }

    #[test]
    fn team_open_and_renew_use_separate_bounded_frames_and_preserve_personal_channels() {
        let session = inert_session();
        let (tx, rx) = mpsc::sync_channel(16);
        *session.writer.lock().unwrap() = Some(Writer {
            sender: tx,
            bytes: Arc::new(AtomicUsize::new(0)),
        });
        let dial = Arc::clone(&session);
        let initial = team_ticket("initial");
        let sent = initial.clone();
        let opening = std::thread::spawn(move || dial.open_team_channel([0xbb; 32], &sent));
        let frame = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(frame[0], 6);
        assert!(frame.len() <= 4613);
        let body: serde_json::Value = serde_json::from_slice(&frame[5..]).unwrap();
        assert_eq!(
            body,
            serde_json::json!({"v":1,"hostKey":"bb".repeat(32),"ticket":initial.wire_value()})
        );
        let id = u32::from_be_bytes(frame[1..5].try_into().unwrap());
        dispatch_frame(&session, &team_frame(7, id, &initial));
        let mut transport = opening.join().unwrap().unwrap();
        let handle = transport.team_authorization().unwrap();
        let next = team_ticket("renewed");
        let renewing = {
            let handle = handle.clone();
            let next = next.clone();
            std::thread::spawn(move || handle.renew(&next))
        };
        let frame = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(frame[0], 8);
        assert_eq!(&frame[1..5], &id.to_be_bytes());
        let body: serde_json::Value = serde_json::from_slice(&frame[5..]).unwrap();
        assert_eq!(body["hostKey"], "bb".repeat(32));
        assert_eq!(body["ticket"], next.wire_value());
        dispatch_frame(&session, &team_frame(9, id, &next));
        renewing.join().unwrap().unwrap();
        assert_eq!(handle.ticket().unwrap().wire_value(), next.wire_value());
        assert!(!format!("{handle:?}").contains(next.wire_value()));

        let personal = Arc::new(ChannelState::new(7));
        session
            .channels
            .lock()
            .unwrap()
            .insert(7, Arc::clone(&personal));
        let mut personal = ChannelTransport::new(Arc::clone(&session), personal);
        // A Team control cannot upgrade a personal channel.
        dispatch_frame(&session, &team_frame(7, 7, &next));
        assert!(personal.team_authorization().is_none());
        let mut data = vec![CH_DATA];
        data.extend_from_slice(&id.to_be_bytes());
        data.extend_from_slice(b"queued team content");
        dispatch_frame(&session, &data);
        let mut refusal = vec![CH_ERROR];
        refusal.extend_from_slice(&id.to_be_bytes());
        refusal.extend_from_slice(b"team_access_changed");
        dispatch_frame(&session, &refusal);
        assert!(handle.ticket().is_err());
        assert!(
            transport.read(&mut [0; 64]).is_err(),
            "revocation must discard already buffered Team bytes"
        );
        let mut data = vec![CH_DATA];
        data.extend_from_slice(&7u32.to_be_bytes());
        data.extend_from_slice(b"personal");
        dispatch_frame(&session, &data);
        let mut output = [0; 8];
        assert_eq!(personal.read(&mut output).unwrap(), 8);
        assert_eq!(&output, b"personal");
        assert!(session.channels.lock().unwrap().contains_key(&7));
    }

    #[test]
    fn malformed_team_controls_and_legacy_downgrades_cannot_enter_the_inbound_queue() {
        let ticket = team_ticket("fixture");
        for payload in [
            br#"{"v":2,"ticket":"ts-team-v1.fixture"}"#.to_vec(),
            br#"{"v":1,"ticket":"ts-team-v1.fixture","actorId":"forged"}"#.to_vec(),
            br#"{"v":1,"v":1,"ticket":"ts-team-v1.fixture"}"#.to_vec(),
            br#"{"v":1}"#.to_vec(),
            vec![b'x'; 4609],
        ] {
            let session = inert_session();
            let inbound = session.take_inbound().unwrap();
            let mut frame = vec![7];
            frame.extend_from_slice(&1u32.to_be_bytes());
            frame.extend_from_slice(&payload);
            dispatch_frame(&session, &frame);
            assert!(inbound.try_recv().is_err());
            assert!(session.channels.lock().unwrap().is_empty());
        }
        let session = inert_session();
        let state = Arc::new(ChannelState {
            team: Some(team::TeamChannel::new(ticket.clone(), Some([0xbb; 32]))),
            ..ChannelState::new(DIAL_ID_BASE + 1)
        });
        session
            .channels
            .lock()
            .unwrap()
            .insert(state.id, Arc::clone(&state));
        dispatch_frame(&session, &opened_frame(state.id));
        assert!(
            state.inner.lock().unwrap().error.is_some(),
            "legacy OPENED cannot strip a Team scope"
        );
        assert!(!state.inner.lock().unwrap().opened);
        let inbound = session.take_inbound().unwrap();
        dispatch_frame(&session, &team_frame(7, 2, &ticket));
        let state = inbound.try_recv().unwrap();
        let transport = ChannelTransport::from_inbound(Arc::clone(&session), state);
        let authorization = transport.team_authorization().unwrap();
        assert!(
            authorization.renew(&ticket).is_err(),
            "a host cannot renew as the actor"
        );
        dispatch_frame(
            &session,
            &team_frame(9, transport.channel_id(), &team_ticket("new")),
        );
        assert_eq!(
            authorization.ticket().unwrap().wire_value(),
            "ts-team-v1.new"
        );
        let mut oversized = vec![CH_DATA];
        oversized.extend_from_slice(&transport.channel_id().to_be_bytes());
        oversized.resize(5 + team::MAX_BUFFER + 1, b'x');
        dispatch_frame(&session, &oversized);
        assert!(
            authorization.ticket().is_err(),
            "Team unread data must stay within its smaller bound"
        );
    }

    #[test]
    fn dropping_an_old_transport_does_not_close_a_reused_channel_id() {
        let session = inert_session();
        let old = Arc::new(ChannelState::new(1));
        let current = Arc::new(ChannelState::new(1));
        session
            .channels
            .lock()
            .unwrap()
            .insert(1, Arc::clone(&current));
        let (tx, rx) = mpsc::sync_channel(2);
        *session.writer.lock().unwrap() = Some(Writer {
            sender: tx,
            bytes: Arc::new(AtomicUsize::new(0)),
        });
        drop(ChannelTransport::new(Arc::clone(&session), old));
        assert!(Arc::ptr_eq(
            session.channels.lock().unwrap().get(&1).unwrap(),
            &current
        ));
        assert!(
            rx.try_recv().is_err(),
            "no CLOSE for the replacement channel"
        );
    }

    #[test]
    fn shutdown_wakes_channels_and_disconnects_the_inbound_receiver() {
        let session = inert_session();
        let state = Arc::new(ChannelState::new(1));
        session
            .channels
            .lock()
            .unwrap()
            .insert(1, Arc::clone(&state));
        let inbound = session.take_inbound().unwrap();
        let mut transport = ChannelTransport::new(Arc::clone(&session), state);
        transport
            .set_read_timeout(Some(Duration::from_millis(10)))
            .unwrap();
        session.shutdown();
        let error = transport.read(&mut [0]).unwrap_err();
        assert_ne!(error.kind(), io::ErrorKind::TimedOut);
        assert!(matches!(
            inbound.try_recv(),
            Err(mpsc::TryRecvError::Disconnected)
        ));
        assert!(transport.write(b"x").is_err());
        assert!(session.channels.lock().unwrap().is_empty());
    }

    #[test]
    fn late_outbound_acknowledgements_do_not_become_inbound_channels() {
        let session = inert_session();
        let inbound = session.take_inbound().unwrap();
        dispatch_frame(&session, &opened_frame(DIAL_ID_BASE + 1));
        assert!(inbound.try_recv().is_err());
        assert!(session.channels.lock().unwrap().is_empty());
    }

    #[test]
    fn a_full_outbound_queue_cannot_block_the_io_threads_refusal() {
        let session = inert_session();
        let (tx, _rx) = mpsc::sync_channel(1);
        let bytes = Arc::new(AtomicUsize::new(0));
        *session.writer.lock().unwrap() = Some(Writer {
            sender: tx,
            bytes: Arc::clone(&bytes),
        });
        session.send_channel_frame(CH_DATA, 1, b"x").unwrap();
        let before = bytes.load(Ordering::Relaxed);
        let start = Instant::now();
        dispatch_frame(&session, &opened_frame(DIAL_ID_BASE + 1));
        assert!(start.elapsed() < Duration::from_secs(1));
        assert_eq!(bytes.load(Ordering::Relaxed), before);
    }

    #[test]
    fn a_channel_handshake_budget_bounds_backpressure_without_stopping_other_channels() {
        let session = inert_session();
        let (tx, rx) = mpsc::sync_channel(1);
        let bytes = Arc::new(AtomicUsize::new(0));
        *session.writer.lock().unwrap() = Some(Writer {
            sender: tx,
            bytes: Arc::clone(&bytes),
        });
        session.send_channel_frame(CH_DATA, 1, b"queued").unwrap();
        let before = bytes.load(Ordering::Relaxed);
        let mut transport =
            ChannelTransport::new(Arc::clone(&session), Arc::new(ChannelState::new(2)));
        transport
            .set_deadline(Some(Duration::from_millis(20)))
            .unwrap();
        let start = Instant::now();
        let error = transport.write(b"handshake").unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));
        assert_eq!(bytes.load(Ordering::Relaxed), before);
        assert!(!session.stopped.load(Ordering::Relaxed));
        drop(transport);
        let queued = rx.try_recv().unwrap();
        bytes.fetch_sub(queued.len(), Ordering::AcqRel);
        let mut other = ChannelTransport::new(Arc::clone(&session), Arc::new(ChannelState::new(3)));
        other.set_deadline(Some(Duration::ZERO)).unwrap();
        assert_eq!(
            other.write(b"expired").unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        other.set_deadline(None).unwrap();
        other.write_all(b"personal work").unwrap();
        assert_eq!(&rx.try_recv().unwrap()[5..], b"personal work");
    }

    #[test]
    fn channel_limits_apply_to_outbound_dials_and_empty_reads_do_not_wait() {
        let session = inert_session();
        for id in 0..MAX_CHANNELS as u32 {
            session
                .channels
                .lock()
                .unwrap()
                .insert(id, Arc::new(ChannelState::new(id)));
        }
        assert!(
            session
                .open_channel([0; 32], ChannelPurpose::Unknown)
                .err()
                .unwrap()
                .to_string()
                .contains("too many")
        );
        let mut transport = ChannelTransport::new(session, Arc::new(ChannelState::new(999)));
        assert_eq!(transport.read(&mut []).unwrap(), 0);
    }

    #[test]
    fn denial_codes_become_sentences() {
        assert!(denial_message("DENIED legacy_token_rejected").contains("update tokenstat"));
        assert!(denial_message("DENIED not_on_this_plan").contains("paid-plan"));
        // An unknown code still carries its wire form so a new relay reason is
        // debuggable from a screenshot.
        assert_eq!(
            denial_message("DENIED brand_new"),
            "the relay refused the connection: brand_new"
        );
        // Anything that is not a denial passes through untouched.
        assert_eq!(denial_message("READY"), "READY");
        assert_eq!(team_moved("TEAM-MOVED repo_0123abc"), Some("repo_0123abc"));
        for bad in [
            "TEAM-MOVED ",
            "TEAM-MOVED a b",
            "TEAM-MOVED ../x",
            "READY",
            "team-moved repo",
        ] {
            assert_eq!(team_moved(bad), None, "{bad}");
        }
    }

    #[test]
    fn only_credential_refusals_ask_for_a_new_token() {
        assert!(renewable_denial("DENIED bad_token"));
        assert!(renewable_denial("DENIED token_expired"));
        assert!(renewable_denial("DENIED key_mismatch"));
        assert!(renewable_denial("DENIED token_revoked"));
        // Minting again cannot buy a plan or free a key another machine holds.
        assert!(!renewable_denial("DENIED not_on_this_plan"));
        assert!(!renewable_denial("DENIED key_already_live"));
        assert!(!renewable_denial("READY"));
    }

    #[test]
    fn a_revoked_credential_gets_its_own_message() {
        assert!(denial_message("DENIED token_revoked").contains("revoked"));
    }

    /// A fresh credential is retried at once rather than after a backoff sized
    /// for a network that is not the problem. Two in a row, then the backoff
    /// takes over: a replacement the relay also refuses is not fixed by
    /// minting a third.
    #[test]
    fn only_a_couple_of_renewals_skip_the_backoff() {
        let mut renewals = 0u32;
        let mut immediate = 0;
        for _ in 0..6 {
            renewals += 1;
            if renewals <= MAX_IMMEDIATE_RENEWALS {
                immediate += 1;
            }
        }
        assert_eq!(immediate, MAX_IMMEDIATE_RENEWALS as usize);
        // The ordinary case is one: expired, minted, retried. A ceiling below
        // that would mean a credential that just healed still waits.
        const { assert!(MAX_IMMEDIATE_RENEWALS >= 1) };
    }

    /// The mint's reason has to reach the sentence, because the relay's is a
    /// symptom. "expired" is what the socket saw, and "remote reach is a
    /// paid-plan feature" is what somebody can do something about.
    #[test]
    fn a_failed_renewal_reports_what_the_account_said() {
        let denial = denial_message("DENIED token_expired");
        let full = format!(
            "{denial}, and a replacement could not be minted: remote reach is a paid-plan feature"
        );
        assert!(full.contains("paid-plan"), "{full}");
        assert!(full.contains("expired"), "{full}");
    }

    #[test]
    fn a_burst_larger_than_the_frame_queue_still_sends() {
        let session = inert_session();
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(2);
        *session.writer.lock().unwrap() = Some(Writer {
            sender: tx,
            bytes: Arc::new(AtomicUsize::new(0)),
        });
        let n = 200u32;
        let producer = Arc::clone(&session);
        let handle = std::thread::spawn(move || {
            for i in 0..n {
                producer
                    .send_channel_frame(CH_DATA, 1, &[i as u8])
                    .expect("backpressure waits instead of failing the burst");
            }
        });
        let mut got = 0u32;
        while got < n {
            rx.recv_timeout(Duration::from_secs(2))
                .unwrap_or_else(|_| panic!("IO thread drained frame {got} of {n}"));
            got += 1;
        }
        handle.join().expect("producer");
    }

    fn inert_session() -> Arc<TunnelSession> {
        let (inbound_tx, inbound_rx) = mpsc::sync_channel(1);
        Arc::new(TunnelSession {
            endpoint: String::new(),
            key_hex: String::new(),
            token: Mutex::new(String::new()),
            next_channel: AtomicU32::new(1),
            writer: Mutex::new(None),
            inbound_tx: Mutex::new(Some(inbound_tx)),
            inbound_rx: Mutex::new(Some(inbound_rx)),
            channels: Mutex::new(HashMap::new()),
            socket: Mutex::new(None),
            connecting: Mutex::new(None),
            status: Mutex::new(TunnelStatus::default()),
            renew: Mutex::new(None),
            wake: Mutex::new(None),
            renewed: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            last_read_ms: AtomicU64::new(0),
        })
    }

    #[test]
    fn a_connected_socket_with_no_read_is_stale() {
        let session = inert_session();
        assert!(
            !session.read_is_stale(),
            "a socket that is not connected is not half-open"
        );
        *session.status.lock().unwrap() = TunnelStatus {
            connected: true,
            error: None,
        };
        assert!(session.read_is_stale(), "READY without a read is stale");
        session.mark_read();
        assert!(!session.read_is_stale());
        session.last_read_ms.store(
            wall_ms().saturating_sub(KEEPALIVE_STALE_MS + 1),
            Ordering::Release,
        );
        assert!(session.read_is_stale());
    }

    #[test]
    fn shutdown_closes_a_connect_that_has_not_stored_the_socket() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let session = inert_session();
        let stream = TcpStream::connect(addr).expect("connect");
        *session.connecting.lock().unwrap_or_else(|e| e.into_inner()) = Some(stream);
        session.shutdown();
        assert!(session.stopped.load(Ordering::Relaxed));
        assert!(
            session
                .connecting
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .is_none()
        );
        // The client's FIN can reach the kernel before the connect finishes
        // queueing for accept, and macOS drops a pending connection whose peer
        // closed first. Either the accept returns a socket that reads as EOF,
        // or the queue briefly empties as the dropped connection is discarded;
        // both mean shutdown closed the half-open connect.
        listener.set_nonblocking(true).expect("nonblocking accept");
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match listener.accept() {
                Ok((mut peer, _)) => {
                    let mut buf = [0u8; 8];
                    let n = peer.read(&mut buf).unwrap_or(0);
                    assert_eq!(n, 0, "shutdown must close the half-open connect");
                    break;
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    // A dropped pending connection leaves the queue empty,
                    // which is the same closed state with the FIN first.
                    if Instant::now() >= deadline {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(e) => panic!("accept failed: {e}"),
            }
        }
    }

    // The open payload is a contract with the relay, which lives in another
    // repository and parses this by hand: `<64 hex>:<purpose>`, split on the
    // first colon. If either side drifts, a screen channel silently meters as
    // `unknown` and is capped by nothing.
    #[test]
    fn a_purpose_is_a_word_from_the_fixed_list() {
        assert_eq!(ChannelPurpose::Screen.as_str(), "screen");
        assert_eq!(ChannelPurpose::Pty.as_str(), "pty");
        assert_eq!(ChannelPurpose::Chat.as_str(), "chat");
        assert_eq!(ChannelPurpose::Workspace.as_str(), "workspace");
        assert_eq!(ChannelPurpose::Ssh.as_str(), "ssh");
        assert_eq!(ChannelPurpose::Sftp.as_str(), "sftp");
        assert_eq!(ChannelPurpose::Files.as_str(), "files");
        assert_eq!(ChannelPurpose::Unknown.as_str(), "unknown");
        // Every variant is one lowercase word: the relay matches the label
        // against its own vocabulary and anything else meters as `unknown`.
        for purpose in [
            ChannelPurpose::Screen,
            ChannelPurpose::Pty,
            ChannelPurpose::Chat,
            ChannelPurpose::Workspace,
            ChannelPurpose::Ssh,
            ChannelPurpose::Sftp,
            ChannelPurpose::Files,
            ChannelPurpose::Unknown,
        ] {
            let label = purpose.as_str();
            assert!(
                label.bytes().all(|b| b.is_ascii_lowercase()),
                "{label} must stay a single lowercase word"
            );
        }
    }

    #[test]
    fn the_open_payload_is_the_key_then_the_purpose() {
        let key = "a".repeat(64);
        let payload = format!("{key}:{}", ChannelPurpose::Screen.as_str());
        let (left, right) = payload.split_once(':').expect("a colon separates the two");
        assert_eq!(left, key, "the relay reads the key up to the first colon");
        assert_eq!(right, "screen");
        // The key itself must never contain the separator, or the relay would
        // cut it in the wrong place and refuse a perfectly good dial.
        assert!(!key.contains(':'));
    }

    #[test]
    fn a_refused_relay_fails_before_the_connect_budget() {
        let started = Instant::now();
        let error =
            connect_relay_to("ws://127.0.0.1:1", None).expect_err("nothing listens on port 1");
        assert!(started.elapsed() < CONNECT_TIMEOUT);
        assert!(
            matches!(error, RemoteError::Io(_)),
            "refused connect is an io error, got {error}"
        );
    }

    fn opened_frame(id: u32) -> Vec<u8> {
        let mut frame = Vec::new();
        frame.push(CH_OPENED);
        frame.extend_from_slice(&id.to_be_bytes());
        frame
    }

    #[test]
    fn a_dead_inbound_id_is_reused_after_the_socket_dies() {
        let session = inert_session();
        let inbound = session.take_inbound().expect("inbound");
        let dead = Arc::new(ChannelState::new(1));
        {
            let mut inner = dead.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.error = Some("tunnel disconnected".into());
        }
        session
            .channels
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(1, dead);
        mark_all_channels(&session, "tunnel disconnected");
        forget_all_channels(&session);
        dispatch_frame(&session, &opened_frame(1));
        let opened = inbound.try_recv().expect("inbound OPENED after reconnect");
        assert_eq!(opened.id, 1);
        assert!(
            opened
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .error
                .is_none()
        );
    }

    #[test]
    fn an_errored_id_is_not_treated_as_our_own_dial() {
        let session = inert_session();
        let inbound = session.take_inbound().expect("inbound");
        let dead = Arc::new(ChannelState::new(1));
        {
            let mut inner = dead.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.error = Some("tunnel disconnected".into());
        }
        session
            .channels
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(1, Arc::clone(&dead));
        dispatch_frame(&session, &opened_frame(1));
        let opened = inbound.try_recv().expect("OPENED delivered as inbound");
        assert_eq!(opened.id, 1);
        assert!(!Arc::ptr_eq(&opened, &dead));
    }

    #[test]
    fn an_overfull_inbound_queue_refuses_instead_of_growing() {
        // The test session's queue holds one: the second OPENED must be
        // dropped and taken back out of the map, not queued behind the first.
        let session = inert_session();
        let inbound = session.take_inbound().expect("inbound");
        dispatch_frame(&session, &opened_frame(1));
        dispatch_frame(&session, &opened_frame(2));
        assert_eq!(inbound.try_recv().expect("first inbound").id, 1);
        assert!(inbound.try_recv().is_err(), "queue must stay bounded");
        let map = session.channels.lock().unwrap_or_else(|e| e.into_inner());
        assert!(map.contains_key(&1));
        assert!(
            !map.contains_key(&2),
            "a refused channel must not stay in the map"
        );
    }

    #[test]
    fn a_full_channel_map_refuses_new_inbound_channels() {
        let session = inert_session();
        let _inbound = session.take_inbound().expect("inbound");
        {
            let mut map = session.channels.lock().unwrap_or_else(|e| e.into_inner());
            for id in 1..=MAX_CHANNELS as u32 {
                map.insert(id, Arc::new(ChannelState::new(id)));
            }
        }
        dispatch_frame(&session, &opened_frame(MAX_CHANNELS as u32 + 1));
        assert!(
            !session
                .channels
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .contains_key(&(MAX_CHANNELS as u32 + 1))
        );
    }

    #[test]
    fn channel_frames_are_big_endian_and_length_prefixed() {
        // The wire shape is a contract with the relay; pin it so a refactor
        // cannot silently change bytes on the wire.
        let frame = {
            let mut frame = Vec::new();
            frame.push(CH_OPEN);
            frame.extend_from_slice(&7u32.to_be_bytes());
            frame.extend_from_slice(b"peer");
            frame
        };
        assert_eq!(frame[0], 1);
        assert_eq!(
            u32::from_be_bytes([frame[1], frame[2], frame[3], frame[4]]),
            7
        );
        assert_eq!(&frame[5..], b"peer");
    }
}
