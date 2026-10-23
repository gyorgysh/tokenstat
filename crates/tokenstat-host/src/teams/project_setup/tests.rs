// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;

fn fixture() -> (tempfile::TempDir, Store, Record) {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("Project");
    std::fs::create_dir(&folder).unwrap();
    let record = Record {
        id: super::super::publications::opaque("setup"),
        owner: Owner {
            issuer: "https://accounts.example.test".into(),
            publisher_id: "fixture_owner".into(),
            host_key: "ab".repeat(32),
        },
        folder: Folder::capture(&folder).unwrap(),
        input: Begin {
            organization: "org_fixture".into(),
            workspace: "private-workspace".into(),
            name: "Project".into(),
            repository: None,
            member_ids: vec!["fixture_member".into()],
            role: RepositoryRole::Contributor,
            request_id: "original-request".into(),
            confirm_sharing: true,
        },
        phase: Phase::Creating,
        repository: None,
        publication: None,
    };
    let store = Store::test_store(root.path().join("publications"));
    (root, store, record)
}

#[test]
fn setup_requests_require_fresh_confirmation_and_cannot_supply_authority() {
    let (_, _, record) = fixture();
    let body = serde_json::to_value(&record.input).unwrap();
    assert!(matches!(
        parse(
            "teams.projectSharing.read",
            json!({"workspace":"private-workspace"})
        )
        .unwrap()
        .unwrap(),
        Request::Read {
            organization: None,
            ..
        }
    ));
    assert!(
        parse("teams.projectSharing.begin", body.clone())
            .unwrap()
            .is_ok()
    );
    for key in [
        "owner",
        "path",
        "hostKey",
        "publisherId",
        "phase",
        "publication",
    ] {
        let mut bad = body.clone();
        bad[key] = json!("forged");
        assert!(parse("teams.projectSharing.begin", bad).unwrap().is_err());
    }
    let mut bad = body;
    bad["confirmSharing"] = json!(false);
    assert!(parse("teams.projectSharing.begin", bad).unwrap().is_err());
    assert!(
        parse(
            "teams.projectSharing.resume",
            json!({"setup":record.id,"confirmSharing":false})
        )
        .unwrap()
        .is_err()
    );
    assert!(
        parse(
            "teams.projectSharing.discard",
            json!({"setup":record.id,"confirmDiscard":false})
        )
        .unwrap()
        .is_err()
    );
    for method in ["read", "begin", "resume", "discard"] {
        crate::request_context::with_remote_peer("fixture-peer", || {
            let error = super::super::call(&format!("teams.projectSharing.{method}"), "{}")
                .unwrap()
                .unwrap_err();
            assert_eq!(error.code, "local_only");
        });
    }
}

#[test]
fn unknown_creation_survives_reload_with_original_selection_and_receipt() {
    let (root, store, record) = fixture();
    store
        .project_setups(|rows| {
            rows.push(record.clone());
            Ok(())
        })
        .unwrap();
    let reopened = Store::test_store(root.path().join("publications"));
    let restored = owned(&reopened, &record.owner, &record.id).unwrap();
    assert!(restored == record);
    assert_eq!(dto(&restored)["needsRepositoryChoice"], true);
    assert_eq!(restored.input.request_id, "original-request");
    assert_eq!(restored.input.member_ids, ["fixture_member"]);
    assert!(
        dto(&restored).get("confirmSharing").is_none(),
        "Stored confirmation is not a fresh UI consent"
    );
    let foreign = Owner {
        publisher_id: "another-person".into(),
        ..record.owner.clone()
    };
    assert!(owned(&reopened, &foreign, &record.id).is_err());
    let lease = store.project_setup_lease(&record.id).unwrap();
    assert_eq!(
        reopened.project_setup_lease(&record.id).err().unwrap().code,
        "sharing_busy"
    );
    drop(lease);
    assert!(reopened.project_setup_lease(&record.id).is_ok());
    let raw = std::fs::read_to_string(root.path().join("publications/index.json")).unwrap();
    for forbidden in ["accountSession", "bearer", "accessToken"] {
        assert!(!raw.contains(forbidden));
    }
}

#[test]
fn stale_setup_write_cannot_reopen_a_discarded_uncertain_attempt() {
    let (_, store, record) = fixture();
    store
        .project_setups(|rows| {
            rows.push(record.clone());
            Ok(())
        })
        .unwrap();
    let mut discarded = record.clone();
    discarded.phase = Phase::Discarded;
    save(&store, &record, &discarded).unwrap();
    let mut stale = record.clone();
    stale.phase = Phase::Repository;
    stale.repository = Some("repo_fixture".into());
    assert_eq!(
        save(&store, &record, &stale).unwrap_err().code,
        "sharing_setup_changed"
    );
    assert!(owned(&store, &record.owner, &record.id).unwrap() == discarded);
}

#[test]
fn missing_or_corrupt_setup_index_never_becomes_an_empty_retry_history() {
    let (root, store, record) = fixture();
    store
        .project_setups(|rows| {
            rows.push(record.clone());
            Ok(())
        })
        .unwrap();
    let index = root.path().join("publications/index.json");
    std::fs::write(&index, b"{broken").unwrap();
    assert!(owned(&store, &record.owner, &record.id).is_err());
    std::fs::remove_file(index).unwrap();
    assert!(store.project_setups(|rows| Ok(rows.is_empty())).is_err());
}
