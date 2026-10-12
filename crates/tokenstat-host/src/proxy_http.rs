// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! HTTP reverse proxy on the browser side of a tunnel port bridge.
//!
//! Raw TCP is the wrong tool for a web app. Vite and the harnesses emit
//! absolute `localhost:<target>` URLs. The page then loads on the phone's
//! random loopback port and those URLs miss. This hop rewrites `Host`,
//! `Location` / `Refresh`, and obvious loopback URLs inside HTML.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use tokenstat_remote::Connection;

const MAX_HEADER: usize = 64 * 1024;
const MAX_HTML_REWRITE: usize = 2 * 1024 * 1024;

/// Bridge one accepted local connection to the peer's loopback service.
pub(crate) fn bridge(
    local: TcpStream,
    connection: Connection,
    target_host: &str,
    target_port: u16,
    listen_port: u16,
) {
    let _ = local.set_nodelay(true);
    // Only the header wait is timed. A 101 upgrade or a long-lived TCP
    // stream must sit idle without the socket treating that as EOF.
    let _ = local.set_read_timeout(Some(Duration::from_secs(30)));
    let _ = local.set_write_timeout(Some(Duration::from_secs(30)));
    let mut local = local;
    let first = match read_until_headers(&mut local) {
        Ok(buf) if !buf.is_empty() => buf,
        _ => return,
    };
    if !looks_like_http(&first) {
        clear_timeouts(&local);
        pump_raw(local, connection, Some(first));
        return;
    }
    let _ = pump_one_http(
        local,
        connection,
        first,
        target_host,
        target_port,
        listen_port,
    );
}

