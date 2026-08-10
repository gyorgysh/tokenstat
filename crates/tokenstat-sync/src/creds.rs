//! Persist vendor session tokens under tokenstat's own data dir, and fall back
//! to tokens the vendor app already left in the OS keychain.
//!
//! Mode 0600 for anything we write. Never write secrets into the SQLite archive.

use std::fs;
use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::Vendor;
use crate::discover;

#[derive(Debug, Error)]
pub enum CredsError {
    #[error("no tokenstat data directory")]
    NoDataDir,
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenSource {
    Env,
    Stored,
    /// Found in the vendor app's OS keychain / local store.
    Discovered,
}

#[derive(Debug, Clone)]
pub struct AuthStatus {
    pub vendor: &'static str,
    pub present: bool,
    pub source: Option<TokenSource>,
    pub path: PathBuf,
}

fn data_dir() -> Result<PathBuf, CredsError> {
    directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .map(|d| d.data_dir().to_path_buf())
        .ok_or(CredsError::NoDataDir)
}

fn creds_dir() -> Result<PathBuf, CredsError> {
    let dir = data_dir()?.join("credentials");
    fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
    }
    Ok(dir)
}

fn token_path(vendor: Vendor) -> Result<PathBuf, CredsError> {
    Ok(creds_dir()?.join(format!("{}.session", vendor.as_str())))
}

/// Path where a pasted session token would be stored (may not exist yet).
pub fn session_path(vendor: Vendor) -> Result<PathBuf, CredsError> {
    token_path(vendor)
}

/// Environment variable overrides, useful for CI and one-off runs.
pub fn env_token(vendor: Vendor) -> Option<String> {
    let key = match vendor {
        Vendor::Cursor => "TOKENSTAT_CURSOR_SESSION",
        Vendor::Antigravity => "TOKENSTAT_ANTIGRAVITY_TOKEN",
    };
    std::env::var(key).ok().filter(|s| !s.trim().is_empty())
}

pub fn save_token(vendor: Vendor, token: &str) -> Result<PathBuf, CredsError> {
    let path = token_path(vendor)?;
    let trimmed = token.trim();
    crate::snapshot::write_private_atomically(&path, trimmed)
        .map_err(|e| CredsError::Io(std::io::Error::other(e.to_string())))?;
    Ok(path)
}

pub fn clear_token(vendor: Vendor) -> Result<(), CredsError> {
    let path = token_path(vendor)?;
    if path.exists() {
        fs::remove_file(&path)?;
    }
    Ok(())
}

/// Resolve a vendor token: env, then live OS discovery, then a stored paste.
///
/// Discovery is preferred over a stored session file so a rotated keychain JWT
/// is used immediately instead of a stale copy that `auth` once persisted.
pub fn token_for(vendor: Vendor) -> Result<Option<String>, CredsError> {
    Ok(token_with_source(vendor)?.map(|(t, _)| t))
}

pub fn token_with_source(vendor: Vendor) -> Result<Option<(String, TokenSource)>, CredsError> {
    if let Some(t) = env_token(vendor) {
        return Ok(Some((t, TokenSource::Env)));
    }
    if let Some(t) = discover::local_token(vendor) {
        return Ok(Some((t, TokenSource::Discovered)));
    }
    let path = token_path(vendor)?;
    if path.exists() {
        let s = fs::read_to_string(&path)?;
        let t = s.trim().to_string();
        if !t.is_empty() {
            return Ok(Some((t, TokenSource::Stored)));
        }
    }
    Ok(None)
}

pub fn has_token(vendor: Vendor) -> bool {
    token_for(vendor).ok().flatten().is_some()
}

pub fn status() -> Result<Vec<AuthStatus>, CredsError> {
    Ok(vec![
        status_one(Vendor::Cursor)?,
        status_one(Vendor::Antigravity)?,
    ])
}

fn status_one(vendor: Vendor) -> Result<AuthStatus, CredsError> {
    let resolved = token_with_source(vendor)?;
    Ok(AuthStatus {
        vendor: vendor.as_str(),
        present: resolved.is_some(),
        source: resolved.map(|(_, s)| s),
        path: token_path(vendor)?,
    })
}

pub fn cache_path(vendor: Vendor, name: &str) -> Result<PathBuf, CredsError> {
    let dir = data_dir()?.join("cache").join(vendor.as_str());
    fs::create_dir_all(&dir)?;
    Ok(dir.join(name))
}

pub fn cache_is_fresh(path: &Path, ttl: std::time::Duration) -> bool {
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    let Ok(modified) = meta.modified() else {
        return false;
    };
    modified.elapsed().map(|age| age < ttl).unwrap_or(false)
}
