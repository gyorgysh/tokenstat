// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::time::Instant;
use tokenstat_workspace::writer::Lease;

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
fn closed_output_and_a_dropped_guard_keep_observing_a_live_process() {
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
    Lease::acquire(temp.path()).unwrap();
    std::fs::write(temp.path().join("release.txt"), b"release").unwrap();
    wait_until("actual process exit", || process.completed());
    assert!(temp.path().join("done.txt").exists());
}

#[test]
fn agents_in_the_same_checkout_are_observed_independently() {
    let temp = tempfile::tempdir().unwrap();
    let mut first = Guard::acquire(temp.path()).unwrap();
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

    let mut second = Guard::acquire(temp.path()).unwrap();
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

    Lease::acquire(temp.path()).unwrap();
    std::fs::write(temp.path().join("first.release"), b"release").unwrap();
    wait_until("first terminal exit", || first_process.completed());
    assert!(!second_process.completed());
    Lease::acquire(temp.path()).unwrap();
    std::fs::write(temp.path().join("second.release"), b"release").unwrap();
    wait_until("second terminal exit", || second_process.completed());
}

#[test]
fn agents_can_start_while_another_operation_uses_the_same_checkout() {
    let temp = tempfile::tempdir().unwrap();
    let mut background = Guard::acquire(temp.path()).unwrap();
    let info = background
        .spawn_piped(&request(
            temp.path(),
            "echo ready > background.ready; while [ ! -f background.release ]; do sleep 0.02; done",
        ))
        .unwrap();
    let _background_session = Session(info.id);
    wait_until("background job startup", || {
        temp.path().join("background.ready").exists()
    });
    let _operation = Lease::acquire(temp.path()).unwrap();
    let mut chat = Guard::acquire(temp.path()).unwrap();
    let info = chat
        .spawn_piped(&request(temp.path(), "echo ran > chat.started"))
        .unwrap();
    let _session = Session(info.id);
    wait_until("chat alongside another checkout operation", || {
        temp.path().join("chat.started").exists()
    });
    assert!(!background.process.as_ref().unwrap().completed());
    std::fs::write(temp.path().join("background.release"), b"release").unwrap();
    wait_until("background job exit", || {
        background.process.as_ref().unwrap().completed()
    });
}

#[test]
fn a_process_launch_does_not_require_working_git_metadata() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join(".git"), "gitdir: no-longer-present\n").unwrap();
    let mut guard = Guard::acquire(temp.path()).unwrap();
    let info = guard
        .spawn_piped(&request(temp.path(), "echo ran > started"))
        .unwrap();
    let _session = Session(info.id);
    wait_until("launch in folder with broken Git metadata", || {
        temp.path().join("started").exists()
    });
}

#[test]
fn a_replaced_launch_folder_is_rejected_and_stays_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("folder");
    let original = temp.path().join("original");
    std::fs::create_dir(&folder).unwrap();
    let mut guard = Guard::acquire(&folder).unwrap();
    std::fs::rename(&folder, &original).unwrap();
    std::fs::create_dir(&folder).unwrap();
    assert!(
        guard
            .spawn_piped(&request(&folder, "echo wrong > started"))
            .is_err()
    );
    assert!(!folder.join("started").exists());
    std::fs::remove_dir(&folder).unwrap();
    std::fs::rename(&original, &folder).unwrap();
    assert_eq!(guard.ensure_current(), Err(Error::Changed));
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