fn pump_one_http(
    mut local: TcpStream,
    connection: Connection,
    first: Vec<u8>,
    target_host: &str,
    target_port: u16,
    listen_port: u16,
) -> Result<(), ()> {
    let (head, leftover) = split_head(&first).ok_or(())?;
    let head_text = String::from_utf8_lossy(&head);
    let (rewritten, is_upgrade) =
        rewrite_request_headers(&head_text, target_host, target_port, listen_port).ok_or(())?;
    let body = request_body(&head_text).ok_or(())?;
    let (reader, writer) = connection.split();
    let mut cleanup = HttpCleanup {
        socket: local.try_clone().map_err(|_| ())?,
        writer: writer.clone(),
        upload: None,
    };
    writer.write(rewritten.as_bytes()).map_err(|_| ())?;
    if is_upgrade && matches!(body, RequestBody::Length(0)) {
        if !leftover.is_empty() {
            writer.write(&leftover).map_err(|_| ())?;
        }
    } else {
        // Upload and response are independent: a server may send 100 Continue
        // before accepting a body, or reject an upload before it finishes.
        let socket = local.try_clone().map_err(|_| ())?;
        let upload_writer = writer.clone();
        cleanup.upload = Some(std::thread::spawn(move || {
            let mut source = BufReader::new(std::io::Cursor::new(leftover).chain(socket));
            if forward_body(&mut source, body, |bytes| {
                upload_writer.write(bytes).map_err(std::io::Error::other)
            })
            .is_err()
            {
                upload_writer.close();
            }
        }));
    }

    let mut remote = RemoteBuf {
        reader: &reader,
        buf: Vec::new(),
    };
    let mut resp_head = remote.read_headers().ok_or(())?;
    let mut resp_text = String::from_utf8_lossy(&resp_head).into_owned();
    // An interim response (100 Continue, 103 Early Hints) is not the answer.
    // It carries no body, and the real response follows on the same
    // connection, so forward it and read on; treating it as final would close
    // the connection the client is still waiting on. A 101 switches protocols
    // instead: hand it to the upgrade pump without reading another HTTP head.
    let mut interim_hops = 0;
    while interim_hops < 8
        && response_status(&resp_text)
            .is_some_and(|status| (100..200).contains(&status) && status != 101)
    {
        let (rewritten_interim, _) =
            rewrite_response_headers(&resp_text, target_port, listen_port).ok_or(())?;
        local
            .write_all(rewritten_interim.as_bytes())
            .map_err(|_| ())?;
        resp_head = remote.read_headers().ok_or(())?;
        resp_text = String::from_utf8_lossy(&resp_head).into_owned();
        interim_hops += 1;
    }
    let (rewritten_resp, mut meta) =
        rewrite_response_headers(&resp_text, target_port, listen_port).ok_or(())?;
    meta.no_body =
        response_has_no_body(head_text.starts_with("HEAD "), response_status(&resp_text));
    if meta.is_upgrade {
        clear_timeouts(&local);
        local.write_all(rewritten_resp.as_bytes()).map_err(|_| ())?;
        if !remote.buf.is_empty() {
            local.write_all(&remote.buf).map_err(|_| ())?;
        }
        pump_split(local, reader, writer);
        return Ok(());
    }

    if meta.no_body {
        local.write_all(rewritten_resp.as_bytes()).map_err(|_| ())?;
        // No body follows by definition (HEAD, 204, 304), so buffered bytes
        // are never the rest of this response. Forwarding them would graft
        // the next response's head onto a body that does not exist.
        remote.buf.clear();
        finish(reader, writer);
        return Ok(());
    }

    if meta.can_rewrite_body()
        && let Some(len) = meta.content_length
        && len <= MAX_HTML_REWRITE
    {
        let body = remote.take(len).ok_or(())?;
        let rewritten_body =
            rewrite_loopback_urls(&String::from_utf8_lossy(&body), target_port, listen_port);
        let bytes = rewritten_body.into_bytes();
        let headers = replace_content_length(&rewritten_resp, bytes.len());
        local.write_all(headers.as_bytes()).map_err(|_| ())?;
        local.write_all(&bytes).map_err(|_| ())?;
        finish(reader, writer);
        return Ok(());
    }

    local.write_all(rewritten_resp.as_bytes()).map_err(|_| ())?;
    let buffered = meta
        .content_length
        .map_or(remote.buf.len(), |len| len.min(remote.buf.len()));
    if buffered > 0 {
        local.write_all(&remote.buf[..buffered]).map_err(|_| ())?;
    }
    if let Some(len) = meta.content_length {
        let mut left = len.saturating_sub(remote.buf.len());
        while left > 0 {
            let chunk = reader.read(1 << 20).map_err(|_| ())?;
            if chunk.is_empty() {
                break;
            }
            let take = left.min(chunk.len());
            local.write_all(&chunk[..take]).map_err(|_| ())?;
            left -= take;
        }
    } else {
        loop {
            match reader.read(1 << 20) {
                Ok(data) if data.is_empty() => break,
                Ok(data) => {
                    if local.write_all(&data).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    }
    finish(reader, writer);
    Ok(())
}

fn finish(reader: tokenstat_remote::StreamReader, writer: tokenstat_remote::StreamWriter) {
    let _ = writer.write(&[]);
    writer.close();
    reader.close();
}

fn pump_raw(local: TcpStream, connection: Connection, prefix: Option<Vec<u8>>) {
    let (reader, writer) = connection.split();
    if let Some(prefix) = prefix
        && !prefix.is_empty()
        && writer.write(&prefix).is_err()
    {
        finish(reader, writer);
        return;
    }
    pump_split(local, reader, writer);
}

fn clear_timeouts(stream: &TcpStream) {
    let _ = stream.set_read_timeout(None);
    let _ = stream.set_write_timeout(None);
}

fn is_idle(err: &std::io::Error) -> bool {
    matches!(
        err.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    )
}

fn pump_split(
    tcp: TcpStream,
    reader: tokenstat_remote::StreamReader,
    writer: tokenstat_remote::StreamWriter,
) {
    let tcp_reader = match tcp.try_clone() {
        Ok(clone) => clone,
        Err(_) => {
            finish(reader, writer);
            return;
        }
    };
    let writer = std::sync::Arc::new(writer);
    let reader = std::sync::Arc::new(reader);
    let to_remote = {
        let mut tcp_reader = tcp_reader;
        let writer = std::sync::Arc::clone(&writer);
        std::thread::spawn(move || {
            let mut buffer = [0u8; 64 * 1024];
            loop {
                match tcp_reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        if writer.write(&buffer[..n]).is_err() {
                            break;
                        }
                    }
                    Err(err) if is_idle(&err) => continue,
                    Err(_) => break,
                }
            }
            let _ = writer.write(&[]);
            writer.close();
        })
    };
    let to_tcp = {
        let reader = std::sync::Arc::clone(&reader);
        std::thread::spawn(move || {
            let mut tcp = tcp;
            loop {
                match reader.read(1 << 20) {
                    Ok(data) if data.is_empty() => break,
                    Ok(data) => {
                        if tcp.write_all(&data).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            reader.close();
            let _ = tcp.shutdown(std::net::Shutdown::Both);
        })
    };
    let _ = to_remote.join();
    let _ = to_tcp.join();
}

struct RemoteBuf<'a> {
    reader: &'a tokenstat_remote::StreamReader,
    buf: Vec<u8>,
}

impl RemoteBuf<'_> {
    fn read_headers(&mut self) -> Option<Vec<u8>> {
        loop {
            if let Some((head, rest)) = split_head(&self.buf) {
                if head.len() > MAX_HEADER {
                    return None;
                }
                self.buf = rest;
                return Some(head);
            }
            if self.buf.len() > MAX_HEADER {
                return None;
            }
            let chunk = self.reader.read(1 << 20).ok()?;
            if chunk.is_empty() {
                return None;
            }
            self.buf.extend_from_slice(&chunk);
        }
    }

    fn take(&mut self, n: usize) -> Option<Vec<u8>> {
        while self.buf.len() < n {
            let chunk = self.reader.read(1 << 20).ok()?;
            if chunk.is_empty() {
                break;
            }
            self.buf.extend_from_slice(&chunk);
        }
        if self.buf.len() < n {
            return None;
        }
        let rest = self.buf.split_off(n);
        let taken = std::mem::replace(&mut self.buf, rest);
        Some(taken)
    }
}

fn read_until_headers(stream: &mut TcpStream) -> std::io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        if buf.len() >= MAX_HEADER {
            break;
        }
        let n = stream.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
        if split_head(&buf).is_some() {
            break;
        }
        if !maybe_http(&buf) {
            break;
        }
    }
    Ok(buf)
}

