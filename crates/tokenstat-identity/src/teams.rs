// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Offline verification of account-server authorization, bound to the static
//! keys authenticated by Noise. Server Ed25519 keys never replace machine
//! X25519 keys or add a teammate to the personal peer allowlist.

use std::collections::BTreeMap;
use std::fmt;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::{digest, signature};
use serde::{Deserialize, Deserializer, Serialize};

use crate::{PublicKey, hex};

pub const TICKET_PREFIX: &str = "ts-team-v1";
pub const TICKET_AUDIENCE: &str = "tokenstat-teams-host-v1";
pub const MAX_TICKET_BYTES: usize = 4096;
pub const MAX_LEASE_SECONDS: u64 = 60;
const JS_MAX_INTEGER: u64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TeamTicketError {
    #[error("The team access ticket is not valid.")]
    Invalid,
    #[error("Team access expired. Connect again.")]
    Expired,
    #[error("The team connection does not match this device and host.")]
    BindingMismatch,
    #[error("The team verification keys do not match this account server.")]
    UntrustedAuthority,
}

/// A wire ticket is unverified. Its contents must never supply an actor or
/// authorize a method until `TrustedTeamKeys::verify` succeeds.
#[derive(Clone, Deserialize)]
#[serde(try_from = "String")]
pub struct TeamTicket(String);

impl TryFrom<String> for TeamTicket {
    type Error = TeamTicketError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > MAX_TICKET_BYTES
            || !value.starts_with(TICKET_PREFIX)
            || !value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return Err(TeamTicketError::Invalid);
        }
        Ok(Self(value))
    }
}
impl TeamTicket {
    /// Only for the encrypted connection and account-server validation call.
    pub fn wire_value(&self) -> &str {
        &self.0
    }
}
impl fmt::Debug for TeamTicket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TeamTicket([redacted])")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TeamCapability {
    Read,
    Comment,
    Run,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamVerificationKey {
    pub kid: String,
    pub key: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamKeyResponse {
    pub version: u32,
    pub issuer: String,
    pub audience: String,
    pub keys: Vec<TeamVerificationKey>,
}

#[derive(Clone)]
pub struct TrustedTeamKeys {
    issuer: String,
    keys: BTreeMap<String, PublicKey>,
}

impl TrustedTeamKeys {
    /// The caller obtains this response over the chosen account origin's
    /// authenticated HTTPS connection. Never obtain keys from a ticket URL.
    pub fn from_response(
        response: TeamKeyResponse,
        expected_issuer: &str,
    ) -> Result<Self, TeamTicketError> {
        if response.version != 1
            || response.issuer != expected_issuer
            || response.audience != TICKET_AUDIENCE
            || expected_issuer.is_empty()
            || expected_issuer.len() > 512
            || response.keys.is_empty()
            || response.keys.len() > 8
        {
            return Err(TeamTicketError::UntrustedAuthority);
        }
        let mut keys = BTreeMap::new();
        for entry in response.keys {
            if !lower_hex(&entry.kid, 24) || entry.key.len() != 43 {
                return Err(TeamTicketError::UntrustedAuthority);
            }
            let raw = URL_SAFE_NO_PAD
                .decode(&entry.key)
                .map_err(|_| TeamTicketError::UntrustedAuthority)?;
            let key: PublicKey = raw
                .try_into()
                .map_err(|_| TeamTicketError::UntrustedAuthority)?;
            let kid = hex(digest::digest(&digest::SHA256, &key).as_ref());
            if kid.get(..24) != Some(entry.kid.as_str()) || keys.insert(entry.kid, key).is_some() {
                return Err(TeamTicketError::UntrustedAuthority);
            }
        }
        Ok(Self {
            issuer: response.issuer,
            keys,
        })
    }

    pub fn verify(
        &self,
        ticket: &TeamTicket,
        binding: &TeamTicketBinding<'_>,
        now: u64,
    ) -> Result<VerifiedTeamTicket, TeamTicketError> {
        let parts: Vec<_> = ticket.0.split('.').collect();
        if parts.len() != 4
            || parts[0] != TICKET_PREFIX
            || !lower_hex(parts[1], 24)
            || parts[3].len() != 86
        {
            return Err(TeamTicketError::Invalid);
        }
        let key = self.keys.get(parts[1]).ok_or(TeamTicketError::Invalid)?;
        let signed_len = ticket
            .0
            .len()
            .checked_sub(parts[3].len() + 1)
            .ok_or(TeamTicketError::Invalid)?;
        let signature = URL_SAFE_NO_PAD
            .decode(parts[3])
            .map_err(|_| TeamTicketError::Invalid)?;
        signature::UnparsedPublicKey::new(&signature::ED25519, key)
            .verify(
                ticket
                    .0
                    .as_bytes()
                    .get(..signed_len)
                    .ok_or(TeamTicketError::Invalid)?,
                &signature,
            )
            .map_err(|_| TeamTicketError::Invalid)?;
        let payload = URL_SAFE_NO_PAD
            .decode(parts[2])
            .map_err(|_| TeamTicketError::Invalid)?;
        let claims: TeamTicketClaims =
            serde_json::from_slice(&payload).map_err(|_| TeamTicketError::Invalid)?;
        claims.validate(&self.issuer, now)?;
        if claims.device != hex(binding.device_key)
            || claims.host != hex(binding.host_key)
            || claims.publisher != binding.publisher_id
            || binding.actor_id.is_some_and(|actor| claims.sub != actor)
        {
            return Err(TeamTicketError::BindingMismatch);
        }
        Ok(VerifiedTeamTicket {
            ticket: ticket.clone(),
            claims,
        })
    }
}

pub struct TeamTicketBinding<'a> {
    /// The source static key that Noise actually authenticated.
    pub device_key: &'a PublicKey,
    /// This host's own static key, or the destination the caller pinned.
    pub host_key: &'a PublicKey,
    pub publisher_id: &'a str,
    /// A caller knows its own account; an incoming host learns the actor from
    /// the signed claim and revalidates it with the account service.
    pub actor_id: Option<&'a str>,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamTicketClaims {
    pub v: u32,
    pub iss: String,
    pub aud: String,
    pub sub: String,
    pub device: String,
    pub token: String,
    pub consent: u64,
    pub org: String,
    pub repository: String,
    pub checkout: String,
    pub host: String,
    pub publisher: String,
    pub epoch: u64,
    pub revision: u64,
    #[serde(deserialize_with = "required_option")]
    pub share: Option<String>,
    #[serde(rename = "shareRevision", deserialize_with = "required_option")]
    pub share_revision: Option<u64>,
    /// Identity of the exact host-approved execution grant. Revocation and a
    /// later approval must never revive a previous connection or run lease.
    #[serde(deserialize_with = "required_option")]
    pub grant: Option<String>,
    pub cap: Vec<TeamCapability>,
    pub iat: u64,
    pub exp: u64,
    pub nonce: String,
}

