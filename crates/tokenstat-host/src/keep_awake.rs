// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! System-sleep assertion for inbound remote workspace work.
//!
//! `hostd` is a launchd user agent on macOS and a per-user scheduled
//! task on Windows. Always-on host is what sets `KeepAlive` /
//! `RunAtLoad`, or the matching Task Scheduler restart policy. Neither
//! is a sleep lock. `ProcessType=Interactive` is the macOS scheduler
//! class so a live terminal is not throttled. It is also not a sleep
//! lock.
//!
//! The Mac app being closed must leave the laptop free to sleep, unless
//! Always-on host is on. A tunnel that is merely present, a sync, a
//! `workspace.list` / `pty.list` poll, and a local terminal must do the
//! same. Sleep is prevented only while a remote peer is actually using a
//! workspace or a terminal on this machine, or for the life of hostd when
//! Always-on host is on.
//!
//! The assertion is `PreventUserIdleSystemSleep` on macOS and
//! `PowerRequestSystemRequired` on Windows. Closing the lid is still
//! the user's choice. Nothing here calls `pmset` or holds a Keepresso lease.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use serde_json::Value;

/// How long a burst of inbound workspace / pty RPCs keeps the assertion
/// after the last one. Long enough to cover a short reconnect, short
/// enough that a phone that just listed a folder does not hold the
/// laptop all afternoon.
pub(crate) const GRACE_MS: i64 = 120_000;

struct Inner {
    streams: u32,
    grace_until_ms: i64,
    /// macOS IOPM id, or a Windows POWER_REQUEST handle truncated to u64.
    assertion: Option<u64>,
}

struct State {
    inner: Mutex<Inner>,
    poke: Condvar,
}

fn state() -> &'static State {
    static STATE: OnceLock<State> = OnceLock::new();
    STATE.get_or_init(|| State {
        inner: Mutex::new(Inner {
            streams: 0,
            grace_until_ms: 0,
            assertion: None,
        }),
        poke: Condvar::new(),
    })
}

fn lock_inner() -> std::sync::MutexGuard<'static, Inner> {
    state().inner.lock().unwrap_or_else(PoisonError::into_inner)
}

fn now_ms() -> i64 {
    jiff::Timestamp::now().as_millisecond()
}

/// Whether an inbound RPC means a remote peer is working in a workspace
/// or a terminal here. List polls and everything else do not.
pub(crate) fn counts_as_work(method: &str, stream_kind: Option<&str>) -> bool {
    match method {
        "workspace.list" | "pty.list" => false,
        "workflow.list" | "workflow.get" | "workflow.runs" | "workflow.transcript" => false,
        m if m.starts_with("workspace.") => true,
        m if m.starts_with("pty.") => true,
        m if m.starts_with("workflow.") => true,
        m if m.starts_with("ssh.") => true,
        m if m.starts_with("screen.transfer.") => true,
        "stream.open" => matches!(stream_kind, Some("pty.subscribe" | "screen.video")),
        _ => false,
    }
}

/// Whether the assertion should be held right now.
pub(crate) fn should_hold(streams: u32, grace_until_ms: i64, now_ms: i64) -> bool {
    streams > 0 || grace_until_ms > now_ms
}

/// Always-on holds for the life of hostd. Otherwise only inbound work, and
/// only while this Mac is actually hosting. The worker must be live: without
/// it a true here would lock sleep until hostd restarts.
pub(crate) fn assertion_wanted(
    worker: bool,
    policy_hold: bool,
    hosting_active: bool,
    streams: u32,
    grace_until_ms: i64,
    now_ms: i64,
) -> bool {
    worker && (policy_hold || (hosting_active && should_hold(streams, grace_until_ms, now_ms)))
}

fn policy_hold() -> bool {
    POLICY_HOLD.load(Ordering::Acquire)
}

fn hosting_active() -> bool {
    HOSTING_ACTIVE.load(Ordering::Acquire)
}

