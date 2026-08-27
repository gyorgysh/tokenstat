// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! One machine reaching another, over a channel neither end shares with anyone.
//!
//! # What this carries
//!
//! The same request and response `tokenstat-host::dispatch` already answers,
//! over a third transport. That is the point: a method cannot exist over the
//! socket and be missing here, because there is one dispatch and this is a
//! caller of it.
//!
//! What it carries is *not* what sync carries. Sync moves aggregate counters.
//! This moves terminal output, file contents and diffs, which is the whole of
//! somebody's work. `docs/remote-transport.md` is the reasoning; the part that
//! decides this crate is that nothing in the middle may be able to read it.
//!
//! # The handshake
//!
//! `Noise_XX_25519_ChaChaPoly_BLAKE2s`. Both ends present a static key and each
//! checks the other against what it pinned. There is no certificate and no
//! authority, because there is no name to bind and no third party to consult:
//! the static key **is** the identity.
//!
//! Two rules are enforced here rather than left to a caller, because a caller
//! that forgets either produces something that looks like it works:
//!
//! - A server serves nobody it has not approved. Unknown is refused, and
//!   recorded as pending so a person can be asked.
//! - A client refuses a server whose key is not the one it expected, and says
//!   which of the two explanations to go and check.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use thiserror::Error;
use tokenstat_identity::{MachineIdentity, PeerStore, PublicKey, Trust, fingerprint};

pub mod tunnel;

/// The Noise pattern. XX rather than KK because the server does not know the
/// client's key in advance: a machine that has never connected still has to
/// reach the point where it can be *offered* for approval, and KK would refuse
/// it before anybody could see it had tried.
const PATTERN: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";

/// Noise caps a message at 65535 bytes including its 16-byte tag. Frames are
/// split to fit, so a large file diff is several frames rather than an error.
const MAX_NOISE_MESSAGE: usize = 65535;
const MAX_PAYLOAD: usize = MAX_NOISE_MESSAGE - 16;

/// The default port. Registered with nobody, picked to sit above the range
/// anything common uses.
pub const DEFAULT_PORT: u16 = 7878;

/// How long a peer gets to complete a handshake before it is dropped.
///
/// Without this, a connection that opens and then says nothing holds a thread
/// for as long as it likes, which is a denial of service anyone on the network
/// can perform with `nc`.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a connect may take before the peer is treated as unreachable.
///
/// Separate from the handshake timeout because the failure is different: an
/// address that will not accept TCP is a machine that is offline or gone, and
/// nobody benefits from waiting out the OS's own minutes-long timeout. A front
/// end refreshes the peer list on a timer, so a dead peer must fail in seconds,
/// not pile up stalled connections in the pool.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Error)]
pub enum RemoteError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("noise: {0}")]
    Noise(String),
    #[error("identity: {0}")]
    Identity(#[from] tokenstat_identity::IdentityError),
    #[error(
        "{label} offered the key {offered}, and {pinned} was pinned for it. \
         Refusing to connect. Either that machine was reinstalled, in which case \
         forget it here and pair it again, or something is answering in its place."
    )]
    WrongKey {
        label: String,
        pinned: String,
        offered: String,
    },
    #[error(
        "{0} has not approved this machine yet. Its fingerprint is now in that \
         machine's peer list, waiting for someone to allow it."
    )]
    NotApproved(String),
    #[error("the peer sent a {0} byte frame, and the limit is {1}")]
    FrameTooLarge(u64, usize),
    #[error("the connection closed before the answer arrived")]
    Closed,
    #[error(
        "the link failed in the middle of a message, so the stream can no \
         longer be read in step and this connection has to be replaced"
    )]
    BrokenMessage,
    #[error("tunnel: {0}")]
    Tunnel(String),
}

/// A bidirectional byte stream used by the authenticated connection.
pub trait Transport: Read + Write + Send {
    /// Close the underlying stream or WebSocket.
    fn close(&mut self);

    /// Set the handshake timeout. Transports without a native deadline may
    /// leave this as a no-op because their connection setup has its own limit.
    fn set_deadline(&mut self, timeout: Option<Duration>) -> std::io::Result<()>;

    /// Set the read timeout on the underlying socket.
    ///
    /// A stream split into read and write halves shares one transport, and a
    /// reader that blocks forever would starve the writer. A bounded read
    /// timeout is what lets the reader give the lock back; a timed-out read
    /// means "no data yet", never a failure.
    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> std::io::Result<()>;
}

impl<T: Transport + ?Sized> Transport for Box<T> {
    fn close(&mut self) {
        (**self).close();
    }

    fn set_deadline(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
        (**self).set_deadline(timeout)
    }

    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
        (**self).set_read_timeout(timeout)
    }
}

impl Transport for TcpStream {
    fn close(&mut self) {
        let _ = self.shutdown(std::net::Shutdown::Both);
    }

    fn set_deadline(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.set_read_timeout(timeout)?;
        self.set_write_timeout(timeout)
    }

    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
        TcpStream::set_read_timeout(self, timeout)
    }
}

impl From<snow::Error> for RemoteError {
    fn from(e: snow::Error) -> Self {
        RemoteError::Noise(e.to_string())
    }
}

/// An established, authenticated, encrypted connection.
///
/// Framing above the encryption is the daemon's own: one JSON request per
/// message, one response per message. The unix socket uses newlines for the
/// same envelope; here the length is already framed by Noise, so there is
/// nothing for a newline to disambiguate.
pub struct Connection {
    stream: Box<dyn Transport>,
    noise: snow::TransportState,
    /// Who is on the other end. Already checked by the time this exists.
    peer: PublicKey,
    /// Friendly name the peer sent in the handshake (device name). Empty when
    /// the far side is older and sent nothing.
    intro_label: String,
}

