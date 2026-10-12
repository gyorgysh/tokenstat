//! Local config for machine id, project salt, preferred sync host, and cursors.
//!
//! Sync bearer tokens stay in the OS keychain. The project HMAC salt is a local
//! secret stored under credentials/ (mode 0600), never in the sync payload.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokenstat_core::{is_valid_machine_id, is_valid_salt_id};

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("no tokenstat data directory")]
    NoDataDir,
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("config json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid machine id in config: {0}")]
    InvalidMachineId(String),
    #[error("invalid salt id: {0}")]
    InvalidSaltId(String),
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Config {
    /// Stable random id (`m_` + 16 hex). Not hardware-derived.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    #[serde(default)]
    pub sync: SyncConfig,
    #[serde(default)]
    pub update: UpdateConfig,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdateConfig {
    /// Apply a newer GitHub Release from scan / the daily schedule when the
    /// binary path is writable (not cargo/homebrew system installs).
    /// Omitted means on; set `false` to opt out (`tokenstat update --auto off`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto: Option<bool>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SyncConfig {
    /// Last successful login host, reused by later `sync` calls.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// Per-host last successful sync window / timestamp.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub cursor: BTreeMap<String, SyncCursor>,
    /// Post plan-limit readings to the account after a sync (P2).
    ///
    /// Opt-in. Off when omitted so an existing config never starts uploading
    /// quota percentages until the user turns it on. Percentages and reset
    /// times only; vendor credentials never leave the machine.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limits: Option<bool>,
    /// Sources that must not be posted even when `limits` is on.
    ///
    /// A vendor the user turned off (expired plan, do not track) stays out
    /// of the account payload. Empty means share every reading that has
    /// numbers.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub limits_skip: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncCursor {
    pub from: String,
    pub to: String,
    pub last_sync_at: String,
    /// Earliest time the server will accept the next sync from this machine,
    /// as it told us. Remembered so a scheduled run can stay quiet instead of
    /// spending a request to be refused. Advisory: the server decides.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_allowed_at: Option<String>,
    /// Minimum seconds between accepted syncs on the account's current plan.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_interval: Option<u64>,
}

/// Local project-hashing salt. `id` goes on the wire; `key` never does.
#[derive(Debug, Clone)]
pub struct ProjectSalt {
    pub id: String,
    pub key: Vec<u8>,
}

#[derive(Debug, Serialize, Deserialize)]
struct SaltFile {
    id: String,
    /// Hex-encoded HMAC key bytes.
    key_hex: String,
}

fn data_dir() -> Result<PathBuf, ConfigError> {
    tokenstat_paths::data_dir().ok_or(ConfigError::NoDataDir)
}

pub fn config_path() -> Result<PathBuf, ConfigError> {
    Ok(data_dir()?.join("config.json"))
}

fn salt_path() -> Result<PathBuf, ConfigError> {
    let dir = data_dir()?.join("credentials");
    fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
    }
    Ok(dir.join("project.salt"))
}

pub fn load() -> Result<Config, ConfigError> {
    load_from(&config_path()?)
}

fn load_from(path: &Path) -> Result<Config, ConfigError> {
    if !path.exists() {
        return Ok(Config::default());
    }
    let text = fs::read_to_string(path)?;
    let cfg: Config = serde_json::from_str(&text)?;
    if let Some(m) = &cfg.machine
        && !is_valid_machine_id(m)
    {
        return Err(ConfigError::InvalidMachineId(m.clone()));
    }
    Ok(cfg)
}

fn save_to(path: &Path, cfg: &Config) -> Result<(), ConfigError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(cfg)?;
    crate::snapshot::write_private_atomically(path, &json)
        .map_err(|e| ConfigError::Io(std::io::Error::other(e.to_string())))?;
    Ok(())
}

// Keep the stable lock separate from the atomically replaced JSON inode.
fn lock(path: &Path) -> Result<fs::File, ConfigError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut options = fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(path.with_extension("lock"))?;
    file.lock()?;
    Ok(file)
}

fn update_at<T>(
    path: &Path,
    mutate: impl FnOnce(&mut Config) -> Result<T, ConfigError>,
) -> Result<T, ConfigError> {
    let _lock = lock(path)?;
    let mut cfg = load_from(path)?;
    let value = mutate(&mut cfg)?;
    save_to(path, &cfg)?;
    Ok(value)
}

fn update<T>(mutate: impl FnOnce(&mut Config) -> Result<T, ConfigError>) -> Result<T, ConfigError> {
    update_at(&config_path()?, mutate)
}

/// Return the persisted machine id, creating one on first use.
pub fn ensure_machine_id() -> Result<String, ConfigError> {
    ensure_machine_id_at(&config_path()?)
}

