// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{AuthorizedTeamPrincipal, api_error, scoped_source::Source};
use crate::{
    chat::sharing::{AskInput, AskPreparation},
    error::DispatchError,
};
use serde_json::Value;
use sha2::{Digest, Sha256};

// Admission is compiled and tested alongside canonical storage. Execution
// remains closed until a supervised runner, scoped SDK and host grant UI are
// ready. Changing this gate alone would only record a NotStarted attempt.
fn execution_ready() -> bool {
    false
}

pub(super) fn review(
    principal: &AuthorizedTeamPrincipal,
    params: &str,
) -> Result<Value, DispatchError> {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Input {}
    if params.len() > 1024 {
        return Err(invalid());
    }
    let _: Input = serde_json::from_str(params).map_err(|_| invalid())?;
    principal.run_ticket()?;
    let source = Source::capture(principal)?;
    let checkout = checkout_digest(&source)?;
    let review =
        crate::chat::shared().team_ask_review(source.target(), principal, &checkout, || {
            source.ensure_current()
        })?;
    source.ensure_current()?;
    principal.ensure_account_current()?;
    Ok(serde_json::json!({"review":review,"agentRuns":execution_ready()}))
}
fn checkout_digest(source: &Source) -> Result<String, DispatchError> {
    Ok(tokenstat_identity::hex(&Sha256::digest(
        serde_json::to_vec(&source.checkout).map_err(|_| invalid())?,
    )))
}

pub(super) fn send(
    principal: &AuthorizedTeamPrincipal,
    params: &str,
) -> Result<Value, DispatchError> {
    if !execution_ready() {
        return Err(DispatchError::new(
            "team_agent_runs_unavailable",
            "Agent runs are not available in shared chats yet.",
        ));
    }
    if params.len() > 16 * 1024 {
        return Err(invalid());
    }
    let input: AskInput = serde_json::from_str(params).map_err(|_| invalid())?;
    input.validate()?;
    let ticket = principal.run_ticket()?;
    let client = principal.account_client()?;
    let source = Source::capture(principal)?;
    // The physical publication identity stays private; only its hash enters
    // local run metadata. Worktree/branch-state review is a later launch gate.
    let checkout = checkout_digest(&source)?;
    let chats = crate::chat::shared();
    match chats.prepare_team_ask(
        source.target(),
        principal,
        &input,
        &source.checkout.folder.canonical,
        &checkout,
        || source.ensure_current(),
    )? {
        AskPreparation::Existing(value) => Ok(value),
        AskPreparation::New(prepared) => {
            let admitted = (|| {
                principal.ensure_account_current()?;
                source.ensure_current()?;
                prepared.ensure_writer_current()?;
                chats
                    .ensure_prepared_ask(source.target(), &prepared, || source.ensure_current())?;
                // Paid backend birth is still prohibited. This is the actual
                // production SDK admission seam, outside canonical locks.
                let mut authority = client
                    .admit_host_run_authority(&prepared.binding().cloud_reference, ticket)
                    .map_err(api_error)?;
                let checked: Result<(), DispatchError> = (|| {
                    principal.ensure_account_current()?;
                    source.ensure_current()?;
                    prepared.ensure_writer_current()?;
                    chats.ensure_prepared_ask(source.target(), &prepared, || {
                        source.ensure_current()
                    })?;
                    authority.ensure_live().map_err(api_error)?;
                    // The future runner consumes this frozen visible prefix,
                    // never the private send context or a later Comment tail.
                    let _frozen_context = prepared.context();
                    Ok(())
                })();
                let _cleanup = authority.retire();
                checked
            })();
            // No process was spawned in this compiled admission-only path.
            // Persist a terminal result before clearing the exact local fence.
            let result = chats.refuse_prepared_ask(source.target(), *prepared);
            admitted?;
            result
        }
    }
}
fn invalid() -> DispatchError {
    DispatchError::new(
        "invalid_ask",
        "Check the message and review the shared chat before asking the agent.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn execution_stays_closed_before_storage_or_network_effects() {
        assert!(!execution_ready());
        let p = AuthorizedTeamPrincipal::storage_fixture(serde_json::from_value(serde_json::json!({
            "id":"person","name":"Example member","handle":null,"avatar":null,"deviceKey":"a".repeat(64),
            "organizationId":"org","repositoryId":"repo","checkoutId":"checkout","hostKey":"b".repeat(64),"publisherId":"owner",
            "shareId":format!("share_{}","a".repeat(32)),"grantId":null,"epoch":1,"capabilities":["read"],"role":"viewer","expiresAt":"2026-12-01T00:00:00Z"
        })).unwrap());
        assert_eq!(
            send(&p, "{}").unwrap_err().code,
            "team_agent_runs_unavailable"
        );
    }
}