/// Names the peer and nothing else. The keying material inside the transport
/// state must never reach a log line, so this is written by hand rather than
/// derived.
impl std::fmt::Debug for Connection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connection")
            .field("peer", &self.peer_fingerprint())
            .finish_non_exhaustive()
    }
}

impl Connection {
    /// The peer's static key. Authenticated by the handshake, so a caller can
    /// use it to decide what this connection is allowed to do.
    pub fn peer_key(&self) -> PublicKey {
        self.peer
    }

    pub fn peer_fingerprint(&self) -> String {
        fingerprint(&self.peer)
    }

    /// Device name from the peer's handshake intro, when it sent one.
    pub fn intro_label(&self) -> &str {
        &self.intro_label
    }

    /// Send one message.
    pub fn send(&mut self, payload: &[u8]) -> Result<(), RemoteError> {
        write_one(&mut self.noise, &mut *self.stream, payload)
    }

    /// Receive one message.
    ///
    /// `max` bounds what this end is willing to allocate for a peer that claims
    /// a large frame. An approved peer is trusted, not unlimited: a bug on the
    /// other side should not be able to exhaust this machine's memory.
    pub fn receive(&mut self, max: usize) -> Result<Vec<u8>, RemoteError> {
        read_one(&mut self.noise, &mut *self.stream, max, None)
    }

    /// Receive one message, giving up when nothing arrives for `idle`.
    ///
    /// `receive` waits forever on purpose: a request/response caller cannot
    /// know how long the far side needs. That is right for a peer that is
    /// answering slowly and wrong for one that has stopped answering at all.
    /// A Mac that sleeps leaves its relay socket open until the keepalive
    /// notices, and until then a read here has nothing to wake it, so the
    /// caller's thread and the connection it holds are parked on a machine
    /// that is not coming back within the caller's patience anyway.
    ///
    /// The budget covers silence, not the whole answer: once the frame starts
    /// arriving it is read to the end with no deadline.
    pub fn receive_within(&mut self, max: usize, idle: Duration) -> Result<Vec<u8>, RemoteError> {
        let result = read_one(&mut self.noise, &mut *self.stream, max, Some(idle));
        // `read_one` leaves the idle timeout on the transport for the next
        // frame. This connection goes back into a pool where the next caller
        // decides its own budget, so hand it back the way it was found.
        let _ = self.stream.set_read_timeout(None);
        result
    }

    /// Close the socket. Idempotent, and a failure is not worth reporting: the
    /// connection is being abandoned either way.
    pub fn close(&mut self) {
        self.stream.close();
    }

    /// Split into independent read and write halves for a byte stream.
    ///
    /// The proxy and the terminal subscription both need bytes moving in both
    /// directions at once, which a single request/response owner cannot do.
    /// The halves share one Noise session behind a mutex; the read half uses a
    /// short read timeout so an idle reader gives the writer the lock back
    /// within milliseconds. An empty message is a clean end-of-stream.
    pub fn split(self) -> (StreamReader, StreamWriter) {
        let Connection {
            stream,
            noise,
            peer: _,
            intro_label: _,
        } = self;
        let mut core = Core {
            noise,
            stream,
            closed: std::sync::atomic::AtomicBool::new(false),
        };
        let _ = core.stream.set_read_timeout(Some(STREAM_READ_TIMEOUT));
        let core = Arc::new(Mutex::new(core));
        (
            StreamReader {
                core: Arc::clone(&core),
            },
            StreamWriter { core },
        )
    }
}

/// How long the read half of a split stream waits for data before giving the
/// writer the lock. Short enough that a write behind an idle reader is never
/// visibly stalled. A timeout inside a partially arrived frame (the length
/// header in, the body still coming) means the link is dying anyway; the next
/// read fails loudly rather than silently corrupting anything.
const STREAM_READ_TIMEOUT: Duration = Duration::from_millis(50);

/// How long the rest of a message may take once its first frame has arrived.
///
/// Not the same budget as the wait before a message, and it cannot be: the
/// short one exists so an idle reader hands the writer the lock, and applying
/// it inside a message is what used to tear the stream in half. A message that
/// has started is being delivered, so the only question here is whether the
/// far side is still alive at all.
const MESSAGE_STALL_TIMEOUT: Duration = Duration::from_secs(30);

/// The shared state of a split connection: one Noise session, one transport,
/// one ownership flag.
struct Core {
    noise: snow::TransportState,
    stream: Box<dyn Transport>,
    closed: std::sync::atomic::AtomicBool,
}

/// The read half of a split connection.
pub struct StreamReader {
    core: Arc<Mutex<Core>>,
}

