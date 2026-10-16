// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Thin kernel32 bindings for the Windows host daemon.
//!
//! Kept in one module so named pipes, file locks, battery detection and the
//! sleep assertion do not each grow their own copy of the same FFI. No extra
//! crate: the Mac keep-awake path already talks to the system this way.

#![cfg(windows)]

use std::ffi::c_void;
use std::os::windows::io::{FromRawHandle, OwnedHandle};

pub(crate) type Handle = *mut c_void;
pub(crate) type Dword = u32;
pub(crate) type Bool = i32;

pub(crate) const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;
pub(crate) const PIPE_ACCESS_DUPLEX: Dword = 0x0000_0003;
pub(crate) const FILE_FLAG_FIRST_PIPE_INSTANCE: Dword = 0x0008_0000;
pub(crate) const PIPE_REJECT_REMOTE_CLIENTS: Dword = 0x0000_0008;
pub(crate) const GENERIC_READ: Dword = 0x8000_0000;
pub(crate) const GENERIC_WRITE: Dword = 0x4000_0000;
pub(crate) const OPEN_EXISTING: Dword = 3;
pub(crate) const ERROR_PIPE_CONNECTED: Dword = 535;
pub(crate) const ERROR_PIPE_BUSY: Dword = 231;
pub(crate) const LOCKFILE_FAIL_IMMEDIATELY: Dword = 0x0000_0001;
pub(crate) const LOCKFILE_EXCLUSIVE_LOCK: Dword = 0x0000_0002;
// Keep-awake and battery detection are compiled out of unit tests so a
// `cargo test` cannot pin the machine awake. The FFI still has to exist
// in that build, hence the allow.
#[cfg_attr(test, allow(dead_code))]
pub(crate) const POWER_REQUEST_CONTEXT_VERSION: Dword = 0;
#[cfg_attr(test, allow(dead_code))]
pub(crate) const POWER_REQUEST_CONTEXT_SIMPLE_STRING: Dword = 0x0000_0001;
#[cfg_attr(test, allow(dead_code))]
pub(crate) const POWER_REQUEST_SYSTEM_REQUIRED: i32 = 1;
#[cfg_attr(test, allow(dead_code))]
pub(crate) const BATTERY_FLAG_NO_SYSTEM_BATTERY: u8 = 128;

#[allow(dead_code)]
#[repr(C)]
pub(crate) struct Overlapped {
    pub internal: usize,
    pub internal_high: usize,
    pub offset: u32,
    pub offset_high: u32,
    pub event: Handle,
}

impl Overlapped {
    pub(crate) fn zero() -> Self {
        Self {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event: std::ptr::null_mut(),
        }
    }
}

#[cfg_attr(test, allow(dead_code))]
#[repr(C)]
pub(crate) struct FileTime {
    pub low: u32,
    pub high: u32,
}

#[cfg_attr(test, allow(dead_code))]
#[repr(C)]
pub(crate) struct MemoryStatusEx {
    pub length: u32,
    pub memory_load: u32,
    pub total_phys: u64,
    pub avail_phys: u64,
    pub total_page_file: u64,
    pub avail_page_file: u64,
    pub total_virtual: u64,
    pub avail_virtual: u64,
    pub avail_extended_virtual: u64,
}

#[cfg_attr(test, allow(dead_code))]
#[repr(C)]
pub(crate) struct SystemPowerStatus {
    pub ac_line_status: u8,
    pub battery_flag: u8,
    pub battery_life_percent: u8,
    pub system_status_flag: u8,
    pub battery_life_time: u32,
    pub battery_full_life_time: u32,
}

#[cfg_attr(test, allow(dead_code))]
#[repr(C)]
pub(crate) struct ReasonContext {
    pub version: Dword,
    pub flags: Dword,
    pub reason: ReasonString,
}

#[cfg_attr(test, allow(dead_code))]
#[repr(C)]
pub(crate) union ReasonString {
    pub simple: *const u16,
    detailed: std::mem::ManuallyDrop<DetailedReason>,
}

#[cfg_attr(test, allow(dead_code))]
#[repr(C)]
pub(crate) struct DetailedReason {
    module: Handle,
    reason_id: Dword,
    string_count: Dword,
    strings: *const *const u16,
}

#[cfg(feature = "local-host")]
#[repr(C)]
pub(crate) struct ProcessEntry32 {
    pub size: Dword,
    pub usage: Dword,
    pub pid: Dword,
    pub default_heap: usize,
    pub module_id: Dword,
    pub threads: Dword,
    pub parent_pid: Dword,
    pub base_priority: i32,
    pub flags: Dword,
    pub executable: [u16; 260],
}

#[cfg(feature = "local-host")]
#[repr(C)]
pub(crate) struct ProcessMemoryCounters {
    pub size: Dword,
    pub page_faults: Dword,
    pub peak_working_set: usize,
    pub working_set: usize,
    pub peak_paged_pool: usize,
    pub paged_pool: usize,
    pub peak_nonpaged_pool: usize,
    pub nonpaged_pool: usize,
    pub pagefile: usize,
    pub peak_pagefile: usize,
}

#[cfg(feature = "local-host")]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetFileInformationByHandleEx(
        file: Handle,
        information_class: i32,
        information: *mut c_void,
        size: Dword,
    ) -> Bool;
    pub(crate) fn CreateToolhelp32Snapshot(flags: Dword, pid: Dword) -> Handle;
    pub(crate) fn Process32FirstW(snapshot: Handle, entry: *mut ProcessEntry32) -> Bool;
    pub(crate) fn Process32NextW(snapshot: Handle, entry: *mut ProcessEntry32) -> Bool;
    pub(crate) fn OpenProcess(access: Dword, inherit: Bool, pid: Dword) -> Handle;
    pub(crate) fn GetProcessTimes(
        process: Handle,
        created: *mut FileTime,
        exited: *mut FileTime,
        kernel: *mut FileTime,
        user: *mut FileTime,
    ) -> Bool;
    pub(crate) fn K32GetProcessMemoryInfo(
        process: Handle,
        counters: *mut ProcessMemoryCounters,
        size: Dword,
    ) -> Bool;
}

