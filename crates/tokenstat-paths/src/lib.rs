// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.

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
    if let Some(roots) = MOBILE_ROOTS.get() {
        return Some(roots.data.clone());
    }
    if let Some(dir) = data_dir_override() {
        return Some(dir);
    }
    project_dirs().map(|dirs| dirs.data_dir().to_path_buf())
}

fn data_dir_override() -> Option<PathBuf> {
    let dir = std::env::var_os("TOKENSTAT_DATA_DIR").map(PathBuf::from)?;
    if dir.as_os_str().is_empty() || dir.is_relative() {
        return None;
    }
    Some(dir)
}

/// A generated opaque agent profile identifier, safe as a path segment.
pub fn is_agent_profile_id(id: &str) -> bool {
    id.strip_prefix("p_").is_some_and(|suffix| {
        suffix.len() == 16 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
    })
}

pub const CHAT_AGENT_PROFILE_FILE: &str = ".tokenstat-profile";

pub fn chat_agent_profile(home: &Path) -> Option<String> {
    let id = std::fs::read_to_string(home.join(CHAT_AGENT_PROFILE_FILE)).ok()?;
    is_agent_profile_id(&id).then_some(id)
}

/// Known native agent homes under this installation's profile directory.
pub fn agent_profile_homes(agent: &str) -> Vec<(String, PathBuf)> {
    let Some(entries) = data_dir().and_then(|data| std::fs::read_dir(data.join("profiles")).ok())
    else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let id = entry.file_name().into_string().ok()?;
            if !is_agent_profile_id(&id) || !entry.file_type().ok()?.is_dir() {
                return None;
            }
            let home = entry.path().join(agent);
            std::fs::symlink_metadata(&home)
                .ok()?
                .is_dir()
                .then_some((id, home))
        })
        .collect()
}

pub fn data_local_dir() -> Option<PathBuf> {
    MOBILE_ROOTS
        .get()
        .map(|roots| roots.data.clone())
        .or_else(data_dir_override)
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

/// The user's home directory, even when the process environment does not name
/// one.
///
/// `$HOME` first, because an explicit value is an answer and a portable
/// install may mean it. Then the password database, through `directories`,
/// because a **systemd system service has no HOME at all**: the unit starts
/// with PATH, USER and the journal variables, and nothing else. Building a
/// conventional location from an empty string turned `~/.local/bin` into
/// `/.local/bin`, so a headless host could not see a harness its own
/// installer had just delivered, and the install read as a failure.
///
/// `None` only where there is genuinely no home to find, which on a sandboxed
/// mobile client is the normal answer: those processes have roots handed to
/// them by [`configure_mobile`] instead.
pub fn home_dir() -> Option<PathBuf> {
    for key in HOME_KEYS {
        if let Some(value) = std::env::var_os(key).filter(|value| !value.is_empty()) {
            let path = PathBuf::from(value);
            // A relative HOME would make every join relative too; ignore it
            // and fall back to the password database.
            if path.is_absolute() {
                return Some(path);
            }
        }
    }
    directories::BaseDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

#[cfg(windows)]
const HOME_KEYS: &[&str] = &["USERPROFILE", "HOME"];
#[cfg(not(windows))]
const HOME_KEYS: &[&str] = &["HOME"];

#[cfg(test)]
mod home_tests {
    #[test]
    #[cfg(unix)]
    fn a_scrubbed_environment_still_finds_home() {
        let restore = std::env::var_os("HOME");
        unsafe { std::env::remove_var("HOME") };
        let found = super::home_dir();
        if let Some(home) = restore {
            unsafe { std::env::set_var("HOME", home) };
        }
        let found = found.expect("a unix account has a home in the password database");
        assert!(found.is_absolute(), "{} is not absolute", found.display());
    }
}