impl StreamReader {
    /// Read one message. An empty vec is a clean end-of-stream. A read that
    /// simply found no data yet is retried rather than reported, so the caller
    /// sees either bytes, EOF, or a real failure.
    pub fn read(&self, max: usize) -> Result<Vec<u8>, RemoteError> {
        loop {
            let mut guard = self.core.lock().map_err(|_| RemoteError::Closed)?;
            let Core {
                noise,
                stream,
                closed,
            } = &mut *guard;
            if closed.load(std::sync::atomic::Ordering::Relaxed) {
                return Err(RemoteError::Closed);
            }
            match read_one(noise, &mut **stream, max, Some(STREAM_READ_TIMEOUT)) {
                // Nothing arrived yet. No bytes were taken off the transport,
                // so the next pass starts where this one did.
                Err(RemoteError::Io(e))
                    if e.kind() == std::io::ErrorKind::TimedOut
                        || e.kind() == std::io::ErrorKind::WouldBlock => {}
                // Anything else leaves the stream somewhere it cannot be read
                // in step from again, so the connection is finished rather
                // than merely unlucky. Closing here is what stops a later
                // caller picking it up and reading ciphertext as a header.
                other => {
                    if other.is_err() {
                        closed.store(true, std::sync::atomic::Ordering::Relaxed);
                    }
                    return other;
                }
            }
            drop(guard);
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Close the underlying stream. Idempotent.
    pub fn close(&self) {
        if let Ok(mut guard) = self.core.lock() {
            guard
                .closed
                .store(true, std::sync::atomic::Ordering::Relaxed);
            guard.stream.close();
        }
    }
}

/// The write half of a split connection.
#[derive(Clone)]
pub struct StreamWriter {
    core: Arc<Mutex<Core>>,
}

impl StreamWriter {
    /// Send one message. An empty slice is a clean end-of-stream marker.
    pub fn write(&self, payload: &[u8]) -> Result<(), RemoteError> {
        let mut guard = self.core.lock().map_err(|_| RemoteError::Closed)?;
        let Core {
            noise,
            stream,
            closed,
        } = &mut *guard;
        if closed.load(std::sync::atomic::Ordering::Relaxed) {
            return Err(RemoteError::Closed);
        }
        write_one(noise, &mut **stream, payload)
    }

    /// Close the underlying stream. Idempotent.
    pub fn close(&self) {
        if let Ok(mut guard) = self.core.lock() {
            guard
                .closed
                .store(true, std::sync::atomic::Ordering::Relaxed);
            guard.stream.close();
        }
    }
}

/// Send one message over an established Noise session. A payload larger than
/// one Noise message is split across several, with a total length in front so
/// the far end knows when it has all of it; a file's diff exceeds 64 KB
/// routinely.
fn write_one(
    noise: &mut snow::TransportState,
    stream: &mut dyn Transport,
    payload: &[u8],
) -> Result<(), RemoteError> {
    let mut header = [0u8; 4];
    let total = u32::try_from(payload.len())
        .map_err(|_| RemoteError::FrameTooLarge(payload.len() as u64, u32::MAX as usize))?;
    header.copy_from_slice(&total.to_be_bytes());
    write_noise_frame(noise, stream, &header)?;

    for chunk in payload.chunks(MAX_PAYLOAD) {
        write_noise_frame(noise, stream, chunk)?;
    }
    stream.flush()?;
    Ok(())
}

fn write_noise_frame(
    noise: &mut snow::TransportState,
    stream: &mut dyn Transport,
    plaintext: &[u8],
) -> Result<(), RemoteError> {
    let mut buffer = vec![0u8; plaintext.len() + 16];
    let n = noise.write_message(plaintext, &mut buffer)?;
    write_framed(stream, &buffer[..n])
}

fn read_one(
    noise: &mut snow::TransportState,
    stream: &mut dyn Transport,
    max: usize,
    idle_timeout: Option<Duration>,
) -> Result<Vec<u8>, RemoteError> {
    let header = read_noise_frame(noise, stream, idle_timeout)?;
    if header.len() != 4 {
        return Err(RemoteError::Noise(format!(
            "expected a 4 byte length header, got {}",
            header.len()
        )));
    }
    let total = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
    if total > max {
        return Err(RemoteError::FrameTooLarge(total as u64, max));
    }

    // The message has started, so the deadline comes off the transport until
    // it ends.
    //
    // `read_framed`'s no-deadline path calls `read_exact`, which *discards the
    // bytes it already consumed* when it fails. The idle timeout `split` arms
    // is a property of the transport, not of the call, so without this the
    // continuation frames were read with a 50 ms deadline still live: one
    // relay gap inside a large message dropped part of a frame, the stream
    // never came back into step, and the next four bytes read as a length
    // header were ciphertext. A 1 MiB video frame is seventeen Noise messages,
    // which is why the screen stream met this and request/response never did.
    //
    // The budget covers silence *before* a message. Inside one there is
    // nothing to wait for but the rest of it.
    let restore = idle_timeout.is_some();
    if restore {
        // A long deadline rather than none at all. None would trade the
        // desynchronised stream for a parked one: the reader on a split
        // connection holds the shared lock while it waits, so a peer whose
        // Mac went to sleep half way through a frame would starve the writer
        // for as long as the socket stayed open. This is long enough that no
        // healthy link reaches it and short enough that a dead one is noticed,
        // and hitting it now ends the connection instead of corrupting it.
        stream
            .set_read_timeout(Some(MESSAGE_STALL_TIMEOUT))
            .map_err(RemoteError::Io)?;
    }
    let result = read_remaining_frames(noise, stream, total);
    if restore {
        // Best effort: the value is going back the way it was found, and a
        // transport that cannot take it is already failing the read above.
        let _ = stream.set_read_timeout(idle_timeout);
    }
    result
}

/// Read the frames after the header, treating every failure as terminal.
///
/// A timeout in here is not "no data yet". Part of the message has been taken
/// off the transport already, so there is nothing to retry into: the caller
/// must drop the connection. Mapping it away from `Io` is what stops
/// `StreamReader::read` from looping back and reading from the middle of a
/// frame.
fn read_remaining_frames(
    noise: &mut snow::TransportState,
    stream: &mut dyn Transport,
    total: usize,
) -> Result<Vec<u8>, RemoteError> {
    let mut payload = Vec::with_capacity(total.min(MAX_NOISE_MESSAGE));
    while payload.len() < total {
        let chunk = read_noise_frame(noise, stream, None).map_err(|error| match error {
            RemoteError::Io(e)
                if e.kind() == std::io::ErrorKind::TimedOut
                    || e.kind() == std::io::ErrorKind::WouldBlock =>
            {
                RemoteError::BrokenMessage
            }
            other => other,
        })?;
        if chunk.is_empty() {
            return Err(RemoteError::Closed);
        }
        payload.extend_from_slice(&chunk);
    }
    payload.truncate(total);
    Ok(payload)
}

fn read_noise_frame(
    noise: &mut snow::TransportState,
    stream: &mut dyn Transport,
    idle_timeout: Option<Duration>,
) -> Result<Vec<u8>, RemoteError> {
    let ciphertext = read_framed(stream, MAX_NOISE_MESSAGE, idle_timeout)?;
    let mut plaintext = vec![0u8; ciphertext.len()];
    let n = noise.read_message(&ciphertext, &mut plaintext)?;
    plaintext.truncate(n);
    Ok(plaintext)
}

/// Read one length-prefixed frame.
///
/// `idle_timeout` bounds the wait before the first byte of the frame. Once a
/// byte has arrived the frame is read to completion with the timeout
/// suspended, then the timeout is restored. This is what keeps a split stream
/// honest: the read half uses a short timeout so an idle reader hands the
/// write half the shared lock, but a timeout in the *middle* of a frame would
/// leave the stream misaligned and every later read corrupt — which a browser
/// sees as a connection that opens and then dies ("the network connection was
/// lost").
fn read_framed(
    stream: &mut dyn Transport,
    max: usize,
    idle_timeout: Option<Duration>,
) -> Result<Vec<u8>, RemoteError> {
    let mut header = [0u8; 4];
    match idle_timeout {
        Some(timeout) => {
            // The split-stream path: bound only the wait before the first
            // byte. Once a byte has arrived the frame must complete, or the
            // retry would re-read from the middle of it and corrupt the
            // stream. The timeout is restored afterwards.
            let mut filled = 0;
            let header_result = loop {
                match stream.read(&mut header[filled..]) {
                    Ok(0) => break Err(RemoteError::Closed),
                    Ok(n) => {
                        filled += n;
                        if filled == 4 {
                            break Ok(());
                        }
                        stream.set_read_timeout(None).map_err(RemoteError::Io)?;
                    }
                    Err(e)
                        if e.kind() == std::io::ErrorKind::TimedOut
                            || e.kind() == std::io::ErrorKind::WouldBlock =>
                    {
                        if filled == 0 {
                            break Err(RemoteError::Io(e));
                        }
                        stream.set_read_timeout(None).map_err(RemoteError::Io)?;
                    }
                    Err(e) => break Err(RemoteError::Io(e)),
                }
            };
            stream
                .set_read_timeout(Some(timeout))
                .map_err(RemoteError::Io)?;
            header_result?;
        }
        None => {
            // The handshake and request/response paths: a deadline, if any,
            // is owned by the caller and the whole frame must finish under
            // it.
            stream.read_exact(&mut header)?;
        }
    }

    let len = u32::from_be_bytes(header) as usize;
    if len > max {
        return Err(RemoteError::FrameTooLarge(len as u64, max));
    }
    let mut bytes = vec![0u8; len];
    match idle_timeout {
        Some(timeout) => {
            // The header is in; the payload must complete without an idle
            // timeout, then the timeout is restored for the next message.
            stream.set_read_timeout(None).map_err(RemoteError::Io)?;
            let payload_result = stream.read_exact(&mut bytes);
            stream
                .set_read_timeout(Some(timeout))
                .map_err(RemoteError::Io)?;
            payload_result.map_err(RemoteError::Io)?;
        }
        None => {
            stream.read_exact(&mut bytes)?;
        }
    }
    Ok(bytes)
}

// MARK: - Dialling out

/// Connect to a peer and authenticate both ends.
///
/// `expect` is the key this machine pinned for that peer. Passing `None` is
/// **trust on first use** and is only correct when a person is about to be
/// shown the fingerprint and asked. Every routine reconnect passes the pinned
/// key, or the pinning is decoration.
pub fn dial(
    address: &str,
    identity: &MachineIdentity,
    expect: Option<PublicKey>,
    label_for_errors: &str,
) -> Result<Connection, RemoteError> {
    dial_with_timeout(address, identity, expect, label_for_errors, CONNECT_TIMEOUT)
}

/// Dial one candidate under a deliberately short direct-path budget.
///
/// Candidate racing calls this in parallel. A dead LAN address must not delay
/// the reliable relay by the normal operating-system TCP timeout, and a socket
/// that accepts but never speaks must be bounded by the same attempt budget.
pub fn dial_with_timeout(
    address: &str,
    identity: &MachineIdentity,
    expect: Option<PublicKey>,
    label_for_errors: &str,
    timeout: Duration,
) -> Result<Connection, RemoteError> {
    let deadline = Instant::now() + timeout;
    let targets = resolve_with_timeout(address, timeout)?;
    let mut last = None;
    for target in targets {
        let Some(left) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        match TcpStream::connect_timeout(&target, left) {
            Ok(stream) => {
                stream.set_nodelay(true)?;
                let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                    break;
                };
                match handshake_initiator_with_timeout(
                    Box::new(stream),
                    identity,
                    expect,
                    label_for_errors,
                    left,
                ) {
                    Ok(connection) => return Ok(connection),
                    Err(error) => last = Some(error),
                }
            }
            Err(error) => last = Some(RemoteError::Io(error)),
        }
    }
    Err(last.unwrap_or_else(|| {
        RemoteError::Io(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            format!("{address} did not answer within {} ms", timeout.as_millis()),
        ))
    }))
}

