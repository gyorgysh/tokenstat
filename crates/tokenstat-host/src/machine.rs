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
        "machine.rename" => rename(params),
        "machine.peers" => peers(),
        "machine.pair" => pair(params),
        "machine.approve" => set_trust(params, Trust::Approved),
        "machine.revoke" => set_trust(params, Trust::Revoked),
        "machine.forget" => forget(params),
        _ => return None,
    })
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
        // Two words over a hex fingerprint, because that is the comparison a
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
    // The nearby-machines list on every other screen is a Bonjour record that
    // carried the old name, so a rename that stopped at the file would leave
    // this machine introducing itself as somebody it no longer is. A failure to
    // re-advertise does not fail the rename: the name is saved either way, and
    // the worst case is a stale line until serving restarts.
    if let Err(e) = crate::remote::readvertise() {
        eprintln!("remote: renamed, but could not advertise the new name: {e}");
    }
    // The whole identity back, not just the name. One shape for "who am I"
    // means the caller replaces what it holds instead of patching a field.
    identity()
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

    let mut store = PeerStore::load().map_err(|e| e.to_string())?;
    let label = p.label.unwrap_or_else(|| fingerprint(&key));
    let peer = store.add_approved(&key, &label, p.address.as_deref(), &now());
    store.save().map_err(|e| e.to_string())?;
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
    Ok(json!({"forgotten": forgotten}))
}
