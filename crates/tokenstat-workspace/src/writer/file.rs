// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{Error, Identity};
use std::fs::{File, OpenOptions};
use std::path::Path;

pub(super) fn private_directory(path: &Path) -> Result<(), Error> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path).map_err(|_| Error::Unavailable)?;
    let value = std::fs::symlink_metadata(path).map_err(|_| Error::Unavailable)?;
    if !value.is_dir() || value.file_type().is_symlink() {
        return Err(Error::Unavailable);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if value.uid() != unsafe { libc::geteuid() } || value.mode() & 0o077 != 0 {
            return Err(Error::Unavailable);
        }
    }
    Ok(())
}

pub(super) fn directory(path: &Path) -> Result<File, Error> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x02000000 | 0x00200000).share_mode(3);
    }
    let file = options.open(path).map_err(|_| Error::Unavailable)?;
    let value = file.metadata().map_err(|_| Error::Unavailable)?;
    if !value.is_dir() || reparse(&value) {
        return Err(Error::Unavailable);
    }
    Ok(file)
}

fn reparse(value: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        value.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        value.file_type().is_symlink()
    }
}

fn lock_file(path: &Path, create: bool) -> Result<File, Error> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(true)
        .create(create)
        .truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000).share_mode(3);
    }
    let file = options.open(path).map_err(|_| Error::Unavailable)?;
    let value = file.metadata().map_err(|_| Error::Unavailable)?;
    if !value.is_file() || reparse(&value) {
        return Err(Error::Unavailable);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if value.nlink() != 1
            || value.uid() != unsafe { libc::geteuid() }
            || value.mode() & 0o077 != 0
        {
            return Err(Error::Unavailable);
        }
    }
    Ok(file)
}
pub(super) fn existing_lock(path: &Path) -> Result<File, Error> {
    lock_file(path, false)
}
pub(super) fn lock(path: &Path, exclusive: bool) -> Result<File, Error> {
    let file = lock_file(path, true)?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        loop {
            let mode = if exclusive {
                libc::LOCK_EX
            } else {
                libc::LOCK_SH
            };
            if unsafe { libc::flock(file.as_raw_fd(), mode | libc::LOCK_NB) } == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(if error.kind() == std::io::ErrorKind::WouldBlock {
                Error::Busy
            } else {
                Error::Unavailable
            });
        }
    }
    #[cfg(windows)]
    windows::lock(&file, exclusive)?;
    #[cfg(not(any(unix, windows)))]
    return Err(Error::Unavailable);
    Ok(file)
}

pub(super) fn identity(file: &File) -> Result<Identity, Error> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let value = file.metadata().map_err(|_| Error::Unavailable)?;
        let mut id = [0; 16];
        id[..8].copy_from_slice(&value.ino().to_be_bytes());
        Ok(Identity {
            volume: value.dev(),
            file: id,
        })
    }
    #[cfg(windows)]
    {
        windows::identity(file)
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err(Error::Unavailable)
    }
}

#[cfg(windows)]
mod windows {
    use super::*;
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
    #[repr(C)]
    struct FileIdInfo {
        volume: u64,
        id: [u8; 16],
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
        fn GetFileInformationByHandleEx(
            file: *mut c_void,
            class: i32,
            value: *mut c_void,
            size: u32,
        ) -> i32;
    }
    pub(super) fn identity(file: &File) -> Result<Identity, Error> {
        let mut value = FileIdInfo {
            volume: 0,
            id: [0; 16],
        };
        let ok = unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle(),
                18,
                (&mut value as *mut FileIdInfo).cast(),
                std::mem::size_of::<FileIdInfo>() as u32,
            )
        };
        if ok == 0 {
            return Err(Error::Unavailable);
        }
        Ok(Identity {
            volume: value.volume,
            file: value.id,
        })
    }
    pub(super) fn lock(file: &File, exclusive: bool) -> Result<(), Error> {
        let mut value = Overlapped {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event: std::ptr::null_mut(),
        };
        if unsafe {
            LockFileEx(
                file.as_raw_handle(),
                1 | if exclusive { 2 } else { 0 },
                0,
                1,
                0,
                &mut value,
            )
        } == 0
        {
            return Err(
                if std::io::Error::last_os_error().raw_os_error() == Some(33) {
                    Error::Busy
                } else {
                    Error::Unavailable
                },
            );
        }
        Ok(())
    }
}
