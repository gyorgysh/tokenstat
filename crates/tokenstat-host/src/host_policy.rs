// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Whether this Mac stays a host after the app quits.
//!
//! `hostd` used to outlive the window for everyone: launchd `KeepAlive` plus
//! `RunAtLoad`. That is right on a Mac mini. It is wrong on a laptop, where
//! the helper staying up (and still answering the tunnel) lets a phone start
//! shells after the lid is closed.
//!
//! Always-on is the switch. Off by default when this machine has an internal
//! battery, on when it does not. The process type stays Interactive either
//! way. Background throttles terminals, and it is not a sleep lock.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
#[cfg(not(test))]
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::keep_awake;

/// How long hostd waits after the last app lock disappears before exiting.
#[cfg(not(test))]
const OWNER_GRACE: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSettings {
    pub always_on: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostSettingsFile {
    always_on: Option<bool>,
}

/// Pure default: a battery Mac sleeps unless somebody asked it to stay a host.
pub fn default_always_on(has_internal_battery: bool) -> bool {
    !has_internal_battery
}

/// Whether inbound workspace / pty work should be accepted right now.
///
/// Always-on hosts regardless of the lid and regardless of the app. Otherwise
/// this Mac is a host only while Tokenstat is open and the lid is open.
pub fn hosting_active(always_on: bool, lid_closed: bool, owner_present: bool) -> bool {
    always_on || (owner_present && !lid_closed)
}

fn settings_path_in(dir: &Path) -> PathBuf {
    dir.join("host.json")
}

fn settings_path() -> Result<PathBuf, String> {
    let dir = tokenstat_identity::identity_dir().map_err(|e| e.to_string())?;
    Ok(settings_path_in(&dir))
}

/// Load `host.json`, writing the hardware default the first time.
pub fn load_or_init() -> HostSettings {
    let has_battery = has_internal_battery();
    match settings_path() {
        Ok(path) => load_or_init_in(path.parent().unwrap_or(path.as_path()), has_battery),
        Err(_) => HostSettings {
            always_on: default_always_on(has_battery),
        },
    }
}

pub(crate) fn load_or_init_in(dir: &Path, has_internal_battery: bool) -> HostSettings {
    let path = settings_path_in(dir);
    if let Ok(text) = fs::read_to_string(&path)
        && let Ok(file) = serde_json::from_str::<HostSettingsFile>(&text)
        && let Some(always_on) = file.always_on
    {
        return HostSettings { always_on };
    }
    let settings = HostSettings {
        always_on: default_always_on(has_internal_battery),
    };
    let _ = save_in(dir, &settings);
    settings
}

fn save_in(dir: &Path, settings: &HostSettings) -> Result<(), String> {
    let _ = fs::create_dir_all(dir);
    let path = settings_path_in(dir);
    let text = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))
}

fn save(settings: &HostSettings) -> Result<(), String> {
    let dir = tokenstat_identity::identity_dir().map_err(|e| e.to_string())?;
    save_in(&dir, settings)
}

fn cached() -> &'static Mutex<HostSettings> {
    static CACHED: OnceLock<Mutex<HostSettings>> = OnceLock::new();
    CACHED.get_or_init(|| {
        // Tests never write the developer's host.json as a side effect of
        // asking whether inbound work is allowed.
        Mutex::new(if cfg!(test) {
            HostSettings { always_on: false }
        } else {
            load_or_init()
        })
    })
}

fn lock_settings() -> std::sync::MutexGuard<'static, HostSettings> {
    cached().lock().unwrap_or_else(PoisonError::into_inner)
}

/// The setting the running daemon is honouring.
pub fn always_on() -> bool {
    lock_settings().always_on
}

fn last_hosting() -> &'static AtomicBool {
    static LAST: AtomicBool = AtomicBool::new(true);
    &LAST
}

fn lid_closed_flag() -> &'static AtomicBool {
    static LID: AtomicBool = AtomicBool::new(false);
    &LID
}

#[cfg(test)]
fn battery_override() -> &'static Mutex<Option<bool>> {
    static OVERRIDE: Mutex<Option<bool>> = Mutex::new(None);
    &OVERRIDE
}

/// Whether this machine has an internal battery.
///
/// Used only to pick the first default. A MacBook on AC is still a laptop.
pub fn has_internal_battery() -> bool {
    #[cfg(test)]
    {
        if let Some(value) = battery_override()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .copied()
        {
            return value;
        }
    }
    detect_internal_battery()
}

#[cfg(test)]
pub(crate) fn set_battery_override_for_tests(value: Option<bool>) {
    *battery_override()
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = value;
}

#[cfg(test)]
pub(crate) fn reset_settings_cache_for_tests() {
    *lock_settings() = HostSettings { always_on: false };
}

#[cfg(all(target_os = "macos", not(test)))]
fn detect_internal_battery() -> bool {
    macos::has_smart_battery()
}

#[cfg(not(all(target_os = "macos", not(test))))]
fn detect_internal_battery() -> bool {
    false
}