/// True while the bytes we have could still become an HTTP request.
/// A raw "ping" to an echo port must not wait for `\r\n\r\n`.
fn maybe_http(buf: &[u8]) -> bool {
    const METHODS: [&[u8]; 8] = [
        b"GET ",
        b"POST ",
        b"PUT ",
        b"HEAD ",
        b"DELETE ",
        b"OPTIONS ",
        b"PATCH ",
        b"CONNECT ",
    ];
    METHODS.iter().any(|method| {
        let n = buf.len().min(method.len());
        buf[..n] == method[..n]
    })
}

fn split_head(buf: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let pos = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    let end = pos + 4;
    if end > MAX_HEADER {
        return None;
    }
    Some((buf[..end].to_vec(), buf[end..].to_vec()))
}

fn looks_like_http(buf: &[u8]) -> bool {
    const METHODS: [&[u8]; 8] = [
        b"GET ",
        b"POST ",
        b"PUT ",
        b"HEAD ",
        b"DELETE ",
        b"OPTIONS ",
        b"PATCH ",
        b"CONNECT ",
    ];
    METHODS.iter().any(|m| buf.starts_with(m))
}

#[derive(Debug, Default)]
struct ResponseMeta {
    content_length: Option<usize>,
    is_rewritable: bool,
    compressed: bool,
    chunked: bool,
    is_upgrade: bool,
    no_body: bool,
}

impl ResponseMeta {
    fn can_rewrite_body(&self) -> bool {
        self.is_rewritable
            && !self.compressed
            && !self.chunked
            && !self.no_body
            && self.content_length.is_some()
    }
}

fn response_has_no_body(request_head: bool, status: Option<u16>) -> bool {
    // 1xx is not here: an interim response is followed by the real one, and
    // the caller forwards it and keeps reading. Only these are final and
    // bodiless.
    request_head || status.is_some_and(|status| status == 204 || status == 304)
}

fn response_status(block: &str) -> Option<u16> {
    block
        .lines()
        .next()?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

fn content_type_is_rewritable(ct: &str) -> bool {
    let ct = ct.to_ascii_lowercase();
    ct.contains("text/html")
        || ct.contains("text/javascript")
        || ct.contains("application/javascript")
        || ct.contains("application/x-javascript")
        || ct.contains("text/css")
}

fn header_map(block: &str) -> Option<(String, Vec<(String, String)>)> {
    let mut lines = block.split("\r\n");
    let first = lines.next()?.to_string();
    if first.is_empty() {
        return None;
    }
    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        headers.push((name.trim().to_string(), value.trim().to_string()));
    }
    Some((first, headers))
}