static POLICY_HOLD: AtomicBool = AtomicBool::new(false);
static HOSTING_ACTIVE: AtomicBool = AtomicBool::new(true);

/// Always-on host: hold idle-sleep for the life of this process.
pub(crate) fn set_policy_hold(on: bool) {
    POLICY_HOLD.store(on, Ordering::Release);
    if on {
        let _ = ensure_worker();
    }
    let mut inner = lock_inner();
    apply(&mut inner);
    state().poke.notify_one();
}

/// When hosting is paused (lid closed, app gone) inbound work must not pin sleep.
pub(crate) fn set_hosting_active(on: bool) {
    HOSTING_ACTIVE.store(on, Ordering::Release);
    let mut inner = lock_inner();
    apply(&mut inner);
    state().poke.notify_one();
}

/// Look at one inbound request line and, if it is workspace / pty work,
/// extend the grace window.
pub(crate) fn note_inbound(line: &str) {
    let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
        return;
    };
    let Some(method) = value.get("method").and_then(Value::as_str) else {
        return;
    };
    let kind = value
        .get("params")
        .and_then(|params| params.get("kind"))
        .and_then(Value::as_str);
    if !counts_as_work(method, kind) {
        return;
    }
    if !hosting_active() {
        return;
    }
    note_work();
}

fn note_work() {
    let _ = ensure_worker();
    {
        let mut inner = lock_inner();
        inner.grace_until_ms = now_ms().saturating_add(GRACE_MS);
        apply(&mut inner);
    }
    state().poke.notify_one();
}

/// Held for the life of an inbound `pty.subscribe` pump. The far side is
/// attached to a terminal this machine owns, so the laptop must not idle
/// to sleep under it.
#[cfg(feature = "local-host")]
pub(crate) struct StreamHold {
    _private: (),
}

#[cfg(feature = "local-host")]
impl StreamHold {
    pub(crate) fn acquire() -> Self {
        let _ = ensure_worker();
        {
            let mut inner = lock_inner();
            inner.streams = inner.streams.saturating_add(1);
            apply(&mut inner);
        }
        state().poke.notify_one();
        Self { _private: () }
    }
}

#[cfg(feature = "local-host")]
impl Drop for StreamHold {
    fn drop(&mut self) {
        {
            let mut inner = lock_inner();
            inner.streams = inner.streams.saturating_sub(1);
            apply(&mut inner);
        }
        state().poke.notify_one();
    }
}

fn apply(inner: &mut Inner) {
    let hold = assertion_wanted(
        worker_started(),
        policy_hold(),
        hosting_active(),
        inner.streams,
        inner.grace_until_ms,
        now_ms(),
    );
    if hold {
        take_assertion(inner);
    } else {
        drop_assertion(inner);
    }
}

fn worker_started() -> bool {
    worker_flag().load(Ordering::Acquire)
}

fn worker_flag() -> &'static AtomicBool {
    static STARTED: AtomicBool = AtomicBool::new(false);
    &STARTED
}

/// Start the grace-expiry thread if it is not already running.
///
/// The flag is set only after spawn succeeds. A `Once` that swallowed a
/// failed spawn would never retry, and an assertion taken on this thread
/// would then live until hostd restarted. Concurrent callers wait on the
/// gate so nobody treats a still-spawning worker as live.
fn ensure_worker() -> bool {
    static GATE: Mutex<()> = Mutex::new(());
    if worker_started() {
        return true;
    }
    let _gate = GATE.lock().unwrap_or_else(PoisonError::into_inner);
    if worker_started() {
        return true;
    }
    match std::thread::Builder::new()
        .name("tokenstat-keep-awake".into())
        .spawn(worker)
    {
        Ok(_) => {
            worker_flag().store(true, Ordering::Release);
            true
        }
        Err(error) => {
            eprintln!("keep-awake: worker failed to start: {error}");
            false
        }
    }
}

