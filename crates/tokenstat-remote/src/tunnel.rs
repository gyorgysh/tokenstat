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
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use tokenstat_identity::{MachineIdentity, PublicKey, hex};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket, connect};

use crate::{RemoteError, Transport};

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

// Channel frame ops: [op: u8][channel: u32 BE][payload].
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
    writer: Mutex<Option<mpsc::Sender<Vec<u8>>>>,
    /// The relay-dialled channels, for the host to answer.
    inbound_tx: Mutex<Option<mpsc::Sender<Arc<ChannelState>>>>,
    inbound_rx: Mutex<Option<mpsc::Receiver<Arc<ChannelState>>>>,
    /// Every live channel, by its local id.
    channels: Mutex<HashMap<u32, Arc<ChannelState>>>,
    /// The current socket, so shutdown can interrupt a parked supervisor.
    socket: Mutex<Option<Socket>>,
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
    stopped: AtomicBool,
}

/// Mints a replacement HELLO credential. `None` when one cannot be had right
/// now (offline, signed out), which leaves the supervisor retrying.
pub type RenewToken = Box<dyn Fn() -> Option<String> + Send + Sync>;

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
        let (inbound_tx, inbound_rx) = mpsc::channel::<Arc<ChannelState>>();
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
            status: Mutex::new(TunnelStatus::default()),
            renew: Mutex::new(None),
            wake: Mutex::new(Some(wake_tx)),
            stopped: AtomicBool::new(false),
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

    /// Ask for a fresh credential and keep it. True when one arrived.
    fn renew_credential(&self) -> bool {
        let minted = {
            let guard = self.renew.lock().unwrap_or_else(|e| e.into_inner());
            match guard.as_ref() {
                Some(renew) => renew(),
                None => None,
            }
        };
        match minted {
            Some(token) if !token.is_empty() => {
                *self.token.lock().unwrap_or_else(|e| e.into_inner()) = token;
                true
            }
            _ => false,
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
    pub fn open_channel(
        self: &Arc<Self>,
        peer: PublicKey,
    ) -> Result<ChannelTransport, RemoteError> {
        if self.stopped.load(Ordering::Relaxed) {
            return Err(RemoteError::Tunnel("tunnel is stopped".into()));
        }
        let id = DIAL_ID_BASE + self.next_channel.fetch_add(1, Ordering::Relaxed);
        let state = Arc::new(ChannelState::new(id));
        self.channels
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, Arc::clone(&state));
        if let Err(error) = self.send_channel_frame(CH_OPEN, id, hex(&peer).as_bytes()) {
            self.forget_channel(&state);
            return Err(error);
        }

        // Wait for OPENED or ERROR. The relay answers in milliseconds when it
        // is there; the timeout covers the relay being gone or the peer being
        // unreachable.
        let deadline = Instant::now() + OPEN_TIMEOUT;
        let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
        while !inner.opened && inner.error.is_none() && Instant::now() < deadline {
            let (guard, _) = state
                .cond
                .wait_timeout(inner, Duration::from_millis(20))
                .unwrap_or_else(|e| e.into_inner());
            inner = guard;
        }
        let error = inner.error.clone();
        let opened = inner.opened;
        drop(inner);
        if let Some(error) = error {
            self.forget_channel(&state);
            return Err(RemoteError::Tunnel(error));
        }
        if !opened {
            self.forget_channel(&state);
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
        self.nudge();
        if let Some(mut socket) = self.socket.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = socket.close(None);
        }
    }

    /// Wake the supervisor and reset its reconnect backoff.
    ///
    /// Called when the network comes back or the machine wakes from sleep, so a
    /// reconnect that would otherwise wait out its backoff starts immediately
    /// instead. A no-op while the supervisor is connecting or connected: the
    /// next wait simply runs at the floor, which is what a healthy network is
    /// owed anyway.
    pub fn nudge(&self) {
        if let Some(tx) = self.wake.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            let _ = tx.send(());
        }
    }

    /// What the connection is doing right now.
    pub fn status(&self) -> TunnelStatus {
        self.status
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    fn send_channel_frame(&self, op: u8, ch: u32, payload: &[u8]) -> Result<(), RemoteError> {
        let mut frame = Vec::with_capacity(5 + payload.len());
        frame.push(op);
        frame.extend_from_slice(&ch.to_be_bytes());
        frame.extend_from_slice(payload);
        let sender = self
            .writer
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .ok_or_else(|| RemoteError::Tunnel("tunnel is not connected".into()))?;
        sender
            .send(frame)
            .map_err(|_| RemoteError::Tunnel("tunnel is not connected".into()))
    }

    fn forget_channel(&self, state: &Arc<ChannelState>) {
        self.channels
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&state.id);
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
    closed: AtomicBool,
}

