// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! One framing helper for the local host-helper socket.
//!
//! The CLI console (`tokenstat-cli`) and the MCP server (`tokenstat-mcp`)
//! used to carry their own copies of this exchange: same 30s timeout, same
//! 4MiB cap, same `{id, method, params}` request and `{ok, result/error}`
//! envelope. Two copies meant the next transport fix had to land twice, so
//! both now call [`exchange`] here. The wire itself is unchanged: newline-
//! delimited JSON over a local unix socket, never the network. Anything that
//! makes a request still belongs above this crate (see `tokenstat-sync`);
//! this only frames bytes on an already-connected local stream.

use std::time::Duration;

use serde_json::{Value, json};

/// Largest host reply accepted before the connection is refused.
pub const MAX_RESPONSE_BYTES: u64 = 4 * 1024 * 1024;

/// A wedged helper must not park a console command or the MCP loop forever.
pub const TIMEOUT: Duration = Duration::from_secs(30);

/// Send one `{id: 1, method, params}` request and read one reply line.
///
/// Returns the envelope's `result` when `ok` is true, or a plain-text reason
/// otherwise. An envelope without an `id` is accepted for older helpers; a
/// mismatched one is rejected, so a crossed reply is never mistaken for the
/// answer that was asked for.
#[cfg(unix)]
pub fn exchange(
    mut stream: std::os::unix::net::UnixStream,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, String> {
    use std::io::{BufRead, BufReader, Read, Write};

    stream
        .set_read_timeout(Some(timeout))
        .and_then(|_| stream.set_write_timeout(Some(timeout)))
        .map_err(|e| e.to_string())?;
    let request = json!({"id": 1, "method": method, "params": params});
    serde_json::to_writer(&mut stream, &request).map_err(|e| e.to_string())?;
    stream.write_all(b"\n").map_err(|e| e.to_string())?;
    // Limit the reader, not a buffer checked after allocation. A broken
    // helper must not make a caller allocate without a bound.
    let mut response = Vec::new();
    BufReader::new(stream)
        .take(MAX_RESPONSE_BYTES + 1)
        .read_until(b'\n', &mut response)
        .map_err(|_| {
            format!("The host did not finish answering {method}. Check `tokenstat host logs`.")
        })?;
    if response.len() as u64 > MAX_RESPONSE_BYTES {
        return Err(format!("The host response to {method} was too large"));
    }
    if response.last() != Some(&b'\n') {
        return Err(format!(
            "The host closed the connection before answering {method}"
        ));
    }
    let envelope: Value = serde_json::from_slice(&response)
        .map_err(|_| format!("The host sent an invalid response to {method}"))?;
    if let Some(id) = envelope.get("id") {
        if id != &json!(1) {
            return Err(format!(
                "The host response did not match the request for {method}"
            ));
        }
    }
    match envelope.get("ok").and_then(Value::as_bool) {
        Some(true) => envelope
            .get("result")
            .cloned()
            .ok_or_else(|| "The host response has no result".to_string()),
        Some(false) => {
            let error = &envelope["error"];
            let message = error["message"]
                .as_str()
                .or_else(|| error.as_str())
                .unwrap_or("The host refused the request");
            Err(format!("{method}: {message}"))
        }
        None => Err("The host response has no success state".to_string()),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;

    fn reply(response: &'static [u8]) -> Result<Value, String> {
        let (client, server) = UnixStream::pair().unwrap();
        let worker = std::thread::spawn(move || {
            let mut reader = BufReader::new(server);
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            let request: Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["method"], "workspace.list");
            assert_eq!(request["id"], 1);
            reader.get_mut().write_all(response).unwrap();
        });
        let result = exchange(client, "workspace.list", json!({}), Duration::from_secs(1));
        worker.join().unwrap();
        result
    }

    #[test]
    fn success_and_refusal_roundtrip() {
        assert_eq!(
            reply(b"{\"id\":1,\"ok\":true,\"result\":{\"saved\":true}}\n").unwrap(),
            json!({"saved":true})
        );
        // Older helpers omit the id; the result still counts.
        assert_eq!(
            reply(b"{\"ok\":true,\"result\":{\"saved\":true}}\n").unwrap(),
            json!({"saved":true})
        );
        let error =
            reply(b"{\"id\":1,\"ok\":false,\"error\":{\"message\":\"permission refused\"}}\n")
                .unwrap_err();
        assert!(error.contains("permission refused"));
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
}
