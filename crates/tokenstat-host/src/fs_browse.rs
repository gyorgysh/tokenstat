// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Picking a folder on a machine that has no file panel.

use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{Value, json};

const MAX_ENTRIES: usize = 2000;

#[derive(Deserialize)]
struct BrowseParams {
    #[serde(default)]
    path: Option<String>,
}

#[derive(Deserialize)]
struct MkdirParams {
    path: String,
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "fs.browse" => browse(params),
        "fs.mkdir" => mkdir(params),
        _ => return None,
    })
}

fn roots() -> Vec<(PathBuf, String, &'static str)> {
    let mut roots = Vec::new();
    if let Some(home) = home() {
        roots.push((home, "Home".to_string(), "home"));
    }
    let is_general = crate::general_folder::matcher();
    for folder in crate::workspaces::read().workspaces.iter() {
        if is_general(folder) {
            continue;
        }
        let Some(parent) = folder.path.parent() else {
            continue;
        };
        let parent = parent
            .canonicalize()
            .unwrap_or_else(|_| parent.to_path_buf());
        if roots.iter().any(|(held, _, _)| *held == parent) {
            continue;
        }
        let label = parent
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| parent.display().to_string());
        roots.push((parent, label, "folder"));
    }
    roots
}

fn home() -> Option<PathBuf> {
    let home = directories::BaseDirs::new()?.home_dir().to_path_buf();
    Some(home.canonicalize().unwrap_or(home))
}

