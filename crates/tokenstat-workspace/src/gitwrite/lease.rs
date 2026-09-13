// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use std::fs::{File, OpenOptions};
use std::path::Path;

/// Unlike Git's index lock, the process lease releases on a crash. Recovery
/// can distinguish an interrupted operation from a commit still running hooks.
/// The file handle is the lock: Drop closes it. On Windows nothing else reads
/// the field, so keep it marked used for the lint that only counts reads.
pub(super) struct Lease(#[allow(dead_code)] File);

pub(super) fn identity(file: &File) -> Result<[u64; 2], String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = file.metadata().map_err(|e| e.to_string())?;
        Ok([metadata.dev(), metadata.ino()])
    }
    #[cfg(windows)]
    {
        windows::identity(file)
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err("Git recovery is unavailable on this platform.".into())
    }
}

impl Lease {
    pub(super) fn acquire(path: &Path) -> Result<Self, String> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            loop {
                if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                    break;
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(
                        "A Git operation is still running. Check its outcome shortly.".into(),
                    );
                }
            }
        }
        #[cfg(windows)]
        if !windows::lock(&file) {
            return Err("A Git operation is still running. Check its outcome shortly.".into());
        }
        #[cfg(not(any(unix, windows)))]
        return Err("Git operation recovery is unavailable on this platform.".into());
        Ok(Self(file))
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe {
                libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
            }
        }
        // Windows releases its byte-range lock when this file handle closes.
    }
}

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    #[repr(C)]
    struct Overlapped {
        internal: usize,
        internal_high: usize,
        offset: u32,
        offset_high: u32,
        event: *mut c_void,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LockFileEx(
            file: *mut c_void,
            flags: u32,
            reserved: u32,
            low: u32,
            high: u32,
            overlapped: *mut Overlapped,
        ) -> i32;
        fn GetFileInformationByHandle(file: *mut c_void, info: *mut FileInformation) -> i32;
    }

    #[repr(C)]
    struct FileInformation {
        attributes: u32,
        created: [u32; 2],
        accessed: [u32; 2],
        written: [u32; 2],
        volume: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    }

    pub(super) fn identity(file: &std::fs::File) -> Result<[u64; 2], String> {
        let mut info: FileInformation = unsafe { std::mem::zeroed() };
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } == 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        Ok([
            u64::from(info.volume),
            (u64::from(info.index_high) << 32) | u64::from(info.index_low),
        ])
    }
    pub(super) fn lock(file: &std::fs::File) -> bool {
        let mut overlapped = Overlapped {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event: std::ptr::null_mut(),
        };
        unsafe { LockFileEx(file.as_raw_handle(), 3, 0, 1, 0, &mut overlapped) != 0 }
    }
}
