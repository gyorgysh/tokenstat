// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! End-to-end encrypted, cross-device SSH vault.
//!
//! tokenstat.ai receives one authenticated ciphertext snapshot plus opaque key
//! wraps. Recovery material and plaintext are consumed only in this module.

use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::{Aead, KeyInit, OsRng, Payload, rand_core::RngCore};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

const SCHEMA: u32 = 3;
const WRAP_VERSION: u32 = 1;

/// Argon2id cost. 64 MiB, three passes, one lane.
///
/// The ciphertext is on a server, so somebody who takes a copy can guess
/// offline for as long as they like. This is what makes each guess cost
/// something. The numbers are the RustCrypto defaults, which are the OWASP
/// recommendation, and they take well under a second on a phone.
const KDF_MEMORY_KIB: u32 = 64 * 1024;
const KDF_PASSES: u32 = 3;
const KDF_LANES: u32 = 1;

/// The KDF written down beside the wrap it produced.
///
/// Stored with the vault so a future change of cost can be read rather than
/// guessed. A device that meets a descriptor it does not understand refuses
/// rather than deriving the wrong key and reporting a bad password.
fn kdf_descriptor() -> String {
    format!("argon2id$v=19$m={KDF_MEMORY_KIB},t={KDF_PASSES},p={KDF_LANES}")
}

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
    #[serde(default)]
    password_salt: String,
    #[serde(default)]
    password_wrap: String,
    #[serde(default)]
    kdf: String,
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PasswordParams {
    #[serde(default)]
    password: String,
    /// Only set when resetting a forgotten password.
    #[serde(default)]
    recovery: String,
    /// The replacement, when changing or resetting.
    #[serde(default)]
    new_password: String,
}

/// The vault key for this run of the daemon.
///
/// Held after a successful unlock so the password is typed once and not on
/// every record read. In memory only: it is never written anywhere, and it
/// goes when the process does.
fn unlocked() -> &'static Mutex<Option<[u8; 32]>> {
    static UNLOCKED: OnceLock<Mutex<Option<[u8; 32]>>> = OnceLock::new();
    UNLOCKED.get_or_init(|| Mutex::new(None))
}

fn remember_key(vmk: [u8; 32]) {
    if let Ok(mut held) = unlocked().lock() {
        *held = Some(vmk);
    }
}

fn forget_key() {
    if let Ok(mut held) = unlocked().lock() {
        *held = None;
    }
}

