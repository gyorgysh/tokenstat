// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! End-to-end encrypted, cross-device SSH vault.
//!
//! tokenstat.ai receives one authenticated ciphertext snapshot plus opaque key
//! wraps. Recovery material and plaintext are consumed only in this module.

use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use getrandom::fill as os_fill;
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
#[cfg(test)]
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

const SCHEMA: u32 = 4;
const PASSWORD_ONLY: &str = "password-only-v4";

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
    /// Deliberate lock on this device. Survives a helper restart, because a
    /// flag that lived only in this process was undone the moment the helper
    /// started again and unwrapped the device wrap with nothing typed.
    #[serde(default)]
    locked: bool,
    #[serde(default)]
    key_id: String,
    #[serde(default)]
    lock_generation: u64,
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
struct PasswordParams {
    #[serde(default)]
    password: String,
    /// Only set when resetting a forgotten password.
    #[serde(default)]
    recovery: String,
    /// The replacement, when changing or resetting.
    #[serde(default)]
    new_password: String,
    #[serde(default)]
    migrate: bool,
}

/// The vault key for this run of the daemon.
///
/// Held after a successful unlock so the password is typed once and not on
/// every record read. In memory only: it is never written anywhere, and it
/// goes when the process does.
struct VaultSession {
    key: Option<Zeroizing<[u8; 32]>>,
    locked: bool,
    lock_generation: u64,
}

const LOCKED: &str = "the vault is locked. Enter your vault password to open it.";

fn vault_session() -> &'static Mutex<VaultSession> {
    static SESSION: OnceLock<Mutex<VaultSession>> = OnceLock::new();
    SESSION.get_or_init(|| {
        Mutex::new(VaultSession {
            key: None,
            locked: true,
            lock_generation: 0,
        })
    })
}

/// Disk may lock a process, but can never unlock it. Only a password can.
fn hydrate_locked(session: &mut VaultSession) {
    match read() {
        Ok(store) if !store.locked && store.lock_generation == session.lock_generation => {}
        _ => {
            session.locked = true;
            session.key = None;
        }
    }
}

fn forget_key() {
    if let Ok(mut session) = vault_session().lock() {
        session.key = None;
        session.locked = true;
    }
}

fn cached_key() -> Option<Zeroizing<[u8; 32]>> {
    vault_session().lock().ok().and_then(|mut session| {
        hydrate_locked(&mut session);
        if session.locked {
            None
        } else {
            session.key.as_ref().map(|key| Zeroizing::new(**key))
        }
    })
}

fn unlock_session(vmk: [u8; 32]) -> Result<(), String> {
    let mut session = vault_session()
        .lock()
        .map_err(|_| "vault session lock poisoned")?;
    // Remain locked if writing fails, even when a key was already cached.
    session.key = None;
    session.locked = true;
    let mut store = read()?;
    store.locked = false;
    write(&store)?;
    session.lock_generation = store.lock_generation;
    session.key = Some(Zeroizing::new(vmk));
    session.locked = false;
    Ok(())
}

fn lock_session() -> Result<(), String> {
    forget_key();
    let mut store = read()?;
    store.locked = true;
    store.lock_generation = store
        .lock_generation
        .checked_add(1)
        .ok_or("vault lock generation exhausted")?;
    write(&store)
}