/// Where the Mac app holds a shared lock for the life of the process.
pub fn owner_lock_path() -> Result<PathBuf, String> {
    let socket = crate::server::default_socket_path()?;
    Ok(socket.with_file_name("host-owner.lock"))
}

/// True when at least one Tokenstat app is holding the owner lock.
pub fn owner_present() -> bool {
    owner_present_at(&match owner_lock_path() {
        Ok(path) => path,
        Err(_) => return false,
    })
}

#[cfg(unix)]
pub(crate) fn owner_present_at(path: &Path) -> bool {
    use std::fs::OpenOptions;
    use std::os::unix::io::AsRawFd;

    let file = match OpenOptions::new().read(true).write(true).open(path) {
        Ok(file) => file,
        Err(_) => return false,
    };
    let rc = unsafe { libc_flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if rc == 0 {
        unsafe {
            libc_flock(file.as_raw_fd(), LOCK_UN);
        }
        false
    } else {
        true
    }
}

#[cfg(not(unix))]
pub(crate) fn owner_present_at(_path: &Path) -> bool {
    false
}

const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;

#[cfg(unix)]
unsafe fn libc_flock(fd: i32, op: i32) -> i32 {
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    unsafe { flock(fd, op) }
}

#[cfg(not(unix))]
fn libc_flock(_fd: i32, _op: i32) -> i32 {
    0
}

pub fn lid_closed() -> bool {
    lid_closed_flag().load(Ordering::Acquire)
}

fn refresh_lid() {
    lid_closed_flag().store(detect_lid_closed(), Ordering::Release);
}

#[cfg(all(target_os = "macos", not(test)))]
fn detect_lid_closed() -> bool {
    macos::clamshell_closed()
}

#[cfg(not(all(target_os = "macos", not(test))))]
fn detect_lid_closed() -> bool {
    false
}

/// Current accept policy, combining the setting with lid and owner.
pub fn hosting_active_now() -> bool {
    hosting_active(always_on(), lid_closed(), owner_present())
}

/// Apply keep-awake and the tunnel pause to match `active`.
pub fn apply_hosting(active: bool) {
    let previous = last_hosting().swap(active, Ordering::AcqRel);
    keep_awake::set_policy_hold(always_on());
    keep_awake::set_hosting_active(active);
    if previous == active {
        return;
    }
    if active {
        crate::remote::resume_tunnel_if_enabled();
    } else {
        crate::remote::pause_tunnel();
    }
}

fn apply_now() {
    refresh_lid();
    apply_hosting(hosting_active_now());
}

/// Watch the owner lock and the lid. Only the hostd process calls this.
///
/// The in-process bridge must not: an exit here would take the app with it.
/// Tests get a no-op: the watch thread exits the process when Always-on is
/// off and the app lock is gone, which is every unit test.
#[cfg(test)]
pub fn start_runtime() {}

#[cfg(not(test))]
pub fn start_runtime() {
    apply_now();
    let _ = std::thread::Builder::new()
        .name("tokenstat-host-policy".into())
        .spawn(watch);
}

#[cfg(not(test))]
fn watch() {
    let mut gone_since: Option<Instant> = None;
    loop {
        std::thread::sleep(Duration::from_secs(1));
        refresh_lid();
        let always = always_on();
        let owner = owner_present();
        let active = hosting_active(always, lid_closed(), owner);
        apply_hosting(active);
        if always || owner {
            gone_since = None;
            continue;
        }
        match gone_since {
            None => gone_since = Some(Instant::now()),
            Some(started) if started.elapsed() >= OWNER_GRACE => {
                eprintln!(
                    "tokenstat-hostd: always-on host is off and Tokenstat is not running, so this helper is stopping"
                );
                std::process::exit(0);
            }
            Some(_) => {}
        }
    }
}

/// Whether an inbound remote line is work this Mac should refuse.
pub fn should_refuse_inbound(line: &str) -> bool {
    should_refuse_inbound_with(always_on(), lid_closed(), owner_present(), line)
}

pub(crate) fn should_refuse_inbound_with(
    always_on: bool,
    lid_closed: bool,
    owner_present: bool,
    line: &str,
) -> bool {
    if hosting_active(always_on, lid_closed, owner_present) {
        return false;
    }
    let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
        return false;
    };
    let Some(method) = value.get("method").and_then(Value::as_str) else {
        return false;
    };
    let kind = value
        .get("params")
        .and_then(|params| params.get("kind"))
        .and_then(Value::as_str);
    keep_awake::counts_as_work(method, kind)
}

/// Envelope for a refused inbound line, echoing the request id when present.
pub fn refuse_inbound(line: &str) -> String {
    let id = serde_json::from_str::<Value>(line.trim())
        .ok()
        .and_then(|value| value.get("id").cloned())
        .unwrap_or(Value::Null);
    json!({
        "id": id,
        "ok": false,
        "error": {
            "code": "host_asleep",
            "message": "This Mac is asleep."
        }
    })
    .to_string()
}

