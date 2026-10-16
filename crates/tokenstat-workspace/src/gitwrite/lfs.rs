// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! LFS preflight belongs to explicit Git reviews, never status polling.
//! Setup runs only after the person accepts the action in the sync panel.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use super::lease::Lease;
use super::selected::{command, index_path, text};

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub installed: bool,
    pub configured: bool,
    pub can_install: bool,
}

impl Status {
    pub fn ready(&self) -> bool {
        self.installed && self.configured
    }
}

fn attributes_use_lfs(dir: &Path, revision: Option<&str>) -> bool {
    let mut args = vec![
        "grep",
        "-I",
        "-q",
        "-E",
        r"^[[:space:]]*[^#[:space:]].*[[:space:]]filter=lfs([[:space:]]|$)",
    ];
    if let Some(revision) = revision {
        if revision.starts_with('-') {
            return false;
        }
        args.push(revision);
    }
    args.extend(["--", ":(glob)**/.gitattributes"]);
    command(dir, &args)
        .env_remove("GIT_LITERAL_PATHSPECS")
        .output()
        .is_ok_and(|out| out.status.success())
}

fn installed(dir: &Path) -> bool {
    command(dir, &["lfs", "version"])
        .output()
        .is_ok_and(|out| out.status.success())
}

/// Resolve effective attributes too: .git/info/attributes, global attribute
/// files and macros can enable LFS without a tracked filter=lfs declaration.
fn tracked_files_use_lfs(dir: &Path) -> bool {
    let Ok(mut files) = command(dir, &["ls-files", "-z", "--cached"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let paths = files.stdout.take().expect("piped Git file list");
    // Connect the processes directly so a large index cannot deadlock while
    // one side writes its input and the other writes attribute results.
    let attributes = command(dir, &["check-attr", "-z", "--stdin", "filter"])
        .stdin(paths)
        .output();
    if attributes.is_err() {
        let _ = files.kill();
    }
    let listed = files.wait().is_ok_and(|status| status.success());
    attributes.is_ok_and(|out| {
        listed
            && out.status.success()
            && out
                .stdout
                .split(|byte| *byte == 0)
                .skip(2)
                .step_by(3)
                .any(|value| value == b"lfs")
    })
}

/// Read both the checkout and the commit about to be checked out. Incoming
/// attributes can introduce LFS even when the current branch never used it.
pub fn status(dir: &Path, revision: Option<&str>) -> Option<Status> {
    if !attributes_use_lfs(dir, None)
        && !attributes_use_lfs(dir, revision)
        && !lfs_hook(dir)
        && !tracked_files_use_lfs(dir)
    {
        return None;
    }
    Some(inspect(dir))
}

fn inspect(dir: &Path) -> Status {
    let installed = installed(dir);
    let filters = [
        "filter.lfs.clean",
        "filter.lfs.smudge",
        "filter.lfs.process",
    ]
    .iter()
    .all(|key| text(dir, &["config", "--get", key]).is_ok_and(|value| !value.is_empty()));
    let required = text(dir, &["config", "--bool", "--get", "filter.lfs.required"])
        .is_ok_and(|value| value == "true");
    Status {
        installed,
        configured: filters && required,
        can_install: !installed && installer(dir).is_some(),
    }
}

fn lfs_hook(dir: &Path) -> bool {
    text(dir, &["rev-parse", "--git-path", "hooks/pre-push"])
        .ok()
        .map(|path| dir.join(path))
        .and_then(|path| std::fs::read_to_string(path).ok())
        .is_some_and(|body| body.contains("git lfs pre-push") || body.contains("git-lfs pre-push"))
}

pub(super) fn ensure_ready(dir: &Path, revision: &str) -> Result<(), String> {
    match status(dir, Some(revision)) {
        Some(status) if !status.installed => Err("This repository uses Git LFS, but Git LFS is not installed on this computer. Set up Git LFS in the Pull or Push panel, then review the branch again.".into()),
        Some(status) if !status.configured => Err("This repository needs Git LFS setup. Enable Git LFS in the Pull or Push panel, then review the branch again.".into()),
        _ => Ok(()),
    }
}

/// Upload exactly the reviewed ref's LFS objects before sending its Git ref.
/// Existing hooks still run normally; an unrelated/custom hook need not be
/// rewritten or trusted to perform the LFS upload on the app's behalf.
pub(super) fn pre_push(
    dir: &Path,
    reviewed: &super::reviewed_push::Review,
    url: &str,
) -> Result<(), String> {
    if status(dir, Some(&reviewed.head)).is_none() {
        return Ok(());
    }
    let zeros = "0".repeat(reviewed.head.len());
    let remote_head = reviewed.remote_head.as_deref().unwrap_or(&zeros);
    let input = format!(
        "{} {} {} {}\n",
        reviewed.branch, reviewed.head, reviewed.remote_ref, remote_head
    );
    // The URL is the same pinned endpoint Git push will use. LFS maps that
    // address to its configured remote, just as in Git's native pre-push hook.
    let mut child = command(dir, &["lfs", "pre-push", "--", url, url])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    let write = child
        .stdin
        .take()
        .ok_or("Git LFS did not accept the reviewed ref.")?
        .write_all(input.as_bytes());
    let out = child
        .wait_with_output()
        .map_err(|error| error.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "Git LFS could not upload the reviewed files. {}",
            super::GitOutcome::from(out).message
        ));
    }
    write.map_err(|error| error.to_string())
}