fn is_locked() -> bool {
    cached_key().is_none()
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
            if cfg!(test) {
                return std::env::temp_dir()
                    .join(format!("tokenstat-vault-test-{}.json", std::process::id()));
            }
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
    if !value.is_ascii() {
        return Err("invalid encrypted vault data".into());
    }
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
    os_fill(&mut value).expect("os randomness unavailable");
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
    let key = Zeroizing::new(password_key(password, salt, &kdf_descriptor())?);
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
    os_fill(&mut nonce).expect("os randomness unavailable");
    let sealed = XChaCha20Poly1305::new(key.into())
        .encrypt(
            &XNonce::from(nonce),
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
    let nonce: [u8; 24] = nonce
        .try_into()
        .map_err(|_| "invalid vault nonce".to_string())?;
    XChaCha20Poly1305::new(key.into())
        .decrypt(
            &XNonce::from(nonce),
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
    if !value.is_ascii() || value.len() < 48 {
        return Err("invalid key wrap".into());
    }
    Ok(value.split_at(48))
}

fn wrap_recovery(vmk: &[u8; 32], recovery: &str, salt: &str) -> Result<String, String> {
    let key = Zeroizing::new(recovery_key(recovery, salt)?);
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

#[cfg(test)]
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

#[cfg(test)]
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
    let plain = Zeroizing::new(serde_json::to_vec(value).map_err(|e| e.to_string())?);
    seal(vmk, &plain, &snapshot_context(revision))
}

fn decrypt_snapshot(
    vmk: &[u8; 32],
    revision: u64,
    nonce: &str,
    ciphertext: &str,
) -> Result<Snapshot, String> {
    serde_json::from_slice(&Zeroizing::new(open(
        vmk,
        nonce,
        ciphertext,
        &snapshot_context(revision),
    )?))
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
    use std::io::Write;
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(&temp).map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    }
    fs::rename(temp, &path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    fs::File::open(path.parent().ok_or("invalid vault path")?)
        .and_then(|dir| dir.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn key_id(key: &[u8; 32]) -> String {
    let mut hash = Sha256::new();
    hash.update(b"tokenstat/ssh-vault/root/v4\0");
    hash.update(key);
    hex(&hash.finalize())
}

/// Revisions only advance, including across password-authorized root rotation.
fn validate_remote(
    local: &VaultStore,
    remote: &tokenstat_sync::vault::RemoteVault,
    key: &[u8; 32],
    allow_rotation: bool,
) -> Result<(), String> {
    if remote.schema_version < 3 || remote.schema_version > SCHEMA {
        return Err("this vault needs a compatible version of tokenstat".into());
    }
    if remote.revision < local.revision || remote.schema_version < local.schema_version {
        return Err("the server returned an older vault; refusing to roll back".into());
    }
    if !local.key_id.is_empty() {
        let changed = local.key_id != key_id(key);
        if changed && (!allow_rotation || remote.revision <= local.revision) {
            return Err(
                "the vault encryption key changed; unlock with the current password".into(),
            );
        }
        if remote.revision == local.revision
            && (remote.ciphertext != local.ciphertext || remote.nonce != local.nonce)
        {
            return Err("the server changed an already verified vault revision".into());
        }
    }
    decrypt_snapshot(key, remote.revision, &remote.nonce, &remote.ciphertext)?;
    Ok(())
}

fn cache_remote(
    remote: &tokenstat_sync::vault::RemoteVault,
    key: &[u8; 32],
    allow_rotation: bool,
) -> Result<(), String> {
    let mut store = read()?;
    validate_remote(&store, remote, key, allow_rotation)?;
    store.schema_version = remote.schema_version;
    store.revision = remote.revision;
    store.ciphertext.clone_from(&remote.ciphertext);
    store.nonce.clone_from(&remote.nonce);
    store.recovery_salt.clone_from(&remote.recovery_salt);
    store.recovery_wrap.clone_from(&remote.recovery_wrap);
    // Transport identity material is never a vault unlock credential.
    store.device_wrap.clear();
    store.password_salt = remote.password_salt.clone().unwrap_or_default();
    store.password_wrap = remote.password_wrap.clone().unwrap_or_default();
    store.kdf = remote.kdf.clone().unwrap_or_default();
    store.key_id = key_id(key);
    write(&store)
}

fn remote_and_key(
    recovery: &str,
) -> Result<(tokenstat_sync::vault::RemoteVault, Zeroizing<[u8; 32]>), String> {
    if !recovery.trim().is_empty() {
        return Err("a recovery code resets the password. It cannot unlock on its own.".into());
    }
    let key = cached_key().ok_or(LOCKED)?;
    let remote = remote_vault().map_err(|e| e.to_string())?;
    if let Err(error) = cache_remote(&remote, &key, false) {
        forget_key();
        return Err(error);
    }
    Ok((remote, key))
}

fn enroll_self() -> Result<(), String> {
    let identity =
        tokenstat_identity::MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    let nonce = hex(&random32());
    let request = tokenstat_sync::vault::request_enrollment(&nonce).map_err(|e| e.to_string())?;
    if request.nonce != nonce || request.public_identity != identity.public_key_hex() {
        return Err("enrollment response does not match this device identity".into());
    }
    let result = tokenstat_sync::vault::approve_enrollment(
        &request.machine_id,
        &request.id,
        PASSWORD_ONLY,
        SCHEMA,
    )
    .map_err(|e| e.to_string())?;
    if !result.enrolled {
        return Err("server did not enroll this device".into());
    }
    Ok(())
}

/// Run one vault call, publishing this machine's record if the account says it
/// has never heard of it.
///
/// The record is published once, at login, and best effort: one failed call
/// there (offline, a flaky minute, a sign-in that predates the code) left the
/// machine unknown for good, and every vault call from it answered
/// `machine_required` forever. Nothing retried it, so the vault was simply
/// unusable on that computer and the screen said there was no vault rather
/// than that it could not ask.
///
/// One retry, because if the republish did not fix it the cause is the token
/// rather than the record, and only signing in again replaces that.
fn with_machine_record<T>(
    mut call: impl FnMut() -> Result<T, tokenstat_sync::vault::VaultError>,
) -> Result<T, tokenstat_sync::vault::VaultError> {
    match call() {
        Err(tokenstat_sync::vault::VaultError::MachineNotRegistered(_)) => {
            tokenstat_sync::profile::publish_machine_profile(None)
                .map_err(tokenstat_sync::vault::VaultError::Profile)?;
            call()
        }
        other => other,
    }
}

/// The account's copy of the vault, registering this machine if it has to.
/// Whether a vault exists, from what the account said and what this device has
/// left over from one.
///
/// Its own function because the rule is one line and easy to write backwards.
/// A local record is evidence only while the account could not be asked: once
/// it answers, it is the answer. Writing this as `remote.is_some() || local`
/// meant a vault deleted on another device stayed on screen here forever,
/// because the leftover never expired and nothing else ever contradicted it.
fn vault_exists(remote_found: bool, unreachable: bool, local_schema: u32) -> bool {
    remote_found || (unreachable && local_schema >= 3)
}

fn remote_vault() -> Result<tokenstat_sync::vault::RemoteVault, tokenstat_sync::vault::VaultError> {
    with_machine_record(tokenstat_sync::vault::get)
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
fn create_v4(password: &str) -> Result<String, String> {
    // The password before the plan. It is a pure check on what the caller
    // typed, so answering it first costs nothing and does not make somebody
    // with a short password wait on an account lookup to be told so.
    if let Some(problem) = tokenstat_core::passphrase::password_error(password) {
        return Err(problem);
    }
    if !read()?.key_id.is_empty() {
        return Err(
            "this device remembers an existing vault; remove it explicitly before creating another"
                .into(),
        );
    }
    verify_paid_account()?;
    let recovery = generate_recovery();
    let vmk = Zeroizing::new(random32());
    let recovery_salt = hex(&random32());
    let recovery_wrap = wrap_recovery(&vmk, &recovery, &recovery_salt)?;
    let password_salt = hex(&random32());
    let password_wrap = wrap_password(&vmk, password, &password_salt)?;
    let device_wrap = PASSWORD_ONLY.to_string();
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
        wrap_version: SCHEMA,
        password_salt: &password_salt,
        password_wrap: &password_wrap,
        kdf: &kdf,
    })
    .map_err(create_error)?;
    if revision.revision != 1 {
        return Err("server returned an unexpected initial vault revision".into());
    }
    // The account now has revision 1. If the local writes below fail, a retry
    // would hit `AlreadyExists` with no local cache. Say so directly so the
    // recovery path (reset, then create again) is discoverable.
    write(&VaultStore {
        schema_version: SCHEMA,
        revision: revision.revision,
        ciphertext,
        nonce,
        recovery_salt,
        recovery_wrap,
        device_wrap: String::new(),
        password_salt,
        password_wrap,
        kdf,
        locked: false,
        key_id: key_id(&vmk),
        lock_generation: 0,
    })
    .map_err(|e| {
        format!("vault was created but this device could not remember it: {e}. Reset the vault and create it again")
    })?;
    // An unlock, not just a cached key. A lock left over from the vault this
    // one replaces would otherwise still be standing, and the vault this
    // device created seconds ago would answer that it is locked.
    unlock_session(*vmk).map_err(|e| {
        format!("vault was created but this device could not unlock it: {e}. Unlock it with your password")
    })?;
    Ok(recovery)
}

/// Open the vault with what the person typed, and remember the key for this
/// run so they are not asked again.
///
/// The key lives only in this process. Enrollment grants API access but never
/// stores an identity-encrypted copy of the key locally or on the server.
fn unlock_with(password: &str, recovery: &str) -> Result<Zeroizing<[u8; 32]>, String> {
    let remote = remote_vault().map_err(|e| e.to_string())?;
    let vmk = Zeroizing::new(if !recovery.trim().is_empty() {
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
    });
    // Prove it before believing it. A wrap that unwraps to the wrong key would
    // otherwise be reported as a working unlock and fail later, on a read.
    decrypt_snapshot(&vmk, remote.revision, &remote.nonce, &remote.ciphertext)?;
    if remote.device_wrap.is_none() {
        enroll_self()?;
    }
    cache_remote(&remote, &vmk, true)?;
    unlock_session(*vmk)?;
    Ok(vmk)
}

fn cache_written(
    mut remote: tokenstat_sync::vault::RemoteVault,
    key: &[u8; 32],
    revision: u64,
    nonce: String,
    ciphertext: String,
    accepted: u64,
) -> Result<(), String> {
    if accepted != revision {
        return Err("server returned an unexpected vault revision".into());
    }
    remote.revision = revision;
    remote.nonce = nonce;
    remote.ciphertext = ciphertext;
    cache_remote(&remote, key, false)
}

/// A rotation always replaces the master key, both recovery/password wraps,
/// and every device enrollment together. Never emulate this with two requests.
fn rotate_root(password: &str, recovery: &str, new_password: &str) -> Result<String, String> {
    if let Some(problem) = tokenstat_core::passphrase::password_error(new_password) {
        return Err(problem);
    }
    let old_key = unlock_with(password, recovery)?;
    let remote = remote_vault().map_err(|e| e.to_string())?;
    validate_remote(&read()?, &remote, &old_key, false)?;
    let snapshot = decrypt_snapshot(&old_key, remote.revision, &remote.nonce, &remote.ciphertext)?;
    let key = Zeroizing::new(random32());
    let code = generate_recovery();
    let recovery_salt = hex(&random32());
    let recovery_wrap = wrap_recovery(&key, &code, &recovery_salt)?;
    let password_salt = hex(&random32());
    let password_wrap = wrap_password(&key, new_password, &password_salt)?;
    let revision = remote
        .revision
        .checked_add(1)
        .ok_or("vault revision exhausted")?;
    let (nonce, ciphertext) = encrypt_snapshot(&key, revision, &snapshot)?;
    let descriptor = kdf_descriptor();
    let result = tokenstat_sync::vault::rotate(&tokenstat_sync::vault::RotateVault {
        expected_revision: remote.revision,
        vault: tokenstat_sync::vault::CreateVault {
            schema_version: SCHEMA,
            ciphertext: &ciphertext,
            nonce: &nonce,
            recovery_salt: &recovery_salt,
            recovery_wrap: &recovery_wrap,
            device_wrap: PASSWORD_ONLY,
            wrap_version: SCHEMA,
            password_salt: &password_salt,
            password_wrap: &password_wrap,
            kdf: &descriptor,
        },
    })
    .map_err(|error| format!("vault key rotation failed: {error}"))?;
    if result.revision != revision {
        forget_key();
        return Err("server returned an unexpected vault revision".into());
    }
    let rotated = tokenstat_sync::vault::RemoteVault {
        schema_version: SCHEMA,
        revision,
        ciphertext,
        nonce,
        recovery_salt,
        recovery_wrap,
        password_salt: Some(password_salt),
        password_wrap: Some(password_wrap),
        kdf: Some(descriptor),
        device_wrap: None,
        wrap_version: None,
        updated_at: String::new(),
    };
    forget_key();
    cache_remote(&rotated, &key, true)?;
    unlock_session(*key)?;
    Ok(code)
}

/// Serialize vault operations across the app and helper, including the
/// verification/write of the local rollback floor. File close releases flock.
struct OperationGuard {
    _process: std::sync::MutexGuard<'static, ()>,
    file: fs::File,
}
impl Drop for OperationGuard {
    fn drop(&mut self) {
        #[cfg(windows)]
        crate::win32::unlock(&self.file);
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe {
                libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
            }
        }
    }
}
fn operation_guard() -> Result<OperationGuard, String> {
    static OPERATIONS: Mutex<()> = Mutex::new(());
    let process = OPERATIONS
        .lock()
        .map_err(|_| "vault operation lock poisoned")?;
    let lock_path = path().with_extension("lock");
    fs::create_dir_all(lock_path.parent().ok_or("invalid vault path")?)
        .map_err(|e| e.to_string())?;
    let mut options = fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(lock_path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
    }
    #[cfg(windows)]
    if !crate::win32::try_lock_exclusive(&file, true) {
        return Err("cannot lock vault storage".into());
    }
    Ok(OperationGuard {
        _process: process,
        file,
    })
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("ssh.vault.") {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("SSH vault methods")?;
        let _operation = operation_guard()?;
        match method {
            "ssh.vault.status" => {
                let local = read()?;
                // What the account said, kept rather than discarded. Swallowing
                // this made every failure to *reach* the vault look like the
                // account not having one, so a machine the account did not know
                // was told to create a second vault and then refused when it
                // tried. The screen can only be honest if it is given the
                // difference.
                let answer = remote_vault();
                let mut unreachable = match &answer {
                    Ok(_) => None,
                    // No vault on the account is an answer, not a failure.
                    Err(tokenstat_sync::vault::VaultError::NotFound) => None,
                    Err(error) => Some(error.to_string()),
                };
                let remote = answer.ok();
                // The account answered, and what it said is that there is no
                // vault. That is not the same as not being able to ask, which
                // is what `unreachable` carries, and the difference is the
                // whole of this: a vault is deleted on one device and every
                // other device finds out here.
                //
                // Local state left over from the vault that used to exist is
                // not evidence that one still does. It is the thing to clean
                // up, and until it was, a Mac went on showing "Encrypted
                // vault, 0 records" and offering to change the password of a
                // vault an iPhone had deleted an hour earlier.
                let gone = remote.is_none() && unreachable.is_none();
                if gone && local.schema_version >= 3 {
                    forget_key();
                }
                let created = vault_exists(
                    remote.is_some(),
                    unreachable.is_some(),
                    local.schema_version,
                );
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
                let record_count = if let (Some(remote), Some(key)) =
                    (remote.as_ref(), cached_key())
                {
                    match validate_remote(&local, remote, &key, false).and_then(|_| {
                        decrypt_snapshot(&key, remote.revision, &remote.nonce, &remote.ciphertext)
                    }) {
                        Ok(snapshot) => snapshot.records.iter().filter(|r| !r.deleted).count(),
                        Err(error) => {
                            forget_key();
                            unreachable = Some(error);
                            0
                        }
                    }
                } else {
                    0
                };
                let locked = !needs_recreate && remote.is_some() && is_locked();
                Ok(json!({
                    "created": created,
                    "recordCount": record_count,
                    "enrolled": enrolled,
                    "locked": locked,
                    "needsRecreate": needs_recreate,
                    "unreachable": unreachable
                }))
            }
            "ssh.vault.create" => {
                let p: PasswordParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                Ok(json!({"recovery": create_v4(&p.password)?}))
            }
            "ssh.vault.reset" => {
                tokenstat_sync::vault::remove().map_err(|e| e.to_string())?;
                clear_local()?;
                forget_key();

                Ok(json!({"reset": true}))
            }
            "ssh.vault.unlock" => {
                let p: PasswordParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                if !p.recovery.trim().is_empty() {
                    return Err(
                        "a recovery code resets the password. It cannot unlock on its own.".into(),
                    );
                }
                unlock_with(&p.password, "")?;
                let recovery = if read()?.schema_version < SCHEMA {
                    verify_paid_account()?;
                    if !p.migrate {
                        forget_key();
                        return Err("update tokenstat to upgrade this vault securely".into());
                    }
                    Some(match rotate_root(&p.password, "", &p.password) {
                        Ok(code) => code,
                        Err(error) => {
                            forget_key();
                            return Err(error);
                        }
                    })
                } else {
                    None
                };
                Ok(json!({"unlocked": true, "recovery": recovery}))
            }
            "ssh.vault.lock" => {
                lock_session()?;
                Ok(json!({"locked": true}))
            }
            // Password changes and recovery resets replace the root key and
            // all wraps atomically; old wraps cannot decrypt future snapshots.
            "ssh.vault.password.set" => {
                verify_paid_account()?;
                let p: PasswordParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                if let Some(problem) = tokenstat_core::passphrase::password_error(&p.new_password) {
                    return Err(problem);
                }
                let recovery = rotate_root(&p.password, &p.recovery, &p.new_password)?;
                Ok(json!({"changed": true, "recovery": recovery}))
            }
            "ssh.vault.enrollment.request"
            | "ssh.vault.enrollment.list"
            | "ssh.vault.enrollment.approve" => Err(
                "enrollment is gone. Unlock the vault with your password on this device.".into(),
            ),
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
                verify_paid_account()?;
                if read()?.schema_version < SCHEMA {
                    return Err("unlock the vault to upgrade its encryption first".into());
                }
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
                    let next_revision = remote
                        .revision
                        .checked_add(1)
                        .ok_or("vault revision exhausted")?;
                    let (nonce, ciphertext) = encrypt_snapshot(&vmk, next_revision, &snapshot)?;
                    match tokenstat_sync::vault::update(&tokenstat_sync::vault::UpdateVault {
                        expected_revision: remote.revision,
                        schema_version: SCHEMA,
                        ciphertext: &ciphertext,
                        nonce: &nonce,
                        recovery_salt: None,
                        recovery_wrap: None,
                    }) {
                        Ok(answer) => {
                            cache_written(
                                remote.clone(),
                                &vmk,
                                next_revision,
                                nonce,
                                ciphertext,
                                answer.revision,
                            )?;
                            return Ok(json!({"id": p.id, "version": version}));
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
            "ssh.vault.record.delete" => {
                verify_paid_account()?;
                if read()?.schema_version < SCHEMA {
                    return Err("unlock the vault to upgrade its encryption first".into());
                }
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
                    let next_revision = remote
                        .revision
                        .checked_add(1)
                        .ok_or("vault revision exhausted")?;
                    let (nonce, ciphertext) = encrypt_snapshot(&vmk, next_revision, &snapshot)?;
                    match tokenstat_sync::vault::update(&tokenstat_sync::vault::UpdateVault {
                        expected_revision: remote.revision,
                        schema_version: SCHEMA,
                        ciphertext: &ciphertext,
                        nonce: &nonce,
                        recovery_salt: None,
                        recovery_wrap: None,
                    }) {
                        Ok(answer) => {
                            cache_written(
                                remote.clone(),
                                &vmk,
                                next_revision,
                                nonce,
                                ciphertext,
                                answer.revision,
                            )?;
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
                let p: PasswordParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let recovery = rotate_root(&p.password, "", &p.password)?;
                Ok(json!({"recovery": recovery}))
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
    fn a_vault_deleted_elsewhere_stops_existing_here() {
        // The account answered and has no vault. A local leftover from the one
        // that used to be there does not keep it alive.
        assert!(!vault_exists(false, false, SCHEMA));
    }

    #[test]
    fn a_vault_out_of_reach_is_still_a_vault() {
        // The account could not be asked. Saying "no vault" here is what sent
        // a machine off to create a second one.
        assert!(vault_exists(false, true, SCHEMA));
        // Nothing local either, so there is nothing to claim.
        assert!(!vault_exists(false, true, 0));
    }

    #[test]
    fn what_the_account_holds_needs_no_local_record() {
        assert!(vault_exists(true, false, 0));
    }

    #[test]
    fn a_vault_cannot_be_created_behind_a_weak_password() {
        // The host checks as well as the client. A client that forgets to
        // must not be able to put a weak password on an account's one vault.
        //
        // The password is checked before the account, which is what makes this
        // hold on a machine with no account signed in. It failed on CI while
        // passing here for exactly that reason.
        let refused = create_v4("short").unwrap_err();
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
    fn enrollment_public_methods_are_gone() {
        for method in [
            "ssh.vault.enrollment.request",
            "ssh.vault.enrollment.list",
            "ssh.vault.enrollment.approve",
        ] {
            let err = call(method, "{}").unwrap().expect_err(method);
            assert!(err.contains("password"), "{method}: {err}");
        }
    }

    #[test]
    fn unlock_does_not_accept_a_recovery_code() {
        let err = call("ssh.vault.unlock", r#"{"recovery":"ABCD-EFGH"}"#)
            .unwrap()
            .expect_err("recovery is a reset, not an unlock");
        assert!(err.contains("resets the password"), "{err}");
    }

    #[test]
    fn record_methods_do_not_accept_a_recovery_code() {
        let err = call("ssh.vault.record.list", r#"{"recovery":"ABCD-EFGH"}"#)
            .unwrap()
            .expect_err("recovery is a reset, not a record unlock");
        assert!(err.contains("resets the password"), "{err}");
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
    fn remote_fixture(key: &[u8; 32], revision: u64) -> tokenstat_sync::vault::RemoteVault {
        let (nonce, ciphertext) = encrypt_snapshot(key, revision, &Snapshot::default()).unwrap();
        tokenstat_sync::vault::RemoteVault {
            schema_version: SCHEMA,
            revision,
            nonce,
            ciphertext,
            recovery_salt: String::new(),
            recovery_wrap: String::new(),
            device_wrap: Some("untrusted-service-wrap".into()),
            wrap_version: Some(4),
            password_salt: Some(String::new()),
            password_wrap: Some(String::new()),
            kdf: Some(kdf_descriptor()),
            updated_at: String::new(),
        }
    }

    fn local_fixture(key: &[u8; 32], remote: &tokenstat_sync::vault::RemoteVault) -> VaultStore {
        VaultStore {
            key_id: key_id(key),
            schema_version: SCHEMA,
            revision: remote.revision,
            nonce: remote.nonce.clone(),
            ciphertext: remote.ciphertext.clone(),
            ..VaultStore::default()
        }
    }

    #[test]
    fn server_cannot_replace_root_or_replay_an_old_snapshot() {
        let key = [3; 32];
        let current = remote_fixture(&key, 9);
        let local = local_fixture(&key, &current);
        assert!(validate_remote(&local, &current, &key, false).is_ok());
        assert!(validate_remote(&local, &remote_fixture(&key, 8), &key, false).is_err());
        assert!(validate_remote(&local, &remote_fixture(&key, 9), &key, false).is_err());
        let replacement = [4; 32];
        let forged = remote_fixture(&replacement, 10);
        assert!(validate_remote(&local, &forged, &key, false).is_err());
        assert!(validate_remote(&local, &forged, &replacement, false).is_err());
        assert!(validate_remote(&local, &forged, &replacement, true).is_ok());
        assert!(
            validate_remote(&local, &remote_fixture(&replacement, 8), &replacement, true).is_err()
        );
        let mut downgrade = current.clone();
        downgrade.schema_version = 3;
        assert!(validate_remote(&local, &downgrade, &key, true).is_err());
    }

    #[test]
    fn failed_lock_persistence_cannot_restore_a_cached_key() {
        let _operation = operation_guard().unwrap();
        write(&VaultStore {
            schema_version: SCHEMA,
            ..VaultStore::default()
        })
        .unwrap();
        unlock_session([5; 32]).unwrap();
        assert!(!is_locked());
        // Reproduce a failed atomic-write staging file without real vault data.
        fs::create_dir(path().with_extension("tmp")).unwrap();
        assert!(lock_session().is_err());
        assert!(is_locked());
        assert!(cached_key().is_none());
        fs::remove_dir(path().with_extension("tmp")).unwrap();
        unlock_session([5; 32]).unwrap();
        assert!(!is_locked());
        lock_session().unwrap();
        // An unlocked flag from another process must not unlock this session.
        let mut store = read().unwrap();
        store.locked = false;
        write(&store).unwrap();
        assert!(is_locked());
        // Legacy device wraps cannot bring an empty session back to life.
        store.device_wrap = wrap_for_device(
            &[5; 32],
            &tokenstat_identity::MachineIdentity::from_secret([9; 32]).public_key(),
        )
        .unwrap();
        write(&store).unwrap();
        forget_key();
        assert!(cached_key().is_none());
        clear_local().unwrap();
    }

    #[test]
    fn malformed_unicode_wraps_fail_without_panicking() {
        assert!(unhex(&"é".repeat(32)).is_err());
        assert!(unpack(&format!("{}é00", "0".repeat(47))).is_err());
    }
}
