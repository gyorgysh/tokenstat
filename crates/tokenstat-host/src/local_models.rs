// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.

//! Discovery for model servers listening on this machine's loopback.
//!
//! This is deliberately in the host crate. Local provider discovery is a host
//! feature, not archive parsing, and must never add a network dependency to
//! `tokenstat-core`.

use std::io::Read;
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
    /// Serves Anthropic's Messages API, which Claude Code needs. LM Studio
    /// always has. Ollama gained it in a later release, so it is asked.
    pub anthropic: bool,
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

fn spec(provider: &str) -> Option<&'static ProviderSpec> {
    PROVIDERS.iter().find(|spec| spec.id == provider)
}

/// Chat names a local model as `local:<provider>/<model>`, so a stored
/// choice can never be mistaken for a cloud model of the same name.
pub(crate) const CHAT_PREFIX: &str = "local:";

/// The local servers each chat agent can talk to. Same contract as the
/// terminal launcher's `model_environment`: Claude needs an Anthropic
/// compatible endpoint, which LM Studio and recent Ollama builds serve.
pub(crate) fn chat_providers(backend: &str) -> &'static [&'static str] {
    match backend {
        // Ollama only where it answers Anthropic's API: see `anthropic`.
        "claude" | "codex" | "opencode" | "opencode2" => &["lmstudio", "ollama"],
        _ => &[],
    }
}

/// The provider and model a chat's stored model names, when it is local.
pub(crate) fn chat_selection(model: Option<&str>) -> Option<(&str, &str)> {
    let rest = model?.trim().strip_prefix(CHAT_PREFIX)?;
    let (provider, model) = rest.split_once('/')?;
    (spec(provider).is_some() && !model.is_empty() && !model.chars().any(char::is_control))
        .then_some((provider, model))
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
    let providers = probe()?;
    // Reports price these at zero. Best effort: a failed write only means a
    // local model may borrow a similar cloud model's list rate.
    let _ = tokenstat_core::pricing::local_models::remember(
        providers
            .iter()
            .flat_map(|provider| provider.models.iter().map(|model| model.id.clone())),
    );
    Ok(providers)
}

/// Before a turn, make sure the server is up and still has the model, so a
/// person reads what to do rather than the agent's connection error.
pub(crate) fn check_ready(provider: &str, model: &str, anthropic: bool) -> Result<(), String> {
    let spec = spec(provider).ok_or("unknown local model provider")?;
    check_ready_at(spec, configured_port(provider)?, model, anthropic)?;
    let _ = tokenstat_core::pricing::local_models::remember([model.to_owned()]);
    Ok(())
}

fn check_ready_at(
    spec: &ProviderSpec,
    port: u16,
    model: &str,
    anthropic: bool,
) -> Result<(), String> {
    let models = get_json(port, spec.path)
        .and_then(|value| (spec.parse)(&value))
        .map_err(|_| {
            format!(
                "{} is not running on this computer. Start it, or pick another model for this chat.",
                spec.name
            )
        })?;
    if !models.iter().any(|known| known.id == model) {
        return Err(format!(
            "{} is running but no longer has {model}. Load it again, or pick another model.",
            spec.name
        ));
    }
    if anthropic && spec.id == "ollama" && !has_messages_route(port) {
        return Err(
            "This Ollama server does not support Claude Code. Update Ollama or pick another model."
                .into(),
        );
    }
    Ok(())
}

fn probe() -> Result<Vec<LocalProvider>, String> {
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
            let anthropic = available && (spec.id == "lmstudio" || has_messages_route(port));
            LocalProvider {
                id: spec.id.to_string(),
                name: spec.name.to_string(),
                base_url,
                port,
                default_port: spec.port,
                available,
                models,
                error,
                anthropic,
            }
        })
        .collect())
}

