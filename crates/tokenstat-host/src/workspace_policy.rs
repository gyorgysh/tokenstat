// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Which devices may reach the work on this machine.
//!
//! Being approved is not the same as being let in. Any device on the account
//! is auto-approved on first contact with the tunnel: `remote::serve_peer`
//! hands `authorize_with` an `auto_approve` hook that says yes to anything the
//! account directory knows. That was fine while a peer could only read
//! aggregate numbers. It is not fine now, because an approved peer can read
//! and write every file in a registered folder, commit and push it, spawn a
//! shell with `pty.spawn`, run every automation and workflow, and open a
//! socket to this machine's own loopback.
//!
//! So there is a second, explicit grant, and nothing is grandfathered into it.
//! Typing a pairing code is a person saying yes to one device by name, and
//! that still grants this. Appearing on the account does not.
//!
//! Deliberately the same shape as `screen_policy`: a per-device grant, a
//! request that arrives over the tunnel carrying the peer from the transport,
//! and an answer given by whoever is at the machine. The two share the request
//! record, its staleness window and its pruning, so one person answering two
//! kinds of question answers them the same way.

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::screen_policy::{PENDING_TTL, PendingRequest, now_secs, prune_pending};

#[derive(Default, Deserialize, Serialize)]
struct Store {
    /// Peer keys, as hex, that may reach the work here.
    #[serde(default)]
    allowed: Vec<String>,
    #[serde(default)]
    pending: Vec<PendingRequest>,
}

fn path() -> Result<PathBuf, String> {
    tokenstat_identity::identity_dir()
        .map(|p| p.join("workspace-policy.json"))
        .map_err(|e| e.to_string())
}

fn load() -> Result<Store, String> {
    let mut store: Store = match fs::read(path()?) {
        Ok(v) => serde_json::from_slice(&v).map_err(|e| e.to_string())?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Store::default(),
        Err(e) => return Err(e.to_string()),
    };
    prune_pending(&mut store.pending, now_secs());
    Ok(store)
}

