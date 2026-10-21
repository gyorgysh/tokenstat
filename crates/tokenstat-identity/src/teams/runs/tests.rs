// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::{
    MachineIdentity,
    team_host_proof::{HostChallenge, HostProofBinding},
    teams::{TeamTicket, TeamTicketBinding},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::signature;
use serde_json::{Value, json};

fn vector() -> Value {
    serde_json::from_str(include_str!(
        "../../../../../fixtures/teams/run-lease-v1.json"
    ))
    .unwrap()
}
fn keys() -> TrustedTeamKeys {
    TrustedTeamKeys::from_response(
        serde_json::from_value(vector()["keys"].clone()).unwrap(),
        "https://accounts.example.test",
    )
    .unwrap()
}
fn actor() -> VerifiedTeamTicket {
    keys()
        .verify(
            &TeamTicket::try_from(vector()["actorTicket"].as_str().unwrap().to_owned()).unwrap(),
            &TeamTicketBinding {
                device_key: &[0xaa; 32],
                host_key: &MachineIdentity::from_secret([7; 32]).public_key(),
                publisher_id: "fixture-owner",
                actor_id: Some("fixture-member"),
            },
            1767225601,
        )
        .unwrap()
}
fn lease() -> TeamRunLease {
    serde_json::from_value(vector()["lease"].clone()).unwrap()
}
fn signed(change: impl FnOnce(&mut Value)) -> TeamRunLease {
    let v = vector();
    let parts: Vec<_> = v["lease"].as_str().unwrap().split('.').collect();
    let mut c: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
    change(&mut c);
    let message = format!(
        "{}.{}.{}",
        parts[0],
        parts[1],
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&c).unwrap())
    );
    let key = signature::Ed25519KeyPair::from_seed_unchecked(&[7; 32]).unwrap();
    TeamRunLease::try_from(format!(
        "{message}.{}",
        URL_SAFE_NO_PAD.encode(key.sign(message.as_bytes()))
    ))
    .unwrap()
}
#[test]
fn verifies_node_lease_and_original_identity_without_reusing_the_viewing_ticket() {
    let v = vector();
    let actor = actor();
    let binding = TeamRunBinding {
        run: v["run"].as_str().unwrap(),
        initiator: &actor,
    };
    let proof = keys()
        .verify_run_lease(&lease(), &binding, 1767225601)
        .unwrap();
    assert_eq!(proof.claims().sub, "fixture-member");
    assert_eq!(proof.lease_seconds(1767225601), 30);
    assert!(TeamTicket::try_from(v["lease"].as_str().unwrap().to_owned()).is_err());
    assert!(TeamRunLease::try_from(v["actorTicket"].as_str().unwrap().to_owned()).is_err());
    assert!(!format!("{proof:?} {:?}", lease()).contains("fixture-member"));
    let later = signed(|c| {
        c["iat"] = json!(1767225671u64);
        c["exp"] = json!(1767225701u64);
        c["revision"] = json!(8);
    });
    assert_eq!(
        keys()
            .verify_run_lease(&later, &binding, 1767225672)
            .unwrap()
            .claims()
            .revision,
        8
    );
    assert!(matches!(
        keys().verify_run_lease(&lease(), &binding, 1767225631),
        Err(TeamTicketError::Expired)
    ));
}
#[test]
fn binds_every_original_target_and_grant_without_trusting_claimed_authorship() {
    let v = vector();
    let actor = actor();
    let binding = TeamRunBinding {
        run: v["run"].as_str().unwrap(),
        initiator: &actor,
    };
    for (field, value) in [
        ("sub", json!("fixture-other")),
        ("device", json!("11".repeat(32))),
        ("org", json!("org_other")),
        ("repository", json!("repo_other")),
        ("checkout", json!("checkout_other")),
        ("share", json!(format!("share_{}", "11".repeat(16)))),
        ("host", json!("11".repeat(32))),
        ("publisher", json!("fixture-other")),
        ("grant", json!(format!("grant_{}", "11".repeat(16)))),
        ("run", json!(format!("runlease_{}", "11".repeat(16)))),
    ] {
        assert!(
            matches!(
                keys().verify_run_lease(&signed(|c| c[field] = value), &binding, 1767225601),
                Err(TeamTicketError::BindingMismatch)
            ),
            "{field}"
        );
    }
    for (field, value) in [
        ("v", json!(2)),
        ("aud", json!("tokenstat-teams-host-v1")),
        ("iss", json!("https://other.example.test")),
        ("exp", json!(1767225632u64)),
        ("revision", json!(0)),
        ("grant", Value::Null),
        ("privatePath", json!("/fixture/private")),
    ] {
        assert!(
            keys()
                .verify_run_lease(&signed(|c| c[field] = value), &binding, 1767225601)
                .is_err(),
            "{field}"
        );
    }
}
#[test]
fn matches_native_create_and_renew_host_proofs_using_public_test_keys() {
    let v = vector();
    let identity = MachineIdentity::from_secret([7; 32]);
    for (name, now) in [("create", 1767225601000), ("renew", 1767225611000)] {
        let fixture = &v[name];
        let challenge: HostChallenge =
            serde_json::from_value(fixture["challenge"].clone()).unwrap();
        let expected = HostProofBinding {
            issuer: "https://accounts.example.test",
            actor: "fixture-owner",
            token: "abcdef0123456789abcdef01",
            machine: "fixture-host",
            organization: "org_fixture",
            checkout: "checkout_fixture",
            operation_hash: fixture["operationHash"].as_str().unwrap(),
        };
        let proof = challenge.answer(&identity, &expected, now).unwrap();
        assert_eq!(serde_json::to_value(proof).unwrap(), fixture["proof"]);
        assert!(
            challenge
                .answer(&MachineIdentity::from_secret([8; 32]), &expected, now)
                .is_err()
        );
    }
}

#[test]
fn only_an_unknown_signer_requests_keys_from_the_pinned_authority() {
    let v = vector();
    let actor = actor();
    let binding = TeamRunBinding {
        run: v["run"].as_str().unwrap(),
        initiator: &actor,
    };
    let lease: TeamRunLease = serde_json::from_value(v["rotatedLease"].clone()).unwrap();
    assert!(matches!(
        keys().verify_run_lease(&lease, &binding, 1767225611),
        Err(TeamTicketError::UntrustedAuthority)
    ));
    let fresh = TrustedTeamKeys::from_response(
        serde_json::from_value(v["rotatedKeys"].clone()).unwrap(),
        "https://accounts.example.test",
    )
    .unwrap();
    assert_eq!(
        fresh
            .verify_run_lease(&lease, &binding, 1767225611)
            .unwrap()
            .claims()
            .revision,
        2
    );
}
