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
        if !matches!(method, "team.protocol" | "team.checkout.info") {
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
        #[cfg(feature = "local-host")]
        if method == "team.checkout.info" {
            let owner = super::publications::Owner {
                issuer: principal.issuer().into(),
                publisher_id: scope.publisher_id.clone(),
                host_key: scope.host_key.clone(),
            };
            let row = super::publications::Store::capture()?.resolve(
                &owner,
                &scope.organization_id,
                &scope.repository_id,
                &scope.checkout_id,
            )?;
            let workspace = crate::workspaces::get(&row.workspace_id).map_err(|_| {
                DispatchError::new(
                    "checkout_not_shared",
                    "This checkout is no longer registered on this computer.",
                )
            })?;
            if super::publications::Folder::capture(&workspace.path)? != row.folder {
                return Err(DispatchError::new(
                    "checkout_changed",
                    "This checkout changed. Ask its publisher to review sharing.",
                ));
            }
            principal.ensure_live()?;
            return Ok(
                json!({"checkoutId":row.id,"organizationId":row.organization_id,"repositoryId":row.repository_id,"deviceName":tokenstat_identity::machine_label(),"state":"available"}),
            );
        }
        #[cfg(not(feature = "local-host"))]
        if method == "team.checkout.info" {
            return Err(DispatchError::new(
                "host_required",
                "Open this checkout on its publishing computer.",
            ));
        }
        // Content becomes available only after local publication and scoped
        // resource methods are installed. Directory consent alone grants none.
        Ok(
            json!({"version":1,"protocolVersion":crate::PROTOCOL_VERSION,"issuer":principal.issuer(),"organizationId":scope.organization_id,"repositoryId":scope.repository_id,"checkoutId":scope.checkout_id,"checkoutInfo":cfg!(feature="local-host"),
            "sharedChats":false,"agentRuns":false}),
        )
    })())
}
