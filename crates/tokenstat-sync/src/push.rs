// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Tell this account's phones that something finished here.
//!
//! A Mac with the app open notifies itself: it can see the run end and post a
//! local notification, with no account, no network and no server. This module
//! is for the other case, a phone in a pocket with the app closed, which only
//! Apple or Google can wake.
//!
//! # What may be said
//!
//! A [`Reason`], and the id of this machine. Nothing else. The sentence is
//! composed on the server from the reason and the machine label the account
//! already carries, so there is no field here that a folder name, a prompt or
//! a command could travel in. That is deliberate: notifications go through
//! somebody else's servers, and the boundary that holds for sync has to hold
//! for them too.
//!
//! # When nothing happens
//!
//! Not signed in, no phone registered, or the server has no push key: all
//! three are a quiet no-op rather than an error. Notifying is never the point
//! of the work that triggered it, so a failure here must not be able to fail a
//! run, and [`notify_in_background`] is what callers on a hot path use.

use std::time::Duration;

use crate::keychain;
use crate::profile::{ProfileError, resolve_api_host};

/// The sentences the server knows how to send.
///
/// Adding one means adding it to `REASONS` in the website's `lib/push.js` as
/// well: the server rejects a reason it does not recognise, which is what
/// stops a future client from smuggling text through this field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    /// An agent run ended, whatever it produced.
    RunFinished,
    /// An agent run ended badly.
    RunFailed,
    /// An agent is waiting for an answer and is not going to continue alone.
    RunNeedsInput,
    /// A conversational agent finished one turn cleanly.
    ChatFinished,
    /// A conversational agent's process did not finish cleanly.
    ChatFailed,
    /// A signed-in device asks the host owner to review screen permission.
    ScreenAccess,
    /// Sent by the "send a test" button, and by nothing else.
    Test,
}

impl Reason {
    pub fn wire(self) -> &'static str {
        match self {
            Reason::RunFinished => "run.finished",
            Reason::RunFailed => "run.failed",
            Reason::RunNeedsInput => "run.needs_input",
            Reason::ChatFinished => "chat.finished",
            Reason::ChatFailed => "chat.failed",
            Reason::ScreenAccess => "screen.access",
            Reason::Test => "test",
        }
    }

    /// What an exit code means, for callers that have one.
    pub fn for_exit(status: &str, exit_code: Option<i32>) -> Reason {
        if status == "error" || exit_code.is_some_and(|code| code != 0) {
            Reason::RunFailed
        } else {
            Reason::RunFinished
        }
    }
}

/// What the account did with a notification request.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Sent {
    /// Devices that took it.
    pub devices: u32,
    /// Whether the server can send at all.
    ///
    /// False means it has no push key, which is a different thing from having
    /// nowhere to send and needs different words in front of somebody. Without
    /// this, a "send a test" that quietly did nothing looked identical to one
    /// that worked and had no phone to arrive on.
    pub enabled: bool,
    /// Whether this machine is signed in. False short-circuits before the
    /// request: an account is what a notification is addressed to.
    pub signed_in: bool,
}

/// Ask the server to notify this account's registered devices.
///
/// Zero devices is the ordinary answer on an account that has never opened the
/// app on a phone, and is not a failure.
pub fn notify(reason: Reason) -> Result<Sent, ProfileError> {
    let host = resolve_api_host(None)?;
    let Some(token) = keychain::load_token(&host)? else {
        // Signed out. A machine nobody has linked has nowhere to send.
        return Ok(Sent::default());
    };
    let machine = crate::config::ensure_machine_id()?;
    let body = serde_json::json!({ "reason": reason.wire(), "machine": machine });
    let text = post(&host, &token, "/api/v1/push/notify", &body)?;
    let answer = serde_json::from_str::<serde_json::Value>(&text).ok();
    Ok(Sent {
        devices: answer
            .as_ref()
            .and_then(|v| v.get("sent").and_then(|s| s.as_u64()))
            .unwrap_or(0) as u32,
        // Absent means an older server that had no opinion, and one that
        // answered at all can send.
        enabled: answer
            .as_ref()
            .and_then(|v| v.get("enabled").and_then(|s| s.as_bool()))
            .unwrap_or(true),
        signed_in: true,
    })
}

