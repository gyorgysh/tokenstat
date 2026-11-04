// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use std::{io, net::TcpStream, time::Duration};

/// Wait for input without consuming bytes or changing the socket's timeouts.
/// The owned duplicate keeps the descriptor valid while the stream closes.
pub(crate) fn tcp(stream: &TcpStream) -> Option<crate::ReadReady> {
    let socket = stream.try_clone().ok()?;
    Some(Box::new(move |timeout| wait(&socket, timeout)))
}

#[cfg(unix)]
fn wait(socket: &TcpStream, timeout: Duration) -> io::Result<bool> {
    use std::os::fd::AsRawFd;
    let mut descriptor = libc::pollfd {
        fd: socket.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // The descriptor belongs to socket for the entire call; poll only writes
    // this stack-allocated array element. HUP and errors wake the reader too.
    let result = unsafe {
        libc::poll(
            &mut descriptor,
            1,
            timeout.as_millis().min(i32::MAX as u128) as i32,
        )
    };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result > 0)
    }
}

#[cfg(windows)]
fn wait(socket: &TcpStream, timeout: Duration) -> io::Result<bool> {
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{
        POLLRDNORM, WSAGetLastError, WSAPOLLFD, WSAPoll,
    };
    let mut descriptor = WSAPOLLFD {
        fd: socket.as_raw_socket() as _,
        events: POLLRDNORM,
        revents: 0,
    };
    // The socket and the single descriptor remain valid throughout WSAPoll.
    let result = unsafe {
        WSAPoll(
            &mut descriptor,
            1,
            timeout.as_millis().min(i32::MAX as u128) as i32,
        )
    };
    if result < 0 {
        Err(io::Error::from_raw_os_error(unsafe { WSAGetLastError() }))
    } else {
        Ok(result > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    #[test]
    fn readiness_preserves_bytes_and_timeout_and_observes_eof() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut sender = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (mut receiver, _) = listener.accept().unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let ready = tcp(&receiver).unwrap();
        assert!(!ready(Duration::from_millis(10)).unwrap());
        sender.write_all(b"hello").unwrap();
        assert!(ready(Duration::from_secs(1)).unwrap());
        let mut bytes = [0; 5];
        receiver.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"hello");
        assert_eq!(
            receiver.read_timeout().unwrap(),
            Some(Duration::from_secs(2))
        );
        drop(sender);
        assert!(ready(Duration::from_secs(1)).unwrap());
        assert_eq!(receiver.read(&mut bytes).unwrap(), 0);
    }
}
