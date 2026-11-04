// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::time::Instant;

struct Session(String);
impl Drop for Session {
    fn drop(&mut self) {
        let _ = tokenstat_pty::manager().close(&self.0);
    }
}
fn wait_until(phase: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready() {
        assert!(
            Instant::now() < deadline,
            "owned writer fixture did not settle: {phase}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn request(folder: &Path, script: &str) -> tokenstat_pty::Spawn {
    tokenstat_pty::Spawn {
        command: "/bin/sh".into(),
        args: vec!["-c".into(), script.into()],
        cwd: folder.to_owned(),
        workspace_id: None,
        hidden: true,
        rows: 24,
        cols: 80,
        no_color: false,
        dark: None,
        environment: Vec::new(),
    }
}

#[test]
fn closed_output_and_a_dropped_guard_cannot_release_a_still_running_writer() {
    let temp = tempfile::tempdir().unwrap();
    let mut writer = Guard::acquire(temp.path()).unwrap();
    let info = writer.spawn_piped(&request(temp.path(), "exec </dev/null >/dev/null 2>&1; echo ready > ready.txt; while [ ! -f release.txt ]; do sleep 0.02; done; echo done > done.txt")).unwrap();
    let _session = Session(info.id);
    wait_until("stream closure while the root stays alive", || {
        temp.path().join("ready.txt").exists() && writer.process.as_ref().unwrap().output_closed()
    });
    let process = writer.process.as_ref().unwrap().clone();
    assert!(
        !process.completed(),
        "stream EOF is not a process exit receipt"
    );
    drop(writer);
    assert!(pending_count() >= 1);
    assert!(
        matches!(Lease::acquire(temp.path()), Err(Error::Busy)),
        "a lost local guard released a live writer"
    );
    std::fs::write(temp.path().join("release.txt"), b"release").unwrap();
    wait_until("actual process exit", || process.completed());
    wait_until("writer retirement", || Lease::acquire(temp.path()).is_ok());
    assert!(temp.path().join("done.txt").exists());
}

#[test]
fn interactive_agents_share_one_checkout_until_both_exit() {
    let temp = tempfile::tempdir().unwrap();
    let mut first = Guard::acquire_interactive(temp.path()).unwrap();
    let first_info = first
        .spawn_piped(&request(
            temp.path(),
            "echo ready > first.ready; while [ ! -f first.release ]; do sleep 0.02; done",
        ))
        .unwrap();
    let _first_session = Session(first_info.id);
    let first_process = first.process.as_ref().unwrap().clone();
    wait_until("first terminal startup", || {
        temp.path().join("first.ready").exists()
    });

    let mut second = Guard::acquire_interactive(temp.path()).unwrap();
    let second_info = second
        .spawn_piped(&request(
            temp.path(),
            "echo ready > second.ready; while [ ! -f second.release ]; do sleep 0.02; done",
        ))
        .unwrap();
    let _second_session = Session(second_info.id);
    let second_process = second.process.as_ref().unwrap().clone();
    wait_until("second terminal startup", || {
        temp.path().join("second.ready").exists()
    });
    drop(first);
    drop(second);

    assert!(matches!(Lease::acquire(temp.path()), Err(Error::Busy)));
    std::fs::write(temp.path().join("first.release"), b"release").unwrap();
    wait_until("first terminal exit", || first_process.completed());
    assert!(matches!(Lease::acquire(temp.path()), Err(Error::Busy)));
    std::fs::write(temp.path().join("second.release"), b"release").unwrap();
    wait_until("second terminal exit", || second_process.completed());
    wait_until("shared writer retirement", || {
        Lease::acquire(temp.path()).is_ok()
    });
}

#[test]
fn interactive_agent_cannot_join_a_background_writer() {
    let temp = tempfile::tempdir().unwrap();
    let _background = Guard::acquire(temp.path()).unwrap();
    assert!(matches!(
        Guard::acquire_interactive(temp.path()),
        Err(Error::Busy)
    ));
}

#[test]
fn a_writer_cannot_launch_in_a_different_folder() {
    let temp = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let mut writer = Guard::acquire(temp.path()).unwrap();
    assert!(
        writer
            .spawn(&request(other.path(), "echo wrong > launched.txt"))
            .is_err()
    );
    assert!(!other.path().join("launched.txt").exists());
    assert!(writer.process.is_none());
}
