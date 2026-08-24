// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build. See LICENSE.

//! Live power, CPU and memory for a connected peer.
//!
//! Sampled on this machine and returned over dispatch. Allowed on the tunnel:
//! a phone that has already dialled a host asks `host.stats` the same way it
//! asks `workspace.list`. CPU and RAM never go to tokenstat.ai. Missing
//! readings are omitted, never reported as zero.

use std::sync::{Mutex, OnceLock, PoisonError};

use serde_json::{Map, Value, json};

/// Answer `host.stats`, or `None` when the method is not ours.
pub(crate) fn call(method: &str, _params: &str) -> Option<Result<Value, String>> {
    match method {
        "host.stats" => Some(Ok(sample())),
        _ => None,
    }
}

fn sample() -> Value {
    let power = power_state();
    let cpu = cpu_fraction();
    let (ram_used, ram_total) = memory();
    let mut out = Map::new();
    out.insert("power".into(), json!(power.kind));
    out.insert("charging".into(), json!(power.charging));
    if let Some(percent) = power.percent {
        out.insert("percent".into(), json!(percent));
    }
    if let Some(cpu) = cpu {
        out.insert("cpu".into(), json!(cpu));
    }
    if ram_total > 0 {
        out.insert("ramUsedBytes".into(), json!(ram_used));
        out.insert("ramTotalBytes".into(), json!(ram_total));
    }
    Value::Object(out)
}

struct Power {
    kind: &'static str,
    charging: bool,
    percent: Option<u8>,
}

fn power_state() -> Power {
    platform::power()
}

fn cpu_fraction() -> Option<f64> {
    let now = platform::cpu_ticks()?;
    let mut last = cpu_last().lock().unwrap_or_else(PoisonError::into_inner);
    let prev = last.replace(now)?;
    let user = now.user.saturating_sub(prev.user);
    let system = now.system.saturating_sub(prev.system);
    let idle = now.idle.saturating_sub(prev.idle);
    let nice = now.nice.saturating_sub(prev.nice);
    let total = user + system + idle + nice;
    if total == 0 {
        return None;
    }
    Some(((user + system + nice) as f64 / total as f64).clamp(0.0, 1.0))
}

fn memory() -> (u64, u64) {
    platform::memory()
}

#[derive(Clone, Copy)]
struct CpuTicks {
    user: u64,
    system: u64,
    idle: u64,
    nice: u64,
}

