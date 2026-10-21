// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

fn source() -> Source {
    Source {
        conversation: "chat_fixture".into(),
        workspace: "workspace_fixture".into(),
        created_at_ms: 1,
    }
}
fn record() -> Record {
    Record::new(
        10,
        "A fictional comment".into(),
        2,
        Attribution {
            scope: Scope {
                issuer: "https://accounts.example.test".into(),
                organization: "org_fixture".into(),
                repository: "repo_fixture".into(),
                checkout: "checkout_fixture".into(),
                share: format!("share_{}", "a".repeat(32)),
            },
            actor: Actor {
                id: "fixture-person".into(),
                device: "a".repeat(64),
                name: "Example member".into(),
                handle: None,
                avatar: None,
            },
            client_message_id: "fixture-message".into(),
            client_message_created_at_ms: 1,
        },
    )
}

#[test]
fn a_run_receipt_cannot_be_reinterpreted_as_a_comment_or_moved_to_another_source() {
    use crate::chat_receipts::team_runs as runs;
    let row = record();
    let mut journal = Journal::new(source());
    let a = &row.attribution;
    let mut ledger = runs::Ledger::new(runs::Source {
        conversation: source().conversation,
        workspace: source().workspace,
        created_at_ms: 1,
    })
    .unwrap();
    ledger
        .reserve(
            runs::Request {
                scope: runs::Scope {
                    issuer: a.scope.issuer.clone(),
                    organization: a.scope.organization.clone(),
                    repository: a.scope.repository.clone(),
                    checkout: a.scope.checkout.clone(),
                    share: a.scope.share.clone(),
                },
                actor: runs::Actor {
                    person: a.actor.id.clone(),
                    device: a.actor.device.clone(),
                },
                client_message_id: a.client_message_id.clone(),
                client_message_created_at_ms: 1,
                request_digest: "11".repeat(32),
                context_digest: "22".repeat(32),
                checkout_digest: "33".repeat(32),
                backend: "codex".into(),
            },
            runs::Binding {
                fence: runs::Fence::new(format!("run_{}", "44".repeat(16)), "55".repeat(32))
                    .unwrap(),
                cloud_reference: format!("runlease_{}", "66".repeat(16)),
                grant: format!("grant_{}", "77".repeat(16)),
            },
            2,
        )
        .unwrap();
    journal.runs = Some(ledger);
    assert!(journal.receipt(&row).is_err());
    let mut raw: Value = serde_json::from_slice(&journal.encoded().unwrap()).unwrap();
    raw["runs"]["source"]["conversation"] = json!("other-chat");
    assert!(Journal::decode(&serde_json::to_vec(&raw).unwrap(), &source()).is_err());
    let durable = Journal::decode(&journal.encoded().unwrap(), &source()).unwrap();
    assert!(durable.receipt(&row).is_err());
}

#[test]
fn a_reserved_row_is_recovered_exactly_once_without_replaying_missing_text() {
    let mut journal = Journal::new(source());
    let row = record();
    journal.reserve(row.clone(), b"prefix\n").unwrap();
    let bytes = journal.encoded().unwrap();
    let mut recovered = Journal::decode(&bytes, &source()).unwrap();
    assert!(!recovered.observe(b"prefix\n").unwrap());
    assert!(recovered.receipt(&row).unwrap().is_none());
    let a = &row.attribution;
    assert_eq!(
        recovered
            .status(&a.scope, &a.actor.id, &a.client_message_id)
            .unwrap(),
        Some(Status::Pending)
    );
    let original = recovered
        .pending_record(&row, b"prefix\n")
        .unwrap()
        .unwrap();
    assert_eq!(original.at_ms, 2);
    let mut canonical = b"prefix\n".to_vec();
    canonical.extend(original.encoded().unwrap());
    assert!(recovered.observe(&canonical).unwrap());
    assert!(!recovered.observe(&canonical).unwrap());
    assert!(matches!(
        recovered.receipt(&row).unwrap(),
        Some(Receipt::Accepted { seq: 10, .. })
    ));
    assert_eq!(
        recovered
            .status(&a.scope, &a.actor.id, &a.client_message_id)
            .unwrap(),
        Some(Status::Accepted { seq: 10, at_ms: 2 })
    );
    assert!(recovered.reserve(row, &canonical).is_err());
    let durable = Journal::decode(&recovered.encoded().unwrap(), &source()).unwrap();
    assert!(
        !String::from_utf8(durable.encoded().unwrap())
            .unwrap()
            .contains("A fictional comment")
    );
}

#[test]
fn receipts_bind_person_scope_content_and_original_attempt_time_across_devices() {
    let mut journal = Journal::new(source());
    let row = record();
    journal.reserve(row.clone(), b"").unwrap();
    journal.observe(&row.encoded().unwrap()).unwrap();
    for edit in 0..6 {
        let mut other = row.clone();
        match edit {
            0 => other.attribution.actor.id.push('x'),
            1 => other.attribution.scope.organization.push('x'),
            2 => other.attribution.scope.checkout.push('x'),
            3 => other.attribution.scope.share = format!("share_{}", "b".repeat(32)),
            4 => other.attribution.scope.issuer.push('x'),
            _ => other.attribution.client_message_id.push('x'),
        }
        assert!(journal.receipt(&other).unwrap().is_none());
    }
    let mut other_device = row.clone();
    other_device.attribution.actor.device = "b".repeat(64);
    assert!(journal.receipt(&other_device).unwrap().is_some());
    assert!(
        journal
            .author(&serde_json::to_value(other_device).unwrap(), row.seq)
            .is_err()
    );
    let mut changed = row.clone();
    changed.text.push('x');
    assert!(journal.receipt(&changed).is_err());
    changed = row.clone();
    changed.attribution.client_message_created_at_ms += 1;
    assert!(journal.receipt(&changed).is_err());
    changed = row.clone();
    changed.attribution.actor.name = "Renamed member".into();
    assert!(journal.receipt(&changed).unwrap().is_some());
    assert!(
        Journal::decode(
            &journal.encoded().unwrap(),
            &Source {
                conversation: "other".into(),
                ..source()
            }
        )
        .is_err()
    );
}

