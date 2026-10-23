// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#![cfg(feature = "local-host")]

use std::{
    collections::BTreeMap,
    fs, io,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
    time::{Duration, Instant},
};
use tokenstat_host::team_process::{Owned, Poll, Program};

fn fake() -> &'static Path {
    static FIXTURE: OnceLock<tempfile::TempDir> = OnceLock::new();
    let root = FIXTURE.get_or_init(|| {
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join(if cfg!(windows) {
            "fake-agent.exe"
        } else {
            "fake-agent"
        });
        let source =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/qa/teams/fake_agent.rs");
        let status = Command::new(std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into()))
            .args(["--edition=2024"])
            .arg(source)
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap();
        assert!(status.success());
        root
    });
    let executable = root.path().join(if cfg!(windows) {
        "fake-agent.exe"
    } else {
        "fake-agent"
    });
    // Stable owned fixture path; the TempDir outlives every test thread.
    static PATH: OnceLock<PathBuf> = OnceLock::new();
    PATH.get_or_init(|| executable)
}
fn program(root: &Path, mode: &str) -> Program {
    let input = root.join("input");
    fs::write(&input, r#"{"message":{"text":"Fictional supervised Ask"}}"#).unwrap();
    Program {
        executable: fake().into(),
        args: vec![
            mode.into(),
            root.join("processes").to_string_lossy().into_owned(),
        ],
        env: BTreeMap::new(),
        folder: root.into(),
        input,
        output: root.join("output"),
        errors: root.join("errors"),
    }
}
fn wait(mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(8);
    while !ready() {
        assert!(
            Instant::now() < deadline,
            "Owned process fixture did not reach its expected state."
        );
        std::thread::sleep(Duration::from_millis(15));
    }
}
fn started(process: &mut Owned) {
    wait(|| matches!(process.poll().unwrap(), Poll::Started));
}
fn beat(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

#[test]
fn closed_output_cannot_complete_an_owned_backend_and_stop_freezes_its_descendant() {
    let root = tempfile::tempdir().unwrap();
    let mut process = Owned::start(
        Path::new(env!("CARGO_BIN_EXE_tokenstat-hostd")),
        program(root.path(), "hold"),
        |_| Ok(()),
    )
    .unwrap();
    started(&mut process);
    let root_beat = root.path().join("processes.root");
    let leaf = root.path().join("processes.leaf");
    wait(|| !beat(&root_beat).is_empty() && !beat(&leaf).is_empty());
    let first = beat(&leaf);
    wait(|| beat(&leaf) != first);
    assert!(matches!(process.poll().unwrap(), Poll::Running));
    let _proof = process.stop().unwrap();
    let last = beat(&leaf);
    std::thread::sleep(Duration::from_millis(180));
    assert_eq!(beat(&leaf), last);
    assert!(process.stop().is_err());
    assert!(process.poll().is_err());
}

#[test]
fn foreground_exit_leaves_a_live_descendant_until_the_exact_owner_stops() {
    let root = tempfile::tempdir().unwrap();
    let mut process = Owned::start(
        Path::new(env!("CARGO_BIN_EXE_tokenstat-hostd")),
        program(root.path(), "finish"),
        |_| Ok(()),
    )
    .unwrap();
    wait(|| matches!(process.poll().unwrap(), Poll::Exited(Some(0))));
    let leaf = root.path().join("processes.leaf");
    wait(|| !beat(&leaf).is_empty());
    let first = beat(&leaf);
    wait(|| beat(&leaf) != first);
    let _proof = process.stop().unwrap();
    let last = beat(&leaf);
    std::thread::sleep(Duration::from_millis(180));
    assert_eq!(beat(&leaf), last);
}

#[test]
fn refusal_after_anchor_birth_prevents_any_backend_birth() {
    let root = tempfile::tempdir().unwrap();
    let result = Owned::start(
        Path::new(env!("CARGO_BIN_EXE_tokenstat-hostd")),
        program(root.path(), "hold"),
        |_| Err(io::Error::other("Fixture admission expired.")),
    );
    assert!(result.is_err());
    assert!(!root.path().join("processes").exists());
    assert!(!root.path().join("output").exists());
}

#[test]
fn delayed_admission_cannot_extend_a_one_shot_backend_birth_window() {
    let root = tempfile::tempdir().unwrap();
    let result = Owned::start(
        Path::new(env!("CARGO_BIN_EXE_tokenstat-hostd")),
        program(root.path(), "hold"),
        |_| {
            std::thread::sleep(Duration::from_millis(2200));
            Ok(())
        },
    );
    assert!(result.is_err());
    assert!(!root.path().join("processes").exists());
    assert!(!root.path().join("output").exists());
}

#[test]
fn stopping_one_owner_never_stops_an_independent_run() {
    let one = tempfile::tempdir().unwrap();
    let two = tempfile::tempdir().unwrap();
    let helper = Path::new(env!("CARGO_BIN_EXE_tokenstat-hostd"));
    let mut first = Owned::start(helper, program(one.path(), "hold"), |_| Ok(())).unwrap();
    let mut second = Owned::start(helper, program(two.path(), "hold"), |_| Ok(())).unwrap();
    started(&mut first);
    started(&mut second);
    let leaf = two.path().join("processes.leaf");
    wait(|| !beat(&leaf).is_empty());
    let _proof = first.stop().unwrap();
    let before = beat(&leaf);
    wait(|| beat(&leaf) != before);
    assert!(matches!(second.poll().unwrap(), Poll::Running));
    let _proof = second.stop().unwrap();
}

#[test]
fn a_definite_backend_spawn_failure_remains_distinct_from_process_completion() {
    let root = tempfile::tempdir().unwrap();
    let mut configured = program(root.path(), "hold");
    configured.executable = root.path().join("missing-fixture-executable");
    let mut process = Owned::start(
        Path::new(env!("CARGO_BIN_EXE_tokenstat-hostd")),
        configured,
        |_| Ok(()),
    )
    .unwrap();
    wait(|| matches!(process.poll().unwrap(), Poll::LaunchFailed));
    assert!(!root.path().join("processes").exists());
    let _proof = process.stop().unwrap();
}

#[cfg(unix)]
#[test]
fn a_descendant_in_another_group_cannot_prove_run_completion() {
    struct ReleaseLeaf(PathBuf);
    impl Drop for ReleaseLeaf {
        fn drop(&mut self) {
            let _ = fs::write(self.0.with_extension("release"), "release");
        }
    }
    let root = tempfile::tempdir().unwrap();
    let anchor = std::cell::Cell::new(0);
    let mut process = Owned::start(
        Path::new(env!("CARGO_BIN_EXE_tokenstat-hostd")),
        program(root.path(), "separate-group"),
        |group| {
            anchor.set(group);
            Ok(())
        },
    )
    .unwrap();
    // Release before Owned drops on every assertion/panic path, so cleanup
    // never signals a possibly reused grandchild PID.
    let control = root.path().join("processes.control");
    let release = ReleaseLeaf(control.clone());
    wait(|| matches!(process.poll().unwrap(), Poll::Exited(Some(0))));
    let leaf = root.path().join("processes.leaf");
    wait(|| !beat(&leaf).is_empty());
    let pids = fs::read_to_string(root.path().join("processes")).unwrap();
    let leaf_pid = pids
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse::<i32>()
        .unwrap();
    let stopped = process.stop();
    // A fixed heartbeat sampling window can see no progress on a loaded CI
    // runner. Ask for a fresh acknowledgement after Stop instead: the child
    // must execute this request while its original owner refuses completion.
    fs::write(control.with_extension("probe"), "after-stop").unwrap();
    wait(|| beat(&control.with_extension("ack")) == "after-stop");
    // SAFETY: these queries deliver no signal. The acknowledgement above
    // proves the fixture is running; its group must differ from the anchor.
    let (group, session) = unsafe { (libc::getpgid(leaf_pid), libc::getsid(leaf_pid)) };
    drop(release);
    wait(|| control.with_extension("released").exists());
    let cleanup = stopped.is_err().then(|| process.stop());
    assert!(stopped.is_err(), "a live descendant was reported completed");
    assert_eq!(
        group, leaf_pid,
        "fixture did not lead its own process group"
    );
    assert_eq!(
        session,
        anchor.get() as i32,
        "fixture left its owner's session"
    );
    let _proof = cleanup.unwrap().unwrap();
}
