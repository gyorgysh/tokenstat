// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Local console authority, carried over the daemon's existing JSON protocol.

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use serde_json::Value;
use tokenstat_core::host_rpc;

pub fn call(socket: &Path, method: &str, params: Value) -> Result<Value> {
    let stream = UnixStream::connect(socket).with_context(|| {
        format!("Cannot reach the host at {}. Run `tokenstat host start`, or install it with `tokenstat host install`.", socket.display())
    })?;
    exchange(stream, method, params, host_rpc::TIMEOUT)
}

fn exchange(stream: UnixStream, method: &str, params: Value, timeout: Duration) -> Result<Value> {
    host_rpc::exchange(stream, method, params, timeout).map_err(anyhow::Error::msg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{BufRead, BufReader, Write};

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
