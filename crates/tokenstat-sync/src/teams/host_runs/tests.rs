// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use crate::teams::{
    TeamWire, WireRequest,
    tests::{MockWire, fixture_replies, response},
};
use serde_json::{Value, json};
use std::sync::Mutex;
use tokenstat_identity::teams::{TeamTicket, TeamTicketBinding};

fn vector() -> Value {
    serde_json::from_str(include_str!(
        "../../../../../fixtures/teams/run-lease-v1.json"
    ))
    .unwrap()
}
fn actor() -> VerifiedTeamTicket {
    let v = vector();
    let keys = TrustedTeamKeys::from_response(
        serde_json::from_value(v["keys"].clone()).unwrap(),
        "https://accounts.example.test",
    )
    .unwrap();
    keys.verify(
        &TeamTicket::try_from(v["actorTicket"].as_str().unwrap().to_owned()).unwrap(),
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
fn caps() -> Value {
    json!({"enabled":true,"version":1,"actorId":"fixture-owner","deviceKey":MachineIdentity::from_secret([7;32]).public_key_hex(),"scopes":["teams:read","teams:manage","teams:connect"],"authorizationRequired":false,"authorizationPath":"/settings/teams/devices/abcdef0123456789abcdef01","features":[FEATURE],"ticketLifetimeSeconds":60})
}
fn lease_reply(revision: u64) -> Value {
    let v = vector();
    let exp = v["nowMs"].as_i64().unwrap() / 1000 + if revision == 1 { 30 } else { 40 };
    json!({"id":v["run"],"revision":revision,"state":"active","lease":v[if revision==1{"lease"}else{"renewedLease"}],"expiresAt":jiff::Timestamp::from_second(exp).unwrap().to_string()})
}
fn replies() -> Vec<Result<(u16, Vec<u8>), TeamError>> {
    let v = vector();
    vec![
        response(caps()),
        response(v["keys"].clone()),
        response(v["create"]["challenge"].clone()),
        response(lease_reply(1)),
    ]
}
fn time() -> Arc<Mutex<Time>> {
    Arc::new(Mutex::new(Time {
        stamp: Stamp {
            awake: std::time::Instant::now(),
            boot: Duration::from_secs(100),
        },
        wall_ms: vector()["nowMs"].as_i64().unwrap(),
    }))
}
fn clock(now: &Arc<Mutex<Time>>) -> Clock {
    let now = Arc::clone(now);
    Arc::new(move || Some(*now.lock().unwrap()))
}
fn advance(now: &Arc<Mutex<Time>>, seconds: u64) {
    let mut now = now.lock().unwrap();
    now.wall_ms += seconds as i64 * 1000;
    now.stamp.awake += Duration::from_secs(seconds);
    now.stamp.boot += Duration::from_secs(seconds);
}
fn fixture() -> (HostRunAuthority, Arc<MockWire>, Arc<Mutex<Time>>) {
    let (client, wire) = fixture_replies(replies(), false);
    let now = time();
    let v = vector();
    let authority = admit(
        client,
        MachineIdentity::from_secret([7; 32]),
        "fixture-host".into(),
        v["run"].as_str().unwrap(),
        actor(),
        clock(&now),
    )
    .unwrap();
    (authority, wire, now)
}

#[test]
fn birth_budget_uses_the_original_continuous_deadline_and_never_revives_after_sleep() {
    let (authority, _, now) = fixture();
    let before = authority.remaining().unwrap();
    assert!(before > Duration::from_secs(2) && before <= Duration::from_secs(30));
    {
        let mut time = now.lock().unwrap();
        time.wall_ms -= 1000;
        time.stamp.boot += Duration::from_secs(4);
    }
    assert!(authority.remaining().unwrap() <= before - Duration::from_secs(4));
    let saved = *now.lock().unwrap();
    {
        let mut time = now.lock().unwrap();
        time.wall_ms -= 60000;
        time.stamp.boot += Duration::from_secs(30);
    }
    assert!(authority.remaining().is_err());
    *now.lock().unwrap() = saved;
    assert!(authority.remaining().is_err());
}
fn pending(authority: &mut HostRunAuthority, now: &Arc<Mutex<Time>>) {
    authority.pending = Some(Pending {
        expected_revision: 1,
        operation_id: vector()["renew"]["operation"]["operationId"]
            .as_str()
            .unwrap()
            .to_owned(),
        start: *now.lock().unwrap(),
    });
}
#[test]
fn admits_exact_public_proof_without_exposing_a_host_credential_or_launch_permit() {
    let (authority, wire, _) = fixture();
    authority.ensure_live().unwrap();
    assert_eq!(authority.lease().claims().sub, "fixture-member");
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    assert!(requests.iter().all(|r| r.3));
    assert!(requests[2].1.ends_with("/teams/runs/challenge"));
    assert_eq!(
        requests[2].2.as_ref().unwrap(),
        &vector()["create"]["operation"]
    );
    assert_eq!(
        requests[3].2.as_ref().unwrap()["hostProof"],
        vector()["create"]["proof"]
    );
    assert!(!format!("{authority:?}").contains("fixture-member"));
}
#[test]
fn retries_only_the_same_unresolved_renewal_without_extending_its_original_budget() {
    let (mut authority, wire, now) = fixture();
    advance(&now, 10);
    pending(&mut authority, &now);
    let v = vector();
    wire.reply.lock().unwrap().extend([
        response(v["renew"]["challenge"].clone()),
        Err(TeamError::Network),
    ]);
    assert_eq!(authority.renew().unwrap_err(), TeamError::Network);
    authority.ensure_live().unwrap();
    advance(&now, 5);
    wire.reply.lock().unwrap().extend([
        response(v["renew"]["challenge"].clone()),
        response(lease_reply(2)),
    ]);
    authority.renew().unwrap();
    assert_eq!(authority.lease().claims().revision, 2);
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests[5].2, requests[7].2);
    assert_eq!(
        requests[5].2.as_ref().unwrap()["hostProof"],
        v["renew"]["proof"]
    );
    drop(requests);
    // The reply arrived at t+15, but its original request was t+10. Sleep
    // past t+40 with a rolled-back wall clock cannot give it another 5s.
    {
        let mut time = now.lock().unwrap();
        time.stamp.boot += Duration::from_secs(25);
        time.wall_ms = v["nowMs"].as_i64().unwrap();
    }
    assert!(authority.ensure_live().is_err());
    let before = wire.requests.lock().unwrap().len();
    assert!(authority.renew().is_err());
    assert_eq!(wire.requests.lock().unwrap().len(), before);
}
struct OnReply {
    wire: Arc<MockWire>,
    now: Arc<Mutex<Time>>,
    trigger: usize,
}
impl TeamWire for OnReply {
    fn send(&self, request: WireRequest) -> Result<(u16, Vec<u8>), TeamError> {
        let reply = self.wire.send(request);
        if self.wire.requests.lock().unwrap().len() == self.trigger {
            self.now.lock().unwrap().stamp.boot += Duration::from_secs(30);
        }
        reply
    }
}
#[test]
fn delayed_signed_renewal_cannot_revive_an_expired_run_after_sleep_and_wall_rollback() {
    let (mut authority, wire, now) = fixture();
    advance(&now, 10);
    pending(&mut authority, &now);
    let v = vector();
    wire.reply.lock().unwrap().extend([
        response(v["renew"]["challenge"].clone()),
        response(lease_reply(2)),
    ]);
    authority.client.wire = Arc::new(OnReply {
        wire: wire.clone(),
        now: now.clone(),
        trigger: 6,
    });
    assert!(authority.renew().is_err());
    assert_eq!(authority.lease().claims().revision, 1);
    {
        let mut time = now.lock().unwrap();
        time.wall_ms = v["nowMs"].as_i64().unwrap();
        time.stamp.boot -= Duration::from_secs(20);
    }
    assert!(authority.ensure_live().is_err());
    assert_eq!(wire.requests.lock().unwrap().len(), 6);
}
#[test]
fn retiring_local_authority_is_terminal_even_when_cloud_cleanup_cannot_be_reached() {
    let (mut authority, wire, _) = fixture();
    assert_eq!(authority.retire().unwrap_err(), TeamError::Network);
    assert!(authority.ensure_live().is_err());
    let before = wire.requests.lock().unwrap().len();
    assert!(authority.renew().is_err());
    assert_eq!(wire.requests.lock().unwrap().len(), before);
}
#[test]
fn account_and_clock_failures_permanently_retire_the_original_authority() {
    let (authority, _, now) = fixture();
    advance(&now, 1);
    let failed = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let flag = failed.clone();
    let mut authority = authority;
    authority.clock = Arc::new(move || {
        if flag.load(Ordering::Acquire) {
            None
        } else {
            Some(*now.lock().unwrap())
        }
    });
    assert!(authority.ensure_live().is_err());
    failed.store(false, Ordering::Release);
    assert!(authority.ensure_live().is_err());
    let (mut authority, _, _) = fixture();
    let original = authority.client.clone();
    authority.client = original
        .clone()
        .with_retirement_guard(|| Err(TeamError::AccountChanged));
    assert_eq!(
        authority.ensure_live().unwrap_err(),
        TeamError::AccountChanged
    );
    authority.client = original;
    assert!(authority.ensure_live().is_err());
}
#[test]
fn rejects_unconfigured_hosts_and_mismatched_signed_reply_metadata() {
    let now = time();
    let v = vector();
    let mut c = caps();
    c["features"] = json!([]);
    let (client, wire) = fixture_replies(vec![response(c)], false);
    assert_eq!(
        admit(
            client,
            MachineIdentity::from_secret([7; 32]),
            "fixture-host".into(),
            v["run"].as_str().unwrap(),
            actor(),
            clock(&now)
        )
        .unwrap_err(),
        TeamError::Unsupported
    );
    assert_eq!(wire.requests.lock().unwrap().len(), 1);
    for (field, value) in [
        ("id", json!(format!("runlease_{}", "00".repeat(16)))),
        ("revision", json!(2)),
        ("expiresAt", json!("2026-01-01T00:00:32Z")),
        ("privatePath", json!("/fixture/private")),
    ] {
        let mut list = replies();
        let mut reply = lease_reply(1);
        reply[field] = value;
        *list.last_mut().unwrap() = response(reply);
        let (client, _) = fixture_replies(list, false);
        assert_eq!(
            admit(
                client,
                MachineIdentity::from_secret([7; 32]),
                "fixture-host".into(),
                v["run"].as_str().unwrap(),
                actor(),
                clock(&now)
            )
            .unwrap_err(),
            TeamError::InvalidResponse,
            "{field}"
        );
    }
}

#[test]
fn refreshes_an_unknown_signer_only_through_the_original_account_and_lease_budget() {
    let (mut authority, wire, now) = fixture();
    advance(&now, 10);
    pending(&mut authority, &now);
    let v = vector();
    let mut reply = lease_reply(2);
    reply["lease"] = v["rotatedLease"].clone();
    wire.reply.lock().unwrap().extend([
        response(v["renew"]["challenge"].clone()),
        response(reply),
        response(v["rotatedKeys"].clone()),
    ]);
    authority.renew().unwrap();
    assert_eq!(authority.lease().claims().revision, 2);
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests.len(), 7);
    assert!(requests[6].1.ends_with("/teams/keys"));
}

#[test]
fn a_key_refresh_never_extends_an_expired_original_run() {
    let (mut authority, wire, now) = fixture();
    advance(&now, 10);
    pending(&mut authority, &now);
    let v = vector();
    let mut reply = lease_reply(2);
    reply["lease"] = v["rotatedLease"].clone();
    wire.reply.lock().unwrap().extend([
        response(v["renew"]["challenge"].clone()),
        response(reply),
        response(v["rotatedKeys"].clone()),
    ]);
    authority.client.wire = Arc::new(OnReply {
        wire: wire.clone(),
        now: now.clone(),
        trigger: 7,
    });
    assert!(authority.renew().is_err());
    assert_eq!(authority.lease().claims().revision, 1);
    assert!(authority.ensure_live().is_err());
    assert_eq!(wire.requests.lock().unwrap().len(), 7);
}