fn worker() {
    let mut guard = lock_inner();
    loop {
        apply(&mut guard);
        let now = now_ms();
        if guard.streams == 0 && guard.grace_until_ms > now {
            let remain = Duration::from_millis((guard.grace_until_ms - now) as u64);
            let (next, _) = state()
                .poke
                .wait_timeout(guard, remain)
                .unwrap_or_else(|e| e.into_inner());
            guard = next;
        } else {
            guard = state()
                .poke
                .wait(guard)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }
}

fn take_assertion(inner: &mut Inner) {
    if inner.assertion.is_some() {
        return;
    }
    inner.assertion = create_assertion();
}

fn drop_assertion(inner: &mut Inner) {
    if let Some(id) = inner.assertion.take() {
        release_assertion(id);
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn create_assertion() -> Option<u64> {
    macos::create().map(u64::from)
}

#[cfg(all(windows, not(test)))]
fn create_assertion() -> Option<u64> {
    windows::create()
}

#[cfg(not(any(all(target_os = "macos", not(test)), all(windows, not(test)))))]
fn create_assertion() -> Option<u64> {
    // Tests, and OSes without a sleep assertion, must not pin the build
    // machine awake.
    None
}

#[cfg(all(target_os = "macos", not(test)))]
fn release_assertion(id: u64) {
    macos::release(id as u32);
}

#[cfg(all(windows, not(test)))]
fn release_assertion(id: u64) {
    windows::release(id);
}

#[cfg(not(any(all(target_os = "macos", not(test)), all(windows, not(test)))))]
fn release_assertion(_id: u64) {}

#[cfg(all(target_os = "macos", not(test)))]
mod macos {
    use std::ffi::{CStr, c_void};

    type CfStringRef = *const c_void;
    type IopmAssertionId = u32;

    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    const K_IOPM_ASSERTION_LEVEL_ON: u32 = 255;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const i8,
            encoding: u32,
        ) -> CfStringRef;
        fn CFRelease(cf: *const c_void);
    }

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPMAssertionCreateWithName(
            assertion_type: CfStringRef,
            assertion_level: u32,
            assertion_name: CfStringRef,
            assertion_id: *mut IopmAssertionId,
        ) -> i32;
        fn IOPMAssertionRelease(assertion_id: IopmAssertionId) -> i32;
    }

    struct CfString(CfStringRef);

    impl CfString {
        fn new(text: &CStr) -> Option<Self> {
            let raw = unsafe {
                CFStringCreateWithCString(
                    std::ptr::null(),
                    text.as_ptr(),
                    K_CF_STRING_ENCODING_UTF8,
                )
            };
            if raw.is_null() { None } else { Some(Self(raw)) }
        }
    }

    impl Drop for CfString {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0) };
        }
    }

    pub(super) fn create() -> Option<u32> {
        let kind = CfString::new(c"PreventUserIdleSystemSleep")?;
        let name = CfString::new(c"tokenstat remote workspace session")?;
        let mut id = 0u32;
        let status = unsafe {
            IOPMAssertionCreateWithName(kind.0, K_IOPM_ASSERTION_LEVEL_ON, name.0, &mut id)
        };
        if status == 0 { Some(id) } else { None }
    }

    pub(super) fn release(id: u32) {
        unsafe {
            let _ = IOPMAssertionRelease(id);
        }
    }
}

#[cfg(all(windows, not(test)))]
mod windows {
    use std::sync::OnceLock;

    use crate::win32::{self, ReasonContext};

