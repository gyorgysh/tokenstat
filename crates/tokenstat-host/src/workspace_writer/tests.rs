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
