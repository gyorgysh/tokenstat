// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted.

//! The blind WebSocket pipe used when two machines cannot reach each other.

use std::io;
use std::net::TcpStream;

use tokenstat_identity::{MachineIdentity, PublicKey, hex};
use tungstenite::{Message, WebSocket, connect};

use crate::{Connection, RemoteError, Transport, handshake_initiator, handshake_responder};

type Socket = WebSocket<tungstenite::stream::MaybeTlsStream<TcpStream>>;

struct WsTransport {
    socket: Socket,
    pending: Vec<u8>,
}

impl WsTransport {
    fn new(socket: Socket) -> Self {
        Self {
            socket,
            pending: Vec::new(),
        }
    }
}

impl io::Read for WsTransport {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if self.pending.is_empty() {
            match self.socket.read() {
                Ok(Message::Binary(bytes)) => self.pending.extend_from_slice(&bytes),
                Ok(Message::Close(_)) => return Ok(0),
                Ok(message) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("expected binary tunnel frame, got {message:?}"),
                    ));
                }
                Err(error) => return Err(io_error(error)),
            }
        }
        let count = output.len().min(self.pending.len());
        output[..count].copy_from_slice(&self.pending[..count]);
        self.pending.drain(..count);
        Ok(count)
    }
}

impl io::Write for WsTransport {
    fn write(&mut self, input: &[u8]) -> io::Result<usize> {
        self.socket
            .send(Message::Binary(input.to_vec().into()))
            .map_err(io_error)?;
        Ok(input.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.socket.flush().map_err(io_error)
    }
}

impl Transport for WsTransport {
    fn close(&mut self) {
        let _ = self.socket.close(None);
    }

    fn set_deadline(&mut self, _timeout: Option<std::time::Duration>) -> std::io::Result<()> {
        Ok(())
    }
}

/// Open the registered side of a tunnel and establish an end-to-end session
/// with the requested machine. The account token authenticates tunnel use only.
pub fn dial(
    endpoint: &str,
    peer_key: PublicKey,
    identity: &MachineIdentity,
    expect: Option<PublicKey>,
    account_token: &str,
) -> Result<Connection, RemoteError> {
    let (mut socket, _) = connect(endpoint).map_err(tunnel_error)?;
    send_text(
        &mut socket,
        &format!("HELLO {} {}", identity.public_key_hex(), account_token),
    )?;
    expect_control(&mut socket, "READY")?;
    send_text(&mut socket, &format!("CONNECT {}", hex(&peer_key)))?;
    expect_control(&mut socket, "PAIRED")?;
    handshake_initiator(
        Box::new(WsTransport::new(socket)),
        identity,
        expect,
        "tunnel peer",
    )
}

/// Register this machine with the tunnel and wait for another machine to pair.
pub fn listen(
    endpoint: &str,
    identity: &MachineIdentity,
    account_token: &str,
) -> Result<Connection, RemoteError> {
    let (mut socket, _) = connect(endpoint).map_err(tunnel_error)?;
    send_text(
        &mut socket,
        &format!("HELLO {} {}", identity.public_key_hex(), account_token),
    )?;
    expect_control(&mut socket, "READY")?;
    expect_control(&mut socket, "PAIRED")?;
    handshake_responder(Box::new(WsTransport::new(socket)), identity)
}

fn send_text(socket: &mut Socket, text: &str) -> Result<(), RemoteError> {
    socket
        .send(Message::Text(text.to_owned().into()))
        .map_err(tunnel_error)
}

fn expect_control(socket: &mut Socket, expected: &str) -> Result<(), RemoteError> {
    match socket.read().map_err(tunnel_error)? {
        Message::Text(text) if text == expected => Ok(()),
        Message::Text(text) => Err(RemoteError::Tunnel(text.to_string())),
        Message::Close(_) => Err(RemoteError::Closed),
        other => Err(RemoteError::Tunnel(format!(
            "expected {expected}, got {other:?}"
        ))),
    }
}

fn tunnel_error(error: tungstenite::Error) -> RemoteError {
    match error {
        tungstenite::Error::Io(error) => RemoteError::Io(error),
        other => RemoteError::Tunnel(other.to_string()),
    }
}

fn io_error(error: tungstenite::Error) -> io::Error {
    match error {
        tungstenite::Error::Io(error) => error,
        other => io::Error::other(other.to_string()),
    }
}

/// Parse a control frame, rejecting payload frames and malformed commands.
pub fn parse_control(frame: &str) -> Result<Control<'_>, RemoteError> {
    let mut parts = frame.splitn(3, ' ');
    let command = parts.next().unwrap_or_default();
    match command {
        "READY" if parts.next().is_none() => Ok(Control::Ready),
        "PAIRED" if parts.next().is_none() => Ok(Control::Paired),
        "NOPEER" if parts.next().is_none() => Ok(Control::NoPeer),
        "DENIED" => Ok(Control::Denied(parts.next().unwrap_or_default())),
        _ => Err(RemoteError::Tunnel(format!(
            "invalid control frame: {frame}"
        ))),
    }
}

/// Control messages the client may receive before binary forwarding starts.
#[derive(Debug, PartialEq, Eq)]
pub enum Control<'a> {
    Ready,
    Paired,
    NoPeer,
    Denied(&'a str),
}

#[cfg(test)]
mod tests {
    use super::{Control, parse_control};

    #[test]
    fn parses_control_protocol() {
        assert!(matches!(parse_control("READY"), Ok(Control::Ready)));
        assert!(matches!(parse_control("PAIRED"), Ok(Control::Paired)));
        assert!(matches!(parse_control("NOPEER"), Ok(Control::NoPeer)));
        assert!(matches!(
            parse_control("DENIED not_on_this_plan"),
            Ok(Control::Denied("not_on_this_plan"))
        ));
        assert!(parse_control("READY extra").is_err());
    }
}