fn resolve(path: &Path, roots: &[(PathBuf, String, &'static str)]) -> Result<PathBuf, String> {
    let real = path
        .canonicalize()
        .map_err(|_| format!("There is no {} on this machine.", path.display()))?;
    if roots
        .iter()
        .any(|(root, _, _)| real == *root || real.starts_with(root))
    {
        return Ok(real);
    }
    Err("That folder is outside what this machine offers. Browse from home, or from a folder that is already registered.".into())
}

/// The same containment rule, for a caller outside this module.
///
/// A clone lands where browsing would have shown it, and nowhere else. The
/// check runs on canonical paths, and the answer drops the Windows verbatim
/// prefix that canonicalizing adds: git cannot create a worktree under
/// `\\?\C:\...`, and the project list should not show one either.
pub(crate) fn resolve_root(path: &Path) -> Result<PathBuf, String> {
    resolve(path, &roots()).map(plain)
}

fn plain(path: PathBuf) -> PathBuf {
    tokenstat_workspace::registry::plain_path(&path)
}

fn browse(params: &str) -> Result<Value, String> {
    let p: BrowseParams =
        serde_json::from_str(params.trim()).unwrap_or(BrowseParams { path: None });
    let registered: Vec<PathBuf> = crate::workspaces::read()
        .workspaces
        .iter()
        .map(|folder| folder.path.clone())
        .collect();
    browse_in(p.path.as_deref(), &roots(), &registered)
}

fn browse_in(
    path: Option<&str>,
    roots: &[(PathBuf, String, &'static str)],
    registered: &[PathBuf],
) -> Result<Value, String> {
    let start = match path.filter(|path| !path.is_empty()) {
        Some(path) => resolve(Path::new(path), roots)?,
        None => roots
            .first()
            .map(|(path, _, _)| path.clone())
            .ok_or("This machine has no home directory to browse.")?,
    };
    if !start.is_dir() {
        return Err(format!("{} is not a folder.", start.display()));
    }
    let mut entries: Vec<Value> = Vec::new();
    let mut truncated = false;
    let reader = std::fs::read_dir(&start)
        .map_err(|error| format!("Could not read {}: {error}", start.display()))?;
    for entry in reader {
        let Ok(entry) = entry else { continue };
        if entries.len() >= MAX_ENTRIES {
            truncated = true;
            break;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        let link = entry.file_type().is_ok_and(|kind| kind.is_symlink());
        let Ok(meta) = std::fs::metadata(&path) else {
            entries.push(json!({
                "name": name,
                "kind": "unreadable",
                "symlink": link,
                "hidden": name.starts_with('.'),
            }));
            continue;
        };
        let directory = meta.is_dir();
        entries.push(json!({
            "name": name,
            "path": plain(path.clone()),
            "kind": if directory { "directory" } else { "file" },
            "symlink": link,
            "hidden": name.starts_with('.'),
            "isRepo": directory && path.join(".git").exists(),
            "isRegistered": registered.iter().any(|registered| {
                let registered = registered.canonicalize().unwrap_or_else(|_| registered.clone());
                let candidate = path.canonicalize().unwrap_or_else(|_| path.clone());
                plain(registered) == plain(candidate)
            }),
            "size": (!directory).then_some(meta.len()),
            "modified": meta
                .modified()
                .ok()
                .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|since| since.as_millis() as u64),
        }));
    }

    entries.sort_by(|left, right| {
        let folder = |value: &Value| value["kind"].as_str() == Some("directory");
        folder(right).cmp(&folder(left)).then_with(|| {
            left["name"]
                .as_str()
                .unwrap_or_default()
                .to_lowercase()
                .cmp(&right["name"].as_str().unwrap_or_default().to_lowercase())
        })
    });

    let parent = start
        .parent()
        .and_then(|parent| resolve(parent, roots).ok());
    Ok(json!({
        "path": plain(start),
        "parent": parent.map(plain),
        "roots": roots
            .iter()
            .map(|(path, label, kind)| json!({"path": plain(path.clone()), "label": label, "kind": kind}))
            .collect::<Vec<_>>(),
        "entries": entries,
        "truncated": truncated,
    }))
}

fn mkdir(params: &str) -> Result<Value, String> {
    let p: MkdirParams = serde_json::from_str(params.trim()).map_err(|error| error.to_string())?;
    let path = PathBuf::from(&p.path);
    if path.is_dir() {
        return Err("There is already a folder there.".into());
    }
    let parent = path
        .parent()
        .ok_or("A new folder needs somewhere to go.")?
        .to_path_buf();
    let roots = roots();
    let parent = resolve(&parent, &roots)?;
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .ok_or("A new folder needs a name.")?;

    tokenstat_workspace::gitwrite::validate_clone_name(&name)?;
    let target = parent.join(&name);
    std::fs::create_dir(&target)
        .map_err(|error| format!("Could not create {}: {error}", target.display()))?;
    Ok(json!({"path": plain(target)}))
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_verbatim_drive_or_share_path_loses_its_prefix() {
        use std::path::PathBuf;
        let plain = super::plain;
        assert_eq!(
            plain(PathBuf::from(r"\\?\C:\Users\a\git")),
            PathBuf::from(r"C:\Users\a\git")
        );
        assert_eq!(
            plain(PathBuf::from(r"\\?\UNC\server\share\x")),
            PathBuf::from(r"\\server\share\x")
        );
        assert_eq!(
            plain(PathBuf::from(r"\\?\Volume{0000}\x")),
            PathBuf::from(r"\\?\Volume{0000}\x")
        );
        assert_eq!(
            plain(PathBuf::from(r"C:\Users\a")),
            PathBuf::from(r"C:\Users\a")
        );
        assert_eq!(
            plain(PathBuf::from("/Users/a/git")),
            PathBuf::from("/Users/a/git")
        );
    }

    use super::*;

    #[test]
    #[cfg(unix)]
    fn nothing_outside_a_root_is_reachable_however_it_is_spelled() {
        let temp = std::env::temp_dir()
            .canonicalize()
            .expect("a temp directory");
        let root = temp.join(format!("tokenstat-browse-{}", std::process::id()));
        let inside = root.join("inside");
        let outside = temp.join(format!("tokenstat-outside-{}", std::process::id()));
        std::fs::create_dir_all(&inside).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let roots = vec![(root.clone(), "Root".to_string(), "folder")];

        assert_eq!(resolve(&inside, &roots).unwrap(), inside);
        assert_eq!(resolve(&root, &roots).unwrap(), root);
        assert!(resolve(&outside, &roots).is_err());

        assert!(resolve(&inside.join("../.."), &roots).is_err());
        let escape = root.join("escape");
        std::os::unix::fs::symlink(&outside, &escape).unwrap();
        assert!(resolve(&escape, &roots).is_err());

        let missing = resolve(&root.join("absent"), &roots).unwrap_err();
        assert!(missing.contains("no "), "{missing}");

        std::fs::remove_dir_all(&root).unwrap();
        std::fs::remove_dir_all(&outside).unwrap();
    }

    #[test]
    fn a_listing_names_folders_first_and_never_a_files_contents() {
        let temp = std::env::temp_dir().canonicalize().unwrap();
        let root = temp.join(format!("tokenstat-listing-{}", std::process::id()));
        let repo = root.join("beta");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("Alpha")).unwrap();
        std::fs::write(root.join("notes.txt"), "secret").unwrap();
        std::fs::write(root.join(".hidden"), "").unwrap();
        let roots = vec![(root.clone(), "Root".to_string(), "folder")];

        let listing = browse_in(
            Some(root.to_str().unwrap()),
            &roots,
            std::slice::from_ref(&repo),
        )
        .unwrap();
        let entries = listing["entries"].as_array().unwrap();
        let names: Vec<&str> = entries
            .iter()
            .filter_map(|entry| entry["name"].as_str())
            .collect();
        assert_eq!(names, ["Alpha", "beta", ".hidden", "notes.txt"]);
        let beta = &entries[1];
        assert_eq!(beta["isRepo"], true);
        assert_eq!(beta["isRegistered"], true);
        assert_eq!(entries[0]["isRegistered"], false);
        assert_eq!(entries[2]["hidden"], true);
        let file = &entries[3];
        assert_eq!(file["kind"], "file");
        assert_eq!(file["size"], 6);
        assert!(
            !serde_json::to_string(&listing).unwrap().contains("secret"),
            "a listing must never carry a file's contents"
        );
        assert!(listing["parent"].is_null());
        assert!(browse_in(Some(root.join("notes.txt").to_str().unwrap()), &roots, &[]).is_err());

        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_new_folder_is_one_name_and_never_a_path() {
        for name in ["../escape", "a/b", ".", ".."] {
            let params = serde_json::to_string(&json!({"path": format!("/tmp/{name}")})).unwrap();
            assert!(mkdir(&params).is_err(), "{name} was accepted");
        }
    }
}