fn resolve_with_timeout(address: &str, timeout: Duration) -> Result<Vec<SocketAddr>, RemoteError> {
    let address = address.to_string();
    let shown = address.clone();
    let (send, receive) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("direct-dns".into())
        .spawn(move || {
            let result = address
                .to_socket_addrs()
                .map(|addresses| addresses.collect::<Vec<_>>());
            let _ = send.send(result);
        })
        .map_err(RemoteError::Io)?;
    match receive.recv_timeout(timeout) {
        Ok(Ok(addresses)) if addresses.is_empty() => Err(RemoteError::Io(std::io::Error::other(
            format!("{shown} resolves to nothing"),
        ))),
        Ok(Ok(addresses)) => Ok(addresses),
        Ok(Err(error)) => Err(RemoteError::Io(error)),
        Err(_) => Err(RemoteError::Io(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            format!("resolving {shown} exceeded {} ms", timeout.as_millis()),
        ))),
    }
}

/// Run the initiator side of the Noise handshake over any bidirectional
/// transport. The caller has already completed any transport-specific setup.
pub fn handshake_initiator(
    stream: Box<dyn Transport>,
    identity: &MachineIdentity,
    expect: Option<PublicKey>,
    label_for_errors: &str,
) -> Result<Connection, RemoteError> {
    handshake_initiator_with_timeout(
        stream,
        identity,
        expect,
        label_for_errors,
        HANDSHAKE_TIMEOUT,
    )
}

