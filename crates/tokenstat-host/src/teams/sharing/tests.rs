// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
use super::*;
#[test]
fn sharing_requests_are_closed_and_require_an_explicit_current_preview() {
    for field in ["actorId", "hostKey", "path", "publisherId", "peer"] {
        let mut body = json!({"organization":"org_fixture","repository":"repo_fixture","workspace":"private-workspace"});
        body[field] = json!("forged");
        assert!(parse("teams.checkout.preview", body).unwrap().is_err());
    }
    let valid = json!({"organization":"org_fixture","repository":"repo_fixture","workspace":"private-workspace","requestId":"request-one","preview":"ab".repeat(32),"confirmSharing":true});
    assert!(
        parse("teams.checkout.publish", valid.clone())
            .unwrap()
            .is_ok()
    );
    let mut unconfirmed = valid.clone();
    unconfirmed["confirmSharing"] = json!(false);
    assert!(
        parse("teams.checkout.publish", unconfirmed)
            .unwrap()
            .is_err()
    );
    let mut missing = valid;
    missing.as_object_mut().unwrap().remove("preview");
    assert!(parse("teams.checkout.publish", missing).unwrap().is_err());
}
#[test]
fn every_publication_method_refuses_personal_and_team_peers_before_loading_credentials() {
    for method in [
        "teams.checkout.options",
        "teams.checkout.preview",
        "teams.checkout.publish",
        "teams.checkout.list",
        "teams.checkout.withdraw",
    ] {
        crate::request_context::with_remote_peer("fixture-peer", || {
            let error = super::super::call(method, "{}").unwrap().unwrap_err();
            assert_eq!(error.code, "local_only");
        });
    }
}
#[test]
fn only_an_explicit_not_found_ends_sharing_that_was_stopped_elsewhere() {
    let rejected = |status, code: &str| -> Result<(), TeamError> {
        Err(TeamError::Rejected {
            status,
            code: code.into(),
            message: String::new(),
        })
    };
    assert!(stopped_elsewhere(&rejected(404, "not_found")));
    assert!(!stopped_elsewhere(&rejected(404, "route_missing")));
    assert!(!stopped_elsewhere(&rejected(403, "not_found")));
    assert!(!stopped_elsewhere(&rejected(503, "unavailable")));
    assert!(!stopped_elsewhere::<()>(&Err(TeamError::InvalidResponse)));
    assert!(!stopped_elsewhere(&Ok(())));
}
