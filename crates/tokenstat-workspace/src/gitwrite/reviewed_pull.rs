// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Explicit, fast-forward-only updates of the current branch from its
//! upstream.
//!
//! Review fetches the upstream branch, once, because a person pressed Pull.
//! Apply moves the branch to exactly the commit that review showed, and only
//! when that is a fast-forward of the commit the branch was on. There is no
//! merge commit, no rebase, no stash and no flag that asks for one: a branch
//! that has diverged is reported in words and left exactly as it was.
//!
//! No receipt is kept. After the fetch everything here is local, and whether
//! it happened is answered by reading HEAD, so repeating an apply whose
//! answer went missing is safe and says so.

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::lease::Lease;
use super::selected::{command, index_path, text};

/// What a pull would do, as of the fetch that review just made.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    /// The local branch, as a full ref.
    pub branch: String,
    /// Where that branch was when review ran.
    pub head: String,
    pub remote: String,
    /// The upstream branch on that remote, as a full ref.
    pub remote_ref: String,
    /// The upstream commit review fetched. None when the remote has no such
    /// branch any more.
    pub upstream_head: Option<String>,
    /// Commits the upstream has that this branch does not.
    pub incoming: u64,
    /// Commits this branch has that the upstream does not.
    pub outgoing: u64,
    pub state: State,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Nothing to bring in and nothing to send.
    UpToDate,
    /// Only this branch has new commits. Push, not pull.
    Ahead,
    /// The upstream is strictly ahead. Pull can fast-forward.
    FastForward,
    /// Both sides have commits the other lacks. Pull will not choose.
    Diverged,
    /// The upstream branch is gone from the remote.
    Missing,
}

/// The outcome of an apply.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub ok: bool,
    /// What happened, or git's own words when it refused.
    pub message: String,
    /// Where the branch is now.
    pub head: Option<String>,
}

fn config(dir: &Path, key: &str) -> Result<Option<String>, String> {
    let out = command(dir, &["config", "--get", key])
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.code() == Some(1) {
        return Ok(None);
    }
    if !out.status.success() {
        return Err(super::GitOutcome::from(out).message);
    }
    Ok(Some(
        String::from_utf8_lossy(&out.stdout).trim().to_string(),
    ))
}

fn count(dir: &Path, range: &str) -> Result<u64, String> {
    text(dir, &["rev-list", "--count", range])?
        .parse()
        .map_err(|_| "Git did not report a commit count.".to_string())
}

/// Fetch the current branch's upstream and say what a pull would do.
///
/// This is the one place a fetch runs, and it runs because a person asked to
/// pull. It never runs from a refresh, a watcher or a timer.
pub fn review(dir: &Path) -> Result<Review, String> {
    let branch = text(dir, &["symbolic-ref", "-q", "HEAD"])
        .map_err(|_| "Choose a branch before pulling. HEAD is detached.".to_string())?;
    let short = branch
        .strip_prefix("refs/heads/")
        .ok_or("Choose a local branch before pulling.")?;
    let head = text(dir, &["rev-parse", "--verify", "HEAD^{commit}"]).map_err(|_| {
        "This branch has no commits yet. There is nothing to pull into.".to_string()
    })?;
    let remote = config(dir, &format!("branch.{short}.remote"))?;
    let merge = config(dir, &format!("branch.{short}.merge"))?;
    let (Some(remote), Some(remote_ref)) = (remote, merge) else {
        return Err("This branch has no upstream yet. Push it once, then pull.".into());
    };
    if remote.is_empty()
        || remote == "."
        || remote.starts_with('-')
        || remote.contains(['\n', '\r'])
    {
        return Err(
            "This branch follows another local branch, not a remote. Pull it from a terminal."
                .into(),
        );
    }
    if !remote_ref.starts_with("refs/heads/") {
        return Err("The upstream must be a branch.".into());
    }
    text(dir, &["check-ref-format", &remote_ref])?;
    // Exit code 2 is "no such ref", whatever language git speaks.
    let listed = command(
        dir,
        &[
            "ls-remote",
            "--exit-code",
            "--heads",
            "--",
            &remote,
            &remote_ref,
        ],
    )
    .output()
    .map_err(|e| e.to_string())?;
    if listed.status.code() == Some(2) {
        return Ok(Review {
            branch,
            head,
            remote,
            remote_ref,
            upstream_head: None,
            incoming: 0,
            outgoing: 0,
            state: State::Missing,
        });
    }
    if !listed.status.success() {
        return Err(failure(listed, "Git could not reach the remote."));
    }
    // No tags, no submodules, and only this one branch: the fetch brings in
    // what the review is about and nothing else.
    let fetched = command(
        dir,
        &[
            "fetch",
            "--quiet",
            "--no-tags",
            "--no-recurse-submodules",
            "--no-write-fetch-head",
            "--",
            &remote,
            &format!("+{remote_ref}:{}", tracking_ref(&remote, &remote_ref)),
        ],
    )
    .output()
    .map_err(|e| e.to_string())?;
    if !fetched.status.success() {
        return Err(failure(fetched, "Git could not fetch the upstream branch."));
    }
    let upstream = text(
        dir,
        &[
            "rev-parse",
            "--verify",
            &format!("{}^{{commit}}", tracking_ref(&remote, &remote_ref)),
        ],
    )?;
    let incoming = count(dir, &format!("{head}..{upstream}"))?;
    let outgoing = count(dir, &format!("{upstream}..{head}"))?;
    let state = match (incoming, outgoing) {
        (0, 0) => State::UpToDate,
        (0, _) => State::Ahead,
        (_, 0) => State::FastForward,
        _ => State::Diverged,
    };
    Ok(Review {
        branch,
        head,
        remote,
        remote_ref,
        upstream_head: Some(upstream),
        incoming,
        outgoing,
        state,
    })
}

