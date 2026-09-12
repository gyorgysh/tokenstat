// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Selected-file commits use a private index. The real index is locked before
//! validation and keeps every entry outside the explicitly reviewed selection.
//! Only explicit review/commit actions call this module, never status polling.

use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

mod lease;

/// An exact reviewed tree and the repository state it was based on.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    pub branch: String,
    pub head: Option<String>,
    pub base_tree: String,
    pub index_digest: String,
    pub tree: String,
    pub paths: Vec<String>,
    pub included_paths: Vec<String>,
}

/// A durable answer to one submitted commit, including an interrupted one.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub operation_id: String,
    pub request_digest: String,
    pub state: String,
    pub commit: Option<String>,
    pub message: String,
    pub branch: String,
    pub previous_head: Option<String>,
    pub previous_index_digest: String,
    pub prepared_index_digest: Option<String>,
    pub index_lock_identity: Option<[u64; 2]>,
}

fn output(mut command: Command) -> Result<Vec<u8>, String> {
    let out = command.output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        let message = super::GitOutcome::from(out).message;
        return Err(if message.is_empty() {
            "Git could not complete this operation.".into()
        } else {
            message
        });
    }
    Ok(out.stdout)
}

fn command(dir: &Path, args: &[&str]) -> Command {
    let mut command = super::git_command(dir);
    command.args(args).env("GIT_OPTIONAL_LOCKS", "0");
    command
}

fn text(dir: &Path, args: &[&str]) -> Result<String, String> {
    String::from_utf8(output(command(dir, args))?)
        .map(|s| s.trim().to_owned())
        .map_err(|e| e.to_string())
}

fn input(mut command: Command, bytes: &[u8]) -> Result<Vec<u8>, String> {
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    child
        .stdin
        .take()
        .ok_or("Git did not accept input")?
        .write_all(bytes)
        .map_err(|e| e.to_string())?;
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().into());
    }
    Ok(out.stdout)
}

