// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.

//! Discovery for model servers listening on this machine's loopback.
//!
//! This is deliberately in the host crate. Local provider discovery is a host
//! feature, not archive parsing, and must never add a network dependency to
//! `tokenstat-core`.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

const CONNECT_TIMEOUT: Duration = Duration::from_millis(250);
const READ_TIMEOUT: Duration = Duration::from_millis(700);
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LocalProvider {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub available: bool,
    pub models: Vec<LocalModel>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LocalModel {
    pub id: String,
    pub name: String,
    pub size_bytes: Option<u64>,
}

struct ProviderSpec {
    id: &'static str,
    name: &'static str,
    port: u16,
    base_url: &'static str,
    path: &'static str,
    parse: fn(&Value) -> Result<Vec<LocalModel>, String>,
}

const PROVIDERS: &[ProviderSpec] = &[
    ProviderSpec {
        id: "lmstudio",
        name: "LM Studio",
        port: 1234,
        base_url: "http://127.0.0.1:1234/v1",
        path: "/v1/models",
        parse: parse_lmstudio,
    },
    ProviderSpec {
        id: "ollama",
        name: "Ollama",
        port: 11434,
        base_url: "http://127.0.0.1:11434",
        path: "/api/tags",
        parse: parse_ollama,
    },
];

/// Probe the supported local model servers without contacting the internet.
pub(crate) fn discover() -> Result<Vec<LocalProvider>, String> {
    Ok(PROVIDERS
        .iter()
        .map(
            |spec| match get_json(spec.port, spec.path).and_then(|value| (spec.parse)(&value)) {
                Ok(models) => LocalProvider {
                    id: spec.id.to_string(),
                    name: spec.name.to_string(),
                    base_url: spec.base_url.to_string(),
                    available: true,
                    models,
                    error: None,
                },
                Err(error) => LocalProvider {
                    id: spec.id.to_string(),
                    name: spec.name.to_string(),
                    base_url: spec.base_url.to_string(),
                    available: false,
                    models: Vec::new(),
                    error: Some(error),
                },
            },
        )
        .collect())
}

fn get_json(port: u16, path: &str) -> Result<Value, String> {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT)
        .map_err(|error| format!("not running ({error})"))?;
    stream
        .set_read_timeout(Some(READ_TIMEOUT))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(READ_TIMEOUT))
        .map_err(|error| error.to_string())?;
    write!(stream, "GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAccept: application/json\r\n\r\n")
        .map_err(|error| error.to_string())?;

    let mut response = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(count) => {
                response.extend_from_slice(&chunk[..count]);
                if response.len() > MAX_RESPONSE_BYTES {
                    return Err("response was too large".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::TimedOut => break,
            Err(error) => return Err(error.to_string()),
        }
    }

    let text = String::from_utf8(response).map_err(|_| "response was not UTF-8".to_string())?;
    let (headers, body) = text
        .split_once("\r\n\r\n")
        .ok_or("response had no HTTP body")?;
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .ok_or("response had no HTTP status")?;
    if !status.starts_with('2') {
        return Err(format!("local server returned HTTP {status}"));
    }
    serde_json::from_str(body).map_err(|error| format!("invalid model response: {error}"))
}

fn parse_lmstudio(value: &Value) -> Result<Vec<LocalModel>, String> {
    let rows = value
        .get("data")
        .and_then(Value::as_array)
        .ok_or("LM Studio response had no data array")?;
    Ok(rows
        .iter()
        .filter_map(|row| {
            let id = row.get("id")?.as_str()?.trim();
            (!id.is_empty()).then(|| LocalModel {
                id: id.to_string(),
                name: id.to_string(),
                size_bytes: None,
            })
        })
        .collect())
}

fn parse_ollama(value: &Value) -> Result<Vec<LocalModel>, String> {
    let rows = value
        .get("models")
        .and_then(Value::as_array)
        .ok_or("Ollama response had no models array")?;
    Ok(rows
        .iter()
        .filter_map(|row| {
            let id = row
                .get("name")
                .or_else(|| row.get("model"))?
                .as_str()?
                .trim();
            (!id.is_empty()).then(|| LocalModel {
                id: id.to_string(),
                name: id.to_string(),
                size_bytes: row.get("size").and_then(Value::as_u64),
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::{parse_lmstudio, parse_ollama};
    use serde_json::json;

    #[test]
    fn lm_studio_models_use_the_openai_ids() {
        let models = parse_lmstudio(&json!({
            "data": [{"id": "qwen/qwen3.5-27b"}, {"id": ""}, {"object": "model"}]
        }))
        .expect("models");
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "qwen/qwen3.5-27b");
    }

    #[test]
    fn ollama_models_keep_names_and_sizes() {
        let models = parse_ollama(&json!({
            "models": [{"name": "llama3.2:latest", "size": 1234}]
        }))
        .expect("models");
        assert_eq!(models[0].name, "llama3.2:latest");
        assert_eq!(models[0].size_bytes, Some(1234));
    }
}
