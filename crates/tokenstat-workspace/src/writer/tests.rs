// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::process::{Child, Command};

#[test]
fn an_abandoned_claim_blocks_managed_writers_and_an_owned_completion_clears_only_its_exact_id() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("checkout");
    std::fs::create_dir(&folder).unwrap();
    let root = temp.path().join("locks");
    let mut lease = Lease::at(&folder, &root).unwrap();
    let id = "ab".repeat(32);
    lease.claim_run(&id).unwrap();
    lease.ensure_current().unwrap();
    assert_eq!(
        lease.clear_completed_run(&"cd".repeat(32)),
        Err(Error::Changed)
    );
    lease.ensure_current().unwrap();
    lease.clear_completed_run(&id).unwrap();
    drop(lease);
    let mut next = Lease::at(&folder, &root).unwrap();
    next.claim_run(&id).unwrap();
    drop(next);
    assert!(matches!(
        Lease::at(&folder, &root),
        Err(Error::RecoveryRequired)
    ));
    assert!(matches!(
        Lease::at(temp.path(), &root),
        Err(Error::Busy) | Err(Error::RecoveryRequired)
    ));
    let other = temp.path().join("independent");
    std::fs::create_dir(&other).unwrap();
    Lease::at(&other, &root).unwrap().ensure_current().unwrap();
}

#[test]
fn an_abandoned_common_git_claim_blocks_linked_checkouts_and_aliases() {
    let temp = tempfile::tempdir().unwrap();
    let main = temp.path().join("primary");
    repo(&main);
    let linked = temp.path().join("linked");
    git(
        &main,
        &[
            "worktree",
            "add",
            "-qb",
            "linked-fixture",
            linked.to_str().unwrap(),
        ],
    );
    let root = temp.path().join("locks");
    let mut lease = Lease::at(&main, &root).unwrap();
    lease.claim_run(&"ab".repeat(32)).unwrap();
    drop(lease);
    assert!(matches!(
        Lease::at(&linked, &root),
        Err(Error::RecoveryRequired)
    ));
    #[cfg(unix)]
    {
        let alias = temp.path().join("alias");
        std::os::unix::fs::symlink(&main, &alias).unwrap();
        assert!(matches!(
            Lease::at(&alias, &root),
            Err(Error::RecoveryRequired)
        ));
    }
}

#[test]
fn a_torn_or_missing_initialized_claim_registry_never_becomes_an_empty_registry() {
    for damage in ["empty", "missing", "checksum"] {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("checkout");
        std::fs::create_dir(&folder).unwrap();
        let root = temp.path().join("locks");
        let mut lease = Lease::at(&folder, &root).unwrap();
        lease.claim_run(&"ab".repeat(32)).unwrap();
        drop(lease);
        let path = root.join("claims.lock");
        match damage {
            "empty" => std::fs::write(&path, b"").unwrap(),
            "missing" => std::fs::remove_file(&path).unwrap(),
            _ => {
                let mut value: serde_json::Value =
                    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
                value["payload"]["claims"] = serde_json::json!({});
                std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            }
        }
        assert!(
            matches!(Lease::at(&folder, &root), Err(Error::RecoveryRequired)),
            "{damage}"
        );
    }
}

