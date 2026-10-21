// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Share a project this computer already has. A Team repository is what the
/// team sees, and the first share of a project names one after its folder, so
/// nobody has to create an empty repository first and attach a folder later.
struct TeamProjectShareEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let organization: TeamOrganization?
    let repositories: [TeamRepository]
    @State private var workspaces: [TeamLocalWorkspace] = []
    @State private var workspacesNext: Int?
    @State private var deviceName = ""
    @State private var workspaceId: String?
    /// `nil` shares as a new repository named `newName`.
    @State private var repositoryId: String?
    @State private var newName = ""
    @State private var nameEdited = false
    /// Created on an earlier attempt that then failed to share.
    @State private var created: TeamRepository?
    @State private var confirmed = false
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var requestId = UUID().uuidString
    @Environment(\.dismiss) private var dismiss

    private var canCreate: Bool { organization?.role.canManage == true && organization?.isActive == true }
    private var shareable: [TeamRepository] {
        repositories.filter { $0.role == .contributor || $0.role == .maintainer }
    }
    private var workspace: TeamLocalWorkspace? { workspaces.first { $0.id == workspaceId } }
    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var targetName: String {
        repositoryId.flatMap { id in repositories.first { $0.id == id }?.name } ?? trimmedName
    }
    private var valid: Bool {
        guard workspace != nil, confirmed else { return false }
        if repositoryId != nil { return true }
        return canCreate && !trimmedName.isEmpty && trimmedName.utf16.count <= 80
    }

    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.share_project"), subtitle: organization?.name ?? "", icon: .connect,
            submitTitle: L10n.text("common.teams.share_project"), submitIcon: .connect, valid: valid && !loading,
            saving: saving || store.isMutating, error: error, submit: share) {
            Text(L10n.text("common.teams.share_project_detail")).font(Theme.body).foregroundStyle(.secondary)
            TeamPickerField(title: L10n.text("common.teams.project"), selection: $workspaceId) {
                Text(L10n.text("common.teams.choose_project")).tag(Optional<String>.none)
                ForEach(workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
            }.disabled(loading || saving).accessibilityIdentifier("team.project.picker")
            if let workspace {
                Text(workspace.path).font(Theme.mono(12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if workspacesNext != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await load(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving)
            }
            if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
            if !loading && workspaces.isEmpty { TeamNotice(message: L10n.text("common.teams.no_local_checkouts")) }
            TeamPickerField(title: L10n.text("common.teams.shared_as"), selection: $repositoryId) {
                if canCreate { Text(L10n.text("common.teams.new_repository")).tag(Optional<String>.none) }
                ForEach(shareable) { repository in Text(repository.name).tag(Optional(repository.id)) }
            }.disabled(saving).accessibilityIdentifier("team.project.repository")
            if repositoryId == nil && canCreate {
                TextField(L10n.text("common.teams.repository_name"), text: Binding(get: { newName }, set: { newName = $0; nameEdited = true }))
                    .textFieldStyle(ThemedFieldStyle()).disabled(saving)
                Text(L10n.text("common.teams.repository_create_access")).font(Theme.callout).foregroundStyle(.secondary)
            } else if repositoryId == nil {
                TeamNotice(message: L10n.text("common.teams.share_project_existing_only"))
            }
            if !deviceName.isEmpty {
                LabeledContent(L10n.text("common.teams.computer"), value: deviceName)
            }
            TeamNotice(message: L10n.text("common.teams.checkout_share_detail"))
            Text(L10n.text("common.teams.checkout_share_exclusions")).font(Theme.body).foregroundStyle(.secondary)
            if workspace != nil && !targetName.isEmpty {
                Toggle(L10n.text("common.teams.checkout_share_confirm", targetName), isOn: $confirmed)
                    .toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.project.confirm")
            }
        }
        .task {
            if !canCreate { repositoryId = shareable.first?.id }
            await load(more: false)
        }
        .onChange(of: workspaceId) { _, _ in
            confirmed = false
            if !nameEdited { newName = workspace?.name ?? "" }
        }
        .onChange(of: repositoryId) { _, _ in confirmed = false }
        .interactiveDismissDisabled(saving)
    }

    private func load(more: Bool) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let result: TeamCheckoutOptions = try await store.read(.checkoutOptions, fields: ["page": TeamStore.page(offset: more ? workspacesNext ?? 0 : 0)], context: context)
            if more { let ids = Set(workspaces.map(\.id)); workspaces += result.workspaces.filter { !ids.contains($0.id) } } else { workspaces = result.workspaces }
            workspacesNext = result.nextOffset; deviceName = result.deviceName; error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func share() {
        guard valid, let workspaceId, let organizationId = context.organizationId else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                // A new repository exists from here on. If sharing then fails,
                // it stays listed and the project can be shared into it again.
                let repository: TeamRepository
                if let repositoryId, let existing = repositories.first(where: { $0.id == repositoryId }) {
                    repository = existing
                } else if let created, created.name == trimmedName {
                    repository = created
                } else {
                    let result: TeamRepositoryCreated = try await store.perform("repositories.create", fields: ["organization": .string(organizationId), "name": .string(trimmedName)], context: context)
                    repository = result.repository
                    created = repository
                }
                let target: [String: JSONValue] = ["organization": .string(organizationId), "repository": .string(repository.id), "workspace": .string(workspaceId)]
                let preview: TeamCheckoutPreview = try await store.read(.checkoutPreview, fields: target, context: context)
                guard preview.workspaceId == workspaceId, preview.repository.id == repository.id,
                    preview.repository.organizationId == organizationId, !preview.sharesExistingChats, !preview.allowsAgentRuns else { throw CancellationError() }
                var fields = target
                fields["preview"] = .string(preview.preview); fields["requestId"] = .string(requestId); fields["confirmSharing"] = .bool(true)
                let _: TeamCheckoutPublished = try await store.perform(.checkoutPublish, fields: fields, context: context)
                dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamRepositoryCreated: Decodable, Sendable { let repository: TeamRepository }
