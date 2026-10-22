// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use std::{
    ffi::c_void,
    io, mem,
    os::windows::{
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    process::{Child, Command},
};
type Handle = *mut c_void;
#[repr(C)]
#[derive(Default)]
struct BasicLimits {
    process_time: i64,
    job_time: i64,
    flags: u32,
    min_working: usize,
    max_working: usize,
    active_limit: u32,
    affinity: usize,
    priority: u32,
    scheduling: u32,
}
#[repr(C)]
#[derive(Default)]
struct Counters {
    read_ops: u64,
    write_ops: u64,
    other_ops: u64,
    read_bytes: u64,
    write_bytes: u64,
    other_bytes: u64,
}
#[repr(C)]
#[derive(Default)]
struct Limits {
    basic: BasicLimits,
    io: Counters,
    process_memory: usize,
    job_memory: usize,
    peak_process: usize,
    peak_job: usize,
}
#[repr(C)]
#[derive(Default)]
struct Accounting {
    user: i64,
    kernel: i64,
    period_user: i64,
    period_kernel: i64,
    faults: u32,
    total: u32,
    active: u32,
    terminated: u32,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> Handle;
    fn SetInformationJobObject(job: Handle, class: i32, info: *const c_void, length: u32) -> i32;
    fn QueryInformationJobObject(
        job: Handle,
        class: i32,
        info: *mut c_void,
        length: u32,
        returned: *mut u32,
    ) -> i32;
    fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
    fn IsProcessInJob(process: Handle, job: Handle, result: *mut i32) -> i32;
    fn TerminateJobObject(job: Handle, code: u32) -> i32;
}
const QUERY_LIMITED: u32 = 0x1000;
const INVALID_PARAMETER: i32 = 87;
const STILL_ACTIVE: u32 = 259;

use crate::win32::{FileTime, GetCurrentProcess, GetExitCodeProcess, GetProcessTimes, OpenProcess};

fn started(process: Handle) -> Option<u64> {
    let blank = || FileTime { low: 0, high: 0 };
    let (mut creation, mut exit, mut kernel, mut user) = (blank(), blank(), blank(), blank());
    // SAFETY: four valid out-pointers to FILETIME structures.
    let ok = unsafe { GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user) };
    let created = (u64::from(creation.high) << 32) | u64::from(creation.low);
    (ok != 0 && created != 0).then_some(created)
}
fn error() -> io::Error {
    io::Error::last_os_error()
}
pub(super) fn configure(command: &mut Command) {
    command.creation_flags(0x08000000);
}
pub(super) fn check_anchor() -> io::Result<()> {
    Ok(())
}
pub(super) fn run_owner(_anchor: u32) -> (u32, u64) {
    // SAFETY: the pseudo handle for this process needs no closing.
    let born = started(unsafe { GetCurrentProcess() }).unwrap_or(0);
    (std::process::id(), born)
}
/// The guardian is gone when its pid no longer exists, has exited, or now
/// names a process started at another time. Anything unclear keeps the run
/// fenced. The job's kill-on-close limit ended every process in it.
pub(super) fn run_owner_gone(pid: u32, born: u64) -> bool {
    if pid == 0 || born == 0 {
        return false;
    }
    // SAFETY: OpenProcess returns null or a handle we own and close below.
    let raw = unsafe { OpenProcess(QUERY_LIMITED, 0, pid) };
    if raw.is_null() {
        return io::Error::last_os_error().raw_os_error() == Some(INVALID_PARAMETER);
    }
    // SAFETY: a non-null handle from OpenProcess, closed when dropped.
    let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
    match started(handle.as_raw_handle()) {
        Some(creation) if creation != born => true,
        Some(_) => {
            let mut code = 0u32;
            // SAFETY: valid handle and out-pointer.
            let ok = unsafe { GetExitCodeProcess(handle.as_raw_handle(), &mut code) };
            ok != 0 && code != STILL_ACTIVE
        }
        None => false,
    }
}
pub(super) fn stop_self() -> io::Result<()> {
    Ok(())
}
pub(super) struct Owner {
    job: OwnedHandle,
}
impl Owner {
    pub(super) fn attach(child: &Child) -> io::Result<Self> {
        let raw = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if raw.is_null() {
            return Err(error());
        }
        let owner = Self {
            job: unsafe { OwnedHandle::from_raw_handle(raw) },
        };
        let limits = Limits {
            basic: BasicLimits {
                flags: 0x2000,
                ..BasicLimits::default()
            },
            ..Limits::default()
        };
        if unsafe {
            SetInformationJobObject(
                owner.job.as_raw_handle(),
                9,
                (&limits as *const Limits).cast(),
                mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            return Err(error());
        }
        // Only our trusted pipe-waiting anchor exists. No backend can be born
        // until assignment and membership checks finish and Start is written.
        if unsafe { AssignProcessToJobObject(owner.job.as_raw_handle(), child.as_raw_handle()) }
            == 0
        {
            return Err(error());
        }
        owner.ensure_anchor(child)?;
        Ok(owner)
    }
    pub(super) fn ensure_anchor(&self, child: &Child) -> io::Result<()> {
        let mut yes = 0;
        if unsafe { IsProcessInJob(child.as_raw_handle(), self.job.as_raw_handle(), &mut yes) } == 0
            || yes == 0
        {
            return Err(error());
        }
        Ok(())
    }
    pub(super) fn terminate(&self, _: &Child) -> io::Result<()> {
        if unsafe { TerminateJobObject(self.job.as_raw_handle(), 1) } == 0 {
            return Err(error());
        }
        Ok(())
    }
    pub(super) fn stopped(&self, _: &Child) -> io::Result<bool> {
        let mut accounting = Accounting::default();
        if unsafe {
            QueryInformationJobObject(
                self.job.as_raw_handle(),
                1,
                (&mut accounting as *mut Accounting).cast(),
                mem::size_of_val(&accounting) as u32,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(error());
        }
        Ok(accounting.active == 0)
    }
}

/// The recovery proof on a real Windows process table. CI runs these on its
/// Windows runner, which is where "the guardian is gone" has to be true.
#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        process::Stdio,
        time::{Duration, Instant},
    };

