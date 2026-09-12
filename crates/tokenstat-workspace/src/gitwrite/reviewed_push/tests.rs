// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn repositories() -> (tempfile::TempDir, tempfile::TempDir) {
    let local = tempfile::tempdir().unwrap();
    let remote = tempfile::tempdir().unwrap();
    text(remote.path(), &["init", "--bare", "-q"]).unwrap();
    text(local.path(), &["init", "-q", "-b", "main"]).unwrap();
    for (key, value) in [
        ("user.name", "Fixture"),
        ("user.email", "fixture@example.invalid"),
        ("commit.gpgSign", "false"),
        ("core.hooksPath", ".git/hooks"),
    ] {
        text(local.path(), &["config", key, value]).unwrap();
    }
    text(
        local.path(),
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
    )
    .unwrap();
    fs::write(local.path().join("file"), "initial").unwrap();
    text(local.path(), &["add", "file"]).unwrap();
    text(local.path(), &["commit", "-qm", "Initial"]).unwrap();
    (local, remote)
}

#[test]
fn publishes_only_reviewed_branch_and_restores_tracking() {
    let (local, remote) = repositories();
    let dir = local.path();
    text(dir, &["branch", "unrelated"]).unwrap();
    text(dir, &["tag", "unrelated-tag"]).unwrap();
    text(dir, &["config", "push.default", "matching"]).unwrap();
    text(dir, &["config", "push.followTags", "true"]).unwrap();
    text(dir, &["config", "remote.origin.mirror", "true"]).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir.join(".git/config"), fs::Permissions::from_mode(0o600)).unwrap();
    }
    let reviewed = review(dir).unwrap();
    assert_eq!(reviewed.outgoing, Some(1));
    assert!(reviewed.set_upstream);
    let result = push(dir, "fixture-push-0001", &reviewed, false).unwrap();
    assert_eq!(result.state, "succeeded", "{}", result.message);
    assert_eq!(
        text(remote.path(), &["show-ref", "--heads"]).unwrap(),
        format!("{} refs/heads/main", reviewed.head)
    );
    assert!(text(remote.path(), &["show-ref", "--tags"]).is_err());
    assert_eq!(
        text(dir, &["rev-parse", "--abbrev-ref", "@{upstream}"]).unwrap(),
        "origin/main"
    );
    assert_eq!(review(dir).unwrap().outgoing, Some(0));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(dir.join(".git/config"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    assert_eq!(
        push(dir, "fixture-push-0001", &reviewed, false)
            .unwrap()
            .state,
        "succeeded"
    );
}

#[test]
fn changed_branch_head_or_destination_requires_a_new_review() {
    for change in ["branch", "head", "remote"] {
        let (local, remote) = repositories();
        let dir = local.path();
        let reviewed = review(dir).unwrap();
        match change {
            "branch" => {
                text(dir, &["switch", "-qc", "other"]).unwrap();
            }
            "head" => {
                text(dir, &["commit", "--allow-empty", "-qm", "New"]).unwrap();
            }
            _ => {
                text(
                    dir,
                    &["remote", "set-url", "origin", "missing-fixture-repository"],
                )
                .unwrap();
            }
        }
        let result = push(dir, "fixture-push-0002", &reviewed, false).unwrap();
        assert_eq!(result.state, "failed");
        assert!(text(remote.path(), &["show-ref", "--heads"]).is_err());
    }
}

#[test]
fn recovery_observes_a_landed_push_without_resending() {
    let (local, _remote) = repositories();
    let dir = local.path();
    let reviewed = review(dir).unwrap();
    let mut result = push(dir, "fixture-push-0003", &reviewed, false).unwrap();
    result.state = "started".into();
    save_receipt(
        &path(dir, &result.operation_id).unwrap(),
        &result,
        Some(&endpoint(dir, "origin").unwrap()),
    )
    .unwrap();
    let recovered = recover(dir, &result.operation_id).unwrap();
    assert_eq!(recovered.state, "succeeded");
    assert!(!recovered.retry_allowed);
}

#[test]
fn non_fast_forward_is_never_forced_and_retry_is_explicit() {
    let (local, remote) = repositories();
    let dir = local.path();
    let initial = review(dir).unwrap();
    push(dir, "fixture-push-0004", &initial, false).unwrap();
    text(dir, &["commit", "--allow-empty", "-qm", "Remote work"]).unwrap();
    let newer = review(dir).unwrap();
    push(dir, "fixture-push-0005", &newer, false).unwrap();
    text(dir, &["reset", "--hard", &initial.head]).unwrap();
    text(
        dir,
        &["commit", "--allow-empty", "-qm", "Different local work"],
    )
    .unwrap();
    let diverged = review(dir).unwrap();
    let result = push(dir, "fixture-push-0006", &diverged, false).unwrap();
    assert_eq!(result.state, "failed");
    assert!(!result.retry_allowed);
    let recovered = recover(dir, &result.operation_id).unwrap();
    assert!(!recovered.retry_allowed);
    assert_eq!(
        text(remote.path(), &["rev-parse", "refs/heads/main"]).unwrap(),
        newer.head
    );
}

#[test]
fn detached_head_and_missing_remote_are_actionable_failures() {
    let (local, _remote) = repositories();
    let dir = local.path();
    text(dir, &["switch", "--detach"]).unwrap();
    assert!(review(dir).unwrap_err().contains("detached"));
    text(dir, &["switch", "main"]).unwrap();
    text(dir, &["remote", "remove", "origin"]).unwrap();
    assert!(review(dir).is_err());
}

#[test]
fn interrupted_before_sending_requires_explicit_recovery_and_retry() {
    let (local, remote) = repositories();
    let dir = local.path();
    let reviewed = review(dir).unwrap();
    let started = Receipt {
        operation_id: "fixture-push-0007".into(),
        review: reviewed.clone(),
        state: "started".into(),
        message: "Started".into(),
        retry_allowed: false,
    };
    save_receipt(
        &path(dir, &started.operation_id).unwrap(),
        &started,
        Some(&endpoint(dir, "origin").unwrap()),
    )
    .unwrap();
    assert_eq!(
        push(dir, &started.operation_id, &reviewed, false)
            .unwrap()
            .state,
        "started"
    );
    assert!(text(remote.path(), &["show-ref", "--heads"]).is_err());
    let recovered = recover(dir, &started.operation_id).unwrap();
    assert!(recovered.retry_allowed);
    assert!(text(remote.path(), &["show-ref", "--heads"]).is_err());
    assert_eq!(
        push(dir, &started.operation_id, &reviewed, true)
            .unwrap()
            .state,
        "succeeded"
    );
    let mut different = reviewed.clone();
    different.remote_ref = "refs/heads/other".into();
    assert!(push(dir, &started.operation_id, &different, true).is_err());
}

#[test]
fn a_configuration_lock_is_preserved_after_successful_publication() {
    let (local, _remote) = repositories();
    let dir = local.path();
    let reviewed = review(dir).unwrap();
    let lock = dir.join(".git/config.lock");
    fs::write(&lock, "Another writer").unwrap();
    let result = push(dir, "fixture-push-0008", &reviewed, false).unwrap();
    assert_eq!(result.state, "succeeded");
    assert!(result.message.contains("Tracking could not be set"));
    assert_eq!(fs::read_to_string(lock).unwrap(), "Another writer");
}

#[test]
fn live_git_operations_exclude_push_and_recovery() {
    let (local, _remote) = repositories();
    let dir = local.path();
    let reviewed = review(dir).unwrap();
    let _lease = Lease::acquire(
        &index_path(dir)
            .unwrap()
            .with_file_name("tokenstat-git-operation.lock"),
    )
    .unwrap();
    assert!(push(dir, "fixture-push-0009", &reviewed, false).is_err());
    assert!(recover(dir, "fixture-push-0009").is_err());
}

#[test]
fn recovery_keeps_the_original_destination_after_remote_reconfiguration() {
    let (local, remote) = repositories();
    let dir = local.path();
    let reviewed = review(dir).unwrap();
    let mut result = push(dir, "fixture-push-0010", &reviewed, false).unwrap();
    result.state = "started".into();
    let url = endpoint(dir, "origin").unwrap();
    save_receipt(
        &path(dir, &result.operation_id).unwrap(),
        &result,
        Some(&url),
    )
    .unwrap();
    text(
        dir,
        &["remote", "set-url", "origin", "another-fixture-destination"],
    )
    .unwrap();
    let recovered = recover(dir, &result.operation_id).unwrap();
    assert_eq!(recovered.state, "succeeded");
    assert_eq!(
        text(remote.path(), &["rev-parse", "refs/heads/main"]).unwrap(),
        reviewed.head
    );
    assert!(
        !serde_json::to_string(&recovered).unwrap().contains(&url),
        "The client receipt never contains the URL"
    );
}
