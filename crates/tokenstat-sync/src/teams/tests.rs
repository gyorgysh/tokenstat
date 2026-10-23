// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use tokenstat_identity::teams::{TeamTicket, TeamTicketBinding};

type Reply = Result<(u16, Vec<u8>), TeamError>;
type RecordedRequest = (Method, String, Option<Value>, bool);
pub(super) struct MockWire {
    pub(super) reply: Mutex<std::collections::VecDeque<Reply>>,
    pub(super) requests: Mutex<Vec<RecordedRequest>>,
    retire: Option<Arc<AtomicBool>>,
}
impl TeamWire for MockWire {
    fn send(&self, request: WireRequest) -> Reply {
        self.requests.lock().unwrap().push((
            request.method,
            request.url.to_string(),
            request.body.map(|b| serde_json::from_slice(&b).unwrap()),
            request.authorization.is_sensitive(),
        ));
        if let Some(retired) = &self.retire {
            retired.store(true, Ordering::Release);
        }
        self.reply
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(Err(TeamError::Network))
    }
}
fn fixture(reply: Reply, retire_on_send: bool) -> (TeamClient, Arc<MockWire>) {
    fixture_replies(vec![reply], retire_on_send)
}
pub(super) fn fixture_replies(
    replies: Vec<Reply>,
    retire_on_send: bool,
) -> (TeamClient, Arc<MockWire>) {
    let captured = Authentication {
        origin: "https://accounts.example.test".into(),
        bearer: Zeroizing::new("tsk_abcdef0123456789abcdef01_publicfixturesecret".into()),
    };
    let current_auth = captured.clone();
    let retired = Arc::new(AtomicBool::new(false));
    let flag = retired.clone();
    let wire = Arc::new(MockWire {
        reply: Mutex::new(replies.into()),
        requests: Mutex::new(Vec::new()),
        retire: retire_on_send.then_some(retired),
    });
    let client = TeamClient {
        authentication: Arc::new(captured),
        wire: wire.clone(),
        current: Arc::new(move || {
            if flag.load(Ordering::Acquire) {
                Err(TeamError::AccountChanged)
            } else {
                Ok(current_auth.clone())
            }
        }),
    };
    (client, wire)
}
pub(super) fn response(body: Value) -> Reply {
    Ok((200, serde_json::to_vec(&body).unwrap()))
}
fn capabilities() -> Value {
    json!({"enabled":true,"version":1,"actorId":"fixture-member","scopes":["teams:read","teams:manage","teams:connect"],"authorizationRequired":false,"authorizationPath":"/settings/teams/devices/abcdef0123","deviceKey":"a".repeat(64),"ticketLifetimeSeconds":60})
}

