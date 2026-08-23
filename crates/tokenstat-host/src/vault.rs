// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! End-to-end encrypted SSH vault records.
//!
//! The recovery phrase is generated and consumed on the client side. Storage
//! sees authenticated ciphertext and opaque record ids only. There is no
//! recovery endpoint: losing all enrolled devices and the phrase loses access.

use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use chacha20poly1305::aead::{Aead, KeyInit, OsRng, rand_core::RngCore};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct VaultStore {
    verifier: String,
    records: Vec<VaultRecord>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct VaultRecord {
    id: String,
    version: u64,
    ciphertext: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryParams {
    recovery: String,
    #[serde(default, rename = "tier")]
    _tier: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PutParams {
    recovery: String,
    #[serde(default, rename = "tier")]
    _tier: String,
    id: String,
    plaintext: String,
}

fn lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn path() -> PathBuf {
    std::env::var_os("TOKENSTAT_SSH_VAULT_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            tokenstat_paths::data_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join("ssh-vault.json")
        })
}

fn paid(tier: &str) -> Result<(), String> {
    if matches!(tier, "supporter" | "patron" | "legend") {
        Ok(())
    } else {
        Err("SSH vault sync requires a paid plan".into())
    }
}

fn verify_paid_account() -> Result<(), String> {
    let status = tokenstat_sync::sync_status(None).map_err(|e| e.to_string())?;
    paid(status.tier.as_deref().unwrap_or(""))
}

fn key(recovery: &str) -> [u8; 32] {
    Sha256::digest(recovery.trim().as_bytes()).into()
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn unhex(value: &str) -> Result<Vec<u8>, String> {
    if value.len() % 2 != 0 {
        return Err("invalid ciphertext".into());
    }
    (0..value.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&value[i..i + 2], 16).map_err(|_| "invalid ciphertext".into()))
        .collect()
}

fn generate_recovery() -> String {
    let mut entropy = [0u8; 24];
    OsRng.fill_bytes(&mut entropy);
    entropy
        .iter()
        .map(|b| format!("vault{b:03}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn verifier(recovery: &str) -> String {
    let mut h = Sha256::new();
    h.update(b"tokenstat ssh vault verifier\0");
    h.update(key(recovery));
    hex(&h.finalize())
}

fn encrypt(recovery: &str, plaintext: &str) -> Result<String, String> {
    let cipher = XChaCha20Poly1305::new((&key(recovery)).into());
    let mut nonce = [0u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let sealed = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext.as_bytes())
        .map_err(|_| "vault encryption failed")?;
    Ok(format!("{}{}", hex(&nonce), hex(&sealed)))
}

fn decrypt(recovery: &str, ciphertext: &str) -> Result<String, String> {
    let bytes = unhex(ciphertext)?;
    if bytes.len() < 40 {
        return Err("invalid ciphertext".into());
    }
    let plain = XChaCha20Poly1305::new((&key(recovery)).into())
        .decrypt(XNonce::from_slice(&bytes[..24]), &bytes[24..])
        .map_err(|_| "wrong recovery phrase or damaged vault")?;
    String::from_utf8(plain).map_err(|_| "vault record is not UTF-8".into())
}

fn read() -> Result<VaultStore, String> {
    match fs::read(path()) {
        Ok(v) => serde_json::from_slice(&v).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(VaultStore::default()),
        Err(e) => Err(e.to_string()),
    }
}
fn write(store: &VaultStore) -> Result<(), String> {
    let path = path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let temp = path.with_extension("tmp");
    fs::write(
        &temp,
        serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    }
    fs::rename(temp, path).map_err(|e| e.to_string())
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("ssh.vault.") {
        return None;
    }
    Some((|| {
        let _guard = lock().lock().map_err(|_| "vault lock poisoned")?;
        match method {
            "ssh.vault.status" => {
                let store = read()?;
                Ok(
                    json!({"created": !store.verifier.is_empty(), "recordCount": store.records.len()}),
                )
            }
            "ssh.vault.create" => {
                let _: Value = serde_json::from_str(params).map_err(|e| e.to_string())?;
                verify_paid_account()?;
                let mut store = read()?;
                if !store.verifier.is_empty() {
                    return Err("vault already exists".into());
                }
                let recovery = generate_recovery();
                store.verifier = verifier(&recovery);
                write(&store)?;
                Ok(json!({"recovery": recovery}))
            }
            "ssh.vault.unlock" => {
                let p: RecoveryParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                verify_paid_account()?;
                let store = read()?;
                if store.verifier != verifier(&p.recovery) {
                    return Err("wrong recovery phrase".into());
                }
                Ok(json!({"unlocked": true}))
            }
            "ssh.vault.record.list" => {
                let p: RecoveryParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                verify_paid_account()?;
                let store = read()?;
                if store.verifier != verifier(&p.recovery) {
                    return Err("wrong recovery phrase".into());
                }
                let records = store.records.iter().map(|r| Ok(json!({"id": r.id, "version": r.version, "plaintext": decrypt(&p.recovery, &r.ciphertext)?}))).collect::<Result<Vec<_>, String>>()?;
                Ok(json!({"records": records}))
            }
            "ssh.vault.record.put" => {
                let p: PutParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                verify_paid_account()?;
                let mut store = read()?;
                if store.verifier != verifier(&p.recovery) {
                    return Err("wrong recovery phrase".into());
                }
                let ciphertext = encrypt(&p.recovery, &p.plaintext)?;
                let version = store
                    .records
                    .iter()
                    .find(|r| r.id == p.id)
                    .map_or(1, |r| r.version + 1);
                store.records.retain(|r| r.id != p.id);
                store.records.push(VaultRecord {
                    id: p.id.clone(),
                    version,
                    ciphertext,
                });
                write(&store)?;
                Ok(json!({"id": p.id, "version": version}))
            }
            _ => Err(format!("unknown SSH vault method: {method}")),
        }
    })())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_has_24_words_and_ciphertext_authenticates() {
        let r = generate_recovery();
        assert_eq!(r.split_whitespace().count(), 24);
        let c = encrypt(&r, "secret").unwrap();
        assert!(!c.contains("secret"));
        assert_eq!(decrypt(&r, &c).unwrap(), "secret");
        assert!(decrypt("wrong", &c).is_err());
    }
}