fn cpu_last() -> &'static Mutex<Option<CpuTicks>> {
    static LAST: OnceLock<Mutex<Option<CpuTicks>>> = OnceLock::new();
    LAST.get_or_init(|| Mutex::new(None))
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{CpuTicks, Power};
    use std::ffi::c_void;

    pub(super) fn power() -> Power {
        macos_power()
    }

    pub(super) fn cpu_ticks() -> Option<CpuTicks> {
        macos_cpu()
    }

    pub(super) fn memory() -> (u64, u64) {
        macos_memory()
    }

    type CfTypeRef = *const c_void;
    type CfArrayRef = *const c_void;
    type CfDictionaryRef = *const c_void;
    type CfStringRef = *const c_void;
    type CfIndex = isize;

    const CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    const CF_NUMBER_SINT32: i32 = 3;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(cf: CfTypeRef);
        fn CFArrayGetCount(array: CfArrayRef) -> CfIndex;
        fn CFArrayGetValueAtIndex(array: CfArrayRef, idx: CfIndex) -> *const c_void;
        fn CFDictionaryGetValue(dict: CfDictionaryRef, key: *const c_void) -> *const c_void;
        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const i8,
            encoding: u32,
        ) -> CfStringRef;
        fn CFStringCompare(a: CfStringRef, b: CfStringRef, options: u32) -> i32;
        fn CFBooleanGetValue(boolean: *const c_void) -> u8;
        fn CFNumberGetValue(number: *const c_void, the_type: i32, value_ptr: *mut c_void) -> u8;
        static kCFBooleanTrue: *const c_void;
    }

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> CfTypeRef;
        fn IOPSCopyPowerSourcesList(blob: CfTypeRef) -> CfArrayRef;
        fn IOPSGetPowerSourceDescription(blob: CfTypeRef, ps: CfTypeRef) -> CfDictionaryRef;
        fn IOPSGetProvidingPowerSourceType(blob: CfTypeRef) -> CfStringRef;
    }

    struct CfDrop(CfTypeRef);
    impl Drop for CfDrop {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CFRelease(self.0) }
            }
        }
    }

    fn cf_str(text: &str) -> CfStringRef {
        let mut bytes = Vec::with_capacity(text.len() + 1);
        bytes.extend_from_slice(text.as_bytes());
        bytes.push(0);
        unsafe {
            CFStringCreateWithCString(
                std::ptr::null(),
                bytes.as_ptr().cast(),
                CF_STRING_ENCODING_UTF8,
            )
        }
    }

    fn dict_str(dict: CfDictionaryRef, key: &str) -> Option<CfStringRef> {
        let key_ref = CfDrop(cf_str(key));
        if key_ref.0.is_null() {
            return None;
        }
        let value = unsafe { CFDictionaryGetValue(dict, key_ref.0) };
        if value.is_null() { None } else { Some(value) }
    }

    fn dict_i32(dict: CfDictionaryRef, key: &str) -> Option<i32> {
        let key_ref = CfDrop(cf_str(key));
        if key_ref.0.is_null() {
            return None;
        }
        let value = unsafe { CFDictionaryGetValue(dict, key_ref.0) };
        if value.is_null() {
            return None;
        }
        let mut out: i32 = 0;
        let ok =
            unsafe { CFNumberGetValue(value, CF_NUMBER_SINT32, (&mut out as *mut i32).cast()) };
        (ok != 0).then_some(out)
    }

    fn dict_bool(dict: CfDictionaryRef, key: &str) -> bool {
        let key_ref = CfDrop(cf_str(key));
        if key_ref.0.is_null() {
            return false;
        }
        let value = unsafe { CFDictionaryGetValue(dict, key_ref.0) };
        if value.is_null() {
            return false;
        }
        unsafe { CFBooleanGetValue(value) != 0 || value == kCFBooleanTrue }
    }

    fn str_eq(value: CfStringRef, expected: &str) -> bool {
        if value.is_null() {
            return false;
        }
        let expected = CfDrop(cf_str(expected));
        if expected.0.is_null() {
            return false;
        }
        unsafe { CFStringCompare(value, expected.0, 0) == 0 }
    }

    fn macos_power() -> Power {
        let blob = unsafe { IOPSCopyPowerSourcesInfo() };
        if blob.is_null() {
            return Power {
                kind: "unknown",
                charging: false,
                percent: None,
            };
        }
        let blob = CfDrop(blob);
        let providing = unsafe { IOPSGetProvidingPowerSourceType(blob.0) };
        let on_battery = str_eq(providing, "Battery Power");
        let kind = if on_battery {
            "battery"
        } else if str_eq(providing, "AC Power") {
            "ac"
        } else {
            "unknown"
        };
        let list = unsafe { IOPSCopyPowerSourcesList(blob.0) };
        if list.is_null() {
            return Power {
                kind,
                charging: false,
                percent: None,
            };
        }
        let list = CfDrop(list);
        let count = unsafe { CFArrayGetCount(list.0) };
        let mut percent = None;
        let mut charging = false;
        for i in 0..count {
            let ps = unsafe { CFArrayGetValueAtIndex(list.0, i) };
            if ps.is_null() {
                continue;
            }
            let desc = unsafe { IOPSGetPowerSourceDescription(blob.0, ps) };
            if desc.is_null() {
                continue;
            }
            let source_type = dict_str(desc, "Type");
            let internal = source_type.is_some_and(|s| str_eq(s, "InternalBattery"));
            if !internal {
                continue;
            }
            charging = dict_bool(desc, "Is Charging");
            let current = dict_i32(desc, "Current Capacity");
            let max = dict_i32(desc, "Max Capacity").filter(|n| *n > 0);
            percent = match (current, max) {
                (Some(c), Some(m)) => {
                    Some(((c as f64 / m as f64) * 100.0).round() as u8).map(|n| n.min(100))
                }
                (Some(c), None) if (0..=100).contains(&c) => Some(c as u8),
                _ => None,
            };
            break;
        }
        Power {
            kind,
            charging,
            percent,
        }
    }

    const HOST_CPU_LOAD_INFO: i32 = 3;
    const HOST_CPU_LOAD_INFO_COUNT: u32 = 4;
    const CPU_STATE_USER: usize = 0;
    const CPU_STATE_SYSTEM: usize = 1;
    const CPU_STATE_IDLE: usize = 2;
    const CPU_STATE_NICE: usize = 3;

    unsafe extern "C" {
        fn mach_host_self() -> u32;
        fn host_statistics(host: u32, flavor: i32, host_info: *mut u32, count: *mut u32) -> i32;
        fn host_page_size(host: u32, out: *mut usize) -> i32;
        fn host_statistics64(host: u32, flavor: i32, host_info: *mut i32, count: *mut u32) -> i32;
        fn sysctlbyname(
            name: *const i8,
            oldp: *mut c_void,
            oldlenp: *mut usize,
            newp: *mut c_void,
            newlen: usize,
        ) -> i32;
    }

    fn macos_cpu() -> Option<CpuTicks> {
        let mut info = [0u32; 4];
        let mut count = HOST_CPU_LOAD_INFO_COUNT;
        let kr = unsafe {
            host_statistics(
                mach_host_self(),
                HOST_CPU_LOAD_INFO,
                info.as_mut_ptr(),
                &mut count,
            )
        };
        if kr != 0 {
            return None;
        }
        Some(CpuTicks {
            user: info[CPU_STATE_USER] as u64,
            system: info[CPU_STATE_SYSTEM] as u64,
            idle: info[CPU_STATE_IDLE] as u64,
            nice: info[CPU_STATE_NICE] as u64,
        })
    }

    // HOST_VM_INFO64 layout (natural_t fields packed into 64-bit words is
    // wrong). Use the documented 32-bit natural_t struct and read as u32.
    #[repr(C)]
    struct VmStatistics64 {
        free_count: u32,
        active_count: u32,
        inactive_count: u32,
        wire_count: u32,
        zero_fill_count: u64,
        reactivations: u64,
        pageins: u64,
        pageouts: u64,
        faults: u64,
        cow_faults: u64,
        lookups: u64,
        hits: u64,
        purges: u64,
        purgeable_count: u32,
        speculative_count: u32,
        decompressions: u64,
        compressions: u64,
        swapins: u64,
        swapouts: u64,
        compressor_page_count: u32,
        throttled_count: u32,
        external_page_count: u32,
        internal_page_count: u32,
        total_uncompressed_pages_in_compressor: u64,
    }

    const HOST_VM_INFO64: i32 = 4;
    // HOST_VM_INFO64_COUNT: sizeof(vm_statistics64) / sizeof(integer_t)
    const HOST_VM_INFO64_COUNT: u32 = (std::mem::size_of::<VmStatistics64>() / 4) as u32;

    fn macos_memory() -> (u64, u64) {
        let mut total: u64 = 0;
        let mut len = std::mem::size_of::<u64>();
        let name = c"hw.memsize";
        let sys = unsafe {
            sysctlbyname(
                name.as_ptr(),
                (&mut total as *mut u64).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        if sys != 0 || total == 0 {
            return (0, 0);
        }
        let host = unsafe { mach_host_self() };
        let mut page: usize = 0;
        if unsafe { host_page_size(host, &mut page) } != 0 || page == 0 {
            return (0, total);
        }
        let mut vm = VmStatistics64 {
            free_count: 0,
            active_count: 0,
            inactive_count: 0,
            wire_count: 0,
            zero_fill_count: 0,
            reactivations: 0,
            pageins: 0,
            pageouts: 0,
            faults: 0,
            cow_faults: 0,
            lookups: 0,
            hits: 0,
            purges: 0,
            purgeable_count: 0,
            speculative_count: 0,
            decompressions: 0,
            compressions: 0,
            swapins: 0,
            swapouts: 0,
            compressor_page_count: 0,
            throttled_count: 0,
            external_page_count: 0,
            internal_page_count: 0,
            total_uncompressed_pages_in_compressor: 0,
        };
        let mut count = HOST_VM_INFO64_COUNT;
        let kr = unsafe {
            host_statistics64(
                host,
                HOST_VM_INFO64,
                (&mut vm as *mut VmStatistics64).cast(),
                &mut count,
            )
        };
        if kr != 0 {
            return (0, total);
        }
        let free = (vm.free_count as u64)
            .saturating_add(vm.speculative_count as u64)
            .saturating_mul(page as u64);
        let used = total.saturating_sub(free.min(total));
        (used, total)
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{CpuTicks, Power};
    use std::fs;

    pub(super) fn power() -> Power {
        linux_power()
    }

    pub(super) fn cpu_ticks() -> Option<CpuTicks> {
        linux_cpu()
    }

    pub(super) fn memory() -> (u64, u64) {
        linux_memory()
    }

    fn linux_power() -> Power {
        let mut percent = None;
        let mut charging = false;
        let mut has_battery = false;
        let mut on_ac = false;
        if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
            for entry in entries.flatten() {
                let path = entry.path();
                let kind = fs::read_to_string(path.join("type")).unwrap_or_default();
                match kind.trim() {
                    "Battery" => {
                        has_battery = true;
                        if let Ok(text) = fs::read_to_string(path.join("capacity"))
                            && let Ok(n) = text.trim().parse::<u8>()
                        {
                            percent = Some(n.min(100));
                        }
                        if let Ok(status) = fs::read_to_string(path.join("status")) {
                            let status = status.trim();
                            charging = status.eq_ignore_ascii_case("charging")
                                || status.eq_ignore_ascii_case("full");
                        }
                    }
                    "Mains" | "ADP" => {
                        if fs::read_to_string(path.join("online"))
                            .map(|t| t.trim() == "1")
                            .unwrap_or(false)
                        {
                            on_ac = true;
                        }
                    }
                    _ => {}
                }
            }
        }
        let kind = if has_battery && !on_ac {
            "battery"
        } else {
            "ac"
        };
        Power {
            kind,
            charging,
            percent,
        }
    }

    fn linux_cpu() -> Option<CpuTicks> {
        let text = fs::read_to_string("/proc/stat").ok()?;
        let line = text.lines().next()?;
        let mut parts = line.split_whitespace();
        if parts.next()? != "cpu" {
            return None;
        }
        let user = parts.next()?.parse().ok()?;
        let nice = parts.next()?.parse().ok()?;
        let system = parts.next()?.parse().ok()?;
        let idle = parts.next()?.parse().ok()?;
        Some(CpuTicks {
            user,
            system,
            idle,
            nice,
        })
    }

    fn linux_memory() -> (u64, u64) {
        let text = match fs::read_to_string("/proc/meminfo") {
            Ok(t) => t,
            Err(_) => return (0, 0),
        };
        let mut total_kb = 0u64;
        let mut available_kb = 0u64;
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix("MemTotal:") {
                total_kb = parse_kb(rest);
            } else if let Some(rest) = line.strip_prefix("MemAvailable:") {
                available_kb = parse_kb(rest);
            }
        }
        let total = total_kb.saturating_mul(1024);
        let used = total.saturating_sub(available_kb.saturating_mul(1024));
        (used, total)
    }

    fn parse_kb(rest: &str) -> u64 {
        rest.split_whitespace()
            .next()
            .and_then(|n| n.parse().ok())
            .unwrap_or(0)
    }
}

