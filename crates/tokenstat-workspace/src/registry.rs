//! The folders a user chose to work in.
//!
//! Deliberately **not** derived from the usage archive. The archive's `project`
//! is a display label recovered from a slug that lost the difference between a
//! `/` and a `-`, so it cannot name a folder on disk even in principle. More to
//! the point, a workspace is a decision: these are the folders you want open,
//! not every directory an agent has ever touched.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, thiserror::Error)]
pub enum RegistryError {
    #[error("no data directory on this platform")]
    NoDataDir,
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("{0}")]
    Json(#[from] serde_json::Error),
    #[error("not a folder: {0}")]
    NotAFolder(PathBuf),
}

/// One registered folder.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    /// Stable across renames of the folder's contents, because it is the path.
    pub id: String,
    pub path: PathBuf,
    /// What to call it. Defaults to the folder name, and a user may override
    /// it: two checkouts of one repository otherwise look identical.
    pub name: String,
    pub added_at_ms: i64,
}

impl Workspace {
    fn new(path: PathBuf, added_at_ms: i64) -> Workspace {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| path.to_string_lossy().into_owned());
        Workspace {
            id: id_for(&path),
            path,
            name,
            added_at_ms,
        }
    }

    /// Whether the folder is still there.
    ///
    /// A workspace whose folder is gone is kept and marked, not deleted. The
    /// user added it deliberately, and an unplugged external disk or a
    /// not-yet-mounted network share is not a decision to forget it.
    pub fn exists(&self) -> bool {
        self.path.is_dir()
    }
}

/// Identify a workspace by its path.
///
/// Not a hash: a readable id is far easier to follow in a log or a protocol
/// trace, and this never leaves the machine.
fn id_for(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// The registered set, persisted as JSON.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Registry {
    #[serde(default)]
    pub workspaces: Vec<Workspace>,
}

impl Registry {
    pub fn default_path() -> Result<PathBuf, RegistryError> {
        let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .ok_or(RegistryError::NoDataDir)?;
        Ok(dirs.data_dir().join("workspaces.json"))
    }

    /// Load, treating a missing file as an empty registry.
    ///
    /// A corrupt file is an error rather than a silent reset: quietly starting
    /// over would drop a user's list of folders without telling them.
    pub fn load_from(path: &Path) -> Result<Registry, RegistryError> {
        match std::fs::read_to_string(path) {
            Ok(s) => Ok(serde_json::from_str(&s)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Registry::default()),
            Err(source) => Err(RegistryError::Io {
                path: path.to_path_buf(),
                source,
            }),
        }
    }

    pub fn load() -> Result<Registry, RegistryError> {
        Self::load_from(&Self::default_path()?)
    }