#[test]
fn move_catch_up_collects_every_page_and_rejects_nonadvancing_cursors() {
    let first = format!("repo_{:032x}", 1);
    let last = format!("repo_{:032x}", 1000);
    let tail = format!("repo_{:032x}", 1001);
    let rows: Vec<Value> = (1..=1000)
        .map(|i| json!({"repositoryId": format!("repo_{i:032x}"), "sequence": 1}))
        .collect();
    let (client, wire) = fixture_replies(
        vec![
            response(json!({"moves": rows, "nextCursor": last})),
            response(json!({"moves": [{"repositoryId": tail, "sequence": 2}], "nextCursor": null})),
        ],
        false,
    );
    let result = client.my_moves().unwrap();
    assert_eq!(result["moves"].as_array().unwrap().len(), 1001);
    assert_eq!(result["moves"][1000]["repositoryId"], tail);
    assert!(
        wire.requests.lock().unwrap()[1]
            .1
            .ends_with(&format!("?after={last}"))
    );
    // Older account servers omit the cursor on their single page.
    let (client, _) = fixture(
        response(json!({"moves": [{"repositoryId": first, "sequence": 1}]})),
        false,
    );
    assert_eq!(
        client.my_moves().unwrap()["moves"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    for page in [
        json!({"moves": [], "nextCursor": first}),
        json!({"moves": [{"repositoryId": first, "sequence": 1}], "nextCursor": "../private"}),
        json!({"moves": [{"repositoryId": first, "sequence": 0}]}),
    ] {
        let (client, _) = fixture(response(page), false);
        assert_eq!(client.my_moves(), Err(TeamError::InvalidResponse));
    }
    let (client, _) = fixture_replies(
        vec![
            response(
                json!({"moves": [{"repositoryId": first, "sequence": 1}], "nextCursor": first}),
            ),
            response(
                json!({"moves": [{"repositoryId": first, "sequence": 2}], "nextCursor": first}),
            ),
        ],
        false,
    );
    assert_eq!(client.my_moves(), Err(TeamError::InvalidResponse));
}

#[test]
fn move_catch_up_bounds_requests_and_retains_only_protocol_metadata() {
    let replies = (1..=129)
        .map(|index| {
            let id = format!("repo_{index:032x}");
            response(json!({
                "moves": [{"repositoryId": id, "sequence": 1}],
                "nextCursor": if index == 129 { Value::Null } else { json!(id) },
            }))
        })
        .collect();
    let (client, wire) = fixture_replies(replies, false);
    assert_eq!(client.my_moves(), Err(TeamError::InvalidResponse));
    assert!(wire.requests.lock().unwrap().len() < 129);

    let id = format!("repo_{:032x}", 1);
    let (client, _) = fixture(
        response(json!({"moves": [{
            "repositoryId": id, "sequence": 42, "extra": "x".repeat(256 * 1024)
        }]})),
        false,
    );
    assert_eq!(
        client.my_moves().unwrap(),
        json!({"moves": [{"repositoryId": id, "sequence": 42}]}),
        "large unknown fields must not accumulate across pages"
    );
}

#[test]
fn host_execution_proves_the_actual_identity_for_one_exact_reviewed_write() {
    let v: Value = serde_json::from_str(include_str!(
        "../../../../fixtures/teams/host-proof-v1.json"
    ))
    .unwrap();
    let identity = tokenstat_identity::MachineIdentity::from_secret([7; 32]);
    let mut caps = capabilities();
    caps["actorId"] = json!("fixture-owner");
    caps["deviceKey"] = json!(identity.public_key_hex());
    caps["features"] = json!(["host-execution-proof-v1"]);
    caps["authorizationPath"] = json!("/settings/teams/devices/abcdef0123456789abcdef01");
    let input: SetExecutionGrant = serde_json::from_value(v["operation"].clone()).unwrap();
    let org = v["binding"]["organization"].as_str().unwrap();
    let checkout = v["binding"]["checkout"].as_str().unwrap();
    let (client, wire) = fixture_replies(
        vec![
            response(caps.clone()),
            response(v["challenge"].clone()),
            response(json!({"allowed":true,"revision":2})),
        ],
        false,
    );
    let result = super::host_execution::grant_for_identity(
        &client,
        org,
        checkout,
        &input,
        &identity,
        "fixture-host",
        || v["nowMs"].as_i64().unwrap(),
    )
    .unwrap();
    assert!(result.allowed);
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(requests[1].1.ends_with("/execution/challenge"));
    assert_eq!(requests[1].2.as_ref().unwrap(), &v["operation"]);
    assert_eq!(requests[2].0, Method::PUT);
    assert_eq!(requests[2].2.as_ref().unwrap()["hostProof"], v["proof"]);
    assert!(requests.iter().all(|request| request.3));
    drop(requests);

    let mut altered_input = input.clone();
    altered_input.user_id = "fixture-other".into();
    let (client, wire) = fixture_replies(
        vec![response(caps.clone()), response(v["challenge"].clone())],
        false,
    );
    assert_eq!(
        super::host_execution::grant_for_identity(
            &client,
            org,
            checkout,
            &altered_input,
            &identity,
            "fixture-host",
            || v["nowMs"].as_i64().unwrap()
        )
        .unwrap_err(),
        TeamError::InvalidResponse
    );
    assert_eq!(
        wire.requests.lock().unwrap().len(),
        2,
        "a substituted operation never sends a permission write"
    );

    let (client, wire) = fixture(response(caps.clone()), true);
    assert_eq!(
        super::host_execution::grant_for_identity(
            &client,
            org,
            checkout,
            &input,
            &identity,
            "fixture-host",
            || v["nowMs"].as_i64().unwrap()
        )
        .unwrap_err(),
        TeamError::AccountChanged
    );
    assert_eq!(wire.requests.lock().unwrap().len(), 1);

    caps["features"] = json!([]);
    let (client, wire) = fixture(response(caps), false);
    assert_eq!(
        super::host_execution::grant_for_identity(
            &client,
            org,
            checkout,
            &input,
            &identity,
            "fixture-host",
            || v["nowMs"].as_i64().unwrap()
        )
        .unwrap_err(),
        TeamError::Unsupported
    );
    assert_eq!(wire.requests.lock().unwrap().len(), 1);

    let (client, wire) = fixture(response(json!({"allowed":false,"revision":2})), false);
    let mut revoke = input;
    revoke.allow = false;
    revoke.machine_id = None;
    revoke.acknowledge_host_access = None;
    assert!(
        !client
            .set_execution_grant(org, checkout, &revoke)
            .unwrap()
            .allowed
    );
    let requests = wire.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        1,
        "revocation does not need a challenge or consent lookup"
    );
    assert!(requests[0].2.as_ref().unwrap().get("hostProof").is_none());
}

#[test]
fn member_policy_requires_a_bound_physical_host_proof_and_server_support() {
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use sha2::{Digest, Sha256};
    let v: Value = serde_json::from_str(include_str!(
        "../../../../fixtures/teams/host-proof-v1.json"
    ))
    .unwrap();
    let identity = tokenstat_identity::MachineIdentity::from_secret([7; 32]);
    let input = SetExecutionPolicy {
        policy: ExecutionPolicy::Members,
        expected_revision: 1,
        acknowledge_host_access: true,
    };
    let operation = serde_json::to_vec(&("execution.policy", input.policy, 1, true)).unwrap();
    let mut fields: Value = serde_json::from_slice(
        &URL_SAFE_NO_PAD
            .decode(v["challenge"]["context"].as_str().unwrap())
            .unwrap(),
    )
    .unwrap();
    fields[8] = json!(tokenstat_identity::hex(
        Sha256::digest(operation).as_slice()
    ));
    let challenge = json!({"version": 1, "context": URL_SAFE_NO_PAD.encode(serde_json::to_vec(&fields).unwrap())});
    let org = v["binding"]["organization"].as_str().unwrap();
    let checkout = v["binding"]["checkout"].as_str().unwrap();
    let mut caps = capabilities();
    caps["actorId"] = json!("fixture-owner");
    caps["deviceKey"] = json!(identity.public_key_hex());
    caps["features"] = json!(["member-execution-policy-v1"]);
    caps["authorizationPath"] = json!("/settings/teams/devices/abcdef0123456789abcdef01");
    let (client, wire) = fixture_replies(
        vec![
            response(caps.clone()),
            response(challenge.clone()),
            response(json!({"policy":"members","revision":2})),
        ],
        false,
    );
    let reply = super::host_execution::policy_for_identity(
        &client,
        org,
        checkout,
        &input,
        &identity,
        "fixture-host",
        || v["nowMs"].as_i64().unwrap(),
    )
    .unwrap();
    assert_eq!(reply.policy, ExecutionPolicy::Members);
    assert_eq!(reply.revision, 2);
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(requests[1].1.ends_with("/execution/policy/challenge"));
    assert_eq!(requests[1].2, Some(serde_json::to_value(&input).unwrap()));
    assert_eq!(requests[2].0, Method::PUT);
    assert!(requests[2].1.ends_with("/execution/policy"));
    assert!(requests[2].2.as_ref().unwrap().get("hostProof").is_some());
    assert!(requests.iter().all(|request| request.3));
    drop(requests);
    let mut substituted = input.clone();
    substituted.policy = ExecutionPolicy::Devices;
    let (client, wire) = fixture_replies(vec![response(caps.clone()), response(challenge)], false);
    assert_eq!(
        super::host_execution::policy_for_identity(
            &client,
            org,
            checkout,
            &substituted,
            &identity,
            "fixture-host",
            || v["nowMs"].as_i64().unwrap()
        )
        .unwrap_err(),
        TeamError::InvalidResponse
    );
    assert_eq!(
        wire.requests.lock().unwrap().len(),
        2,
        "a substituted policy must never send a write"
    );
    caps["features"] = json!(["host-execution-proof-v1"]);
    let (client, wire) = fixture(response(caps), false);
    assert_eq!(
        super::host_execution::policy_for_identity(
            &client,
            org,
            checkout,
            &input,
            &identity,
            "fixture-host",
            || 0
        )
        .unwrap_err(),
        TeamError::Unsupported
    );
    assert_eq!(wire.requests.lock().unwrap().len(), 1);
    for (revision, acknowledged) in [(0, true), (9_007_199_254_740_992, true), (1, false)] {
        let bad = SetExecutionPolicy {
            expected_revision: revision,
            acknowledge_host_access: acknowledged,
            ..input.clone()
        };
        let (client, wire) = fixture_replies(vec![], false);
        assert_eq!(
            super::host_execution::policy_for_identity(
                &client,
                org,
                checkout,
                &bad,
                &identity,
                "fixture-host",
                || 0
            )
            .unwrap_err(),
            TeamError::InvalidRequest
        );
        assert!(wire.requests.lock().unwrap().is_empty());
    }
    let legacy: ExecutionGrants =
        serde_json::from_value(json!({"grants":[],"revision":1})).unwrap();
    assert_eq!(legacy.policy, ExecutionPolicy::Devices);
    assert!(!legacy.supports_member_policy);
}

#[test]
fn captures_the_origin_uses_sensitive_headers_and_bounds_pages_and_identifiers() {
    let (client, wire) = fixture(
        response(json!({"organizations":[],"nextOffset":null})),
        false,
    );
    assert!(
        client
            .organizations(Page {
                limit: 0,
                offset: 0
            })
            .is_err()
    );
    assert!(
        client
            .organizations(Page {
                limit: 101,
                offset: 0
            })
            .is_err()
    );
    assert!(
        client
            .organizations(Page {
                limit: 20,
                offset: 10001
            })
            .is_err()
    );
    for id in [
        "..",
        ".",
        "../billing",
        "a/b",
        "a?scope=owner",
        "%2e%2e",
        "\n",
        "",
    ] {
        assert!(client.organization(id).is_err());
    }
    assert_eq!(wire.requests.lock().unwrap().len(), 0);
    assert!(
        client
            .organizations(Page {
                limit: 25,
                offset: 50
            })
            .unwrap()
            .organizations
            .is_empty()
    );
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests[0].0, Method::GET);
    assert_eq!(
        requests[0].1,
        "https://accounts.example.test/api/v1/organizations?limit=25&offset=50"
    );
    assert!(requests[0].2.is_none());
    assert!(requests[0].3);
}
#[test]
fn retires_late_success_refusal_and_transport_failure_after_an_account_change() {
    for reply in [
        response(capabilities()),
        Ok((
            403,
            serde_json::to_vec(&json!({"error":"forbidden","message":"Fixture refusal"})).unwrap(),
        )),
        Err(TeamError::Network),
    ] {
        let (client, wire) = fixture(reply, true);
        assert_eq!(
            client.capabilities().unwrap_err(),
            TeamError::AccountChanged
        );
        assert_eq!(wire.requests.lock().unwrap().len(), 1);
    }
    let (client, wire) = fixture(response(capabilities()), false);
    let client = client.with_retirement_guard(|| Err(TeamError::AccountChanged));
    assert_eq!(
        client.capabilities().unwrap_err(),
        TeamError::AccountChanged
    );
    assert!(wire.requests.lock().unwrap().is_empty());
}
#[test]
fn rejects_unbounded_bodies_and_responses_without_logging_response_content() {
    let (client, wire) = fixture(response(json!({})), false);
    let input = CreateOrganization {
        name: "x".repeat(REQUEST_LIMIT + 1),
        slug: "fixture".into(),
    };
    assert_eq!(
        client.create_organization(&input).unwrap_err(),
        TeamError::InvalidRequest
    );
    assert!(wire.requests.lock().unwrap().is_empty());
    for body in [
        vec![b'x'; RESPONSE_LIMIT + 1],
        b"<html>private server error</html>".to_vec(),
    ] {
        let (client, _) = fixture(Ok((500, body)), false);
        let error = client.capabilities().unwrap_err();
        assert_eq!(error, TeamError::InvalidResponse);
        assert!(!format!("{error:?}").contains("private server"));
    }
}
#[test]
fn keeps_server_refusals_structured_and_hides_malformed_error_text() {
    let (client, _) = fixture(Ok((402, serde_json::to_vec(&json!({"error":"legend_required","message":"Creating an organization requires Legend."})).unwrap())), false);
    assert!(
        matches!(client.capabilities(), Err(TeamError::Rejected { status: 402, code, .. }) if code == "legend_required")
    );
    let (client, _) = fixture(
        Ok((
            403,
            serde_json::to_vec(&json!({"error":"forbidden","message":"unsafe\nfixture"})).unwrap(),
        )),
        false,
    );
    assert!(
        !client
            .capabilities()
            .unwrap_err()
            .to_string()
            .contains("unsafe")
    );
    let (client, _) = fixture(Ok((404, b"not implemented".to_vec())), false);
    assert_eq!(client.capabilities().unwrap_err(), TeamError::Unsupported);
}
#[test]
fn enables_the_interface_only_for_the_complete_authorized_contract() {
    let (client, _) = fixture(response(capabilities()), false);
    let ready = client.capabilities().unwrap();
    assert!(ready.ready());
    assert_eq!(
        client.authorization_url(&ready).unwrap(),
        "https://accounts.example.test/settings/teams/devices/abcdef0123"
    );
    for path in [
        "https://another.example.test/consent",
        "//another.example.test",
        "/settings/teams/devices/../billing",
        "/settings/teams/devices/abc?next=other",
    ] {
        let mut changed = ready.clone();
        changed.authorization_path = Some(path.into());
        assert!(client.authorization_url(&changed).is_err());
    }
    let (client, _) = fixture(response(json!({"enabled":false})), false);
    assert!(!client.capabilities().unwrap().ready());
    let (client, _) = fixture(response(json!({"enabled":true,"version":1})), false);
    assert!(!client.capabilities().unwrap().ready());
    let mut changed = ready;
    changed.scopes.retain(|s| s != "teams:connect");
    assert!(!changed.ready());
}
#[test]
fn mutation_types_serialize_only_approved_metadata_and_preserve_null_for_revocation() {
    let input = ChangeRepositoryAccess {
        role: None,
        expected_revision: 3,
    };
    let (client, wire) = fixture(response(json!({"role":null,"revision":4})), false);
    assert!(
        client
            .repository_access("org_fixture", "repo_fixture", "fixture_member", &input)
            .unwrap()
            .role
            .is_none()
    );
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests[0].0, Method::PUT);
    assert_eq!(
        requests[0].2,
        Some(json!({"role":null,"expectedRevision":3}))
    );
    assert!(
        serde_json::from_value::<CreateOrganization>(
            json!({"name":"Example","slug":"example","path":"private"})
        )
        .is_err()
    );
    assert!(
        serde_json::from_value::<ChangeMemberRole>(json!({"role":"owner","expectedRevision":1}))
            .is_err()
    );
}
fn verified_ticket() -> VerifiedTeamTicket {
    let vector: Value =
        serde_json::from_str(include_str!("../../../../fixtures/teams/ticket-v1.json")).unwrap();
    let keys = TrustedTeamKeys::from_response(
        serde_json::from_value(vector["keys"].clone()).unwrap(),
        "https://accounts.example.test",
    )
    .unwrap();
    let ticket: TeamTicket = serde_json::from_value(vector["ticket"].clone()).unwrap();
    keys.verify(
        &ticket,
        &TeamTicketBinding {
            device_key: &[0xaa; 32],
            host_key: &[0xbb; 32],
            publisher_id: "fixture-owner",
            actor_id: Some("fixture-member"),
        },
        1767225601,
    )
    .unwrap()
}
fn principal() -> Value {
    json!({"principal":{"id":"fixture-member","name":"Example member","handle":"example-member","avatar":null,
    "deviceKey":"a".repeat(64),"organizationId":"org_fixture","repositoryId":"repo_fixture","checkoutId":"checkout_fixture",
    "hostKey":"b".repeat(64),"publisherId":"fixture-owner","shareId":null,"grantId":null,"epoch":3,"capabilities":["read","comment"],"role":"contributor","expiresAt":"2026-01-01T00:01:00.000Z"}})
}
#[test]
fn checks_the_online_principal_against_every_signed_resource_and_peer_binding() {
    let ticket = verified_ticket();
    let (client, wire) = fixture(response(principal()), false);
    assert_eq!(
        client.validate_connection(&ticket).unwrap().person.id,
        "fixture-member"
    );
    let requests = wire.requests.lock().unwrap();
    let request = requests[0].2.as_ref().unwrap();
    assert_eq!(request["actorId"], "fixture-member");
    assert_eq!(request["ticket"], ticket.ticket().wire_value());
    for field in [
        "id",
        "deviceKey",
        "organizationId",
        "repositoryId",
        "checkoutId",
        "hostKey",
        "publisherId",
        "shareId",
        "grantId",
        "expiresAt",
    ] {
        let mut changed = principal();
        changed["principal"][field] = json!("another-fixture");
        let (client, _) = fixture(response(changed), false);
        assert_eq!(
            client.validate_connection(&ticket).unwrap_err(),
            TeamError::InvalidResponse
        );
    }
    for (field, changed) in [
        ("epoch", json!(4)),
        ("role", json!("viewer")),
        ("capabilities", json!(["read", "run"])),
    ] {
        let mut body = principal();
        body["principal"][field] = changed;
        let (client, _) = fixture(response(body), false);
        assert_eq!(
            client.validate_connection(&ticket).unwrap_err(),
            TeamError::InvalidResponse
        );
    }
}