    /// A child that would live a minute on its own.
    fn sleeper() -> Child {
        Command::new("cmd")
            .args(["/C", "ping -n 60 127.0.0.1 >NUL"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap()
    }

    fn creation(pid: u32) -> u64 {
        // SAFETY: OpenProcess returns null or a handle we own and close below.
        let raw = unsafe { OpenProcess(QUERY_LIMITED, 0, pid) };
        assert!(!raw.is_null());
        // SAFETY: a non-null handle from OpenProcess.
        let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
        started(handle.as_raw_handle()).unwrap()
    }

    fn until(what: &str, done: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !done() {
            assert!(Instant::now() < deadline, "{what}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    #[test]
    fn this_process_is_its_own_live_owner() {
        let (pid, born) = run_owner(0);
        assert_eq!(pid, std::process::id());
        assert_ne!(born, 0);
        assert!(!run_owner_gone(pid, born));
        // Nothing unclear proves a run gone.
        assert!(!run_owner_gone(0, born));
        assert!(!run_owner_gone(pid, 0));
    }

    #[test]
    fn an_ended_owner_is_proven_gone_and_a_reused_pid_is_not_it() {
        let mut child = sleeper();
        let pid = child.id();
        let born = creation(pid);
        assert!(!run_owner_gone(pid, born), "a live owner read as gone");
        // Another start time at the same pid is another process.
        assert!(run_owner_gone(pid, born + 1));
        child.kill().unwrap();
        child.wait().unwrap();
        until("an ended owner did not read as gone", || {
            run_owner_gone(pid, born)
        });
    }

    #[test]
    fn closing_the_job_ends_everything_in_it() {
        let mut child = sleeper();
        let owner = Owner::attach(&child).unwrap();
        assert!(!owner.stopped(&child).unwrap());
        drop(owner);
        until("kill on close left the anchor running", || {
            matches!(child.try_wait(), Ok(Some(_)))
        });
    }

    #[test]
    fn terminating_the_job_is_observed_as_stopped() {
        let mut child = sleeper();
        let owner = Owner::attach(&child).unwrap();
        owner.terminate(&child).unwrap();
        until("terminate left the job active", || {
            owner.stopped(&child).unwrap()
        });
        child.wait().unwrap();
    }
}
