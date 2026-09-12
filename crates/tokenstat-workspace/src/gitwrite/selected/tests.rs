// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn repo(initial: bool) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    text(dir.path(), &["init", "-q"]).unwrap();
    text(dir.path(), &["config", "user.name", "Fixture"]).unwrap();
    text(
        dir.path(),
        &["config", "user.email", "fixture@example.invalid"],
    )
    .unwrap();
    text(dir.path(), &["config", "commit.gpgSign", "false"]).unwrap();
    // A developer's global hook configuration must not enter fixture tests.
    let hooks = dir.path().join(".git/hooks");
    text(
        dir.path(),
        &["config", "core.hooksPath", hooks.to_str().unwrap()],
    )
    .unwrap();
    if initial {
        fs::write(dir.path().join("chosen"), "before\n").unwrap();
        fs::write(dir.path().join("other"), "before\n").unwrap();
        text(dir.path(), &["add", "."]).unwrap();
        text(dir.path(), &["commit", "-qm", "Initial"]).unwrap();
    }
    dir
}

fn submit(dir: &Path, names: &[&str]) -> Receipt {
    let paths = names.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let reviewed = review(dir, &paths).unwrap();
    commit(dir, "fixture-operation-0001", &reviewed, "Selected files").unwrap()
}

#[test]
fn unrelated_staged_content_survives_and_is_not_committed() {
    let dir = repo(true);
    let dir = dir.path();
    fs::write(dir.join("other"), "staged\n").unwrap();
    text(dir, &["add", "other"]).unwrap();
    fs::write(dir.join("other"), "unstaged too\n").unwrap();
    fs::write(dir.join("chosen"), "chosen staged\n").unwrap();
    text(dir, &["add", "chosen"]).unwrap();
    fs::write(dir.join("chosen"), "chosen final\n").unwrap();
    let result = submit(dir, &["chosen"]);
    assert_eq!(result.state, "succeeded", "{}", result.message);
    assert_eq!(text(dir, &["show", "HEAD:chosen"]).unwrap(), "chosen final");
    assert_eq!(text(dir, &["show", "HEAD:other"]).unwrap(), "before");
    assert_eq!(text(dir, &["show", ":other"]).unwrap(), "staged");
    assert_eq!(
        fs::read_to_string(dir.join("other")).unwrap(),
        "unstaged too\n"
    );
    assert_eq!(
        text(dir, &["diff", "--cached", "--name-only"]).unwrap(),
        "other"
    );
}

#[test]
fn replay_returns_the_same_commit_and_rejects_id_reuse() {
    let dir = repo(true);
    let dir = dir.path();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    let review = review(dir, &["chosen".into()]).unwrap();
    let first = commit(dir, "fixture-operation-0001", &review, "Selected").unwrap();
    let second = commit(dir, "fixture-operation-0001", &review, "Selected").unwrap();
    assert_eq!(first.state, "succeeded");
    assert_eq!(first.commit, second.commit);
    assert_eq!(text(dir, &["rev-list", "--count", "HEAD"]).unwrap(), "2");
    assert!(commit(dir, "fixture-operation-0001", &review, "Different").is_err());
}

#[test]
fn stale_worktree_or_index_review_leaves_everything_untouched() {
    for change_index in [false, true] {
        let dir = repo(true);
        let dir = dir.path();
        fs::write(dir.join("chosen"), "reviewed\n").unwrap();
        let reviewed = review(dir, &["chosen".into()]).unwrap();
        if change_index {
            fs::write(dir.join("other"), "new stage\n").unwrap();
            text(dir, &["add", "other"]).unwrap();
        } else {
            fs::write(dir.join("chosen"), "not reviewed\n").unwrap();
        }
        let before = fs::read(index_path(dir).unwrap()).unwrap();
        assert!(
            commit(dir, "fixture-operation-0001", &reviewed, "Selected")
                .unwrap()
                .message
                .contains("changed since review")
        );
        assert_eq!(before, fs::read(index_path(dir).unwrap()).unwrap());
        assert_eq!(text(dir, &["rev-list", "--count", "HEAD"]).unwrap(), "1");
    }
}

#[test]
fn first_commit_can_choose_one_untracked_binary_file() {
    let dir = repo(false);
    let dir = dir.path();
    fs::write(dir.join("chosen"), [0, 1, 0, 255]).unwrap();
    fs::write(dir.join("other"), "leave this alone").unwrap();
    let result = submit(dir, &["chosen"]);
    assert_eq!(result.state, "succeeded", "{}", result.message);
    assert_eq!(
        text(dir, &["ls-tree", "--name-only", "HEAD"]).unwrap(),
        "chosen"
    );
    assert_eq!(
        output(command(dir, &["show", "HEAD:chosen"])).unwrap(),
        [0, 1, 0, 255]
    );
}

