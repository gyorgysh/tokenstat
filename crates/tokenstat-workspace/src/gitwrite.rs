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
    for path in paths {
        if let Err(error) = crate::tree::assert_relative_inside(path) {
            return GitOutcome::failed(error.to_string());
        }
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
    for path in paths {
        if let Err(error) = crate::tree::assert_relative_inside(path) {
            return GitOutcome::failed(error.to_string());
        }
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

/// Switch to a local branch, or create a tracking branch from a remote ref.
///
/// No stash, force, clean, or detach option exists here. A dirty tree that
/// cannot move is left exactly where it was and git's explanation is returned.
pub fn checkout(dir: &Path, name: &str, remote: bool) -> GitOutcome {
    if !valid_branch(dir, name) {
        return GitOutcome::failed("that is not a valid branch name");
    }
    if remote {
        git(dir, &["switch", "--track", name])
    } else {
        git(dir, &["switch", name])
    }
}

/// Create and switch to a branch from the current branch or a named start.
pub fn create_branch(dir: &Path, name: &str, from: Option<&str>) -> GitOutcome {
    let name = name.trim();
    if name.is_empty() || !valid_branch(dir, name) {
        return GitOutcome::failed("that is not a valid branch name");
    }
    match from.map(str::trim).filter(|value| !value.is_empty()) {
        // A start point is a revision, not a branch, so `check-ref-format`
        // cannot judge it. What it must not be is an option: git reads a
        // leading dash as one, and `--discard-changes` in this position
        // throws away every uncommitted change in the workspace.
        Some(start) if start.starts_with('-') => {
            GitOutcome::failed("that is not a valid starting point")
        }
        Some(start) => git(dir, &["switch", "-c", name, start]),
        None => git(dir, &["switch", "-c", name]),
    }
}

/// Fetch one GitHub pull-request head into a new local branch, then switch.
///
/// This never runs when a pull request is merely opened. It is the separate,
/// labelled checkout action and refuses to rewrite an existing local branch.
pub fn fetch_pull(dir: &Path, number: u32, branch: &str) -> GitOutcome {
    let branch = branch.trim();
    if number == 0 || branch.is_empty() || !valid_branch(dir, branch) {
        return GitOutcome::failed("that is not a valid local branch name");
    }
    let exists = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ])
        .status()
        .map(|status| status.success())
        .unwrap_or(false);
    if exists {
        return GitOutcome::failed(format!("a local branch named '{branch}' already exists"));
    }

    let source = format!("pull/{number}/head:refs/heads/{branch}");
    let fetched = git(dir, &["fetch", "origin", &source]);
    if !fetched.ok {
        return fetched;
    }
    let switched = git(dir, &["switch", branch]);
    if switched.ok {
        switched
    } else {
        GitOutcome::failed(format!(
            "The pull request was fetched as '{branch}', but git could not switch to it. {}",
            switched.message
        ))
    }
}

