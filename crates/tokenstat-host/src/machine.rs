// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Dispatch methods for this machine's identity and the peers it trusts.
//!
//! Sessionless, and not because of speed. The Machines screen has to work on a
//! machine whose archive will not open: "who am I and who may connect" is the
//! screen somebody goes to *when* something is wrong, and putting it behind the
//! archive would take it away exactly then.

use serde::Deserialize;
use serde_json::{Value, json};
use tokenstat_identity::{MachineIdentity, PeerStore, Trust, fingerprint, public_key_from_hex};

#[derive(Debug, Deserialize)]
pub(crate) struct KeyParams {
    /// Public key as hex. Never a fingerprint: a fingerprint is a hash and
    /// cannot be turned back into the key it names.
    #[serde(default)]
    key: String,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    address: Option<String>,
}

/// Now, as RFC 3339. The peer store records times as strings from whichever
/// machine wrote them, so there is one place that decides the format.
pub(crate) fn now() -> String {
    jiff::Timestamp::now().to_string()
}

/// Answer a `machine.*` method, or `None` when it is not one.
pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    Some(match method {
        "machine.identity" => identity(),
        "machine.peers" => peers(),
        "machine.rename" => local_trust(|| rename(params)),
        "machine.pair" => local_trust(|| pair(params)),
        "machine.approve" => local_trust(|| set_trust(params, Trust::Approved)),
        "machine.revoke" => local_trust(|| set_trust(params, Trust::Revoked)),
        "machine.forget" => local_trust(|| forget(params)),
        _ => return None,
    })
}

fn local_trust(work: impl FnOnce() -> Result<Value, String>) -> Result<Value, String> {
    crate::request_context::refuse_remote("machine trust settings")?;
    work()
}

/// Who this machine is.
///
/// Creates the keypair on first call, which means simply opening the Machines
/// screen is enough to have an identity to show somebody. There is nothing to
/// generate, no button, and no state where the screen says "not set up yet".
fn identity() -> Result<Value, String> {
    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    Ok(json!({
        "key": identity.public_key_hex(),
        "fingerprint": identity.fingerprint(),
        // Three words over a hex fingerprint, because that is the comparison a
        // person performs instead of skims. Both are sent: the screen leads
        // with the words and keeps the fingerprint for whoever wants it.
        "words": tokenstat_identity::key_words(&identity.public_key()),
        "label": tokenstat_identity::machine_label(),
        "labelIsChosen": tokenstat_identity::machine_label_is_chosen(),
    }))
}

/// Call this machine something.
///
/// The name travels to a paired machine and nowhere else, so this is not a
/// setting with consequences beyond how a peer list reads. An empty name is a
/// reset rather than an error: the field is the undo.
fn rename(params: &str) -> Result<Value, String> {
    #[derive(Deserialize)]
    struct NameParams {
        #[serde(default)]
        name: String,
    }
    let p: NameParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    tokenstat_identity::set_machine_label(&p.name).map_err(|e| e.to_string())?;
    push_name_to_account(&p.name);
    identity()
}

/// Tell the account this machine's new name.
///
/// **Never in a test build.** This is one HTTP call against the real account
/// with this machine's real credentials, and `TOKENSTAT_IDENTITY_DIR` does not
/// redirect it: it moves the identity file, not the account. A unit test for
/// renaming therefore renamed the developer's own machine on the website, and
/// because the push runs on a detached thread that the process outlives by
/// nothing, the test's own undo often never landed. The name it happened to
/// use sat on the account afterwards.
///
/// The guard is `cfg!(test)` rather than an environment variable, because a
/// person may legitimately set any variable and none of them should mean
/// "do not update my account".
fn push_name_to_account(name: &str) {
    if cfg!(test) {
        return;
    }
    // With remote reach on, the account directory shows this name on the
    // other screens, so it is refreshed rather than waiting for a reconnect.
    crate::remote::register_if_tunnel_enabled();
    // And with remote reach off, the account still has a device list with this
    // machine in it. Renaming the computer here and leaving the website on the
    // old name is one name too many.
    //
    // Clearing is handled there too: `rename_machine` drops the choice and
    // then says this machine's own name, so "use the computer's name" leaves
    // the account showing that name rather than showing none.
    //
    // On its own thread: this is one HTTP round trip, and a rename must not
    // sit there waiting for it on a machine that is offline. Best effort: no
    // account, no call, no complaint.
    let named = name.to_string();
    std::thread::spawn(move || {
        if let Ok(machine_id) = tokenstat_sync::config::ensure_machine_id() {
            let _ = tokenstat_sync::profile::rename_machine(None, &machine_id, &named);
        }
    });
}

