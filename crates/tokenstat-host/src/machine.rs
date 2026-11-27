// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.
use serde::Deserialize;
use serde_json::{Value, json};
use tokenstat_identity::{MachineIdentity, PeerStore, Trust, fingerprint, public_key_from_hex};

#[derive(Debug, Deserialize)]
pub(crate) struct KeyParams {
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

        "machine.peers" => local_trust(peers),
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

fn identity() -> Result<Value, String> {
    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    Ok(json!({
        "key": identity.public_key_hex(),
        "fingerprint": identity.fingerprint(),


        "words": tokenstat_identity::key_words(&identity.public_key()),
        "label": tokenstat_identity::machine_label(),
        "labelIsChosen": tokenstat_identity::machine_label_is_chosen(),
    }))
}

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

fn push_name_to_account(name: &str) {
    if cfg!(test) {
        return;
    }

    crate::remote::register_if_tunnel_enabled();

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

fn pair(params: &str) -> Result<Value, String> {
    let p: KeyParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let key = public_key_from_hex(&p.key).map_err(|e| e.to_string())?;

    let identity = MachineIdentity::load_or_create().map_err(|e| e.to_string())?;
    if identity.public_key() == key {
        return Err("that is this machine's own key, not another machine".into());
    }

    let label = p
        .label
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| fingerprint(&key));

    let address = p
        .address
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let peer = PeerStore::update(|store| {
        (
            store.add_approved(&key, &label, address.as_deref(), &now()),
            true,
        )
    })
    .map_err(|e| e.to_string())?;

    grant_work(&key, true);
    Ok(peer_json(&peer))
}

fn grant_work(key: &tokenstat_identity::PublicKey, allow: bool) {
    let hex = tokenstat_identity::hex(key);
    if let Err(error) = crate::workspace_policy::set_allowed_by_with_label(
        &hex,
        allow,
        crate::access_audit::Authority::Console,
        None,
    ) {
        eprintln!("remote: could not record workspace access: {error}");
    }
}

fn set_trust(params: &str, trust: Trust) -> Result<Value, String> {
    let p: KeyParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let key = public_key_from_hex(&p.key).map_err(|e| e.to_string())?;

    let changed = PeerStore::update(|store| {
        let changed = match trust {
            Trust::Approved => store.approve(&key),
            Trust::Revoked => store.revoke(&key),
            Trust::Pending => false,
        };
        (changed, changed)
    })
    .map_err(|e| e.to_string())?;

    match trust {
        Trust::Approved if changed => grant_work(&key, true),
        Trust::Revoked => grant_work(&key, false),
        _ => {}
    }

    Ok(json!({"changed": changed}))
}

fn forget(params: &str) -> Result<Value, String> {
    let p: KeyParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
    let key = public_key_from_hex(&p.key).map_err(|e| e.to_string())?;

    let forgotten = PeerStore::update(|store| {
        let forgotten = store.forget(&key);
        (forgotten, forgotten)
    })
    .map_err(|e| e.to_string())?;

    grant_work(&key, false);
    Ok(json!({"forgotten": forgotten}))
}

#[cfg(test)]
mod tests {
    #[test]
    fn repeated_approval_preserves_a_disabled_workspace_grant() {
        crate::test_identity::isolated(|| {
            let key = tokenstat_identity::MachineIdentity::from_secret([63; 32]).public_key();
            tokenstat_identity::PeerStore::update(|store| {
                store.add_approved(&key, "Test device", None, "2026-10-12T00:00:00Z");
                ((), true)
            })
            .unwrap();
            super::grant_work(&key, false);
            let params = serde_json::json!({"key": tokenstat_identity::hex(&key)}).to_string();
            let result = super::set_trust(&params, tokenstat_identity::Trust::Approved).unwrap();
            assert_eq!(result["changed"], false);
            assert!(!crate::workspace_policy::is_allowed(
                &tokenstat_identity::hex(&key)
            ));
        });
    }

    #[test]
    fn a_remote_peer_cannot_change_who_is_trusted() {
        crate::request_context::with_remote_peer("phone", || {
            for method in [
                "machine.peers",
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