fn handshake_initiator_with_timeout(
    mut stream: Box<dyn Transport>,
    identity: &MachineIdentity,
    expect: Option<PublicKey>,
    label_for_errors: &str,
    timeout: Duration,
) -> Result<Connection, RemoteError> {
    stream.set_deadline(Some(timeout))?;

    let secret = identity.secret_bytes();
    let mut handshake = snow::Builder::new(PATTERN.parse().map_err(RemoteError::from)?)
        .local_private_key(&secret)?
        .build_initiator()?;

    let mut stream = stream;
    let mut buffer = vec![0u8; MAX_NOISE_MESSAGE];

    // XX is three messages: -> e, <- e ee s es, -> s se.
    let n = handshake.write_message(&[], &mut buffer)?;
    write_framed(&mut stream, &buffer[..n])?;
    stream.flush()?;

    let response = read_framed(&mut stream, MAX_NOISE_MESSAGE, None)?;
    handshake.read_message(&response, &mut buffer)?;

    // Last message carries this machine's display name so the far side can
    // show "iPhone" rather than "unnamed machine" when recording a pending peer.
    let intro = intro_payload();
    let n = handshake.write_message(&intro, &mut buffer)?;
    write_framed(&mut stream, &buffer[..n])?;
    stream.flush()?;

    let peer = remote_static(&handshake)?;

    // Checked before the connection is handed back, so no caller can forget.
    if let Some(pinned) = expect
        && pinned != peer
    {
        return Err(RemoteError::WrongKey {
            label: label_for_errors.to_string(),
            pinned: fingerprint(&pinned),
            offered: fingerprint(&peer),
        });
    }

    // The handshake timeout was for the handshake. A session read blocks until
    // there is an answer, which for a scan is a long time.
    stream.set_deadline(None)?;

    Ok(Connection {
        stream,
        noise: handshake.into_transport_mode()?,
        peer,
        intro_label: String::new(),
    })
}

// MARK: - Serving

/// Bind and accept. Nothing is served until a peer is approved.
pub struct Server {
    listener: TcpListener,
    secret: [u8; 32],
}

/// Why an inbound connection was turned away, for the caller to log.
#[derive(Debug)]
pub enum Refused {
    /// Never seen before. Now recorded as pending, so somebody can be asked.
    Unknown { fingerprint: String, label: String },
    /// Seen and not approved, or approved and then revoked. Nothing is
    /// recorded and nobody is asked again: knocking is not an argument.
    NotApproved { fingerprint: String },
    /// The handshake itself failed, so there is no peer to name.
    Handshake(RemoteError),
}

impl Server {
    /// `address` is usually `0.0.0.0:7878` or a single interface.
    ///
    /// Binding does not mean serving. Whether this is called at all is the
    /// user's decision, and the default is not to: see `serving` in the host's
    /// settings. A daemon that listened as soon as it started would be a daemon
    /// that made that choice for them.
    pub fn bind(address: &str, identity: &MachineIdentity) -> Result<Self, RemoteError> {
        let listener = TcpListener::bind(address)?;
        Ok(Self {
            listener,
            secret: identity.secret_bytes(),
        })
    }

    pub fn local_address(&self) -> Result<String, RemoteError> {
        Ok(self.listener.local_addr()?.to_string())
    }

    pub fn set_nonblocking(&self, value: bool) -> Result<(), RemoteError> {
        self.listener.set_nonblocking(value)?;
        Ok(())
    }

    /// Accept one connection and authenticate it.
    ///
    /// Returns `Err(Refused)` for a peer that may not be served, which the
    /// caller reports rather than treating as a failure: being turned away is
    /// the system working.
    ///
    /// The peer store is consulted *inside* here, not by the caller, so there
    /// is no path that reaches a connection without asking. It is re-read per
    /// connection so a revocation takes effect on the next attempt rather than
    /// on the next restart.
    pub fn accept(&self) -> Result<Result<Connection, Refused>, RemoteError> {
        let (stream, remote) = self.listener.accept()?;
        let address = remote.to_string();
        Ok(self.handshake(stream, &address))
    }

