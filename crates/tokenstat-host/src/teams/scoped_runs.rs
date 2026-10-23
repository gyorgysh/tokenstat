// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{AuthorizedTeamPrincipal, scoped_source::Source};
use crate::{chat::sharing::AskInput, error::DispatchError};
use serde_json::Value;
use sha2::{Digest, Sha256};

// Release builds stay closed until the whole-change review and the Windows
// proof are done. A debug build opens it so the owner's own test builds can
// run agents for teammates the owner allowed, and the disposable fixture
// opens it for the end-to-end check. Unit tests stay closed.
pub(super) fn execution_ready() -> bool {
    (cfg!(debug_assertions) && !cfg!(test)) || super::guardian::fixture_enabled()
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
    let review = crate::chat::shared().team_ask_review(
        source.target(),
        principal,
        &source.checkout.folder.canonical,
        &checkout,
        || source.ensure_current(),
    )?;
    source.ensure_current()?;
    principal.ensure_account_current()?;
    Ok(
        serde_json::json!({"review":review.digest,"agentRuns":execution_ready(),"worktree":review.worktree}),
    )
}
pub(super) fn checkout_digest(source: &Source) -> Result<String, DispatchError> {
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
    super::guardian::run(principal, &input)
}
/// Start an empty shared chat on this checkout for the member, so a person
/// can Ask without waiting for the publisher to share a chat first.
pub(super) fn new_chat(
    principal: &AuthorizedTeamPrincipal,
    params: &str,
) -> Result<Value, DispatchError> {
    if !execution_ready() {
        return Err(DispatchError::new(
            "team_agent_runs_unavailable",
            "Agent runs are not available in shared chats yet.",
        ));
    }
    let input = super::chats::new_chat_input(params)?;
    principal.new_chat_ticket()?;
    let scope = principal.value();
    let owner = crate::account_session::AccountSnapshot::capture().map_err(|_| unavailable())?;
    let authority = principal.clone();
    let client = super::client(&owner)?.with_retirement_guard(move || {
        authority.ensure_account_current().map_err(|error| {
            tokenstat_sync::teams::TeamError::Rejected {
                status: 403,
                code: error.code,
                message: error.message,
            }
        })
    });
    // Only the computer that published this checkout makes chats for it.
    let binding = super::sharing::local_binding(&owner, &client)?;
    if binding.issuer != principal.issuer()
        || binding.publisher_id != scope.publisher_id
        || binding.host_key != scope.host_key
    {
        return Err(unavailable());
    }
    let result = super::chats::start_for_member(
        &owner,
        &client,
        super::chats::NewChat {
            organization: &scope.organization_id,
            repository: &scope.repository_id,
            checkout: &scope.checkout_id,
            title: &input.title,
            request_id: &input.request_id,
            person: &scope.person.id,
        },
        &|| principal.ensure_account_current(),
    )?;
    principal.ensure_account_current()?;
    Ok(result)
}
fn unavailable() -> DispatchError {
    DispatchError::new(
        "team_host_unavailable",
        "The publishing computer cannot start a chat right now.",
    )
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
        assert_eq!(
            new_chat(&p, r#"{"title":"Fictional","requestId":"new-fixture"}"#)
                .unwrap_err()
                .code,
            "team_agent_runs_unavailable"
        );
    }
}