fn ensure_machine_id_at(path: &Path) -> Result<String, ConfigError> {
    if let Some(id) = load_from(path)?.machine {
        return Ok(id);
    }
    update_at(path, |cfg| {
        if let Some(id) = &cfg.machine {
            return Ok(id.clone());
        }
        let id = generate_hex_id("m_", 8)?;
        cfg.machine = Some(id.clone());
        Ok(id)
    })
}

/// Return the local project salt, creating one on first use.
///
/// Rotating this file creates a new `salt_id` namespace on the server; old rows
/// are not remapped.
pub fn ensure_project_salt() -> Result<ProjectSalt, ConfigError> {
    ensure_project_salt_at(&salt_path()?)
}

fn ensure_project_salt_at(path: &Path) -> Result<ProjectSalt, ConfigError> {
    let _lock = lock(path)?;
    if path.exists() {
        let text = fs::read_to_string(path)?;
        let file: SaltFile = serde_json::from_str(&text)?;
        if !is_valid_salt_id(&file.id) {
            return Err(ConfigError::InvalidSaltId(file.id));
        }
        let key =
            hex_decode(&file.key_hex).map_err(|e| ConfigError::Io(std::io::Error::other(e)))?;
        if key.is_empty() {
            return Err(ConfigError::InvalidSaltId("empty key".into()));
        }
        return Ok(ProjectSalt { id: file.id, key });
    }
    let id = generate_hex_id("s_", 4)?;
    let mut key = vec![0u8; 32];
    getrandom::fill(&mut key)
        .map_err(|e| ConfigError::Io(std::io::Error::other(format!("getrandom: {e}"))))?;
    let file = SaltFile {
        id: id.clone(),
        key_hex: hex_encode(&key),
    };
    let json = serde_json::to_string_pretty(&file)?;
    crate::snapshot::write_private_atomically(path, &json)
        .map_err(|e| ConfigError::Io(std::io::Error::other(e.to_string())))?;
    Ok(ProjectSalt { id, key })
}

pub fn set_sync_host(host: &str) -> Result<(), ConfigError> {
    update(|cfg| {
        cfg.sync.host = Some(host.to_string());
        Ok(())
    })
}

/// Whether this machine posts plan-limit readings after a sync (P2).
///
/// Opt-in: missing or `false` means off.
pub fn limits_sync_enabled() -> bool {
    load().ok().and_then(|c| c.sync.limits).unwrap_or(false)
}

/// Turn plan-limit posting on or off.
pub fn set_limits_sync(on: bool) -> Result<(), ConfigError> {
    update(|cfg| {
        cfg.sync.limits = Some(on);
        Ok(())
    })
}

/// Source ids that must not be posted, even when limits sync is on.
pub fn limits_skip() -> Vec<String> {
    load().ok().map(|c| c.sync.limits_skip).unwrap_or_default()
}

/// Replace the skip list. Empty ids and junk are dropped.
pub fn set_limits_skip(skip: Vec<String>) -> Result<(), ConfigError> {
    update(|cfg| {
        cfg.sync.limits_skip = clean_skip(skip);
        Ok(())
    })
}

/// Turn posting for one source on or off. Off adds it to the skip list.
pub fn set_limits_source_shared(source: &str, shared: bool) -> Result<(), ConfigError> {
    update(|cfg| {
        let skip = &mut cfg.sync.limits_skip;
        if shared {
            skip.retain(|s| s != source);
        } else if is_skip_id(source) && !skip.iter().any(|s| s == source) {
            skip.push(source.to_string());
        }
        skip.sort();
        skip.dedup();
        Ok(())
    })
}

fn clean_skip(skip: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = skip.into_iter().filter(|s| is_skip_id(s)).collect();
    out.sort();
    out.dedup();
    out
}

fn is_skip_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
}

/// Turn automatic update applying on or off.
///
/// Default is on. Persist an explicit value so a scheduler entry (which does
/// not inherit shell env) matches the user's choice after `update --auto`.
pub fn set_update_auto(on: bool) -> Result<(), ConfigError> {
    update(|cfg| {
        cfg.update.auto = Some(on);
        Ok(())
    })
}

pub fn record_sync_cursor(
    host: &str,
    from: &str,
    to: &str,
    last_sync_at: &str,
    pacing: SyncPacing,
) -> Result<(), ConfigError> {
    update(|cfg| {
        cfg.sync.cursor.insert(
            host.to_string(),
            SyncCursor {
                from: from.to_string(),
                to: to.to_string(),
                last_sync_at: last_sync_at.to_string(),
                next_allowed_at: pacing.next_allowed_at,
                min_interval: pacing.min_interval,
            },
        );
        Ok(())
    })
}

/// What the server said about when this machine may sync again.
#[derive(Debug, Clone, Default)]
pub struct SyncPacing {
    pub next_allowed_at: Option<String>,
    pub min_interval: Option<u64>,
}