/// The volume plus 128-bit identifier distinguishes an atomic replacement
/// even when the filesystem preserves its name, length and timestamps.
#[cfg(feature = "local-host")]
pub(crate) fn file_identity(file: &std::fs::File) -> Option<(u64, [u8; 16])> {
    use std::os::windows::io::AsRawHandle;

    #[repr(C)]
    struct FileIdInfo {
        volume_serial_number: u64,
        file_id: [u8; 16],
    }
    let mut information = FileIdInfo {
        volume_serial_number: 0,
        file_id: [0; 16],
    };
    // SAFETY: FileIdInfo is the FILE_ID_INFO C layout for class FileIdInfo
    // (18), and the buffer size and live file handle match that call.
    let ok = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            18,
            (&mut information as *mut FileIdInfo).cast(),
            std::mem::size_of::<FileIdInfo>() as Dword,
        )
    };
    (ok != 0).then_some((information.volume_serial_number, information.file_id))
}

#[link(name = "kernel32")]
unsafe extern "system" {
    pub(crate) fn CreateNamedPipeW(
        name: *const u16,
        open_mode: Dword,
        pipe_mode: Dword,
        max_instances: Dword,
        out_buffer: Dword,
        in_buffer: Dword,
        default_timeout: Dword,
        security: *mut c_void,
    ) -> Handle;
    pub(crate) fn ConnectNamedPipe(pipe: Handle, overlapped: *mut Overlapped) -> Bool;
    pub(crate) fn CreateFileW(
        name: *const u16,
        access: Dword,
        share: Dword,
        security: *mut c_void,
        creation: Dword,
        flags: Dword,
        template: Handle,
    ) -> Handle;
    pub(crate) fn WaitNamedPipeW(name: *const u16, timeout_ms: Dword) -> Bool;
    pub(crate) fn PeekNamedPipe(
        pipe: Handle,
        buffer: *mut u8,
        buffer_size: Dword,
        bytes_read: *mut Dword,
        bytes_avail: *mut Dword,
        bytes_left: *mut Dword,
    ) -> Bool;
    pub(crate) fn GetLastError() -> Dword;
    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn CloseHandle(handle: Handle) -> Bool;
    pub(crate) fn LockFileEx(
        file: Handle,
        flags: Dword,
        reserved: Dword,
        bytes_low: Dword,
        bytes_high: Dword,
        overlapped: *mut Overlapped,
    ) -> Bool;
    pub(crate) fn UnlockFileEx(
        file: Handle,
        reserved: Dword,
        bytes_low: Dword,
        bytes_high: Dword,
        overlapped: *mut Overlapped,
    ) -> Bool;
    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn GetSystemPowerStatus(status: *mut SystemPowerStatus) -> Bool;
    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn GlobalMemoryStatusEx(status: *mut MemoryStatusEx) -> Bool;
    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn GetSystemTimes(
        idle: *mut FileTime,
        kernel: *mut FileTime,
        user: *mut FileTime,
    ) -> Bool;
    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn PowerCreateRequest(context: *mut ReasonContext) -> Handle;
    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn PowerSetRequest(request: Handle, kind: i32) -> Bool;
    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn PowerClearRequest(request: Handle, kind: i32) -> Bool;
}

pub(crate) fn wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

pub(crate) unsafe fn handle_to_owned(handle: Handle) -> Option<OwnedHandle> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        None
    } else {
        // SAFETY: caller transfers a kernel handle that CloseHandle owns.
        Some(unsafe { OwnedHandle::from_raw_handle(handle) })
    }
}

pub(crate) fn last_error() -> Dword {
    unsafe { GetLastError() }
}

pub(crate) fn try_lock_exclusive(file: &std::fs::File, wait: bool) -> bool {
    try_lock(file, wait, true)
}

pub(crate) fn try_lock(file: &std::fs::File, wait: bool, exclusive: bool) -> bool {
    use std::os::windows::io::AsRawHandle;
    let mut overlapped = Overlapped::zero();
    let mut flags = if exclusive {
        LOCKFILE_EXCLUSIVE_LOCK
    } else {
        0
    };
    if !wait {
        flags |= LOCKFILE_FAIL_IMMEDIATELY;
    }
    let ok = unsafe { LockFileEx(file.as_raw_handle(), flags, 0, 1, 0, &mut overlapped) };
    ok != 0
}

pub(crate) fn unlock(file: &std::fs::File) {
    use std::os::windows::io::AsRawHandle;
    let mut overlapped = Overlapped::zero();
    unsafe {
        UnlockFileEx(file.as_raw_handle(), 0, 1, 0, &mut overlapped);
    }
}

#[cfg_attr(test, allow(dead_code))]
pub(crate) fn has_system_battery() -> bool {
    let mut status = SystemPowerStatus {
        ac_line_status: 0,
        battery_flag: 0,
        battery_life_percent: 0,
        system_status_flag: 0,
        battery_life_time: 0,
        battery_full_life_time: 0,
    };
    let ok = unsafe { GetSystemPowerStatus(&mut status) };
    ok != 0 && (status.battery_flag & BATTERY_FLAG_NO_SYSTEM_BATTERY) == 0
}