fn git(dir: &Path, args: &[&str]) {
    let output = crate::gitwrite::git_command(dir)
        .args([
            "-c",
            "core.hooksPath=",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
fn repo(path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    git(path, &["init", "-q"]);
    git(
        path,
        &["commit", "--allow-empty", "-qm", "Fixture baseline"],
    );
}

#[test]
fn linked_checkouts_conflict_but_independent_clones_do_not() {
    let temp = tempfile::tempdir().unwrap();
    let main = temp.path().join("primary");
    repo(&main);
    let linked = temp.path().join("linked");
    git(
        &main,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "linked-fixture",
            linked.to_str().unwrap(),
        ],
    );
    let clone = temp.path().join("clone");
    git(
        temp.path(),
        &[
            "clone",
            "-q",
            "--",
            main.to_str().unwrap(),
            clone.to_str().unwrap(),
        ],
    );
    let root = temp.path().join("locks");
    let first = Lease::at(&main, &root).unwrap();
    assert!(matches!(Lease::at(&linked, &root), Err(Error::Busy)));
    let independent = Lease::at(&clone, &root).unwrap();
    independent.ensure_current().unwrap();
    first.ensure_current().unwrap();
    drop(first);
    // A failed partial acquisition must not leave a linked-checkout lock.
    let next = Lease::at(&linked, &root).unwrap();
    next.ensure_current().unwrap();
    assert_eq!(
        crate::gitwrite::git_command(&linked)
            .args(["branch", "--show-current"])
            .output()
            .unwrap()
            .stdout,
        b"linked-fixture\n"
    );
}

#[test]
fn plain_folders_are_exclusive_and_release_on_drop_and_unwind() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("plain");
    std::fs::create_dir(&folder).unwrap();
    let root = temp.path().join("locks");
    let lease = Lease::at(&folder, &root).unwrap();
    assert!(matches!(Lease::at(&folder, &root), Err(Error::Busy)));
    drop(lease);
    let _ = std::panic::catch_unwind(|| {
        let _held = Lease::at(&folder, &root).unwrap();
        panic!("fixture unwind");
    });
    Lease::at(&folder, &root).unwrap().ensure_current().unwrap();
}

#[test]
fn nested_folders_conflict_in_both_directions_while_siblings_remain_independent() {
    let temp = tempfile::tempdir().unwrap();
    let parent = temp.path().join("parent");
    let child = parent.join("child");
    let sibling = parent.join("sibling");
    std::fs::create_dir_all(&child).unwrap();
    std::fs::create_dir(&sibling).unwrap();
    let root = temp.path().join("locks");
    let held = Lease::at(&parent, &root).unwrap();
    assert!(matches!(Lease::at(&child, &root), Err(Error::Busy)));
    drop(held);
    let held = Lease::at(&child, &root).unwrap();
    assert!(matches!(Lease::at(&parent, &root), Err(Error::Busy)));
    Lease::at(&sibling, &root)
        .unwrap()
        .ensure_current()
        .unwrap();
    held.ensure_current().unwrap();
}

#[cfg(unix)]
#[test]
fn aliases_and_subfolders_use_the_same_git_metadata_lock() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let main = temp.path().join(" leading and trailing ");
    repo(&main);
    let nested = main.join("nested");
    std::fs::create_dir(&nested).unwrap();
    let alias = temp.path().join("alias");
    symlink(&main, &alias).unwrap();
    let root = temp.path().join("locks");
    let held = Lease::at(&main, &root).unwrap();
    assert!(matches!(Lease::at(&alias, &root), Err(Error::Busy)));
    assert!(matches!(Lease::at(&nested, &root), Err(Error::Busy)));
    held.ensure_current().unwrap();
}

#[cfg(unix)]
#[test]
fn linked_metadata_paths_preserve_non_utf8_and_control_bytes() {
    use std::os::unix::ffi::OsStringExt;
    let temp = tempfile::tempdir().unwrap();
    let main = temp
        .path()
        .join(std::ffi::OsString::from_vec(b" space\xff\n\" ".to_vec()));
    if let Err(error) = std::fs::create_dir(&main) {
        // Some filesystems require UTF-8 names. Refusal must happen before
        // any coordination files or project effects are created.
        assert_eq!(error.raw_os_error(), Some(libc::EILSEQ));
        let root = temp.path().join("locks");
        assert!(matches!(Lease::at(&main, &root), Err(Error::Unavailable)));
        assert!(!root.exists());
        return;
    }
    repo(&main);
    let linked = temp.path().join("linked");
    git(
        &main,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "byte-fixture",
            linked.to_str().unwrap(),
        ],
    );
    let root = temp.path().join("locks");
    let held = Lease::at(&main, &root).unwrap();
    assert!(matches!(Lease::at(&linked, &root), Err(Error::Busy)));
    held.ensure_current().unwrap();
}

#[cfg(unix)]
#[test]
fn linked_metadata_paths_preserve_unicode_quotes_newlines_and_whitespace() {
    let temp = tempfile::tempdir().unwrap();
    let main = temp.path().join(" Équipe \n\" ");
    repo(&main);
    let linked = temp.path().join("linked");
    git(
        &main,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "unicode-fixture",
            linked.to_str().unwrap(),
        ],
    );
    let root = temp.path().join("locks");
    let held = Lease::at(&main, &root).unwrap();
    assert!(matches!(Lease::at(&linked, &root), Err(Error::Busy)));
    held.ensure_current().unwrap();
}

#[cfg(unix)]
#[test]
fn replacement_or_symlinked_lock_retires_the_original_writer() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("folder");
    std::fs::create_dir(&folder).unwrap();
    let lease = Lease::at(&folder, &temp.path().join("locks")).unwrap();
    let path = &lease.locks[0].0;
    let old = path.with_extension("old");
    std::fs::rename(path, &old).unwrap();
    symlink(&old, path).unwrap();
    assert_eq!(lease.ensure_current(), Err(Error::Changed));
    std::fs::remove_file(path).unwrap();
    std::fs::rename(&old, path).unwrap();
    assert_eq!(
        lease.ensure_current(),
        Err(Error::Changed),
        "a retired writer cannot revive"
    );
}

