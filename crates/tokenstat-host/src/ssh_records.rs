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
}

fn default_port() -> u16 {
    22
}
fn store_version() -> u32 {
    1
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
            version: 1,
            ..Store::default()
        }),
        Err(e) => Err(format!("read SSH records: {e}")),
    }
}

fn save_to(path: &Path, store: &Store) -> Result<(), String> {
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

#[derive(Deserialize)]
struct IdParam {
    id: String,
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("ssh.host.")
        && !method.starts_with("ssh.key.")
        && !method.starts_with("ssh.snippet.")
    {
        return None;
    }
    Some(call_inner(method, params))
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
            if item.port == 0 {
                return Err("port must be between 1 and 65535".into());
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
            }],
            snippets: vec![],
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
}
