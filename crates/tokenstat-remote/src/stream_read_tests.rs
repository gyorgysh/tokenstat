// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use std::sync::{Condvar, mpsc};

struct Pause {
    position: AtomicUsize,
    cut: usize,
    released: Mutex<bool>,
    changed: Condvar,
    waiting: mpsc::Sender<()>,
}
impl Pause {
    fn ready(&self, timeout: Duration) -> std::io::Result<bool> {
        let released = self.released.lock().unwrap();
        if self.position.load(Ordering::Relaxed) < self.cut || *released {
            return Ok(true);
        }
        let _ = self.waiting.send(());
        let (released, _) = self
            .changed
            .wait_timeout_while(released, timeout, |v| !*v)
            .unwrap();
        Ok(*released)
    }
    fn release(&self) {
        *self.released.lock().unwrap() = true;
        self.changed.notify_all();
    }
}
struct PausedTransport {
    input: Vec<u8>,
    output: Arc<Mutex<Vec<u8>>>,
    pause: Arc<Pause>,
    timeout: Duration,
    readiness: bool,
}
impl Read for PausedTransport {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        if !self.pause.ready(self.timeout)? {
            return Err(std::io::ErrorKind::TimedOut.into());
        }
        let position = self.pause.position.load(Ordering::Relaxed);
        let end = if *self.pause.released.lock().unwrap() {
            self.input.len()
        } else {
            self.pause.cut
        };
        let count = bytes.len().min(end - position);
        bytes[..count].copy_from_slice(&self.input[position..position + count]);
        self.pause
            .position
            .store(position + count, Ordering::Relaxed);
        Ok(count)
    }
}
impl Write for PausedTransport {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.output.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
impl Transport for PausedTransport {
    fn close(&mut self) {
        self.pause.release();
    }
    fn set_deadline(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.set_read_timeout(timeout)
    }
    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.timeout = timeout.unwrap_or(Duration::from_secs(30));
        Ok(())
    }
    fn read_ready(&self) -> Option<ReadReady> {
        if !self.readiness {
            return None;
        }
        let pause = Arc::clone(&self.pause);
        Some(Box::new(move |timeout| pause.ready(timeout)))
    }
}

struct Fixture {
    reader: StreamReader,
    writer: StreamWriter,
    pause: Arc<Pause>,
    entered: mpsc::Receiver<()>,
    expected: Vec<u8>,
    output: Arc<Mutex<Vec<u8>>>,
    sender: snow::TransportState,
}
impl Fixture {
    fn new(
        cut: usize,
        readiness: bool,
        allowed: Arc<AtomicBool>,
        alter: impl FnOnce(&mut Vec<u8>),
    ) -> Self {
        let (mut sender, receiver) = super::tests::transport_pair();
        let (waiting, entered) = mpsc::channel();
        let pause = Arc::new(Pause {
            position: AtomicUsize::new(0),
            cut,
            released: Mutex::new(false),
            changed: Condvar::new(),
            waiting,
        });
        let output = Arc::new(Mutex::new(Vec::new()));
        let mut transport = PausedTransport {
            input: Vec::new(),
            output: Arc::clone(&output),
            pause: Arc::clone(&pause),
            timeout: STREAM_READ_TIMEOUT,
            readiness,
        };
        let expected: Vec<_> = (0..MAX_PAYLOAD * 2 + 1024)
            .map(|i| (i % 251) as u8)
            .collect();
        write_one(&mut sender, &mut transport, &expected).unwrap();
        write_one(&mut sender, &mut transport, b"next message").unwrap();
        write_one(&mut sender, &mut transport, b"").unwrap();
        transport.input = std::mem::take(&mut *output.lock().unwrap());
        alter(&mut transport.input);
        let (reader, writer) = Connection {
            noise: receiver,
            stream: Box::new(transport),
            peer: [0; 32],
            intro_label: String::new(),
            relay: false,
        }
        .split_authorized(move || allowed.load(Ordering::Relaxed));

        Self {
            reader,
            writer,
            pause,
            entered,
            expected,
            output,
            sender,
        }
    }
}