fn required_option<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::deserialize(deserializer)
}

impl TeamTicketClaims {
    fn validate(&self, issuer: &str, now: u64) -> Result<(), TeamTicketError> {
        if self.v != 1
            || self.iss != issuer
            || self.aud != TICKET_AUDIENCE
            || self.iat > now.saturating_add(5)
            || self.exp <= self.iat
            || self.exp.saturating_sub(self.iat) > MAX_LEASE_SECONDS
            || !lower_hex(&self.nonce, 32)
            || ![self.epoch, self.revision, self.consent]
                .iter()
                .all(|n| *n > 0 && *n <= JS_MAX_INTEGER)
            || ![
                &self.sub,
                &self.token,
                &self.org,
                &self.repository,
                &self.checkout,
                &self.publisher,
            ]
            .iter()
            .all(|s| valid_id(s))
            || !lower_hex(&self.device, 64)
            || !lower_hex(&self.host, 64)
            || self.share.as_ref().is_some_and(|share| {
                !share
                    .strip_prefix("share_")
                    .is_some_and(|s| lower_hex(s, 32))
            })
            || (self.share.is_some() != self.share_revision.is_some())
            || self
                .share_revision
                .is_some_and(|r| r == 0 || r > JS_MAX_INTEGER)
            || self.cap.is_empty()
            || self.cap.len() > 3
            || !self.cap.contains(&TeamCapability::Read)
            || self.cap.contains(&TeamCapability::Run) != self.grant.is_some()
            || self.grant.as_ref().is_some_and(|grant| {
                !grant
                    .strip_prefix("grant_")
                    .is_some_and(|id| lower_hex(id, 32))
            })
            || self
                .cap
                .iter()
                .enumerate()
                .any(|(index, cap)| self.cap[..index].contains(cap))
        {
            return Err(TeamTicketError::Invalid);
        }
        if self.exp <= now {
            return Err(TeamTicketError::Expired);
        }
        Ok(())
    }
}
fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && value.bytes().all(|b| b.is_ascii_graphic())
}
fn lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Signature and peer binding are verified. Current membership, sharing and
/// execution grants still require online validation before every request.
#[derive(Clone)]
pub struct VerifiedTeamTicket {
    ticket: TeamTicket,
    claims: TeamTicketClaims,
}
impl VerifiedTeamTicket {
    pub fn ticket(&self) -> &TeamTicket {
        &self.ticket
    }
    pub fn claims(&self) -> &TeamTicketClaims {
        &self.claims
    }
    /// Use this to establish an additional monotonic deadline. A wall-clock
    /// adjustment must never extend a lease beyond one minute.
    pub fn lease_seconds(&self, now: u64) -> u64 {
        self.claims.exp.saturating_sub(now).min(MAX_LEASE_SECONDS)
    }
}
impl fmt::Debug for VerifiedTeamTicket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("VerifiedTeamTicket([redacted])")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::KeyPair;
    use serde_json::{Value, json};

    const ISSUER: &str = "https://accounts.example.test";
    fn binding() -> TeamTicketBinding<'static> {
        TeamTicketBinding {
            device_key: &[0xaa; 32],
            host_key: &[0xbb; 32],
            publisher_id: "fixture-owner",
            actor_id: Some("fixture-member"),
        }
    }
    fn vector() -> Value {
        serde_json::from_str(include_str!("../../../fixtures/teams/ticket-v1.json")).unwrap()
    }
    fn keys() -> TrustedTeamKeys {
        TrustedTeamKeys::from_response(
            serde_json::from_value(vector()["keys"].clone()).unwrap(),
            ISSUER,
        )
        .unwrap()
    }
    fn ticket() -> TeamTicket {
        TeamTicket::try_from(vector()["ticket"].as_str().unwrap().to_owned()).unwrap()
    }
    fn signed(change: impl FnOnce(&mut Value)) -> TeamTicket {
        let original = vector();
        let parts: Vec<_> = original["ticket"].as_str().unwrap().split('.').collect();
        let mut payload: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
        change(&mut payload);
        let message = format!(
            "{}.{}.{}",
            parts[0],
            parts[1],
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap())
        );
        // Public deterministic fixture seed, shared with the Node vector.
        let key = signature::Ed25519KeyPair::from_seed_unchecked(&[7; 32]).unwrap();
        TeamTicket::try_from(format!(
            "{message}.{}",
            URL_SAFE_NO_PAD.encode(key.sign(message.as_bytes()))
        ))
        .unwrap()
    }
    #[test]
    fn verifies_the_node_crypto_interoperability_vector() {
        let verified = keys().verify(&ticket(), &binding(), 1767225601).unwrap();
        assert_eq!(verified.claims().sub, "fixture-member");
        assert_eq!(
            verified.claims().cap,
            [TeamCapability::Read, TeamCapability::Comment]
        );
        assert_eq!(verified.lease_seconds(1767225601), 59);
        assert_eq!(verified.lease_seconds(0), MAX_LEASE_SECONDS);
        assert!(!format!("{verified:?}").contains("fixture-member"));
        assert!(!format!("{:?}", ticket()).contains("ts-team-v1"));
        let raw = vector()["keys"]["keys"][0]["key"]
            .as_str()
            .unwrap()
            .to_owned();
        let key = signature::Ed25519KeyPair::from_seed_unchecked(&[7; 32]).unwrap();
        assert_eq!(URL_SAFE_NO_PAD.encode(key.public_key()), raw);
    }
    #[test]
    fn binds_the_signature_to_the_account_origin_and_noise_keys() {
        let response: TeamKeyResponse = serde_json::from_value(vector()["keys"].clone()).unwrap();
        assert!(
            TrustedTeamKeys::from_response(response.clone(), "https://another.example.test")
                .is_err()
        );
        for field in ["device", "host", "publisher", "sub"] {
            let bad = signed(|claims| {
                claims[field] = json!(if field == "device" || field == "host" {
                    "d".repeat(64)
                } else {
                    "another-fixture".into()
                });
            });
            assert_eq!(
                keys().verify(&bad, &binding(), 1767225601).unwrap_err(),
                TeamTicketError::BindingMismatch
            );
        }
        let mut wrong = response;
        wrong.keys[0].key = URL_SAFE_NO_PAD.encode([9; 32]);
        assert!(TrustedTeamKeys::from_response(wrong, ISSUER).is_err());
        let bad = signed(|claims| {
            claims["iss"] = json!("https://another.example.test");
        });
        assert_eq!(
            keys().verify(&bad, &binding(), 1767225601).unwrap_err(),
            TeamTicketError::Invalid
        );
    }
    #[test]
    fn refuses_expired_long_future_and_malformed_authority() {
        assert_eq!(
            keys()
                .verify(&ticket(), &binding(), 1767225660)
                .unwrap_err(),
            TeamTicketError::Expired
        );
        for value in [
            signed(|c| {
                c["exp"] = json!(1767225661_u64);
            }),
            signed(|c| {
                c["iat"] = json!(1767225607_u64);
                c["exp"] = json!(1767225660_u64);
            }),
            signed(|c| {
                c["cap"] = json!(["read", "read"]);
            }),
            signed(|c| {
                c["cap"] = json!(["run"]);
            }),
            signed(|c| {
                c["cap"] = json!(["read", "vault"]);
            }),
            signed(|c| {
                c["epoch"] = json!(0);
            }),
            signed(|c| {
                c["epoch"] = json!(JS_MAX_INTEGER + 1);
            }),
            signed(|c| {
                c["authorId"] = json!("fixture-owner");
            }),
            signed(|c| {
                c["nonce"] = json!("c".repeat(31));
            }),
            signed(|c| {
                c.as_object_mut().unwrap().remove("share");
            }),
            signed(|c| {
                c["share"] = json!("share_".to_owned() + &"a".repeat(32));
            }),
        ] {
            assert!(keys().verify(&value, &binding(), 1767225601).is_err());
        }
    }
    #[test]
    fn run_authority_requires_one_exact_grant_and_read_authority_has_none() {
        let valid = signed(|c| {
            c["cap"] = json!(["read", "run"]);
            c["grant"] = json!("grant_".to_owned() + &"e".repeat(32));
        });
        assert_eq!(
            keys()
                .verify(&valid, &binding(), 1767225601)
                .unwrap()
                .claims()
                .grant,
            Some("grant_".to_owned() + &"e".repeat(32))
        );
        for invalid in [
            signed(|c| {
                c.as_object_mut().unwrap().remove("grant");
            }),
            signed(|c| {
                c["cap"] = json!(["read", "run"]);
            }),
            signed(|c| {
                c["cap"] = json!(["read", "run"]);
                c["grant"] = json!("grant_bad");
            }),
            signed(|c| {
                c["grant"] = json!("grant_".to_owned() + &"e".repeat(32));
            }),
        ] {
            assert!(keys().verify(&invalid, &binding(), 1767225601).is_err());
        }
    }
    #[test]
    fn rejects_modified_bytes_unknown_keys_and_unbounded_wire_input() {
        let original = ticket();
        let mut value = original.wire_value().as_bytes().to_vec();
        let at = value.iter().position(|b| *b == b'.').unwrap() + 1;
        value[at] = if value[at] == b'a' { b'b' } else { b'a' };
        assert!(
            keys()
                .verify(
                    &TeamTicket::try_from(String::from_utf8(value).unwrap()).unwrap(),
                    &binding(),
                    1767225601
                )
                .is_err()
        );
        assert!(TeamTicket::try_from("x".repeat(MAX_TICKET_BYTES + 1)).is_err());
        assert!(TeamTicket::try_from(format!("{}\n", original.wire_value())).is_err());
        assert!(
            keys()
                .verify(
                    &TeamTicket::try_from("ts-team-v1.a.b.c".to_string()).unwrap(),
                    &binding(),
                    1767225601
                )
                .is_err()
        );
    }
}