/// Homebrew installation is offered only when Homebrew already exists.
/// Other hosts get the standard installation guide, without a hidden sudo.
fn installer(dir: &Path) -> Option<Command> {
    #[cfg(target_os = "macos")]
    {
        let mut brew = Command::new("brew");
        if let Some(path) =
            crate::git_environment::executable_path(std::env::var_os("PATH").as_deref())
        {
            brew.env("PATH", path);
        }
        brew.current_dir(dir)
            .env("HOMEBREW_NO_AUTO_UPDATE", "1")
            .env("NONINTERACTIVE", "1");
        if brew
            .arg("--version")
            .output()
            .is_ok_and(|out| out.status.success())
        {
            let mut install = Command::new("brew");
            install.envs(
                brew.get_envs()
                    .filter_map(|(key, value)| value.map(|value| (key, value))),
            );
            install.current_dir(dir).args(["install", "git-lfs"]);
            return Some(install);
        }
    }
    let _ = dir;
    None
}

/// The explicit enable action replaces only repository-local LFS filters.
/// Never force installation over an existing hook or change global filters.
pub fn setup(dir: &Path, allow_install: bool) -> Result<Status, String> {
    let _lease = Lease::acquire(&index_path(dir)?.with_file_name("tokenstat-git-operation.lock"))?;
    if !installed(dir) {
        if !allow_install {
            return Err("Git LFS is no longer available. Check the branch again and choose Install and enable Git LFS to allow installation.".into());
        }
        let mut installer = installer(dir).ok_or(
            "Install Git LFS on this computer from https://git-lfs.com, then choose Check again.",
        )?;
        let out = installer.output().map_err(|error| error.to_string())?;
        if !out.status.success() {
            return Err(super::GitOutcome::from(out).message);
        }
    }
    let scope = if text(
        dir,
        &["config", "--bool", "--get", "extensions.worktreeConfig"],
    )
    .is_ok_and(|value| value == "true")
    {
        "--worktree"
    } else {
        "--local"
    };
    let filters = command(dir, &["lfs", "install", scope, "--force", "--skip-repo"])
        .output()
        .map_err(|error| error.to_string())?;
    if !filters.status.success() {
        return Err(super::GitOutcome::from(filters).message);
    }
    // --skip-repo preserves custom and shared hooks. Reviewed pushes perform
    // the LFS pre-push explicitly, so no hook installation is needed here.
    Ok(inspect(dir))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        text(dir.path(), &["init", "-q"]).unwrap();
        text(dir.path(), &["config", "core.hooksPath", ".git/hooks"]).unwrap();
        dir
    }

    #[test]
    fn ordinary_repositories_do_not_need_lfs() {
        let dir = repo();
        fs::write(
            dir.path().join(".gitattributes"),
            "# Example: *.bin filter=lfs\n*.txt text\n",
        )
        .unwrap();
        text(dir.path(), &["add", ".gitattributes"]).unwrap();
        assert!(status(dir.path(), None).is_none());
    }

    #[test]
    fn nested_attributes_are_detected_and_setup_preserves_existing_hooks() {
        let dir = repo();
        fs::create_dir(dir.path().join("assets")).unwrap();
        fs::write(
            dir.path().join("assets/.gitattributes"),
            "*.bin filter=lfs diff=lfs merge=lfs -text\n",
        )
        .unwrap();
        text(dir.path(), &["add", "assets/.gitattributes"]).unwrap();
        let before = status(dir.path(), None).expect("nested LFS attributes");
        if !before.installed {
            return;
        }
        let hook = dir.path().join(".git/hooks/pre-push");
        let body = "#!/bin/sh\necho custom-hook\n";
        fs::write(&hook, body).unwrap();
        assert!(setup(dir.path(), false).unwrap().ready());
        assert_eq!(fs::read_to_string(&hook).unwrap(), body);
        fs::remove_file(hook).unwrap();
        assert!(setup(dir.path(), false).unwrap().ready());
        assert!(!dir.path().join(".git/hooks/pre-push").exists());
        assert!(status(dir.path(), None).unwrap().ready());
    }

    #[test]
    fn repository_private_attributes_are_detected() {
        let dir = repo();
        fs::write(dir.path().join("asset.bin"), "existing file").unwrap();
        text(dir.path(), &["add", "asset.bin"]).unwrap();
        fs::write(
            dir.path().join(".git/info/attributes"),
            "*.bin filter=lfs\n",
        )
        .unwrap();
        assert!(status(dir.path(), None).is_some());
    }

    #[test]
    fn setup_repairs_worktree_overrides_without_replacing_shared_filters() {
        let dir = repo();
        if !installed(dir.path()) {
            return;
        }
        text(dir.path(), &["config", "extensions.worktreeConfig", "true"]).unwrap();
        text(
            dir.path(),
            &["config", "--local", "filter.lfs.process", "shared-filter"],
        )
        .unwrap();
        text(
            dir.path(),
            &["config", "--worktree", "filter.lfs.process", ""],
        )
        .unwrap();
        assert!(!inspect(dir.path()).ready());
        assert!(setup(dir.path(), false).unwrap().ready());
        assert_eq!(
            text(
                dir.path(),
                &["config", "--local", "--get", "filter.lfs.process"]
            )
            .unwrap(),
            "shared-filter"
        );
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn desktop_path_keeps_existing_choices_and_adds_homebrew_for_hooks() {
        let path = crate::git_environment::executable_path(Some(std::ffi::OsStr::new(
            "/custom/bin:/usr/bin:/bin",
        )))
        .unwrap();
        let paths: Vec<_> = std::env::split_paths(&path).collect();
        assert_eq!(paths[0], Path::new("/custom/bin"));
        for expected in ["/opt/homebrew/bin", "/usr/local/bin"] {
            assert!(paths.contains(&Path::new(expected).to_path_buf()));
        }
        assert_eq!(
            paths
                .iter()
                .filter(|path| **path == Path::new("/usr/bin"))
                .count(),
            1
        );
        let dir = repo();
        let out = command(dir.path(), &["lfs", "version"])
            .env("PATH", path)
            .output()
            .unwrap();
        if Path::new("/opt/homebrew/bin/git-lfs").exists()
            || Path::new("/usr/local/bin/git-lfs").exists()
        {
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
    }
}
