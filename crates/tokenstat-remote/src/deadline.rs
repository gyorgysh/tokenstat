// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use crate::{Connection, RemoteError, Transport, note_payload, read_one};
use std::{
    io::{self, Read, Write},
    time::{Duration, Instant},
};

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
