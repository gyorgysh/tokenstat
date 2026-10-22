// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use crate::error::DispatchError;
use crate::remote::{TeamReadMethod, TeamReadParams};
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
        if matches!(
            method,
            "team.chat.ask"
                | "team.chat.ask.review"
                | "team.chat.ask.stop"
                | "team.chat.ask.status"
                | "team.lanes.land"
                | "team.lanes.discard"
                | "team.chat.new"
        ) {
            #[cfg(feature = "local-host")]
            return match method {
                "team.chat.ask.review" => super::scoped_runs::review(&principal, params),
                "team.chat.ask.stop" => super::runs::stop(&principal, params),
                "team.chat.ask.status" => super::runs::status(&principal, params),
                "team.lanes.land" => super::lanes::land_ready(&principal, params),
                "team.lanes.discard" => super::lanes::discard(&principal, params),
                "team.chat.new" => super::scoped_runs::new_chat(&principal, params),
                _ => super::scoped_runs::send(&principal, params),
            };
            #[cfg(not(feature = "local-host"))]
            return Err(DispatchError::new(
                "host_required",
                "Open this chat on its publishing computer.",
            ));
        }
        if method == "team.chat.comment" {
            if params.len() > 16 * 1024 {
                return Err(DispatchError::new(
                    "invalid_comment",
                    "Enter a shorter comment and try again.",
                ));
            }
            let input: crate::remote::TeamCommentInput =
                serde_json::from_str(params).map_err(|_| {
                    DispatchError::new("invalid_comment", "Check the comment and try again.")
                })?;
            #[cfg(feature = "local-host")]
            return super::scoped_comments::send(&principal, &input);
            #[cfg(not(feature = "local-host"))]
            {
                let _ = input;
                return Err(DispatchError::new(
                    "host_required",
                    "Open this chat on its publishing computer.",
                ));
            }
        }
        let operation = serde_json::from_value::<TeamReadMethod>(json!(method)).map_err(|_| {
            DispatchError::new(
                "team_method_required",
                "This action is not available through a Team connection.",
            )
        })?;
        if params.len() > 16 * 1024 {
            return Err(DispatchError::new(
                "invalid_request",
                "Check the Team request and try again.",
            ));
        }
        let body: TeamReadParams = serde_json::from_str(params).map_err(|_| {
            DispatchError::new("invalid_request", "Check the Team request and try again.")
        })?;
        if !body.validate(operation, principal.value().share_id.as_deref()) {
            return Err(DispatchError::new(
                "invalid_request",
                "Check the Team request and try again.",
            ));
        }
        let scope = principal.value();
        if operation == TeamReadMethod::ChatReceipt {
            #[cfg(feature = "local-host")]
            return super::scoped_comments::status(
                &principal,
                body.client_message_id.as_deref().unwrap_or_default(),
            );
            #[cfg(not(feature = "local-host"))]
            return Err(DispatchError::new(
                "host_required",
                "Open this chat on its publishing computer.",
            ));
        }
        if operation == TeamReadMethod::Lanes {
            #[cfg(feature = "local-host")]
            {
                // Same gates as checkout info: a read capability, this exact
                // publication, and its folder unchanged on this computer.
                if !scope
                    .capabilities
                    .contains(&tokenstat_sync::teams::TeamCapability::Read)
                {
                    return Err(DispatchError::new(
                        "team_method_required",
                        "This action is not available through a Team connection.",
                    ));
                }
                super::publications::Store::current_for(&principal)?;
                let result = super::lanes::list(&scope.checkout_id, scope.share_id.as_deref())?;
                principal.ensure_live()?;
                return Ok(result);
            }
            #[cfg(not(feature = "local-host"))]
            return Err(DispatchError::new(
                "host_required",
                "Open this checkout on its publishing computer.",
            ));
        }
        if operation == TeamReadMethod::ChatCatalog {
            #[cfg(feature = "local-host")]
            return super::catalog::call(&principal, &body);
            #[cfg(not(feature = "local-host"))]
            return Err(DispatchError::new(
                "host_required",
                "Open this checkout on its publishing computer.",
            ));
        }
        if matches!(
            operation,
            TeamReadMethod::ChatDetails
                | TeamReadMethod::ChatEvents
                | TeamReadMethod::ChatAttachment
        ) {
            #[cfg(feature = "local-host")]
            return super::scoped_chats::call(&principal, operation, &body);
            #[cfg(not(feature = "local-host"))]
            return Err(DispatchError::new(
                "host_required",
                "Open this chat on its publishing computer.",
            ));
        }
        #[cfg(feature = "local-host")]
        if method == "team.checkout.info" {
            let row = super::publications::Store::current_for(&principal)?;
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
        Ok(
            json!({"version":1,"protocolVersion":crate::PROTOCOL_VERSION,"issuer":principal.issuer(),"organizationId":scope.organization_id,"repositoryId":scope.repository_id,"checkoutId":scope.checkout_id,"checkoutInfo":cfg!(feature="local-host"),
            "sharedChats":cfg!(feature="local-host"),"chatCatalog":cfg!(feature="local-host"),"comments":cfg!(feature="local-host"),"agentRuns":super::agent_runs_ready(),"lanes":cfg!(feature="local-host")}),
        )
    })())
}
