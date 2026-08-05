// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! The registered folders, reachable without the session lock.
//!
//! These used to live in `Session`, which put every folder method behind the
//! one daemon-wide mutex that also guards the archive. Nothing here reads the
//! archive, so a `git status` and a terminal spawn were queueing behind scans
//! and reports for no reason: opening a terminal took tens of seconds because
//! it waited for work it shares nothing with.
//!
//! The rule that keeps it fixed: a lookup takes a guard, clones the folder it
//! wants, and drops the guard before touching the disk. Holding one across a
//! `git log` would rebuild the contention this module exists to remove.

use std::path::PathBuf;
use std::sync::{OnceLock, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};
use tokenstat_workspace::{Registry, Workspace};

/// Where the list is read from and written to.
///
/// Under test this is a per-process temp file, and that is not a nicety.
/// `Registry::save` resolves the platform data directory with no override, so
/// `cargo test` wrote its throwaway folders straight into the file the app
/// reads, and they accumulated there for as long as the tests have existed.
/// One shared registry per process makes that worse, because any test that
/// saves persists what every other test added.
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
    // A registry that will not parse is surfaced as an empty one rather than
    // refusing to start, the same way opening an archive treats it.
    REGISTRY.get_or_init(|| RwLock::new(Registry::load_from(&path()).unwrap_or_default()))
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