fn serialize(first: &str, headers: &[(String, String)]) -> String {
    let mut out = String::with_capacity(256);
    out.push_str(first);
    out.push_str("\r\n");
    for (name, value) in headers {
        out.push_str(name);
        out.push_str(": ");
        out.push_str(value);
        out.push_str("\r\n");
    }
    out.push_str("\r\n");
    out
}

fn header_ci<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

fn set_header(headers: &mut Vec<(String, String)>, name: &str, value: String) {
    if let Some(existing) = headers
        .iter_mut()
        .find(|(n, _)| n.eq_ignore_ascii_case(name))
    {
        existing.1 = value;
        return;
    }
    headers.push((name.to_string(), value));
}

fn rewrite_request_headers(
    block: &str,
    target_host: &str,
    target_port: u16,
    listen_port: u16,
) -> Option<(String, bool)> {
    let (first, mut headers) = header_map(block)?;
    let is_upgrade = header_ci(&headers, "Upgrade")
        .is_some_and(|v| v.to_ascii_lowercase().contains("websocket"));
    let host = if target_host == "localhost" || target_host == "::1" || target_host == "[::1]" {
        "127.0.0.1"
    } else {
        target_host
    };
    set_header(&mut headers, "Host", format!("{host}:{target_port}"));
    set_header(
        &mut headers,
        "X-Forwarded-Host",
        format!("127.0.0.1:{listen_port}"),
    );
    set_header(&mut headers, "X-Forwarded-Port", listen_port.to_string());
    set_header(&mut headers, "X-Forwarded-Proto", "http".into());
    if !is_upgrade {
        set_header(&mut headers, "Connection", "close".into());
    }
    Some((serialize(&first, &headers), is_upgrade))
}

fn rewrite_response_headers(
    block: &str,
    target_port: u16,
    listen_port: u16,
) -> Option<(String, ResponseMeta)> {
    let (first, mut headers) = header_map(block)?;
    let mut meta = ResponseMeta {
        is_upgrade: response_status(block) == Some(101),
        ..ResponseMeta::default()
    };
    if let Some(len) = header_ci(&headers, "Content-Length") {
        meta.content_length = len.parse().ok();
    }
    if let Some(ct) = header_ci(&headers, "Content-Type") {
        meta.is_rewritable = content_type_is_rewritable(ct);
    }
    if let Some(enc) = header_ci(&headers, "Content-Encoding") {
        let enc = enc.to_ascii_lowercase();
        meta.compressed = !enc.is_empty() && enc != "identity";
    }
    if let Some(te) = header_ci(&headers, "Transfer-Encoding") {
        meta.chunked = te.to_ascii_lowercase().contains("chunked");
        // Transfer-Encoding takes precedence over Content-Length.
        meta.content_length = None;
        headers.retain(|(name, _)| !name.eq_ignore_ascii_case("Content-Length"));
    }
    for name in ["Location", "Content-Location", "Refresh"] {
        if let Some(value) = header_ci(&headers, name).map(str::to_string) {
            let rewritten = rewrite_loopback_urls(&value, target_port, listen_port);
            set_header(&mut headers, name, rewritten);
        }
    }
    Some((serialize(&first, &headers), meta))
}

struct HttpCleanup {
    socket: TcpStream,
    writer: tokenstat_remote::StreamWriter,
    upload: Option<std::thread::JoinHandle<()>>,
}

impl Drop for HttpCleanup {
    fn drop(&mut self) {
        let _ = self.socket.shutdown(std::net::Shutdown::Both);
        self.writer.close();
        if let Some(upload) = self.upload.take() {
            let _ = upload.join();
        }
    }
}

#[derive(Clone, Copy)]
enum RequestBody {
    Length(u64),
    Chunked,
}