fn advance_head(dir: &Path, branch: &str, old: &str, new: &str) -> Result<(), String> {
    let mut errors = tempfile::tempfile().map_err(|e| e.to_string())?;
    let mut cmd = command(
        dir,
        &["update-ref", "-m", "commit: selected files", "--stdin"],
    );
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(errors.try_clone().map_err(|e| e.to_string())?);
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    let result = (|| {
        let mut stdin = child
            .stdin
            .take()
            .ok_or("Git did not accept a reference transaction")?;
        let mut stdout = BufReader::new(
            child
                .stdout
                .take()
                .ok_or("Git did not acknowledge the transaction")?,
        );
        stdin
            .write_all(format!("start\nupdate HEAD {new} {old}\nprepare\n").as_bytes())
            .map_err(|e| e.to_string())?;
        stdin.flush().map_err(|e| e.to_string())?;
        for expected in ["start: ok", "prepare: ok"] {
            let mut line = String::new();
            stdout.read_line(&mut line).map_err(|e| e.to_string())?;
            if line.trim() != expected {
                return Err("Git could not lock the reviewed branch.".to_owned());
            }
        }
        // Git now holds both HEAD and its referent. Checking the symbolic
        // target here closes the check/checkout race without taking a second
        // HEAD lock that would conflict with Git's transaction itself.
        if text(dir, &["symbolic-ref", "-q", "HEAD"])? != branch {
            return Err("The selected branch changed. Review again before committing.".into());
        }
        stdin.write_all(b"commit\n").map_err(|e| e.to_string())?;
        drop(stdin);
        let mut line = String::new();
        stdout.read_line(&mut line).map_err(|e| e.to_string())?;
        if line.trim() != "commit: ok" {
            return Err("Git could not publish the commit.".to_owned());
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = child.kill();
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    if result.is_err() || !status.success() {
        errors.rewind().map_err(|e| e.to_string())?;
        let mut message = String::new();
        errors
            .take(64 * 1024)
            .read_to_string(&mut message)
            .map_err(|e| e.to_string())?;
        return Err(if message.trim().is_empty() {
            result
                .err()
                .unwrap_or_else(|| "Git could not publish the commit.".into())
        } else {
            message.trim().into()
        });
    }
    Ok(())
}

fn private(dir: &Path, index: &Path, args: &[&str]) -> Command {
    let mut cmd = command(dir, args);
    cmd.env("GIT_INDEX_FILE", index);
    cmd
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn index_path(dir: &Path) -> Result<PathBuf, String> {
    text(
        dir,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
    )
    .map(PathBuf::from)
}

fn index_bytes(path: &Path) -> Result<Vec<u8>, String> {
    match fs::read(path) {
        Ok(bytes) => Ok(bytes),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e.to_string()),
    }
}

fn base(dir: &Path) -> Result<(String, Option<String>), String> {
    let branch = text(dir, &["symbolic-ref", "-q", "HEAD"])
        .map_err(|_| "Choose a branch before committing. HEAD is detached.".to_owned())?;
    let head = text(dir, &["rev-parse", "--verify", "HEAD"]).ok();
    for name in [
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "rebase-merge",
        "rebase-apply",
    ] {
        let path = text(
            dir,
            &["rev-parse", "--path-format=absolute", "--git-path", name],
        )?;
        if Path::new(&path).exists() {
            return Err("Finish the active merge, rebase or cherry-pick on the computer before committing selected files.".into());
        }
    }
    if !output(command(dir, &["ls-files", "--unmerged", "-z"]))?.is_empty() {
        return Err("Resolve the repository's conflicts before committing.".into());
    }
    Ok((branch, head))
}

fn build_review(dir: &Path, paths: &[String], index: &Path) -> Result<Review, String> {
    if paths.is_empty() || paths.len() > 10_000 {
        return Err("Select between 1 and 10,000 files.".into());
    }
    let root = text(dir, &["rev-parse", "--show-toplevel"])?;
    if fs::canonicalize(dir).map_err(|e| e.to_string())?
        != fs::canonicalize(root).map_err(|e| e.to_string())?
    {
        return Err("Open the repository root to commit selected files.".into());
    }
    let mut paths = paths.to_vec();
    paths.sort();
    paths.dedup();
    for path in &paths {
        if path.is_empty() {
            return Err("Select individual files.".into());
        }
        crate::tree::assert_relative_inside(path).map_err(|e| e.to_string())?;
        if path
            .split('/')
            .any(|part| part.eq_ignore_ascii_case(".git"))
            || path.contains('\0')
        {
            return Err("Git metadata cannot be selected.".into());
        }
        for parent in Path::new(path)
            .ancestors()
            .skip(1)
            .filter(|p| !p.as_os_str().is_empty())
        {
            if fs::symlink_metadata(dir.join(parent)).is_ok() {
                crate::tree::resolve(dir, &parent.to_string_lossy()).map_err(|e| e.to_string())?;
                break;
            }
        }
        if fs::symlink_metadata(dir.join(path)).is_ok_and(|m| m.is_dir()) {
            return Err("Select individual files, not directories or submodules.".into());
        }
    }
    let (branch, head) = base(dir)?;
    let mut included_paths = paths.clone();
    let status = output(command(
        dir,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    ))?;
    let mut records = status.split(|byte| *byte == 0);
    while let Some(record) = records.next() {
        if record.len() < 4 {
            continue;
        }
        if record[..2]
            .iter()
            .any(|byte| *byte == b'R' || *byte == b'C')
        {
            let original = records.next().ok_or("Git returned an incomplete rename")?;
            let destination = std::str::from_utf8(&record[3..]).map_err(|e| e.to_string())?;
            if record[..2].contains(&b'R') && paths.iter().any(|path| path == destination) {
                let original = std::str::from_utf8(original).map_err(|e| e.to_string())?;
                crate::tree::assert_relative_inside(original).map_err(|e| e.to_string())?;
                included_paths.push(original.into());
            }
        }
    }
    included_paths.sort();
    included_paths.dedup();
    let original_index = index_bytes(&index_path(dir)?)?;
    let mut read = private(dir, index, &["read-tree"]);
    read.arg(head.as_deref().unwrap_or("--empty"));
    output(read)?;
    let base_tree = String::from_utf8(output(private(dir, index, &["write-tree"]))?)
        .map_err(|e| e.to_string())?
        .trim()
        .to_owned();
    let mut add = private(dir, index, &["add", "--"]);
    add.args(&included_paths);
    output(add)?;
    let tree = String::from_utf8(output(private(dir, index, &["write-tree"]))?)
        .map_err(|e| e.to_string())?
        .trim()
        .to_owned();
    if let Some(head) = &head {
        if tree == text(dir, &["rev-parse", &format!("{head}^{{tree}}")])? {
            return Err("The selected files have no changes to commit.".into());
        }
    }
    Ok(Review {
        branch,
        head,
        base_tree,
        index_digest: digest(&original_index),
        tree,
        paths,
        included_paths,
    })
}

#[cfg(test)]
mod tests;

/// Freeze the selected content for an explicit review, without staging anything
/// in the user's index. Later edits must produce another review.
pub fn review(dir: &Path, paths: &[String]) -> Result<Review, String> {
    let temp = tempfile::tempdir().map_err(|e| e.to_string())?;
    build_review(dir, paths, &temp.path().join("index"))
}

/// A bounded, immutable diff from the reviewed tree, even if an agent edits
/// the worktree while the person is reading it. No external diff command runs.
pub fn review_diff(dir: &Path, reviewed: &Review, path: &str) -> Result<crate::FileDiff, String> {
    if !reviewed
        .included_paths
        .iter()
        .any(|selected| selected == path)
    {
        return Err("That file is outside this reviewed selection.".into());
    }
    crate::tree::assert_relative_inside(path).map_err(|e| e.to_string())?;
    for revision in [&reviewed.base_tree, &reviewed.tree] {
        if !matches!(revision.len(), 40 | 64) || !revision.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("Invalid reviewed tree.".into());
        }
    }
    let error_file = tempfile::tempfile().map_err(|e| e.to_string())?;
    let mut cmd = command(
        dir,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            &reviewed.base_tree,
            &reviewed.tree,
            "--",
            path,
        ],
    );
    cmd.stdout(Stdio::piped())
        .stderr(error_file.try_clone().map_err(|e| e.to_string())?);
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    const LIMIT: u64 = 8 * 1024 * 1024;
    let mut bytes = Vec::new();
    let read = child
        .stdout
        .take()
        .ok_or("Git did not return a diff")?
        .take(LIMIT + 1)
        .read_to_end(&mut bytes);
    if read.is_err() || bytes.len() as u64 > LIMIT {
        let _ = child.kill();
        let _ = child.wait();
        return Err("This diff exceeds the review limit. Review this file on the computer before committing it.".into());
    }
    if !child.wait().map_err(|e| e.to_string())?.success() {
        return Err("The reviewed diff is no longer available. Prepare a fresh review.".into());
    }
    let raw = String::from_utf8_lossy(&bytes);
    Ok(crate::FileDiff {
        path: path.into(),
        binary: raw.lines().any(|line| line.starts_with("Binary files ")),
        hunks: crate::git::parse_diff(&raw),
        untracked: false,
    })
}

struct IndexLock {
    path: PathBuf,
    file: File,
    keep: bool,
}

impl IndexLock {
    fn acquire(index: &Path) -> Result<Self, String> {
        let path = index.with_extension("lock");
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|_| {
                "Git is busy or an unfinished Git operation needs attention on the computer."
                    .to_owned()
            })?;
        Ok(Self {
            path,
            file,
            keep: false,
        })
    }
}