    fn reason_wide() -> &'static [u16] {
        static CELL: OnceLock<Vec<u16>> = OnceLock::new();
        CELL.get_or_init(|| {
            "tokenstat remote workspace session\0"
                .encode_utf16()
                .collect()
        })
    }

    pub(super) fn create() -> Option<u64> {
        let mut context = ReasonContext {
            version: win32::POWER_REQUEST_CONTEXT_VERSION,
            flags: win32::POWER_REQUEST_CONTEXT_SIMPLE_STRING,
            simple_reason_string: reason_wide().as_ptr(),
        };
        let handle = unsafe { win32::PowerCreateRequest(&mut context) };
        if handle.is_null() || handle == win32::INVALID_HANDLE_VALUE {
            return None;
        }
        let ok = unsafe { win32::PowerSetRequest(handle, win32::POWER_REQUEST_SYSTEM_REQUIRED) };
        if ok == 0 {
            unsafe {
                win32::CloseHandle(handle);
            }
            return None;
        }
        Some(handle as usize as u64)
    }

    pub(super) fn release(id: u64) {
        let handle = id as usize as win32::Handle;
        unsafe {
            let _ = win32::PowerClearRequest(handle, win32::POWER_REQUEST_SYSTEM_REQUIRED);
            let _ = win32::CloseHandle(handle);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{GRACE_MS, assertion_wanted, counts_as_work, should_hold};

    #[test]
    fn list_polls_do_not_count() {
        assert!(!counts_as_work("workspace.list", None));
        assert!(!counts_as_work("pty.list", None));
    }

    #[test]
    fn workspace_and_pty_work_count() {
        assert!(counts_as_work("workspace.tree", None));
        assert!(counts_as_work("workspace.status", None));
        assert!(counts_as_work("workspace.read", None));
        assert!(counts_as_work("workspace.write", None));
        assert!(counts_as_work("pty.spawn", None));
        assert!(counts_as_work("pty.read", None));
        assert!(counts_as_work("pty.write", None));
        assert!(counts_as_work("pty.info", None));
    }

    #[test]
    fn pty_and_screen_stream_opens_count() {
        assert!(counts_as_work("stream.open", Some("pty.subscribe")));
        assert!(counts_as_work("stream.open", Some("screen.video")));
        assert!(counts_as_work("screen.transfer.open", None));
        assert!(counts_as_work("ssh.session.open", None));
        assert!(!counts_as_work("stream.open", Some("proxy")));
        assert!(!counts_as_work("stream.open", None));
    }

    #[test]
    fn account_and_sync_do_not_count() {
        assert!(!counts_as_work("info", None));
        assert!(!counts_as_work("host.stats", None));
        assert!(!counts_as_work("sync.run", None));
        assert!(!counts_as_work("activity.calendar", None));
        assert!(!counts_as_work("remote.serve", None));
        assert!(!counts_as_work("account.me", None));
    }

    #[test]
    fn hold_while_a_stream_or_grace_is_live() {
        assert!(should_hold(1, 0, 1_000));
        assert!(should_hold(0, 5_000, 1_000));
        assert!(!should_hold(0, 1_000, 1_000));
        assert!(!should_hold(0, 0, 1_000));
    }

    #[test]
    fn assertion_requires_a_worker() {
        assert!(!assertion_wanted(false, false, true, 1, 5_000, 1_000));
        assert!(!assertion_wanted(false, true, false, 0, 0, 1_000));
        assert!(assertion_wanted(true, false, true, 1, 0, 1_000));
        assert!(assertion_wanted(true, false, true, 0, 5_000, 1_000));
        assert!(!assertion_wanted(true, false, true, 0, 0, 1_000));
    }

    #[test]
    fn always_on_holds_without_inbound_work() {
        assert!(assertion_wanted(true, true, false, 0, 0, 1_000));
        assert!(!assertion_wanted(true, false, false, 1, 5_000, 1_000));
        assert!(assertion_wanted(true, false, true, 1, 0, 1_000));
        assert!(!assertion_wanted(true, false, true, 0, 0, 1_000));
    }

    #[test]
    fn grace_is_two_minutes() {
        assert_eq!(GRACE_MS, 120_000);
    }

    #[test]
    fn inbound_json_that_is_work_is_recognised() {
        let line = r#"{"id":1,"method":"workspace.tree","params":{"id":"w1"}}"#;
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        let method = value.get("method").and_then(|m| m.as_str()).unwrap();
        assert!(counts_as_work(method, None));
    }
}