/// Git's own words for a failure, or a sentence when it said nothing.
fn failure(out: std::process::Output, fallback: &str) -> String {
    let message = super::GitOutcome::from(out).message;
    if message.is_empty() {
        fallback.into()
    } else {
        message
    }
}

/// The remote-tracking ref this branch's upstream lands in. Fetched into
/// explicitly, so a remote with a custom fetch mapping cannot send the
/// review's commit somewhere review does not read.
fn tracking_ref(remote: &str, remote_ref: &str) -> String {
    format!(
        "refs/remotes/{remote}/{}",
        remote_ref.trim_start_matches("refs/heads/")
    )
}

/// Move the branch to the reviewed upstream commit, fast-forward only.
///
/// Refused when the branch moved since review, when review did not find a
/// fast-forward, or when git would have to touch a file with uncommitted
/// changes. Each refusal leaves the working tree exactly as it was.
pub fn pull(dir: &Path, reviewed: &Review) -> Result<Outcome, String> {
    let _lease = Lease::acquire(&index_path(dir)?.with_file_name("tokenstat-git-operation.lock"))?;
    let Some(target) = reviewed.upstream_head.as_deref() else {
        return Err("The upstream branch is gone. There is nothing to pull.".into());
    };
    let branch = text(dir, &["symbolic-ref", "-q", "HEAD"])
        .map_err(|_| "HEAD is detached now. Review the branch again.".to_string())?;
    let head = text(dir, &["rev-parse", "--verify", "HEAD^{commit}"])?;
    if branch != reviewed.branch {
        return Err("The current branch changed. Review it again before pulling.".into());
    }
    // A repeat of an apply whose answer went missing finds the work done.
    if head == target {
        return Ok(Outcome {
            ok: true,
            message: "The branch is already at the reviewed commit.".into(),
            head: Some(head),
        });
    }
    if head != reviewed.head {
        return Err("The branch moved since the review. Review it again before pulling.".into());
    }
    if reviewed.state != State::FastForward {
        return Err(match reviewed.state {
            State::Diverged => "This branch and its upstream have both changed. Pull does not merge or rebase. Resolve it in a terminal or ask an agent to.".into(),
            State::Ahead => "There is nothing new upstream. Push to publish your commits.".into(),
            _ => "There is nothing to pull.".into(),
        });
    }
    let out = command(
        dir,
        &[
            "merge",
            "--ff-only",
            "--no-autostash",
            "--no-edit",
            "--quiet",
            target,
        ],
    )
    .output()
    .map_err(|e| e.to_string())?;
    let after = text(dir, &["rev-parse", "--verify", "HEAD^{commit}"]).ok();
    if out.status.success() && after.as_deref() == Some(target) {
        let count = reviewed.incoming;
        return Ok(Outcome {
            ok: true,
            message: if count == 1 {
                "Pulled 1 commit.".into()
            } else {
                format!("Pulled {count} commits.")
            },
            head: after,
        });
    }
    Ok(Outcome {
        ok: false,
        message: failure(out, "Git did not move the branch."),
        head: after,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct Fixture {
        _remote: tempfile::TempDir,
        local: tempfile::TempDir,
        other: tempfile::TempDir,
    }

    fn configure(dir: &Path) {
        for (key, value) in [
            ("user.name", "Fixture"),
            ("user.email", "fixture@example.invalid"),
            ("commit.gpgSign", "false"),
            ("core.hooksPath", ".git/hooks"),
        ] {
            text(dir, &["config", key, value]).unwrap();
        }
    }

    fn commit(dir: &Path, file: &str, body: &str) {
        fs::write(dir.join(file), body).unwrap();
        text(dir, &["add", file]).unwrap();
        text(dir, &["commit", "-qm", file]).unwrap();
    }

    /// A bare remote, a local clone tracking `main`, and a second clone that
    /// stands in for somebody else pushing.
    fn fixture() -> Fixture {
        let remote = tempfile::tempdir().unwrap();
        text(remote.path(), &["init", "--bare", "-q", "-b", "main"]).unwrap();
        let local = tempfile::tempdir().unwrap();
        text(local.path(), &["init", "-q", "-b", "main"]).unwrap();
        configure(local.path());
        text(
            local.path(),
            &["remote", "add", "origin", remote.path().to_str().unwrap()],
        )
        .unwrap();
        commit(local.path(), "file", "initial");
        text(local.path(), &["push", "-q", "-u", "origin", "main"]).unwrap();
        let other = tempfile::tempdir().unwrap();
        text(
            other.path(),
            &["clone", "-q", remote.path().to_str().unwrap(), "."],
        )
        .unwrap();
        configure(other.path());
        Fixture {
            _remote: remote,
            local,
            other,
        }
    }

    fn push_from_other(f: &Fixture, file: &str) {
        commit(f.other.path(), file, "theirs");
        text(f.other.path(), &["push", "-q"]).unwrap();
    }

    #[test]
    fn fast_forwards_to_exactly_the_reviewed_commit() {
        let f = fixture();
        let dir = f.local.path();
        assert_eq!(review(dir).unwrap().state, State::UpToDate);
        push_from_other(&f, "theirs");
        let reviewed = review(dir).unwrap();
        assert_eq!(reviewed.state, State::FastForward);
        assert_eq!(reviewed.incoming, 1);
        assert_eq!(reviewed.outgoing, 0);
        // A second push after review is not taken: apply moves to what was shown.
        push_from_other(&f, "later");
        let outcome = pull(dir, &reviewed).unwrap();
        assert!(outcome.ok, "{}", outcome.message);
        assert_eq!(outcome.head, reviewed.upstream_head);
        assert!(dir.join("theirs").exists());
        assert!(!dir.join("later").exists());
        // Repeating it finds the work done rather than failing.
        let again = pull(dir, &reviewed).unwrap();
        assert!(again.ok);
    }

    #[test]
    fn a_diverged_branch_is_reported_and_left_alone() {
        let f = fixture();
        let dir = f.local.path();
        push_from_other(&f, "theirs");
        commit(dir, "mine", "mine");
        let reviewed = review(dir).unwrap();
        assert_eq!(reviewed.state, State::Diverged);
        let before = text(dir, &["rev-parse", "HEAD"]).unwrap();
        assert!(pull(dir, &reviewed).is_err());
        assert_eq!(text(dir, &["rev-parse", "HEAD"]).unwrap(), before);
    }

    #[test]
    fn ahead_is_push_territory() {
        let f = fixture();
        let dir = f.local.path();
        commit(dir, "mine", "mine");
        let reviewed = review(dir).unwrap();
        assert_eq!(reviewed.state, State::Ahead);
        assert_eq!(reviewed.outgoing, 1);
        assert!(pull(dir, &reviewed).is_err());
    }

    #[test]
    fn a_branch_that_moved_since_review_is_refused() {
        let f = fixture();
        let dir = f.local.path();
        push_from_other(&f, "theirs");
        let reviewed = review(dir).unwrap();
        commit(dir, "mine", "mine");
        let error = pull(dir, &reviewed).unwrap_err();
        assert!(error.contains("moved"), "{error}");
    }

    #[test]
    fn uncommitted_changes_in_the_way_are_never_touched() {
        let f = fixture();
        let dir = f.local.path();
        commit(f.other.path(), "file", "theirs");
        text(f.other.path(), &["push", "-q"]).unwrap();
        fs::write(dir.join("file"), "my edit").unwrap();
        let reviewed = review(dir).unwrap();
        let outcome = pull(dir, &reviewed).unwrap();
        assert!(!outcome.ok);
        assert!(!outcome.message.is_empty());
        assert_eq!(fs::read_to_string(dir.join("file")).unwrap(), "my edit");
        assert_eq!(outcome.head.as_deref(), Some(reviewed.head.as_str()));
    }

    #[test]
    fn a_branch_without_upstream_says_so() {
        let f = fixture();
        let dir = f.local.path();
        text(dir, &["switch", "-q", "-c", "feature"]).unwrap();
        let error = review(dir).unwrap_err();
        assert!(error.contains("no upstream"), "{error}");
    }

    #[test]
    fn a_deleted_upstream_is_missing() {
        let f = fixture();
        let dir = f.local.path();
        text(dir, &["switch", "-q", "-c", "feature"]).unwrap();
        text(dir, &["push", "-q", "-u", "origin", "feature"]).unwrap();
        text(dir, &["push", "-q", "origin", "--delete", "feature"]).unwrap();
        let reviewed = review(dir).unwrap();
        assert_eq!(reviewed.state, State::Missing);
        assert!(pull(dir, &reviewed).is_err());
    }
}