/// Answer a `host.policy` / `host.setPolicy` method, or `None` when it is not one.
pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "host.policy" => policy(),
        "host.setPolicy" => set_policy(params),
        _ => return None,
    })
}

fn policy() -> Result<Value, String> {
    let has_battery = has_internal_battery();
    let settings = *lock_settings();
    Ok(json!({
        "alwaysOn": settings.always_on,
        "defaultAlwaysOn": default_always_on(has_battery),
        "hasInternalBattery": has_battery,
        "hostingActive": hosting_active_now(),
    }))
}

fn set_policy(params: &str) -> Result<Value, String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Params {
        always_on: bool,
    }
    let p: Params = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    {
        let mut settings = lock_settings();
        settings.always_on = p.always_on;
        save(&settings)?;
    }
    apply_now();
    policy()
}

#[cfg(all(target_os = "macos", not(test)))]
mod macos {
    use std::ffi::c_void;

    type IoObject = u32;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceGetMatchingService(main_port: u32, matching: *const c_void) -> IoObject;
        fn IOServiceMatching(name: *const i8) -> *const c_void;
        fn IOObjectRelease(object: IoObject) -> i32;
    }

    unsafe extern "C" {
        fn notify_register_check(name: *const i8, out_token: *mut i32) -> u32;
        fn notify_get_state(token: i32, state: *mut u64) -> u32;
    }

    pub(super) fn has_smart_battery() -> bool {
        let matching = unsafe { IOServiceMatching(c"AppleSmartBattery".as_ptr()) };
        if matching.is_null() {
            return false;
        }
        let service = unsafe { IOServiceGetMatchingService(0, matching) };
        if service == 0 {
            return false;
        }
        unsafe {
            let _ = IOObjectRelease(service);
        }
        true
    }

    pub(super) fn clamshell_closed() -> bool {
        static TOKEN: std::sync::OnceLock<Option<i32>> = std::sync::OnceLock::new();
        let Some(token) = TOKEN.get_or_init(|| {
            let mut token = 0i32;
            let status = unsafe {
                notify_register_check(
                    c"com.apple.system.powermanagement.clamshellstate".as_ptr(),
                    &mut token,
                )
            };
            if status == 0 { Some(token) } else { None }
        }) else {
            return false;
        };
        let mut state = 0u64;
        let status = unsafe { notify_get_state(*token, &mut state) };
        status == 0 && state != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battery_macs_default_off() {
        assert!(!default_always_on(true));
        assert!(default_always_on(false));
    }

    #[test]
    fn hosting_follows_the_lid_only_when_always_on_is_off() {
        assert!(hosting_active(true, true, false));
        assert!(hosting_active(true, false, false));
        assert!(hosting_active(false, false, true));
        assert!(!hosting_active(false, true, true));
        assert!(!hosting_active(false, false, false));
        assert!(!hosting_active(false, true, false));
    }

    #[test]
    fn missing_file_writes_the_hardware_default() {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-host-policy-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::create_dir_all(&dir);
        let laptop = load_or_init_in(&dir, true);
        assert!(!laptop.always_on);
        let text = fs::read_to_string(settings_path_in(&dir)).expect("wrote host.json");
        assert!(text.contains("\"alwaysOn\": false"), "{text}");
        let again = load_or_init_in(&dir, false);
        assert!(
            !again.always_on,
            "a later desktop heuristic must not flip a stored laptop default"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn stored_on_survives_a_battery_default() {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-host-policy-on-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::create_dir_all(&dir);
        save_in(&dir, &HostSettings { always_on: true }).expect("save");
        let loaded = load_or_init_in(&dir, true);
        assert!(loaded.always_on);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn lists_are_not_refused_when_hosting_is_inactive() {
        let refuse = |line| should_refuse_inbound_with(false, true, true, line);
        assert!(refuse(r#"{"id":1,"method":"pty.spawn","params":{}}"#));
        assert!(refuse(
            r#"{"id":2,"method":"workspace.tree","params":{"id":"w"}}"#
        ));
        assert!(!refuse(r#"{"id":3,"method":"workspace.list","params":{}}"#));
        assert!(!refuse(r#"{"id":4,"method":"pty.list","params":{}}"#));
        assert!(!should_refuse_inbound_with(
            true,
            true,
            false,
            r#"{"id":5,"method":"pty.spawn","params":{}}"#
        ));
    }

    #[test]
    fn owner_lock_missing_means_no_owner() {
        let path =
            std::env::temp_dir().join(format!("tokenstat-no-owner-{}.lock", std::process::id()));
        let _ = fs::remove_file(&path);
        assert!(!owner_present_at(&path));
    }

    #[test]
    fn refuse_envelope_names_the_mac_asleep() {
        let line = r#"{"id":9,"method":"pty.spawn","params":{}}"#;
        let out: Value = serde_json::from_str(&refuse_inbound(line)).expect("json");
        assert_eq!(out["ok"], false);
        assert_eq!(out["id"], 9);
        assert_eq!(out["error"]["code"], "host_asleep");
        assert_eq!(out["error"]["message"], "This Mac is asleep.");
    }
}
