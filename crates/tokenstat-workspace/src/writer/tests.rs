// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::process::{Child, Command};

#[test]
fn recovery_is_scoped_to_the_run_and_completion_clears_only_its_exact_id() {
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
    let mut duplicate = Lease::at(&folder, &root).unwrap();
    assert_eq!(duplicate.claim_run(&id), Err(Error::RecoveryRequired));
    duplicate.ensure_current().unwrap();
    let mut unrelated = Lease::at(&folder, &root).unwrap();
    let other_id = "ef".repeat(32);
    unrelated.claim_run(&other_id).unwrap();
    Lease::at(temp.path(), &root)
        .unwrap()
        .ensure_current()
        .unwrap();
    assert_eq!(
        claim::clear_orphaned_run_at("not-an-id", &root),
        Err(Error::Changed)
    );
    claim::clear_orphaned_run_at(&id, &root).unwrap();
    unrelated.ensure_current().unwrap();
    assert_eq!(duplicate.claim_run(&other_id), Err(Error::RecoveryRequired));
    duplicate.claim_run(&id).unwrap();
    duplicate.clear_completed_run(&id).unwrap();
    unrelated.clear_completed_run(&other_id).unwrap();
    Lease::at(&folder, &root).unwrap().ensure_current().unwrap();
    // Clearing a claim that is already gone changes nothing.
    claim::clear_orphaned_run_at(&id, &root).unwrap();
    let other = temp.path().join("independent");
    std::fs::create_dir(&other).unwrap();
    Lease::at(&other, &root).unwrap().ensure_current().unwrap();
}

#[test]
fn an_abandoned_run_does_not_block_linked_checkouts_or_aliases() {
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
    let mut other = Lease::at(&linked, &root).unwrap();
    other.claim_run(&"cd".repeat(32)).unwrap();
    other.ensure_current().unwrap();
    #[cfg(unix)]
    {
        let alias = temp.path().join("alias");
        std::os::unix::fs::symlink(&main, &alias).unwrap();
        Lease::at(&alias, &root).unwrap().ensure_current().unwrap();
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
        // Ordinary operations do not depend on recovery records. A Team run
        // must still refuse to overwrite a damaged registry.
        let mut ordinary = Lease::at(&folder, &root).unwrap();
        ordinary.ensure_current().unwrap();
        let result = ordinary.claim_run(&"cd".repeat(32));
        let present = std::fs::read_dir(&root)
            .map(|entries| {
                entries
                    .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
                    .collect::<Vec<_>>()
            })
            .ok();
        assert!(
            matches!(result, Err(Error::RecoveryRequired)),
            "{damage}: {result:?}; {present:?}"
        );
    }
}

#[test]
fn lanes_run_beside_the_main_checkout_and_each_other() {
    let temp = tempfile::tempdir().unwrap();
    let main = temp.path().join("primary");
    repo(&main);
    let lanes = temp.path().join("lanes");
    std::fs::create_dir(&lanes).unwrap();
    let (a, b) = (lanes.join("a"), lanes.join("b"));
    for (lane, branch) in [(&a, "lane-a"), (&b, "lane-b")] {
        git(
            &main,
            &["worktree", "add", "-qb", branch, lane.to_str().unwrap()],
        );
    }
    let root = temp.path().join("locks");
    let main_lease = Lease::at(&main, &root).unwrap();
    let mut first = Lease::at_with(&a, None, &root, true).unwrap();
    let second = Lease::at_with(&b, None, &root, true).unwrap();
    Lease::at_with(&a, None, &root, true).unwrap();
    first.claim_run(&"ab".repeat(32)).unwrap();
    first.ensure_current().unwrap();
    drop(main_lease);
    // A run's recovery record does not reserve its lane or the project.
    Lease::at(&main, &root).unwrap().ensure_current().unwrap();
    drop((first, second));
    Lease::at_with(&a, None, &root, true).unwrap();
    Lease::at_with(&b, None, &root, true).unwrap();
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
fn linked_checkouts_and_independent_clones_can_run_concurrently() {
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
    let linked_lease = Lease::at(&linked, &root).unwrap();
    let independent = Lease::at(&clone, &root).unwrap();
    independent.ensure_current().unwrap();
    first.ensure_current().unwrap();
    linked_lease.ensure_current().unwrap();
    drop(first);
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
fn ordinary_operations_do_not_create_checkout_lock_files() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("plain");
    std::fs::create_dir(&folder).unwrap();
    let root = temp.path().join("locks");
    let lease = Lease::at(&folder, &root).unwrap();
    Lease::at(&folder, &root).unwrap().ensure_current().unwrap();
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), 0);
    drop(lease);
    let _ = std::panic::catch_unwind(|| {
        let _held = Lease::at(&folder, &root).unwrap();
        panic!("fixture unwind");
    });
    Lease::at(&folder, &root).unwrap().ensure_current().unwrap();
}

