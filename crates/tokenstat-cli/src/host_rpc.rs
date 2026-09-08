// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Local console authority, carried over the daemon's existing JSON protocol.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

const MAX_RESPONSE: u64 = 4 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(30);

pub fn call(socket: &Path, method: &str, params: Value) -> Result<Value> {
    let stream = UnixStream::connect(socket).with_context(|| {
        format!("Cannot reach the host at {}. Run `tokenstat host start`, or install it with `tokenstat host install`.", socket.display())
    })?;
    exchange(stream, method, params, TIMEOUT)
}

fn exchange(
    mut stream: UnixStream,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value> {
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    let request = json!({"id": 1, "method": method, "params": params});
    serde_json::to_writer(&mut stream, &request)?;
    stream.write_all(b"\n")?;
    // Limit the reader, not a buffer checked after allocation. A broken daemon
    // must not make a console command allocate without a bound.
    let mut response = Vec::new();
    BufReader::new(stream)
        .take(MAX_RESPONSE + 1)
        .read_until(b'\n', &mut response)
        .with_context(|| {
            format!("The host did not finish answering {method}. Check `tokenstat host logs`.")
        })?;
    if response.len() as u64 > MAX_RESPONSE {
        bail!("The host response to {method} was too large");
    }
    if response.last() != Some(&b'\n') {
        bail!("The host closed the connection before answering {method}");
    }
    let envelope: Value = serde_json::from_slice(&response)
        .with_context(|| format!("The host sent an invalid response to {method}"))?;
    if envelope.get("id") != Some(&json!(1)) {
        bail!("The host response did not match the request for {method}");
    }
    match envelope.get("ok").and_then(Value::as_bool) {
        Some(true) => envelope
            .get("result")
            .cloned()
            .context("The host response has no result"),
        Some(false) => {
            let error = &envelope["error"];
            let message = error["message"]
                .as_str()
                .or_else(|| error.as_str())
                .unwrap_or("The host refused the request");
            bail!("{method}: {message}")
        }
        None => bail!("The host response has no success state"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(response: &'static [u8]) -> Result<Value> {
        let (client, server) = UnixStream::pair().unwrap();
        let worker = std::thread::spawn(move || {
            let mut reader = BufReader::new(server);
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            let request: Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["method"], "workspace.access.set");
            assert_eq!(request["params"]["allow"], true);
            reader.get_mut().write_all(response).unwrap();
        });
        let result = exchange(
            client,
            "workspace.access.set",
            json!({"allow":true}),
            Duration::from_secs(1),
        );
        worker.join().unwrap();
        result
    }

    #[test]
    fn console_requests_use_the_dispatch_envelope() {
        assert_eq!(
            reply(b"{\"id\":1,\"ok\":true,\"result\":{\"saved\":true}}\n").unwrap(),
            json!({"saved":true})
        );
        let error =
            reply(b"{\"id\":1,\"ok\":false,\"error\":{\"message\":\"permission refused\"}}\n")
                .unwrap_err();
        assert!(error.to_string().contains("permission refused"));
    }

    #[test]
    fn incomplete_wrong_and_malformed_responses_are_not_success() {
        for response in [
            b"{\"id\":2,\"ok\":true,\"result\":{}}\n".as_slice(),
            b"{\"id\":1,\"ok\":true}\n",
            b"{\"id\":1,\"result\":{}}\n",
            b"not json\n",
            b"{\"id\":1,\"ok\":true,\"result\":{}}",
        ] {
            assert!(reply(response).is_err());
        }
    }

    #[test]
    fn an_unresponsive_host_does_not_hang_the_console() {
        let (client, _server) = UnixStream::pair().unwrap();
        let started = std::time::Instant::now();
        assert!(exchange(client, "protocol", json!({}), Duration::from_millis(50)).is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
