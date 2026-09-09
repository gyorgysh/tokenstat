// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Picking a folder on a machine that has no file panel.
//!
//! `NSOpenPanel` cannot run on a phone and does not exist on a server, so the
//! machine answers the question instead: what is in this directory, which of
//! them are repositories, and which are already registered.
//!
//! Two rules hold it in. **No contents**: names, kinds and a few stat fields,
//! never a byte of a file. And **roots**: the home directory and the parent of
//! every registered folder are what may be browsed, and a path outside them is
//! refused here rather than hidden by the client. A client cannot be the
//! enforcement, because the client is the thing on the other side of the
//! tunnel.

use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{Value, json};

/// Entries returned for one directory before the answer says so and stops.
///
/// A home directory with a node_modules tree in it can hold hundreds of
/// thousands of names, and a picker cannot draw them anyway.
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

/// Where browsing may start, and everything it may reach.
///
/// The home directory, because that is where somebody's work lives, and the
/// parent of every registered folder, because a folder that is already trusted
/// enough to open is one whose neighbours are worth offering.
fn roots() -> Vec<(PathBuf, String, &'static str)> {
    let mut roots = Vec::new();
    if let Some(home) = home() {
        roots.push((home, "Home".to_string(), "home"));
    }
    for folder in crate::workspaces::read().workspaces.iter() {
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

/// The real path, and whether it is inside something browsable.
///
/// Canonicalized first, so a symlink out of a root is checked where it lands
/// rather than where it is written. `..` is resolved by the same call.
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
/// A clone lands where browsing would have shown it, and nowhere else.
pub(crate) fn resolve_root(path: &Path) -> Result<PathBuf, String> {
    resolve(path, &roots())
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

/// The listing itself, with what may be browsed passed in.
///
/// Separate from [`browse`] so the containment rule can be tested against a
/// tree a test owns, rather than against whatever is in the home directory of
/// the machine running the suite.
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
        // One unreadable entry is skipped rather than failing the listing: a
        // directory somebody cannot stat is exactly the kind of thing a home
        // directory has one of.
        let Ok(entry) = entry else { continue };
        if entries.len() >= MAX_ENTRIES {
            truncated = true;
            break;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        let link = entry.file_type().is_ok_and(|kind| kind.is_symlink());
        let Ok(meta) = std::fs::metadata(&path) else {
            // A link with nothing at the end of it. Worth showing, because
            // that is a fact about the folder, and not worth stat-ing further.
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
            "path": path,
            "kind": if directory { "directory" } else { "file" },
            "symlink": link,
            "hidden": name.starts_with('.'),
            "isRepo": directory && path.join(".git").exists(),
            "isRegistered": registered.contains(&path),
            "size": (!directory).then_some(meta.len()),
            "modified": meta
                .modified()
                .ok()
                .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|since| since.as_millis() as u64),
        }));
    }
    // Folders first, then by name without case getting in the way. The picker
    // shows what it is given, so the order is decided once, here.
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

    // A parent only exists when it is still somewhere this machine offers, so
    // "up" stops at a root instead of walking out of it and then being refused.
    let parent = start
        .parent()
        .and_then(|parent| resolve(parent, roots).ok());
    Ok(json!({
        "path": start,
        "parent": parent,
        "roots": roots
            .iter()
            .map(|(path, label, kind)| json!({"path": path, "label": label, "kind": kind}))
            .collect::<Vec<_>>(),
        "entries": entries,
        "truncated": truncated,
    }))
}

/// One directory, inside a root, so a clone has somewhere to land.
///
/// In `gitwrite`'s spirit: it exists because a person pressed a button. It
/// creates one level, never a tree, and never removes anything.
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
    // The name only, never a path: a caller must not be able to write two
    // levels up by asking for one folder called `../..`. Same gate as a clone
    // target, so odd names cannot arrive through this door either.
    tokenstat_workspace::gitwrite::validate_clone_name(&name)?;
    let target = parent.join(&name);
    std::fs::create_dir(&target)
        .map_err(|error| format!("Could not create {}: {error}", target.display()))?;
    Ok(json!({"path": target}))
}

#[cfg(test)]
mod tests {
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
        // `..` is resolved before the check, not after it.
        assert!(resolve(&inside.join("../.."), &roots).is_err());
        // And so is a link that points out of the root.
        let escape = root.join("escape");
        std::os::unix::fs::symlink(&outside, &escape).unwrap();
        assert!(resolve(&escape, &roots).is_err());
        // A path that is not there at all is not an error about permission.
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
        // Hidden is a flag, not a filter: the client decides.
        assert_eq!(entries[2]["hidden"], true);
        let file = &entries[3];
        assert_eq!(file["kind"], "file");
        assert_eq!(file["size"], 6);
        assert!(
            !serde_json::to_string(&listing).unwrap().contains("secret"),
            "a listing must never carry a file's contents"
        );
        // The top of a root has no parent to walk up to.
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