    fn handshake(&self, stream: TcpStream, address: &str) -> Result<Connection, Refused> {
        // Blocking from here on, whatever the listener was.
        //
        // The direct listener is non-blocking so its accept loop can notice a
        // stop flag rather than parking forever on `accept`. On BSD, and so on
        // macOS, an accepted socket inherits that flag, and the Noise
        // handshake's first read then returns EAGAIN before the peer has had a
        // chance to say anything. Every direct connection to a Mac failed that
        // way, which read in the log as a flood of "handshake failed:
        // Resource temporarily unavailable" and on a phone as a long wait
        // before it gave up and used the relay.
        stream
            .set_nonblocking(false)
            .map_err(|e| Refused::Handshake(e.into()))?;
        stream
            .set_nodelay(true)
            .map_err(|e| Refused::Handshake(e.into()))?;
        match handshake_responder(Box::new(stream), &MachineIdentity::from_secret(self.secret)) {
            Ok(connection) => authorize(connection, address),
            Err(e) => Err(Refused::Handshake(e)),
        }
    }
}

/// Authorize an authenticated connection against the local peer store.
///
/// This is shared by direct TCP and tunnel connections. The transport used to
/// reach a machine must not change the approval rule.
///
/// The peer's handshake intro label (device name) is recorded on first contact
/// so the UI shows "iPhone" rather than "unnamed machine".
pub fn authorize(connection: Connection, address: &str) -> Result<Connection, Refused> {
    authorize_with(connection, address, None)
}

/// Decides whether a pending peer is one this machine already knows through
/// the account, and what to call it. `None` leaves the peer pending.
pub type AutoApprove<'a> = &'a dyn Fn(&PublicKey) -> Option<String>;

/// Like [`authorize`], but when `auto_approve` returns a label for a pending
/// peer the connection is approved immediately (used for same-account devices).
pub fn authorize_with(
    connection: Connection,
    address: &str,
    auto_approve: Option<AutoApprove<'_>>,
) -> Result<Connection, Refused> {
    let Connection {
        stream,
        noise,
        peer,
        intro_label,
    } = connection;
    let label = intro_label.trim().to_string();
    let trust_result = {
        let mut store = match PeerStore::load() {
            Ok(store) => store,
            Err(e) => return Err(Refused::Handshake(RemoteError::Identity(e))),
        };
        let prior_peer = store.get(&peer);
        let known = prior_peer.is_some();
        let prior = prior_peer.map(|p| p.trust);
        // Whether the peer arrived carrying a name this store does not have.
        // A first contact and a rename are both worth a write; a machine
        // saying the same thing again is not.
        let named_differently = store
            .get(&peer)
            .map(|existing| !label.is_empty() && existing.label != label)
            .unwrap_or(false);
        let mut trust = store.seen(&peer, &label, Some(address), &crate::now());
        let mut approved_now = false;
        // Auto-approve only when still pending (never when revoked).
        if trust == Trust::Pending && prior != Some(Trust::Revoked) {
            if let Some(hook) = auto_approve {
                if let Some(account_label) = hook(&peer) {
                    let name = if label.is_empty() {
                        account_label
                    } else {
                        label.clone()
                    };
                    store.add_approved(&peer, &name, Some(address), &crate::now());
                    trust = Trust::Approved;
                    approved_now = true;
                }
            }
        }
        // Written back only when something changed. A phone opens a channel
        // per workspace, per terminal and per port, and rewriting peers.json
        // on each of them is the disk churn the original code avoided by
        // saving new peers only.
        if !known || approved_now || named_differently {
            let _ = store.save();
        }
        (
            known,
            trust,
            if label.is_empty() {
                address.to_string()
            } else {
                label
            },
        )
    };
    match trust_result {
        (_, Trust::Approved, _) => Ok(Connection {
            stream,
            noise,
            peer,
            intro_label,
        }),
        (known, _, display) => {
            let mut refusal = Connection {
                stream,
                noise,
                peer,
                intro_label,
            };
            let _ = refusal.send(NOT_APPROVED.as_bytes());
            refusal.close();
            if known {
                Err(Refused::NotApproved {
                    fingerprint: fingerprint(&peer),
                })
            } else {
                Err(Refused::Unknown {
                    fingerprint: fingerprint(&peer),
                    label: display,
                })
            }
        }
    }
}

/// UTF-8 device name carried in the last Noise XX message (max 80 bytes).
fn intro_payload() -> Vec<u8> {
    let name = tokenstat_identity::machine_label();
    let bytes = name.as_bytes();
    bytes[..bytes.len().min(80)].to_vec()
}

/// Run the responder side of the Noise handshake over any transport.
pub fn handshake_responder(
    mut stream: Box<dyn Transport>,
    identity: &MachineIdentity,
) -> Result<Connection, RemoteError> {
    stream.set_deadline(Some(HANDSHAKE_TIMEOUT))?;
    let secret = identity.secret_bytes();
    let mut handshake = snow::Builder::new(PATTERN.parse().map_err(RemoteError::from)?)
        .local_private_key(&secret)?
        .build_responder()?;
    let mut buffer = vec![0u8; MAX_NOISE_MESSAGE];
    let first = read_framed(&mut stream, MAX_NOISE_MESSAGE, None)?;
    handshake.read_message(&first, &mut buffer)?;
    let n = handshake.write_message(&[], &mut buffer)?;
    write_framed(&mut stream, &buffer[..n])?;
    stream.flush()?;
    let third = read_framed(&mut stream, MAX_NOISE_MESSAGE, None)?;
    let payload_len = handshake.read_message(&third, &mut buffer)?;
    let intro_label = String::from_utf8_lossy(&buffer[..payload_len])
        .trim()
        .chars()
        .take(80)
        .collect::<String>();
    let peer = remote_static(&handshake)?;
    stream.set_deadline(None)?;
    Ok(Connection {
        stream,
        noise: handshake.into_transport_mode()?,
        peer,
        intro_label,
    })
}

