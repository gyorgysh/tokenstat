// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::{api_error, serialize};
use crate::error::DispatchError;
use serde::Deserialize;
use serde_json::{Value, json};
use tokenstat_sync::teams::*;

pub(super) enum Request {
    Capabilities,
    AuthorizationPreview,
    PrepareAuthorization {
        expected_device_key: String,
    },
    Directory(Operation),
    #[cfg(feature = "local-host")]
    Sharing(super::sharing::Request),
}
pub(super) fn parse(method: &str, params: &str) -> Result<Request, DispatchError> {
    let invalid =
        || DispatchError::new("invalid_request", "Check the Teams request and try again.");
    if params.len() > 16 * 1024 {
        return Err(invalid());
    }
    let mut body: Value = serde_json::from_str(params).map_err(|_| invalid())?;
    let object = body.as_object_mut().ok_or_else(invalid)?;
    // These are verified by AccountSnapshot before any network operation.
    object.remove("_accountScope");
    object.remove("_accountSession");
    #[cfg(feature = "local-host")]
    if let Some(request) = super::sharing::parse(method, Value::Object(object.clone())) {
        return request.map(Request::Sharing);
    }
    match method {
        "teams.capabilities" if object.is_empty() => Ok(Request::Capabilities),
        "teams.authorizationPreview" if object.is_empty() => Ok(Request::AuthorizationPreview),
        "teams.prepareAuthorization"
            if object.len() == 2 && object.get("confirmMetadata") == Some(&Value::Bool(true)) =>
        {
            let key = object
                .get("expectedDeviceKey")
                .and_then(Value::as_str)
                .filter(|key| key.len() == 64 && key.bytes().all(|b| b.is_ascii_hexdigit()))
                .ok_or_else(invalid)?;
            Ok(Request::PrepareAuthorization {
                expected_device_key: key.to_owned(),
            })
        }
        "teams.directory" => serde_json::from_value(body)
            .map(Request::Directory)
            .map_err(|_| invalid()),
        "teams.capabilities" | "teams.authorizationPreview" | "teams.prepareAuthorization" => {
            Err(invalid())
        }
        _ => Err(DispatchError::new(
            "unknown_method",
            "This Team method is not available.",
        )),
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", deny_unknown_fields)]
pub(super) enum Operation {
    #[serde(rename = "organizations.list")]
    Organizations {
        #[serde(default)]
        page: Page,
    },
    #[serde(rename = "organizations.get")]
    Organization { organization: String },
    #[serde(rename = "organizations.create")]
    CreateOrganization { input: CreateOrganization },
    #[serde(rename = "organizations.rename")]
    RenameOrganization { organization: String, input: Rename },
    #[serde(rename = "organizations.delete")]
    DeleteOrganization {
        organization: String,
        input: DeleteOrganization,
    },
    #[serde(rename = "members.list")]
    Members {
        organization: String,
        #[serde(default)]
        page: Page,
    },
    #[serde(rename = "members.role")]
    MemberRole {
        organization: String,
        user: String,
        input: ChangeMemberRole,
    },
    #[serde(rename = "members.remove")]
    RemoveMember {
        organization: String,
        user: String,
        input: Revision,
    },
    #[serde(rename = "ownership.request")]
    TransferOwnership {
        organization: String,
        input: TransferOwnership,
    },
    #[serde(rename = "ownership.accept")]
    AcceptOwnership {
        organization: String,
        input: OwnershipApproval,
    },
    #[serde(rename = "ownership.cancel")]
    CancelOwnership {
        organization: String,
        input: OwnershipApproval,
    },
    #[serde(rename = "repositories.list")]
    Repositories {
        organization: String,
        #[serde(default)]
        page: Page,
    },
    #[serde(rename = "repositories.create")]
    CreateRepository { organization: String, name: String },
    #[serde(rename = "repositories.rename")]
    RenameRepository {
        organization: String,
        repository: String,
        input: Rename,
    },
    #[serde(rename = "repositories.members")]
    RepositoryMembers {
        organization: String,
        repository: String,
        #[serde(default)]
        page: Page,
    },
    #[serde(rename = "repositories.access")]
    RepositoryAccess {
        organization: String,
        repository: String,
        user: String,
        input: ChangeRepositoryAccess,
    },
    #[serde(rename = "invitations.list")]
    Invitations {
        organization: String,
        #[serde(default)]
        page: Page,
    },
    #[serde(rename = "invitations.create")]
    Invite {
        organization: String,
        input: InviteMember,
    },
    #[serde(rename = "invitations.renew")]
    RenewInvitation {
        organization: String,
        invitation: String,
        input: Revision,
    },
    #[serde(rename = "invitations.revoke")]
    RevokeInvitation {
        organization: String,
        invitation: String,
        input: Revision,
    },
    #[serde(rename = "inbox.list")]
    Inbox {
        #[serde(default)]
        page: Page,
    },
    #[serde(rename = "inbox.get")]
    Invitation { invitation: String },
    #[serde(rename = "inbox.accept")]
    AcceptInvitation { invitation: String },
    #[serde(rename = "checkouts.list")]
    Checkouts {
        organization: String,
        repository: String,
        #[serde(default)]
        page: Page,
    },
    #[serde(rename = "execution.list")]
    ExecutionGrants {
        organization: String,
        checkout: String,
    },
    #[serde(rename = "execution.set")]
    SetExecutionGrant {
        organization: String,
        checkout: String,
        input: SetExecutionGrant,
    },
    #[serde(rename = "execution.devices")]
    MemberDevices {
        organization: String,
        checkout: String,
        user: String,
    },
    #[serde(rename = "activity.list")]
    Activity {
        organization: String,
        #[serde(default)]
        page: Page,
    },
}

pub(super) fn perform(client: &TeamClient, operation: Operation) -> Result<Value, DispatchError> {
    macro_rules! api {
        ($call:expr) => {
            serialize($call.map_err(api_error)?)
        };
    }
    match operation {
        Operation::Organizations { page } => api!(client.organizations(page)),
        Operation::Organization { organization } => api!(client.organization(&organization)),
        Operation::CreateOrganization { input } => api!(client.create_organization(&input)),
        Operation::RenameOrganization {
            organization,
            input,
        } => api!(client.rename_organization(&organization, &input)),
        Operation::DeleteOrganization {
            organization,
            input,
        } => api!(client.delete_organization(&organization, &input)),
        Operation::Members { organization, page } => api!(client.members(&organization, page)),
        Operation::MemberRole {
            organization,
            user,
            input,
        } => api!(client.change_member_role(&organization, &user, &input)),
        Operation::RemoveMember {
            organization,
            user,
            input,
        } => api!(client.remove_member(&organization, &user, input)),
        Operation::TransferOwnership {
            organization,
            input,
        } => api!(client.transfer_ownership(&organization, &input)),
        Operation::AcceptOwnership {
            organization,
            input,
        } => api!(client.accept_ownership(&organization, input)),
        Operation::CancelOwnership {
            organization,
            input,
        } => api!(client.cancel_ownership(&organization, input)),
        Operation::Repositories { organization, page } => {
            api!(client.repositories(&organization, page))
        }
        Operation::CreateRepository { organization, name } => {
            api!(client.create_repository(&organization, &name))
        }
        Operation::RenameRepository {
            organization,
            repository,
            input,
        } => api!(client.rename_repository(&organization, &repository, &input)),
        Operation::RepositoryMembers {
            organization,
            repository,
            page,
        } => api!(client.repository_members(&organization, &repository, page)),
        Operation::RepositoryAccess {
            organization,
            repository,
            user,
            input,
        } => api!(client.repository_access(&organization, &repository, &user, &input)),
        Operation::Invitations { organization, page } => {
            api!(client.invitations(&organization, page))
        }
        Operation::Invite {
            organization,
            input,
        } => invitation_created(
            client,
            client.invite(&organization, &input).map_err(api_error)?,
        ),
        Operation::RenewInvitation {
            organization,
            invitation,
            input,
        } => invitation_created(
            client,
            client
                .renew_invitation(&organization, &invitation, input)
                .map_err(api_error)?,
        ),
        Operation::RevokeInvitation {
            organization,
            invitation,
            input,
        } => api!(client.revoke_invitation(&organization, &invitation, input)),
        Operation::Inbox { page } => api!(client.inbox(page)),
        Operation::Invitation { invitation } => api!(client.invitation(&invitation)),
        Operation::AcceptInvitation { invitation } => api!(client.accept_invitation(&invitation)),
        Operation::Checkouts {
            organization,
            repository,
            page,
        } => api!(client.checkouts(&organization, &repository, page)),
        Operation::ExecutionGrants {
            organization,
            checkout,
        } => api!(client.execution_grants(&organization, &checkout)),
        Operation::SetExecutionGrant {
            organization,
            checkout,
            input,
        } => api!(client.set_execution_grant(&organization, &checkout, &input)),
        Operation::MemberDevices {
            organization,
            checkout,
            user,
        } => api!(client.member_devices(&organization, &checkout, &user)),
        Operation::Activity { organization, page } => api!(client.activity(&organization, page)),
    }
}
fn invitation_created(
    client: &TeamClient,
    value: InvitationCreated,
) -> Result<Value, DispatchError> {
    let id = value.invitation.id.as_str();
    if !id
        .strip_prefix("invite_")
        .is_some_and(|suffix| suffix.len() == 32 && suffix.bytes().all(|b| b.is_ascii_hexdigit()))
        || value.secret.len() != 43
        || !value
            .secret
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    {
        return Err(api_error(TeamError::InvalidResponse));
    }
    let url = format!(
        "{}/teams/invitations/{id}#{}",
        client.origin(),
        value.secret
    );
    Ok(json!({"invitation":value.invitation,"invitationURL":url}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn typed_management_rejects_content_transport_and_identity_injection() {
        for body in [
            json!({"operation":"organizations.create","input":{"name":"Example","slug":"example","path":"private"}}),
            json!({"operation":"members.role","organization":"org_fixture","user":"fixture_member","input":{"role":"owner","expectedRevision":1}}),
            json!({"operation":"repositories.list","organization":"org_fixture","actorId":"another-person"}),
            json!({"operation":"checkouts.publish","path":"private"}),
            json!({"operation":"connection.ticket","capabilities":["run"]}),
        ] {
            assert!(parse("teams.directory", &body.to_string()).is_err());
        }
        assert!(parse("teams.prepareAuthorization", "{}").is_err());
        assert!(
            parse(
                "teams.prepareAuthorization",
                r#"{"confirmMetadata":true,"machine":"another-device"}"#
            )
            .is_err()
        );
        assert!(
            parse(
                "teams.prepareAuthorization",
                &json!({"confirmMetadata":true,"expectedDeviceKey":"ab".repeat(32)}).to_string()
            )
            .is_ok()
        );
        assert!(parse("teams.prepareAuthorization", r#"{"confirmMetadata":true}"#).is_err());
        assert!(parse("teams.authorizationPreview", "{}").is_ok());
        assert!(parse("teams.directory", r#"{"operation":"organizations.list","_accountSession":"fixture","_accountScope":{"kind":"account"}}"#).is_ok());
    }
    #[test]
    fn every_management_method_refuses_an_authenticated_peer_before_loading_credentials() {
        crate::request_context::with_remote_peer("fixture-peer", || {
            for method in [
                "teams.capabilities",
                "teams.authorizationPreview",
                "teams.prepareAuthorization",
                "teams.directory",
                "teams.unknown",
            ] {
                let error = super::super::call(method, "{}").unwrap().unwrap_err();
                assert_eq!(error.code, "local_only");
            }
        });
    }
    #[test]
    fn local_requests_need_the_current_account_receipt_before_loading_credentials() {
        for (method, params) in [
            ("teams.capabilities", "{}"),
            ("teams.authorizationPreview", "{}"),
            (
                "teams.prepareAuthorization",
                r#"{"confirmMetadata":true,"expectedDeviceKey":"abababababababababababababababababababababababababababababababab"}"#,
            ),
            ("teams.directory", r#"{"operation":"organizations.list"}"#),
        ] {
            let error = super::super::call(method, params).unwrap().unwrap_err();
            assert_eq!(error.code, "account_changed");
        }
    }
}