/// How many tokens a local model can hold, as its server reports it.
///
/// A tool that is told a model with no size assumes a small one, and
/// OpenCode then compacts a fresh chat on its first turn: a long system
/// prompt reads as an overflow. Best effort: None when the server does not
/// say, and the tool keeps its own default.
pub(crate) fn context_window(provider: &str, model: &str) -> Option<u64> {
    let port = configured_port(provider).ok()?;
    match provider {
        "ollama" => {
            // The loaded window can be much smaller than the model's maximum.
            if let Some(tokens) = get_json(port, "/api/ps")
                .ok()
                .as_ref()
                .and_then(|value| ollama_loaded_context(value, model))
            {
                return Some(tokens);
            }
            let info = request_json(
                port,
                "/api/show",
                Some(serde_json::json!({ "model": model })),
            )
            .ok()?;
            info.get("model_info")?
                .as_object()?
                .iter()
                .find(|(key, _)| key.ends_with(".context_length"))
                .and_then(|(_, value)| value.as_u64())
        }
        "lmstudio" => {
            let path = format!("/api/v0/models/{}", url_segment(model));
            let info = request_json(port, &path, None).ok()?;
            info.get("loaded_context_length")
                .or_else(|| info.get("max_context_length"))
                .and_then(Value::as_u64)
        }
        _ => None,
    }
    .filter(|tokens| *tokens > 0)
}

/// A model id as one path segment. LM Studio ids carry a slash.
fn ollama_loaded_context(value: &Value, model: &str) -> Option<u64> {
    value
        .get("models")?
        .as_array()?
        .iter()
        .find(|row| {
            row.get("name")
                .or_else(|| row.get("model"))
                .and_then(Value::as_str)
                == Some(model)
        })?
        .get("context_length")?
        .as_u64()
        .filter(|tokens| *tokens > 0)
}

fn url_segment(id: &str) -> String {
    id.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (byte as char).to_string()
            }
            other => format!("%{other:02X}"),
        })
        .collect()
}

/// Whether the server knows Anthropic's `/v1/messages` route. An empty body
/// is refused as a bad request where the route exists and as not found where
/// it does not, so nothing is generated and no model is loaded to answer.
fn has_messages_route(port: u16) -> bool {
    let Ok(client) = tokenstat_sync::http::client_builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(READ_TIMEOUT)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
    else {
        return false;
    };
    client
        .post(format!("http://127.0.0.1:{port}/v1/messages"))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body("{}")
        .send()
        .is_ok_and(|response| matches!(response.status().as_u16(), 400 | 422))
}

fn get_json(port: u16, path: &str) -> Result<Value, String> {
    request_json(port, path, None)
}

