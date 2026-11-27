// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use std::{
    io,
    process::{Child, Command},
};

pub(super) fn configure(command: &mut Command) {
    use std::os::unix::process::CommandExt;

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
/// True only when no process is left in `group` or with its leader's id.
/// A reused id reads as alive, which keeps a run fenced: the safe answer.
pub(super) fn group_gone(group: u32) -> bool {
    let Ok(group) = i32::try_from(group) else {
        return false;
    };
    if group <= 1 {
        return false;
    }

    let gone = |target: i32| {
        let status = unsafe { libc::kill(target, 0) };
        status == -1 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    };

    gone(-group) && gone(group) && session_gone(group)
}

#[cfg(target_os = "macos")]
fn session_gone(session: i32) -> bool {
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return false;
    }
    let mut pids = vec![0 as libc::pid_t; count as usize * 2 + 64];
    let bytes = i32::try_from(pids.len() * std::mem::size_of::<libc::pid_t>()).unwrap_or(i32::MAX);

    let found = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    if found <= 0 || found as usize >= pids.len() {
        return false;
    }
    pids[..found as usize]
        .iter()
        .filter(|pid| **pid > 0)
        .all(|pid| {
            let owner = unsafe { libc::getsid(*pid) };
            if owner == -1 {
                return io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
            }
            owner != session
        })
}

#[cfg(target_os = "linux")]
fn session_gone(session: i32) -> bool {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return false;
    };
    for entry in entries {
        let Ok(entry) = entry else {
            return false;
        };
        let name = entry.file_name();
        if !name.to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let stat = match std::fs::read_to_string(entry.path().join("stat")) {
            Ok(stat) => stat,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(_) => return false,
        };

        let Some(session_field) = stat
            .rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().nth(3))
            .and_then(|field| field.parse::<i32>().ok())
        else {
            return false;
        };
        if session_field == session {
            return false;
        }
    }
    true
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn session_gone(_session: i32) -> bool {
    false
}
pub(super) fn run_owner(anchor: u32) -> (u32, u64) {
    (anchor, 0)
}
pub(super) fn run_owner_gone(id: u32, _born: u64) -> bool {
    group_gone(id)
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

        if unsafe { libc::kill(-self.pid, libc::SIGKILL) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }

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
fn no_live_members(session: i32) -> io::Result<bool> {
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Err(super::invalid());
    }
    let mut pids = vec![0 as libc::pid_t; count as usize * 2 + 64];
    let bytes = i32::try_from(pids.len() * std::mem::size_of::<libc::pid_t>())
        .map_err(|_| super::invalid())?;
    let found = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    if found <= 0 || found as usize >= pids.len() {
        return Err(super::invalid());
    }
    for pid in pids.into_iter().take(found as usize).filter(|pid| *pid > 0) {
        let owner = unsafe { libc::getsid(pid) };
        if owner < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                continue;
            }
            return Err(error);
        }
        if owner != session {
            continue;
        }
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
        if info.pbi_status != 5 {
            return Ok(false);
        }
    }
    Ok(true)
}
#[cfg(target_os = "linux")]
fn no_live_members(session: i32) -> io::Result<bool> {
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
        let owner = unsafe { libc::getsid(pid) };
        if owner < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                continue;
            }
            return Err(error);
        }
        if owner != session {
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
        let owner = fields[3].parse::<i32>().map_err(|_| super::invalid())?;
        if owner == session && fields[0] != "Z" && fields[0] != "X" {
            return Ok(false);
        }
    }
    Ok(true)
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn no_live_members(_: i32) -> io::Result<bool> {
    Err(io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_live_session_is_never_gone() {
        let own = unsafe { libc::getsid(0) };
        assert!(own > 0);
        assert!(!session_gone(own));
        assert!(!group_gone(own as u32));
    }

    #[test]
    fn a_finished_session_is_gone() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "exit 0"]);
        configure(&mut command);
        let mut child = command.spawn().unwrap();
        let session = child.id();
        child.wait().unwrap();

        if group_gone(session) {
            assert!(session_gone(session as i32));
        }
    }
}
