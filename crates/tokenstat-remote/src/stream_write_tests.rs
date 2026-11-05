// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;

#[cfg(windows)]
#[test]
fn split_tcp_uses_nonblocking_io_instead_of_winsock_timeouts() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (_server, _) = listener.accept().unwrap();
    let mut probe = client.try_clone().unwrap();
    // Bound a broken implementation so this regression cannot hang CI.
    probe
        .set_read_timeout(Some(Duration::from_millis(200)))
        .unwrap();
    let (noise, _) = super::tests::transport_pair();
    let (_reader, writer) = Connection {
        noise,
        stream: Box::new(Box::new(client)),
        peer: [0; 32],
        intro_label: String::new(),
        relay: false,
    }
    .split();
    assert!(writer.short_writes);
    assert_eq!(
        probe.read(&mut [0]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    assert!(!writer.is_closed());
}

#[test]
fn simultaneous_large_stream_writes_retain_partial_bytes() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (server, _) = listener.accept().unwrap();
    client
        .set_write_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    server
        .set_write_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    #[cfg(unix)]
    for socket in [&client, &server] {
        use std::os::fd::AsRawFd;
        let size: libc::c_int = 32768;
        for option in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
            assert_eq!(
                unsafe {
                    libc::setsockopt(
                        socket.as_raw_fd(),
                        libc::SOL_SOCKET,
                        option,
                        (&size as *const libc::c_int).cast(),
                        std::mem::size_of_val(&size) as _,
                    )
                },
                0
            );
        }
    }
    let (left, right) = super::tests::transport_pair();
    let connect = |stream: TcpStream, noise| {
        Connection {
            noise,
            stream: Box::new(stream),
            peer: [0; 32],
            intro_label: String::new(),
            relay: false,
        }
        .split()
    };
    let (read_a, write_a) = connect(client, left);
    let (read_b, write_b) = connect(server, right);
    let a = std::thread::spawn(move || read_a.read(16 << 20));
    let b = std::thread::spawn(move || read_b.read(16 << 20));
    let ready = Arc::new(std::sync::Barrier::new(2));
    let other = ready.clone();
    let send_a = std::thread::spawn(move || {
        let bytes = vec![17; 8 << 20];
        ready.wait();
        write_a.write_with_stall_timeout(&bytes, Duration::from_secs(2))
    });
    let send_b = std::thread::spawn(move || {
        let bytes = vec![29; 8 << 20];
        other.wait();
        write_b.write_with_stall_timeout(&bytes, Duration::from_secs(2))
    });
    let start = Instant::now();
    let left = send_a.join().unwrap();
    let right = send_b.join().unwrap();
    let got_a = a.join().unwrap();
    let got_b = b.join().unwrap();
    eprintln!(
        "8 MiB simultaneous duplex: {:?}; left={left:?}; right={right:?}; read lengths {:?} {:?}",
        start.elapsed(),
        got_a.as_ref().map(Vec::len),
        got_b.as_ref().map(Vec::len)
    );
    assert!(left.is_ok() && right.is_ok());
    assert_eq!(got_a.unwrap(), vec![29; 8 << 20]);
    assert_eq!(got_b.unwrap(), vec![17; 8 << 20]);
}

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize};

