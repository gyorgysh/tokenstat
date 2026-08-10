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
    if let Some(t) = file_load(host)? {
        return Ok(Some(t));
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(t) = legacy_keychain_load(host)? {
            let _ = file_store(host, &t);
            let _ = legacy_keychain_delete(host);
            return Ok(Some(t));
        }
    }
    Ok(None)
}

/// Delete the sync bearer token for `host`. Idempotent.
pub fn delete_token(host: &str) -> Result<(), KeychainError> {
    file_delete(host)?;
    #[cfg(target_os = "macos")]
    {
        let _ = legacy_keychain_delete(host);
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn legacy_keychain_load(host: &str) -> Result<Option<String>, KeychainError> {
    let output = std::process::Command::new("security")
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
    let _ = std::process::Command::new("security")
        .args(["delete-generic-password", "-s", SERVICE, "-a", host])
        .output()?;
    Ok(())
}

fn creds_path(host: &str) -> Result<std::path::PathBuf, KeychainError> {
    let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .ok_or_else(|| KeychainError::Unavailable("no data directory".into()))?;
    let dir = dirs.data_dir().join("credentials").join("sync");
    std::fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    // Host origin as filename is awkward on Windows; hash for the path.
    Ok(dir.join(format!("{}.token", blake3_lite(host.as_bytes()))))
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