impl Drop for IndexLock {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn receipt_path(dir: &Path, id: &str) -> Result<PathBuf, String> {
    if id.len() < 16 || id.len() > 80 || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("Invalid operation identifier.".into());
    }
    let root = text(
        dir,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "tokenstat-operations",
        ],
    )?;
    Ok(PathBuf::from(root).join(format!("{id}.json")))
}

fn save(path: &Path, receipt: &Receipt) -> Result<(), String> {
    let parent = path.parent().ok_or("Missing operation directory")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    temp.write_all(&serde_json::to_vec(receipt).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    temp.as_file().sync_all().map_err(|e| e.to_string())?;
    temp.persist(path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    File::open(parent)
        .and_then(|file| file.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Reading an operation never repeats it. A prepared result requires recovery
/// if its process ended between updating the branch and publishing the index.
pub fn receipt(dir: &Path, id: &str) -> Result<Option<Receipt>, String> {
    match fs::read(receipt_path(dir, id)?) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

/// Commit an already reviewed snapshot once. Hooks see a private index and
/// cannot accidentally bring unrelated staged files into this commit.
pub fn commit(dir: &Path, id: &str, reviewed: &Review, message: &str) -> Result<Receipt, String> {
    let path = receipt_path(dir, id)?;
    if message.trim().is_empty() || message.len() > 128 * 1024 {
        return Err("A commit needs a message of at most 128 KiB.".into());
    }
    let request_digest =
        digest(&serde_json::to_vec(&(reviewed, message)).map_err(|e| e.to_string())?);
    if let Some(previous) = receipt(dir, id)? {
        if previous.request_digest != request_digest {
            return Err("This operation identifier belongs to another commit.".into());
        }
        return Ok(previous);
    }
    let index = index_path(dir)?;
    let _lease = lease::Lease::acquire(&index.with_file_name("tokenstat-git-operation.lock"))?;
    // Recheck after taking the lock, including another request with this ID.
    if let Some(previous) = receipt(dir, id)? {
        if previous.request_digest != request_digest {
            return Err("This operation identifier belongs to another commit.".into());
        }
        return Ok(previous);
    }
    let mut result = Receipt {
        operation_id: id.into(),
        request_digest,
        state: "started".into(),
        commit: None,
        message: "The commit was submitted. Check its outcome before starting another.".into(),
        branch: reviewed.branch.clone(),
        previous_head: reviewed.head.clone(),
        previous_index_digest: reviewed.index_digest.clone(),
        prepared_index_digest: None,
        index_lock_identity: None,
    };
    save(&path, &result)?;
    let outcome = (|| {
        let mut lock = IndexLock::acquire(&index)?;
        result.index_lock_identity = Some(lease::identity(&lock.file)?);
        result.prepared_index_digest = Some(digest(&[]));
        save(&path, &result)?;
        let temp = tempfile::tempdir().map_err(|e| e.to_string())?;
        let selected_index = temp.path().join("selected");
        let fresh = build_review(dir, &reviewed.paths, &selected_index)?;
        if &fresh != reviewed {
            return Err(
                "The repository changed since review. Review the selected files again.".into(),
            );
        }
        perform(
            dir,
            reviewed,
            message,
            &selected_index,
            temp.path(),
            &index,
            &mut lock,
            &path,
            &mut result,
        )
    })();
    if let Err(error) = outcome {
        if result.state != "prepared" && result.state != "succeeded" {
            result.state = "failed".into();
            result.message = error;
        } else if result.state == "prepared" {
            result.message = format!("Commit recovery needs attention on the computer. {error}");
        }
    }
    save(&path, &result)?;
    Ok(result)
}

#[allow(clippy::too_many_arguments)]
fn perform(
    dir: &Path,
    reviewed: &Review,
    message: &str,
    selected: &Path,
    temp: &Path,
    index: &Path,
    lock: &mut IndexLock,
    receipt_path: &Path,
    result: &mut Receipt,
) -> Result<(), String> {
    let message_path = temp.join("COMMIT_EDITMSG");
    fs::write(&message_path, message).map_err(|e| e.to_string())?;
    for hook in ["pre-commit", "prepare-commit-msg", "commit-msg"] {
        let mut cmd = private(dir, selected, &["hook", "run", "--ignore-missing", hook]);
        cmd.env("GIT_EDITOR", ":");
        if hook != "pre-commit" {
            cmd.arg("--").arg(&message_path);
        }
        if hook == "prepare-commit-msg" {
            cmd.arg("message");
        }
        output(cmd)?;
    }
    let hooked_tree = String::from_utf8(output(private(dir, selected, &["write-tree"]))?)
        .map_err(|e| e.to_string())?;
    if hooked_tree.trim() != reviewed.tree {
        return Err(
            "A Git hook changed the reviewed content. Review its changes before committing.".into(),
        );
    }
    if base(dir)? != (reviewed.branch.clone(), reviewed.head.clone()) {
        return Err("The branch changed during the commit checks. Review again.".into());
    }
    let final_message = fs::read(&message_path).map_err(|e| e.to_string())?;
    if final_message.iter().all(u8::is_ascii_whitespace) {
        return Err("The Git hook left an empty commit message.".into());
    }
    let mut create = private(dir, selected, &["commit-tree", &reviewed.tree]);
    if let Some(head) = &reviewed.head {
        create.args(["-p", head]);
    }
    if text(dir, &["config", "--bool", "commit.gpgSign"]).is_ok_and(|s| s == "true") {
        create.arg("-S");
    }
    let commit = String::from_utf8(input(create, &final_message)?)
        .map_err(|e| e.to_string())?
        .trim()
        .to_owned();
    // Prepare the post-commit real index before changing a ref. Reset only the
    // chosen paths to the committed tree, retaining unrelated staged entries.
    let merged = temp.join("merged");
    let original = index_bytes(index)?;
    if original.is_empty() {
        output(private(dir, &merged, &["read-tree", "--empty"]))?;
    } else {
        fs::write(&merged, &original).map_err(|e| e.to_string())?;
    }
    let mut reset = private(dir, &merged, &["reset", "-q", &commit, "--"]);
    reset.args(&reviewed.included_paths);
    output(reset)?;
    let merged_bytes = fs::read(&merged).map_err(|e| e.to_string())?;
    lock.file.set_len(0).map_err(|e| e.to_string())?;
    lock.file.rewind().map_err(|e| e.to_string())?;
    lock.file
        .write_all(&merged_bytes)
        .map_err(|e| e.to_string())?;
    lock.file.sync_all().map_err(|e| e.to_string())?;
    result.state = "prepared".into();
    result.commit = Some(commit.clone());
    result.prepared_index_digest = Some(digest(&merged_bytes));
    result.index_lock_identity = Some(lease::identity(&lock.file)?);
    result.message = "The commit is prepared. Confirm its recorded outcome before retrying.".into();
    save(receipt_path, result)?;
    // After this point a crash must leave the index lock for recovery. A later
    // request cannot race ahead with an index that predates the new commit.
    lock.keep = true;
    let zero = "0".repeat(commit.len());
    let updated = advance_head(
        dir,
        &reviewed.branch,
        reviewed.head.as_deref().unwrap_or(&zero),
        &commit,
    );
    updated?;
    fs::rename(&lock.path, index).map_err(|e| e.to_string())?;
    lock.keep = false;
    result.state = "succeeded".into();
    result.message = "Committed the selected files.".into();
    save(receipt_path, result)?;
    // post-commit is informational. Its failure cannot undo a created commit.
    let _ = output(command(
        dir,
        &["hook", "run", "--ignore-missing", "post-commit"],
    ));
    Ok(())
}

/// Explicitly reconcile an interrupted commit. Never create another commit or
/// replace an index whose ownership/content cannot be proven from the receipt.
pub fn recover(dir: &Path, id: &str) -> Result<Receipt, String> {
    let index = index_path(dir)?;
    let _lease = lease::Lease::acquire(&index.with_file_name("tokenstat-git-operation.lock"))?;
    let mut result = receipt(dir, id)?.ok_or("No submitted commit was found.")?;
    if result.state == "succeeded" || result.state == "failed" {
        return Ok(result);
    }
    let Some(commit) = result.commit.as_deref() else {
        let lock_path = index.with_extension("lock");
        if lock_path.exists() {
            let file = File::open(&lock_path).map_err(|e| e.to_string())?;
            let bytes = fs::read(&lock_path).map_err(|e| e.to_string())?;
            if Some(lease::identity(&file)?) != result.index_lock_identity
                || result.prepared_index_digest.as_deref() != Some(digest(&bytes).as_str())
            {
                return Err("The interrupted operation's Git lock could not be verified. Inspect it on the computer.".into());
            }
            fs::remove_file(lock_path).map_err(|e| e.to_string())?;
        }
        result.state = "failed".into();
        result.message = "The operation ended before publishing a commit. Your draft is ready for a fresh review.".into();
        save(&receipt_path(dir, id)?, &result)?;
        return Ok(result);
    };
    let current_head = text(dir, &["rev-parse", "--verify", &result.branch]).ok();
    let landed = current_head.as_deref() == Some(commit)
        || current_head.as_deref().is_some_and(|head| {
            output(command(dir, &["merge-base", "--is-ancestor", commit, head])).is_ok()
        });
    let lock_path = index.with_extension("lock");
    if lock_path.exists() {
        let lock_file = File::open(&lock_path).map_err(|e| e.to_string())?;
        if Some(lease::identity(&lock_file)?) != result.index_lock_identity {
            return Err("Another Git operation owns the index lock. It was left untouched.".into());
        }
        let locked = fs::read(&lock_path).map_err(|e| e.to_string())?;
        let known_lock = result.prepared_index_digest.as_deref() == Some(digest(&locked).as_str());
        let unchanged_index = digest(&index_bytes(&index)?) == result.previous_index_digest;
        if !known_lock || !unchanged_index {
            return Err("The Git index changed outside this operation. Inspect it on the computer before recovery.".into());
        }
        if landed
            && current_head.as_deref() == Some(commit)
            && text(dir, &["symbolic-ref", "-q", "HEAD"])? == result.branch
        {
            fs::rename(lock_path, &index).map_err(|e| e.to_string())?;
        } else if !landed && current_head == result.previous_head {
            fs::remove_file(lock_path).map_err(|e| e.to_string())?;
            result.state = "failed".into();
            result.message = "The interrupted commit did not move the branch. Your staged work is unchanged. Review again to start a new commit.".into();
            save(&receipt_path(dir, id)?, &result)?;
            return Ok(result);
        } else {
            return Err("The branch moved after this operation. Inspect the recorded commit and Git index on the computer.".into());
        }
    }
    if landed {
        let current_index = digest(&index_bytes(&index)?);
        if current_index == result.previous_index_digest
            && result.prepared_index_digest.as_deref() != Some(current_index.as_str())
        {
            return Err("The commit exists, but its index update is missing. Inspect staged changes on the computer before continuing.".into());
        }
        result.state = "succeeded".into();
        result.message = "Confirmed the selected files were committed.".into();
        save(&receipt_path(dir, id)?, &result)?;
    } else {
        result.message = "The commit outcome could not be confirmed. Inspect the recorded commit on the computer before starting another.".into();
    }
    Ok(result)
}
