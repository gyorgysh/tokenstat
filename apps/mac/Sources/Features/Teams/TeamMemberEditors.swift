// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamInviteEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let organization: TeamOrganization?
    @State private var repositories: [TeamRepository]
    @State private var nextOffset: Int?
    @State private var handle = ""
    @State private var role: TeamOrganizationRole = .member
    @State private var assignments: [String: TeamRepositoryRole] = [:]
    @State private var created: TeamInvitationCreated?
    @State private var saving = false
    @State private var loading = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: TeamStore, context: TeamMutationContext, organization: TeamOrganization?, repositories: [TeamRepository]) {
        self.store = store; self.context = context; self.organization = organization
        _repositories = State(initialValue: repositories)
        _nextOffset = State(initialValue: store.directory?.repositories.nextOffset)
    }
    private var valid: Bool {
        let name = handle.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^@", with: "", options: .regularExpression).lowercased()
        return name.range(of: "^[a-z0-9][a-z0-9-]{1,31}$", options: .regularExpression) != nil && organization?.isActive == true
    }
    var body: some View {
        if let created {
            ThemedSheet(title: L10n.text("common.teams.invitation_ready"), subtitle: L10n.text("common.teams.invitation_send_detail"), icon: .invite, onClose: { dismiss() }) {
                TeamInvitationLink(value: created)
                TeamNotice(message: L10n.text("common.teams.invitation_expiry"))
            } actions: {
                Spacer()
                Button(L10n.text("common.done"), .approve) { dismiss() }.buttonStyle(TeamButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        } else {
            TeamEditorFrame(title: L10n.text("common.teams.invite_member"), subtitle: organization?.name ?? "", icon: .invite,
                submitTitle: L10n.text("common.teams.create_invitation"), submitIcon: .invite, valid: valid, saving: saving || store.isMutating, error: error, submit: save) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("common.teams.tokenstat_handle")).font(Theme.headline)
                    TextField(L10n.text("common.teams.handle_placeholder"), text: $handle).textFieldStyle(ThemedFieldStyle()).teamIdentifierInput()
                    Text(L10n.text("common.teams.handle_detail")).font(Theme.callout).foregroundStyle(.secondary)
                }
                Picker(L10n.text("common.teams.organization_role"), selection: $role) {
                    Text(TeamOrganizationRole.member.label).tag(TeamOrganizationRole.member)
                    if organization?.role == .owner { Text(TeamOrganizationRole.admin.label).tag(TeamOrganizationRole.admin) }
                }
                Text(role == .admin ? L10n.text("common.teams.admin_detail") : L10n.text("common.teams.member_detail")).font(Theme.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(L10n.text("common.teams.repository_access")).font(Theme.headline)
                    Text(L10n.text("common.teams.invite_repository_detail")).font(Theme.callout).foregroundStyle(.secondary)
                    ForEach(repositories) { repository in
                        Picker(repository.name, selection: Binding<TeamRepositoryRole?>(get: { assignments[repository.id] }, set: { assignments[repository.id] = $0 })) {
                            Text(L10n.text("common.teams.no_access")).tag(Optional<TeamRepositoryRole>.none)
                            ForEach(TeamRepositoryRole.allCases) { access in Text(access.label).tag(Optional(access)) }
                        }.disabled(assignments.count >= 50 && assignments[repository.id] == nil)
                    }
                    if nextOffset != nil {
                        Button(L10n.text("common.teams.load_more"), .more) { loadMore() }.buttonStyle(TeamButtonStyle()).disabled(loading)
                    }
                    TeamNotice(message: L10n.text("common.teams.execution_separate"))
                }
            }
        }
    }
    private func loadMore() {
        guard let org = context.organizationId, let offset = nextOffset else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let result: TeamRepositories = try await store.read("repositories.list", fields: ["organization":.string(org),"page":TeamStore.page(offset: offset)], context: context)
                let existing = Set(repositories.map(\.id)); repositories += result.repositories.filter { !existing.contains($0.id) }; nextOffset = result.nextOffset
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        guard let org = context.organizationId else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let access: [JSONValue] = assignments.sorted { $0.key < $1.key }.map { .object(["repositoryId":.string($0.key),"role":.string($0.value.rawValue)]) }
                let reply: TeamInvitationCreated = try await store.perform("invitations.create", fields: ["organization":.string(org),"input":.object(["handle":.string(handle),"role":.string(role.rawValue),"assignments":.array(access)])], context: context)
                created = reply; await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamMemberRoleEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let member: TeamMember
    @State private var role: TeamOrganizationRole
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: TeamStore, context: TeamMutationContext, member: TeamMember) {
        self.store = store; self.context = context; self.member = member; _role = State(initialValue: member.role)
    }
    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.change_role"), subtitle: member.name,
            submitTitle: L10n.text("common.save"), valid: role != member.role && member.role != .owner, saving: saving || store.isMutating, error: error, submit: save) {
            TeamPersonLabel(id: member.id, name: member.name, handle: member.handle, avatar: member.avatar, owner: context.owner)
            Picker(L10n.text("common.teams.organization_role"), selection: $role) {
                Text(TeamOrganizationRole.member.label).tag(TeamOrganizationRole.member)
                Text(TeamOrganizationRole.admin.label).tag(TeamOrganizationRole.admin)
            }
            Text(role == .admin ? L10n.text("common.teams.admin_detail") : L10n.text("common.teams.member_detail")).font(Theme.body).foregroundStyle(.secondary)
            TeamNotice(message: L10n.text("common.teams.role_content_separate"))
        }
    }
    private func save() {
        guard let org = context.organizationId else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let _: JSONValue = try await store.perform("members.role", fields: ["organization":.string(org),"user":.string(member.id),"input":.object(["role":.string(role.rawValue),"expectedRevision":.uint(member.revision)])], context: context)
                dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamRemovalEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let organization: TeamOrganization?
    let member: TeamMember?
    let deleting: Bool
    let leaving: Bool
    @State private var confirmation = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var title: String { (deleting ? L10n.text("common.teams.delete_organization") : leaving ? L10n.text("common.teams.leave_organization") : L10n.text("common.teams.remove_member")) }
    private var valid: Bool {
        guard let organization else { return false }
        if deleting { return organization.role == .owner && confirmation == organization.name }
        if leaving { return organization.role != .owner }
        return member != nil && member?.role != .owner
    }
    var body: some View {
        TeamEditorFrame(title: title, subtitle: member?.name ?? organization?.name ?? "", submitTitle: title, submitIcon: deleting ? .delete : leaving ? .signOut : .revoke,
            valid: valid, saving: saving || store.isMutating, destructive: true, error: error, submit: save) {
            TeamNotice(message: (deleting ? L10n.text("common.teams.delete_confirmation_detail") : leaving ? L10n.text("common.teams.leave_confirmation_detail") : L10n.text("common.teams.remove_confirmation_detail")), warning: true)
            if deleting, let organization {
                Text(L10n.text("common.teams.type_name_to_delete", organization.name)).font(Theme.body)
                TextField(L10n.text("common.teams.organization_name"), text: $confirmation).textFieldStyle(ThemedFieldStyle()).autocorrectionDisabled()
            }
        }
    }
    private func save() {
        guard let organization, let org = context.organizationId else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                if deleting {
                    let _: JSONValue = try await store.perform("organizations.delete", fields: ["organization":.string(org),"input":.object(["expectedRevision":.uint(organization.revision),"confirmName":.string(confirmation)])], context: context)
                } else {
                    guard let user = leaving ? store.capabilities?.actorId : member?.id else { throw CancellationError() }
                    let revision = leaving ? organization.membershipRevision : member?.revision ?? 0
                    let _: JSONValue = try await store.perform("members.remove", fields: ["organization":.string(org),"user":.string(user),"input":.object(["expectedRevision":.uint(revision)])], context: context)
                }
                if deleting || leaving { store.select(nil) }
                dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamInvitationEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let invitation: TeamInvitation
    let onAccount: () -> Void
    @State private var preview: TeamInvitationPreview?
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.join_organization"), subtitle: preview?.invitation.organizationName ?? invitation.organizationName ?? "", icon: .invite,
            submitTitle: L10n.text("common.teams.join_organization"), submitIcon: .approve, valid: preview?.eligible == true && preview?.invitation.state == "pending", saving: saving || store.isMutating, error: error, submit: accept) {
            if let preview {
                LabeledContent(L10n.text("common.teams.your_role"), value: preview.invitation.role.label)
                Text(L10n.text("common.teams.invitation_assignments", String(preview.invitation.assignments.count))).font(Theme.body)
                TeamNotice(message: L10n.text("common.teams.join_content_detail"))
                if !preview.eligible {
                    TeamNotice(message: L10n.text("common.teams.patron_invitation"), warning: true)
                    Button(L10n.text("common.teams.view_plan"), .plans) { dismiss(); onAccount() }.buttonStyle(TeamButtonStyle())
                }
                if preview.invitation.state != "pending" { TeamNotice(message: L10n.text("common.teams.invitation_unavailable"), warning: true) }
            } else if error != nil {
                Button(L10n.text("common.retry"), .refresh) { Task { await loadPreview() } }.buttonStyle(TeamButtonStyle())
            } else { ProgressView().controlSize(.small) }
        }
        .task { await loadPreview() }
    }
    private func loadPreview() async {
        error = nil
        do { preview = try await store.read("inbox.get", fields: ["invitation":.string(invitation.id)], context: context) }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func accept() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let reply: TeamJoined = try await store.perform("inbox.accept", fields: ["invitation":.string(invitation.id)], context: context)
                let details: TeamOrganizationDetails = try await store.read("organizations.get", fields: ["organization":.string(reply.organizationId)], context: context)
                store.select(details.organization); dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
private struct TeamJoined: Decodable, Sendable { let joined: Bool; let organizationId: String }

struct TeamInvitationActionEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let invitation: TeamInvitation
    let renewing: Bool
    @State private var created: TeamInvitationCreated?
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var title: String { renewing ? L10n.text("common.teams.new_invitation_link") : L10n.text("common.teams.revoke_invitation") }
    var body: some View {
        if let created {
            ThemedSheet(title: L10n.text("common.teams.invitation_ready"), subtitle: L10n.text("common.teams.invitation_send_detail"), icon: .invite, onClose: { dismiss() }) {
                TeamInvitationLink(value: created)
                TeamNotice(message: L10n.text("common.teams.invitation_expiry"))
            } actions: {
                Spacer()
                Button(L10n.text("common.done"), .approve) { dismiss() }.buttonStyle(TeamButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        } else {
            TeamEditorFrame(title: title, subtitle: invitation.recipient?.name ?? "", icon: .invite, submitTitle: title, submitIcon: renewing ? .refresh : .revoke,
                saving: saving || store.isMutating, destructive: !renewing, error: error, submit: save) {
                TeamNotice(message: renewing ? L10n.text("common.teams.renew_invitation_detail") : L10n.text("common.teams.revoke_invitation_detail"), warning: true)
            }
        }
    }
    private func save() {
        guard let org = context.organizationId else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let fields: [String: JSONValue] = ["organization":.string(org),"invitation":.string(invitation.id),"input":.object(["expectedRevision":.uint(invitation.revision)])]
                if renewing { created = try await store.perform("invitations.renew", fields: fields, context: context) }
                else { let _: JSONValue = try await store.perform("invitations.revoke", fields: fields, context: context); dismiss() }
                await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