#[cfg(unix)]
#[test]
fn replaced_folder_does_not_gain_the_old_writer() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("folder");
    std::fs::create_dir(&folder).unwrap();
    let lease = Lease::at(&folder, &temp.path().join("locks")).unwrap();
    std::fs::rename(&folder, temp.path().join("original")).unwrap();
    std::fs::create_dir(&folder).unwrap();
    assert_eq!(lease.ensure_current(), Err(Error::Changed));
}

#[test]
fn broken_git_metadata_is_never_treated_as_a_plain_folder() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("folder");
    std::fs::create_dir(&folder).unwrap();
    std::fs::write(folder.join(".git"), "gitdir: missing\n").unwrap();
    assert!(matches!(
        Lease::at(&folder, &temp.path().join("locks")),
        Err(Error::Unavailable)
    ));
}

#[test]
fn active_writer_blocks_real_git_and_editor_effects_but_leaves_status_readable() {
    let temp = tempfile::tempdir().unwrap();
    let main = temp.path().join("main");
    repo(&main);
    std::fs::write(main.join("file.txt"), "keep this writing\n").unwrap();
    let before = crate::gitwrite::git_command(&main)
        .args(["rev-parse", "HEAD"])
        .output()
        .unwrap()
        .stdout;
    let held = Lease::acquire(&main).unwrap();
    assert!(!crate::gitwrite::stage(&main, &["file.txt".into()]).ok);
    assert!(!crate::gitwrite::create_branch(&main, "blocked-fixture", None).ok);
    assert!(!crate::gitwrite::write_text(&main, "file.txt", "replace").ok);
    let destination = temp.path().join("worktree");
    assert!(
        !crate::gitwrite::worktree::create(&main, &destination, "fixture", "blocked", "HEAD").ok
    );
    assert!(!destination.exists());
    assert_eq!(
        std::fs::read_to_string(main.join("file.txt")).unwrap(),
        "keep this writing\n"
    );
    assert_eq!(
        crate::gitwrite::git_command(&main)
            .args(["rev-parse", "HEAD"])
            .output()
            .unwrap()
            .stdout,
        before
    );
    assert!(crate::git::status(&main).is_repo);
    drop(held);
    assert!(crate::gitwrite::stage(&main, &["file.txt".into()]).ok);
    assert!(crate::gitwrite::write_text(&main, "file.txt", "explicit save after release").ok);
}

#[test]
fn bare_repository_and_its_linked_checkout_share_a_writer() {
    let temp = tempfile::tempdir().unwrap();
    let main = temp.path().join("main");
    repo(&main);
    let bare = temp.path().join("bare");
    git(
        temp.path(),
        &[
            "clone",
            "-q",
            "--bare",
            "--",
            main.to_str().unwrap(),
            bare.to_str().unwrap(),
        ],
    );
    let linked = temp.path().join("linked");
    git(
        &bare,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "linked-fixture",
            linked.to_str().unwrap(),
        ],
    );
    let root = temp.path().join("locks");
    let _held = Lease::at(&bare, &root).unwrap();
    assert!(matches!(Lease::at(&linked, &root), Err(Error::Busy)));
}

struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn independent_process_ownership_releases_after_process_exit() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("folder");
    std::fs::create_dir(&folder).unwrap();
    let root = temp.path().join("locks");
    let ready = temp.path().join("ready");
    let mut child = Process(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "writer::tests::lease_process_child",
                "--ignored",
                "--nocapture",
            ])
            .env("TOKENSTAT_WRITER_FIXTURE_FOLDER", &folder)
            .env("TOKENSTAT_WRITER_FIXTURE_LOCKS", &root)
            .env("TOKENSTAT_WRITER_FIXTURE_READY", &ready)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() {
        assert!(
            Instant::now() < deadline && child.0.try_wait().unwrap().is_none(),
            "owned fixture did not acquire its lease"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(matches!(Lease::at(&folder, &root), Err(Error::Busy)));
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    Lease::at(&folder, &root).unwrap().ensure_current().unwrap();
}

#[test]
#[ignore = "owned child of independent_process_ownership_releases_after_process_exit"]
fn lease_process_child() {
    let Some(folder) = std::env::var_os("TOKENSTAT_WRITER_FIXTURE_FOLDER") else {
        return;
    };
    let root = std::env::var_os("TOKENSTAT_WRITER_FIXTURE_LOCKS").unwrap();
    let ready = std::env::var_os("TOKENSTAT_WRITER_FIXTURE_READY").unwrap();
    let _held = Lease::at(Path::new(&folder), Path::new(&root)).unwrap();
    std::fs::write(ready, b"ready").unwrap();
    std::thread::sleep(Duration::from_secs(10));
}
