// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! End-to-end encrypted, cross-device SSH vault.
//!
//! tokenstat.ai receives one authenticated ciphertext snapshot plus opaque key
//! wraps. Recovery material and plaintext are consumed only in this module.

use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use bip39::{Language, Mnemonic};
use chacha20poly1305::aead::{Aead, KeyInit, OsRng, Payload, rand_core::RngCore};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

const SCHEMA: u32 = 2;
const WRAP_VERSION: u32 = 1;

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct VaultStore {
    #[serde(default)]
    schema_version: u32,
    #[serde(default)]
    revision: u64,
    #[serde(default)]
    ciphertext: String,
    #[serde(default)]
    nonce: String,
    #[serde(default)]
    recovery_salt: String,
    #[serde(default)]
    recovery_wrap: String,
    #[serde(default)]
    device_wrap: String,
    // v1 fields are retained only until guided migration succeeds.
    #[serde(default)]
    verifier: String,
    #[serde(default)]
    records: Vec<LegacyRecord>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct LegacyRecord {
    id: String,
    version: u64,
    ciphertext: String,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    records: Vec<PlainRecord>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlainRecord {
    id: String,
    version: u64,
    #[serde(default)]
    deleted: bool,
    #[serde(default)]
    modified_at: u64,
    #[serde(default)]
    device_id: String,
    plaintext: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryParams {
    #[serde(default)]
    recovery: String,
    #[serde(default, rename = "tier")]
    _tier: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PutParams {
    #[serde(default)]
    recovery: String,
    #[serde(default, rename = "tier")]
    _tier: String,
    id: String,
    plaintext: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeleteParams {
    #[serde(default)]
    recovery: String,
    id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnrollmentApprovalParams {
    request_id: String,
    machine_id: String,
    public_identity: String,
}

fn mutation_stamp() -> Result<(u64, String), String> {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX);
    let device = tokenstat_identity::MachineIdentity::load_or_create()
        .map_err(|e| e.to_string())?
        .public_key_hex();
    Ok((millis, device))
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

fn legacy_backup_path() -> PathBuf {
    path().with_extension("legacy-backup.json")
}

fn verify_paid_account() -> Result<(), String> {
    let status = tokenstat_sync::profile::sync_status(None).map_err(|e| e.to_string())?;
    if matches!(
        status.tier.as_deref(),
        Some("supporter" | "patron" | "legend")
    ) {
        Ok(())
    } else {
        Err("SSH vault sync requires Supporter or higher".into())
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(value: &str) -> Result<Vec<u8>, String> {
    if value.len() % 2 != 0 {
        return Err("invalid encrypted vault data".into());
    }
    (0..value.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&value[i..i + 2], 16)
                .map_err(|_| "invalid encrypted vault data".into())
        })
        .collect()
}

fn random32() -> [u8; 32] {
    let mut value = [0u8; 32];
    OsRng.fill_bytes(&mut value);
    value
}

fn generate_recovery() -> String {
    Mnemonic::from_entropy_in(Language::English, &random32())
        .expect("32 bytes is valid BIP-39 entropy")
        .to_string()
}

fn recovery_key(recovery: &str, salt: &str) -> Result<[u8; 32], String> {
    let mnemonic = Mnemonic::parse_in_normalized(Language::English, recovery.trim())
        .map_err(|_| "recovery phrase must be 24 valid BIP-39 words")?;
    if mnemonic.word_count() != 24 {
        return Err("recovery phrase must contain 24 words".into());
    }
    let salt = unhex(salt)?;
    let hk = Hkdf::<Sha256>::new(Some(&salt), mnemonic.to_entropy().as_slice());
    let mut out = [0u8; 32];
    hk.expand(b"tokenstat/ssh-vault/recovery-wrap/v2", &mut out)
        .map_err(|_| "recovery key derivation failed")?;
    Ok(out)
}

fn seal(key: &[u8; 32], plaintext: &[u8], context: &[u8]) -> Result<(String, String), String> {
    let mut nonce = [0u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let sealed = XChaCha20Poly1305::new(key.into())
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: context,
            },
        )
        .map_err(|_| "vault encryption failed")?;
    Ok((hex(&nonce), hex(&sealed)))
}

fn open(key: &[u8; 32], nonce: &str, ciphertext: &str, context: &[u8]) -> Result<Vec<u8>, String> {
    let nonce = unhex(nonce)?;
    let ciphertext = unhex(ciphertext)?;
    if nonce.len() != 24 {
        return Err("invalid vault nonce".into());
    }
    XChaCha20Poly1305::new(key.into())
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: context,
            },
        )
        .map_err(|_| "wrong recovery phrase or damaged vault".into())
}

fn pack(nonce: &str, ciphertext: &str) -> String {
    format!("{nonce}{ciphertext}")
}

fn unpack(value: &str) -> Result<(&str, &str), String> {
    if value.len() < 48 {
        return Err("invalid key wrap".into());
    }
    Ok(value.split_at(48))
}

fn wrap_recovery(vmk: &[u8; 32], recovery: &str, salt: &str) -> Result<String, String> {
    let key = recovery_key(recovery, salt)?;
    let (nonce, ciphertext) = seal(&key, vmk, b"tokenstat/ssh-vault/vmk/recovery/v2")?;
    Ok(pack(&nonce, &ciphertext))
}

fn unwrap_recovery(wrap: &str, recovery: &str, salt: &str) -> Result<[u8; 32], String> {
    let (nonce, ciphertext) = unpack(wrap)?;
    let plain = open(
        &recovery_key(recovery, salt)?,
        nonce,
        ciphertext,
        b"tokenstat/ssh-vault/vmk/recovery/v2",
    )?;
    plain
        .try_into()
        .map_err(|_| "invalid wrapped vault key".into())
}

fn wrap_for_device(vmk: &[u8; 32], target: &[u8; 32]) -> Result<String, String> {
    let ephemeral = StaticSecret::from(random32());
    let ephemeral_public = PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(&PublicKey::from(*target));
    let hk = Hkdf::<Sha256>::new(Some(target), shared.as_bytes());
    let mut key = [0u8; 32];
    hk.expand(b"tokenstat/ssh-vault/device-wrap/v1", &mut key)
        .map_err(|_| "device key derivation failed")?;
    let (nonce, ciphertext) = seal(&key, vmk, target)?;
    Ok(format!(
        "{}{}{}",
        hex(ephemeral_public.as_bytes()),
        nonce,
        ciphertext
    ))
}

fn unwrap_for_self(wrap: &str) -> Result<[u8; 32], String> {
    let identity =
        tokenstat_identity::MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    unwrap_for_identity(wrap, &identity)
}

fn unwrap_for_identity(
    wrap: &str,
    identity: &tokenstat_identity::MachineIdentity,
) -> Result<[u8; 32], String> {
    if wrap.len() < 64 + 48 {
        return Err("invalid device key wrap".into());
    }
    let ephemeral: [u8; 32] = unhex(&wrap[..64])?
        .try_into()
        .map_err(|_| "invalid device key wrap")?;
    let target = identity.public_key();
    let secret = StaticSecret::from(identity.secret_bytes());
    let shared = secret.diffie_hellman(&PublicKey::from(ephemeral));
    let hk = Hkdf::<Sha256>::new(Some(&target), shared.as_bytes());
    let mut key = [0u8; 32];
    hk.expand(b"tokenstat/ssh-vault/device-wrap/v1", &mut key)
        .map_err(|_| "device key derivation failed")?;
    let (nonce, ciphertext) = unpack(&wrap[64..])?;
    open(&key, nonce, ciphertext, &target)?
        .try_into()
        .map_err(|_| "invalid wrapped vault key".into())
}

fn snapshot_context(revision: u64) -> Vec<u8> {
    format!("tokenstat/ssh-vault/snapshot/v2/{revision}").into_bytes()
}

fn encrypt_snapshot(
    vmk: &[u8; 32],
    revision: u64,
    value: &Snapshot,
) -> Result<(String, String), String> {
    let plain = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    seal(vmk, &plain, &snapshot_context(revision))
}

fn decrypt_snapshot(
    vmk: &[u8; 32],
    revision: u64,
    nonce: &str,
    ciphertext: &str,
) -> Result<Snapshot, String> {
    serde_json::from_slice(&open(vmk, nonce, ciphertext, &snapshot_context(revision))?)
        .map_err(|e| format!("damaged vault snapshot: {e}"))
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

fn cache_remote(remote: &tokenstat_sync::vault::RemoteVault) -> Result<(), String> {
    let mut store = read()?;
    store.schema_version = remote.schema_version;
    store.revision = remote.revision;
    store.ciphertext.clone_from(&remote.ciphertext);
    store.nonce.clone_from(&remote.nonce);
    store.recovery_salt.clone_from(&remote.recovery_salt);
    store.recovery_wrap.clone_from(&remote.recovery_wrap);
    store.device_wrap = remote.device_wrap.clone().unwrap_or_default();
    write(&store)
}

fn remote_and_key(
    recovery: &str,
) -> Result<(tokenstat_sync::vault::RemoteVault, [u8; 32]), String> {
    let mut remote = tokenstat_sync::vault::get().map_err(|e| e.to_string())?;
    let key = if recovery.trim().is_empty() {
        unwrap_for_self(
            remote
                .device_wrap
                .as_deref()
                .ok_or("this device is not enrolled")?,
        )?
    } else {
        let key = unwrap_recovery(&remote.recovery_wrap, recovery, &remote.recovery_salt)?;
        if remote.device_wrap.is_none() {
            enroll_self(&key)?;
            remote = tokenstat_sync::vault::get().map_err(|e| e.to_string())?;
        }
        key
    };
    cache_remote(&remote)?;
    Ok((remote, key))
}

fn enroll_self(vmk: &[u8; 32]) -> Result<(), String> {
    let identity =
        tokenstat_identity::MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let nonce = hex(&random32());
    let request = tokenstat_sync::vault::request_enrollment(&nonce).map_err(|e| e.to_string())?;
    if request.nonce != nonce || request.public_identity != identity.public_key_hex() {
        return Err("enrollment response does not match this device identity".into());
    }
    let wrap = wrap_for_device(vmk, &identity.public_key())?;
    let result = tokenstat_sync::vault::approve_enrollment(
        &request.machine_id,
        &request.id,
        &wrap,
        WRAP_VERSION,
    )
    .map_err(|e| e.to_string())?;
    if !result.enrolled {
        return Err("server did not enroll this device".into());
    }
    Ok(())
}

fn create_v2(records: Vec<PlainRecord>) -> Result<String, String> {
    verify_paid_account()?;
    let recovery = generate_recovery();
    let vmk = random32();
    let recovery_salt = hex(&random32());
    let recovery_wrap = wrap_recovery(&vmk, &recovery, &recovery_salt)?;
    let identity =
        tokenstat_identity::MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let device_wrap = wrap_for_device(&vmk, &identity.public_key())?;
    let (nonce, ciphertext) = encrypt_snapshot(&vmk, 1, &Snapshot { records })?;
    let revision = tokenstat_sync::vault::create(&tokenstat_sync::vault::CreateVault {
        schema_version: SCHEMA,
        ciphertext: &ciphertext,
        nonce: &nonce,
        recovery_salt: &recovery_salt,
        recovery_wrap: &recovery_wrap,
        device_wrap: &device_wrap,
        wrap_version: WRAP_VERSION,
    })
    .map_err(|e| e.to_string())?;
    write(&VaultStore {
        schema_version: SCHEMA,
        revision: revision.revision,
        ciphertext,
        nonce,
        recovery_salt,
        recovery_wrap,
        device_wrap,
        verifier: String::new(),
        records: Vec::new(),
    })?;
    Ok(recovery)
}

fn legacy_key(recovery: &str) -> [u8; 32] {
    Sha256::digest(recovery.trim().as_bytes()).into()
}

fn legacy_verifier(recovery: &str) -> String {
    let mut h = Sha256::new();
    h.update(b"tokenstat ssh vault verifier\0");
    h.update(legacy_key(recovery));
    hex(&h.finalize())
}

fn decrypt_legacy(recovery: &str, ciphertext: &str) -> Result<String, String> {
    let bytes = unhex(ciphertext)?;
    if bytes.len() < 40 {
        return Err("invalid legacy ciphertext".into());
    }
    let plain = XChaCha20Poly1305::new((&legacy_key(recovery)).into())
        .decrypt(XNonce::from_slice(&bytes[..24]), &bytes[24..])
        .map_err(|_| "wrong recovery phrase or damaged legacy vault")?;
    String::from_utf8(plain).map_err(|_| "legacy vault record is not UTF-8".into())
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("ssh.vault.") {
        return None;
    }
    Some((|| {
        let _guard = lock().lock().map_err(|_| "vault lock poisoned")?;
        match method {
            "ssh.vault.status" => {
                let local = read()?;
                let remote = tokenstat_sync::vault::get().ok();
                let created = remote.is_some() || local.schema_version == SCHEMA;
                let enrolled = remote
                    .as_ref()
                    .and_then(|value| value.device_wrap.as_ref())
                    .is_some();
                let record_count = if let Some(remote) = remote {
                    if let Some(wrap) = remote.device_wrap.as_deref() {
                        unwrap_for_self(wrap)
                            .and_then(|key| {
                                decrypt_snapshot(
                                    &key,
                                    remote.revision,
                                    &remote.nonce,
                                    &remote.ciphertext,
                                )
                            })
                            .map_or(0, |s| {
                                s.records.iter().filter(|record| !record.deleted).count()
                            })
                    } else {
                        0
                    }
                } else {
                    0
                };
                Ok(
                    json!({"created": created, "recordCount": record_count, "legacy": !local.verifier.is_empty(), "enrolled": enrolled}),
                )
            }
            "ssh.vault.create" => {
                let _: Value = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let store = read()?;
                if !store.verifier.is_empty() {
                    return Err("A legacy vault is present. Choose Migrate instead of creating a second vault.".into());
                }
                Ok(json!({"recovery": create_v2(Vec::new())?}))
            }
            "ssh.vault.migrate" => {
                let p: RecoveryParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let store = read()?;
                if store.verifier.is_empty() {
                    return Err("no legacy vault to migrate".into());
                }
                if store.verifier != legacy_verifier(&p.recovery) {
                    return Err("wrong legacy recovery phrase".into());
                }
                let records = store
                    .records
                    .iter()
                    .map(|r| {
                        Ok(PlainRecord {
                            id: r.id.clone(),
                            version: r.version,
                            deleted: false,
                            modified_at: 0,
                            device_id: "legacy".into(),
                            plaintext: decrypt_legacy(&p.recovery, &r.ciphertext)?,
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                fs::copy(path(), legacy_backup_path())
                    .map_err(|e| format!("back up legacy vault before migration: {e}"))?;
                let recovery = create_v2(records)?;
                // `create_v2` atomically switched the active local cache only
                // after the server accepted the encrypted snapshot.
                Ok(json!({"recovery": recovery, "migrated": true}))
            }
            "ssh.vault.unlock" => {
                let p: RecoveryParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let (remote, vmk) = remote_and_key(&p.recovery)?;
                let _ = decrypt_snapshot(&vmk, remote.revision, &remote.nonce, &remote.ciphertext)?;
                Ok(json!({"unlocked": true}))
            }
            "ssh.vault.enrollment.request" => {
                let nonce = hex(&random32());
                let request =
                    tokenstat_sync::vault::request_enrollment(&nonce).map_err(|e| e.to_string())?;
                Ok(
                    json!({"id": request.id, "machineId": request.machine_id, "publicIdentity": request.public_identity, "nonce": request.nonce, "expiresAt": request.expires_at}),
                )
            }
            "ssh.vault.enrollment.list" => {
                let requests =
                    tokenstat_sync::vault::list_enrollments().map_err(|e| e.to_string())?;
                Ok(
                    json!({"requests": requests.into_iter().map(|r| json!({"id": r.id, "machineId": r.machine_id, "publicIdentity": r.public_identity, "nonce": r.nonce, "expiresAt": r.expires_at})).collect::<Vec<_>>() }),
                )
            }
            "ssh.vault.enrollment.approve" => {
                let p: EnrollmentApprovalParams =
                    serde_json::from_str(params).map_err(|e| e.to_string())?;
                let request = tokenstat_sync::vault::list_enrollments()
                    .map_err(|e| e.to_string())?
                    .into_iter()
                    .find(|r| r.id == p.request_id && r.machine_id == p.machine_id)
                    .ok_or("enrollment request is missing or expired")?;
                if request.public_identity != p.public_identity {
                    return Err("enrollment identity changed before approval".into());
                }
                let target: [u8; 32] = unhex(&request.public_identity)?
                    .try_into()
                    .map_err(|_| "invalid enrollment public identity")?;
                let remote = tokenstat_sync::vault::get().map_err(|e| e.to_string())?;
                let vmk = unwrap_for_self(
                    remote
                        .device_wrap
                        .as_deref()
                        .ok_or("this device is not enrolled")?,
                )?;
                let wrap = wrap_for_device(&vmk, &target)?;
                let result = tokenstat_sync::vault::approve_enrollment(
                    &request.machine_id,
                    &request.id,
                    &wrap,
                    WRAP_VERSION,
                )
                .map_err(|e| e.to_string())?;
                Ok(json!({"enrolled": result.enrolled, "machineId": request.machine_id}))
            }
            "ssh.vault.record.list" => {
                let p: RecoveryParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let (remote, vmk) = remote_and_key(&p.recovery)?;
                let snapshot =
                    decrypt_snapshot(&vmk, remote.revision, &remote.nonce, &remote.ciphertext)?;
                // Tombstones must cross the bridge too. Filtering them here
                // made deletes permanent on the writer but impossible to
                // apply on another enrolled device.
                Ok(json!({"records": snapshot.records}))
            }
            "ssh.vault.record.put" => {
                let p: PutParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let mut last_conflict = None;
                for _ in 0..4 {
                    let (remote, vmk) = remote_and_key(&p.recovery)?;
                    let mut snapshot =
                        decrypt_snapshot(&vmk, remote.revision, &remote.nonce, &remote.ciphertext)?;
                    let version = snapshot
                        .records
                        .iter()
                        .find(|r| r.id == p.id)
                        .map_or(1, |r| r.version + 1);
                    snapshot.records.retain(|r| r.id != p.id);
                    let (modified_at, device_id) = mutation_stamp()?;
                    snapshot.records.push(PlainRecord {
                        id: p.id.clone(),
                        version,
                        deleted: false,
                        modified_at,
                        device_id,
                        plaintext: p.plaintext.clone(),
                    });
                    snapshot.records.sort_by(|a, b| a.id.cmp(&b.id));
                    let next_revision = remote.revision + 1;
                    let (nonce, ciphertext) = encrypt_snapshot(&vmk, next_revision, &snapshot)?;
                    match tokenstat_sync::vault::update(&tokenstat_sync::vault::UpdateVault {
                        expected_revision: remote.revision,
                        schema_version: SCHEMA,
                        ciphertext: &ciphertext,
                        nonce: &nonce,
                        recovery_salt: None,
                        recovery_wrap: None,
                    }) {
                        Ok(_) => return Ok(json!({"id": p.id, "version": version})),
                        Err(tokenstat_sync::vault::VaultError::Conflict(revision)) => {
                            last_conflict = Some(revision)
                        }
                        Err(e) => return Err(e.to_string()),
                    }
                }
                Err(format!(
                    "vault remained busy after conflict at revision {}",
                    last_conflict.unwrap_or(0)
                ))
            }
            "ssh.vault.record.delete" => {
                let p: DeleteParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let mut last_conflict = None;
                for _ in 0..4 {
                    let (remote, vmk) = remote_and_key(&p.recovery)?;
                    let mut snapshot =
                        decrypt_snapshot(&vmk, remote.revision, &remote.nonce, &remote.ciphertext)?;
                    let version = snapshot
                        .records
                        .iter()
                        .find(|r| r.id == p.id)
                        .map_or(1, |r| r.version + 1);
                    snapshot.records.retain(|r| r.id != p.id);
                    let (modified_at, device_id) = mutation_stamp()?;
                    snapshot.records.push(PlainRecord {
                        id: p.id.clone(),
                        version,
                        deleted: true,
                        modified_at,
                        device_id,
                        plaintext: String::new(),
                    });
                    snapshot.records.sort_by(|a, b| a.id.cmp(&b.id));
                    let next_revision = remote.revision + 1;
                    let (nonce, ciphertext) = encrypt_snapshot(&vmk, next_revision, &snapshot)?;
                    match tokenstat_sync::vault::update(&tokenstat_sync::vault::UpdateVault {
                        expected_revision: remote.revision,
                        schema_version: SCHEMA,
                        ciphertext: &ciphertext,
                        nonce: &nonce,
                        recovery_salt: None,
                        recovery_wrap: None,
                    }) {
                        Ok(_) => {
                            return Ok(json!({"id": p.id, "version": version, "deleted": true}));
                        }
                        Err(tokenstat_sync::vault::VaultError::Conflict(revision)) => {
                            last_conflict = Some(revision)
                        }
                        Err(e) => return Err(e.to_string()),
                    }
                }
                Err(format!(
                    "vault remained busy after conflict at revision {}",
                    last_conflict.unwrap_or(0)
                ))
            }
            "ssh.vault.recovery.rotate" => {
                verify_paid_account()?;
                let mut last_conflict = None;
                for _ in 0..4 {
                    let (remote, vmk) = remote_and_key("")?;
                    let snapshot =
                        decrypt_snapshot(&vmk, remote.revision, &remote.nonce, &remote.ciphertext)?;
                    let recovery = generate_recovery();
                    let recovery_salt = hex(&random32());
                    let recovery_wrap = wrap_recovery(&vmk, &recovery, &recovery_salt)?;
                    let next_revision = remote.revision + 1;
                    let (nonce, ciphertext) = encrypt_snapshot(&vmk, next_revision, &snapshot)?;
                    match tokenstat_sync::vault::update(&tokenstat_sync::vault::UpdateVault {
                        expected_revision: remote.revision,
                        schema_version: SCHEMA,
                        ciphertext: &ciphertext,
                        nonce: &nonce,
                        recovery_salt: Some(&recovery_salt),
                        recovery_wrap: Some(&recovery_wrap),
                    }) {
                        Ok(_) => return Ok(json!({"recovery": recovery})),
                        Err(tokenstat_sync::vault::VaultError::Conflict(revision)) => {
                            last_conflict = Some(revision)
                        }
                        Err(e) => return Err(e.to_string()),
                    }
                }
                Err(format!(
                    "vault remained busy after conflict at revision {}",
                    last_conflict.unwrap_or(0)
                ))
            }
            _ => Err(format!("unknown SSH vault method: {method}")),
        }
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_is_bip39_and_wrap_round_trips() {
        let recovery = generate_recovery();
        assert_eq!(recovery.split_whitespace().count(), 24);
        assert!(Mnemonic::parse_in_normalized(Language::English, &recovery).is_ok());
        let vmk = random32();
        let salt = hex(&random32());
        let wrap = wrap_recovery(&vmk, &recovery, &salt).unwrap();
        assert_eq!(unwrap_recovery(&wrap, &recovery, &salt).unwrap(), vmk);
        assert!(unwrap_recovery(&wrap, &generate_recovery(), &salt).is_err());
    }

    #[test]
    fn device_wrap_and_snapshot_are_authenticated() {
        let identity = tokenstat_identity::MachineIdentity::from_secret([9; 32]);
        let vmk = [7; 32];
        let wrap = wrap_for_device(&vmk, &identity.public_key()).unwrap();
        assert!(!wrap.contains(&hex(&vmk)));
        assert_eq!(unwrap_for_identity(&wrap, &identity).unwrap(), vmk);
        let snapshot = Snapshot {
            records: vec![PlainRecord {
                id: "host".into(),
                version: 1,
                deleted: false,
                modified_at: 1,
                device_id: "device".into(),
                plaintext: "secret".into(),
            }],
        };
        let (nonce, ciphertext) = encrypt_snapshot(&vmk, 3, &snapshot).unwrap();
        assert!(!ciphertext.contains("secret"));
        assert_eq!(
            decrypt_snapshot(&vmk, 3, &nonce, &ciphertext)
                .unwrap()
                .records
                .len(),
            1
        );
        assert!(decrypt_snapshot(&vmk, 4, &nonce, &ciphertext).is_err());
    }

    #[test]
    fn encrypted_snapshot_preserves_tombstones() {
        let vmk = [3; 32];
        let snapshot = Snapshot {
            records: vec![PlainRecord {
                id: "host:removed".into(),
                version: 4,
                deleted: true,
                modified_at: 99,
                device_id: "device-a".into(),
                plaintext: String::new(),
            }],
        };
        let (nonce, ciphertext) = encrypt_snapshot(&vmk, 8, &snapshot).unwrap();
        let decoded = decrypt_snapshot(&vmk, 8, &nonce, &ciphertext).unwrap();
        assert_eq!(decoded.records.len(), 1);
        assert!(decoded.records[0].deleted);
        assert_eq!(decoded.records[0].id, "host:removed");
        // The list bridge must serialize tombstones too. Filtering here used
        // to make a delete on one device impossible to apply on another.
        let listed = json!({"records": decoded.records});
        assert_eq!(listed["records"][0]["deleted"], true);
        assert_eq!(listed["records"].as_array().map(|rows| rows.len()), Some(1));
    }
}