/// Tell the account where to reach this device.
///
/// Called on every launch by a client that has notifications on, because the
/// OS reissues the token when it feels like it and the server keys devices by
/// the token itself. `environment` is which Apple host the token belongs to:
/// a build signed for development gets a sandbox token, and sending it to the
/// production host is answered with BadDeviceToken. Android has one host, so
/// it always registers as production.
pub fn register_device(token: &str, platform: &str, environment: &str) -> Result<(), ProfileError> {
    // Both fields are an allowlist, the same way `Reason` is: they travel to
    // somebody else's servers, so free text from a caller must not be able
    // to ride along. The server rejects what it does not recognise; refusing
    // here first keeps a bad value a local error instead of a failed request.
    if !matches!(platform, "ios" | "ipados" | "android") {
        return Err(ProfileError::Message(format!(
            "unknown push platform {platform:?}: expected \"ios\", \"ipados\" or \"android\""
        )));
    }
    if !matches!(environment, "production" | "sandbox") {
        return Err(ProfileError::Message(format!(
            "unknown push environment {environment:?}: expected \"production\" or \"sandbox\""
        )));
    }
    if token.is_empty() {
        return Err(ProfileError::Message(
            "cannot register a device without its token".into(),
        ));
    }
    let host = resolve_api_host(None)?;
    let bearer = keychain::load_token(&host)?
        .ok_or_else(|| ProfileError::Message("Sign in to get notifications.".into()))?;
    let machine = crate::config::ensure_machine_id()?;
    let body = serde_json::json!({
        "token": token,
        "platform": platform,
        "environment": environment,
        "machine": machine,
    });
    post(&host, &bearer, "/api/v1/push/register", &body).map(|_| ())
}

/// Stop sending here. Called when the switch goes off and before signing out,
/// so an unwanted notification does not wait on Apple noticing the token died.
pub fn unregister_device(token: &str) -> Result<(), ProfileError> {
    let host = resolve_api_host(None)?;
    let Some(bearer) = keychain::load_token(&host)? else {
        return Ok(());
    };
    let body = serde_json::json!({ "token": token });
    post(&host, &bearer, "/api/v1/push/unregister", &body).map(|_| ())
}

/// An opaque conversation key; work names and transcript content never travel in a push.
pub fn activity_key(conversation: &str) -> String {
    work_activity_key("chat", conversation)
}

/// Terminals have one run per unique PTY id, with revision zero.
pub fn terminal_activity_key(terminal: &str) -> String {
    work_activity_key("terminal", terminal)
}

fn work_activity_key(kind: &str, id: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(format!("{kind}:{id}"))
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn register_activity(
    token: &str,
    peer: &str,
    key: &str,
    revision: &str,
    environment: &str,
) -> Result<(), ProfileError> {
    if !(64..=200).contains(&token.len())
        || !token.len().is_multiple_of(2)
        || !token.bytes().all(|b| b.is_ascii_hexdigit())
        || peer.len() != 64
        || !peer.bytes().all(|b| b.is_ascii_hexdigit())
        || key.len() != 64
        || !key.bytes().all(|b| b.is_ascii_hexdigit())
        || revision
            .parse::<u64>()
            .ok()
            .map(|value| value.to_string())
            .as_deref()
            != Some(revision)
        || !matches!(environment, "sandbox" | "production")
    {
        return Err(ProfileError::Message(
            "Invalid Live Activity registration.".into(),
        ));
    }
    let host = resolve_api_host(None)?;
    let bearer = keychain::load_token(&host)?
        .ok_or_else(|| ProfileError::Message("Sign in first.".into()))?;
    post(&host, &bearer, "/api/v1/push/activity/register", &serde_json::json!({
        "token": token, "peer": peer, "key": key, "revision": revision, "environment": environment,
        "machine": crate::config::ensure_machine_id()?,
    })).map(|_| ())
}

pub fn unregister_activity(token: &str) -> Result<(), ProfileError> {
    if !(64..=200).contains(&token.len())
        || !token.len().is_multiple_of(2)
        || !token.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(ProfileError::Message("Invalid Live Activity token.".into()));
    }
    let host = resolve_api_host(None)?;
    let Some(bearer) = keychain::load_token(&host)? else {
        return Ok(());
    };
    post(
        &host,
        &bearer,
        "/api/v1/push/activity/unregister",
        &serde_json::json!({"token": token}),
    )
    .map(|_| ())
}

// Credentials are captured once when a run starts, before its first status.
#[derive(Clone)]
struct ActivityUpdate {
    host: String,
    bearer: String,
    machine: String,
    key: String,
    revision: u64,
    phase: &'static str,
}

fn activity_runs() -> &'static std::sync::Mutex<std::collections::HashMap<String, ActivityUpdate>> {
    static RUNS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, ActivityUpdate>>,
    > = std::sync::OnceLock::new();
    RUNS.get_or_init(Default::default)
}

