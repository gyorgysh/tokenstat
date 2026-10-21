// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! One-use account-server challenge for granting trusted host execution.
//! X25519 proves key possession through DH; it is never used as a signature.

use crate::{MachineIdentity, hex, public_key_from_hex};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::{hkdf, hmac};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const DOMAIN: &str = "tokenstat/teams/host-proof/v1";

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostChallenge {
    version: u32,
    context: String,
}
impl std::fmt::Debug for HostChallenge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HostChallenge([redacted])")
    }
}

/// All expected values come from the captured account and reviewed operation.
pub struct HostProofBinding<'a> {
    pub issuer: &'a str,
    pub actor: &'a str,
    pub token: &'a str,
    pub machine: &'a str,
    pub organization: &'a str,
    pub checkout: &'a str,
    pub operation_hash: &'a str,
}

#[derive(Serialize)]
pub struct HostProof {
    id: String,
    mac: String,
}
impl std::fmt::Debug for HostProof {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HostProof([redacted])")
    }
}
#[derive(Debug, thiserror::Error)]
#[error("The host confirmation expired or did not match this computer and change.")]
pub struct InvalidHostChallenge;

impl HostChallenge {
    pub fn answer(
        &self,
        identity: &MachineIdentity,
        expected: &HostProofBinding<'_>,
        now_ms: i64,
    ) -> Result<HostProof, InvalidHostChallenge> {
        let invalid = || InvalidHostChallenge;
        if self.version != 1 || self.context.len() > 5462 {
            return Err(invalid());
        }
        let context = URL_SAFE_NO_PAD
            .decode(&self.context)
            .map_err(|_| invalid())?;
        let fields: [String; 15] = serde_json::from_slice(&context).map_err(|_| invalid())?;
        let host_key = identity.public_key_hex();
        let wanted = [
            DOMAIN,
            expected.issuer,
            expected.actor,
            expected.token,
            expected.machine,
            &host_key,
            expected.organization,
            expected.checkout,
            expected.operation_hash,
        ];
        if !fields[..9].iter().map(String::as_str).eq(wanted)
            || !fields[9].split_once(':').is_some_and(|(epoch, consent)| {
                [epoch, consent].iter().all(|v| {
                    v.parse::<u64>()
                        .is_ok_and(|v| v > 0 && v <= 9_007_199_254_740_991)
                })
            })
            || !fields[10]
                .strip_prefix("hostproof_")
                .is_some_and(|v| lower_hex(v, 32))
            || !lower_hex(&fields[11], 64)
            || !lower_hex(&fields[12], 64)
        {
            return Err(invalid());
        }
        let time = |value: &str| {
            value
                .parse::<jiff::Timestamp>()
                .map(|v| v.as_millisecond())
                .map_err(|_| invalid())
        };
        let issued = time(&fields[13])?;
        let expires = time(&fields[14])?;
        if issued > now_ms.saturating_add(5_000)
            || expires <= now_ms
            || expires.checked_sub(issued) != Some(60_000)
        {
            return Err(invalid());
        }
        let peer = public_key_from_hex(&fields[11]).map_err(|_| invalid())?;
        let salt = public_key_from_hex(&fields[12]).map_err(|_| invalid())?;
        let shared = identity
            .secret
            .diffie_hellman(&x25519_dalek::PublicKey::from(peer));
        if !shared.was_contributory() {
            return Err(invalid());
        }
        let extracted = hkdf::Salt::new(hkdf::HKDF_SHA256, &salt).extract(shared.as_bytes());
        let info = [DOMAIN.as_bytes()];
        let mut key = Zeroizing::new([0u8; 32]);
        extracted
            .expand(&info, hkdf::HKDF_SHA256)
            .map_err(|_| invalid())?
            .fill(&mut *key)
            .map_err(|_| invalid())?;
        let mac = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, &*key), &context);
        Ok(HostProof {
            id: fields[10].clone(),
            mac: hex(mac.as_ref()),
        })
    }
}
fn lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    fn vector() -> Value {
        serde_json::from_str(include_str!("../../../fixtures/teams/host-proof-v1.json")).unwrap()
    }
    fn answer(
        challenge: Value,
        identity: &MachineIdentity,
        now: i64,
    ) -> Result<HostProof, InvalidHostChallenge> {
        let v = vector();
        let b = &v["binding"];
        serde_json::from_value::<HostChallenge>(challenge)
            .unwrap()
            .answer(
                identity,
                &HostProofBinding {
                    issuer: b["issuer"].as_str().unwrap(),
                    actor: b["actor"].as_str().unwrap(),
                    token: b["token"].as_str().unwrap(),
                    machine: b["machine"].as_str().unwrap(),
                    organization: b["organization"].as_str().unwrap(),
                    checkout: b["checkout"].as_str().unwrap(),
                    operation_hash: b["operationHash"].as_str().unwrap(),
                },
                now,
            )
    }
    #[test]
    fn matches_the_public_node_crypto_interoperability_vector() {
        let v = vector();
        let identity = MachineIdentity::from_secret([7; 32]);
        let proof = answer(
            v["challenge"].clone(),
            &identity,
            v["nowMs"].as_i64().unwrap(),
        )
        .unwrap();
        assert_eq!(serde_json::to_value(&proof).unwrap(), v["proof"]);
        assert_eq!(format!("{proof:?}"), "HostProof([redacted])");
        let other = answer(
            v["challenge"].clone(),
            &MachineIdentity::from_secret([8; 32]),
            v["nowMs"].as_i64().unwrap(),
        );
        assert!(other.is_err());
    }
    #[test]
    fn refuses_retargeting_malformed_points_and_expired_or_extended_challenges() {
        let v = vector();
        let identity = MachineIdentity::from_secret([7; 32]);
        let now = v["nowMs"].as_i64().unwrap();
        let context = URL_SAFE_NO_PAD
            .decode(v["challenge"]["context"].as_str().unwrap())
            .unwrap();
        let fields: Vec<Value> = serde_json::from_slice(&context).unwrap();
        for index in 0..15 {
            let mut changed = fields.clone();
            changed[index] = match index {
                9 => json!("0:0"),
                11 => json!("0".repeat(64)),
                12 => json!("g".repeat(64)),
                13 => json!("2026-01-01T00:00:10.000Z"),
                14 => json!("2026-01-01T00:02:00.000Z"),
                _ => json!("changed"),
            };
            let challenge = json!({"version":1,"context":URL_SAFE_NO_PAD.encode(serde_json::to_vec(&changed).unwrap())});
            assert!(answer(challenge, &identity, now).is_err(), "field {index}");
        }
        assert!(answer(v["challenge"].clone(), &identity, now + 60_000).is_err());
        assert!(
            answer(
                json!({"version":2,"context":v["challenge"]["context"]}),
                &identity,
                now
            )
            .is_err()
        );
        assert!(
            answer(
                json!({"version":1,"context":"x".repeat(5463)}),
                &identity,
                now
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<HostChallenge>(
                json!({"version":1,"context":"x","other":true})
            )
            .is_err()
        );
    }
}