/// What a peer is told when it is not approved.
///
/// Deliberately says nothing about *why* beyond the fact, and nothing about
/// what else this machine knows. A machine that has not been let in does not
/// get to learn whether it was once approved, or how many peers there are.
const NOT_APPROVED: &str = r#"{"ok":false,"error":{"code":"not_approved","message":"That machine has not approved this one yet. Its fingerprint is now in that machine's peer list, waiting for someone to allow it."}}"#;

/// The peer's static key, once the handshake has carried it.
fn remote_static(handshake: &snow::HandshakeState) -> Result<PublicKey, RemoteError> {
    let bytes = handshake
        .get_remote_static()
        .ok_or_else(|| RemoteError::Noise("the peer sent no static key".into()))?;
    bytes
        .try_into()
        .map_err(|_| RemoteError::Noise(format!("a static key is 32 bytes, got {}", bytes.len())))
}

fn now() -> String {
    // Seconds since the epoch, as an RFC 3339 string, without pulling a date
    // library into a crate that needs one timestamp. The peer store compares
    // these as text and never parses them.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format_epoch(secs)
}

/// Epoch seconds to `YYYY-MM-DDTHH:MM:SSZ`, civil-from-days.
///
/// Only ever used for a "last seen" the user reads, so it is deliberately
/// simple: UTC, no leap seconds, no zone.
fn format_epoch(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Howard Hinnant's civil_from_days, which is exact and short.
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

// MARK: - Length framing under Noise

/// A 4-byte big-endian length, then that many bytes.
///
/// Under the encryption rather than over it, so a listener on the wire learns
/// frame sizes and nothing else. Big-endian because that is what every wire
/// format does and there is no reason to be the exception.
fn write_framed(stream: &mut dyn Transport, bytes: &[u8]) -> Result<(), RemoteError> {
    let len = u32::try_from(bytes.len())
        .map_err(|_| RemoteError::FrameTooLarge(bytes.len() as u64, MAX_NOISE_MESSAGE))?;
    stream.write_all(&len.to_be_bytes())?;
    stream.write_all(bytes)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_formats_as_rfc3339() {
        assert_eq!(format_epoch(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_epoch(1_754_300_000), "2025-08-04T09:33:20Z");
        // A leap day, because the civil calendar arithmetic is the part that
        // silently goes wrong.
        assert_eq!(format_epoch(1_709_164_800), "2024-02-29T00:00:00Z");
    }

    /// Timestamps are compared as text by the peer store, which only works
    /// while every field is fixed width.
    #[test]
    fn timestamps_sort_as_text() {
        assert!(format_epoch(1_000) < format_epoch(2_000_000_000));
        assert_eq!(format_epoch(0).len(), format_epoch(2_000_000_000).len());
    }

    /// A split connection moves bytes in both directions at once over one
    /// Noise session: an echo loop on one side, a write and a read on the
    /// other. This is the pump the localhost proxy and the terminal
    /// subscription both depend on, so it gets a test of its own rather than
    /// being assumed.
    #[test]
    fn a_split_connection_echoes_both_ways() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a listener");
        let address = listener.local_addr().expect("its address");
        let responder_ident = MachineIdentity::from_secret([1u8; 32]);
        let initiator_ident = MachineIdentity::from_secret([2u8; 32]);
        let responder_key = responder_ident.public_key();

        let echo = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("a connection");
            let connection =
                handshake_responder(Box::new(stream), &responder_ident).expect("handshake");
            let (reader, writer) = connection.split();
            loop {
                match reader.read(1 << 20) {
                    Ok(data) if data.is_empty() => break,
                    Ok(data) => {
                        writer.write(&data).expect("echo write");
                    }
                    Err(_) => break,
                }
            }
        });

        let stream = TcpStream::connect(address).expect("connect");
        let connection = handshake_initiator(
            Box::new(stream),
            &initiator_ident,
            Some(responder_key),
            "test",
        )
        .expect("handshake");
        let (reader, writer) = connection.split();
        writer.write(b"first").expect("write one");
        writer.write(b"second").expect("write two");
        assert_eq!(reader.read(1 << 20).expect("read one"), b"first");
        assert_eq!(reader.read(1 << 20).expect("read two"), b"second");
        writer.write(&[]).expect("end of stream");
        echo.join().expect("echo thread");
    }

    /// A non-blocking listener must still be able to complete a handshake.
    ///
    /// The direct listener sets `set_nonblocking(true)` so its accept loop can
    /// poll a stop flag. On BSD the accepted socket inherits that, and the
    /// Noise handshake's first read then failed with EAGAIN before the peer had
    /// said anything: every direct connection to a Mac was refused, and the
    /// only sign was a repeated "Resource temporarily unavailable" in the log.
    #[test]
    fn a_non_blocking_listener_still_completes_a_handshake() {
        let responder_ident = MachineIdentity::from_secret([3u8; 32]);
        let responder_key = responder_ident.public_key();
        let initiator_ident = MachineIdentity::from_secret([4u8; 32]);

        let server = Server::bind("127.0.0.1:0", &responder_ident).expect("a listener");
        let address = server.local_address().expect("its address");
        server.set_nonblocking(true).expect("non-blocking");

        let accepted = std::thread::spawn(move || {
            loop {
                match server.accept() {
                    // Approval is not what this is about: a refusal that names
                    // the peer store means the handshake itself got through.
                    Ok(answer) => return answer.map(|_| ()).map_err(|e| format!("{e:?}")),
                    Err(RemoteError::Io(error))
                        if error.kind() == std::io::ErrorKind::WouldBlock =>
                    {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => return Err(format!("{error}")),
                }
            }
        });

        let stream = TcpStream::connect(&address).expect("connect");
        let _ = handshake_initiator(
            Box::new(stream),
            &initiator_ident,
            Some(responder_key),
            "test",
        );
        let outcome = accepted.join().expect("accept thread");
        if let Err(reason) = outcome {
            assert!(
                !reason.contains("Handshake"),
                "the handshake itself must not fail: {reason}"
            );
        }
    }

    /// A transport that hands over one byte at a time and reports a timeout
    /// between each, which is what a relay under load looks like from here.
    ///
    /// The point is the gaps, not the slowness: a gap inside a message used to
    /// be read with the split stream's 50 ms deadline still armed, and
    /// `read_exact` throws away what it already consumed when it fails.
    struct StutteringTransport {
        data: Vec<u8>,
        position: usize,
        timeout: Option<Duration>,
        /// Flips on every read, so every byte is followed by one timeout.
        stall: bool,
    }

    impl Read for StutteringTransport {
        fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
            if output.is_empty() || self.position >= self.data.len() {
                return Ok(0);
            }
            // A gap longer than the split stream's short deadline and far
            // shorter than the one a message is allowed. Only a deadline in
            // that band fires, which is the band a loaded relay sits in.
            if self.timeout.is_some_and(|t| t < Duration::from_secs(1)) {
                self.stall = !self.stall;
                if self.stall {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "no data yet",
                    ));
                }
            }
            output[0] = self.data[self.position];
            self.position += 1;
            Ok(1)
        }
    }

    impl Write for StutteringTransport {
        fn write(&mut self, input: &[u8]) -> std::io::Result<usize> {
            self.data.extend_from_slice(input);
            Ok(input.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl Transport for StutteringTransport {
        fn close(&mut self) {}

        fn set_deadline(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
            self.set_read_timeout(timeout)
        }

        fn set_read_timeout(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
            self.timeout = timeout;
            Ok(())
        }
    }

    /// A message longer than one Noise frame survives a link that pauses in
    /// the middle of it.
    ///
    /// Before the fix this failed the way the screen stream failed on a
    /// phone: the continuation frames kept the split stream's deadline, a
    /// stalled read dropped the bytes it had taken, and the next four bytes
    /// were decoded as a length header, giving a nonsense frame size against
    /// the 65535 limit.
    #[test]
    fn a_large_message_survives_a_pause_inside_it() {
        // Three Noise frames' worth, so the continuation path is exercised
        // rather than the header path alone.
        let payload: Vec<u8> = (0..(MAX_PAYLOAD * 2 + 1024))
            .map(|i| (i % 251) as u8)
            .collect();

        let (mut initiator, mut responder) = transport_pair();
        let mut wire = StutteringTransport {
            data: Vec::new(),
            position: 0,
            timeout: None,
            stall: false,
        };
        write_one(&mut initiator, &mut wire, &payload).expect("write the message");

        let mut reader = StutteringTransport {
            data: std::mem::take(&mut wire.data),
            position: 0,
            timeout: None,
            stall: false,
        };
        // Exactly what `split` does to the transport it is handed.
        reader
            .set_read_timeout(Some(STREAM_READ_TIMEOUT))
            .expect("arm the deadline");

        // The same loop `StreamReader::read` runs: a timeout before a message
        // has started is "nothing yet", and is retried. A timeout once one has
        // started is the failure this test is about.
        let got = loop {
            match read_one(
                &mut responder,
                &mut reader,
                1 << 20,
                Some(STREAM_READ_TIMEOUT),
            ) {
                Err(RemoteError::Io(e))
                    if e.kind() == std::io::ErrorKind::TimedOut
                        || e.kind() == std::io::ErrorKind::WouldBlock => {}
                other => break other.expect("the message must survive a pause inside it"),
            }
        };
        assert_eq!(got.len(), payload.len());
        assert_eq!(got, payload);
        // And the deadline is handed back, so the next read still yields to
        // the writer rather than parking on the lock forever.
        assert_eq!(reader.timeout, Some(STREAM_READ_TIMEOUT));
    }

    /// Two Noise transport states that can talk to each other, without a
    /// socket in the way.
    fn transport_pair() -> (snow::TransportState, snow::TransportState) {
        let initiator_ident = MachineIdentity::from_secret([7u8; 32]);
        let responder_ident = MachineIdentity::from_secret([9u8; 32]);
        let mut initiator = snow::Builder::new(PATTERN.parse().expect("pattern"))
            .local_private_key(&initiator_ident.secret_bytes())
            .expect("initiator key")
            .build_initiator()
            .expect("initiator");
        let mut responder = snow::Builder::new(PATTERN.parse().expect("pattern"))
            .local_private_key(&responder_ident.secret_bytes())
            .expect("responder key")
            .build_responder()
            .expect("responder");

        let mut buffer = [0u8; 1024];
        let mut scratch = [0u8; 1024];
        let n = initiator.write_message(&[], &mut buffer).expect("e");
        responder
            .read_message(&buffer[..n], &mut scratch)
            .expect("e in");
        let n = responder.write_message(&[], &mut buffer).expect("ee");
        initiator
            .read_message(&buffer[..n], &mut scratch)
            .expect("ee in");
        let n = initiator.write_message(&[], &mut buffer).expect("s");
        responder
            .read_message(&buffer[..n], &mut scratch)
            .expect("s in");

        (
            initiator
                .into_transport_mode()
                .expect("initiator transport"),
            responder
                .into_transport_mode()
                .expect("responder transport"),
        )
    }
}
