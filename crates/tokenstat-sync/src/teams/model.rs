// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde::{Deserialize, Serialize};
pub use tokenstat_identity::teams::{TeamCapability, TeamTicket};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrganizationRole {
    Owner,
    Admin,
    Member,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InvitationRole {
    Admin,
    Member,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RepositoryRole {
    Viewer,
    Contributor,
    Maintainer,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrganizationState {
    Active,
    Paused,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Person {
    pub id: String,
    pub name: String,
    pub handle: Option<String>,
    pub avatar: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Organization {
    pub id: String,
    pub slug: String,
    pub name: String,
    pub owner_id: String,
    pub role: OrganizationRole,
    pub revision: u64,
    pub epoch: u64,
    pub state: OrganizationState,
    pub eligible: bool,
    pub created_at: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnershipRequest {
    pub from_user_id: String,
    pub to_user_id: String,
    pub expires_at: String,
    pub revision: u64,
    pub current: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrganizationDetails {
    pub organization: Organization,
    pub ownership_request: Option<OwnershipRequest>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    #[serde(flatten)]
    pub person: Person,
    pub role: OrganizationRole,
    pub revision: u64,
    pub eligible: bool,
    pub joined_at: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repository {
    pub id: String,
    pub organization_id: String,
    pub name: String,
    pub role: Option<RepositoryRole>,
    pub revision: u64,
    pub created_at: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositoryMember {
    #[serde(flatten)]
    pub person: Person,
    pub role: Option<RepositoryRole>,
    pub revision: u64,
    pub eligible: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryAssignment {
    pub repository_id: String,
    pub role: RepositoryRole,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InvitationState {
    Pending,
    Accepted,
    Revoked,
    Expired,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Invitation {
    pub id: String,
    pub organization_id: String,
    pub recipient: Option<Person>,
    pub role: InvitationRole,
    pub assignments: Vec<RepositoryAssignment>,
    pub expires_at: String,
    pub revision: u64,
    pub state: InvitationState,
    pub created_at: String,
    pub organization_name: Option<String>,
    pub organization_slug: Option<String>,
}
#[derive(Clone, Deserialize)]
pub struct InvitationCreated {
    pub invitation: Invitation,
    pub secret: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InvitationPreview {
    pub invitation: Invitation,
    pub eligible: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Joined {
    pub joined: bool,
    pub organization_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Checkout {
    pub id: String,
    pub organization_id: String,
    pub repository_id: String,
    pub publisher_id: String,
    pub machine_id: String,
    pub host_key: String,
    pub revision: u64,
    pub created_at: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedChat {
    pub id: String,
    pub checkout_id: String,
    pub revision: u64,
    pub created_at: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecutionGrant {
    pub user_id: String,
    pub device_key: String,
    pub created_at: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionGrants {
    pub grants: Vec<ExecutionGrant>,
    pub revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberDevice {
    pub id: String,
    pub key: String,
    pub kind: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberDevices {
    pub devices: Vec<MemberDevice>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityEvent {
    pub id: String,
    pub actor_id: Option<String>,
    pub action: String,
    pub resource_id: Option<String>,
    pub at: String,
}

macro_rules! paged {
    ($name:ident, $field:ident, $item:ty) => {
        #[derive(Debug, Clone, Serialize, Deserialize)]
        #[serde(rename_all = "camelCase")]
        pub struct $name {
            pub $field: Vec<$item>,
            pub next_offset: Option<u32>,
        }
    };
}
paged!(Organizations, organizations, Organization);
paged!(Members, members, Member);
paged!(Repositories, repositories, Repository);
paged!(RepositoryMembers, members, RepositoryMember);
paged!(Invitations, invitations, Invitation);
paged!(Checkouts, checkouts, Checkout);
paged!(SharedChats, shares, SharedChat);
paged!(Activity, events, ActivityEvent);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub enabled: bool,
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub scopes: Vec<String>,
    #[serde(default)]
    pub authorization_required: bool,
    pub authorization_path: Option<String>,
    pub device_key: Option<String>,
    #[serde(default)]
    pub ticket_lifetime_seconds: u32,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionTicket {
    pub ticket: TeamTicket,
    pub expires_at: String,
    pub host_key: String,
    pub capabilities: Vec<TeamCapability>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamPrincipal {
    #[serde(flatten)]
    pub person: Person,
    pub device_key: String,
    pub organization_id: String,
    pub repository_id: String,
    pub checkout_id: String,
    pub host_key: String,
    pub publisher_id: String,
    pub share_id: Option<String>,
    pub epoch: u64,
    pub capabilities: Vec<TeamCapability>,
    pub role: RepositoryRole,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateOrganization {
    pub name: String,
    pub slug: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Rename {
    pub name: String,
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Revision {
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeleteOrganization {
    pub confirm_name: String,
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChangeMemberRole {
    pub role: InvitationRole,
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InviteMember {
    pub handle: String,
    pub role: InvitationRole,
    pub assignments: Vec<RepositoryAssignment>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChangeRepositoryAccess {
    pub role: Option<RepositoryRole>,
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TransferOwnership {
    pub user_id: String,
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SetExecutionGrant {
    pub user_id: String,
    pub device_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine_id: Option<String>,
    pub allow: bool,
    pub expected_revision: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub acknowledge_host_access: Option<bool>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RequestTicket {
    pub organization_id: String,
    pub checkout_id: String,
    pub capabilities: Vec<TeamCapability>,
    pub share_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Deleted {
    pub deleted: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Removed {
    pub removed: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Withdrawn {
    pub withdrawn: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberRoleReply {
    pub role: InvitationRole,
    pub revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositoryAccessReply {
    pub role: Option<RepositoryRole>,
    pub revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionReply {
    pub allowed: bool,
    pub revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferPending {
    pub pending: bool,
    pub user_id: String,
    pub expires_at: String,
    pub revision: u64,
}
