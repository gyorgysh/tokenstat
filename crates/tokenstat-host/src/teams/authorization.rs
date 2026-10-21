// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{api_error, client};
use crate::{account_session::AccountSnapshot, error::DispatchError};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tokenstat_identity::{
    PublicKey, hex,
    teams::{TeamTicket, TeamTicketBinding, TrustedTeamKeys, VerifiedTeamTicket},
};
use tokenstat_remote::tunnel::TeamChannelHandle;
use tokenstat_sync::teams::{TeamClient, TeamPrincipal};

#[derive(Clone)]
pub(crate) struct AuthorizedTeamPrincipal {
    value: TeamPrincipal,
    deadline: Instant,
    issuer: String,
    #[cfg(feature = "local-host")]
    client: Option<TeamClient>,
}
impl AuthorizedTeamPrincipal {
    pub(super) fn issuer(&self) -> &str {
        &self.issuer
    }
    #[cfg(feature = "local-host")]
    pub(super) fn account_client(&self) -> Result<&TeamClient, DispatchError> {
        self.ensure_live()?;
        let client = self.client.as_ref().ok_or_else(expired)?;
        client.ensure_current().map_err(api_error)?;
        Ok(client)
    }
    pub(crate) fn value(&self) -> &TeamPrincipal {
        &self.value
    }
    pub(crate) fn ensure_live(&self) -> Result<(), DispatchError> {
        if Instant::now() >= self.deadline {
            return Err(expired());
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct Time {
    wall: u64,
    monotonic: Instant,
}
impl Time {
    fn now() -> Self {
        Self {
            wall: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |value| value.as_secs()),
            monotonic: Instant::now(),
        }
    }
}
fn expired() -> DispatchError {
    DispatchError::new(
        "team_access_expired",
        "Team access expired or changed. Connect again.",
    )
}

struct Gate {
    keys: TrustedTeamKeys,
    device: PublicKey,
    host: PublicKey,
    publisher: String,
    previous: VerifiedTeamTicket,
    deadline: Instant,
    retired: bool,
}
impl Gate {
    fn new(
        keys: TrustedTeamKeys,
        device: PublicKey,
        host: PublicKey,
        publisher: String,
        ticket: &TeamTicket,
        now: Time,
    ) -> Result<Self, DispatchError> {
        let previous = keys
            .verify(
                ticket,
                &TeamTicketBinding {
                    device_key: &device,
                    host_key: &host,
                    publisher_id: &publisher,
                    actor_id: None,
                },
                now.wall,
            )
            .map_err(|_| expired())?;
        let deadline =
            now.monotonic + std::time::Duration::from_secs(previous.lease_seconds(now.wall));
        Ok(Self {
            keys,
            device,
            host,
            publisher,
            previous,
            deadline,
            retired: false,
        })
    }
    fn authorize(
        &mut self,
        ticket: &TeamTicket,
        clock: impl Fn() -> Time,
        online: impl FnOnce(&VerifiedTeamTicket) -> Result<TeamPrincipal, DispatchError>,
    ) -> Result<AuthorizedTeamPrincipal, DispatchError> {
        let result = self.check(ticket, clock, online);
        if result.is_err() {
            self.retired = true;
        }
        result
    }
    fn check(
        &mut self,
        ticket: &TeamTicket,
        clock: impl Fn() -> Time,
        online: impl FnOnce(&VerifiedTeamTicket) -> Result<TeamPrincipal, DispatchError>,
    ) -> Result<AuthorizedTeamPrincipal, DispatchError> {
        let start = clock();
        if self.retired || start.monotonic >= self.deadline {
            return Err(expired());
        }
        let verified = self
            .keys
            .verify(
                ticket,
                &TeamTicketBinding {
                    device_key: &self.device,
                    host_key: &self.host,
                    publisher_id: &self.publisher,
                    actor_id: None,
                },
                start.wall,
            )
            .map_err(|_| expired())?;
        let next = verified.claims();
        let prior = self.previous.claims();
        // Renewal refreshes authority for the same connection; it cannot
        // select another person, device, repository, chat or capability set.
        if next.sub != prior.sub
            || next.device != prior.device
            || next.token != prior.token
            || next.consent != prior.consent
            || next.org != prior.org
            || next.repository != prior.repository
            || next.checkout != prior.checkout
            || next.host != prior.host
            || next.publisher != prior.publisher
            || next.share != prior.share
            || next.share_revision != prior.share_revision
            || next.grant != prior.grant
            || next.cap != prior.cap
            || next.iat < prior.iat
            || next.exp < prior.exp
            || next.epoch < prior.epoch
            || next.revision < prior.revision
        {
            return Err(expired());
        }
        let deadline = if ticket.wire_value() == self.previous.ticket().wire_value() {
            self.deadline
        } else {
            start.monotonic + std::time::Duration::from_secs(verified.lease_seconds(start.wall))
        };
        let principal = online(&verified)?;
        let end = clock();
        if end.monotonic >= deadline || end.wall >= next.exp {
            return Err(expired());
        }
        let issuer = next.iss.clone();
        self.previous = verified;
        self.deadline = deadline;
        Ok(AuthorizedTeamPrincipal {
            value: principal,
            deadline,
            issuer,
            #[cfg(feature = "local-host")]
            client: None,
        })
    }
}

pub(super) struct Authorization {
    client: TeamClient,
    channel: TeamChannelHandle,
    gate: Gate,
}
impl Authorization {
    pub(super) fn ensure_live(&self) -> Result<(), DispatchError> {
        self.channel.ticket().map_err(|_| expired())?;
        self.client.ensure_current().map_err(api_error)?;
        let now = Time::now();
        if self.gate.retired
            || now.monotonic >= self.gate.deadline
            || now.wall >= self.gate.previous.claims().exp
        {
            return Err(expired());
        }
        Ok(())
    }
    pub(super) fn capture(
        owner: &AccountSnapshot,
        device: PublicKey,
        host: PublicKey,
        channel: TeamChannelHandle,
    ) -> Result<Self, DispatchError> {
        let client = client(owner)?;
        let capabilities = client.capabilities().map_err(api_error)?;
        if !capabilities.ready() || capabilities.device_key.as_deref() != Some(hex(&host).as_str())
        {
            return Err(expired());
        }
        let publisher = capabilities.actor_id.ok_or_else(expired)?;
        // Keys come from the host's captured account origin, never a URL or
        // account id supplied by the connecting person or relay.
        let keys = client.verification_keys().map_err(api_error)?;
        let ticket = channel.ticket().map_err(|_| expired())?;
        let gate = Gate::new(keys, device, host, publisher, &ticket, Time::now())?;
        Ok(Self {
            client,
            channel,
            gate,
        })
    }
    pub(super) fn authorize(&mut self) -> Result<AuthorizedTeamPrincipal, DispatchError> {
        let ticket = self.channel.ticket().map_err(|_| expired())?;
        let principal = self.gate.authorize(&ticket, Time::now, |verified| {
            self.client.validate_connection(verified).map_err(api_error)
        })?;
        // A channel or login retired during the authority round trip cannot
        // publish a late response into another account or connection.
        self.channel.ticket().map_err(|_| expired())?;
        self.client.ensure_current().map_err(api_error)?;
        #[cfg(feature = "local-host")]
        let principal = AuthorizedTeamPrincipal {
            client: Some(self.client.clone()),
            ..principal
        };
        Ok(principal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::{cell::Cell, sync::Mutex, time::Duration};
    use tokenstat_identity::teams::TeamKeyResponse;

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../../../../fixtures/teams/ticket-v1.json")).unwrap()
    }
    fn ticket(value: &Value) -> TeamTicket {
        TeamTicket::try_from(value.as_str().unwrap().to_string()).unwrap()
    }
    fn keys() -> TrustedTeamKeys {
        let response: TeamKeyResponse = serde_json::from_value(fixture()["keys"].clone()).unwrap();
        TrustedTeamKeys::from_response(response, "https://accounts.example.test").unwrap()
    }
    fn principal(ticket: &VerifiedTeamTicket) -> TeamPrincipal {
        let c = ticket.claims();
        serde_json::from_value(json!({"id":c.sub,"name":"Example member","handle":"example-member","avatar":null,
            "deviceKey":c.device,"organizationId":c.org,"repositoryId":c.repository,"checkoutId":c.checkout,"hostKey":c.host,
            "publisherId":c.publisher,"shareId":c.share,"grantId":c.grant,"epoch":c.epoch,"capabilities":c.cap,"role":"contributor",
            "expiresAt":jiff::Timestamp::from_second(c.exp as i64).unwrap().to_string()})).unwrap()
    }
    fn gate(now: Time) -> Gate {
        Gate::new(
            keys(),
            [0xaa; 32],
            [0xbb; 32],
            "fixture-owner".into(),
            &ticket(&fixture()["ticket"]),
            now,
        )
        .unwrap()
    }

    #[test]
    fn authority_is_noise_bound_and_is_rechecked_for_each_request() {
        let f = fixture();
        let now = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
        };
        assert!(
            Gate::new(
                keys(),
                [0x01; 32],
                [0xbb; 32],
                "fixture-owner".into(),
                &ticket(&f["ticket"]),
                now
            )
            .is_err()
        );
        assert!(
            Gate::new(
                keys(),
                [0xaa; 32],
                [0xbb; 32],
                "another-owner".into(),
                &ticket(&f["ticket"]),
                now
            )
            .is_err()
        );
        let mut gate = gate(now);
        let calls = Cell::new(0);
        for _ in 0..2 {
            let authorized = gate
                .authorize(
                    &ticket(&f["ticket"]),
                    || now,
                    |ticket| {
                        calls.set(calls.get() + 1);
                        Ok(principal(ticket))
                    },
                )
                .unwrap();
            assert_eq!(authorized.value().person.id, "fixture-member");
        }
        assert_eq!(calls.get(), 2);
        assert!(
            gate.authorize(
                &ticket(&f["ticket"]),
                || now,
                |_| Err(DispatchError::new("team_access_changed", "Access removed."))
            )
            .is_err()
        );
        assert!(
            gate.authorize(
                &ticket(&f["ticket"]),
                || now,
                |_| panic!("a refused connection must stay retired")
            )
            .is_err()
        );
    }
    #[test]
    fn renewal_cannot_expand_capabilities_retarget_or_regress_authority() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
        };
        let later = Time {
            wall: start.wall + 20,
            monotonic: start.monotonic + Duration::from_secs(20),
        };
        for invalid in ["expanded", "otherCheckout"] {
            let mut gate = gate(start);
            assert!(
                gate.authorize(
                    &ticket(&f["variants"][invalid]),
                    || later,
                    |_| panic!("scope change reached account validation")
                )
                .is_err()
            );
        }
        let mut gate = gate(start);
        gate.authorize(
            &ticket(&f["variants"]["renewed"]),
            || later,
            |ticket| Ok(principal(ticket)),
        )
        .unwrap();
        assert!(
            gate.authorize(
                &ticket(&f["ticket"]),
                || later,
                |_| panic!("old ticket was revived after renewal")
            )
            .is_err()
        );
    }
    #[test]
    fn clock_rollback_and_slow_validation_cannot_extend_a_lease_or_revive_it() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
        };
        let rollback = Time {
            wall: start.wall - 1000,
            monotonic: start.monotonic + Duration::from_secs(60),
        };
        assert!(
            gate(start)
                .authorize(
                    &ticket(&f["variants"]["renewed"]),
                    || rollback,
                    |_| panic!("expired connection renewed")
                )
                .is_err()
        );
        let clock = Mutex::new(start);
        let result = gate(start).authorize(
            &ticket(&f["ticket"]),
            || *clock.lock().unwrap(),
            |ticket| {
                *clock.lock().unwrap() = Time {
                    wall: start.wall + 60,
                    monotonic: start.monotonic + Duration::from_secs(60),
                };
                Ok(principal(ticket))
            },
        );
        assert!(
            result.is_err(),
            "a validation finishing after expiry must not expose a principal"
        );
    }
    #[test]
    fn a_new_valid_execution_grant_cannot_revive_an_admitted_connection() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
        };
        let mut gate = Gate::new(
            keys(),
            [0xaa; 32],
            [0xbb; 32],
            "fixture-owner".into(),
            &ticket(&f["variants"]["run"]),
            start,
        )
        .unwrap();
        let authorized = gate
            .authorize(
                &ticket(&f["variants"]["run"]),
                || start,
                |ticket| Ok(principal(ticket)),
            )
            .unwrap();
        assert_eq!(
            authorized.value().grant_id.as_deref(),
            Some(format!("grant_{}", "e".repeat(32)).as_str())
        );
        let later = Time {
            wall: start.wall + 20,
            monotonic: start.monotonic + Duration::from_secs(20),
        };
        assert!(
            gate.authorize(
                &ticket(&f["variants"]["regranted"]),
                || later,
                |_| panic!("replacement grant reached online validation on an old connection")
            )
            .is_err()
        );
        assert!(
            gate.authorize(
                &ticket(&f["variants"]["run"]),
                || start,
                |_| panic!("retired connection accepted its old grant")
            )
            .is_err()
        );
    }
    #[test]
    fn scoped_requests_never_enter_personal_dispatch_or_archive_fast_paths() {
        let f = fixture();
        let now = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
        };
        let authorized = gate(now)
            .authorize(
                &ticket(&f["ticket"]),
                || now,
                |ticket| Ok(principal(ticket)),
            )
            .unwrap();
        let session = Mutex::new(crate::Session::open_client(None).unwrap());
        let held = session.lock().unwrap();
        let (done, result) = std::sync::mpsc::channel();
        std::thread::scope(|threads| {
            let session = &session;
            threads.spawn(move || {
                crate::request_context::with_team_principal(authorized, || {
                    assert_eq!(
                        crate::request_context::remote_peer().as_deref(),
                        Some("aa".repeat(32).as_str())
                    );
                    crate::request_context::with_remote_peer("personal-pair", || {
                        assert_eq!(crate::request_context::remote_peer(), Some("aa".repeat(32)));
                        assert!(crate::request_context::refuse_remote("owner action").is_err());
                    });
                    for method in [
                        "scan",
                        "totals",
                        "workspace.list",
                        "chat.list",
                        "chat.sharing.info",
                        "chat.sharing.stopLocal",
                        "pty.spawn",
                        "vault.get",
                        "teams.directory",
                        "remote.call",
                    ] {
                        let response: Value = serde_json::from_str(&crate::server::respond(
                            &json!({"id":1,"method":method,"params":{}}).to_string(),
                            session,
                        ))
                        .unwrap();
                        assert_eq!(
                            response["error"]["code"], "team_method_required",
                            "{method}"
                        );
                    }
                    let value: Value = serde_json::from_str(&crate::server::respond(
                        r#"{"id":2,"method":"team.protocol","params":{}}"#,
                        session,
                    ))
                    .unwrap();
                    assert_eq!(value["result"]["checkoutId"], "checkout_fixture");
                    assert_eq!(value["result"]["sharedChats"], cfg!(feature = "local-host"));
                    let forged: Value = serde_json::from_str(&crate::server::respond(
                        r#"{"id":3,"method":"team.protocol","params":{"actorId":"another-user"}}"#,
                        session,
                    ))
                    .unwrap();
                    assert_eq!(forged["error"]["code"], "invalid_request");
                });
                assert!(crate::request_context::team_principal().is_none());
                assert!(crate::request_context::remote_peer().is_none());
                done.send(()).unwrap();
            });
            let completed = result.recv_timeout(Duration::from_secs(3));
            // Release even on a regression so a failed test cannot deadlock
            // the suite while the worker is waiting for the personal lock.
            drop(held);
            assert!(
                completed.is_ok(),
                "Team dispatch waited for the personal archive lock"
            );
        });
        let local: Value = serde_json::from_str(
            &crate::dispatch::call_sessionless("team.protocol", "{}").unwrap(),
        )
        .unwrap();
        assert_eq!(local["error"]["code"], "team_context_required");
    }
}