#[cfg(windows)]
mod platform {
    use super::{CpuTicks, Power};
    use crate::win32::{
        self, BATTERY_FLAG_NO_SYSTEM_BATTERY, FileTime, MemoryStatusEx, SystemPowerStatus,
    };

    const AC_ONLINE: u8 = 1;
    const AC_OFFLINE: u8 = 0;
    const BATTERY_FLAG_CHARGING: u8 = 8;
    const BATTERY_PERCENT_UNKNOWN: u8 = 255;

    pub(super) fn power() -> Power {
        let mut status = SystemPowerStatus {
            ac_line_status: 255,
            battery_flag: 0,
            battery_life_percent: BATTERY_PERCENT_UNKNOWN,
            system_status_flag: 0,
            battery_life_time: 0,
            battery_full_life_time: 0,
        };
        let ok = unsafe { win32::GetSystemPowerStatus(&mut status) };
        if ok == 0 {
            return Power {
                kind: "unknown",
                charging: false,
                percent: None,
            };
        }
        let no_battery = (status.battery_flag & BATTERY_FLAG_NO_SYSTEM_BATTERY) != 0;
        let kind = if status.ac_line_status == AC_OFFLINE && !no_battery {
            "battery"
        } else if status.ac_line_status == AC_ONLINE || no_battery {
            "ac"
        } else {
            "unknown"
        };
        let charging = (status.battery_flag & BATTERY_FLAG_CHARGING) != 0;
        let percent = if no_battery || status.battery_life_percent == BATTERY_PERCENT_UNKNOWN {
            None
        } else {
            Some(status.battery_life_percent.min(100))
        };
        Power {
            kind,
            charging,
            percent,
        }
    }

