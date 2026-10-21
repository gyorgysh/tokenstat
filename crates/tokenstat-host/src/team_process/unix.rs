// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use std::{
    io,
    process::{Child, Command},
};

pub(super) fn configure(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    // SAFETY: the pre-exec child performs only async-signal-safe setsid and
    // errno access. The trusted executable, not a backend, is born first.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
}
pub(super) fn check_anchor() -> io::Result<()> {
    let pid = std::process::id() as i32;
    if unsafe { libc::getpgrp() } != pid || unsafe { libc::getsid(0) } != pid {
        return Err(super::invalid());
    }
    Ok(())
}
pub(super) fn group_gone(group: u32) -> bool {
    let Ok(group) = i32::try_from(group) else {
        return false;
    };
    if group <= 1 {
        return false;
    }
    // Signal 0 sends nothing. Only ESRCH proves absence.
    let gone = |target: i32| {
        // SAFETY: signal 0 only checks for existence and delivers nothing.
        let status = unsafe { libc::kill(target, 0) };
        status == -1 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    };
    gone(-group) && gone(group)
}
pub(super) fn stop_self() -> io::Result<()> {
    check_anchor()?;
    unsafe {
        libc::kill(-libc::getpgrp(), libc::SIGKILL);
    }
    Err(super::invalid())
}
pub(super) struct Owner {
    pid: i32,
}
impl Owner {
    pub(super) fn attach(child: &Child) -> io::Result<Self> {
        let pid = i32::try_from(child.id()).map_err(|_| super::invalid())?;
        if pid <= 1 {
            return Err(super::invalid());
        }
        Ok(Self { pid })
    }
    pub(super) fn ensure_anchor(&self, child: &Child) -> io::Result<()> {
        if child.id() != self.pid as u32
            || unsafe { libc::getpgid(self.pid) } != self.pid
            || unsafe { libc::getsid(self.pid) } != self.pid
        {
            return Err(super::invalid());
        }
        Ok(())
    }
    pub(super) fn terminate(&self, child: &Child) -> io::Result<()> {
        if child.id() != self.pid as u32 {
            return Err(super::invalid());
        }
        // Child is never polled/reaped by any other owner. Even an exited
        // anchor's waitable PID pins this group's identity until final wait.
        if unsafe { libc::kill(-self.pid, libc::SIGKILL) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }
        // A hosted macOS runner can refuse a signal addressed to another
        // session even when it owns every member. Signal those members
        // directly. The caller retries, so a child born between sweeps is
        // still reached.
        #[cfg(target_os = "macos")]
        if error.raw_os_error() == Some(libc::EPERM) {
            return signal_members(self.pid);
        }
        Err(error)
    }
    pub(super) fn stopped(&self, child: &Child) -> io::Result<bool> {
        if child.id() != self.pid as u32 {
            return Err(super::invalid());
        }
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.pid as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        #[cfg(target_os = "macos")]
        let exited = info.si_pid == self.pid;
        #[cfg(not(target_os = "macos"))]
        let exited = unsafe { info.si_pid() } == self.pid;
        if !exited {
            return Ok(false);
        }
        no_live_members(self.pid)
    }
}

#[cfg(target_os = "macos")]
fn group_pids(group: i32) -> io::Result<Vec<i32>> {
    // The unreaped anchor pins the group id. A growing list is retried and
    // bounded; a failed process inspection is never treated as completion.
    let mut capacity = 64usize;
    loop {
        let mut pids = vec![0i32; capacity];
        let size = (capacity * std::mem::size_of::<i32>()) as i32;
        unsafe {
            *libc::__error() = 0;
        }
        let bytes = unsafe { libc::proc_listpids(2, group as u32, pids.as_mut_ptr().cast(), size) };
        if bytes < 0 || bytes % 4 != 0 || bytes == 0 && unsafe { *libc::__error() } != 0 {
            return Err(super::invalid());
        }
        if bytes == size {
            if capacity >= 65536 {
                return Err(super::invalid());
            }
            capacity *= 2;
            continue;
        }
        return Ok(pids
            .into_iter()
            .take(bytes as usize / 4)
            .filter(|pid| *pid > 0)
            .collect());
    }
}
#[cfg(target_os = "macos")]
fn signal_members(group: i32) -> io::Result<()> {
    let mut denied = false;
    for pid in group_pids(group)? {
        if unsafe { libc::kill(pid, libc::SIGKILL) } == 0 {
            continue;
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::ESRCH) => {}
            Some(libc::EPERM) => denied = true,
            _ => return Err(error),
        }
    }
    if denied {
        return Err(io::Error::from_raw_os_error(libc::EPERM));
    }
    Ok(())
}
#[cfg(target_os = "macos")]
fn no_live_members(group: i32) -> io::Result<bool> {
    for pid in group_pids(group)? {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let count = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                std::mem::size_of_val(&info) as i32,
            )
        };
        if count == 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
            continue;
        }
        if count != std::mem::size_of_val(&info) as i32 {
            return Err(super::invalid());
        }
        if info.pbi_pgid == group as u32 && info.pbi_status != 5 {
            return Ok(false);
        }
    }
    Ok(true)
}
#[cfg(target_os = "linux")]
fn no_live_members(group: i32) -> io::Result<bool> {
    for entry in std::fs::read_dir("/proc")? {
        let entry = entry?;
        if entry
            .file_name()
            .to_str()
            .is_none_or(|s| s.parse::<u32>().is_err())
        {
            continue;
        }
        let pid = entry
            .file_name()
            .to_string_lossy()
            .parse::<i32>()
            .map_err(|_| super::invalid())?;
        let actual = unsafe { libc::getpgid(pid) };
        if actual < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                continue;
            }
            return Err(error);
        }
        if actual != group {
            continue;
        }
        let raw = match std::fs::read_to_string(entry.path().join("stat")) {
            Ok(raw) => raw,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        let fields = raw
            .rsplit_once(") ")
            .ok_or_else(super::invalid)?
            .1
            .split_whitespace()
            .take(4)
            .collect::<Vec<_>>();
        if fields.len() != 4 {
            return Err(super::invalid());
        }
        let pgid = fields[2].parse::<i32>().map_err(|_| super::invalid())?;
        if pgid == group && fields[0] != "Z" && fields[0] != "X" {
            return Ok(false);
        }
    }
    Ok(true)
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn no_live_members(_: i32) -> io::Result<bool> {
    Err(io::ErrorKind::Unsupported.into())
}