#[test]
fn nested_folders_and_siblings_can_run_concurrently() {
    let temp = tempfile::tempdir().unwrap();
    let parent = temp.path().join("parent");
    let child = parent.join("child");
    let sibling = parent.join("sibling");
    std::fs::create_dir_all(&child).unwrap();
    std::fs::create_dir(&sibling).unwrap();
    let root = temp.path().join("locks");
    let held = Lease::at(&parent, &root).unwrap();
    Lease::at(&child, &root).unwrap().ensure_current().unwrap();
    drop(held);
    let held = Lease::at(&child, &root).unwrap();
    Lease::at(&parent, &root).unwrap().ensure_current().unwrap();
    Lease::at(&sibling, &root)
        .unwrap()
        .ensure_current()
        .unwrap();
    held.ensure_current().unwrap();
}

#[cfg(unix)]
#[test]
fn aliases_and_subfolders_do_not_reserve_shared_git_metadata() {
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
    Lease::at(&alias, &root).unwrap().ensure_current().unwrap();
    Lease::at(&nested, &root).unwrap().ensure_current().unwrap();
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
    Lease::at(&linked, &root).unwrap().ensure_current().unwrap();
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
    Lease::at(&linked, &root).unwrap().ensure_current().unwrap();
    held.ensure_current().unwrap();
}

#[cfg(unix)]
#[test]
fn old_checkout_lock_files_do_not_affect_operations() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("folder");
    std::fs::create_dir(&folder).unwrap();
    let lease = Lease::at(&folder, &temp.path().join("locks")).unwrap();
    let path = &lease.root.path.join(lease.target.folder.identity.name());
    let legacy = file::lock(path, true).unwrap();
    lease.ensure_current().unwrap();
    Lease::at(&folder, &lease.root.path).unwrap();
    let old = path.with_extension("old");
    std::fs::rename(path, &old).unwrap();
    symlink(&old, path).unwrap();
    lease.ensure_current().unwrap();
    Lease::at(&folder, &lease.root.path).unwrap();
    std::fs::remove_file(path).unwrap();
    std::fs::rename(&old, path).unwrap();
    lease.ensure_current().unwrap();
    drop(legacy);
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
    std::fs::remove_dir(&folder).unwrap();
    std::fs::rename(temp.path().join("original"), &folder).unwrap();
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
fn another_operation_does_not_block_git_or_editor_actions() {
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
    assert!(crate::gitwrite::stage(&main, &["file.txt".into()]).ok);
    assert!(crate::gitwrite::create_branch(&main, "concurrent-fixture", None).ok);
    assert!(crate::gitwrite::write_text(&main, "file.txt", "replace").ok);
    let destination = temp.path().join("worktree");
    assert!(
        crate::gitwrite::worktree::create(&main, &destination, "fixture", "concurrent", "HEAD").ok
    );
    assert!(destination.is_dir());
    assert_eq!(
        std::fs::read_to_string(main.join("file.txt")).unwrap(),
        "replace"
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
fn bare_repository_and_its_linked_checkout_can_run_concurrently() {
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
    Lease::at(&linked, &root).unwrap().ensure_current().unwrap();
}

struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn a_separate_process_does_not_reserve_the_checkout() {
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
    Lease::at(&folder, &root).unwrap().ensure_current().unwrap();
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    Lease::at(&folder, &root).unwrap().ensure_current().unwrap();
}

#[test]
#[ignore = "owned child of a_separate_process_does_not_reserve_the_checkout"]
fn lease_process_child() {
    let Some(folder) = std::env::var_os("TOKENSTAT_WRITER_FIXTURE_FOLDER") else {
        return;
    };
    let root = std::env::var_os("TOKENSTAT_WRITER_FIXTURE_LOCKS").unwrap();
    let ready = std::env::var_os("TOKENSTAT_WRITER_FIXTURE_READY").unwrap();
    let held = Lease::at(Path::new(&folder), Path::new(&root)).unwrap();
    // Model a still-running host from before checkout locks were removed.
    let _legacy: Vec<_> = held
        .target
        .requests()
        .into_iter()
        .map(|(id, exclusive)| file::lock(&held.root.path.join(id.name()), exclusive).unwrap())
        .collect();
    std::fs::write(ready, b"ready").unwrap();
    std::thread::sleep(Duration::from_secs(10));
}
