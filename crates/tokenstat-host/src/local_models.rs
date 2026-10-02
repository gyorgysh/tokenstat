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

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const CONNECT_TIMEOUT: Duration = Duration::from_millis(250);
const READ_TIMEOUT: Duration = Duration::from_millis(700);
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LocalProvider {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub port: u16,
    pub default_port: u16,
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
    path: &'static str,
    parse: fn(&Value) -> Result<Vec<LocalModel>, String>,
}

const PROVIDERS: &[ProviderSpec] = &[
    ProviderSpec {
        id: "lmstudio",
        name: "LM Studio",
        port: 1234,
        path: "/v1/models",
        parse: parse_lmstudio,
    },
    ProviderSpec {
        id: "ollama",
        name: "Ollama",
        port: 11434,
        path: "/api/tags",
        parse: parse_ollama,
    },
];

/// The spec for a provider id, or `None` when nothing here serves it.
fn spec(provider: &str) -> Option<&'static ProviderSpec> {
    PROVIDERS.iter().find(|spec| spec.id == provider)
}

#[derive(Default, Serialize, Deserialize)]
struct Ports(BTreeMap<String, u16>);

fn ports_path() -> Result<PathBuf, String> {
    tokenstat_identity::identity_dir()
        .map(|dir| dir.join("local-providers.json"))
        .map_err(|error| error.to_string())
}

fn load_ports(path: &Path) -> Result<Ports, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Ports::default()),
        Err(_) => return Err("could not read local model port settings".into()),
    };
    let ports: Ports = serde_json::from_str(&text)
        .map_err(|_| "local model port settings are invalid".to_string())?;
    if ports
        .0
        .iter()
        .any(|(id, port)| spec(id).is_none() || *port == 0)
    {
        return Err("local model port settings are invalid".into());
    }
    Ok(ports)
}

fn port_for(spec: &ProviderSpec, ports: &Ports) -> u16 {
    ports.0.get(spec.id).copied().unwrap_or(spec.port)
}

pub(crate) fn configured_port(provider: &str) -> Result<u16, String> {
    let spec = spec(provider).ok_or("unknown local model provider")?;
    Ok(port_for(spec, &load_ports(&ports_path()?)?))
}

/// A private host setting shared by discovery and newly launched sessions.
pub(crate) fn set_port(provider: &str, port: u16) -> Result<(), String> {
    set_port_in(&ports_path()?, provider, port)
}

fn set_port_in(path: &Path, provider: &str, port: u16) -> Result<(), String> {
    let spec = spec(provider).ok_or("unknown local model provider")?;
    if port == 0 {
        return Err("port must be between 1 and 65535".into());
    }
    static WRITER: Mutex<()> = Mutex::new(());
    let _guard = crate::identity_storage::lock_at(&path.with_extension("lock"), &WRITER)?;
    let mut ports = load_ports(path)?;
    if port == spec.port {
        ports.0.remove(provider);
    } else {
        ports.0.insert(provider.to_string(), port);
    }
    let json = serde_json::to_string(&ports).map_err(|error| error.to_string())?;
    tokenstat_sync::snapshot::write_private_atomically(path, &json)
        .map_err(|_| "could not save local model port settings".to_string())
}

/// Loopback only, with no API path on the end.
pub(crate) fn origin(provider: &str) -> Result<String, String> {
    Ok(format!("http://127.0.0.1:{}", configured_port(provider)?))
}

pub(crate) fn api_base_url(provider: &str) -> Result<String, String> {
    let origin = origin(provider)?;
    Ok(if provider == "lmstudio" {
        format!("{origin}/v1")
    } else {
        origin
    })
}

/// Probe the supported local model servers without contacting the internet.
pub(crate) fn discover() -> Result<Vec<LocalProvider>, String> {
    let ports = load_ports(&ports_path()?)?;
    Ok(PROVIDERS
        .iter()
        .map(|spec| {
            let port = port_for(spec, &ports);
            let origin = format!("http://127.0.0.1:{port}");
            let base_url = if spec.id == "lmstudio" {
                format!("{origin}/v1")
            } else {
                origin
            };
            let result = get_json(port, spec.path).and_then(|value| (spec.parse)(&value));
            let (available, models, error) = match result {
                Ok(models) => (true, models, None),
                Err(error) => (false, Vec::new(), Some(error)),
            };
            LocalProvider {
                id: spec.id.to_string(),
                name: spec.name.to_string(),
                base_url,
                port,
                default_port: spec.port,
                available,
                models,
                error,
            }
        })
        .collect())
}