    pub(super) fn cpu_ticks() -> Option<CpuTicks> {
        let mut idle = FileTime { low: 0, high: 0 };
        let mut kernel = FileTime { low: 0, high: 0 };
        let mut user = FileTime { low: 0, high: 0 };
        let ok = unsafe { win32::GetSystemTimes(&mut idle, &mut kernel, &mut user) };
        if ok == 0 {
            return None;
        }
        let idle_n = filetime(&idle);
        let kernel_n = filetime(&kernel);
        let user_n = filetime(&user);
        // Kernel time includes idle.
        let system = kernel_n.saturating_sub(idle_n);
        Some(CpuTicks {
            user: user_n,
            system,
            idle: idle_n,
            nice: 0,
        })
    }

    pub(super) fn memory() -> (u64, u64) {
        let mut status = MemoryStatusEx {
            length: std::mem::size_of::<MemoryStatusEx>() as u32,
            memory_load: 0,
            total_phys: 0,
            avail_phys: 0,
            total_page_file: 0,
            avail_page_file: 0,
            total_virtual: 0,
            avail_virtual: 0,
            avail_extended_virtual: 0,
        };
        let ok = unsafe { win32::GlobalMemoryStatusEx(&mut status) };
        if ok == 0 || status.total_phys == 0 {
            return (0, 0);
        }
        let used = status.total_phys.saturating_sub(status.avail_phys);
        (used, status.total_phys)
    }

