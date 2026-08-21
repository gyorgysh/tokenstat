// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.

//! Filesystem locations shared by every tokenstat crate.
//!
//! Desktop processes can discover their own standard directories. Sandboxed
//! mobile processes cannot: Android deliberately has no Unix home directory,
//! and only the application knows its private files and cache directories.
//! The native front end therefore supplies those roots exactly once, before
//! making any protocol call.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

#[derive(Clone, Debug, PartialEq, Eq)]
struct MobileRoots {
    data: PathBuf,
    cache: PathBuf,
}

static MOBILE_ROOTS: OnceLock<MobileRoots> = OnceLock::new();

/// Configure a sandboxed client's private roots.
///
/// Idempotent for the same paths and rejected for different paths. Changing
/// roots after a session has opened would split one process across identities.
pub fn configure_mobile(data: impl AsRef<Path>, cache: impl AsRef<Path>) -> Result<(), String> {
    let roots = MobileRoots {
        data: data.as_ref().to_path_buf(),
        cache: cache.as_ref().to_path_buf(),
    };
    if let Some(current) = MOBILE_ROOTS.get() {
        return if current == &roots {
            Ok(())
        } else {
            Err("tokenstat paths were already configured for another sandbox".into())
        };
    }
    std::fs::create_dir_all(&roots.data).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&roots.cache).map_err(|e| e.to_string())?;
    MOBILE_ROOTS
        .set(roots)
        .map_err(|_| "tokenstat paths were configured concurrently".to_string())
}

pub fn data_dir() -> Option<PathBuf> {
    MOBILE_ROOTS
        .get()
        .map(|roots| roots.data.clone())
        .or_else(|| project_dirs().map(|dirs| dirs.data_dir().to_path_buf()))
}

pub fn data_local_dir() -> Option<PathBuf> {
    MOBILE_ROOTS
        .get()
        .map(|roots| roots.data.clone())
        .or_else(|| project_dirs().map(|dirs| dirs.data_local_dir().to_path_buf()))
}

pub fn config_dir() -> Option<PathBuf> {
    MOBILE_ROOTS
        .get()
        .map(|roots| roots.data.clone())
        .or_else(|| project_dirs().map(|dirs| dirs.config_dir().to_path_buf()))
}

pub fn cache_dir() -> Option<PathBuf> {
    MOBILE_ROOTS
        .get()
        .map(|roots| roots.cache.clone())
        .or_else(|| project_dirs().map(|dirs| dirs.cache_dir().to_path_buf()))
}

pub fn runtime_dir() -> Option<PathBuf> {
    MOBILE_ROOTS
        .get()
        .map(|roots| roots.cache.clone())
        .or_else(|| project_dirs().and_then(|dirs| dirs.runtime_dir().map(Path::to_path_buf)))
}

fn project_dirs() -> Option<directories::ProjectDirs> {
    directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
}
