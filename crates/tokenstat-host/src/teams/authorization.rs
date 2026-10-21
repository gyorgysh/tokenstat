// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{api_error, client};
use crate::lease_clock::{Deadline, Stamp};
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
    continuous_deadline: Deadline,
    expires_at: u64,
    issuer: String,
    #[cfg(feature = "local-host")]
    ticket: Option<VerifiedTeamTicket>,
    #[cfg(feature = "local-host")]
    client: Option<TeamClient>,
}
impl AuthorizedTeamPrincipal {
    #[cfg(feature = "local-host")]
    pub(super) fn guardian(
        client: &TeamClient,
        ticket: &TeamTicket,
        device: PublicKey,
        publisher: String,
    ) -> Result<Self, DispatchError> {
        let host = tokenstat_identity::MachineIdentity::load()
            .map_err(|_| expired())?
            .ok_or_else(expired)?
            .public_key();
        let keys = client.verification_keys().map_err(api_error)?;
        let mut gate = Gate::new(keys, device, host, publisher, ticket, Time::now())?;
        let principal = gate.authorize(ticket, Time::now, |proof| {
            client.validate_connection(proof).map_err(api_error)
        })?;
        client.ensure_current().map_err(api_error)?;
        let principal = Self {
            client: Some(client.clone()),
            ..principal
        };
        principal.run_ticket()?;
        Ok(principal)
    }
    pub(super) fn loopback(
        client: &TeamClient,
        proof: &tokenstat_sync::teams::TeamConnectionProof,
        device: &PublicKey,
        deadline: Instant,
        original_lease: Deadline,
    ) -> Result<Self, DispatchError> {
        let claims = proof.ticket().claims();
        let start = Time::now();
        let deadline = local_deadline(proof.ticket(), deadline, start);
        let continuous_deadline = original_lease.clipped(
            Deadline::at(
                start.stamp().ok_or_else(expired)?,
                deadline.saturating_duration_since(start.monotonic),
            )
            .ok_or_else(expired)?,
        );
        if proof.host_key() != device
            || claims.device != hex(device)
            || claims.host != hex(device)
            || claims.sub != claims.publisher
            || claims.iss != client.origin()
            || start.monotonic >= deadline
            || continuous_deadline
                .remaining_at(start.stamp().ok_or_else(expired)?)
                .is_none()
        {
            return Err(expired());
        }
        // Even the physical publisher needs current repository membership,
        // device consent and the exact signed share scope on every call.
        let value = client
            .validate_connection(proof.ticket())
            .map_err(|error| {
                if matches!(&error, tokenstat_sync::teams::TeamError::Rejected { code, .. }
                if matches!(code.as_str(), "team_access_changed" | "invalid_team_ticket"))
                {
                    expired()
                } else {
                    api_error(error)
                }
            })?;
        client.ensure_current().map_err(api_error)?;
        let end = Time::now();
        if end.monotonic >= deadline
            || end.wall >= claims.exp
            || continuous_deadline
                .remaining_at(end.stamp().ok_or_else(expired)?)
                .is_none()
        {
            return Err(expired());
        }
        Ok(Self {
            value,
            deadline,
            continuous_deadline,
            expires_at: claims.exp,
            issuer: claims.iss.clone(),
            #[cfg(feature = "local-host")]
            ticket: Some(proof.ticket().clone()),
            #[cfg(feature = "local-host")]
            client: Some(client.clone()),
        })
    }
    pub(crate) fn issuer(&self) -> &str {
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
    /// Only the original verified Run proof can admit host-owned authority.
    /// A directory principal or caller-supplied actor/grant is insufficient.
    #[cfg(feature = "local-host")]
    pub(crate) fn run_ticket(&self) -> Result<&VerifiedTeamTicket, DispatchError> {
        self.ensure_account_current()?;
        let ticket = self.ticket.as_ref().ok_or_else(expired)?;
        let c = ticket.claims();
        let p = &self.value;
        if !p
            .capabilities
            .contains(&tokenstat_sync::teams::TeamCapability::Run)
            || !c
                .cap
                .contains(&tokenstat_identity::teams::TeamCapability::Run)
            || c.iss != self.issuer
            || c.sub != p.person.id
            || c.device != p.device_key
            || c.org != p.organization_id
            || c.repository != p.repository_id
            || c.checkout != p.checkout_id
            || c.host != p.host_key
            || c.publisher != p.publisher_id
            || c.share != p.share_id
            || c.grant != p.grant_id
            || c.share.is_none()
            || c.grant.is_none()
        {
            return Err(expired());
        }
        Ok(ticket)
    }
    pub(crate) fn ensure_live(&self) -> Result<(), DispatchError> {
        self.ensure_live_at(Time::now())
    }
    fn ensure_live_at(&self, now: Time) -> Result<(), DispatchError> {
        // Check signed expiry and both local clocks immediately before
        // effects, including suspension combined with wall-clock rollback.
        if now.monotonic >= self.deadline
            || now.wall >= self.expires_at
            || self
                .continuous_deadline
                .remaining_at(now.stamp().ok_or_else(expired)?)
                .is_none()
        {
            return Err(expired());
        }
        Ok(())
    }
    #[cfg(feature = "local-host")]
    pub(crate) fn ensure_account_current(&self) -> Result<(), DispatchError> {
        self.ensure_live()?;
        #[cfg(feature = "local-host")]
        if let Some(client) = &self.client {
            return client.ensure_current().map_err(api_error);
        }
        // Storage unit fixtures have no account client. Incoming production
        // principals are created only by online authorization or loopback.
        #[cfg(test)]
        return Ok(());
        #[cfg(not(test))]
        Err(expired())
    }
    #[cfg(all(test, feature = "local-host"))]
    pub(crate) fn storage_fixture(value: TeamPrincipal) -> Self {
        Self {
            value,
            deadline: Instant::now() + std::time::Duration::from_secs(60),
            continuous_deadline: Deadline::capture(std::time::Duration::from_secs(60))
                .expect("supported platform clock"),
            expires_at: Time::now().wall + 60,
            issuer: "https://accounts.example.test".into(),
            ticket: None,
            #[cfg(feature = "local-host")]
            client: None,
        }
    }
}

fn local_deadline(ticket: &VerifiedTeamTicket, requested: Instant, now: Time) -> Instant {
    requested.min(now.monotonic + std::time::Duration::from_secs(ticket.lease_seconds(now.wall)))
}

#[derive(Clone, Copy)]
struct Time {
    wall: u64,
    monotonic: Instant,
    boot: Option<std::time::Duration>,
}
impl Time {
    fn now() -> Self {
        let stamp = Stamp::now();
        Self {
            wall: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |value| value.as_secs()),
            monotonic: stamp.map_or_else(Instant::now, |stamp| stamp.awake),
            boot: stamp.map(|stamp| stamp.boot),
        }
    }
    fn stamp(self) -> Option<Stamp> {
        self.boot.map(|boot| Stamp {
            awake: self.monotonic,
            boot,
        })
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
    continuous_deadline: Deadline,
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
        let continuous_deadline = Deadline::at(
            now.stamp().ok_or_else(expired)?,
            deadline.saturating_duration_since(now.monotonic),
        )
        .ok_or_else(expired)?;
        Ok(Self {
            keys,
            device,
            host,
            publisher,
            previous,
            deadline,
            continuous_deadline,
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
        if self.retired
            || start.monotonic >= self.deadline
            || start.wall >= self.previous.claims().exp
            || self
                .continuous_deadline
                .remaining_at(start.stamp().ok_or_else(expired)?)
                .is_none()
        {
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
        let continuous_deadline = if ticket.wire_value() == self.previous.ticket().wire_value() {
            self.continuous_deadline
        } else {
            Deadline::at(
                start.stamp().ok_or_else(expired)?,
                deadline.saturating_duration_since(start.monotonic),
            )
            .ok_or_else(expired)?
        };
        let principal = online(&verified)?;
        let end = clock();
        if end.monotonic >= deadline
            || end.monotonic >= self.deadline
            || end.wall >= next.exp
            || end.wall >= prior.exp
            || self
                .continuous_deadline
                .remaining_at(end.stamp().ok_or_else(expired)?)
                .is_none()
            || continuous_deadline
                .remaining_at(end.stamp().ok_or_else(expired)?)
                .is_none()
        {
            return Err(expired());
        }
        let issuer = next.iss.clone();
        let expires_at = next.exp;
        #[cfg(feature = "local-host")]
        let ticket = Some(verified.clone());
        self.previous = verified;
        self.deadline = deadline;
        self.continuous_deadline = continuous_deadline;
        Ok(AuthorizedTeamPrincipal {
            value: principal,
            deadline,
            continuous_deadline,
            expires_at,
            issuer,
            #[cfg(feature = "local-host")]
            ticket,
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
            || self
                .gate
                .continuous_deadline
                .remaining_at(now.stamp().ok_or_else(expired)?)
                .is_none()
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
    #[cfg(feature = "local-host")]
    #[test]
    fn admission_retains_the_original_verified_run_ticket_and_rejects_substituted_principal_fields()
    {
        let fixture: Value =
            serde_json::from_str(include_str!("../../../../fixtures/teams/run-lease-v1.json"))
                .unwrap();
        let keys = TrustedTeamKeys::from_response(
            serde_json::from_value(fixture["keys"].clone()).unwrap(),
            "https://accounts.example.test",
        )
        .unwrap();
        let ticket = ticket(&fixture["actorTicket"]);
        let now = Time {
            wall: fixture["nowMs"].as_u64().unwrap() / 1000,
            monotonic: Instant::now(),
            ..Time::now()
        };
        let mut gate = Gate::new(
            keys,
            [0xaa; 32],
            tokenstat_identity::MachineIdentity::from_secret([7; 32]).public_key(),
            "fixture-owner".into(),
            &ticket,
            now,
        )
        .unwrap();
        let mut captured = gate
            .authorize(&ticket, || now, |proof| Ok(principal(proof)))
            .unwrap();
        assert_eq!(
            captured.ticket.as_ref().unwrap().ticket().wire_value(),
            ticket.wire_value()
        );
        // The public signature vector is historical. Only this unit fixture's
        // local expiry is moved so the retained binding can be exercised.
        captured.expires_at = Time::now().wall + 60;
        assert!(captured.run_ticket().is_ok());
        for field in 0..9 {
            let mut changed = captured.clone();
            match field {
                0 => changed.value.person.id = "another-person".into(),
                1 => changed.value.device_key = "cc".repeat(32),
                2 => changed.value.organization_id = "another-org".into(),
                3 => changed.value.repository_id = "another-repo".into(),
                4 => changed.value.checkout_id = "another-checkout".into(),
                5 => changed.value.publisher_id = "another-host-owner".into(),
                6 => changed.value.host_key = "dd".repeat(32),
                7 => changed.value.share_id = Some(format!("share_{}", "cc".repeat(16))),
                _ => changed.value.grant_id = Some(format!("grant_{}", "dd".repeat(16))),
            }
            assert!(changed.run_ticket().is_err(), "{field}");
        }
        let mut absent = captured.clone();
        absent.ticket = None;
        assert!(absent.run_ticket().is_err());
        let mut read_only = captured;
        read_only
            .value
            .capabilities
            .retain(|c| *c != tokenstat_sync::teams::TeamCapability::Run);
        assert!(read_only.run_ticket().is_err());
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
    fn captured_principal_expires_on_either_clock_without_network_or_renewal() {
        let wall = fixture()["now"].as_u64().unwrap();
        let now = Time {
            wall,
            monotonic: Instant::now(),
            ..Time::now()
        };
        let mut gate = gate(now);
        let captured = gate
            .authorize(
                &ticket(&fixture()["ticket"]),
                || now,
                |verified| Ok(principal(verified)),
            )
            .unwrap();
        assert!(captured.ensure_live_at(now).is_ok());
        let woke = Time {
            wall: now.wall - 1000,
            boot: now.boot.map(|boot| boot + Duration::from_secs(60)),
            ..now
        };
        assert!(
            captured.ensure_live_at(woke).is_err(),
            "A captured writer survived sleep and wall rollback"
        );
        assert!(
            gate.authorize(
                &ticket(&fixture()["ticket"]),
                || woke,
                |_| panic!("expired sleep lease reached online renewal")
            )
            .is_err()
        );
        // Model a system waking after signed expiry with its monotonic clock
        // unchanged. A previously captured writer must not perform effects.
        assert!(
            captured
                .ensure_live_at(Time {
                    wall: captured.expires_at,
                    ..now
                })
                .is_err()
        );
        // Moving wall time backward cannot extend the monotonic budget.
        assert!(
            captured
                .ensure_live_at(Time {
                    wall: wall - 10,
                    monotonic: captured.deadline,
                    ..Time::now()
                })
                .is_err()
        );
    }

    #[test]
    fn authority_is_noise_bound_and_is_rechecked_for_each_request() {
        let f = fixture();
        let now = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
            ..Time::now()
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
            ..Time::now()
        };
        let later = Time {
            wall: start.wall + 20,
            monotonic: start.monotonic + Duration::from_secs(20),
            ..Time::now()
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
            ..Time::now()
        };
        let rollback = Time {
            wall: start.wall - 1000,
            monotonic: start.monotonic + Duration::from_secs(60),
            ..Time::now()
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
                    ..Time::now()
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
    fn replacement_ticket_cannot_outlive_the_original_lease_during_validation() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            ..Time::now()
        };
        let validating = Time {
            wall: start.wall + 20,
            monotonic: start.monotonic + Duration::from_secs(20),
            boot: start.boot.map(|boot| boot + Duration::from_secs(20)),
        };
        for end in [
            Time {
                monotonic: start.monotonic + Duration::from_secs(60),
                ..validating
            },
            Time {
                wall: start.wall - 1000,
                boot: start.boot.map(|boot| boot + Duration::from_secs(60)),
                ..validating
            },
            Time {
                wall: start.wall + 60,
                ..validating
            },
        ] {
            let mut gate = gate(start);
            let clock = Cell::new(validating);
            assert!(
                gate.authorize(
                    &ticket(&f["variants"]["renewed"]),
                    || clock.get(),
                    |ticket| {
                        clock.set(end);
                        Ok(principal(ticket))
                    },
                )
                .is_err(),
                "replacement authority revived a connection after its original lease expired"
            );
            assert!(gate.retired);
        }
    }

    #[test]
    fn failed_platform_clock_retires_authority_before_any_online_validation() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            ..Time::now()
        };
        let failed = Time {
            boot: None,
            ..start
        };
        assert!(
            Gate::new(
                keys(),
                [0xaa; 32],
                [0xbb; 32],
                "fixture-owner".into(),
                &ticket(&f["ticket"]),
                failed,
            )
            .is_err()
        );
        let mut gate = gate(start);
        let captured = gate
            .authorize(
                &ticket(&f["ticket"]),
                || start,
                |ticket| Ok(principal(ticket)),
            )
            .unwrap();
        assert!(captured.ensure_live_at(failed).is_err());
        assert!(
            gate.authorize(
                &ticket(&f["ticket"]),
                || failed,
                |_| panic!("failed clock reached online validation"),
            )
            .is_err()
        );
        assert!(
            gate.authorize(
                &ticket(&f["ticket"]),
                || start,
                |_| panic!("retired connection survived a later successful clock read"),
            )
            .is_err()
        );
    }

    #[test]
    fn revalidating_the_same_ticket_preserves_its_original_sleep_budget() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            ..Time::now()
        };
        let mut gate = gate(start);
        let later = Time {
            boot: start.boot.map(|boot| boot + Duration::from_secs(20)),
            ..start
        };
        let captured = gate
            .authorize(
                &ticket(&f["ticket"]),
                || later,
                |ticket| Ok(principal(ticket)),
            )
            .unwrap();
        assert_eq!(
            captured
                .continuous_deadline
                .remaining_at(later.stamp().unwrap()),
            Some(Duration::from_secs(39)),
        );
    }

    #[test]
    fn loopback_reads_cannot_extend_the_signed_lease_or_the_original_deadline() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
            ..Time::now()
        };
        let proof = gate(start).previous;
        let long = start.monotonic + Duration::from_secs(300);
        let original = local_deadline(&proof, long, start);
        assert_eq!(original, start.monotonic + Duration::from_secs(59));
        let short = start.monotonic + Duration::from_secs(2);
        assert_eq!(local_deadline(&proof, short, start), short);
        let rollback = Time {
            wall: start.wall - 1000,
            monotonic: start.monotonic + Duration::from_secs(50),
            ..Time::now()
        };
        assert_eq!(local_deadline(&proof, original, rollback), original);
        let expired = Time {
            wall: start.wall + 60,
            monotonic: start.monotonic + Duration::from_secs(60),
            ..Time::now()
        };
        assert_eq!(local_deadline(&proof, long, expired), expired.monotonic);
    }
    #[test]
    fn a_new_valid_execution_grant_cannot_revive_an_admitted_connection() {
        let f = fixture();
        let start = Time {
            wall: f["now"].as_u64().unwrap(),
            monotonic: Instant::now(),
            ..Time::now()
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
            ..Time::now()
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
            ..Time::now()
        };
        let mut authorized = gate(now)
            .authorize(
                &ticket(&f["ticket"]),
                || now,
                |ticket| Ok(principal(ticket)),
            )
            .unwrap();
        // This dispatch test uses a historical signed fixture. Only its
        // identity/scope are under test; give the captured fixture a live
        // local clock without weakening production ticket verification.
        authorized.expires_at = Time::now().wall + 60;
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
                        "chat.sharing.recoverRun",
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
