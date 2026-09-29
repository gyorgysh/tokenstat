// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Explicit creation of isolated working folders. Never called by a watcher.

use std::path::Path;

use super::{GitOutcome, git_command};

/// Create a new branch in a new working folder. Both the namespace and short
/// name are chosen by the caller; existing branches or directories are never
/// reused or overwritten. The caller owns destination access authorization.
pub fn create(
    repository: &Path,
    destination: &Path,
    namespace: &str,
    name: &str,
    base: &str,
) -> GitOutcome {
    let branch = match branch_name(namespace, name) {
        Ok(branch) => branch,
        Err(message) => return GitOutcome::failed(message),
    };
    if !destination.is_absolute() || destination.symlink_metadata().is_ok() {
        return GitOutcome::failed("Choose a new absolute folder path for this worktree.");
    }
    let valid = git_command(repository)
        .args(["check-ref-format", "--branch", &branch])
        .output();
    if !valid.is_ok_and(|out| out.status.success()) {
        return GitOutcome::failed("Choose a valid branch namespace and name.");
    }
    let revision = format!("{base}^{{commit}}");
    let resolved = match git_command(repository)
        .args(["rev-parse", "--verify", "--end-of-options", &revision])
        .output()
    {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_owned(),
        _ => return GitOutcome::failed("The starting branch or commit is unavailable."),
    };
    match git_command(repository)
        .args(["worktree", "add", "-b", &branch, "--"])
        .arg(destination)
        .arg(resolved)
        .output()
    {
        Ok(out) => GitOutcome::from(out),
        Err(error) => GitOutcome::failed(format!("Could not create the worktree: {error}")),
    }
}

/// A namespace is a branch prefix, never a path. Reject revision shorthand
/// before handing it to Git so values such as @{-1} cannot select old work.
fn branch_name(namespace: &str, name: &str) -> Result<String, &'static str> {
    let invalid = |part: &str| {
        part.starts_with('-')
            || part.contains('@')
            || part.contains('\\')
            || part.chars().any(char::is_control)
            || part
                .split('/')
                .any(|segment| segment.is_empty() || segment == "." || segment == "..")
    };
    if name.trim() != name
        || name.is_empty()
        || invalid(name)
        || (!namespace.is_empty() && (namespace.trim() != namespace || invalid(namespace)))
    {
        return Err("Use a branch name and optional namespace, such as feature / improved-search.");
    }
    Ok(if namespace.is_empty() {
        name.to_owned()
    } else {
        format!("{namespace}/{name}")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repository() -> tempfile::TempDir {
        let directory = tempfile::tempdir().expect("fixture directory");
        assert!(
            git_command(directory.path())
                .args(["init", "-q"])
                .status()
                .expect("git")
                .success()
        );
        assert!(
            git_command(directory.path())
                .args([
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "commit",
                    "--allow-empty",
                    "-qm",
                    "Initial fixture",
                ])
                .status()
                .expect("fixture commit")
                .success()
        );
        directory
    }

    #[test]
    fn creates_isolated_namespaced_branch_without_switching_original() {
        let repository = repository();
        let parent = tempfile::tempdir().expect("destination parent");
        let destination = parent.path().join("isolated folder");
        let before = git_command(repository.path())
            .args(["symbolic-ref", "HEAD"])
            .output()
            .expect("branch")
            .stdout;
        let outcome = create(
            repository.path(),
            &destination,
            "team/feature",
            "search",
            "HEAD",
        );
        assert!(outcome.ok, "{}", outcome.message);
        assert_eq!(
            git_command(repository.path())
                .args(["symbolic-ref", "HEAD"])
                .output()
                .expect("branch")
                .stdout,
            before
        );
        let branch = git_command(&destination)
            .args(["branch", "--show-current"])
            .output()
            .expect("worktree branch");
        assert_eq!(
            String::from_utf8_lossy(&branch.stdout).trim(),
            "team/feature/search"
        );
        let listed = crate::git::worktrees(repository.path()).expect("list worktrees");
        assert_eq!(listed.len(), 2);
        assert!(
            listed
                .iter()
                .any(|tree| tree.branch.as_deref() == Some("team/feature/search")
                    && Path::new(&tree.path)
                        == destination.canonicalize().expect("canonical destination")
                    && !tree.bare
                    && !tree.locked)
        );
        assert!(
            !create(
                repository.path(),
                &parent.path().join("duplicate"),
                "team/feature",
                "search",
                "HEAD"
            )
            .ok
        );
        assert!(!parent.path().join("duplicate").exists());
    }

    #[test]
    fn rejects_existing_paths_invalid_names_and_missing_base() {
        let repository = repository();
        let parent = tempfile::tempdir().expect("parent");
        std::fs::write(parent.path().join("keep.txt"), "keep").expect("fixture");
        assert!(!create(repository.path(), parent.path(), "feature", "safe", "HEAD").ok);
        for name in ["../escape", "@{-1}", "--force", "bad name", "a//b", ""] {
            assert!(
                !create(
                    repository.path(),
                    &parent.path().join("new"),
                    "feature",
                    name,
                    "HEAD"
                )
                .ok
            );
        }
        assert!(
            !create(
                repository.path(),
                &parent.path().join("new"),
                "feature",
                "safe",
                "missing-revision"
            )
            .ok
        );
        assert_eq!(
            std::fs::read_to_string(parent.path().join("keep.txt")).expect("fixture"),
            "keep"
        );
        assert!(!parent.path().join("new").exists());
    }
}