fn peers() -> Result<Value, String> {
    let store = PeerStore::load().map_err(|e| e.to_string())?;
    let listed: Vec<Value> = store.list().iter().map(peer_json).collect();
    Ok(Value::Array(listed))
}

fn peer_json(peer: &tokenstat_identity::Peer) -> Value {
    json!({
        "key": peer.key,
        "fingerprint": peer.fingerprint(),
        "words": peer.words(),
        "label": peer.label,
        "trust": match peer.trust {
            Trust::Pending => "pending",
            Trust::Approved => "approved",
            Trust::Revoked => "revoked",
        },
        "address": peer.address,
        "firstSeen": peer.first_seen,
        "lastSeen": peer.last_seen,
    })
}

/// Pair with a machine whose key somebody entered.
///
/// Approved outright: typing a key in *is* the approval, and asking again on
/// the next screen would train people to click through the question that
/// matters. This is also the path that needs no hosted service at all, which is
/// what makes the privacy claim checkable rather than promised.
fn pair(params: &str) -> Result<Value, String> {
    let p: KeyParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let key = public_key_from_hex(&p.key).map_err(|e| e.to_string())?;

    // Pinning your own key is never a connection: it is a loop somebody can
    // only click by accident, and the Machines screen now filters the machine
    // out of its own discovery list. Refuse here as well so a pasted or
    // account-supplied self-key gets the same answer from every path.
    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    if identity.public_key() == key {
        return Err("that is this machine's own key, not another machine".into());
    }

    let mut store = PeerStore::load().map_err(|e| e.to_string())?;
    // An empty name is "no name", not a machine called "". The stored fallback
    // is the fingerprint, so a row added by key alone still identifies the
    // peer until somebody names it; the screen leads with the word pair anyway.
    let label = p
        .label
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| fingerprint(&key));
    // An empty address is the same as none: this machine may connect *to* the
    // peer through the tunnel, but there is nothing to dial directly.
    let address = p
        .address
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let peer = store.add_approved(&key, &label, address.as_deref(), &now());
    store.save().map_err(|e| e.to_string())?;
    // Pairing by code is a person saying yes to one device by name, in front
    // of the machine, which is exactly the consent workspace access asks for.
    // Appearing on the account is not, and that path grants nothing.
    crate::workspace_policy::set_allowed(&tokenstat_identity::hex(&key), true)?;
    Ok(peer_json(&peer))
}

fn set_trust(params: &str, trust: Trust) -> Result<Value, String> {
    let p: KeyParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let key = public_key_from_hex(&p.key).map_err(|e| e.to_string())?;

    let mut store = PeerStore::load().map_err(|e| e.to_string())?;
    let changed = match trust {
        Trust::Approved => store.approve(&key),
        Trust::Revoked => store.revoke(&key),
        Trust::Pending => false,
    };
    if changed {
        store.save().map_err(|e| e.to_string())?;
    }
    // Approving in Devices is the same yes as typing a pairing code, and
    // revoking has to take the work back with it: a device nobody trusts
    // enough to reach this machine must not keep a grant waiting for it.
    match trust {
        // The canonical hex, not what the caller typed: the policy file is
        // keyed by the form `remote_peer` hands out.
        Trust::Approved => {
            crate::workspace_policy::set_allowed(&tokenstat_identity::hex(&key), true)?
        }
        Trust::Revoked => {
            crate::workspace_policy::set_allowed(&tokenstat_identity::hex(&key), false)?
        }
        Trust::Pending => {}
    }
    // False rather than an error: approving a peer that just went away is not
    // a failure the user did anything about, and it is racy by nature.
    Ok(json!({"changed": changed}))
}

fn forget(params: &str) -> Result<Value, String> {
    let p: KeyParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let key = public_key_from_hex(&p.key).map_err(|e| e.to_string())?;

    let mut store = PeerStore::load().map_err(|e| e.to_string())?;
    let forgotten = store.forget(&key);
    if forgotten {
        store.save().map_err(|e| e.to_string())?;
    }
    // A device this machine has forgotten must not come back to a grant it
    // was left holding.
    crate::workspace_policy::set_allowed(&tokenstat_identity::hex(&key), false)?;
    Ok(json!({"forgotten": forgotten}))
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_remote_peer_cannot_change_who_is_trusted() {
        crate::request_context::with_remote_peer("phone", || {
            for method in [
                "machine.approve",
                "machine.pair",
                "machine.revoke",
                "machine.forget",
                "machine.rename",
            ] {
                let refused = super::call(method, "{}").unwrap().expect_err(method);
                assert!(refused.contains("local-only"), "{method}: {refused}");
            }
        });
    }
}