#[test]
fn partial_input_does_not_block_outbound_frames() {
    for readiness in [true, false] {
        // Partial outer prefix, encrypted length header, frame boundary,
        // encrypted body, and boundary between continuation frames.
        for cut in [1, 6, 24, 31, 24 + 4 + MAX_NOISE_MESSAGE] {
            let Fixture {
                reader,
                writer,
                pause,
                entered,
                expected,
                output,
                mut sender,
            } = Fixture::new(cut, readiness, Arc::new(AtomicBool::new(true)), |_| {});
            let read = std::thread::spawn(move || {
                let first = reader.read(1 << 20);
                let next = reader.read(1024);
                let end = reader.read(1024);
                (first, next, end)
            });
            entered
                .recv_timeout(Duration::from_secs(2))
                .expect("input paused after consuming bytes");
            let (sent, received) = mpsc::channel();
            let write = std::thread::spawn(move || sent.send(writer.write(b"outbound")).unwrap());
            let sent_while_paused = received.recv_timeout(Duration::from_millis(200));
            pause.release();
            write.join().unwrap();
            let (first, next, end) = read.join().unwrap();
            assert_eq!(first.unwrap(), expected);
            assert_eq!(next.unwrap(), b"next message");
            assert!(end.unwrap().is_empty());
            sent_while_paused
                .expect(&format!(
                    "outbound blocked at cut {cut}, readiness={readiness}"
                ))
                .unwrap();
            // The opposite Noise direction remains valid despite yielding
            // between pieces of the incoming message.
            let bytes = output.lock().unwrap();
            let mut wire = &bytes[..];
            let length = u32::from_be_bytes(wire[..4].try_into().unwrap()) as usize;
            wire = &wire[4..];
            let mut plain = [0u8; 64];
            let n = sender.read_message(&wire[..length], &mut plain).unwrap();
            assert_eq!(&plain[..n], &8u32.to_be_bytes());
            wire = &wire[length..];
            let length = u32::from_be_bytes(wire[..4].try_into().unwrap()) as usize;
            let n = sender
                .read_message(&wire[4..4 + length], &mut plain)
                .unwrap();
            assert_eq!(&plain[..n], b"outbound");
        }
    }
}

#[test]
fn closing_or_revoking_a_partial_read_retires_both_halves() {
    for readiness in [true, false] {
        for revoke in [true, false] {
            let allowed = Arc::new(AtomicBool::new(true));
            let Fixture {
                reader,
                writer,
                pause,
                entered,
                ..
            } = Fixture::new(31, readiness, Arc::clone(&allowed), |_| {});
            let (done, completed) = mpsc::channel();
            let read = std::thread::spawn(move || done.send(reader.read(1 << 20)).unwrap());
            entered.recv_timeout(Duration::from_secs(2)).unwrap();
            let start = Instant::now();
            let closing = writer.clone();
            let close = std::thread::spawn(move || {
                if revoke {
                    allowed.store(false, Ordering::Relaxed);
                } else {
                    closing.close();
                }
            });
            let result = completed.recv_timeout(Duration::from_secs(1));
            pause.release();
            close.join().unwrap();
            read.join().unwrap();
            assert!(matches!(result.unwrap(), Err(RemoteError::Closed)));
            assert!(writer.is_closed());
            assert!(matches!(writer.write(b"retired"), Err(RemoteError::Closed)));
            eprintln!(
                "partial stream readiness={readiness} revoke={revoke}: {:?}",
                start.elapsed()
            );
        }
    }
}

#[test]
fn a_partial_stream_still_expires_when_input_stops() {
    for readiness in [true, false] {
        for cut in [1, 6, 24, 31, 24 + 4 + MAX_NOISE_MESSAGE] {
            let Fixture { reader, writer, .. } =
                Fixture::new(cut, readiness, Arc::new(AtomicBool::new(true)), |_| {});
            let start = Instant::now();
            assert!(
                reader
                    .read_with_stall_timeout(1 << 20, Duration::from_millis(80))
                    .is_err()
            );
            assert!(start.elapsed() < Duration::from_secs(2));
            assert!(writer.is_closed());
            assert!(reader.read(1024).is_err());
        }
    }
}

#[test]
fn concurrent_readers_cannot_take_each_others_partial_message() {
    let Fixture {
        reader,
        writer: _,
        pause,
        entered,
        expected,
        ..
    } = Fixture::new(31, true, Arc::new(AtomicBool::new(true)), |_| {});
    let reader = Arc::new(reader);
    let first = Arc::clone(&reader);
    let first = std::thread::spawn(move || first.read(1 << 20));
    entered.recv_timeout(Duration::from_secs(2)).unwrap();
    let second = Arc::clone(&reader);
    let (started, waiting) = mpsc::channel();
    let second = std::thread::spawn(move || {
        started.send(()).unwrap();
        second.read(1024)
    });
    waiting.recv_timeout(Duration::from_secs(2)).unwrap();
    pause.release();
    assert_eq!(first.join().unwrap().unwrap(), expected);
    assert_eq!(second.join().unwrap().unwrap(), b"next message");
    assert!(reader.read(1024).unwrap().is_empty());
}

#[test]
fn invalid_partial_streams_close_without_reinterpreting_remaining_bytes() {
    for case in 0..5 {
        let Fixture {
            reader,
            writer,
            pause,
            ..
        } = Fixture::new(
            1,
            true,
            Arc::new(AtomicBool::new(true)),
            |bytes| match case {
                0 => bytes[..4].copy_from_slice(&((MAX_NOISE_MESSAGE + 1) as u32).to_be_bytes()),
                1 => bytes[6] ^= 1,  // Authentication fails in the length header.
                2 => bytes[31] ^= 1, // Authentication fails in the message body.
                3 => bytes.truncate(31), // EOF after a partial frame.
                _ => (),             // The valid message exceeds the caller's maximum.
            },
        );
        pause.release();
        assert!(reader.read(if case == 4 { 2 } else { 1 << 20 }).is_err());
        assert!(writer.is_closed());
        assert!(writer.write(b"must not resume").is_err());
        assert!(reader.read(1 << 20).is_err());
    }
}