#[test]
fn deletion_and_rename_keep_unrelated_index_entries() {
    let dir = repo(true);
    let dir = dir.path();
    fs::rename(dir.join("chosen"), dir.join("renamed")).unwrap();
    fs::remove_file(dir.join("other")).unwrap();
    let result = submit(dir, &["chosen", "renamed", "other"]);
    assert_eq!(result.state, "succeeded", "{}", result.message);
    assert_eq!(
        text(dir, &["ls-tree", "--name-only", "HEAD"]).unwrap(),
        "renamed"
    );
    assert!(text(dir, &["status", "--porcelain"]).unwrap().is_empty());
}

#[test]
fn selecting_a_staged_rename_includes_its_original_path() {
    let dir = repo(true);
    let dir = dir.path();
    text(dir, &["mv", "chosen", "renamed"]).unwrap();
    fs::write(dir.join("other"), "staged separately\n").unwrap();
    text(dir, &["add", "other"]).unwrap();
    let reviewed = review(dir, &["renamed".into()]).unwrap();
    assert_eq!(reviewed.paths, ["renamed"]);
    assert_eq!(reviewed.included_paths, ["chosen", "renamed"]);
    let result = commit(
        dir,
        "fixture-operation-0001",
        &reviewed,
        "Rename selected file",
    )
    .unwrap();
    assert_eq!(result.state, "succeeded", "{}", result.message);
    assert!(
        !dir.join(".git/ORIG_HEAD").exists(),
        "A path-only private-index reset must not change ORIG_HEAD"
    );
    assert_eq!(
        text(dir, &["ls-tree", "--name-only", "HEAD"]).unwrap(),
        "other\nrenamed"
    );
    assert_eq!(text(dir, &["show", "HEAD:other"]).unwrap(), "before");
    assert_eq!(text(dir, &["show", ":other"]).unwrap(), "staged separately");
}

#[test]
fn an_existing_lock_is_never_removed_or_overwritten() {
    let dir = repo(true);
    let dir = dir.path();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    let reviewed = review(dir, &["chosen".into()]).unwrap();
    let lock = index_path(dir).unwrap().with_extension("lock");
    fs::write(&lock, "someone else's lock").unwrap();
    assert_eq!(
        commit(dir, "fixture-operation-0001", &reviewed, "Selected")
            .unwrap()
            .state,
        "failed"
    );
    assert_eq!(fs::read_to_string(lock).unwrap(), "someone else's lock");
}

