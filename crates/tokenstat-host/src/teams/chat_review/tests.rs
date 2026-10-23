// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;

fn fixture() -> (tempfile::TempDir, Store, Record) {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("Project");
    std::fs::create_dir(&folder).unwrap();
    let row = Record {
        id: super::super::publications::opaque("review"),
        owner: Owner {
            issuer: "https://accounts.example.test".into(),
            publisher_id: "fixture_owner".into(),
            host_key: "ab".repeat(32),
        },
        target: Target {
            organization: "org_fixture".into(),
            repository: "repo_fixture".into(),
            checkout: "checkout_fixture".into(),
        },
        workspace: "private-workspace".into(),
        folder: Folder::capture(&folder).unwrap(),
        request_id: "selection-request".into(),
        items: vec![Item {
            conversation: "original-chat".into(),
            created_at_ms: 1,
            request_id: "original-publication-request".into(),
            review: Some("ab".repeat(32)),
            publication: None,
            skipped: false,
        }],
        discarded: false,
    };
    let store = Store::test_store(root.path().join("publications"));
    (root, store, row)
}

#[test]
fn a_saved_selection_reopens_with_its_original_attempt_and_is_account_bound() {
    let (root, store, row) = fixture();
    store
        .chat_reviews(|rows| {
            rows.push(row.clone());
            Ok(())
        })
        .unwrap();
    let reopened = Store::test_store(root.path().join("publications"));
    let restored = owned(&reopened, &row.owner, &row.id).unwrap();
    assert!(restored == row);
    let encoded = serde_json::to_string(&restored).unwrap();
    assert!(!encoded.contains("confirmHistory"));
    assert!(!encoded.contains("events"));
    assert!(!encoded.contains("text"));
    let mut other = row.owner.clone();
    other.publisher_id = "other_person".into();
    assert!(owned(&reopened, &other, &row.id).is_err());
    other = row.owner.clone();
    other.host_key = "cd".repeat(32);
    assert!(owned(&reopened, &other, &row.id).is_err());
    let _lease = reopened.chat_review_lease(&row.id).unwrap();
    assert!(store.chat_review_lease(&row.id).is_err());
    let mut skipped = restored.clone();
    skipped.items[0].skipped = true;
    save(&reopened, &restored, &skipped).unwrap();
    assert!(
        save(&store, &restored, &restored).is_err(),
        "A stale screen cannot restore an item skipped on another screen"
    );
    let mut discarded = skipped.clone();
    discarded.discarded = true;
    save(&reopened, &skipped, &discarded).unwrap();
    assert!(save(&store, &skipped, &skipped).is_err());
    assert!(!owned(&store, &row.owner, &row.id).unwrap().pending());
}

#[test]
fn bulk_review_requires_each_fresh_consent_and_rejects_supplied_authority() {
    let (_, _, row) = fixture();
    let fields = json!({"selection":row.id,"conversation":"original-chat","preview":"ab".repeat(32),"confirmHistory":true});
    assert!(
        parse("teams.chatSharing.publish", fields.clone())
            .unwrap()
            .is_ok()
    );
    let mut no_consent = fields.clone();
    no_consent["confirmHistory"] = json!(false);
    assert!(
        parse("teams.chatSharing.publish", no_consent)
            .unwrap()
            .is_err()
    );
    for key in [
        "owner",
        "requestId",
        "path",
        "hostKey",
        "publication",
        "role",
    ] {
        let mut forged = fields.clone();
        forged[key] = json!("supplied");
        assert!(parse("teams.chatSharing.publish", forged).unwrap().is_err());
    }
    for method in ["read", "begin", "preview", "publish", "skip", "discard"] {
        crate::request_context::with_remote_peer("fixture-peer", || {
            let error = super::super::call(&format!("teams.chatSharing.{method}"), "{}")
                .unwrap()
                .unwrap_err();
            assert_eq!(error.code, "local_only");
        });
    }
    let mut duplicate = row.clone();
    duplicate.id = super::super::publications::opaque("review");
    assert!(validate(&[row.clone(), duplicate]).is_err());
    let mut oversized = row.clone();
    oversized.items = vec![row.items[0].clone(); MAX_CHATS + 1];
    assert!(validate(&[oversized]).is_err());
    let mut corrupt = row;
    corrupt.items[0].publication = Some(Receipt {
        id: "share_invalid".into(),
        revision: 1,
    });
    assert!(validate(&[corrupt]).is_err());
}