fn valid_branch(dir: &Path, name: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["check-ref-format", "--branch", name])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
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
        run(&["config", "commit.gpgSign", "false"]);
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
    fn creating_and_switching_branches_is_explicit() {
        let dir = repo("branches");
        let created = create_branch(&dir, "feature/picker", None);
        assert!(created.ok, "{}", created.message);

        let branch = Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(["branch", "--show-current"])
            .output()
            .unwrap();
        assert_eq!(
            String::from_utf8_lossy(&branch.stdout).trim(),
            "feature/picker"
        );

        let other = create_branch(&dir, "feature/other", None);
        assert!(other.ok, "{}", other.message);
        let switched = checkout(&dir, "feature/picker", false);
        assert!(switched.ok, "{}", switched.message);
        assert!(!create_branch(&dir, "-unsafe", None).ok);
    }

    #[test]
    fn fetching_a_pull_creates_a_new_branch_without_rewriting_one() {
        let source = repo("pull-source");
        let remote = std::env::temp_dir().join(format!(
            "tokenstat-gitwrite-{}-pull-remote.git",
            std::process::id()
        ));
        let client = std::env::temp_dir().join(format!(
            "tokenstat-gitwrite-{}-pull-client",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&remote);
        let _ = std::fs::remove_dir_all(&client);
        Command::new("git")
            .args(["init", "--bare", "-q"])
            .arg(&remote)
            .status()
            .unwrap();
        let pushed = Command::new("git")
            .arg("-C")
            .arg(&source)
            .args(["push", "-q"])
            .arg(&remote)
            .arg("HEAD:refs/heads/main")
            .arg("HEAD:refs/pull/7/head")
            .status()
            .unwrap();
        assert!(pushed.success());
        let head = Command::new("git")
            .arg("-C")
            .arg(&remote)
            .args(["symbolic-ref", "HEAD", "refs/heads/main"])
            .status()
            .unwrap();
        assert!(head.success());
        Command::new("git")
            .args(["clone", "-q"])
            .arg(&remote)
            .arg(&client)
            .status()
            .unwrap();

        let outcome = fetch_pull(&client, 7, "review/seven");
        assert!(outcome.ok, "{}", outcome.message);
        let branch = Command::new("git")
            .arg("-C")
            .arg(&client)
            .args(["branch", "--show-current"])
            .output()
            .unwrap();
        assert_eq!(
            String::from_utf8_lossy(&branch.stdout).trim(),
            "review/seven"
        );
        assert!(!fetch_pull(&client, 7, "review/seven").ok);

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(&remote);
        let _ = std::fs::remove_dir_all(&client);
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

/// What a clone should be run as, or why it will not be.
///
/// Separate from running it because a clone is the one mutating command this
/// product runs in a terminal rather than capturing: the progress belongs on
/// screen, and a clone that asks for a passphrase or an unknown host key has
/// to be answerable. So the host owns the pty and this owns the decision about
/// what is safe to hand git.
///
/// The checks are not decoration. `git clone` takes options before its
/// arguments, so a URL beginning with `-` is an option, and `--upload-pack=`
/// names a command to run on the far side. `ext::` is git's own escape hatch
/// for running an arbitrary command as a transport. Neither may arrive from a
/// caller, and both are refused by name rather than by hoping a parser catches
/// them.
pub fn clone_command(url: &str, name: &str) -> Result<Vec<String>, String> {
    let url = url.trim();
    if url.is_empty() {
        return Err("A clone needs an address.".into());
    }
    if url.starts_with('-') {
        return Err("That address starts with a dash, which git would read as an option.".into());
    }
    if url.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("That address has a space or a control character in it.".into());
    }
    let lower = url.to_ascii_lowercase();
    if lower.starts_with("ext::") {
        return Err("`ext::` addresses run a command of their own and are not accepted.".into());
    }
    let scheme_ok = ["https://", "http://", "ssh://", "git://"]
        .iter()
        .any(|scheme| lower.starts_with(scheme));
    // The scp-like form, `git@github.com:owner/repo.git`, which is what most
    // people paste. A colon after a host, and no scheme in front of it.
    let scp_like = !lower.contains("://")
        && url.split_once(':').is_some_and(|(host, path)| {
            !host.is_empty() && !path.is_empty() && !host.contains('/')
        });
    if !scheme_ok && !scp_like {
        return Err(
            "That does not look like a repository address. Use an https:// or ssh:// URL, or the git@host:owner/repo form."
                .into(),
        );
    }
    validate_clone_name(name)?;
    Ok(vec![
        "clone".into(),
        "--progress".into(),
        url.to_string(),
        name.to_string(),
    ])
}

/// The folder a clone lands in: one name, in the directory that was chosen.
pub fn validate_clone_name(name: &str) -> Result<(), String> {
    let bad = name.is_empty()
        || name.starts_with('-')
        || name.starts_with('.')
        || name.len() > 255
        || name.contains(['/', '\\'])
        || name.chars().any(|c| c.is_control());
    if bad {
        return Err("A folder name is one name, without a path in it.".into());
    }
    Ok(())
}

/// The folder name a repository address implies, for the field's placeholder.
pub fn name_from_url(url: &str) -> Option<String> {
    let trimmed = url.trim().trim_end_matches('/');
    let last = trimmed.rsplit(['/', ':']).next()?;
    let name = last.strip_suffix(".git").unwrap_or(last);
    validate_clone_name(name).ok().map(|()| name.to_string())
}

#[cfg(test)]
mod clone_tests {
    use super::*;

    #[test]
    fn a_clone_address_can_never_become_an_option_or_a_command() {
        assert_eq!(
            clone_command("https://github.com/o/r.git", "r").unwrap(),
            ["clone", "--progress", "https://github.com/o/r.git", "r"]
        );
        assert!(clone_command("git@github.com:o/r.git", "r").is_ok());
        assert!(clone_command("ssh://git@host/o/r", "r").is_ok());
        for url in [
            "--upload-pack=touch /tmp/pwned",
            "-u",
            "ext::sh -c whoami",
            "EXT::sh -c whoami",
            "file:///etc",
            "https://host/a b",
            "",
            "just-a-word",
        ] {
            assert!(clone_command(url, "r").is_err(), "{url} was accepted");
        }
        for name in ["", "../escape", "a/b", "-x", ".git", &"n".repeat(256)] {
            assert!(
                clone_command("https://github.com/o/r.git", name).is_err(),
                "{name} was accepted"
            );
        }
    }

    #[test]
    fn a_folder_name_is_guessed_from_the_address() {
        assert_eq!(
            name_from_url("https://github.com/owner/repo.git").as_deref(),
            Some("repo")
        );
        assert_eq!(
            name_from_url("git@github.com:owner/repo").as_deref(),
            Some("repo")
        );
        assert_eq!(
            name_from_url("https://github.com/owner/repo/").as_deref(),
            Some("repo")
        );
        assert_eq!(name_from_url("https://github.com/owner/.git"), None);
    }
}
