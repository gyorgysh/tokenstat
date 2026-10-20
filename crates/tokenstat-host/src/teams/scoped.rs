// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use crate::error::DispatchError;
use serde_json::{Value, json};

/// This is a closed dispatch boundary. No Team request falls through to the
/// personal archive, workspace, terminal, vault or machine-policy methods.
pub(super) fn call(method: &str, params: &str) -> Option<Result<Value, DispatchError>> {
    let principal = crate::request_context::team_principal();
    if principal.is_none() && !method.starts_with("team.") {
        return None;
    }
    Some((|| {
        let principal = principal.ok_or_else(|| {
            DispatchError::new(
                "team_context_required",
                "Open a scoped Team connection first.",
            )
        })?;
        principal.ensure_live()?;
        if method != "team.protocol" {
            return Err(DispatchError::new(
                "team_method_required",
                "This action is not available through a Team connection.",
            ));
        }
        if params.len() > 16 * 1024 {
            return Err(DispatchError::new(
                "invalid_request",
                "Check the Team request and try again.",
            ));
        }
        let body: Value = serde_json::from_str(params).map_err(|_| {
            DispatchError::new("invalid_request", "Check the Team request and try again.")
        })?;
        if !body.as_object().is_some_and(|body| body.is_empty()) {
            return Err(DispatchError::new(
                "invalid_request",
                "Check the Team request and try again.",
            ));
        }
        let scope = principal.value();
        // Content becomes available only after local publication and scoped
        // resource methods are installed. Directory consent alone grants none.
        Ok(
            json!({"version":1,"protocolVersion":crate::PROTOCOL_VERSION,"organizationId":scope.organization_id,"repositoryId":scope.repository_id,"checkoutId":scope.checkout_id,
            "sharedChats":false,"agentRuns":false}),
        )
    })())
}
