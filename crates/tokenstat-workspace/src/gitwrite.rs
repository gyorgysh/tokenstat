//! Git commands that change something.
//!
//! Deliberately a separate module from [`crate::git`], which stays read-only.
//! The split is the safety property: `git.rs` runs on a file-change timer and
//! on every workspace list, so nothing in it may ever mutate. Everything here
//! runs because a person pressed a button, once, and never from a timer, a
//! watcher, or a status path.
//!
//! Keep that shape. If a caller wants one of these on a schedule, the answer is
//! no, not a new function here.

use std::path::Path;
use std::process::Command;

use serde::Serialize;

/// What a mutating command reported.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitOutcome {
    pub ok: bool,
    /// What git printed. Shown verbatim on failure: git's own messages name
    /// the file, the hook, or the conflict, and any rewording loses that.
    pub message: String,
}

impl GitOutcome {
    fn from(out: std::process::Output) -> Self {
        let ok = out.status.success();
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        let message = if stderr.trim().is_empty() {
            stdout.trim().to_string()
        } else {
            stderr.trim().to_string()
        };
        Self { ok, message }
    }

    fn failed(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
        }
    }
}

/// Run a git command that changes the repository.
///
/// `GIT_TERMINAL_PROMPT=0` matters more here than in the read-only module: a
/// push that wants a password must fail with a message the window can show,
/// not block forever on a terminal that does not exist.
fn git(dir: &Path, args: &[&str]) -> GitOutcome {
    match Command::new("git")
        .arg("-C")
        .arg(dir)
        .env("GIT_PAGER", "cat")
        .env("GIT_TERMINAL_PROMPT", "0")
        .args(args)
        .output()
    {
        Ok(out) => GitOutcome::from(out),
        Err(e) => GitOutcome::failed(format!("could not run git: {e}")),
    }
}

/// Stage paths. Staging nothing is refused rather than treated as "stage all",
/// because those are very different commits.
pub fn stage(dir: &Path, paths: &[String]) -> GitOutcome {
    if paths.is_empty() {
        return GitOutcome::failed("nothing was selected to stage");
    }
    let mut args = vec!["add", "--"];
    args.extend(paths.iter().map(String::as_str));
    git(dir, &args)
}

/// Unstage paths, leaving the working tree alone.
///
/// `restore --staged` and not `reset`: it only ever touches the index, so a
/// mis-click cannot discard someone's edits.
pub fn unstage(dir: &Path, paths: &[String]) -> GitOutcome {
    if paths.is_empty() {
        return GitOutcome::failed("nothing was selected to unstage");
    }
    let mut args = vec!["restore", "--staged", "--"];
    args.extend(paths.iter().map(String::as_str));
    git(dir, &args)
}

/// Commit what is staged.
///
/// The message is passed as an argument rather than through an editor, and an
/// empty one is refused here rather than left to git, which would open one.
pub fn commit(dir: &Path, message: &str) -> GitOutcome {
    if message.trim().is_empty() {
        return GitOutcome::failed("a commit needs a message");
    }
    git(dir, &["commit", "-m", message])
}

/// Push the current branch, setting the upstream when it has none.
///
/// No force, ever, and no flag to ask for one. A force push is not something to
/// offer behind a button in a side panel.
pub fn push(dir: &Path) -> GitOutcome {
    let has_upstream = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--abbrev-ref", "@{upstream}"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if has_upstream {
        git(dir, &["push"])
    } else {
        git(dir, &["push", "--set-upstream", "origin", "HEAD"])
    }
}

/// Write one text file after an explicit Save action in the editor.
///
/// The path is checked against the canonical workspace root, so a symlink
/// cannot turn an editor save into a write outside the folder the user chose.
pub fn write_text(dir: &Path, relative: &str, content: &str) -> GitOutcome {
    let path = match crate::tree::resolve(dir, relative) {
        Ok(path) => path,
        Err(error) => return GitOutcome::failed(error.to_string()),
    };
    match std::fs::write(path, content) {
        Ok(()) => GitOutcome {
            ok: true,
            message: "Saved".into(),
        },
        Err(error) => GitOutcome::failed(format!("could not save file: {error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-gitwrite-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let run = |args: &[&str]| {
            Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .expect("git must be installed to run this test")
        };
        run(&["init", "-q", "."]);
        run(&["config", "user.email", "t@example.invalid"]);
        run(&["config", "user.name", "t"]);
        std::fs::write(dir.join("seed.txt"), "seed\n").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-qm", "init"]);
        dir
    }

    #[test]
    fn staging_then_committing_lands_a_commit() {
        let dir = repo("commit");
        std::fs::write(dir.join("a.txt"), "hello\n").unwrap();

        assert!(stage(&dir, &["a.txt".into()]).ok);
        let status = crate::git::status(&dir);
        assert!(status.files.iter().any(|f| f.path == "a.txt"));

        assert!(commit(&dir, "feat: add a").ok);
        let log = crate::git::log(&dir, 1);
        assert_eq!(log[0].subject, "feat: add a");
        // And the tree is clean again, which is the actual proof it committed.
        assert!(crate::git::status(&dir).files.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unstaging_keeps_the_edit() {
        // The reason this uses `restore --staged` rather than `reset`: a
        // mis-click must never be able to throw away someone's work.
        let dir = repo("unstage");
        std::fs::write(dir.join("seed.txt"), "seed\nedited\n").unwrap();
        assert!(stage(&dir, &["seed.txt".into()]).ok);
        assert!(unstage(&dir, &["seed.txt".into()]).ok);

        let content = std::fs::read_to_string(dir.join("seed.txt")).unwrap();
        assert_eq!(content, "seed\nedited\n", "the edit must survive unstaging");
        assert!(
            crate::git::status(&dir)
                .files
                .iter()
                .any(|f| f.path == "seed.txt")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_message_is_refused_rather_than_opening_an_editor() {
        let dir = repo("empty-message");
        let outcome = commit(&dir, "   ");
        assert!(!outcome.ok);
        assert!(outcome.message.contains("message"), "{}", outcome.message);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn staging_nothing_is_refused_rather_than_staging_everything() {
        let dir = repo("empty-stage");
        std::fs::write(dir.join("b.txt"), "x\n").unwrap();
        assert!(!stage(&dir, &[]).ok);
        // Nothing was staged as a side effect.
        assert!(
            crate::git::status(&dir)
                .files
                .iter()
                .any(|f| f.path == "b.txt")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_failure_carries_gits_own_words() {
        let dir = repo("failure");
        // Nothing staged, so git refuses and explains why. That explanation is
        // what the window shows, so it has to survive the round trip.
        let outcome = commit(&dir, "feat: nothing");
        assert!(!outcome.ok);
        assert!(!outcome.message.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writing_text_stays_inside_the_workspace() {
        let dir = repo("write-text");
        assert!(write_text(&dir, "seed.txt", "updated\n").ok);
        assert_eq!(
            std::fs::read_to_string(dir.join("seed.txt")).unwrap(),
            "updated\n"
        );
        assert!(!write_text(&dir, "../outside.txt", "nope").ok);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
