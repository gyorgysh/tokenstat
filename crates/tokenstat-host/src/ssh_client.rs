// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Interactive SSH sessions shared by desktop and mobile clients.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use russh::client;
use russh::keys::{PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::{ChannelMsg, Disconnect};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::mpsc;

const MAX_BUFFER: usize = 4 * 1024 * 1024;

#[derive(Clone)]
struct HostKeyCheck {
    allowed: Vec<String>,
    offered: Arc<Mutex<Option<String>>>,
    probe: bool,
}

impl client::Handler for HostKeyCheck {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let fingerprint = key
            .public_key()
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string();
        *self.offered.lock().unwrap_or_else(|e| e.into_inner()) = Some(fingerprint.clone());
        Ok(self.probe || self.allowed.iter().any(|known| known == &fingerprint))
    }
}

enum Command {
    Write(Vec<u8>),
    Resize(u32, u32),
    Close,
}

struct Output {
    bytes: Vec<u8>,
    base: u64,
    closed: bool,
    error: Option<String>,
}

struct LiveSession {
    commands: mpsc::UnboundedSender<Command>,
    output: Arc<Mutex<Output>>,
}

fn sessions() -> &'static Mutex<HashMap<String, LiveSession>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, LiveSession>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn runtime() -> Result<&'static tokio::runtime::Runtime, String> {
    static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .thread_name("tokenstat-ssh")
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(Clone::clone)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenParams {
    hostname: String,
    #[serde(default = "default_port")]
    port: u16,
    username: String,
    #[serde(default = "default_initial_directory")]
    initial_directory: String,
    host_keys: Vec<String>,
    #[serde(default = "default_rows")]
    rows: u32,
    #[serde(default = "default_cols")]
    cols: u32,
    #[serde(default)]
    auth: Option<Auth>,
}

fn default_initial_directory() -> String {
    "~".into()
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum Auth {
    Password {
        password: String,
    },
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
    },
    Agent {
        fingerprint: String,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionParams {
    id: String,
    #[serde(default)]
    offset: u64,
    #[serde(default)]
    data: Vec<u8>,
    #[serde(default)]
    rows: u32,
    #[serde(default)]
    cols: u32,
}

fn default_port() -> u16 {
    22
}
fn default_rows() -> u32 {
    24
}
fn default_cols() -> u32 {
    80
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("ssh.session.") && method != "ssh.host.probe" {
        return None;
    }
    Some(call_inner(method, params))
}

fn call_inner(method: &str, params: &str) -> Result<Value, String> {
    match method {
        "ssh.host.probe" => {
            let p: OpenParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let fingerprint = runtime()?.block_on(probe(&p))?;
            Ok(json!({"fingerprint": fingerprint}))
        }
        "ssh.session.open" => {
            let p: OpenParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            if p.host_keys.is_empty() {
                return Err("Confirm this server's fingerprint before connecting.".into());
            }
            let id = new_id()?;
            let live = runtime()?.block_on(open(p))?;
            sessions()
                .lock()
                .map_err(|e| e.to_string())?
                .insert(id.clone(), live);
            Ok(json!({"id": id}))
        }
        "ssh.session.read" => {
            let p: SessionParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let guard = sessions().lock().map_err(|e| e.to_string())?;
            let live = guard.get(&p.id).ok_or("SSH session no longer exists")?;
            let output = live.output.lock().map_err(|e| e.to_string())?;
            let start = p.offset.saturating_sub(output.base) as usize;
            let data = output.bytes.get(start..).unwrap_or_default();
            Ok(
                json!({"data": data, "nextOffset": output.base + output.bytes.len() as u64,
                "dropped": p.offset < output.base, "closed": output.closed, "error": output.error}),
            )
        }
        "ssh.session.write" => command(params, |p| Command::Write(p.data)),
        "ssh.session.resize" => command(params, |p| Command::Resize(p.cols.max(1), p.rows.max(1))),
        "ssh.session.close" => {
            let p: SessionParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            if let Some(live) = sessions().lock().map_err(|e| e.to_string())?.remove(&p.id) {
                let _ = live.commands.send(Command::Close);
                Ok(json!({"closed": true}))
            } else {
                Ok(json!({"closed": false}))
            }
        }
        _ => Err(format!("unknown method: {method}")),
    }
}

fn command<F>(params: &str, make: F) -> Result<Value, String>
where
    F: FnOnce(SessionParams) -> Command,
{
    let p: SessionParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let guard = sessions().lock().map_err(|e| e.to_string())?;
    let live = guard.get(&p.id).ok_or("SSH session no longer exists")?;
    live.commands
        .send(make(p))
        .map_err(|_| "SSH session is closed".to_string())?;
    Ok(json!({"accepted": true}))
}

async fn connect(
    p: &OpenParams,
    probe: bool,
) -> Result<(client::Handle<HostKeyCheck>, Arc<Mutex<Option<String>>>), String> {
    if p.hostname.trim().is_empty() || p.username.trim().is_empty() {
        return Err("hostname and username are required".into());
    }
    let offered = Arc::new(Mutex::new(None));
    let handler = HostKeyCheck {
        allowed: p.host_keys.clone(),
        offered: Arc::clone(&offered),
        probe,
    };
    let config = Arc::new(client::Config {
        inactivity_timeout: Some(Duration::from_secs(30)),
        ..Default::default()
    });
    let handle = client::connect(config, (p.hostname.as_str(), p.port), handler)
        .await
        .map_err(|e| e.to_string())?;
    Ok((handle, offered))
}

async fn probe(p: &OpenParams) -> Result<String, String> {
    let (handle, offered) = connect(p, true).await?;
    let _ = handle
        .disconnect(Disconnect::ByApplication, "fingerprint checked", "en")
        .await;
    offered
        .lock()
        .map_err(|e| e.to_string())?
        .clone()
        .ok_or_else(|| "server offered no host key".into())
}

async fn open(p: OpenParams) -> Result<LiveSession, String> {
    let (mut handle, _) = connect(&p, false).await?;
    let authenticated = match p.auth.ok_or("SSH authentication is required")? {
        Auth::Password { password } => handle
            .authenticate_password(&p.username, password)
            .await
            .map_err(|e| e.to_string())?,
        Auth::PrivateKey { pem, passphrase } => {
            let key = russh::keys::decode_secret_key(&pem, passphrase.as_deref())
                .map_err(|e| e.to_string())?;
            let hash = handle
                .best_supported_rsa_hash()
                .await
                .map_err(|e| e.to_string())?
                .flatten();
            handle
                .authenticate_publickey(
                    &p.username,
                    PrivateKeyWithHashAlg::new(Arc::new(key), hash),
                )
                .await
                .map_err(|e| e.to_string())?
        }
        Auth::Agent { fingerprint } => {
            authenticate_agent(&mut handle, &p.username, &fingerprint).await?
        }
    };
    if !authenticated.success() {
        return Err("SSH authentication was refused".into());
    }
    let mut channel = handle
        .channel_open_session()
        .await
        .map_err(|e| e.to_string())?;
    channel
        .request_pty(
            true,
            "xterm-256color",
            p.cols.max(1),
            p.rows.max(1),
            0,
            0,
            &[],
        )
        .await
        .map_err(|e| e.to_string())?;
    channel
        .request_shell(true)
        .await
        .map_err(|e| e.to_string())?;
    let directory = p.initial_directory.trim();
    if !directory.is_empty() && directory != "~" {
        let quoted = directory.replace('\'', "'\"'\"'");
        channel
            .data(format!("cd -- '{quoted}'\r").as_bytes())
            .await
            .map_err(|e| e.to_string())?;
    }
    let (tx, mut rx) = mpsc::unbounded_channel();
    let output = Arc::new(Mutex::new(Output {
        bytes: Vec::new(),
        base: 0,
        closed: false,
        error: None,
    }));
    let task_output = Arc::clone(&output);
    runtime()?.spawn(async move {
        loop {
            tokio::select! {
                command = rx.recv() => match command {
                    Some(Command::Write(bytes)) => { if channel.data(&bytes[..]).await.is_err() { break; } }
                    Some(Command::Resize(cols, rows)) => { let _ = channel.window_change(cols, rows, 0, 0).await; }
                    Some(Command::Close) | None => { let _ = channel.close().await; break; }
                },
                message = channel.wait() => match message {
                    Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => append(&task_output, &data),
                    Some(ChannelMsg::ExitStatus { .. }) | None => break,
                    _ => {}
                }
            }
        }
        let _ = handle.disconnect(Disconnect::ByApplication, "closed", "en").await;
        task_output.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
    });
    Ok(LiveSession {
        commands: tx,
        output,
    })
}

#[cfg(unix)]
async fn authenticate_agent(
    handle: &mut client::Handle<HostKeyCheck>,
    username: &str,
    fingerprint: &str,
) -> Result<client::AuthResult, String> {
    use russh::keys::agent::client::AgentClient;
    let mut agent = AgentClient::connect_env()
        .await
        .map_err(|e| e.to_string())?;
    let identities = agent
        .request_identities()
        .await
        .map_err(|e| e.to_string())?;
    let identity = identities
        .into_iter()
        .find(|identity| {
            identity
                .public_key()
                .fingerprint(russh::keys::HashAlg::Sha256)
                .to_string()
                == fingerprint
        })
        .ok_or_else(|| format!("SSH agent no longer offers {fingerprint}"))?;
    let key = identity.public_key().into_owned();
    let hash = handle
        .best_supported_rsa_hash()
        .await
        .map_err(|e| e.to_string())?
        .flatten();
    handle
        .authenticate_publickey_with(username, key, hash, &mut agent)
        .await
        .map_err(|e| e.to_string())
}

#[cfg(not(unix))]
async fn authenticate_agent(
    _handle: &mut client::Handle<HostKeyCheck>,
    _username: &str,
    _fingerprint: &str,
) -> Result<client::AuthResult, String> {
    Err("SSH agent authentication is not available on this platform".into())
}

fn append(output: &Mutex<Output>, data: &[u8]) {
    let mut output = output.lock().unwrap_or_else(|e| e.into_inner());
    output.bytes.extend_from_slice(data);
    if output.bytes.len() > MAX_BUFFER {
        let remove = output.bytes.len() - MAX_BUFFER;
        output.bytes.drain(..remove);
        output.base += remove as u64;
    }
}

fn new_id() -> Result<String, String> {
    let mut bytes = [0u8; 12];
    getrandom::fill(&mut bytes).map_err(|e| e.to_string())?;
    Ok(format!("ssh_{}", tokenstat_identity::hex(&bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_is_bounded_and_reports_its_new_base() {
        let output = Mutex::new(Output {
            bytes: vec![],
            base: 0,
            closed: false,
            error: None,
        });
        append(&output, &vec![b'x'; MAX_BUFFER + 41]);
        let output = output.lock().unwrap();
        assert_eq!(output.bytes.len(), MAX_BUFFER);
        assert_eq!(output.base, 41);
    }

    #[test]
    fn a_probe_does_not_require_a_credential() {
        let parsed: OpenParams =
            serde_json::from_str(r#"{"hostname":"example.com","username":"root","hostKeys":[]}"#)
                .unwrap();
        assert!(parsed.auth.is_none());
        assert_eq!(parsed.rows, 24);
        assert_eq!(parsed.cols, 80);
    }
}
