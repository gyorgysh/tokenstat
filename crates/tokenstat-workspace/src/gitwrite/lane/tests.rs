// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn git(dir: &Path, args: &[&str]) -> String {
    let output = git_command(dir)
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgSign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

struct Fixture {
    _temp: tempfile::TempDir,
    remote: PathBuf,
    main: PathBuf,
    lanes: PathBuf,
}

/// A bare remote, a publisher's clone, and an empty folder for lanes.
fn fixture() -> Fixture {
    let temp = tempfile::tempdir().unwrap();
    let remote = temp.path().join("remote.git");
    let main = temp.path().join("main");
    let lanes = temp.path().join("lanes");
    std::fs::create_dir(&lanes).unwrap();
    git(
        temp.path(),
        &[
            "init",
            "-q",
            "--bare",
            "-b",
            "main",
            remote.to_str().unwrap(),
        ],
    );
    git(
        temp.path(),
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            main.to_str().unwrap(),
        ],
    );
    git(&main, &["checkout", "-q", "-b", "main"]);
    std::fs::write(main.join("a.txt"), "one\ntwo\nthree\n").unwrap();
    std::fs::write(main.join("b.txt"), "b\n").unwrap();
    git(&main, &["add", "-A"]);
    git(&main, &["commit", "-qm", "Baseline"]);
    git(&main, &["push", "-q", "origin", "main"]);
    Fixture {
        _temp: temp,
        remote,
        main,
        lanes,
    }
}

fn identity(lane: &Path) {
    git(lane, &["config", "user.name", "Fixture"]);
    git(lane, &["config", "user.email", "fixture@example.invalid"]);
    git(lane, &["config", "commit.gpgSign", "false"]);
}

fn lane(f: &Fixture, name: &str) -> PathBuf {
    let path = f.lanes.join(name);
    create(&f.main, &path, &format!("team/{name}"), "origin/main").unwrap();
    identity(&path);
    path
}

fn remote_file(f: &Fixture, file: &str) -> String {
    git(&f.remote, &["show", &format!("main:{file}")])
}

