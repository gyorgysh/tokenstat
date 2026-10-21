// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use serde_json::{Value, json};

fn source() -> Source {
    Source {
        conversation: "chat_fixture".into(),
        workspace: "workspace_fixture".into(),
        created_at_ms: 1,
    }
}
fn request() -> Request {
    Request {
        scope: Scope {
            issuer: "https://accounts.example.test".into(),
            organization: "org_fixture".into(),
            repository: "repo_fixture".into(),
            checkout: "checkout_fixture".into(),
            share: format!("share_{}", "ab".repeat(16)),
        },
        actor: Actor {
            person: "fixture-person".into(),
            device: "11".repeat(32),
        },
        client_message_id: "fixture-message".into(),
        client_message_created_at_ms: 1,
        request_digest: "22".repeat(32),
        context_digest: "33".repeat(32),
        checkout_digest: "44".repeat(32),
        backend: "codex".into(),
    }
}
fn binding(n: u64) -> Binding {
    Binding {
        fence: Fence::new(format!("run_{n:032x}"), format!("{n:064x}")).unwrap(),
        cloud_reference: format!("runlease_{n:032x}"),
        grant: format!("grant_{n:032x}"),
    }
}
fn canonical() -> Canonical {
    Canonical {
        sequence: 10,
        record_digest: "55".repeat(32),
    }
}
fn reserve() -> Ledger {
    let mut ledger = Ledger::new(source()).unwrap();
    assert_eq!(
        ledger.reserve(request(), binding(1), 2).unwrap(),
        Reservation::New
    );
    ledger
}
fn transition(ledger: &mut Ledger, state: State) -> Result<bool, Error> {
    let r = request();
    ledger.transition(
        &r.scope,
        &r.actor.person,
        &r.client_message_id,
        &binding(1).fence,
        state,
        3,
    )
}
fn bind(ledger: &mut Ledger) {
    let r = request();
    assert!(
        ledger
            .bind_canonical(
                &r.scope,
                &r.actor.person,
                &r.client_message_id,
                &binding(1).fence,
                canonical()
            )
            .unwrap()
    );
}