    /// Write via a temporary file and a rename, so a crash mid-write cannot
    /// leave a half-written list where a whole one used to be.
    pub fn save_to(&self, path: &Path) -> Result<(), RegistryError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| RegistryError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let tmp = path.with_extension("json.tmp");
        let body = serde_json::to_string_pretty(self)?;
        std::fs::write(&tmp, body).map_err(|source| RegistryError::Io {
            path: tmp.clone(),
            source,
        })?;
        std::fs::rename(&tmp, path).map_err(|source| RegistryError::Io {
            path: path.to_path_buf(),
            source,
        })
    }

    pub fn save(&self) -> Result<(), RegistryError> {
        self.save_to(&Self::default_path()?)
    }

    /// Register a folder. Adding one twice is a no-op rather than an error,
    /// because a user dragging the same folder in again means "I want this",
    /// not "fail".
    pub fn add(&mut self, path: &Path, now_ms: i64) -> Result<Workspace, RegistryError> {
        if !path.is_dir() {
            return Err(RegistryError::NotAFolder(path.to_path_buf()));
        }
        // Resolve symlinks and `..` so the same folder reached two ways is one
        // workspace rather than two rows that disagree.
        let path = std::fs::canonicalize(path).map_err(|source| RegistryError::Io {
            path: path.to_path_buf(),
            source,
        })?;

        if let Some(existing) = self.workspaces.iter().find(|w| w.path == path) {
            return Ok(existing.clone());
        }
        let ws = Workspace::new(path, now_ms);
        self.workspaces.push(ws.clone());
        Ok(ws)
    }

    /// Forget a folder. Removes nothing from disk, ever.
    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.workspaces.len();
        self.workspaces.retain(|w| w.id != id);
        self.workspaces.len() != before
    }

    pub fn get(&self, id: &str) -> Option<&Workspace> {
        self.workspaces.iter().find(|w| w.id == id)
    }

    /// Rename for display. The folder is untouched.
    pub fn rename(&mut self, id: &str, name: &str) -> bool {
        match self.workspaces.iter_mut().find(|w| w.id == id) {
            Some(w) if !name.trim().is_empty() => {
                w.name = name.trim().to_string();
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-registry-{tag}-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::canonicalize(&dir).unwrap()
    }

    #[test]
    fn adding_the_same_folder_twice_is_one_workspace() {
        let dir = temp_dir("dup");
        let mut r = Registry::default();
        let a = r.add(&dir, 1).unwrap();
        let b = r.add(&dir, 2).unwrap();
        assert_eq!(r.workspaces.len(), 1);
        assert_eq!(a.id, b.id);
    }

    #[test]
    fn a_folder_reached_two_ways_is_one_workspace() {
        // `/tmp/x/../x` and `/tmp/x` are the same folder. Two rows that
        // disagree about the same directory would be worse than useless.
        let dir = temp_dir("canon");
        let indirect = dir.join("..").join(dir.file_name().unwrap());
        let mut r = Registry::default();
        r.add(&dir, 1).unwrap();
        r.add(&indirect, 2).unwrap();
        assert_eq!(r.workspaces.len(), 1);
    }

    #[test]
    fn a_file_is_not_a_workspace() {
        let dir = temp_dir("file");
        let file = dir.join("not-a-dir.txt");
        std::fs::write(&file, b"x").unwrap();
        let mut r = Registry::default();
        assert!(r.add(&file, 1).is_err());
    }

    #[test]
    fn removing_forgets_the_entry_and_leaves_the_folder() {
        let dir = temp_dir("remove");
        let mut r = Registry::default();
        let ws = r.add(&dir, 1).unwrap();
        assert!(r.remove(&ws.id));
        assert!(r.workspaces.is_empty());
        assert!(dir.is_dir(), "removing a workspace must not touch the disk");
        assert!(!r.remove(&ws.id), "removing twice is not a success");
    }

    #[test]
    fn a_missing_folder_is_kept_and_marked() {
        // An unplugged disk is not a decision to forget the workspace.
        let dir = temp_dir("missing");
        let mut r = Registry::default();
        let ws = r.add(&dir, 1).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(!ws.exists());
        assert_eq!(r.workspaces.len(), 1);
    }

    #[test]
    fn a_round_trip_through_disk_keeps_everything() {
        let dir = temp_dir("roundtrip");
        let store = dir.join("workspaces.json");
        let mut r = Registry::default();
        r.add(&dir, 42).unwrap();
        r.save_to(&store).unwrap();

        let back = Registry::load_from(&store).unwrap();
        assert_eq!(back.workspaces.len(), 1);
        assert_eq!(back.workspaces[0].added_at_ms, 42);
        assert_eq!(back.workspaces[0].path, dir);
    }

    #[test]
    fn a_missing_file_loads_as_empty_but_a_corrupt_one_does_not() {
        let dir = temp_dir("corrupt");
        assert!(
            Registry::load_from(&dir.join("nothing.json"))
                .unwrap()
                .workspaces
                .is_empty()
        );

        // Silently starting over would drop the user's folders without saying
        // so, which is worse than refusing to load.
        let bad = dir.join("bad.json");
        std::fs::write(&bad, b"{ not json").unwrap();
        assert!(Registry::load_from(&bad).is_err());
    }

    #[test]
    fn renaming_changes_the_label_only() {
        let dir = temp_dir("rename");
        let mut r = Registry::default();
        let ws = r.add(&dir, 1).unwrap();
        assert!(r.rename(&ws.id, "  My Project  "));
        assert_eq!(r.get(&ws.id).unwrap().name, "My Project");
        assert_eq!(r.get(&ws.id).unwrap().path, dir);
        assert!(!r.rename(&ws.id, "   "), "an empty name is not a rename");
    }
}