fn request_body(block: &str) -> Option<RequestBody> {
    let (_, headers) = header_map(block)?;
    if let Some(encoding) = header_ci(&headers, "Transfer-Encoding") {
        // No ambiguous framing or unsupported transfer codings.
        if header_ci(&headers, "Content-Length").is_some()
            || !encoding.eq_ignore_ascii_case("chunked")
        {
            return None;
        }
        return Some(RequestBody::Chunked);
    }
    let mut length = None;
    for (_, value) in headers
        .iter()
        .filter(|(name, _)| name.eq_ignore_ascii_case("Content-Length"))
    {
        let n: u64 = value.parse().ok()?;
        if length.is_some_and(|old| old != n) {
            return None;
        }
        length = Some(n);
    }
    Some(RequestBody::Length(length.unwrap_or(0)))
}

fn forward_body(
    source: &mut impl BufRead,
    body: RequestBody,
    mut send: impl FnMut(&[u8]) -> std::io::Result<()>,
) -> std::io::Result<()> {
    fn copy(
        source: &mut impl Read,
        mut left: u64,
        send: &mut impl FnMut(&[u8]) -> std::io::Result<()>,
    ) -> std::io::Result<()> {
        let mut buf = [0; 64 * 1024];
        while left > 0 {
            let take = left.min(buf.len() as u64) as usize;
            source.read_exact(&mut buf[..take])?;
            send(&buf[..take])?;
            left -= take as u64;
        }
        Ok(())
    }
    fn line(source: &mut impl BufRead) -> std::io::Result<Vec<u8>> {
        let mut line = Vec::new();
        source
            .take(MAX_HEADER as u64 + 1)
            .read_until(b'\n', &mut line)?;
        if line.len() > MAX_HEADER || !line.ends_with(b"\r\n") {
            return Err(std::io::Error::other("invalid chunk header"));
        }
        Ok(line)
    }
    match body {
        RequestBody::Length(n) => copy(source, n, &mut send),
        RequestBody::Chunked => loop {
            let header = line(source)?;
            let text = std::str::from_utf8(&header).map_err(std::io::Error::other)?;
            let size = text.trim_end().split(';').next().unwrap_or("");
            let size = u64::from_str_radix(size, 16).map_err(std::io::Error::other)?;
            send(&header)?;
            if size == 0 {
                let mut total = 0;
                loop {
                    let trailer = line(source)?;
                    total += trailer.len();
                    if total > MAX_HEADER {
                        return Err(std::io::Error::other("chunk trailers too large"));
                    }
                    send(&trailer)?;
                    if trailer == b"\r\n" {
                        return Ok(());
                    }
                }
            }
            copy(source, size, &mut send)?;
            let mut end = [0; 2];
            source.read_exact(&mut end)?;
            if end != *b"\r\n" {
                return Err(std::io::Error::other("invalid chunk ending"));
            }
            send(&end)?;
        },
    }
}

fn replace_content_length(block: &str, len: usize) -> String {
    let Some((first, mut headers)) = header_map(block) else {
        return block.to_string();
    };
    set_header(&mut headers, "Content-Length", len.to_string());
    serialize(&first, &headers)
}