#[test]
fn a_durable_launch_intent_never_becomes_permission_to_replay_after_a_restart() {
    let mut ledger = reserve();
    assert_eq!(
        transition(&mut ledger, State::Launching),
        Err(Error::Conflict)
    );
    bind(&mut ledger);
    assert!(transition(&mut ledger, State::Launching).unwrap());
    let bytes = ledger.encoded().unwrap();
    let mut recovered = Ledger::decode(&bytes, &source()).unwrap();
    let r = request();
    assert_eq!(
        recovered
            .status(&r.scope, &r.actor.person, &r.client_message_id)
            .unwrap()
            .unwrap()
            .state(),
        State::Launching
    );
    assert!(!transition(&mut recovered, State::Launching).unwrap());
    assert_eq!(
        recovered.reserve(r.clone(), binding(2), 4).unwrap(),
        Reservation::Existing
    );
    assert_eq!(recovered.unresolved().unwrap().binding(), &binding(1));
    assert!(transition(&mut recovered, State::NeedsRecovery).unwrap());
    assert_eq!(
        transition(&mut recovered, State::Running),
        Err(Error::Conflict)
    );
    assert_eq!(
        transition(&mut recovered, State::NotStarted),
        Err(Error::Conflict)
    );
    assert!(transition(&mut recovered, State::Recovered).unwrap());
    assert_eq!(
        recovered.reserve(r, binding(2), 5).unwrap(),
        Reservation::Existing
    );
    assert!(recovered.unresolved().is_none());
}
#[test]
fn original_person_attempt_survives_device_and_grant_changes_without_substitution() {
    let mut ledger = reserve();
    let original = request();
    let mut next = original.clone();
    next.actor.device = "66".repeat(32);
    assert_eq!(
        ledger.reserve(next, binding(2), 3).unwrap(),
        Reservation::Existing
    );
    let record = ledger
        .status(
            &original.scope,
            &original.actor.person,
            &original.client_message_id,
        )
        .unwrap()
        .unwrap();
    assert_eq!(record.request().actor.device, original.actor.device);
    assert_eq!(record.binding().grant, binding(1).grant);
    for part in 0..5 {
        let mut changed = original.clone();
        match part {
            0 => changed.request_digest = "77".repeat(32),
            1 => changed.context_digest = "77".repeat(32),
            2 => changed.checkout_digest = "77".repeat(32),
            3 => changed.client_message_created_at_ms += 1,
            _ => changed.backend = "claude".into(),
        };
        assert_eq!(ledger.reserve(changed, binding(2), 4), Err(Error::Conflict));
    }
    let mut other_person = original;
    other_person.actor.person = "another-person".into();
    assert_eq!(
        ledger.reserve(other_person, binding(2), 4),
        Err(Error::Busy)
    );
}
#[test]
fn stale_completion_and_stop_cannot_change_a_replacement_run() {
    let mut ledger = reserve();
    bind(&mut ledger);
    transition(&mut ledger, State::Launching).unwrap();
    transition(&mut ledger, State::Running).unwrap();
    transition(&mut ledger, State::Succeeded).unwrap();
    let mut next = request();
    next.client_message_id = "next-message".into();
    assert_eq!(
        ledger.reserve(next.clone(), binding(2), 5).unwrap(),
        Reservation::New
    );
    assert_eq!(
        ledger.transition(
            &next.scope,
            &next.actor.person,
            &next.client_message_id,
            &binding(1).fence,
            State::NotStarted,
            6
        ),
        Err(Error::Conflict)
    );
    assert_eq!(
        transition(&mut ledger, State::Stopping),
        Err(Error::Conflict)
    );
    assert_eq!(
        ledger.unresolved().unwrap().binding().fence,
        binding(2).fence
    );
}
#[test]
fn canonical_receipt_identity_and_terminal_outcome_are_immutable() {
    let mut ledger = reserve();
    bind(&mut ledger);
    let r = request();
    assert!(
        !ledger
            .bind_canonical(
                &r.scope,
                &r.actor.person,
                &r.client_message_id,
                &binding(1).fence,
                canonical()
            )
            .unwrap()
    );
    let mut other = canonical();
    other.record_digest = "88".repeat(32);
    assert_eq!(
        ledger.bind_canonical(
            &r.scope,
            &r.actor.person,
            &r.client_message_id,
            &binding(1).fence,
            other
        ),
        Err(Error::Conflict)
    );
    transition(&mut ledger, State::Launching).unwrap();
    transition(&mut ledger, State::Running).unwrap();
    transition(&mut ledger, State::Stopping).unwrap();
    transition(&mut ledger, State::Stopped).unwrap();
    assert!(!transition(&mut ledger, State::Stopped).unwrap());
    for state in [
        State::Launching,
        State::Running,
        State::Succeeded,
        State::Failed,
        State::NeedsRecovery,
    ] {
        assert_eq!(transition(&mut ledger, state), Err(Error::Conflict));
    }
}
#[test]
fn retired_run_cloud_and_fence_identities_are_not_reused() {
    for collision in 0..3 {
        let mut ledger = reserve();
        transition(&mut ledger, State::NotStarted).unwrap();
        let mut r = request();
        r.client_message_id = "next-message".into();
        let mut next = binding(2);
        match collision {
            0 => {
                next.fence =
                    Fence::new(binding(1).fence.run_id, binding(2).fence.incarnation).unwrap()
            }
            1 => {
                next.fence =
                    Fence::new(binding(2).fence.run_id, binding(1).fence.incarnation).unwrap()
            }
            _ => next.cloud_reference = binding(1).cloud_reference,
        };
        assert_eq!(ledger.reserve(r, next, 3), Err(Error::Conflict));
    }
}
#[test]
fn stored_receipts_fail_closed_for_wrong_source_scope_or_unverified_schema() {
    let ledger = reserve();
    let bytes = ledger.encoded().unwrap();
    assert!(
        Ledger::decode(
            &bytes,
            &Source {
                conversation: "another-chat".into(),
                ..source()
            }
        )
        .is_err()
    );
    for edit in 0..7 {
        let mut raw: Value = serde_json::from_slice(&bytes).unwrap();
        let row = raw["records"]
            .as_object_mut()
            .unwrap()
            .values_mut()
            .next()
            .unwrap();
        match edit {
            0 => row["binding"]["fence"]["incarnation"] = json!("bad"),
            1 => row["request"]["actor"]["device"] = json!("bad"),
            2 => row["state"] = json!("running"),
            3 => row["request"]["scope"]["issuer"] = json!("https://accounts.example.test/private"),
            4 => row["request"]["prompt"] = json!("PRIVATE_FIXTURE_TEXT"),
            5 => row["request"]["requestDigest"] = json!("bad"),
            _ => row["updatedAtMs"] = json!(0),
        };
        assert!(serde_json::from_value::<Ledger>(raw).is_err(), "{edit}");
    }
    let r = request();
    let mut other = r.scope.clone();
    other.checkout = "another-checkout".into();
    assert!(
        ledger
            .status(&other, &r.actor.person, &r.client_message_id)
            .unwrap()
            .is_none()
    );
}
#[test]
fn capacity_failure_does_not_evict_an_old_attempt_or_leave_a_new_one() {
    let mut ledger = reserve();
    transition(&mut ledger, State::NotStarted).unwrap();
    let mut row = ledger.records.values().next().unwrap().clone();
    for n in 2..=CAPACITY as u64 {
        row.binding = binding(n);
        row.request.client_message_id = format!("message-{n}");
        ledger
            .records
            .insert(row.request.key().unwrap(), row.clone());
    }
    let mut r = request();
    r.client_message_id = "additional-message".into();
    assert_eq!(
        ledger.reserve(r.clone(), binding(CAPACITY as u64 + 1), 5),
        Err(Error::Full)
    );
    assert!(
        ledger
            .status(&r.scope, &r.actor.person, &r.client_message_id)
            .unwrap()
            .is_none()
    );
    let original = request();
    assert_eq!(
        ledger.reserve(original, binding(10000), 6).unwrap(),
        Reservation::Existing
    );
    assert_eq!(ledger.records.len(), CAPACITY);
}

#[test]
fn local_path_identity_preserves_unicode_whitespace_and_legacy_epoch_time() {
    let source = Source {
        workspace: "/tmp/資料\nQuarter 'A' ".into(),
        created_at_ms: 0,
        ..source()
    };
    let mut ledger = Ledger::new(source.clone()).unwrap();
    ledger.reserve(request(), binding(1), 2).unwrap();
    let bytes = ledger.encoded().unwrap();
    assert!(
        Ledger::decode(&bytes, &source)
            .unwrap()
            .unresolved()
            .is_some()
    );
    let mut changed = source.clone();
    changed.workspace = changed.workspace.replace('\n', "");
    assert!(Ledger::decode(&bytes, &changed).is_err());
    let mut invalid = source;
    invalid.workspace.push('\0');
    assert!(Ledger::new(invalid).is_err());
}