fn cached_key() -> Option<[u8; 32]> {
    unlocked().lock().ok().and_then(|held| *held)
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

fn remove_if_present(path: &std::path::Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

fn clear_local() -> Result<(), String> {
    let _guard = lock().lock().map_err(|_| "vault lock poisoned")?;
    let path = path();
    remove_if_present(&path)?;
    remove_if_present(&path.with_extension("tmp"))?;
    remove_if_present(&path.with_extension("legacy-backup.json"))?;
    Ok(())
}

fn paid_vault_tier(tier: Option<&str>) -> bool {
    matches!(
        tier.map(|s| s.to_ascii_lowercase()).as_deref(),
        Some("supporter" | "patron" | "legend")
    )
}

fn verify_paid_account() -> Result<(), String> {
    let status = tokenstat_sync::profile::sync_status(None).map_err(|e| e.to_string())?;
    if paid_vault_tier(status.tier.as_deref()) {
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

/// Crockford base32, which has no I, L, O or U.
///
/// A recovery code is read off a screen and typed back, sometimes from a
/// photograph, so the alphabet must not contain two characters that look the
/// same. Twenty-four words did not have this problem and had a much worse one:
/// nobody could face typing them.
const CODE_ALPHABET: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// A fresh recovery code: 160 bits, in groups of four.
///
/// Not a password and never typed to get in day to day, so it can be as long
/// as it needs to be. It is the way back when the password is forgotten, and
/// the only thing standing between a forgotten password and a lost vault.
fn generate_recovery() -> String {
    let bytes = random32();
    let mut out = String::new();
    for (index, chunk) in bytes[..20].iter().enumerate() {
        if index > 0 && index % 2 == 0 {
            out.push('-');
        }
        out.push(CODE_ALPHABET[(chunk >> 3) as usize] as char);
        out.push(CODE_ALPHABET[(chunk & 0b0001_1111) as usize] as char);
    }
    out
}

/// Compare recovery codes by what was meant, not by how it was typed.
///
/// Case and the grouping dashes carry no information, and neither does the
/// difference between O and 0 on a code read off a photograph.
fn normalize_recovery(recovery: &str) -> String {
    recovery
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| match c.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .collect()
}

fn recovery_key(recovery: &str, salt: &str) -> Result<[u8; 32], String> {
    let code = normalize_recovery(recovery);
    if code.len() < 16 {
        return Err("that is not a recovery code".into());
    }
    let salt = unhex(salt)?;
    let hk = Hkdf::<Sha256>::new(Some(&salt), code.as_bytes());
    let mut out = [0u8; 32];
    hk.expand(b"tokenstat/ssh-vault/recovery-wrap/v3", &mut out)
        .map_err(|_| "recovery key derivation failed")?;
    Ok(out)
}

/// Derive the key-encryption key from what a person typed.
///
/// Argon2id, and slow on purpose. `descriptor` is the KDF the wrap was made
/// with: a device that does not recognise it refuses rather than deriving some
/// other key and reporting a wrong password.
fn password_key(password: &str, salt: &str, descriptor: &str) -> Result<[u8; 32], String> {
    if descriptor != kdf_descriptor() {
        return Err(
            "this vault was locked by a newer version of tokenstat. Update to open it.".into(),
        );
    }
    let salt = unhex(salt)?;
    let params = Params::new(KDF_MEMORY_KIB, KDF_PASSES, KDF_LANES, Some(32))
        .map_err(|_| "vault key derivation is misconfigured")?;
    let mut out = [0u8; 32];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(password.as_bytes(), &salt, &mut out)
        .map_err(|_| "vault key derivation failed")?;
    Ok(out)
}

fn wrap_password(vmk: &[u8; 32], password: &str, salt: &str) -> Result<String, String> {
    let key = password_key(password, salt, &kdf_descriptor())?;
    let (nonce, ciphertext) = seal(&key, vmk, b"tokenstat/ssh-vault/vmk/password/v3")?;
    Ok(pack(&nonce, &ciphertext))
}

fn unwrap_password(
    wrap: &str,
    password: &str,
    salt: &str,
    descriptor: &str,
) -> Result<[u8; 32], String> {
    let (nonce, ciphertext) = unpack(wrap)?;
    let plain = open(
        &password_key(password, salt, descriptor)?,
        nonce,
        ciphertext,
        b"tokenstat/ssh-vault/vmk/password/v3",
    )
    .map_err(|_| "wrong password".to_string())?;
    plain
        .try_into()
        .map_err(|_| "invalid wrapped vault key".into())
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
        .map_err(|_| "wrong password or recovery code, or a damaged vault".into())
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
    let (nonce, ciphertext) = seal(&key, vmk, b"tokenstat/ssh-vault/vmk/recovery/v3")?;
    Ok(pack(&nonce, &ciphertext))
}

fn unwrap_recovery(wrap: &str, recovery: &str, salt: &str) -> Result<[u8; 32], String> {
    let (nonce, ciphertext) = unpack(wrap)?;
    let plain = open(
        &recovery_key(recovery, salt)?,
        nonce,
        ciphertext,
        b"tokenstat/ssh-vault/vmk/recovery/v3",
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
    let _guard = lock().lock().map_err(|_| "vault lock poisoned")?;
    match fs::read(path()) {
        Ok(v) => serde_json::from_slice(&v).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(VaultStore::default()),
        Err(e) => Err(e.to_string()),
    }
}

fn write(store: &VaultStore) -> Result<(), String> {
    let _guard = lock().lock().map_err(|_| "vault lock poisoned")?;
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

/// The remote snapshot and the key that opens it.
///
/// Three ways to the key, cheapest first: the one already unlocked this run,
/// this device's own wrap, or a recovery code the caller supplied. There is no
/// fourth: a device with none of those has to be unlocked with the password,
/// which is a thing a person does and not something a record read can do.
fn remote_and_key(
    recovery: &str,
) -> Result<(tokenstat_sync::vault::RemoteVault, [u8; 32]), String> {
    let mut remote = tokenstat_sync::vault::get().map_err(|e| e.to_string())?;
    let key = if !recovery.trim().is_empty() {
        let key = unwrap_recovery(&remote.recovery_wrap, recovery, &remote.recovery_salt)?;
        if remote.device_wrap.is_none() {
            enroll_self(&key)?;
            remote = tokenstat_sync::vault::get().map_err(|e| e.to_string())?;
        }
        key
    } else if let Some(key) = cached_key() {
        key
    } else if let Some(wrap) = remote.device_wrap.as_deref() {
        let key = unwrap_for_self(wrap)?;
        remember_key(key);
        key
    } else {
        return Err("the vault is locked. Enter your vault password to open it.".into());
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

fn create_error(e: tokenstat_sync::vault::VaultError) -> String {
    match e {
        tokenstat_sync::vault::VaultError::AlreadyExists => {
            "A vault already exists. Drop it first if you want to start over.".into()
        }
        other => other.to_string(),
    }
}

/// Create the account's one vault, locked by a password.
///
/// Returns the recovery code, which is shown once. It is not the way in, it is
/// the way back when the password is forgotten.
fn create_v3(password: &str) -> Result<String, String> {
    verify_paid_account()?;
    if let Some(problem) = tokenstat_core::passphrase::password_error(password) {
        return Err(problem);
    }
    let recovery = generate_recovery();
    let vmk = random32();
    let recovery_salt = hex(&random32());
    let recovery_wrap = wrap_recovery(&vmk, &recovery, &recovery_salt)?;
    let password_salt = hex(&random32());
    let password_wrap = wrap_password(&vmk, password, &password_salt)?;
    let identity =
        tokenstat_identity::MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let device_wrap = wrap_for_device(&vmk, &identity.public_key())?;
    let (nonce, ciphertext) = encrypt_snapshot(
        &vmk,
        1,
        &Snapshot {
            records: Vec::new(),
        },
    )?;
    let kdf = kdf_descriptor();
    let revision = tokenstat_sync::vault::create(&tokenstat_sync::vault::CreateVault {
        schema_version: SCHEMA,
        ciphertext: &ciphertext,
        nonce: &nonce,
        recovery_salt: &recovery_salt,
        recovery_wrap: &recovery_wrap,
        device_wrap: &device_wrap,
        wrap_version: WRAP_VERSION,
        password_salt: &password_salt,
        password_wrap: &password_wrap,
        kdf: &kdf,
    })
    .map_err(create_error)?;
    write(&VaultStore {
        schema_version: SCHEMA,
        revision: revision.revision,
        ciphertext,
        nonce,
        recovery_salt,
        recovery_wrap,
        device_wrap,
        password_salt,
        password_wrap,
        kdf,
    })?;
    remember_key(vmk);
    Ok(recovery)
}

/// Open the vault with what the person typed, and remember the key for this
/// run so they are not asked again.
///
/// A device that opens the vault for the first time also takes its own copy of
/// the key, wrapped to its identity, so later launches need nothing typed. That
/// is the whole of what enrolment used to be, and it happens by itself.
fn unlock_with(password: &str, recovery: &str) -> Result<[u8; 32], String> {
    let remote = tokenstat_sync::vault::get().map_err(|e| e.to_string())?;
    let vmk = if !recovery.trim().is_empty() {
        unwrap_recovery(&remote.recovery_wrap, recovery, &remote.recovery_salt)?
    } else if password.is_empty() {
        return Err("enter your vault password".into());
    } else {
        let wrap = remote
            .password_wrap
            .as_deref()
            .ok_or("this vault predates password unlock and has to be recreated")?;
        let salt = remote
            .password_salt
            .as_deref()
            .ok_or("this vault predates password unlock and has to be recreated")?;
        let kdf = remote.kdf.as_deref().unwrap_or_default();
        unwrap_password(wrap, password, salt, kdf)?
    };
    // Prove it before believing it. A wrap that unwraps to the wrong key would
    // otherwise be reported as a working unlock and fail later, on a read.
    decrypt_snapshot(&vmk, remote.revision, &remote.nonce, &remote.ciphertext)?;
    if remote.device_wrap.is_none() {
        enroll_self(&vmk)?;
    }
    cache_remote(&remote)?;
    remember_key(vmk);
    Ok(vmk)
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("ssh.vault.") {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("SSH vault methods")?;
        match method {
            "ssh.vault.status" => {
                let local = read()?;
                let remote = tokenstat_sync::vault::get().ok();
                let created = remote.is_some() || local.schema_version == SCHEMA;
                let enrolled = remote
                    .as_ref()
                    .and_then(|value| value.device_wrap.as_ref())
                    .is_some();
                // A v2 vault has no password wrap. It cannot be opened by this
                // build and the screen has to say so rather than asking for a
                // password nothing will accept.
                let needs_recreate = remote
                    .as_ref()
                    .is_some_and(|value| value.password_wrap.is_none());
                let locked =
                    !needs_recreate && remote.is_some() && cached_key().is_none() && !enrolled;
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
                Ok(json!({
                    "created": created,
                    "recordCount": record_count,
                    "enrolled": enrolled,
                    "locked": locked,
                    "needsRecreate": needs_recreate
                }))
            }
            "ssh.vault.create" => {
                let p: PasswordParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                Ok(json!({"recovery": create_v3(&p.password)?}))
            }
            "ssh.vault.reset" => {
                tokenstat_sync::vault::remove().map_err(|e| e.to_string())?;
                clear_local()?;
                forget_key();
                Ok(json!({"reset": true}))
            }
            "ssh.vault.unlock" => {
                let p: PasswordParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                unlock_with(&p.password, &p.recovery)?;
                Ok(json!({"unlocked": true}))
            }
            "ssh.vault.lock" => {
                forget_key();
                Ok(json!({"locked": true}))
            }
            // Change the password, or set a new one after a recovery-code
            // reset. Either way the records are untouched: only the wrap around
            // the key changes, so this is not a new revision of the snapshot
            // and cannot collide with a device writing a record.
            "ssh.vault.password.set" => {
                verify_paid_account()?;
                let p: PasswordParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                if let Some(problem) = tokenstat_core::passphrase::password_error(&p.new_password) {
                    return Err(problem);
                }
                // Proving you can already open it is the authorisation. Either
                // the current password or the recovery code will do.
                let vmk = unlock_with(&p.password, &p.recovery)?;
                let password_salt = hex(&random32());
                let password_wrap = wrap_password(&vmk, &p.new_password, &password_salt)?;
                // A reset also retires the recovery code that was just spent,
                // so a code read off an old screenshot cannot be used twice.
                let (recovery, recovery_salt, recovery_wrap) = if p.recovery.trim().is_empty() {
                    (None, None, None)
                } else {
                    let code = generate_recovery();
                    let salt = hex(&random32());
                    let wrap = wrap_recovery(&vmk, &code, &salt)?;
                    (Some(code), Some(salt), Some(wrap))
                };
                tokenstat_sync::vault::rewrap(&tokenstat_sync::vault::RewrapVault {
                    password_salt: &password_salt,
                    password_wrap: &password_wrap,
                    kdf: &kdf_descriptor(),
                    recovery_salt: recovery_salt.as_deref(),
                    recovery_wrap: recovery_wrap.as_deref(),
                })
                .map_err(|e| e.to_string())?;
                let mut local = read()?;
                local.password_salt = password_salt;
                local.password_wrap = password_wrap;
                local.kdf = kdf_descriptor();
                if let (Some(salt), Some(wrap)) = (&recovery_salt, &recovery_wrap) {
                    local.recovery_salt = salt.clone();
                    local.recovery_wrap = wrap.clone();
                }
                write(&local)?;
                Ok(json!({"changed": true, "recovery": recovery}))
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
    fn paid_vault_tier_is_case_insensitive() {
        assert!(paid_vault_tier(Some("legend")));
        assert!(paid_vault_tier(Some("Legend")));
        assert!(paid_vault_tier(Some("SUPPORTER")));
        assert!(paid_vault_tier(Some("patron")));
        assert!(!paid_vault_tier(Some("free")));
        assert!(!paid_vault_tier(None));
        assert!(!paid_vault_tier(Some("fam")));
    }

    #[test]
    fn a_recovery_code_is_one_copyable_line_and_round_trips() {
        let recovery = generate_recovery();
        // One line, not 24 words. Somebody has to be able to copy this in one
        // go, or photograph it.
        assert!(!recovery.contains(' '), "{recovery}");
        assert_eq!(
            recovery.chars().filter(char::is_ascii_alphanumeric).count(),
            40
        );
        let vmk = random32();
        let salt = hex(&random32());
        let wrap = wrap_recovery(&vmk, &recovery, &salt).unwrap();
        assert_eq!(unwrap_recovery(&wrap, &recovery, &salt).unwrap(), vmk);
        assert!(unwrap_recovery(&wrap, &generate_recovery(), &salt).is_err());
    }

    #[test]
    fn a_recovery_code_survives_how_it_was_typed_back() {
        let vmk = random32();
        let salt = hex(&random32());
        let recovery = generate_recovery();
        let wrap = wrap_recovery(&vmk, &recovery, &salt).unwrap();
        // Read off a photograph: lower case, no grouping dashes, and the
        // letters that look like digits confused for them.
        let retyped = recovery.to_lowercase().replace('-', " ").replace('0', "O");
        assert_eq!(unwrap_recovery(&wrap, &retyped, &salt).unwrap(), vmk);
    }

    #[test]
    fn a_password_wrap_round_trips_and_a_wrong_password_is_refused() {
        let vmk = random32();
        let salt = hex(&random32());
        let wrap = wrap_password(&vmk, "Correct-Horse9!", &salt).unwrap();
        let kdf = kdf_descriptor();
        assert_eq!(
            unwrap_password(&wrap, "Correct-Horse9!", &salt, &kdf).unwrap(),
            vmk
        );
        let wrong = unwrap_password(&wrap, "Correct-Horse9?", &salt, &kdf).unwrap_err();
        assert!(wrong.contains("wrong password"), "{wrong}");
    }

    #[test]
    fn a_wrap_made_by_a_kdf_we_do_not_know_is_refused_rather_than_guessed() {
        let vmk = random32();
        let salt = hex(&random32());
        let wrap = wrap_password(&vmk, "Correct-Horse9!", &salt).unwrap();
        // Deriving with different parameters would produce a different key and
        // report a wrong password, which sends somebody looking for a typo in
        // a password that was right.
        let refused = unwrap_password(&wrap, "Correct-Horse9!", &salt, "argon2id$v=19$m=1,t=1,p=1")
            .unwrap_err();
        assert!(refused.contains("newer version"), "{refused}");
    }

    #[test]
    fn a_vault_cannot_be_created_behind_a_weak_password() {
        // The host checks as well as the client. A client that forgets to
        // must not be able to put a weak password on an account's one vault.
        let refused = create_v3("short").unwrap_err();
        assert!(refused.contains("12 characters"), "{refused}");
    }

    #[test]
    fn a_remote_peer_cannot_open_the_vault() {
        crate::request_context::with_remote_peer("phone", || {
            let refused = call("ssh.vault.record.list", r#"{"recovery":""}"#)
                .unwrap()
                .expect_err("must refuse");
            assert!(refused.contains("local-only"), "{refused}");
            assert!(call("ssh.vault.enrollment.approve", "{}").unwrap().is_err());
            assert!(call("ssh.vault.reset", "{}").unwrap().is_err());
        });
    }

    #[test]
    fn migrate_is_not_a_method() {
        let err = call("ssh.vault.migrate", "{}")
            .unwrap()
            .expect_err("migrate was never shipped");
        assert!(err.contains("unknown"), "{err}");
    }

    #[test]
    fn leftover_v1_json_is_an_empty_store() {
        let store: VaultStore = serde_json::from_str(
            r#"{"verifier":"abc","records":[{"id":"h","version":1,"ciphertext":"00"}]}"#,
        )
        .unwrap();
        assert_eq!(store.schema_version, 0);
        assert!(store.ciphertext.is_empty());
        assert!(store.recovery_wrap.is_empty());
    }

    #[test]
    fn remove_if_present_ignores_missing_and_deletes() {
        let path = std::env::temp_dir().join(format!(
            "tokenstat-vault-clear-{}-{}.json",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        let _ = fs::remove_file(&path);
        remove_if_present(&path).unwrap();
        fs::write(&path, b"{}").unwrap();
        remove_if_present(&path).unwrap();
        assert!(!path.exists());
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
