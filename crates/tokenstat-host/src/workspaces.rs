// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.
//! The registered folders, reachable without the session lock.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};
use tokenstat_workspace::{Registry, RegistryError, Workspace};

fn path() -> PathBuf {
    #[cfg(test)]
    {
        std::env::temp_dir().join(format!(
            "tokenstat-test-registry-{}.json",
            std::process::id()
        ))
    }
    #[cfg(not(test))]
    {
        Registry::default_path().unwrap_or_else(|_| PathBuf::from("workspaces.json"))
    }
}

fn cell() -> &'static RwLock<Registry> {
    static REGISTRY: OnceLock<RwLock<Registry>> = OnceLock::new();

    REGISTRY.get_or_init(|| RwLock::new(load_initial()))
}

fn load_initial() -> Registry {
    let path = path();
    match Registry::load_from(&path) {
        Ok(registry) => registry,
        Err(RegistryError::Json(error)) => {
            let kept = preserve_corrupt(&path)
                .map(|kept| kept.display().to_string())
                .unwrap_or_else(|| "nothing (the file could not be moved)".to_string());
            eprintln!("workspaces: {path:?} is unreadable ({error}); kept it at {kept}");
            Registry::default()
        }
        Err(error) => {
            eprintln!("workspaces: {path:?} could not be read: {error}");
            Registry::default()
        }
    }
}

fn preserve_corrupt(path: &Path) -> Option<PathBuf> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0);
    let kept = path.with_extension(format!("json.corrupt-{stamp}"));
    fs::rename(path, &kept).ok().map(|()| kept)
}

/// Persist the list. Always through here, never `Registry::save`, so the test
/// path above cannot be bypassed by a new call site.
pub fn save(registry: &Registry) -> Result<(), String> {
    registry.save_to(&path()).map_err(|e| e.to_string())
}

/// A poisoned lock is recovered rather than propagated. The registry is a plain
/// list with no invariant spanning two fields, so a panic in an earlier caller
/// cannot have left it half-written.
pub fn read() -> RwLockReadGuard<'static, Registry> {
    cell().read().unwrap_or_else(PoisonError::into_inner)
}

pub fn write() -> RwLockWriteGuard<'static, Registry> {
    cell().write().unwrap_or_else(PoisonError::into_inner)
}

/// A registered folder by id, cloned so the caller can release the lock before
/// it spends time on disk.
pub fn get(id: &str) -> Result<Workspace, String> {
    read()
        .get(id)
        .cloned()
        .ok_or_else(|| format!("no workspace with id {id}"))
}

/// The same lookup, refusing a folder that is not on disk.
///
/// Every per-folder method needs the same two checks, and a missing folder has
/// to fail with words rather than with whatever git says about a path that is
/// not there.
pub fn folder(id: &str) -> Result<Workspace, String> {
    let ws = get(id)?;
    if !ws.exists() {
        return Err(format!("the folder is missing: {}", ws.path.display()));
    }
    Ok(ws)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_corrupt_registry_is_kept_beside_the_original() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspaces.json");
        fs::write(&path, b"{ not json").unwrap();
        let kept = preserve_corrupt(&path).expect("the unreadable file must be kept");
        assert!(
            !path.exists(),
            "the original path is cleared for the next save"
        );
        assert_eq!(fs::read(&kept).unwrap(), b"{ not json");
        assert!(
            kept.to_string_lossy().contains(".corrupt-"),
            "{}",
            kept.display()
        );
    }
}
