// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use crate::{Connection, RemoteError, Transport, note_payload, read_one};
use std::{
    io::{self, Read, Write},
    time::{Duration, Instant},
};
use tokenstat_identity::{MachineIdentity, PublicKey};

/// A Team handshake has one time budget across all reads and writes. Personal
/// connections retain their existing handshake and stream behavior.
pub fn handshake_responder_bounded(
    stream: Box<dyn Transport>,
    identity: &MachineIdentity,
) -> Result<Connection, RemoteError> {
    crate::handshake_responder(
        Box::new(HandshakeBudget {
            stream,
            deadline: None,
        }),
        identity,
    )
}
pub fn handshake_initiator_bounded(
    stream: Box<dyn Transport>,
    identity: &MachineIdentity,
    host: PublicKey,
) -> Result<Connection, RemoteError> {
    crate::handshake_initiator(
        Box::new(HandshakeBudget {
            stream,
            deadline: None,
        }),
        identity,
        Some(host),
        "Team computer",
    )
}

struct HandshakeBudget {
    stream: Box<dyn Transport>,
    deadline: Option<Instant>,
}
impl HandshakeBudget {
    fn left(&self) -> io::Result<Option<Duration>> {
        self.deadline
            .map(|deadline| {
                deadline
                    .checked_duration_since(Instant::now())
                    .filter(|left| !left.is_zero())
                    .ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::TimedOut,
                            "The Team handshake time budget expired.",
                        )
                    })
            })
            .transpose()
    }
}
impl Read for HandshakeBudget {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if let Some(left) = self.left()? {
            self.stream.set_read_timeout(Some(left))?;
        }
        self.stream.read(output)
    }
}
impl Write for HandshakeBudget {
    fn write(&mut self, input: &[u8]) -> io::Result<usize> {
        if let Some(left) = self.left()? {
            self.stream.set_deadline(Some(left))?;
        }
        self.stream.write(input)
    }
    fn flush(&mut self) -> io::Result<()> {
        if let Some(left) = self.left()? {
            self.stream.set_deadline(Some(left))?;
        }
        self.stream.flush()
    }
}
impl Transport for HandshakeBudget {
    fn close(&mut self) {
        self.stream.close();
    }
    fn set_deadline(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        if timeout.is_none() {
            self.left()?;
        }
        self.deadline = timeout
            .map(|timeout| {
                Instant::now().checked_add(timeout).ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "The handshake time budget is not valid.",
                    )
                })
            })
            .transpose()?;
        self.stream.set_deadline(timeout)
    }
    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        let timeout = match (timeout, self.left()?) {
            (Some(timeout), Some(left)) => Some(timeout.min(left)),
            (timeout, None) => timeout,
            (None, Some(left)) => Some(left),
        };
        self.stream.set_read_timeout(timeout)
    }
    fn is_relay(&self) -> bool {
        self.stream.is_relay()
    }
}

impl Connection {
    /// Receive a complete message under one monotonic time budget. Receiving
    /// another byte or starting a continuation frame cannot extend it.
    /// Any failure closes this connection because a partial encrypted frame
    /// cannot be retried. Other channels on its tunnel stay open.
    pub fn receive_bounded(
        &mut self,
        max: usize,
        budget: Duration,
    ) -> Result<Vec<u8>, RemoteError> {
        let Some(deadline) = Instant::now().checked_add(budget) else {
            self.stream.close();
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "The message time budget is not valid.",
            )
            .into());
        };
        let mut result = read_one(
            &mut self.noise,
            &mut ReadBudget {
                stream: &mut *self.stream,
                deadline,
            },
            max,
            None,
        );
        if result.is_ok() && Instant::now() >= deadline {
            result = Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "The message time budget expired.",
            )
            .into());
        }
        let _ = self.stream.set_read_timeout(None);
        match &result {
            Ok(payload) => note_payload(self.relay, payload.len() as u64),
            Err(_) => self.stream.close(),
        }
        result
    }
}
struct ReadBudget<'a> {
    stream: &'a mut dyn Transport,
    deadline: Instant,
}
impl ReadBudget<'_> {
    fn remaining(&self) -> io::Result<Duration> {
        self.deadline
            .checked_duration_since(Instant::now())
            .filter(|left| !left.is_zero())
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::TimedOut, "The message time budget expired.")
            })
    }
}
impl Read for ReadBudget<'_> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        let left = self.remaining()?;
        self.stream.set_read_timeout(Some(left))?;
        self.stream.read(output)
    }
}
impl Write for ReadBudget<'_> {
    fn write(&mut self, input: &[u8]) -> io::Result<usize> {
        self.stream.write(input)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}
impl Transport for ReadBudget<'_> {
    fn close(&mut self) {
        self.stream.close();
    }
    fn set_deadline(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_read_timeout(timeout)
    }
    fn set_read_timeout(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        let left = self.remaining()?;
        self.stream
            .set_read_timeout(Some(timeout.map_or(left, |timeout| timeout.min(left))))
    }
    fn is_relay(&self) -> bool {
        self.stream.is_relay()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct SlowWire(std::io::Cursor<Vec<u8>>);
    impl Read for SlowWire {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            std::thread::sleep(Duration::from_millis(2));
            let length = output.len().min(1);
            self.0.read(&mut output[..length])
        }
    }
    impl Write for SlowWire {
        fn write(&mut self, input: &[u8]) -> io::Result<usize> {
            std::thread::sleep(Duration::from_millis(2));
            Ok(input.len().min(1))
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    impl Transport for SlowWire {
        fn close(&mut self) {}
        fn set_deadline(&mut self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }
        fn set_read_timeout(&mut self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }
    }
    fn budget() -> HandshakeBudget {
        HandshakeBudget {
            stream: Box::new(SlowWire(std::io::Cursor::new(vec![1; 100]))),
            deadline: None,
        }
    }
    #[test]
    fn handshake_budget_covers_all_partial_reads_and_writes() {
        let mut reader = budget();
        reader
            .set_deadline(Some(Duration::from_millis(20)))
            .unwrap();
        assert_eq!(
            reader.read_exact(&mut [0; 80]).unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        let mut writer = budget();
        writer
            .set_deadline(Some(Duration::from_millis(20)))
            .unwrap();
        assert_eq!(
            writer.write_all(&[0; 80]).unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
    }
    #[test]
    fn completed_handshakes_remove_the_budget_and_expired_ones_cannot_do_so() {
        let mut wire = budget();
        wire.set_deadline(Some(Duration::from_secs(10))).unwrap();
        wire.read_exact(&mut [0; 1]).unwrap();
        wire.set_deadline(None).unwrap();
        assert!(wire.deadline.is_none());
        wire.read_exact(&mut [0; 1]).unwrap();
        wire.set_deadline(Some(Duration::ZERO)).unwrap();
        assert_eq!(
            wire.set_deadline(None).unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
    }
}