#[test]
fn connects_only_the_requested_checkout_actor_device_and_capabilities() {
    fn replies() -> Vec<Reply> {
        let vector: Value =
            serde_json::from_str(include_str!("../../../../fixtures/teams/ticket-v1.json"))
                .unwrap();
        let mut caps = capabilities();
        caps["features"] = json!(["scoped-connections"]);
        vec![
            response(caps),
            response(json!({"checkout":{
                "id":"checkout_fixture","organizationId":"org_fixture","repositoryId":"repo_fixture","publisherId":"fixture-owner",
                "machineId":"fixture-machine","hostKey":"bb".repeat(32),"revision":2,"createdAt":"2026-01-01T00:00:00Z"
            }})),
            response(vector["keys"].clone()),
            response(
                json!({"ticket":vector["ticket"],"expiresAt":"2026-01-01T00:01:00Z","hostKey":"bb".repeat(32),"capabilities":["read","comment"]}),
            ),
        ]
    }
    let input = RequestTicket {
        organization_id: "org_fixture".into(),
        checkout_id: "checkout_fixture".into(),
        capabilities: vec![TeamCapability::Read, TeamCapability::Comment],
        share_id: None,
    };
    let (client, wire) = fixture_replies(replies(), false);
    let proof = client
        .connection_proof_at(&input, "repo_fixture", &[0xaa; 32], || 1767225601)
        .unwrap();
    assert_eq!(proof.host_key(), &[0xbb; 32]);
    assert_eq!(proof.ticket().claims().sub, "fixture-member");
    assert_eq!(proof.checkout().id, "checkout_fixture");
    assert!(!format!("{proof:?}").contains("fixture-member"));
    let requests = wire.requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    assert!(requests.iter().all(|request| request.3));
    assert!(
        requests[1]
            .1
            .ends_with("/organizations/org_fixture/checkouts/checkout_fixture")
    );
    assert_eq!(
        requests[3].2.as_ref().unwrap()["capabilities"],
        json!(["read", "comment"])
    );
    drop(requests);
    for index in 0..11 {
        let mut values = replies();
        let position = if index < 2 {
            0
        } else if index < 5 {
            1
        } else {
            3
        };
        let (status, body) = values[position].as_mut().unwrap();
        assert_eq!(*status, 200);
        let mut value: Value = serde_json::from_slice(body).unwrap();
        match index {
            0 => value["actorId"] = json!("another-account"),
            1 => value["deviceKey"] = json!("cc".repeat(32)),
            2 => value["checkout"]["repositoryId"] = json!("repo_other"),
            3 => value["checkout"]["publisherId"] = json!("another-publisher"),
            4 => value["checkout"]["revision"] = json!(3),
            5 => value["hostKey"] = json!("cc".repeat(32)),
            6 => value["capabilities"] = json!(["read", "comment", "run"]),
            7 => value["expiresAt"] = json!("2026-01-01T00:02:00Z"),
            8 => {
                let vector: Value =
                    serde_json::from_str(include_str!("../../../../fixtures/teams/ticket-v1.json"))
                        .unwrap();
                value["ticket"] = vector["variants"]["otherCheckout"].clone();
            }
            9 => value["ticket"] = json!("ts-team-v1.invalid.signature"),
            _ => {
                let vector: Value =
                    serde_json::from_str(include_str!("../../../../fixtures/teams/ticket-v1.json"))
                        .unwrap();
                value["ticket"] = vector["variants"]["expanded"].clone();
            }
        }
        *body = serde_json::to_vec(&value).unwrap();
        let (client, _) = fixture_replies(values, false);
        assert_eq!(
            client
                .connection_proof_at(&input, "repo_fixture", &[0xaa; 32], || 1767225601)
                .unwrap_err(),
            TeamError::InvalidResponse,
            "case {index}"
        );
    }
    let (client, _) = fixture_replies(replies(), false);
    assert_eq!(
        client
            .connection_proof_at(&input, "repo_fixture", &[0xaa; 32], || 1767225660)
            .unwrap_err(),
        TeamError::InvalidResponse
    );
    let mut shared = input.clone();
    shared.share_id = Some(format!("share_{}", "a".repeat(32)));
    let (client, _) = fixture_replies(replies(), false);
    assert_eq!(
        client
            .connection_proof_at(&shared, "repo_fixture", &[0xaa; 32], || 1767225601)
            .unwrap_err(),
        TeamError::InvalidResponse
    );
    let (client, wire) = fixture(response(capabilities()), false);
    assert_eq!(
        client
            .connection_proof_at(&input, "repo_fixture", &[0xaa; 32], || 1767225601)
            .unwrap_err(),
        TeamError::Unsupported
    );
    assert_eq!(wire.requests.lock().unwrap().len(), 1);
}