/// Why a probe failed, in words a person can act on.
///
/// A refused or timed-out connect is "the app is not running". The OS
/// string (`os error 61`) is noise on the settings row and the launcher
/// menu, so it stays out of the common case.
fn connect_error(error: std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::ConnectionRefused
        | std::io::ErrorKind::TimedOut
        | std::io::ErrorKind::ConnectionReset => "not running".into(),
        _ => {
            let text = error.to_string();
            let lower = text.to_ascii_lowercase();
            if lower.contains("connection refused") || lower.contains("timed out") {
                "not running".into()
            } else {
                format!("not running ({text})")
            }
        }
    }
}

fn get_json(port: u16, path: &str) -> Result<Value, String> {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream =
        TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).map_err(connect_error)?;
    stream
        .set_read_timeout(Some(READ_TIMEOUT))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(READ_TIMEOUT))
        .map_err(|error| error.to_string())?;
    write!(stream, "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nAccept: application/json\r\n\r\n")
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
    use super::{LocalModel, LocalProvider, api_base_url, origin, parse_lmstudio, parse_ollama};
    use serde_json::json;

    fn fixture_dir() -> std::path::PathBuf {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "tokenstat-local-ports-{}-{now}",
            std::process::id()
        ))
    }

    #[test]
    fn ports_persist_independently_and_reset_to_defaults() {
        let dir = fixture_dir();
        let path = dir.join("ports.json");
        super::set_port_in(&path, "lmstudio", 8123).expect("save LM Studio");
        super::set_port_in(&path, "ollama", 65535).expect("save Ollama");
        let ports = super::load_ports(&path).expect("reload");
        assert_eq!(
            super::port_for(super::spec("lmstudio").expect("provider"), &ports),
            8123
        );
        assert_eq!(
            super::port_for(super::spec("ollama").expect("provider"), &ports),
            65535
        );
        assert!(super::set_port_in(&path, "ollama", 0).is_err());
        assert!(super::set_port_in(&path, "unknown", 1234).is_err());
        super::set_port_in(&path, "lmstudio", 1234).expect("reset");
        let ports = super::load_ports(&path).expect("reload defaults");
        assert!(!ports.0.contains_key("lmstudio"));
        assert_eq!(ports.0.get("ollama"), Some(&65535));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path)
                    .expect("metadata")
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        std::fs::remove_dir_all(dir).expect("cleanup");
    }

    #[test]
    fn corrupt_settings_never_silently_use_another_port() {
        let dir = fixture_dir();
        std::fs::create_dir_all(&dir).expect("directory");
        let path = dir.join("ports.json");
        for data in [
            r#"{"ollama":0}"#,
            r#"{"lmstudio":65536}"#,
            r#"{"unknown":1234}"#,
            "incomplete",
        ] {
            std::fs::write(&path, data).expect("fixture");
            assert!(super::load_ports(&path).is_err());
            assert!(super::set_port_in(&path, "lmstudio", 1234).is_err());
            assert_eq!(std::fs::read_to_string(&path).expect("unchanged"), data);
        }
        std::fs::remove_dir_all(dir).expect("cleanup");
    }

    #[test]
    fn the_wire_shape_is_camel_case() {
        // Pinned because a client decodes these names literally. `baseUrl`
        // spelled `baseURL` on the other side failed every response, and the
        // failure surfaced as "no local models discovered" rather than as a
        // decoding error.
        let value = serde_json::to_value(LocalProvider {
            id: "lmstudio".into(),
            name: "LM Studio".into(),
            base_url: "http://127.0.0.1:1234/v1".into(),
            port: 1234,
            default_port: 1234,
            available: true,
            models: vec![LocalModel {
                id: "qwen/a".into(),
                name: "qwen/a".into(),
                size_bytes: Some(7),
            }],
            error: None,
        })
        .expect("serialize");
        let object = value.as_object().expect("an object");
        let mut keys: Vec<_> = object.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "available",
                "baseUrl",
                "defaultPort",
                "error",
                "id",
                "models",
                "name",
                "port"
            ]
        );
        let model = value["models"][0].as_object().expect("an object");
        let mut model_keys: Vec<_> = model.keys().map(String::as_str).collect();
        model_keys.sort_unstable();
        assert_eq!(model_keys, ["id", "name", "sizeBytes"]);
    }

    #[test]
    fn a_providers_address_comes_from_one_table() {
        assert_eq!(origin("lmstudio").as_deref(), Ok("http://127.0.0.1:1234"));
        assert_eq!(
            api_base_url("lmstudio").as_deref(),
            Ok("http://127.0.0.1:1234/v1")
        );
        assert!(origin("nothing").is_err());
    }

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
    fn a_refused_connect_is_just_not_running() {
        let refused = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "os error 61");
        assert_eq!(super::connect_error(refused), "not running");
        let other = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied");
        assert!(super::connect_error(other).contains("denied"));
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
