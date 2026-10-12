//! Sync bearer token storage for tokenstat.ai.
//!
//! Entries are keyed by host origin so sandbox and prod never share a token.
//! Tokens are never written to `tokenstat.db`, config files, or logs.
//!
//! Storage is a mode-0600 file under the tokenstat data directory. The macOS
//! `security -w` path puts the secret on argv (visible in the process table),
//! so it is not used for writes. Legacy keychain entries are still read once
//! and migrated into the file store.

use thiserror::Error;

#[cfg(target_os = "macos")]
const SERVICE: &str = "ai.tokenstat.sync";

#[derive(Debug, Error)]
pub enum KeychainError {
    #[error("keychain unavailable: {0}")]
    Unavailable(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Store a sync bearer token for `host`.
pub fn store_token(host: &str, token: &str) -> Result<(), KeychainError> {
    let token = token.trim();
    if token.is_empty() {
        return Err(KeychainError::Unavailable("empty token".into()));
    }
    let _lock = token_lock(host)?;
    file_store(host, token)?;
    // Drop any legacy keychain copy so we do not leave the secret in two places.
    #[cfg(target_os = "macos")]
    {
        let _ = legacy_keychain_delete(host);
    }
    Ok(())
}

/// Read the sync bearer token for `host`, if any.
pub fn load_token(host: &str) -> Result<Option<String>, KeychainError> {
    let _lock = token_lock(host)?;
    if let Some(t) = file_load(host)? {
        return Ok(Some(t));
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(t) = legacy_keychain_load(host)? {
            // The legacy entry is the only durable copy of the secret. Delete
            // it only once the file store has actually accepted it, or a
            // failed write loses the token twice over. A write that cannot
            // happen is not a failed read: the token is still returned, and
            // the legacy entry stays for the next attempt.
            if file_store(host, &t).is_ok() {
                let _ = legacy_keychain_delete(host);
            }
            return Ok(Some(t));
        }
    }
    Ok(None)
}

/// Delete the sync bearer token for `host`. Idempotent.
pub fn delete_token(host: &str) -> Result<(), KeychainError> {
    let _lock = token_lock(host)?;
    // Remove the legacy fallback first. If deletion is refused, preserve the
    // current token and report the failure rather than resurrecting it later.
    #[cfg(target_os = "macos")]
    legacy_keychain_delete(host)?;
    file_delete(host)?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn legacy_keychain_load(host: &str) -> Result<Option<String>, KeychainError> {
    let output = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", SERVICE, "-a", host, "-w"])
        .output()?;
    if !output.status.success() {
        return Ok(None);
    }
    let s =
        String::from_utf8(output.stdout).map_err(|e| KeychainError::Unavailable(e.to_string()))?;
    let t = s.trim().to_string();
    Ok((!t.is_empty()).then_some(t))
}

#[cfg(target_os = "macos")]
fn legacy_keychain_delete(host: &str) -> Result<(), KeychainError> {
    let output = std::process::Command::new("/usr/bin/security")
        .args(["delete-generic-password", "-s", SERVICE, "-a", host])
        .output()?;
    if output.status.success() || output.status.code() == Some(44) {
        Ok(())
    } else {
        Err(KeychainError::Unavailable(
            "could not remove the legacy sign-in".into(),
        ))
    }
}

fn creds_path(host: &str) -> Result<std::path::PathBuf, KeychainError> {
    let dir = tokenstat_paths::data_dir()
        .ok_or_else(|| KeychainError::Unavailable("no data directory".into()))?
        .join("credentials")
        .join("sync");
    std::fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    // Host origin as filename is awkward on Windows; hash for the path.
    Ok(dir.join(format!("{}.token", blake3_lite(host.as_bytes()))))
}

fn token_lock(host: &str) -> Result<std::fs::File, KeychainError> {
    let path = creds_path(host)?.with_extension("lock");
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lock = options.open(path)?;
    lock.lock()?;
    Ok(lock)
}

fn blake3_lite(bytes: &[u8]) -> String {
    // Avoid a core dependency just for a filename: FNV-ish hex of bytes.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

fn file_store(host: &str, token: &str) -> Result<(), KeychainError> {
    let path = creds_path(host)?;
    crate::snapshot::write_private_atomically(&path, token)
        .map_err(|e| KeychainError::Unavailable(e.to_string()))?;
    Ok(())
}

fn file_load(host: &str) -> Result<Option<String>, KeychainError> {
    let path = creds_path(host)?;
    if !path.exists() {
        return Ok(None);
    }
    let s = std::fs::read_to_string(&path)?;
    let t = s.trim().to_string();
    Ok((!t.is_empty()).then_some(t))
}

fn file_delete(host: &str) -> Result<(), KeychainError> {
    let path = creds_path(host)?;
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
}
