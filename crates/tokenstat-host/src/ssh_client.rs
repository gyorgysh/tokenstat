// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Interactive SSH sessions shared by desktop and mobile clients.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use russh::client;
use russh::keys::{PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::{ChannelMsg, Disconnect};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::mpsc;

const MAX_BUFFER: usize = 4 * 1024 * 1024;

/// How much of a directory listing is read before the rest is dropped.
///
/// A directory can hold a million names and a palette shows six. Reading is
/// stopped rather than the answer trimmed afterwards, so a server with an
/// enormous directory costs a few kilobytes here and not a few megabytes.
const LIST_BYTES: usize = 64 * 1024;

/// How many names are kept out of one listing.
const LIST_ENTRIES: usize = 2_000;

/// How long a listing may take before it is abandoned.
const LIST_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a listing stays usable. Short, because a person who has just made
/// a directory expects to be able to complete it.
const LIST_FRESH_MS: i64 = 5_000;

/// How long a failure is remembered. Longer, so a server with no `ls`, or a
/// directory nobody may read, is asked once rather than on every keystroke.
const LIST_FAILED_MS: i64 = 30_000;

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
    /// The authenticated connection, shared with the task that runs the
    /// shell. Completion opens its own short-lived channel on it rather than
    /// typing into the person's shell: asking the server what is in a
    /// directory must never disturb the line they are in the middle of.
    handle: Arc<client::Handle<HostKeyCheck>>,
    /// What the far end last said was in a directory, per directory.
    directories: Arc<Mutex<DirCache>>,
    /// What the client called this, and which saved record it came from.
    ///
    /// Carried so `ssh.session.list` can answer with something a person
    /// recognises. The host has no other way to name a session: it knows a
    /// hostname and a username, and a list of four `root@10.0.0.4` rows is a
    /// list nobody can use.
    meta: SessionMeta,
}

/// Recently listed directories, and the ones being listed right now.
#[derive(Default)]
struct DirCache {
    listed: HashMap<String, Listed>,
    /// One request per directory at a time. Typing five characters quickly
    /// asks about the same directory five times, and four of those are work
    /// nobody is waiting for.
    inflight: HashSet<String>,
}

struct Listed {
    entries: Vec<crate::ssh_suggest::Entry>,
    at_ms: i64,
    ok: bool,
}

impl Listed {
    fn fresh(&self, now: i64) -> bool {
        let life = if self.ok {
            LIST_FRESH_MS
        } else {
            LIST_FAILED_MS
        };
        now.saturating_sub(self.at_ms) < life
    }
}

