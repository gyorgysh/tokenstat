//! The file tree of a workspace folder.
//!
//! **Read only, like everything else about a user's project.** This module
//! lists directories. It does not create, move, rename, or delete anything, and
//! it must not grow a function that does.
//!
//! One directory per call rather than a whole recursive walk. A monorepo has
//! hundreds of thousands of files and nobody is looking at more than one level
//! of them at a time, so the tree expands as it is opened.

use std::path::{Component, Path, PathBuf};

use serde::Serialize;

/// One entry in a directory.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeEntry {
    pub name: String,
    /// Path relative to the workspace root, with `/` separators.
    pub path: String,
    pub is_dir: bool,
    /// True when git would ignore this. Listed rather than hidden, because
    /// `target/` and a generated project file are things people look for. The
    /// view dims them.
    pub ignored: bool,
}

/// Why a directory could not be listed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TreeError {
    /// The path escaped the workspace, or was absolute.
    Outside,
    /// The directory is not there, or is not a directory.
    Unreadable(String),
}

impl std::fmt::Display for TreeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Outside => write!(f, "that path is outside the workspace"),
            Self::Unreadable(e) => write!(f, "could not read the directory: {e}"),
        }
    }
}

/// List one directory of a workspace, directories first then files, each
/// alphabetically and case insensitively, which is the order people scan in.
///
/// `relative` is empty for the workspace root. It is resolved against the root
/// and rejected if it climbs out, so a caller cannot walk the whole disk by
/// asking for `../../..`. That check is the reason this takes a relative path
/// rather than an absolute one.
pub fn list(root: &Path, relative: &str) -> Result<Vec<TreeEntry>, TreeError> {
    let dir = resolve(root, relative)?;

    let mut entries = Vec::new();
    let read = std::fs::read_dir(&dir).map_err(|e| TreeError::Unreadable(e.to_string()))?;
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        // `.git` is machinery, not project content, and expanding it is never
        // what anyone wanted.
        if name == ".git" {
            continue;
        }
        // `file_type` does not follow symlinks, so a link to a directory is
        // reported as a link. Ask the target instead: a linked folder should
        // open like the folder it is.
        let is_dir = entry
            .metadata()
            .map(|m| m.is_dir())
            .unwrap_or(entry.file_type().map(|t| t.is_dir()).unwrap_or(false));
        let path = if relative.is_empty() {
            name.clone()
        } else {
            format!("{}/{}", relative.trim_end_matches('/'), name)
        };
        entries.push(TreeEntry {
            name,
            path,
            is_dir,
            ignored: false,
        });
    }

    mark_ignored(root, &mut entries);

    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(entries)
}

/// Resolve a relative path inside the root, refusing anything that leaves it.
///
/// Rejects absolute paths, `..`, and anything a symlink would redirect out of
/// the workspace: the final check is against the canonical root, so a link
/// pointing at `/etc` cannot be listed through a workspace.
fn resolve(root: &Path, relative: &str) -> Result<PathBuf, TreeError> {
    let relative = relative.trim();
    if relative.is_empty() {
        return Ok(root.to_path_buf());
    }
    // An absolute path is refused rather than quietly reinterpreted as a
    // relative one. Stripping the leading slash would turn `/etc` into a lookup
    // for `<workspace>/etc`, which answers a question nobody asked.
    let candidate = Path::new(relative);
    if candidate.is_absolute()
        || candidate
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err(TreeError::Outside);
    }

    let joined = root.join(candidate);
    // Canonicalize both sides: the textual check above stops `..`, and this
    // stops a symlink from doing the same thing without the characters.
    let real = joined
        .canonicalize()
        .map_err(|e| TreeError::Unreadable(e.to_string()))?;
    let real_root = root
        .canonicalize()
        .map_err(|e| TreeError::Unreadable(e.to_string()))?;
    if !real.starts_with(&real_root) {
        return Err(TreeError::Outside);
    }
    Ok(real)
}

/// Flag the entries git would ignore.
///
/// One `check-ignore` for the whole directory rather than one per entry. It
/// exits 1 when nothing matched, which is a normal answer and not a failure, so
/// this cannot use the shared helper in [`crate::git`] that treats a non-zero
/// status as "no output".
fn mark_ignored(root: &Path, entries: &mut [TreeEntry]) {
    use std::io::Write;
    use std::process::{Command, Stdio};

    if entries.is_empty() {
        return;
    }

    let mut child = match Command::new("git")
        .arg("-C")
        .arg(root)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .args(["check-ignore", "--stdin", "-z"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        // Not a repository, or no git. Nothing is ignored, which is the honest
        // answer rather than an error: a plain folder is a valid workspace.
        Err(_) => return,
    };

    if let Some(mut stdin) = child.stdin.take() {
        let payload: Vec<u8> = entries
            .iter()
            .flat_map(|e| {
                let mut b = e.path.clone().into_bytes();
                b.push(0);
                b
            })
            .collect();
        let _ = stdin.write_all(&payload);
    }

    let Ok(out) = child.wait_with_output() else {
        return;
    };
    let ignored: std::collections::HashSet<&[u8]> = out
        .stdout
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .collect();
    for entry in entries.iter_mut() {
        entry.ignored = ignored.contains(entry.path.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-tree-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::create_dir_all(dir.join("target")).unwrap();
        std::fs::write(dir.join("Cargo.toml"), "[package]\n").unwrap();
        std::fs::write(dir.join(".gitignore"), "target\n").unwrap();
        std::fs::write(dir.join("src/main.rs"), "fn main() {}\n").unwrap();
        dir
    }

    #[test]
    fn directories_come_first_and_names_sort_case_insensitively() {
        let dir = fixture();
        let entries = list(&dir, "").unwrap();
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();
        // Both directories, then both files. Not ASCII order, which would put
        // every capital letter above every lower case one.
        assert_eq!(names, vec!["src", "target", ".gitignore", "Cargo.toml"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_subdirectory_lists_with_paths_relative_to_the_root() {
        let dir = fixture();
        let entries = list(&dir, "src").unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "src/main.rs");
        assert!(!entries[0].is_dir);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn climbing_out_of_the_workspace_is_refused() {
        // The whole point of taking a relative path. A front end that passes
        // user input straight through must not be able to list the disk.
        let dir = fixture();
        for escape in ["..", "../..", "src/../..", "/etc"] {
            assert_eq!(
                list(&dir, escape).err(),
                Some(TreeError::Outside),
                "{escape} should have been refused"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ignored_entries_are_listed_and_marked() {
        let dir = fixture();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .expect("git must be installed to run this test")
        };
        run(&["init", "-q", "."]);

        let entries = list(&dir, "").unwrap();
        let target = entries.iter().find(|e| e.name == "target").unwrap();
        let src = entries.iter().find(|e| e.name == "src").unwrap();
        // Present, not hidden: `target/` is something people go looking for.
        assert!(target.ignored, "target is in .gitignore");
        assert!(!src.ignored);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_plain_folder_has_nothing_ignored() {
        let dir = fixture();
        let entries = list(&dir, "").unwrap();
        assert!(entries.iter().all(|e| !e.ignored));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