#[cfg(unix)]
fn hook(dir: &Path, content: &str) {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(".git/hooks/pre-commit");
    fs::write(&path, content).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
#[cfg(unix)]
fn failing_or_staging_hooks_cannot_publish_unreviewed_content() {
    for body in [
        "#!/bin/sh\necho 'fixture refusal' >&2\nexit 1\n",
        "#!/bin/sh\nprintf unexpected > other\ngit add other\n",
    ] {
        let dir = repo(true);
        let dir = dir.path();
        fs::write(dir.join("chosen"), "after\n").unwrap();
        let index_before = fs::read(index_path(dir).unwrap()).unwrap();
        hook(dir, body);
        let result = submit(dir, &["chosen"]);
        assert_eq!(result.state, "failed", "{}", result.message);
        assert_eq!(fs::read(index_path(dir).unwrap()).unwrap(), index_before);
        assert_eq!(text(dir, &["rev-list", "--count", "HEAD"]).unwrap(), "1");
        assert!(!index_path(dir).unwrap().with_extension("lock").exists());
    }
}

#[test]
fn invalid_selections_and_detached_head_are_refused() {
    let dir = repo(true);
    let dir = dir.path();
    for paths in [
        vec![],
        vec!["".into()],
        vec!["../outside".into()],
        vec![".git/config".into()],
    ] {
        assert!(review(dir, &paths).is_err());
    }
    text(dir, &["checkout", "--detach", "-q"]).unwrap();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    assert!(
        review(dir, &["chosen".into()])
            .unwrap_err()
            .contains("detached")
    );
}

#[test]
fn recovery_finishes_only_the_recorded_index_after_a_landed_commit() {
    let dir = repo(true);
    let dir = dir.path();
    fs::write(dir.join("other"), "staged elsewhere\n").unwrap();
    text(dir, &["add", "other"]).unwrap();
    let index = index_path(dir).unwrap();
    let before = fs::read(&index).unwrap();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    let mut result = submit(dir, &["chosen"]);
    assert_eq!(result.state, "succeeded");
    let after = fs::read(&index).unwrap();
    // Emulate a process ending after update-ref and before index publication.
    fs::write(index.with_extension("lock"), &after).unwrap();
    result.index_lock_identity =
        Some(lease::identity(&File::open(index.with_extension("lock")).unwrap()).unwrap());
    fs::write(&index, before).unwrap();
    result.state = "prepared".into();
    save(&receipt_path(dir, &result.operation_id).unwrap(), &result).unwrap();
    let recovered = recover(dir, &result.operation_id).unwrap();
    assert_eq!(recovered.state, "succeeded");
    assert_eq!(fs::read(&index).unwrap(), after);
    assert_eq!(text(dir, &["show", ":other"]).unwrap(), "staged elsewhere");
    assert_eq!(text(dir, &["rev-list", "--count", "HEAD"]).unwrap(), "2");
}

#[test]
fn recovery_before_ref_update_keeps_the_original_index() {
    let dir = repo(true);
    let dir = dir.path();
    let index = index_path(dir).unwrap();
    let before = fs::read(&index).unwrap();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    let mut result = submit(dir, &["chosen"]);
    let after = fs::read(&index).unwrap();
    text(
        dir,
        &[
            "update-ref",
            &result.branch,
            result.previous_head.as_deref().unwrap(),
        ],
    )
    .unwrap();
    fs::write(&index, &before).unwrap();
    fs::write(index.with_extension("lock"), after).unwrap();
    result.index_lock_identity =
        Some(lease::identity(&File::open(index.with_extension("lock")).unwrap()).unwrap());
    result.state = "prepared".into();
    save(&receipt_path(dir, &result.operation_id).unwrap(), &result).unwrap();
    let recovered = recover(dir, &result.operation_id).unwrap();
    assert_eq!(recovered.state, "failed");
    assert_eq!(fs::read(&index).unwrap(), before);
    assert!(!index.with_extension("lock").exists());
}

#[test]
fn recovery_does_not_touch_an_unrecognized_lock() {
    let dir = repo(true);
    let dir = dir.path();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    let mut result = submit(dir, &["chosen"]);
    let lock = index_path(dir).unwrap().with_extension("lock");
    fs::write(&lock, "a different operation").unwrap();
    result.state = "prepared".into();
    save(&receipt_path(dir, &result.operation_id).unwrap(), &result).unwrap();
    assert!(recover(dir, &result.operation_id).is_err());
    assert_eq!(fs::read_to_string(lock).unwrap(), "a different operation");
}

#[test]
fn a_live_operation_excludes_recovery() {
    let dir = repo(true);
    let dir = dir.path();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    let result = submit(dir, &["chosen"]);
    let index = index_path(dir).unwrap();
    let _lease =
        lease::Lease::acquire(&index.with_file_name("tokenstat-git-operation.lock")).unwrap();
    assert!(
        recover(dir, &result.operation_id)
            .unwrap_err()
            .contains("still running")
    );
}

#[test]
fn an_immutable_review_diff_does_not_follow_later_edits() {
    let dir = repo(true);
    let dir = dir.path();
    fs::write(dir.join("chosen"), "reviewed words\n").unwrap();
    let reviewed = review(dir, &["chosen".into()]).unwrap();
    fs::write(dir.join("chosen"), "newer agent edits\n").unwrap();
    let diff = review_diff(dir, &reviewed, "chosen").unwrap();
    let json = serde_json::to_string(&diff).unwrap();
    assert!(json.contains("reviewed words"));
    assert!(!json.contains("newer agent edits"));
    assert!(review_diff(dir, &reviewed, "other").is_err());
}

#[test]
fn a_branch_switch_to_the_same_commit_cannot_retarget_submission() {
    let dir = repo(true);
    let dir = dir.path();
    let (branch, old) = base(dir).unwrap();
    let old = old.unwrap();
    fs::write(dir.join("chosen"), "after\n").unwrap();
    let reviewed = review(dir, &["chosen".into()]).unwrap();
    let created = input(
        command(dir, &["commit-tree", &reviewed.tree, "-p", &old]),
        b"Fixture\n",
    )
    .unwrap();
    let new = String::from_utf8(created).unwrap();
    text(dir, &["switch", "-c", "other-branch"]).unwrap();
    assert!(advance_head(dir, &branch, &old, new.trim()).is_err());
    assert_eq!(text(dir, &["rev-parse", "HEAD"]).unwrap(), old);
    assert_eq!(text(dir, &["rev-parse", &branch]).unwrap(), old);
}
