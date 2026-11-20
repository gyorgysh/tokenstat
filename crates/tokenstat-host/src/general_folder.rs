// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! One folder per host for chats that belong to no repository.
//!
//! Somebody who wants to ask an agent a question, or try something
//! throwaway, should not have to pick or create a project first. Every
//! agent still needs a working directory, so each host keeps one plain
//! folder inside its own data directory and registers it like any other.
//! Chats, terminals and lookups by id then work with no special case.
//!
//! It is one shared folder, not one per chat. A folder per chat would hide
//! files an earlier chat left behind and would grow without bound, while a
//! single place is what "no repository" means to a person.
//!
//! The folder is registered on first use and left out of `workspace.list`
//! unless the caller asks for it, so a client that predates it never shows
//! it as a project.

use std::path::{Path, PathBuf};

/// The name the registry stores. Clients show their own localized label.
const NAME: &str = "General";

/// Where the folder lives, or `None` when there is no data directory.
pub fn path() -> Option<PathBuf> {
    tokenstat_paths::data_dir().map(|dir| dir.join("general"))
}

/// Text form without a Windows verbatim prefix, so a canonical path and the
/// plain spelling the registry stores compare equal.
fn plain(path: &Path) -> String {
    let text = path.to_string_lossy();
    text.strip_prefix(r"\\?\").unwrap_or(&text).to_string()
}

/// Whether a registered folder is this host's general folder.
pub fn is_general(ws: &tokenstat_workspace::Workspace) -> bool {
    let Some(general) = path() else {
        return false;
    };
    let stored = plain(&ws.path);
    stored == plain(&general)
        || std::fs::canonicalize(&general).is_ok_and(|canonical| stored == plain(&canonical))
}

/// Create and register the folder if needed, and return its registry row.
pub fn ensure(now_ms: i64) -> Result<tokenstat_workspace::Workspace, String> {
    let dir = path().ok_or("this computer has no data directory")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let mut registry = crate::workspaces::write();
    let before = registry.workspaces.len();
    let ws = registry
        .add_plain(&dir, now_ms)
        .map_err(|e| e.to_string())?;
    if registry.workspaces.len() != before {
        registry.rename(&ws.id, NAME);
        crate::workspaces::save(&registry)?;
    }
    let row = registry.get(&ws.id).cloned().unwrap_or(ws);
    Ok(row)
}