#[derive(Default)]
struct State {
    bytes: Mutex<Vec<u8>>,
    paused: AtomicBool,
    released: AtomicBool,
    closed: AtomicBool,
    flush_pause: AtomicBool,
    flush_failures: AtomicUsize,
    allowed: AtomicBool,
}
enum Step {
    Bytes(usize),
    Error(std::io::ErrorKind),
    Wait,
    Zero,
}
struct ControlledTransport {
    input: std::io::Cursor<Vec<u8>>,
    steps: VecDeque<Step>,
    state: Arc<State>,
}
impl Read for ControlledTransport {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        self.input.read(output)
    }
}
impl Write for ControlledTransport {
    fn write(&mut self, input: &[u8]) -> std::io::Result<usize> {
        if matches!(self.steps.front(), Some(Step::Wait))
            && !self.state.released.load(Ordering::Relaxed)
        {
            self.state.paused.store(true, Ordering::Relaxed);
            return Err(std::io::ErrorKind::TimedOut.into());
        }
        let count = match self.steps.pop_front() {
            Some(Step::Bytes(count)) => count.min(input.len()),
            Some(Step::Error(kind)) => return Err(kind.into()),
            Some(Step::Zero) => return Ok(0),
            Some(Step::Wait) | None => input.len(),
        };
        self.state
            .bytes
            .lock()
            .unwrap()
            .extend_from_slice(&input[..count]);
        Ok(count)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        if self
            .state
            .flush_failures
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_sub(1))
            .is_ok()
        {
            return Err(std::io::ErrorKind::WouldBlock.into());
        }
        if self.state.flush_pause.load(Ordering::Relaxed)
            && !self.state.released.load(Ordering::Relaxed)
        {
            self.state.paused.store(true, Ordering::Relaxed);
            return Err(std::io::ErrorKind::TimedOut.into());
        }
        Ok(())
    }
}
impl Transport for ControlledTransport {
    fn close(&mut self) {
        self.state.closed.store(true, Ordering::Relaxed);
    }
    fn set_deadline(&mut self, _: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }
    fn set_read_timeout(&mut self, _: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }
    fn set_write_timeout(&mut self, _: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }
}
fn controlled(steps: Vec<Step>) -> (StreamReader, StreamWriter, snow::TransportState, Arc<State>) {
    let (local, mut peer) = super::tests::transport_pair();
    let state = Arc::new(State::default());
    state.allowed.store(true, Ordering::Relaxed);
    let mut transport = ControlledTransport {
        input: std::io::Cursor::new(Vec::new()),
        steps: VecDeque::new(),
        state: state.clone(),
    };
    write_one(&mut peer, &mut transport, b"incoming while sending").unwrap();
    transport.input = std::io::Cursor::new(std::mem::take(&mut *state.bytes.lock().unwrap()));
    transport.steps = steps.into();
    let allowed = state.clone();
    let (reader, writer) = Connection {
        noise: local,
        stream: Box::new(Box::new(transport)),
        peer: [0; 32],
        intro_label: String::new(),
        relay: false,
    }
    .split_authorized(move || allowed.allowed.load(Ordering::Relaxed));
    assert!(
        writer.short_writes,
        "boxed transports forward the write timeout"
    );
    (reader, writer, peer, state)
}
fn decoded(mut peer: snow::TransportState, state: &State, count: usize) -> Vec<Vec<u8>> {
    let mut wire = ControlledTransport {
        input: std::io::Cursor::new(state.bytes.lock().unwrap().clone()),
        steps: VecDeque::new(),
        state: Arc::new(State::default()),
    };
    (0..count)
        .map(|_| read_one(&mut peer, &mut wire, 1 << 20, None).unwrap())
        .collect()
}
fn await_pause(state: &State) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !state.paused.load(Ordering::Relaxed) {
        assert!(Instant::now() < deadline, "writer reaches the pause");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn short_writes_and_retryable_errors_keep_ciphertext_and_nonces() {
    use std::io::ErrorKind::{Interrupted, TimedOut, WouldBlock};
    let (reader, writer, peer, state) = controlled(vec![
        Step::Bytes(1),
        Step::Error(TimedOut),
        Step::Bytes(5),
        Step::Error(WouldBlock),
        Step::Bytes(18),
        Step::Error(Interrupted),
        Step::Bytes(7),
        Step::Error(TimedOut),
    ]);
    state.flush_failures.store(2, Ordering::Relaxed);
    let expected: Vec<_> = (0..MAX_PAYLOAD * 2 + 7).map(|i| (i % 251) as u8).collect();
    writer.write(&expected).unwrap();
    writer.write(b"next").unwrap();
    writer.write(b"").unwrap();
    assert_eq!(
        decoded(peer, &state, 3),
        vec![expected, b"next".to_vec(), Vec::new()]
    );
    assert_eq!(reader.read(1024).unwrap(), b"incoming while sending");
    assert!(!state.closed.load(Ordering::Relaxed));
}

#[test]
fn incoming_data_and_cancellation_progress_during_an_outgoing_pause() {
    for action in 0..3 {
        let (reader, writer, peer, state) = controlled(vec![Step::Bytes(1), Step::Wait]);
        let sending = writer.clone();
        let send = std::thread::spawn(move || {
            sending.write_with_stall_timeout(b"outgoing", Duration::from_secs(2))
        });
        await_pause(&state);
        assert_eq!(reader.read(1024).unwrap(), b"incoming while sending");
        match action {
            0 => state.released.store(true, Ordering::Relaxed),
            1 => writer.close(),
            _ => state.allowed.store(false, Ordering::Relaxed),
        }
        let result = send.join().unwrap();
        if action == 0 {
            result.unwrap();
            assert_eq!(decoded(peer, &state, 1), vec![b"outgoing".to_vec()]);
        } else {
            assert!(matches!(result, Err(RemoteError::Closed)));
            assert!(writer.is_closed());
            assert_eq!(state.bytes.lock().unwrap().len(), 1);
            assert!(writer.write(b"retry").is_err());
        }
    }
}

#[test]
fn stalled_or_failed_writes_and_flushes_retire_both_halves() {
    for case in 0..5 {
        let steps = match case {
            0 => vec![Step::Wait],
            1 => vec![Step::Bytes(1), Step::Wait],
            2 => vec![], // Stall during flush after all frames were written.
            3 => vec![Step::Zero],
            _ => vec![Step::Bytes(1), Step::Error(std::io::ErrorKind::BrokenPipe)],
        };
        let (reader, writer, _, state) = controlled(steps);
        state.flush_pause.store(case == 2, Ordering::Relaxed);
        let start = Instant::now();
        assert!(
            writer
                .write_with_stall_timeout(b"message", Duration::from_millis(80))
                .is_err()
        );
        assert!(start.elapsed() < Duration::from_secs(2));
        assert!(state.closed.load(Ordering::Relaxed));
        let length = state.bytes.lock().unwrap().len();
        assert!(writer.write(b"retry").is_err());
        assert!(reader.read(1024).is_err());
        assert_eq!(state.bytes.lock().unwrap().len(), length);
    }
}

#[test]
fn concurrent_writers_keep_whole_messages_together() {
    let (_, writer, peer, state) = controlled(vec![
        Step::Bytes(3),
        Step::Error(std::io::ErrorKind::WouldBlock),
    ]);
    let ready = Arc::new(std::sync::Barrier::new(4));
    let sends: Vec<_> = (1..=4u8)
        .map(|id| {
            let writer = writer.clone();
            let ready = ready.clone();
            std::thread::spawn(move || {
                ready.wait();
                writer.write(&vec![id; MAX_PAYLOAD * 2 + 11]).unwrap();
            })
        })
        .collect();
    for send in sends {
        send.join().unwrap();
    }
    let mut messages = decoded(peer, &state, 4);
    messages.sort();
    for (index, message) in messages.iter().enumerate() {
        assert_eq!(*message, vec![index as u8 + 1; MAX_PAYLOAD * 2 + 11]);
    }
}