fn rewrite_loopback_urls(text: &str, target_port: u16, listen_port: u16) -> String {
    if target_port == listen_port {
        return text.to_string();
    }
    let patterns: Vec<_> = ["http://", "https://", "ws://", "wss://", "//"]
        .into_iter()
        .flat_map(|scheme| {
            ["127.0.0.1", "localhost", "[::1]"]
                .into_iter()
                .map(move |host| {
                    let from = format!("{scheme}{host}:{target_port}");
                    let local_scheme = if scheme == "//" {
                        "//"
                    } else if scheme.starts_with("ws") {
                        "ws://"
                    } else {
                        "http://"
                    };
                    // The listener is IPv4-only, including when the target used ::1.
                    (from, format!("{local_scheme}127.0.0.1:{listen_port}"))
                })
        })
        .collect();
    let mut out = String::with_capacity(text.len());
    let mut remaining = text;
    while !remaining.is_empty() {
        let found = patterns.iter().find(|(from, _)| {
            remaining.starts_with(from)
                && remaining.as_bytes().get(from.len()).is_none_or(|next| {
                    matches!(
                        next,
                        b'/' | b'?'
                            | b'#'
                            | b' '
                            | b'\t'
                            | b'\r'
                            | b'\n'
                            | b'\"'
                            | b'\''
                            | b'<'
                            | b'>'
                            | b')'
                            | b'}'
                    )
                })
        });
        if let Some((from, to)) = found {
            out.push_str(to);
            remaining = &remaining[from.len()..];
        } else {
            let ch = remaining.chars().next().unwrap();
            out.push(ch);
            remaining = &remaining[ch.len_utf8()..];
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrite_matches_the_complete_port_once() {
        let text = "https://localhost:5/x ws://[::1]:5/ //localhost:5?x http://localhost:50/ http://localhost:5@evil/x";
        assert_eq!(
            rewrite_loopback_urls(text, 5, 50),
            "http://127.0.0.1:50/x ws://127.0.0.1:50/ //127.0.0.1:50?x http://localhost:50/ http://localhost:5@evil/x"
        );
    }

    #[test]
    fn request_framing_is_bounded_and_chunk_trailers_are_forwarded() {
        let bytes = b"4;extension=yes\r\ntest\r\n0\r\nX-Trailer: ok\r\n\r\nNEXT";
        let mut source = std::io::Cursor::new(bytes);
        let mut out = Vec::new();
        forward_body(&mut source, RequestBody::Chunked, |chunk| {
            out.extend_from_slice(chunk);
            Ok(())
        })
        .unwrap();
        assert_eq!(&out, &bytes[..bytes.len() - 4]);
        assert_eq!(source.position(), (bytes.len() - 4) as u64);
        assert!(
            forward_body(
                &mut std::io::Cursor::new(b"5\r\na"),
                RequestBody::Chunked,
                |_| Ok(())
            )
            .is_err()
        );
        assert!(
            request_body("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n")
                .is_none()
        );
        assert!(
            request_body(
                "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n"
            )
            .is_none()
        );
    }

    #[test]
    fn rejected_websocket_is_an_http_response() {
        let (_, meta) = rewrite_response_headers(
            "HTTP/1.1 426 Upgrade Required\r\nUpgrade: websocket\r\nContent-Length: 0\r\n\r\n",
            3000,
            4000,
        )
        .unwrap();
        assert!(!meta.is_upgrade);
        let (_, meta) = rewrite_response_headers(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 12\r\n\r\n",
            3000,
            4000,
        )
        .unwrap();
        assert_eq!(meta.content_length, None);
    }

    fn with_proxy(
        server: impl FnOnce(Connection) + Send + 'static,
        client: impl FnOnce(TcpStream),
    ) {
        use tokenstat_identity::MachineIdentity;
        use tokenstat_remote::{handshake_initiator, handshake_responder};
        let peer = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = peer.local_addr().unwrap();
        let responder = MachineIdentity::from_secret([91; 32]);
        let key = responder.public_key();
        let peer_thread = std::thread::spawn(move || {
            let (tcp, _) = peer.accept().unwrap();
            let connection = handshake_responder(Box::new(tcp), &responder).unwrap();
            server(connection);
        });
        let connection = handshake_initiator(
            Box::new(TcpStream::connect(address).unwrap()),
            &MachineIdentity::from_secret([92; 32]),
            Some(key),
            "proxy test",
        )
        .unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let proxy = std::thread::spawn(move || {
            bridge(
                listener.accept().unwrap().0,
                connection,
                "127.0.0.1",
                3000,
                address.port(),
            );
        });
        let tcp = TcpStream::connect(address).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
        client(tcp);
        proxy.join().unwrap();
        peer_thread.join().unwrap();
    }

    #[test]
    fn continue_response_precedes_upload_and_response_stops_at_length() {
        with_proxy(
            |mut connection| {
                let request = connection
                    .receive_within(1 << 20, Duration::from_secs(5))
                    .unwrap();
                assert!(String::from_utf8_lossy(&request).contains("Expect: 100-continue"));
                connection.send(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap();
                assert_eq!(
                    connection
                        .receive_within(1 << 20, Duration::from_secs(5))
                        .unwrap(),
                    b"test"
                );
                connection
                    .send(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokEXCESS")
                    .unwrap();
            },
            |mut client| {
                client.write_all(b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n").unwrap();
                let mut interim = [0; 25];
                client.read_exact(&mut interim).unwrap();
                assert_eq!(&interim, b"HTTP/1.1 100 Continue\r\n\r\n");
                client.write_all(b"test").unwrap();
                let mut response = String::new();
                client.read_to_string(&mut response).unwrap();
                assert!(response.ends_with("\r\n\r\nok"), "{response}");
            },
        );
    }

    #[test]
    fn request_host_becomes_the_target_port() {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nAccept: */*\r\n\r\n";
        let (out, upgrade) = rewrite_request_headers(raw, "127.0.0.1", 5173, 49152).unwrap();
        assert!(!upgrade);
        assert!(out.contains("Host: 127.0.0.1:5173\r\n"));
        assert!(out.contains("X-Forwarded-Host: 127.0.0.1:49152\r\n"));
        assert!(out.contains("X-Forwarded-Port: 49152"));
        assert!(out.contains("Connection: close"));
    }

    #[test]
    fn websocket_upgrade_is_left_open() {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1:9\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
        let (out, upgrade) = rewrite_request_headers(raw, "127.0.0.1", 5173, 9).unwrap();
        assert!(upgrade);
        assert!(out.contains("Upgrade: websocket"));
        assert!(!out.contains("Connection: close"));
    }

    #[test]
    fn location_stays_on_the_local_listener() {
        let raw = "HTTP/1.1 302 Found\r\nLocation: http://localhost:5173/app\r\nContent-Length: 0\r\n\r\n";
        let (out, meta) = rewrite_response_headers(raw, 5173, 48080).unwrap();
        assert_eq!(meta.content_length, Some(0));
        assert!(out.contains("Location: http://127.0.0.1:48080/app"));
    }

    #[test]
    fn html_rewrites_vite_and_ws_urls() {
        let html = r#"<script src="http://localhost:5173/@vite/client"></script>
<link href="http://127.0.0.1:5173/src/main.css">
const ws = "ws://localhost:5173/";"#;
        let out = rewrite_loopback_urls(html, 5173, 48080);
        assert!(out.contains("http://127.0.0.1:48080/@vite/client"));
        assert!(out.contains("http://127.0.0.1:48080/src/main.css"));
        assert!(out.contains("ws://127.0.0.1:48080/"));
        assert!(!out.contains(":5173"));
    }

    #[test]
    fn compressed_html_is_not_a_rewrite_candidate() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\nContent-Length: 12\r\n\r\n";
        let (_, meta) = rewrite_response_headers(raw, 5173, 9).unwrap();
        assert!(meta.is_rewritable);
        assert!(meta.compressed);
        assert!(!meta.can_rewrite_body());
    }

    #[test]
    fn bodiless_responses_are_not_body_rewrite_candidates() {
        assert!(response_has_no_body(true, Some(200)));
        // 1xx is interim, not final: the caller forwards it and reads the real
        // response that follows, so it is not a bodiless final answer.
        assert!(!response_has_no_body(false, Some(100)));
        assert!(response_has_no_body(false, Some(204)));
        assert!(response_has_no_body(false, Some(304)));
        assert!(!response_has_no_body(false, Some(200)));
        assert!(!response_has_no_body(false, None));

        let raw =
            "HTTP/1.1 304 Not Modified\r\nContent-Type: text/html\r\nContent-Length: 12\r\n\r\n";
        assert_eq!(response_status(raw), Some(304));
        let (_, mut meta) = rewrite_response_headers(raw, 5173, 9).unwrap();
        meta.no_body = response_has_no_body(false, response_status(raw));
        assert!(!meta.can_rewrite_body());
    }

    #[test]
    fn javascript_is_a_rewrite_candidate() {
        let raw =
            "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nContent-Length: 40\r\n\r\n";
        let (_, meta) = rewrite_response_headers(raw, 5173, 9).unwrap();
        assert!(meta.is_rewritable);
        assert!(meta.can_rewrite_body());
    }

    #[test]
    fn looks_like_http_accepts_verbs_only() {
        assert!(looks_like_http(b"GET / HTTP/1.1\r\n"));
        assert!(looks_like_http(b"POST /rpc HTTP/1.1\r\n"));
        assert!(!looks_like_http(b"\x16\x03\x01"));
        assert!(!looks_like_http(b"SSH-2.0"));
        assert!(maybe_http(b"GE"));
        assert!(!maybe_http(b"ping"));
    }

    #[test]
    fn content_length_is_updated_after_a_rewrite() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 4\r\n\r\n";
        let out = replace_content_length(raw, 20);
        assert!(out.contains("Content-Length: 20"));
        assert!(!out.contains("Content-Length: 4"));
    }
}