#[derive(Clone)]
struct SessionMeta {
    host_id: Option<String>,
    label: String,
    opened_ms: i64,
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
    /// The saved record this session came from, when it came from one. Kept
    /// only to answer `ssh.session.list`, never used to reach the server.
    #[serde(default)]
    host_id: Option<String>,
    /// What to call this session in a list. Falls back to `user@host`.
    #[serde(default)]
    label: Option<String>,
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

/// What somebody has typed so far, and where the session is sitting.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SuggestParams {
    id: String,
    /// The command line as typed since the last Return. Never stored, never
    /// logged, and never sent anywhere: it is read to find the last word and
    /// dropped when this call returns.
    #[serde(default)]
    fragment: String,
    /// The session's working directory, when the server has said what it is.
    /// Without one a relative word has no meaning this side could give it, so
    /// nothing is offered for it.
    #[serde(default)]
    directory: Option<String>,
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
            let meta = SessionMeta {
                host_id: p.host_id.clone(),
                label: p
                    .label
                    .clone()
                    .filter(|label| !label.trim().is_empty())
                    .unwrap_or_else(|| format!("{}@{}", p.username, p.hostname)),
                opened_ms: now_ms(),
            };
            let live = runtime()?.block_on(open(p, id.clone(), meta))?;
            let mut map = sessions().lock().map_err(|e| e.to_string())?;
            reap_closed(&mut map);
            map.insert(id.clone(), live);
            Ok(json!({"id": id}))
        }
        // Every session this host is holding, so a client that has been
        // relaunched can adopt what it left running instead of showing an
        // empty screen over four live shells. The pty side has had `pty.list`
        // from the start and SSH never grew the equivalent.
        "ssh.session.list" => {
            let mut guard = sessions().lock().map_err(|e| e.to_string())?;
            reap_closed(&mut guard);
            let mut rows: Vec<Value> = guard
                .iter()
                .map(|(id, live)| {
                    let (dropped, closed) = live
                        .output
                        .lock()
                        .map(|out| (out.base, out.closed))
                        .unwrap_or((0, true));
                    json!({
                        "id": id,
                        "hostId": live.meta.host_id,
                        "label": live.meta.label,
                        "openedMs": live.meta.opened_ms,
                        "alive": !closed,
                        "droppedBytes": dropped,
                    })
                })
                .collect();
            // Oldest first, so a list does not reshuffle itself between two
            // calls the way a hash map's order does.
            rows.sort_by_key(|row| row["openedMs"].as_i64().unwrap_or_default());
            serde_json::to_value(rows).map_err(|e| e.to_string())
        }
        "ssh.session.read" => {
            let p: SessionParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            // Deliberately not reaped here. Reaping first meant a session that
            // had just closed was gone before the read that would have carried
            // its `closed` flag, so every ordinary logout surfaced as "SSH
            // session no longer exists". A closed session is cleared by the
            // next open or list instead.
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
        // What to offer somebody part-way through a command. Two sources,
        // both of them things the person already has: commands they saved,
        // and the names the server itself reports in one directory.
        //
        // It never blocks. A directory that is not already known is asked for
        // in the background and the answer says `pending`, so the palette can
        // show the snippets it does have now and pick the names up on the
        // next keystroke rather than freezing the line for a round trip.
        "ssh.session.suggest" => {
            let p: SuggestParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            if p.fragment.len() > 4096 {
                return Ok(json!({"fragment": "", "rows": [], "pending": false}));
            }
            let (handle, directories, host_id) = {
                let guard = sessions().lock().map_err(|e| e.to_string())?;
                let live = guard.get(&p.id).ok_or("SSH session no longer exists")?;
                (
                    Arc::clone(&live.handle),
                    Arc::clone(&live.directories),
                    live.meta.host_id.clone(),
                )
            };
            let token = crate::ssh_suggest::last_token(&p.fragment);
            let query = crate::ssh_suggest::path_query(&token, p.directory.as_deref());
            let mut entries = Vec::new();
            let mut pending = false;
            if let Some(query) = &query {
                match remembered(&directories, &query.dir)? {
                    Some(known) => entries = known,
                    None => pending = start_listing(handle, directories, query.dir.clone()),
                }
            }
            let snippets = crate::ssh_records::snippets_for(host_id.as_deref())?;
            let rows =
                crate::ssh_suggest::rank(&p.fragment, &token, query.as_ref(), &entries, &snippets);
            // The fragment comes back so a client can throw away an answer
            // that arrived after the person typed something else.
            Ok(json!({"fragment": p.fragment, "rows": rows, "pending": pending}))
        }
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

/// What is already known about a directory, if it is still worth trusting.
fn remembered(
    cache: &Mutex<DirCache>,
    dir: &str,
) -> Result<Option<Vec<crate::ssh_suggest::Entry>>, String> {
    let now = now_ms();
    let guard = cache.lock().map_err(|e| e.to_string())?;
    Ok(guard
        .listed
        .get(dir)
        .filter(|listed| listed.fresh(now))
        .map(|listed| listed.entries.clone()))
}

/// Ask the server what is in one directory, in the background.
///
/// Answers `true` when something is now on its way, which is the client's cue
/// to ask again shortly. A directory already being listed answers `true`
/// without asking twice, and a path that cannot be written as a safe command
/// answers `false` so nothing is ever waited for.
fn start_listing(
    handle: Arc<client::Handle<HostKeyCheck>>,
    cache: Arc<Mutex<DirCache>>,
    dir: String,
) -> bool {
    let Some(command) = crate::ssh_suggest::list_command(&dir) else {
        return false;
    };
    {
        let Ok(mut guard) = cache.lock() else {
            return false;
        };
        if !guard.inflight.insert(dir.clone()) {
            return true;
        }
    }
    let Ok(runtime) = runtime() else {
        return false;
    };
    runtime.spawn(async move {
        let listed = tokio::time::timeout(LIST_TIMEOUT, list_directory(&handle, command)).await;
        let entries = match listed {
            Ok(Ok(entries)) => Some(entries),
            // A server with no `ls`, a directory nobody may read, or one that
            // took too long. Remembered as a failure so it is not asked again
            // on the next keystroke.
            Ok(Err(_)) | Err(_) => None,
        };
        if let Ok(mut guard) = cache.lock() {
            guard.inflight.remove(&dir);
            guard.listed.insert(
                dir,
                Listed {
                    ok: entries.is_some(),
                    entries: entries.unwrap_or_default(),
                    at_ms: now_ms(),
                },
            );
            // The cache follows one person moving around a server, not a
            // crawl of it. Anything older than a failure's lifetime is gone.
            let now = now_ms();
            guard.listed.retain(|_, listed| {
                now.saturating_sub(listed.at_ms) < LIST_FRESH_MS.max(LIST_FAILED_MS)
            });
        }
    });
    true
}

/// Run one bounded `ls` on its own channel and read what it printed.
///
/// Its own channel on the connection that is already open, so the interactive
/// shell never sees it: no line is typed into the person's prompt, no history
/// entry is made, and nothing on the server changes. Reading stops at
/// `LIST_BYTES` whatever the far end is still sending.
async fn list_directory(
    handle: &client::Handle<HostKeyCheck>,
    command: String,
) -> Result<Vec<crate::ssh_suggest::Entry>, String> {
    let mut channel = handle
        .channel_open_session()
        .await
        .map_err(|e| e.to_string())?;
    channel
        .exec(true, command.into_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let mut out: Vec<u8> = Vec::new();
    while let Some(message) = channel.wait().await {
        match message {
            ChannelMsg::Data { data } => {
                let room = LIST_BYTES.saturating_sub(out.len());
                out.extend_from_slice(&data[..room.min(data.len())]);
                if out.len() >= LIST_BYTES {
                    break;
                }
            }
            // `ls` complaining about a directory that is not there. The
            // listing is simply empty; the message is not shown to anybody.
            ChannelMsg::ExtendedData { .. } => {}
            ChannelMsg::Eof | ChannelMsg::Close => break,
            _ => {}
        }
    }
    let _ = channel.close().await;
    Ok(crate::ssh_suggest::parse_listing(
        &String::from_utf8_lossy(&out),
        LIST_ENTRIES,
    ))
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

async fn open(p: OpenParams, id: String, meta: SessionMeta) -> Result<LiveSession, String> {
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
    let handle = Arc::new(handle);
    let task_handle = Arc::clone(&handle);
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
        let _ = task_handle
            .disconnect(Disconnect::ByApplication, "closed", "en")
            .await;
        task_output.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
        if let Ok(mut map) = sessions().lock() {
            map.remove(&id);
        }
    });
    Ok(LiveSession {
        commands: tx,
        output,
        handle,
        directories: Arc::new(Mutex::new(DirCache::default())),
        meta,
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

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
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
    fn a_listing_is_trusted_briefly_and_a_failure_for_longer() {
        let at = 1_000_000i64;
        let ok = Listed {
            entries: vec![],
            at_ms: at,
            ok: true,
        };
        let failed = Listed {
            entries: vec![],
            at_ms: at,
            ok: false,
        };
        assert!(ok.fresh(at + LIST_FRESH_MS - 1));
        assert!(
            !ok.fresh(at + LIST_FRESH_MS),
            "a directory somebody has just added to is asked about again"
        );
        assert!(
            failed.fresh(at + LIST_FRESH_MS),
            "a server with no ls is not asked again on the next keystroke"
        );
        assert!(!failed.fresh(at + LIST_FAILED_MS));
    }

    #[test]
    fn suggesting_for_a_session_that_is_gone_says_so() {
        let refused = call(
            "ssh.session.suggest",
            r#"{"id":"ssh_nothing","fragment":"cd /o"}"#,
        )
        .expect("handled here")
        .expect_err("no such session");
        assert!(refused.contains("no longer exists"), "{refused}");
    }

    #[test]
    fn a_remote_peer_cannot_ask_what_is_on_a_server() {
        crate::request_context::with_remote_peer("phone", || {
            let refused = call("ssh.session.suggest", r#"{"id":"ssh_x","fragment":"cd /"}"#)
                .unwrap()
                .expect_err("must refuse");
            assert!(refused.contains("local-only"), "{refused}");
        });
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