#[test]
fn exact_canonical_proof_is_required_for_authors_and_missing_rows_fail_closed() {
    let row = record();
    let raw = serde_json::to_value(&row).unwrap();
    let mut journal = Journal::new(source());
    assert!(journal.author(&raw, row.seq).unwrap().is_none());
    journal.reserve(row.clone(), b"").unwrap();
    journal.observe(&row.encoded().unwrap()).unwrap();
    let verified = journal.author(&raw, row.seq).unwrap().unwrap();
    assert_eq!(verified.person["id"], "fixture-person");
    assert_eq!(verified.scope.share, row.attribution.scope.share);
    assert_eq!(verified.key, row.key().unwrap());
    let mut forged = raw;
    forged["teamComment"]["actor"]["name"] = json!("Forged owner");
    assert!(journal.author(&forged, row.seq).is_err());
    assert!(
        journal
            .require_complete(&row.attribution.scope.share, &Default::default())
            .is_err()
    );
    assert!(
        journal
            .require_complete("another-share", &Default::default())
            .is_ok()
    );
    assert!(
        journal
            .require_complete(&row.attribution.scope.share, &[row.key().unwrap()].into())
            .is_ok()
    );
}

#[test]
fn another_writer_can_retire_only_a_provably_unwritten_reservation() {
    let row = record();
    let mut journal = Journal::new(source());
    journal.reserve(row.clone(), b"prefix\n").unwrap();
    assert!(journal.retire_unwritten(b"changed\n").is_err());
    assert!(journal.observe(b"prefix\ntorn").is_err());
    assert!(journal.retire_unwritten(b"prefix\n").unwrap());
    assert!(matches!(
        journal.receipt(&row).unwrap(),
        Some(Receipt::NotAccepted { .. })
    ));
    let a = &row.attribution;
    assert_eq!(
        journal
            .status(&a.scope, &a.actor.id, &a.client_message_id)
            .unwrap(),
        Some(Status::NotAccepted)
    );
    assert!(
        journal
            .status(&a.scope, "another-person", &a.client_message_id)
            .unwrap()
            .is_none()
    );
    assert!(journal.reserve(row, b"prefix\n").is_err());
}

#[test]
fn a_full_or_wrong_source_journal_never_evicts_an_earlier_receipt() {
    let mut journal = Journal::new(source());
    for i in 0..CAPACITY {
        journal.receipts.insert(
            format!("{i:064x}"),
            Receipt::NotAccepted {
                request_digest: "a".repeat(64),
            },
        );
    }
    let encoded = journal.encoded().unwrap();
    let mut recovered = Journal::decode(&encoded, &source()).unwrap();
    assert!(recovered.reserve(record(), b"").is_err());
    assert_eq!(recovered.receipts.len(), CAPACITY);
    assert_eq!(recovered.encoded().unwrap(), encoded);
    let mut wrong = source();
    wrong.created_at_ms += 1;
    assert!(Journal::decode(&encoded, &wrong).is_err());
    journal.version = 2;
    assert!(Journal::decode(&journal.encoded().unwrap(), &source()).is_err());
}

#[test]
fn materializing_retained_rows_preserves_the_individual_authorship_proof() {
    let mut row = record();
    row.seq = 1000;
    let mut journal = Journal::new(source());
    journal.reserve(row.clone(), b"").unwrap();
    journal.observe(&row.encoded().unwrap()).unwrap();
    let Value::Object(prefix) =
        json!({"kind":"user","text":"old private text".repeat(100),"at_ms":1})
    else {
        panic!()
    };
    let mut history = crate::work_transcript_identity::encoded(prefix, 0).unwrap();
    let encoded = row.encoded().unwrap();
    history.extend_from_slice(&encoded);
    let kept = crate::work_transcript_identity::retained(&history, encoded.len()).unwrap();
    let raw: Value = serde_json::from_slice(&kept).unwrap();
    assert_eq!(
        journal.author(&raw, row.seq).unwrap().unwrap().person["id"],
        "fixture-person"
    );
}

#[test]
fn invalid_actor_scope_and_oversized_records_fail_before_a_reservation() {
    for change in 0..7 {
        let mut row = record();
        match change {
            0 => row.kind = "agent".into(),
            1 => row.attribution.actor.avatar = Some("https://another.example.test/tracker".into()),
            2 => row.attribution.actor.name = "x".repeat(129),
            3 => row.attribution.actor.device = "x".repeat(64),
            4 => row.attribution.scope.issuer = "http://another.example.test".into(),
            5 => row.attribution.scope.share = "share_bad".into(),
            _ => row.text = "x".repeat(8193),
        }
        let mut journal = Journal::new(source());
        let before = journal.encoded().unwrap();
        assert!(journal.reserve(row, b"").is_err());
        assert_eq!(journal.encoded().unwrap(), before);
    }
}