/// Bind this turn's status to its original account. Signing in or changing
/// accounts while it runs must never subscribe the new account to old work.
pub fn begin_activity(conversation: &str, revision: u64) {
    begin_work_activity(activity_key(conversation), revision);
}

/// A failed launch has no drainer to retire its account binding.
pub fn abandon_activity(conversation: &str, revision: u64) {
    let key = activity_key(conversation);
    let mut runs = activity_runs()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if runs.get(&key).is_some_and(|run| run.revision == revision) {
        runs.remove(&key);
    }
}

pub fn begin_terminal_activity(terminal: &str) -> bool {
    begin_work_activity(terminal_activity_key(terminal), 0)
}

fn begin_work_activity(key: String, revision: u64) -> bool {
    let update = (|| {
        let host = resolve_api_host(None).ok()?;
        let bearer = keychain::load_token(&host).ok()??;
        Some(ActivityUpdate {
            host,
            bearer,
            machine: crate::config::ensure_machine_id().ok()?,
            key: key.clone(),
            revision,
            phase: "working",
        })
    })();
    let mut runs = activity_runs()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    // A signed-out launch deliberately clears any old binding. Later status
    // calls cannot resolve credentials for an account that arrived mid-run.
    runs.remove(&key);
    if let Some(update) = update {
        runs.insert(key, update);
        true
    } else {
        false
    }
}
impl ActivityUpdate {
    fn terminal(&self) -> bool {
        matches!(self.phase, "done" | "failed" | "stopped")
    }
    fn same_run(&self, other: &Self) -> bool {
        self.host == other.host
            && self.bearer == other.bearer
            && self.machine == other.machine
            && self.key == other.key
            && self.revision == other.revision
    }
}
fn queue_activity(queue: &mut std::collections::VecDeque<ActivityUpdate>, update: ActivityUpdate) {
    if let Some(pending) = queue.iter_mut().find(|pending| pending.same_run(&update)) {
        if !pending.terminal() {
            *pending = update;
        }
        return;
    }
    if queue.len() == 64 {
        // Heartbeats must not displace completion, even while the network is unavailable.
        let Some(index) = queue.iter().position(|pending| !pending.terminal()) else {
            return;
        };
        queue.remove(index);
    }
    queue.push_back(update);
}
#[derive(Default)]
struct ActivityQueue {
    pending: std::sync::Mutex<std::collections::VecDeque<ActivityUpdate>>,
    changed: std::sync::Condvar,
}

/// A bounded, best-effort status path independent of notification preferences/presence.
pub fn activity_in_background(conversation: &str, revision: u64, phase: &'static str) {
    work_activity_in_background(&activity_key(conversation), revision, phase);
}

pub fn terminal_activity_in_background(terminal: &str, phase: &'static str) {
    work_activity_in_background(&terminal_activity_key(terminal), 0, phase);
}

fn take_activity_update(
    runs: &mut std::collections::HashMap<String, ActivityUpdate>,
    key: &str,
    revision: u64,
    phase: &'static str,
) -> Option<ActivityUpdate> {
    let mut update = runs
        .get(key)
        .filter(|run| run.revision == revision)?
        .clone();
    update.phase = phase;
    if update.terminal() {
        // Late hooks/heartbeats can no longer revive this completed run.
        runs.remove(key);
    }
    Some(update)
}

fn work_activity_in_background(key: &str, revision: u64, phase: &'static str) {
    if !matches!(phase, "working" | "waiting" | "done" | "failed" | "stopped") {
        return;
    }
    // Keep the run lock until enqueueing: a concurrent completion must not
    // overtake an extracted heartbeat and let it arrive after the ending.
    let mut runs = activity_runs()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(update) = take_activity_update(&mut runs, key, revision, phase) else {
        return;
    };
    static QUEUE: std::sync::OnceLock<std::sync::Arc<ActivityQueue>> = std::sync::OnceLock::new();
    let queue = QUEUE.get_or_init(|| {
        let queue = std::sync::Arc::new(ActivityQueue::default());
        let worker = std::sync::Arc::clone(&queue);
        let _ = std::thread::Builder::new()
            .name("tokenstat-live-activity".into())
            .spawn(move || {
                loop {
                    let update = {
                        let mut pending = worker
                            .pending
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        while pending.is_empty() {
                            pending = worker
                                .changed
                                .wait(pending)
                                .unwrap_or_else(std::sync::PoisonError::into_inner);
                        }
                        let index = pending
                            .iter()
                            .position(ActivityUpdate::terminal)
                            .unwrap_or(0);
                        pending
                            .remove(index)
                            .expect("nonempty pending activity queue")
                    };
                    for attempt in 0..3 {
                        // Revocation wins over retries. Never resolve a new account's bearer for old work.
                        if resolve_api_host(None).ok().as_ref() != Some(&update.host)
                            || keychain::load_token(&update.host).ok().flatten().as_ref()
                                != Some(&update.bearer)
                        {
                            break;
                        }
                        let sent = post(
                            &update.host,
                            &update.bearer,
                            "/api/v1/push/activity/update",
                            &serde_json::json!({
                                "machine": update.machine, "key": update.key,
                                "revision": update.revision.to_string(), "phase": update.phase,
                            }),
                        );
                        if sent.is_ok() || !update.terminal() {
                            break;
                        }
                        if attempt < 2 {
                            std::thread::sleep(Duration::from_secs(attempt + 1));
                        }
                    }
                }
            });
        queue
    });
    let mut pending = queue
        .pending
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    queue_activity(&mut pending, update);
    drop(pending);
    drop(runs);
    queue.changed.notify_one();
}