    fn filetime(t: &FileTime) -> u64 {
        ((t.high as u64) << 32) | t.low as u64
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
mod platform {
    use super::{CpuTicks, Power};

    pub(super) fn power() -> Power {
        Power {
            kind: "unknown",
            charging: false,
            percent: None,
        }
    }

    pub(super) fn cpu_ticks() -> Option<CpuTicks> {
        None
    }

    pub(super) fn memory() -> (u64, u64) {
        (0, 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sample_is_an_object_with_power() {
        let value = sample();
        let obj = value.as_object().expect("object");
        let power = obj["power"].as_str().expect("power");
        assert!(matches!(power, "ac" | "battery" | "unknown"), "{power}");
        assert!(obj["charging"].as_bool().is_some());
        if let Some(percent) = obj.get("percent") {
            let n = percent.as_u64().expect("percent u64");
            assert!(n <= 100, "{n}");
        }
        if let Some(cpu) = obj.get("cpu") {
            let n = cpu.as_f64().expect("cpu f64");
            assert!((0.0..=1.0).contains(&n), "{n}");
        }
        if obj.contains_key("ramTotalBytes") {
            let total = obj["ramTotalBytes"].as_u64().expect("total");
            let used = obj["ramUsedBytes"].as_u64().expect("used");
            assert!(total > 0);
            assert!(used <= total);
        }
    }

    #[test]
    fn host_stats_is_a_known_method() {
        let answered = call("host.stats", "{}").expect("ours");
        let value = answered.expect("ok");
        assert!(value.get("power").is_some());
        assert!(call("host.policy", "{}").is_none());
    }

    #[test]
    fn a_remote_peer_may_read_stats() {
        crate::request_context::with_remote_peer("phone", || {
            let answered = call("host.stats", "{}").expect("ours");
            assert!(answered.is_ok(), "{answered:?}");
        });
    }
}