/// Remember a refusal without touching the window cursor.
///
/// A held-back sync uploaded nothing, so `from` / `to` / `last_sync_at` must
/// stay exactly as they were. Only the pacing hint moves. When there is no
/// cursor yet (first sync refused before any accept), still persist pacing so
/// `--scheduled` can skip without a request.
pub fn record_sync_hold(host: &str, pacing: SyncPacing) -> Result<(), ConfigError> {
    update(|cfg| {
        if let Some(cursor) = cfg.sync.cursor.get_mut(host) {
            if pacing.next_allowed_at.is_some() {
                cursor.next_allowed_at = pacing.next_allowed_at.clone();
            }
            if pacing.min_interval.is_some() {
                cursor.min_interval = pacing.min_interval;
            }
        } else if pacing.next_allowed_at.is_some() || pacing.min_interval.is_some() {
            cfg.sync.cursor.insert(
                host.to_string(),
                SyncCursor {
                    from: String::new(),
                    to: String::new(),
                    last_sync_at: String::new(),
                    next_allowed_at: pacing.next_allowed_at,
                    min_interval: pacing.min_interval,
                },
            );
        } else {
            return Ok(());
        }
        Ok(())
    })
}

pub fn cursor_for(host: &str) -> Result<Option<SyncCursor>, ConfigError> {
    Ok(load()?.sync.cursor.get(host).cloned())
}

fn generate_hex_id(prefix: &str, nbytes: usize) -> Result<String, ConfigError> {
    let mut bytes = vec![0u8; nbytes];
    getrandom::fill(&mut bytes)
        .map_err(|e| ConfigError::Io(std::io::Error::other(format!("getrandom: {e}"))))?;
    Ok(format!("{prefix}{}", hex_encode(&bytes)))
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn hex_decode(s: &str) -> Result<Vec<u8>, String> {
    if !s.is_ascii() {
        return Err("non-ASCII hex value".into());
    }
    if !s.len().is_multiple_of(2) {
        return Err("odd hex length".into());
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let chars: Vec<char> = s.chars().collect();
    for chunk in chars.chunks(2) {
        let byte = u8::from_str_radix(&format!("{}{}", chunk[0], chunk[1]), 16)
            .map_err(|e| e.to_string())?;
        out.push(byte);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokenstat_core::{is_valid_machine_id, is_valid_salt_id};

    #[test]
    fn generated_ids_match_shapes() {
        let m = generate_hex_id("m_", 8).unwrap();
        let s = generate_hex_id("s_", 4).unwrap();
        assert!(is_valid_machine_id(&m), "{m}");
        assert!(is_valid_salt_id(&s), "{s}");
    }

    #[test]
    fn hex_roundtrip() {
        let b = vec![0xab, 0xcd, 0x00, 0xff];
        assert_eq!(hex_decode(&hex_encode(&b)).unwrap(), b);
    }

    #[test]
    fn skip_list_drops_junk_and_dedupes() {
        assert_eq!(
            clean_skip(vec![
                "cursor".into(),
                "cursor".into(),
                "".into(),
                "bad id".into(),
                "claude_code".into(),
            ]),
            vec!["claude_code".to_string(), "cursor".to_string()]
        );
        assert!(is_skip_id("antigravity_ide"));
        assert!(!is_skip_id("no spaces"));
    }
    #[test]
    fn concurrent_initialization_keeps_one_machine_and_salt() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let salt_path = dir.path().join("project.salt");
        let values = std::thread::scope(|scope| {
            let threads = (0..16)
                .map(|_| {
                    scope.spawn(|| {
                        (
                            ensure_machine_id_at(&path).unwrap(),
                            ensure_project_salt_at(&salt_path).unwrap(),
                        )
                    })
                })
                .collect::<Vec<_>>();
            threads
                .into_iter()
                .map(|t| t.join().unwrap())
                .collect::<Vec<_>>()
        });
        for (id, salt) in &values {
            assert_eq!(id, &values[0].0);
            assert_eq!(salt.id, values[0].1.id);
            assert_eq!(salt.key, values[0].1.key);
        }
        assert_eq!(
            load_from(&path).unwrap().machine.as_ref(),
            Some(&values[0].0)
        );
    }

    #[test]
    fn concurrent_updates_preserve_independent_cursors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        std::thread::scope(|scope| {
            for n in 0..16 {
                let path = &path;
                scope.spawn(move || {
                    update_at(path, |cfg| {
                        cfg.sync.cursor.insert(
                            n.to_string(),
                            SyncCursor {
                                from: "2026-10-01".into(),
                                to: "2026-10-12".into(),
                                last_sync_at: String::new(),
                                next_allowed_at: None,
                                min_interval: None,
                            },
                        );
                        Ok(())
                    })
                    .unwrap()
                });
            }
        });
        assert_eq!(load_from(&path).unwrap().sync.cursor.len(), 16);
    }

    #[test]
    fn malformed_unicode_hex_is_an_error() {
        for text in ["éaa", "aaaéa", "zz", "a"] {
            assert!(hex_decode(text).is_err());
        }
    }
}