fn save(store: &Store) -> Result<(), String> {
    let path = path()?;
    fs::create_dir_all(path.parent().ok_or("invalid policy path")?).map_err(|e| e.to_string())?;
    let temp = path.with_extension("tmp");
    fs::write(
        &temp,
        serde_json::to_vec_pretty(store).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    fs::rename(temp, path).map_err(|e| e.to_string())
}

/// Whether one device may reach the work here.
///
/// A read of a small file on every gated inbound request. That is the same
/// cost `PeerStore::cached` already pays per request on this path, and a
/// decision this important is worth reading rather than caching: a grant
/// somebody just took away has to mean the next request.
pub(crate) fn is_allowed(peer_id: &str) -> bool {
    load().is_ok_and(|store| store.allowed.iter().any(|held| held == peer_id))
}

/// Let a device in, or shut it out.
///
/// Called by the toggle in Devices, by answering a request, and by approving a
/// device with a pairing code, which is the one place approval and this grant
/// are the same act.
pub(crate) fn set_allowed(peer_id: &str, allow: bool) -> Result<(), String> {
    let mut store = load()?;
    store.allowed.retain(|held| held != peer_id);
    if allow {
        store.allowed.push(peer_id.to_string());
    }
    // Answered either way. A device told no does not keep standing in the
    // queue, and one told yes has nothing left to ask.
    store.pending.retain(|request| request.peer_id != peer_id);
    save(&store)
}

/// Whether a method reaches the work on this machine.
///
/// Pure, and tested, because the whole guarantee is this list. Reporting is
/// deliberately outside it: reading how many tokens a machine spent is what
/// the product is for, it is aggregate, and gating it would make a phone that
/// cannot open a folder also unable to draw a heatmap.
pub(crate) fn needs_access(method: &str, stream_kind: Option<&str>) -> bool {
    // A device that cannot get in still has to be able to ask.
    if method.starts_with("workspace.access.") {
        return false;
    }
    match method {
        m if m.starts_with("workspace.") => true,
        m if m.starts_with("pty.") => true,
        m if m.starts_with("workflow.") => true,
        m if m.starts_with("automation.") => true,
        m if m.starts_with("todo.") => true,
        m if m.starts_with("launcher.") => true,
        m if m.starts_with("harness.") => true,
        m if m.starts_with("proxy.") => true,
        // The screen has its own grant, and a screen stream must not need this
        // one as well: watching a desktop and opening its files are different
        // questions with different answers.
        "stream.open" => matches!(stream_kind, Some("pty.subscribe" | "proxy")),
        _ => false,
    }
}

/// A refusal envelope when this peer may not do what it asked, or `None`.
///
/// The shape `host_policy::refuse_inbound` uses, so the serve path has one
/// kind of "no" rather than two.
pub(crate) fn refuse_unpermitted(line: &str, peer: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    let method = value.get("method").and_then(Value::as_str)?;
    let kind = value
        .get("params")
        .and_then(|params| params.get("kind"))
        .and_then(Value::as_str);
    if !needs_access(method, kind) || is_allowed(peer) {
        return None;
    }
    let id = value.get("id").cloned().unwrap_or(Value::Null);
    Some(
        json!({
            "id": id,
            "ok": false,
            "error": {
                "code": "workspace_not_allowed",
                "message": "This computer has not let this device open its work yet.",
            }
        })
        .to_string(),
    )
}

/// What a device asks for. No peer id: that comes from the transport.
#[derive(Deserialize)]
struct AskParams {}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetParams {
    peer_id: String,
    allow: bool,
}

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("workspace.access.") {
        return None;
    }
    Some((|| match method {
        // Over the tunnel the device is already on, with the peer taken from
        // the connection rather than from the params. A device naming somebody
        // else would be a device asking on their behalf.
        "workspace.access.ask" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("a request must arrive from the device asking")?;
            let _: AskParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            let mut store = load()?;
            if store.allowed.iter().any(|held| held == &peer) {
                return Ok(json!({"pending": false, "granted": true}));
            }
            let asked_at = now_secs();
            store.pending.retain(|request| request.peer_id != peer);
            store.pending.push(PendingRequest {
                label: crate::remote::account_peer_label_hex(&peer),
                peer_id: peer,
                // Workspace access is one grant. There is no half of it to
                // ask for, so the field the screen request uses for mouse and
                // keyboard is always false here.
                control: false,
                asked_at,
                expires_at: asked_at + PENDING_TTL,
            });
            save(&store)?;
            Ok(json!({"pending": true}))
        }
        // Asked before anything is loaded, so a device that is not allowed can
        // draw the screen that says so and offer to ask. The alternative was
        // reading it off a failure, and `remote.call` flattens a peer's error
        // to its message and drops the code, so that would have meant matching
        // on a sentence.
        "workspace.access.check" => {
            let peer = crate::request_context::remote_peer()
                .ok_or("only a device can ask whether it is allowed")?;
            Ok(json!({"allowed": is_allowed(&peer)}))
        }
        "workspace.access.pending" => {
            crate::request_context::refuse_remote("workspace access requests")?;
            Ok(serde_json::to_value(load()?.pending).map_err(|e| e.to_string())?)
        }
        "workspace.access.list" => {
            crate::request_context::refuse_remote("workspace access settings")?;
            Ok(serde_json::to_value(load()?.allowed).map_err(|e| e.to_string())?)
        }
        // Answering a request and moving the toggle in Devices are the same
        // act, so they are the same method.
        "workspace.access.set" => {
            crate::request_context::refuse_remote("workspace access settings")?;
            let p: SetParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
            set_allowed(&p.peer_id, p.allow)?;
            Ok(json!({"saved": true}))
        }
        _ => Err(format!("unknown workspace access method: {method}")),
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn everything_that_touches_the_work_is_gated() {
        for method in [
            "workspace.read",
            "workspace.write",
            "workspace.push",
            "pty.spawn",
            "pty.write",
            "workflow.run",
            "automation.run",
            "todo.create",
            "launcher.install",
            "harness.config.set",
            "proxy.listen",
        ] {
            assert!(needs_access(method, None), "{method} must be gated");
        }
        assert!(needs_access("stream.open", Some("pty.subscribe")));
        assert!(needs_access("stream.open", Some("proxy")));
    }

    #[test]
    fn reporting_and_the_screen_are_not_gated_by_this() {
        for method in [
            "activity.calendar",
            "activity.day",
            "report.split",
            "usage.limits",
            "blocks.active",
            "host.stats",
            "info",
            "highlight.syntax",
            "screen.capability.issue",
        ] {
            assert!(!needs_access(method, None), "{method} must stay open");
        }
        // The screen carries its own grant. Needing both would mean somebody
        // who allowed a phone to watch this desktop had also, silently, to
        // allow it to open every file.
        assert!(!needs_access("stream.open", Some("screen.video")));
    }

    #[test]
    fn a_device_that_is_not_allowed_can_still_ask() {
        assert!(!needs_access("workspace.access.ask", None));
        assert!(!needs_access("workspace.access.check", None));
    }

    #[test]
    fn only_the_asking_device_may_ask_and_only_the_host_may_answer() {
        let refused = call("workspace.access.ask", "{}")
            .unwrap()
            .expect_err("a local caller has no device to ask for");
        assert!(refused.contains("device asking"), "{refused}");

        crate::request_context::with_remote_peer("phone", || {
            for method in [
                "workspace.access.pending",
                "workspace.access.list",
                "workspace.access.set",
            ] {
                let refused = call(method, r#"{"peerId":"phone","allow":true}"#)
                    .unwrap()
                    .expect_err("a device must not answer its own request");
                assert!(refused.contains("local-only"), "{refused}");
            }
        });
    }

    #[test]
    fn a_refusal_names_the_request_it_is_answering() {
        // No grant exists in the test environment, so anything gated is
        // refused, and the envelope has to carry the id back or the caller
        // never matches the answer to its question.
        let line = r#"{"id":7,"method":"pty.spawn","params":{}}"#;
        let refusal = refuse_unpermitted(line, "phone").expect("must refuse");
        let value: Value = serde_json::from_str(&refusal).unwrap();
        assert_eq!(value["id"], 7);
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "workspace_not_allowed");
        // Ungated methods are answered, not refused.
        assert!(refuse_unpermitted(r#"{"id":8,"method":"info"}"#, "phone").is_none());
    }
}
