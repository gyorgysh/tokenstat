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

use std::io::{Read, Write};
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
    clear_timeouts(&local);
    if !looks_like_http(&first) {
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
    let (reader, writer) = connection.split();
    writer.write(rewritten.as_bytes()).map_err(|_| ())?;
    let want = request_content_length(&head_text).unwrap_or(0);
    if !leftover.is_empty() {
        writer.write(&leftover).map_err(|_| ())?;
    }
    let mut sent = leftover.len();
    while sent < want {
        let mut buf = vec![0u8; (want - sent).min(64 * 1024)];
        let n = local.read(&mut buf).map_err(|_| ())?;
        if n == 0 {
            break;
        }
        writer.write(&buf[..n]).map_err(|_| ())?;
        sent += n;
    }

    let mut remote = RemoteBuf {
        reader: &reader,
        buf: Vec::new(),
    };
    let resp_head = remote.read_headers().ok_or(())?;
    let resp_text = String::from_utf8_lossy(&resp_head);
    let (rewritten_resp, meta) =
        rewrite_response_headers(&resp_text, target_port, listen_port).ok_or(())?;

    if is_upgrade || meta.is_upgrade {
        local.write_all(rewritten_resp.as_bytes()).map_err(|_| ())?;
        if !remote.buf.is_empty() {
            local.write_all(&remote.buf).map_err(|_| ())?;
        }
        pump_split(local, reader, writer);
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
    if !remote.buf.is_empty() {
        local.write_all(&remote.buf).map_err(|_| ())?;
    }
    if let Some(len) = meta.content_length {
        let mut left = len.saturating_sub(remote.buf.len());
        while left > 0 {
            let chunk = reader.read(left.min(1 << 20)).map_err(|_| ())?;
            if chunk.is_empty() {
                break;
            }
            local.write_all(&chunk).map_err(|_| ())?;
            left = left.saturating_sub(chunk.len());
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
                self.buf = rest;
                return Some(head);
            }
            if self.buf.len() > MAX_HEADER {
                return None;
            }
            let chunk = self.reader.read(64 * 1024).ok()?;
            if chunk.is_empty() {
                return None;
            }
            self.buf.extend_from_slice(&chunk);
        }
    }

    fn take(&mut self, n: usize) -> Option<Vec<u8>> {
        while self.buf.len() < n {
            let chunk = self.reader.read((n - self.buf.len()).min(1 << 20)).ok()?;
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
}

impl ResponseMeta {
    fn can_rewrite_body(&self) -> bool {
        self.is_rewritable && !self.compressed && !self.chunked && self.content_length.is_some()
    }
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
        is_upgrade: first.contains(" 101 ")
            || header_ci(&headers, "Upgrade")
                .is_some_and(|v| v.to_ascii_lowercase().contains("websocket")),
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
    }
    for name in ["Location", "Content-Location", "Refresh"] {
        if let Some(value) = header_ci(&headers, name).map(str::to_string) {
            let rewritten = rewrite_loopback_urls(&value, target_port, listen_port);
            set_header(&mut headers, name, rewritten);
        }
    }
    Some((serialize(&first, &headers), meta))
}

fn request_content_length(block: &str) -> Option<usize> {
    let (_, headers) = header_map(block)?;
    header_ci(&headers, "Content-Length")?.parse().ok()
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
    let target = target_port.to_string();
    let listen = listen_port.to_string();
    let hosts = ["127.0.0.1", "localhost", "[::1]"];
    let schemes = ["http://", "https://", "ws://", "wss://", "//"];
    let mut out = text.to_string();
    for scheme in schemes {
        for host in hosts {
            let from = format!("{scheme}{host}:{target}");
            let to_host = if host == "[::1]" { "127.0.0.1" } else { host };
            let to = if scheme == "//" {
                format!("//{to_host}:{listen}")
            } else if scheme.starts_with("ws") {
                format!("ws://{to_host}:{listen}")
            } else if scheme.starts_with("https") || scheme.starts_with("wss") {
                // Stay on the local HTTP listener. The page was loaded over
                // http://127.0.0.1:<listen> and a https/wss target would miss.
                format!("http://{to_host}:{listen}")
            } else {
                format!("{scheme}{to_host}:{listen}")
            };
            out = out.replace(&from, &to);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(out.contains("Location: http://localhost:48080/app"));
    }

    #[test]
    fn html_rewrites_vite_and_ws_urls() {
        let html = r#"<script src="http://localhost:5173/@vite/client"></script>
<link href="http://127.0.0.1:5173/src/main.css">
const ws = "ws://localhost:5173/";"#;
        let out = rewrite_loopback_urls(html, 5173, 48080);
        assert!(out.contains("http://localhost:48080/@vite/client"));
        assert!(out.contains("http://127.0.0.1:48080/src/main.css"));
        assert!(out.contains("ws://localhost:48080/"));
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
