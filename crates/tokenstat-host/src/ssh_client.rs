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
    /// Reach this server through another one.
    ///
    /// The client resolves the chain and sends it, credentials and all,
    /// because only the client can open the platform vault. Boxed because the
    /// jump host is itself a host and may have a jump host of its own.
    #[serde(default)]
    jump: Option<Box<OpenParams>>,
    /// Environment set before the shell is handed over. Sent as `export`
    /// lines rather than as SSH env requests, because most servers refuse
    /// anything outside `AcceptEnv` and refuse it silently.
    #[serde(default)]
    env: Vec<crate::ssh_records::EnvPair>,
    /// Seconds between keepalives. 0 leaves the default alone.
    #[serde(default)]
    keepalive_seconds: u32,
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
    Some((|| {
        crate::request_context::refuse_remote("SSH sessions")?;
        call_inner(method, params)
    })())
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
            crate::ssh_records::validate_initial_directory(&p.initial_directory)?;
            let id = new_id()?;
            let live = runtime()?.block_on(open(p, id.clone()))?;
            let mut map = sessions().lock().map_err(|e| e.to_string())?;
            reap_closed(&mut map);
            map.insert(id.clone(), live);
            Ok(json!({"id": id}))
        }
        "ssh.session.read" => {
            let p: SessionParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let mut guard = sessions().lock().map_err(|e| e.to_string())?;
            reap_closed(&mut guard);
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
    let mut guard = sessions().lock().map_err(|e| e.to_string())?;
    reap_closed(&mut guard);
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
        // Interactive shells sit at a prompt with no traffic. russh's default
        // 30s inactivity window would drop them. Keepalives hold the TCP
        // session without treating silence as a hang.
        inactivity_timeout: Some(Duration::from_secs(30 * 60)),
        keepalive_interval: Some(Duration::from_secs(if p.keepalive_seconds == 0 {
            30
        } else {
            p.keepalive_seconds.clamp(5, 300) as u64
        })),
        keepalive_max: 6,
        ..Default::default()
    });
    // No jump host: dial the server directly, as before.
    let Some(jump) = p.jump.as_deref() else {
        let handle = client::connect(config, (p.hostname.as_str(), p.port), handler)
            .await
            .map_err(|e| e.to_string())?;
        return Ok((handle, offered));
    };
    // Through a jump host: authenticate there, ask it to open a TCP channel to
    // the real server, and run the second SSH session inside that channel. The
    // bytes past the jump host are encrypted to the destination, which is the
    // whole point of doing it this way rather than tunnelling a port.
    let jump_handle = authenticated_handle(jump).await?;
    let stream = jump_handle
        .channel_open_direct_tcpip(p.hostname.as_str(), u32::from(p.port), "127.0.0.1", 0)
        .await
        .map_err(|e| format!("open a channel through {}: {e}", jump.hostname))?
        .into_stream();
    let handle = client::connect_stream(config, stream, handler)
        .await
        .map_err(|e| e.to_string())?;
    Ok((handle, offered))
}

/// Connect to one host and authenticate it. Used for the jump host, where the
/// session exists only to carry somebody else's.
async fn authenticated_handle(p: &OpenParams) -> Result<client::Handle<HostKeyCheck>, String> {
    if p.host_keys.is_empty() {
        return Err(format!(
            "Confirm the fingerprint of {} before connecting through it.",
            p.hostname
        ));
    }
    let (mut handle, _) = Box::pin(connect(p, false)).await?;
    let auth = p
        .auth
        .as_ref()
        .ok_or("the jump host needs its own credential")?;
    if !authenticate(&mut handle, &p.username, auth)
        .await?
        .success()
    {
        return Err(format!("{} refused the credential", p.hostname));
    }
    Ok(handle)
}

/// One authentication attempt, whichever kind it is.
async fn authenticate(
    handle: &mut client::Handle<HostKeyCheck>,
    username: &str,
    auth: &Auth,
) -> Result<client::AuthResult, String> {
    match auth {
        Auth::Password { password } => handle
            .authenticate_password(username, password.clone())
            .await
            .map_err(|e| e.to_string()),
        Auth::PrivateKey { pem, passphrase } => {
            let key = russh::keys::decode_secret_key(pem, passphrase.as_deref())
                .map_err(|e| e.to_string())?;
            let hash = handle
                .best_supported_rsa_hash()
                .await
                .map_err(|e| e.to_string())?
                .flatten();
            handle
                .authenticate_publickey(username, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
                .await
                .map_err(|e| e.to_string())
        }
        Auth::Agent { fingerprint } => authenticate_agent(handle, username, fingerprint).await,
    }
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

async fn open(p: OpenParams, id: String) -> Result<LiveSession, String> {
    let (mut handle, _) = connect(&p, false).await?;
    let auth = p.auth.as_ref().ok_or("SSH authentication is required")?;
    let authenticated = authenticate(&mut handle, &p.username, auth).await?;
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
    for pair in &p.env {
        crate::ssh_records::validate_env_name(&pair.name)?;
        crate::ssh_records::validate_shell_text(&pair.value, "environment value")?;
        let value = pair.value.replace('\'', "'\"'\"'");
        channel
            .data(format!("export {}='{}'\r", pair.name, value).as_bytes())
            .await
            .map_err(|e| e.to_string())?;
    }
    let directory = p.initial_directory.trim();
    if !directory.is_empty() && directory != "~" {
        crate::ssh_records::validate_initial_directory(directory)?;
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
        if let Ok(mut map) = sessions().lock() {
            map.remove(&id);
        }
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

fn reap_closed(map: &mut HashMap<String, LiveSession>) {
    map.retain(|_, live| {
        live.output
            .lock()
            .map(|output| !output.closed)
            .unwrap_or(false)
    });
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

    #[test]
    fn a_remote_peer_cannot_open_an_ssh_session() {
        crate::request_context::with_remote_peer("phone", || {
            let refused = call(
                "ssh.session.open",
                r#"{"hostname":"example.com","username":"root","hostKeys":["x"]}"#,
            )
            .unwrap()
            .expect_err("must refuse");
            assert!(refused.contains("local-only"), "{refused}");
        });
    }
}
