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
//! Apple can wake.
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
//! Not signed in, no phone registered, or the server has no APNs key: all
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
    /// Sent by the "send a test" button, and by nothing else.
    Test,
}

impl Reason {
    pub fn wire(self) -> &'static str {
        match self {
            Reason::RunFinished => "run.finished",
            Reason::RunFailed => "run.failed",
            Reason::RunNeedsInput => "run.needs_input",
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
    /// False means it has no APNs key, which is a different thing from having
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
/// Called on every launch by a client that has notifications on, because iOS
/// reissues the token when it feels like it and the server keys devices by the
/// token itself. `environment` is which Apple host the token belongs to:
/// a build signed for development gets a sandbox token, and sending it to the
/// production host is answered with BadDeviceToken.
pub fn register_device(token: &str, platform: &str, environment: &str) -> Result<(), ProfileError> {
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
    let text = resp.text().unwrap_or_default();
    if !status.is_success() {
        return Err(ProfileError::Message(format!(
            "{path} failed ({status}): {}",
            text.chars().take(200).collect::<String>()
        )));
    }
    Ok(text)
}

/// Notify without waiting and without being able to fail the caller.
///
/// For the drain thread that just watched a run end. The work that mattered is
/// already done and recorded, so an unreachable server here is worth nothing
/// louder than a dropped result.
pub fn notify_in_background(reason: Reason) {
    std::thread::spawn(move || {
        let _ = notify(reason);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn wire_names_match_the_server() {
        assert_eq!(Reason::RunFinished.wire(), "run.finished");
        assert_eq!(Reason::RunFailed.wire(), "run.failed");
        assert_eq!(Reason::RunNeedsInput.wire(), "run.needs_input");
        assert_eq!(Reason::Test.wire(), "test");
    }
}