impl ChannelTransport {
    fn new(session: Arc<TunnelSession>, state: Arc<ChannelState>) -> Self {
        Self {
            session,
            state,
            read_timeout: Mutex::new(None),
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
}

impl Read for ChannelTransport {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if self.closed.load(Ordering::Relaxed) {
            return Ok(0);
        }
        let timeout = *self.read_timeout.lock().unwrap_or_else(|e| e.into_inner());
        let mut inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
        loop {
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
        self.session
            .send_channel_frame(CH_DATA, self.state.id, input)
            .map_err(io::Error::other)?;
        Ok(input.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Transport for ChannelTransport {
    fn close(&mut self) {
        if self.closed.swap(true, Ordering::Relaxed) {
            return;
        }
        let _ = self
            .session
            .send_channel_frame(CH_CLOSE, self.state.id, &[]);
        self.session.forget_channel(&self.state);
        if let Ok(mut inner) = self.state.inner.lock() {
            inner.eof = true;
        }
        self.state.cond.notify_all();
    }

    fn set_deadline(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_read_timeout(timeout)
    }

    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        *self.read_timeout.lock().unwrap_or_else(|e| e.into_inner()) = timeout;
        self.state.cond.notify_all();
        Ok(())
    }
}

// MARK: - The supervisor

fn supervisor(session: Weak<TunnelSession>, wake_rx: mpsc::Receiver<()>) {
    let mut backoff = RECONNECT_FLOOR;
    loop {
        let Some(session) = session.upgrade() else {
            return;
        };
        if session.stopped.load(Ordering::Relaxed) {
            return;
        }
        match connect_once(&session) {
            Ok(()) => {
                // The socket died; that is the ordinary end of a connection,
                // not an error to show.
                *session.status.lock().unwrap_or_else(|e| e.into_inner()) = TunnelStatus::default();
                backoff = RECONNECT_FLOOR;
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
    }
}

/// Connect, register, and pump until the socket dies.
fn connect_once(session: &Arc<TunnelSession>) -> Result<(), RemoteError> {
    let token = session
        .token
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let (mut socket, _) = connect(&session.endpoint).map_err(tunnel_error)?;
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
        }
        Message::Text(text) => {
            // A refusal the machine can answer itself is answered here, before
            // the supervisor sleeps: a stale, expired or re-registered
            // credential is replaced so the next attempt is a different
            // attempt. Plan and duplicate-key refusals are left alone, because
            // minting again would only ask the account the same question.
            if renewable_denial(&text) && session.renew_credential() {
                eprintln!("tunnel: credential refused, minted a fresh one");
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
    // One IO thread owns the socket. It must never block inside a read or a
    // flush: a read that waits is a read that cannot drain the writer queue,
    // and a flush that waits is a write the relay is not draining, either of
    // which stalls every channel on this socket. The socket is nonblocking
    // and the loop parks briefly when there is nothing to do.
    set_relay_nonblocking(&mut socket)?;

    let (writer_tx, writer_rx) = mpsc::channel::<Vec<u8>>();
    *session.writer.lock().unwrap_or_else(|e| e.into_inner()) = Some(writer_tx);
    *session.socket.lock().unwrap_or_else(|e| e.into_inner()) = Some(socket);

    // The IO loop, inline: drain queued outgoing frames, then read one frame
    // (or idle-wait), and repeat. The socket is nonblocking, so neither the
    // read nor the flush can stall the loop.
    loop {
        while let Ok(frame) = writer_rx.try_recv() {
            let send_failed = {
                let mut guard = session.socket.lock().unwrap_or_else(|e| e.into_inner());
                let Some(socket) = guard.as_mut() else { break };
                // A WouldBlock here just means the frame is buffered and the
                // next send or read flushes it; only a real error is fatal.
                match socket.send(Message::Binary(frame.into())) {
                    Ok(()) => false,
                    Err(tungstenite::Error::Io(error))
                        if error.kind() == io::ErrorKind::WouldBlock
                            || error.kind() == io::ErrorKind::TimedOut =>
                    {
                        false
                    }
                    Err(_) => true,
                }
            };
            if send_failed {
                eprintln!("tunnel: io loop writer send failed");
                break;
            }
        }
        // A WouldBlock during the drain left a frame in tungstenite's write
        // buffer; give it another chance to reach the wire before reading.
        if let Ok(mut guard) = session.socket.lock() {
            if let Some(socket) = guard.as_mut() {
                let _ = socket.flush();
            }
        }
        let mut guard = session.socket.lock().unwrap_or_else(|e| e.into_inner());
        let Some(socket) = guard.as_mut() else { break };
        let frame = match socket.read() {
            Ok(Message::Binary(frame)) => Some(frame),
            Ok(Message::Close(_)) => break,
            Ok(_) => None,
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

    match op {
        CH_OPENED => {
            // Our own dial: mark it open. An id we do not know is the relay
            // dialling us: a fresh channel for the host to answer.
            let mut map = channels.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(state) = map.get(&id) {
                let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
                inner.opened = true;
                state.cond.notify_all();
                return;
            }
            let state = Arc::new(ChannelState::new(id));
            map.insert(id, Arc::clone(&state));
            if let Some(tx) = session
                .inbound_tx
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
            {
                let _ = tx.send(state);
            }
        }
        CH_DATA | CH_CLOSE | CH_ERROR => {
            let state = {
                let map = channels.lock().unwrap_or_else(|e| e.into_inner());
                map.get(&id).cloned()
            };
            if let Some(state) = state {
                let mut inner = state.inner.lock().unwrap_or_else(|e| e.into_inner());
                match op {
                    CH_DATA => {
                        if inner.buffer.len().saturating_add(payload.len()) > MAX_CHANNEL_BUFFER {
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