fn post(
    host: &str,
    bearer: &str,
    path: &str,
    body: &serde_json::Value,
) -> Result<String, ProfileError> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .connect_timeout(Duration::from_secs(5))
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        // The bearer must not follow a redirect to another host.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|err| ProfileError::Message(err.to_string()))?;
    let resp = client
        .post(format!("{host}{path}"))
        .header("authorization", format!("Bearer {bearer}"))
        .header("content-type", "application/json")
        .json(body)
        .send()
        .map_err(|err| ProfileError::Message(err.to_string()))?;
    let status = resp.status();
    let text = capped_text(resp, 64 * 1024)?;
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "{path} failed ({status}): {}",
            text.chars().take(200).collect::<String>()
        )));
    }
    Ok(text)
}

/// Read a response body through its `Read` impl with a hard cap.
fn capped_text(response: reqwest::blocking::Response, max: usize) -> Result<String, ProfileError> {
    use std::io::Read;
    let mut reader = response.take(max as u64 + 1);
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8 * 1024];
    loop {
        let n = reader
            .read(&mut chunk)
            .map_err(|err| ProfileError::Message(err.to_string()))?;
        if n == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
    if bytes.len() > max {
        return Err(ProfileError::Message(format!(
            "server response exceeded {max} bytes"
        )));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Notify without waiting and without being able to fail the caller.
///
/// For the drain thread that just watched a run end. The work that mattered is
/// already done and recorded, so an unreachable server here is worth nothing
/// louder than a dropped result.
///
/// One worker thread takes every request off a bounded queue, so a burst of
/// runs ending together cannot grow a thread per notification. A full queue
/// means posts are slower than runs are ending, and the excess is dropped:
/// a notification is never worth blocking the run that triggered it.
pub fn notify_in_background(reason: Reason) {
    static QUEUE: std::sync::OnceLock<std::sync::mpsc::SyncSender<Reason>> =
        std::sync::OnceLock::new();
    let sender = QUEUE.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::sync_channel::<Reason>(8);
        // If this fails, the receiver goes with the closure that never ran,
        // so every `try_send` below fails and notifications are quietly
        // skipped rather than failing the caller.
        let _ = std::thread::Builder::new()
            .name("tokenstat-push-notify".to_string())
            .spawn(move || {
                for queued in rx {
                    let _ = notify(queued);
                }
            });
        tx
    });
    let _ = sender.try_send(reason);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn activity_fixture(key: &str, phase: &'static str) -> ActivityUpdate {
        ActivityUpdate {
            host: "fixture".into(),
            bearer: "account-a".into(),
            machine: "fixture-machine".into(),
            key: key.into(),
            revision: 1,
            phase,
        }
    }

    #[test]
    fn activity_updates_keep_the_launch_account_and_reject_retired_runs() {
        let mut runs = std::collections::HashMap::new();
        runs.insert("chat".into(), activity_fixture("chat", "working"));
        assert!(take_activity_update(&mut runs, "chat", 2, "working").is_none());
        let waiting = take_activity_update(&mut runs, "chat", 1, "waiting").unwrap();
        assert_eq!(waiting.bearer, "account-a");
        let ending = take_activity_update(&mut runs, "chat", 1, "done").unwrap();
        assert_eq!(ending.bearer, "account-a");
        assert!(take_activity_update(&mut runs, "chat", 1, "waiting").is_none());
        let mut next = activity_fixture("chat", "working");
        next.bearer = "account-b".into();
        next.revision = 2;
        runs.insert("chat".into(), next);
        assert!(take_activity_update(&mut runs, "chat", 1, "failed").is_none());
        assert_eq!(
            take_activity_update(&mut runs, "chat", 2, "working")
                .unwrap()
                .bearer,
            "account-b"
        );
    }
    #[test]
    fn pending_activity_heartbeats_coalesce_without_regressing_completion() {
        let mut queue = std::collections::VecDeque::new();
        queue_activity(&mut queue, activity_fixture("chat", "working"));
        queue_activity(&mut queue, activity_fixture("chat", "waiting"));
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].phase, "waiting");
        queue_activity(&mut queue, activity_fixture("chat", "done"));
        queue_activity(&mut queue, activity_fixture("chat", "working"));
        assert_eq!(queue[0].phase, "done");
        let mut other_account = activity_fixture("chat", "working");
        other_account.bearer = "account-b".into();
        queue_activity(&mut queue, other_account);
        assert_eq!(queue.len(), 2);
    }
    #[test]
    fn pending_activity_capacity_preserves_completion_under_heartbeat_pressure() {
        let mut queue = std::collections::VecDeque::new();
        queue_activity(&mut queue, activity_fixture("finished", "done"));
        for i in 0..100 {
            queue_activity(&mut queue, activity_fixture(&i.to_string(), "working"));
        }
        assert_eq!(queue.len(), 64);
        assert!(queue.iter().any(|pending| pending.key == "finished"));
        queue_activity(&mut queue, activity_fixture("last", "failed"));
        assert_eq!(queue.len(), 64);
        assert!(queue.iter().any(|pending| pending.key == "last"));
    }

    #[test]
    fn live_activity_keys_are_opaque_and_registration_is_validated_locally() {
        let key = activity_key("conversation-fixture");
        assert_eq!(key.len(), 64);
        assert!(key.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(key, activity_key("conversation-fixture"));
        assert_ne!(key, activity_key("another-conversation"));
        assert_ne!(key, terminal_activity_key("conversation-fixture"));
        assert_eq!(
            terminal_activity_key("terminal"),
            work_activity_key("terminal", "terminal")
        );
        for (token, peer, key, revision, environment) in [
            ("", "peer", key.as_str(), "1", "sandbox"),
            ("not-a-token", "peer", key.as_str(), "1", "sandbox"),
            ("", "peer", "project name", "1", "production"),
        ] {
            assert!(register_activity(token, peer, key, revision, environment).is_err());
        }
    }

    #[test]
    fn exit_code_decides_which_sentence() {
        assert_eq!(Reason::for_exit("ok", Some(0)), Reason::RunFinished);
        assert_eq!(Reason::for_exit("ok", Some(1)), Reason::RunFailed);
        assert_eq!(Reason::for_exit("error", None), Reason::RunFailed);
        // A run that was stopped by hand did not fail, and telling somebody
        // their run failed when they stopped it is worse than saying nothing.
        assert_eq!(Reason::for_exit("stopped", None), Reason::RunFinished);
    }

    #[test]
    fn register_device_refuses_anything_off_the_allowlist() {
        // Rejected locally, before any credential is read or any request is
        // made: free text must not be able to ride to somebody else's server.
        let err = register_device("tok", "windows", "production").unwrap_err();
        assert!(err.to_string().contains("platform"), "{err}");
        let err = register_device("tok", "ios", "development").unwrap_err();
        assert!(err.to_string().contains("environment"), "{err}");
        let err = register_device("", "ios", "production").unwrap_err();
        assert!(err.to_string().contains("token"), "{err}");
    }

    #[test]
    fn background_notify_never_blocks_the_caller() {
        // Queued on one worker, not a thread per call: a burst must return
        // promptly even while the worker is stuck on a slow server.
        let start = std::time::Instant::now();
        for _ in 0..64 {
            notify_in_background(Reason::Test);
        }
        assert!(start.elapsed() < std::time::Duration::from_secs(10));
    }

    #[test]
    fn wire_names_match_the_server() {
        assert_eq!(Reason::RunFinished.wire(), "run.finished");
        assert_eq!(Reason::RunFailed.wire(), "run.failed");
        assert_eq!(Reason::RunNeedsInput.wire(), "run.needs_input");
        assert_eq!(Reason::ChatFinished.wire(), "chat.finished");
        assert_eq!(Reason::ChatFailed.wire(), "chat.failed");
        assert_eq!(Reason::ScreenAccess.wire(), "screen.access");
        assert_eq!(Reason::Test.wire(), "test");
    }
}
