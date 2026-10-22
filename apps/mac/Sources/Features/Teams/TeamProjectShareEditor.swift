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
    var initialWorkspace: TeamLocalWorkspace? = nil
    var onShared: ((TeamRepository, TeamLocalPublication) -> Void)? = nil
    var onStateChange: ((Bool, Bool) -> Void)? = nil
    var teamPicker: AnyView? = nil
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
    @State private var members: [TeamMember] = []
    @State private var includedMembers: Set<String> = []
    @State private var membersLoaded = false
    @State private var accessRole: TeamRepositoryRole = .contributor
    @State private var detailsExpanded = false
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canCreate: Bool { organization?.role.canManage == true && organization?.isActive == true }
    private var projectChoices: [TeamRepository] {
        guard store.mutationContext == context else { return [] }
        let current = store.directory?.repositories.repositories.filter { $0.organizationId == context.organizationId } ?? []
        return current + repositories.filter { old in !current.contains { $0.id == old.id } }
    }
    private var shareable: [TeamRepository] {
        projectChoices.filter { $0.role == .contributor || $0.role == .maintainer }
    }
    private var matchingProject: TeamRepository? {
        let key = trimmedName.precomposedStringWithCanonicalMapping.lowercased()
        return shareable.first { $0.name.precomposedStringWithCanonicalMapping.lowercased() == key }
    }
    private var workspace: TeamLocalWorkspace? { workspaces.first { $0.id == workspaceId } }
    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var targetName: String {
        repositoryId.flatMap { id in projectChoices.first { $0.id == id }?.name } ?? trimmedName
    }
    private var valid: Bool {
        guard workspace != nil, confirmed else { return false }
        if let repositoryId { return shareable.contains { $0.id == repositoryId } }
        return canCreate && membersLoaded && (created?.name == trimmedName || matchingProject == nil) && !trimmedName.isEmpty && trimmedName.utf16.count <= 80
    }

    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.share_project"), subtitle: initialWorkspace?.name ?? organization?.name ?? "", icon: .connect,
            submitTitle: L10n.text("common.teams.share_project"), submitIcon: .connect, valid: valid && !loading,
            saving: saving || store.isMutating, error: error, submit: share) {
            if let teamPicker { teamPicker }
            if initialWorkspace == nil {
              Text(L10n.text("common.teams.share_project_detail")).font(Theme.body).foregroundStyle(.secondary)
              TeamPickerField(title: L10n.text("common.teams.project"), selection: $workspaceId) {
                Text(L10n.text("common.teams.choose_project")).tag(Optional<String>.none)
                ForEach(workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
            }.disabled(loading || saving || created != nil).accessibilityIdentifier("team.project.picker")
            }
            if initialWorkspace == nil, let workspace {
                Text(workspace.path).font(Theme.mono(12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if initialWorkspace == nil && workspacesNext != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await load(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving)
            }
            if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
            if !loading && workspaces.isEmpty { TeamNotice(message: L10n.text("common.teams.no_local_checkouts")) }
            if initialWorkspace == nil || !canCreate { targetFields }
            else {
                DisclosureGroup(L10n.text("common.teams.project_details"), isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        targetFields
                        if let workspace { Text(workspace.path).font(Theme.mono(12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.top, Theme.Space.s)
                }
            }
            if repositoryId == nil, let matchingProject, created == nil {
                TeamNotice(message: L10n.text("common.teams.project_already_exists", matchingProject.name))
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("common.teams.use_existing_project", matchingProject.name), .connect) {
                        repositoryId = matchingProject.id; detailsExpanded = false
                    }.buttonStyle(TeamButtonStyle()).accessibilityIdentifier("team.project.use_existing")
                    Button(L10n.text("common.teams.choose_another_project_name"), .edit) { detailsExpanded = true; nameFocused = true }
                        .buttonStyle(TeamButtonStyle())
                }
            }
            if repositoryId == nil && canCreate {
                if created != nil && !saving { TeamNotice(message: L10n.text("common.teams.project_setup_partial"), warning: true) }
                Text(L10n.text("common.teams.project_access_review")).font(Theme.callout).foregroundStyle(.secondary)
                if !membersLoaded { ProgressView().controlSize(.small) }
                if !membersLoaded && error != nil {
                    Button(L10n.text("common.retry"), .refresh) { Task { await loadMembers() } }.buttonStyle(TeamButtonStyle())
                }
                ForEach(members) { member in
                    Toggle(isOn: Binding(get: { includedMembers.contains(member.id) }, set: { included in
                        if included { includedMembers.insert(member.id) } else { includedMembers.remove(member.id) }
                        confirmed = false
                    })) {
                        HStack {
                            TeamPersonLabel(id: member.id, name: member.name, handle: member.handle, avatar: member.avatar, owner: context.owner)
                            if !member.eligible { Text(L10n.text("common.teams.needs_patron")).font(Theme.callout).foregroundStyle(.secondary) }
                        }
                    }.toggleStyle(.checkboxForTeam).disabled(saving || created != nil || !member.eligible)
                }
                if !members.isEmpty {
                    TeamPickerField(title: L10n.text("common.teams.access_level"), selection: $accessRole) {
                        Text(L10n.text("common.teams.project_collaborate")).tag(TeamRepositoryRole.contributor)
                        Text(L10n.text("common.teams.project_read_comment")).tag(TeamRepositoryRole.viewer)
                    }.disabled(saving || created != nil)
                }
            } else if repositoryId == nil {
                TeamNotice(message: L10n.text("common.teams.share_project_existing_only"))
            } else {
                TeamNotice(message: L10n.text("common.teams.project_existing_access"))
            }
            if !deviceName.isEmpty {
                LabeledContent(L10n.text("common.teams.computer"), value: deviceName)
            }
            if initialWorkspace != nil {
                Text(L10n.text("common.teams.project_sharing_review")).font(Theme.callout).foregroundStyle(.secondary)
            } else {
                TeamNotice(message: L10n.text("common.teams.checkout_share_detail"))
                Text(L10n.text("common.teams.checkout_share_exclusions")).font(Theme.body).foregroundStyle(.secondary)
            }
            if workspace != nil && !targetName.isEmpty {
                Toggle(L10n.text("common.teams.checkout_share_confirm", targetName), isOn: $confirmed)
                    .toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.project.confirm")
            }
        }
        .task {
            if !canCreate { repositoryId = shareable.first?.id }
            if let initialWorkspace {
                workspaces = [initialWorkspace]; workspaceId = initialWorkspace.id
                newName = initialWorkspace.name
            } else {
                await load(more: false)
            }
            if canCreate { await loadMembers() }
        }
        .onChange(of: workspaceId) { _, _ in
            confirmed = false
            if !nameEdited { newName = workspace?.name ?? "" }
        }
        .onChange(of: repositoryId) { _, _ in confirmed = false }
        .onChange(of: accessRole) { _, _ in confirmed = false }
        .onChange(of: saving) { _, value in onStateChange?(value, created != nil) }
        .interactiveDismissDisabled(saving)
    }

    private var targetFields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TeamPickerField(title: L10n.text("common.teams.shared_as"), selection: $repositoryId) {
                if canCreate { Text(L10n.text("common.teams.new_repository")).tag(Optional<String>.none) }
                ForEach(shareable) { repository in Text(repository.name).tag(Optional(repository.id)) }
            }.disabled(saving || created != nil).accessibilityIdentifier("team.project.repository")
            if repositoryId == nil && canCreate {
                TextField(L10n.text("common.teams.repository_name"), text: Binding(get: { newName }, set: { newName = $0; nameEdited = true; confirmed = false }))
                    .textFieldStyle(ThemedFieldStyle()).disabled(saving || created != nil).focused($nameFocused).accessibilityIdentifier("team.project.name")
            }
            if store.directory?.repositories.nextOffset != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await store.loadMore(.repositories) } }
                    .buttonStyle(TeamButtonStyle()).disabled(saving || store.isLoadingDirectory || created != nil)
            }
        }
    }

    private func loadMembers() async {
        guard let organization = context.organizationId else { return }
        do {
            var offset = 0, rows: [TeamMember] = []
            while true {
                let page: TeamMembers = try await store.read("members.list", fields: ["organization": .string(organization), "page": TeamStore.page(offset: offset)], context: context)
                rows += page.members.filter { next in !rows.contains { $0.id == next.id } }
                guard let next = page.nextOffset else { break }
                guard next > offset else { throw CancellationError() }
                offset = next
            }
            members = rows.filter { $0.id != store.capabilities?.actorId }
            includedMembers = Set(members.filter(\.eligible).map(\.id)); membersLoaded = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func shareAccess(to repository: TeamRepository) async throws {
        var offset = 0
        var members: [TeamRepositoryMember] = []
        while true {
            let page: TeamRepositoryMembers = try await store.read("repositories.members", fields: ["organization": .string(repository.organizationId),
                "repository": .string(repository.id), "page": TeamStore.page(offset: offset)], context: context)
            members += page.members.filter { next in !members.contains { $0.id == next.id } }
            guard let next = page.nextOffset else { break }
            guard next > offset else { throw CancellationError() }
            offset = next
        }
        let grants = try TeamProjectAccessReview.grants(reviewed: includedMembers, role: accessRole, members: members)
        for member in grants {
            let _: JSONValue = try await store.perform("repositories.access", fields: ["organization": .string(repository.organizationId),
                "repository": .string(repository.id), "user": .string(member.id), "input": .object([
                    "role": .string(accessRole.rawValue), "expectedRevision": .uint(member.revision)])], context: context)
        }
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
                if let repositoryId, let existing = shareable.first(where: { $0.id == repositoryId }) {
                    repository = existing
                } else if let created, created.name == trimmedName {
                    repository = created
                } else {
                    let result: TeamRepositoryCreated = try await store.perform("repositories.create", fields: ["organization": .string(organizationId), "name": .string(trimmedName)], context: context)
                    repository = result.repository
                    created = repository
                }
                if repositoryId == nil { try await shareAccess(to: repository) }
                let target: [String: JSONValue] = ["organization": .string(organizationId), "repository": .string(repository.id), "workspace": .string(workspaceId)]
                let preview: TeamCheckoutPreview = try await store.read(.checkoutPreview, fields: target, context: context)
                guard preview.workspaceId == workspaceId, preview.repository.id == repository.id,
                    preview.repository.organizationId == organizationId, !preview.sharesExistingChats, !preview.allowsAgentRuns else { throw CancellationError() }
                var fields = target
                fields["preview"] = .string(preview.preview); fields["requestId"] = .string(requestId); fields["confirmSharing"] = .bool(true)
                let result: TeamCheckoutPublished = try await store.perform(.checkoutPublish, fields: fields, context: context)
                await store.reloadAfterChange()
                guard store.mutationContext == context else { return }
                if let onShared { onShared(repository, result.publication) } else { dismiss() }
            } catch is CancellationError {} catch {
                self.error = error.localizedDescription
                if (error as? TeamRequestFailure)?.code == "repository_exists" {
                    detailsExpanded = true
                    await store.reloadAfterChange()
                }
            }
        }
    }
}

struct TeamRepositoryCreated: Decodable, Sendable { let repository: TeamRepository }