fn request_json(port: u16, path: &str, body: Option<Value>) -> Result<Value, String> {
    // A real HTTP decoder handles chunked responses and Content-Length without
    // waiting for a server to close a reusable connection. The total deadline
    // also bounds a server that continually trickles a few bytes.
    let client = tokenstat_sync::http::client_builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(READ_TIMEOUT)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|error| error.to_string())?;
    let url = format!("http://127.0.0.1:{port}{path}");
    let request = match body {
        Some(body) => client.post(url).json(&body),
        None => client.get(url),
    };
    let response = request
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .map_err(|error| {
            if error.is_connect() || error.is_timeout() {
                "not running".into()
            } else {
                error.to_string()
            }
        })?;
    if !response.status().is_success() {
        return Err(format!("local server returned HTTP {}", response.status()));
    }
    let mut body = Vec::new();
    response
        .take(MAX_RESPONSE_BYTES as u64 + 1)
        .read_to_end(&mut body)
        .map_err(|error| error.to_string())?;
    if body.len() > MAX_RESPONSE_BYTES {
        return Err("response was too large".into());
    }
    serde_json::from_slice(&body).map_err(|error| format!("invalid model response: {error}"))
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
    #[test]
    fn a_chat_model_is_local_only_with_the_prefix_and_a_known_server() {
        assert_eq!(
            super::chat_selection(Some("local:lmstudio/qwen/qwen3-coder")),
            Some(("lmstudio", "qwen/qwen3-coder"))
        );
        assert_eq!(
            super::chat_selection(Some("local:ollama/llama3.2")),
            Some(("ollama", "llama3.2"))
        );
        assert_eq!(super::chat_selection(Some("lmstudio/qwen")), None);
        assert_eq!(super::chat_selection(Some("local:elsewhere/qwen")), None);
        assert_eq!(super::chat_selection(Some("local:ollama/")), None);
        assert_eq!(super::chat_selection(Some("local:ollama/a\nb")), None);
        assert_eq!(super::chat_selection(None), None);
    }

    use super::{LocalModel, LocalProvider, api_base_url, origin, parse_lmstudio, parse_ollama};
    use serde_json::json;

    #[test]
    fn chunked_model_discovery_finishes_without_waiting_for_connection_close() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (done, wait) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                .unwrap();
            let mut request = Vec::new();
            let mut byte = [0];
            while !request.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
            }
            stream.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nB\r\n{\"data\":[]}\r\n0\r\n\r\n").unwrap();
            let _ = wait.recv_timeout(std::time::Duration::from_secs(3));
        });
        let result = super::get_json(port, "/v1/models");
        done.send(()).unwrap();
        server.join().unwrap();
        assert_eq!(result.unwrap(), json!({"data": []}));
    }

    #[test]
    fn local_readiness_checks_route_compatibility_missing_models_and_server_loss() {
        use std::io::{BufRead, BufReader, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            for (expected, status, body) in [
                (
                    "GET /api/tags ",
                    "200 OK",
                    r#"{"models":[{"name":"qwen:latest"}]}"#,
                ),
                ("POST /v1/messages ", "400 Bad Request", "{}"),
                (
                    "GET /api/tags ",
                    "200 OK",
                    r#"{"models":[{"name":"qwen:latest"}]}"#,
                ),
                ("POST /v1/messages ", "404 Not Found", "{}"),
                ("GET /api/tags ", "200 OK", r#"{"models":[]}"#),
            ] {
                let (mut stream, _) = listener.accept().unwrap();
                stream.set_read_timeout(Some(super::READ_TIMEOUT)).unwrap();
                let mut request = BufReader::new(&mut stream);
                let mut line = String::new();
                request.read_line(&mut line).unwrap();
                assert!(line.starts_with(expected), "{line}");
                while line != "\r\n" {
                    line.clear();
                    assert_ne!(request.read_line(&mut line).unwrap(), 0);
                }
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });

        let ollama = super::spec("ollama").unwrap();
        super::check_ready_at(ollama, port, "qwen:latest", true).unwrap();
        assert!(
            super::check_ready_at(ollama, port, "qwen:latest", true)
                .unwrap_err()
                .contains("Update Ollama")
        );
        assert!(
            super::check_ready_at(ollama, port, "qwen:latest", false)
                .unwrap_err()
                .contains("Load it again")
        );
        server.join().unwrap();
        assert!(
            super::check_ready_at(ollama, port, "qwen:latest", false)
                .unwrap_err()
                .contains("Start it")
        );
    }

    #[test]
    fn ollama_reports_the_loaded_window_for_the_exact_model() {
        let ps = json!({"models": [
            {"name": "llama3.2:1b", "context_length": 32_768},
            {"model": "llama3.2:3b", "context_length": 65_536},
            {"name": "not-reported", "context_length": 0},
        ]});
        assert_eq!(
            super::ollama_loaded_context(&ps, "llama3.2:1b"),
            Some(32_768)
        );
        assert_eq!(
            super::ollama_loaded_context(&ps, "llama3.2:3b"),
            Some(65_536)
        );
        assert_eq!(super::ollama_loaded_context(&ps, "llama3.2"), None);
        assert_eq!(super::ollama_loaded_context(&ps, "not-reported"), None);
    }

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
            anthropic: false,
            error: None,
        })
        .expect("serialize");
        let object = value.as_object().expect("an object");
        let mut keys: Vec<_> = object.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "anthropic",
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
        crate::test_identity::isolated(|| {
            assert_eq!(origin("lmstudio").as_deref(), Ok("http://127.0.0.1:1234"));
            assert_eq!(
                api_base_url("lmstudio").as_deref(),
                Ok("http://127.0.0.1:1234/v1")
            );
            assert!(origin("nothing").is_err());
        });
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
    fn ollama_models_keep_names_and_sizes() {
        let models = parse_ollama(&json!({
            "models": [{"name": "llama3.2:latest", "size": 1234}]
        }))
        .expect("models");
        assert_eq!(models[0].name, "llama3.2:latest");
        assert_eq!(models[0].size_bytes, Some(1234));
    }
}