#[test]
fn two_lanes_land_one_after_the_other_without_touching_the_main_folder() {
    let f = fixture();
    let (a, b) = (lane(&f, "a"), lane(&f, "b"));
    std::fs::write(a.join("a.txt"), "one\ntwo\nthree\nfour\n").unwrap();
    std::fs::write(b.join("b.txt"), "b\nmore\n").unwrap();
    assert!(commit_all(&a, "Add four").unwrap());
    assert!(commit_all(&b, "Extend b").unwrap());
    assert!(matches!(
        land(&a, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    // b was cut before a landed. It rebases onto a's result and lands too.
    assert!(matches!(
        land(&b, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    assert_eq!(remote_file(&f, "a.txt"), "one\ntwo\nthree\nfour");
    assert_eq!(remote_file(&f, "b.txt"), "b\nmore");
    // The publisher's own folder is exactly as it was.
    assert_eq!(
        std::fs::read_to_string(f.main.join("a.txt")).unwrap(),
        "one\ntwo\nthree\n"
    );
    assert_eq!(git(&f.main, &["status", "--porcelain"]), "");
}

#[test]
fn a_real_conflict_is_reported_and_leaves_the_lane_unchanged() {
    let f = fixture();
    let (a, b) = (lane(&f, "a"), lane(&f, "b"));
    std::fs::write(a.join("a.txt"), "one\nTWO from a\nthree\n").unwrap();
    std::fs::write(b.join("a.txt"), "one\nTWO from b\nthree\n").unwrap();
    commit_all(&a, "a edits line two").unwrap();
    commit_all(&b, "b edits line two").unwrap();
    assert!(matches!(
        land(&a, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    let before = git(&b, &["rev-parse", "HEAD"]);
    assert_eq!(
        land(&b, "main", Some("origin"), &[]),
        Landing::Conflict {
            files: vec!["a.txt".into()]
        }
    );
    assert_eq!(git(&b, &["rev-parse", "HEAD"]), before);
    assert_eq!(git(&b, &["status", "--porcelain"]), "");
}

#[cfg(unix)]
#[test]
fn a_failing_check_blocks_landing_and_reports_its_output() {
    let f = fixture();
    let a = lane(&f, "a");
    std::fs::write(a.join("a.txt"), "broken\n").unwrap();
    commit_all(&a, "Break it").unwrap();
    let check = [
        "/bin/sh".to_string(),
        "-c".into(),
        "echo tests failed; exit 1".into(),
    ];
    match land(&a, "main", Some("origin"), &check) {
        Landing::CheckFailed { output } => assert!(output.contains("tests failed")),
        other => panic!("{other:?}"),
    }
    assert_eq!(remote_file(&f, "a.txt"), "one\ntwo\nthree");
    let pass = ["/bin/sh".to_string(), "-c".into(), "exit 0".into()];
    assert!(matches!(
        land(&a, "main", Some("origin"), &pass),
        Landing::Landed { .. }
    ));
    // The check log never enters the lane's working tree.
    assert_eq!(git(&a, &["status", "--porcelain"]), "");
}

#[test]
fn nothing_to_land_and_cleanup() {
    let f = fixture();
    let a = lane(&f, "a");
    assert!(!commit_all(&a, "Nothing").unwrap());
    assert_eq!(land(&a, "main", Some("origin"), &[]), Landing::Nothing);
    remove(&f.main, &a, "team/a").unwrap();
    assert!(!a.exists());
    assert!(git(&f.main, &["branch", "--list", "team/a"]).is_empty());
}

#[test]
fn without_a_remote_a_checked_out_target_is_not_moved() {
    let f = fixture();
    git(&f.main, &["remote", "remove", "origin"]);
    let a = f.lanes.join("a");
    create(&f.main, &a, "team/a", "main").unwrap();
    identity(&a);
    std::fs::write(a.join("b.txt"), "local\n").unwrap();
    commit_all(&a, "Local").unwrap();
    assert!(matches!(
        land(&a, "main", None, &[]),
        Landing::Blocked { .. }
    ));
}

#[test]
fn a_conflict_is_left_for_the_agent_and_lands_once_resolved() {
    let f = fixture();
    let (a, b) = (lane(&f, "a"), lane(&f, "b"));
    std::fs::write(a.join("a.txt"), "one\nTWO from a\nthree\n").unwrap();
    std::fs::write(b.join("a.txt"), "one\nTWO from b\nthree\n").unwrap();
    commit_all(&a, "a").unwrap();
    commit_all(&b, "b").unwrap();
    assert!(matches!(
        land(&a, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    assert_eq!(
        start_rebase(&b, "main", Some("origin")).unwrap(),
        vec!["a.txt".to_string()]
    );
    assert!(
        std::fs::read_to_string(b.join("a.txt"))
            .unwrap()
            .contains("<<<<<<<")
    );
    // Markers left behind are refused, and the lane goes back to its own work.
    assert!(finish_rebase(&b).is_err());
    assert_eq!(
        std::fs::read_to_string(b.join("a.txt")).unwrap(),
        "one\nTWO from b\nthree\n"
    );
    // A resolved conflict finishes and lands on top of a.
    start_rebase(&b, "main", Some("origin")).unwrap();
    std::fs::write(b.join("a.txt"), "one\nTWO from a and b\nthree\n").unwrap();
    finish_rebase(&b).unwrap();
    assert!(matches!(
        land(&b, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    assert_eq!(remote_file(&f, "a.txt"), "one\nTWO from a and b\nthree");
}

#[cfg(unix)]
#[test]
fn links_out_of_the_lane_are_found_and_hooks_never_run() {
    let f = fixture();
    let a = lane(&f, "a");
    assert_eq!(escaping_link(&a).unwrap(), None);
    std::os::unix::fs::symlink("a.txt", a.join("inside")).unwrap();
    assert_eq!(escaping_link(&a).unwrap(), None);
    std::os::unix::fs::symlink(&f.main, a.join("outside")).unwrap();
    assert_eq!(
        escaping_link(&a).unwrap(),
        Some(a.canonicalize().unwrap().join("outside"))
    );
    std::fs::remove_file(a.join("outside")).unwrap();
    // A hook in the shared git directory is not run by a lane commit.
    let hooks = f.main.join(".git/hooks");
    std::fs::create_dir_all(&hooks).unwrap();
    let marker = f.lanes.join("hook-ran");
    std::fs::write(
        hooks.join("pre-commit"),
        format!("#!/bin/sh\ntouch {}\n", marker.display()),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        hooks.join("pre-commit"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    std::fs::write(a.join("b.txt"), "changed\n").unwrap();
    assert!(commit_all(&a, "Change").unwrap());
    assert!(!marker.exists());
    assert!(pointer(&a).unwrap().starts_with("gitdir: "));
}

#[test]
fn a_teammates_landing_reaches_a_clean_checkout_and_leaves_others_alone() {
    let f = fixture();
    let a = lane(&f, "a");
    std::fs::write(a.join("b.txt"), "landed\n").unwrap();
    commit_all(&a, "Landed by a teammate").unwrap();
    assert!(matches!(
        land(&a, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    // Uncommitted work is never touched.
    std::fs::write(f.main.join("a.txt"), "unsaved\n").unwrap();
    assert_eq!(catch_up(&f.main, "main", "origin"), CatchUp::Dirty);
    git(&f.main, &["checkout", "-q", "--", "a.txt"]);
    assert_eq!(catch_up(&f.main, "main", "origin"), CatchUp::Updated);
    assert_eq!(
        std::fs::read_to_string(f.main.join("b.txt")).unwrap(),
        "landed\n"
    );
    assert_eq!(catch_up(&f.main, "main", "origin"), CatchUp::Current);
    // Another branch, or local commits of its own, are left for the person.
    git(&f.main, &["checkout", "-q", "-b", "feature"]);
    assert_eq!(catch_up(&f.main, "main", "origin"), CatchUp::OtherBranch);
    git(&f.main, &["checkout", "-q", "main"]);
    std::fs::write(f.main.join("a.txt"), "local commit\n").unwrap();
    git(&f.main, &["commit", "-qam", "Local"]);
    let b = lane(&f, "b");
    std::fs::write(b.join("b.txt"), "landed again\n").unwrap();
    commit_all(&b, "Second landing").unwrap();
    assert!(matches!(
        land(&b, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    assert_eq!(catch_up(&f.main, "main", "origin"), CatchUp::Diverged);
}

#[test]
fn a_prepared_lane_waits_and_lands_later_on_the_newest_target() {
    let f = fixture();
    let (a, b) = (lane(&f, "a"), lane(&f, "b"));
    std::fs::write(a.join("a.txt"), "one\ntwo\nthree\nreviewed\n").unwrap();
    commit_all(&a, "Reviewed change").unwrap();
    assert!(matches!(
        prepare(&a, "main", Some("origin"), &[]),
        Landing::Ready { .. }
    ));
    assert_eq!(remote_file(&f, "a.txt"), "one\ntwo\nthree");
    // Somebody else lands first; the reviewed lane still lands on top.
    std::fs::write(b.join("b.txt"), "b first\n").unwrap();
    commit_all(&b, "First").unwrap();
    assert!(matches!(
        land(&b, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    assert!(matches!(
        land(&a, "main", Some("origin"), &[]),
        Landing::Landed { .. }
    ));
    assert_eq!(remote_file(&f, "a.txt"), "one\ntwo\nthree\nreviewed");
    assert_eq!(remote_file(&f, "b.txt"), "b first");
}
