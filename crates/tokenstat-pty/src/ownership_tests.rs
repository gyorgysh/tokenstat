// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
struct ChildFixture {
    exited: Arc<AtomicBool>,
    calls: Arc<AtomicU64>,
    refuse: bool,
}
impl portable_pty::ChildKiller for ChildFixture {
    fn kill(&mut self) -> std::io::Result<()> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.refuse {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "fixture refused stop",
            ));
        }
        self.exited.store(true, Ordering::SeqCst);
        Ok(())
    }
    fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
        Box::new(self.clone())
    }
}
impl portable_pty::Child for ChildFixture {
    fn try_wait(&mut self) -> std::io::Result<Option<portable_pty::ExitStatus>> {
        Ok(self
            .exited
            .load(Ordering::SeqCst)
            .then(|| portable_pty::ExitStatus::with_exit_code(0)))
    }
    fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
        self.try_wait()?
            .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::WouldBlock))
    }
    fn process_id(&self) -> Option<u32> {
        Some(u32::MAX)
    }
}

fn fixture(refuse: bool, exited: bool) -> (Manager, SessionInfo, ProcessWitness, ChildFixture) {
    let manager = Manager::new();
    let (info, witness) = manager
        .spawn_owned(&Spawn {
            command: "/bin/sh".into(),
            args: vec!["-c".into(), "exit 0".into()],
            cwd: std::env::temp_dir(),
            workspace_id: None,
            hidden: true,
            rows: 24,
            cols: 80,
            no_color: false,
            dark: None,
            environment: Vec::new(),
        })
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !witness.completed() {
        assert!(Instant::now() < deadline, "owned fixture did not exit");
        std::thread::sleep(Duration::from_millis(10));
    }
    // Replace only an already completed owned child. No synthetic PID is
    // ever handed to an operating-system signal or tree-kill function.
    let child = ChildFixture {
        exited: Arc::new(AtomicBool::new(exited)),
        calls: Arc::new(AtomicU64::new(0)),
        refuse,
    };
    let session = manager.get(&info.id).unwrap();
    *session.child.lock().unwrap() = Box::new(child.clone());
    (manager, info, witness, child)
}

#[test]
fn stopping_a_completed_child_never_signals_its_cached_identifier() {
    let (manager, info, witness, child) = fixture(false, true);
    manager.kill(&info.id).unwrap();
    assert_eq!(manager.info(&info.id).unwrap().pid, None);
    manager.close(&info.id).unwrap();
    assert_eq!(child.calls.load(Ordering::SeqCst), 0);
    assert!(witness.completed());
}

#[test]
fn a_refused_stop_does_not_forget_the_process_or_report_it_exited() {
    let (manager, info, witness, child) = fixture(true, false);
    assert!(manager.kill(&info.id).is_err());
    assert!(!witness.completed());
    assert!(manager.info(&info.id).unwrap().alive);
    assert!(manager.close(&info.id).is_err());
    assert!(manager.get(&info.id).is_ok());
    child.exited.store(true, Ordering::SeqCst);
    manager.close(&info.id).unwrap();
    assert!(witness.completed());
    assert_eq!(child.calls.load(Ordering::SeqCst), 2);
}
