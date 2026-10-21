// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{ExecutionReply, SetExecutionGrant, TeamClient, TeamError, value};
use reqwest::Method;
use sha2::{Digest, Sha256};
use tokenstat_identity::{
    MachineIdentity, hex,
    team_host_proof::{HostChallenge, HostProofBinding},
};

pub(super) fn grant(
    client: &TeamClient,
    organization: &str,
    checkout: &str,
    input: &SetExecutionGrant,
) -> Result<ExecutionReply, TeamError> {
    let identity = MachineIdentity::load_or_create().map_err(|_| TeamError::InvalidRequest)?;
    let machine = crate::config::ensure_machine_id().map_err(|_| TeamError::InvalidRequest)?;
    grant_for_identity(
        client,
        organization,
        checkout,
        input,
        &identity,
        &machine,
        || jiff::Timestamp::now().as_millisecond(),
    )
}

pub(super) fn grant_for_identity(
    client: &TeamClient,
    organization: &str,
    checkout: &str,
    input: &SetExecutionGrant,
    identity: &MachineIdentity,
    machine: &str,
    clock: impl FnOnce() -> i64,
) -> Result<ExecutionReply, TeamError> {
    if !input.allow
        || input.expected_revision == 0
        || input.expected_revision > 9_007_199_254_740_991
        || input.acknowledge_host_access != Some(true)
    {
        return Err(TeamError::InvalidRequest);
    }
    let capabilities = client.capabilities()?;
    if !capabilities.enabled
        || capabilities.version != 1
        || !capabilities
            .features
            .iter()
            .any(|feature| feature == "host-execution-proof-v1")
    {
        return Err(TeamError::Unsupported);
    }
    let actor = capabilities
        .actor_id
        .as_deref()
        .ok_or(TeamError::InvalidResponse)?;
    let (token, _) = client
        .authentication
        .bearer
        .strip_prefix("tsk_")
        .and_then(|value| value.split_once('_'))
        .ok_or(TeamError::InvalidResponse)?;
    if !capabilities.ready()
        || capabilities.device_key.as_deref() != Some(identity.public_key_hex().as_str())
        || token.is_empty()
        || token.len() > 128
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || capabilities.authorization_path.as_deref()
            != Some(format!("/settings/teams/devices/{token}").as_str())
    {
        return Err(TeamError::InvalidResponse);
    }
    let operation = serde_json::to_vec(&(
        "execution.grant",
        &input.user_id,
        &input.machine_id,
        &input.device_key,
        input.allow,
        input.expected_revision,
        input.acknowledge_host_access == Some(true),
    ))
    .map_err(|_| TeamError::InvalidRequest)?;
    let operation_hash = hex(Sha256::digest(operation).as_slice());
    let challenge: HostChallenge = client.request(
        Method::POST,
        &[
            "organizations",
            organization,
            "checkouts",
            checkout,
            "execution",
            "challenge",
        ],
        Some(value(input)?),
        None,
    )?;
    client.ensure_current()?;
    let proof = challenge
        .answer(
            identity,
            &HostProofBinding {
                issuer: client.origin(),
                actor,
                token,
                machine,
                organization,
                checkout,
                operation_hash: &operation_hash,
            },
            clock(),
        )
        .map_err(|_| TeamError::InvalidResponse)?;
    let mut body = value(input)?;
    body.as_object_mut()
        .ok_or(TeamError::InvalidRequest)?
        .insert("hostProof".into(), value(&proof)?);
    client.request(
        Method::PUT,
        &[
            "organizations",
            organization,
            "checkouts",
            checkout,
            "execution",
        ],
        Some(body),
        None,
    )
}
