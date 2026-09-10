// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Serialize identity metadata transactions across threads and processes.
//! Lock files stay beside the records and are never replaced or removed.

use std::fs::{File, OpenOptions};
use std::sync::{Mutex, MutexGuard};

pub(crate) struct Guard {
    _process: MutexGuard<'static, ()>,
    file: File,
}

impl Drop for Guard {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe {
                libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
            }
        }
        #[cfg(windows)]
        crate::win32::unlock(&self.file);
    }
}

pub(crate) fn lock(name: &str, mutex: &'static Mutex<()>) -> Result<Guard, String> {
    if name.is_empty()
        || name.contains('/')
        || name.contains('\\')
        || name.contains("..")
        || name.contains('\0')
    {
        return Err("Invalid storage lock name".into());
    }
    let directory = tokenstat_identity::identity_dir().map_err(|error| error.to_string())?;
    lock_at(&directory.join(name), mutex)
}

/// The same permanent-file transaction lock for stores outside identity_dir.
pub(crate) fn lock_at(path: &std::path::Path, mutex: &'static Mutex<()>) -> Result<Guard, String> {
    let process = mutex.lock().map_err(|_| "Storage lock is unavailable")?;
    if let Some(directory) = path.parent() {
        std::fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    }
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error.to_string());
            }
        }
    }
    #[cfg(windows)]
    if !crate::win32::try_lock_exclusive(&file, true) {
        return Err("Cannot lock identity storage".into());
    }
    Ok(Guard {
        _process: process,
        file,
    })
}
