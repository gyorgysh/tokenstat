// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The folder is already chosen. Team selection and the sharing review live
/// together, rather than sending someone through account and repository setup.
struct TeamFolderShareView: View {
    @Bindable var store: TeamStore
    let workspace: TeamLocalWorkspace
    let onManageTeams: () -> Void
    let onOpen: (TeamOrganization, TeamRepository, String) -> Void
    @State private var organizationId: String?
    @State private var setupLocked = false
    @State private var working = false
    @State private var savedSetup: TeamProjectSetup?
    @State private var checkedSavedSetup = false
    @State private var savedSetupError: String?
    @State private var confirmsDiscard = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.phase == .authorization {
                TeamAuthorizationEditor(store: store)
            } else if store.phase == .ready {
                if let organization = store.selectedOrganization, organization.id == organizationId,
                    let directory = store.directory, let context = store.mutationContext {
                    TeamProjectShareEditor(store: store, context: context, organization: organization,
                        repositories: directory.repositories.repositories, initialWorkspace: workspace,
                        onShared: { repository, publication in onOpen(organization, repository, publication.id) },
                        onStateChange: { busy, created in working = busy; setupLocked = busy || created }, teamPicker: AnyView(teamChooser))
                        .id(store.selectionKey)
                } else {
                    ThemedSheet(title: L10n.text("common.teams.share_project"), subtitle: workspace.name, icon: .connect, scrolls: true, onClose: { dismiss() }) {
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            teamChooser
                            if store.isLoadingDirectory { ProgressView() }
                            if let error = store.error {
                                TeamNotice(message: error, warning: true)
                                Button(L10n.text("common.retry"), .refresh) { Task { await store.refreshSelected() } }.buttonStyle(TeamButtonStyle())
                            }
                        }
                    } actions: {
                        Button(L10n.text("common.cancel"), .dismiss) { dismiss() }.buttonStyle(TeamButtonStyle()).keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(L10n.text("common.teams.manage_teams"), .team, action: onManageTeams).buttonStyle(TeamButtonStyle())
                    }
                }
            } else {
                VStack(spacing: Theme.Space.l) {
                    Text(L10n.text("common.teams.share_project")).font(Theme.title)
                    if store.phase == .loading { ProgressView() }
                    else {
                        TeamNotice(message: store.error ?? L10n.text("common.teams.retry_detail"), warning: true)
                        Button(L10n.text("common.retry"), .refresh) { Task { await store.reloadAfterChange() } }.buttonStyle(TeamButtonStyle())
                        Button(L10n.text("common.teams.manage_teams"), .team, action: onManageTeams).buttonStyle(TeamButtonStyle())
                    }
                }.padding(Theme.Space.l)
            }
        }
        .background(Theme.background)
        .onChange(of: store.owner) { _, _ in
            organizationId = nil; savedSetup = nil; checkedSavedSetup = false
            savedSetupError = nil; setupLocked = false; working = false
        }
        .onChange(of: store.phase) { _, phase in if phase != .ready { working = false; setupLocked = false } }
        .task(id: store.phase) { if store.phase == .ready { await discoverSavedSetup() } }
        .confirmationDialog(L10n.text("common.teams.project_setup_start_over"), isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(L10n.text("common.teams.project_setup_start_over"), role: .destructive) { Task { await discardSavedSetup() } }
        } message: { Text(L10n.text("common.teams.project_setup_discard_detail")) }
        .task(id: organizationId) {
            guard let organization = store.organizations.first(where: { $0.id == organizationId }) else { return }
            store.select(organization)
            await store.refreshSelected()
        }
    }

    private var teamChooser: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let savedSetupError {
                TeamNotice(message: savedSetupError, warning: true)
                Button(L10n.text("common.retry"), .refresh) { Task { await discoverSavedSetup() } }.buttonStyle(TeamButtonStyle())
            }
            if savedSetup != nil && organizationId == nil && checkedSavedSetup {
                TeamNotice(message: L10n.text("common.teams.project_setup_team_unavailable"), warning: true)
                Button(L10n.text("common.teams.project_setup_start_over"), .refresh) { confirmsDiscard = true }.buttonStyle(TeamButtonStyle())
                    .accessibilityIdentifier("team.project.recovery.unavailable-discard")
            }
            TeamPickerField(title: L10n.text("common.teams.title"), selection: $organizationId) {
                Text(L10n.text("common.teams.choose_team")).tag(Optional<String>.none)
                ForEach(store.organizations.filter(\.isActive)) { organization in Text(organization.name).tag(Optional(organization.id)) }
            }.disabled(store.isMutating || setupLocked || (store.capabilities?.canResumeProjectSharing == true && !checkedSavedSetup)
                || (savedSetup != nil && organizationId == nil)).accessibilityIdentifier("team.project.team")
            if store.organizationsNextOffset != nil {
                Button(L10n.text("common.teams.more_organizations"), .more) { Task { await store.loadMoreOrganizations() } }
                    .buttonStyle(TeamButtonStyle()).disabled(store.isRefreshing || working)
            }
            if store.organizations.isEmpty { Text(L10n.text("common.teams.no_organizations_detail")).font(Theme.body).foregroundStyle(.secondary) }
            if organizationId == nil {
                ForEach(store.localProjects(for: workspace.id)) { publication in
                    Button(L10n.text("common.teams.open_project_in_team", store.organizations.first { $0.id == publication.organizationId }?.name ?? L10n.text("common.teams.title")), .team) {
                        Task {
                            guard await store.openLocalProject(publication), let organization = store.selectedOrganization,
                                let repository = store.focusedProject else { return }
                            onOpen(organization, repository, publication.id)
                        }
                    }.buttonStyle(TeamButtonStyle()).disabled(working)
                }
            }
        }
    }

    private func discoverSavedSetup() async {
        guard store.capabilities?.canResumeProjectSharing == true else { checkedSavedSetup = true; return }
        guard let context = store.mutationContext else { return }
        checkedSavedSetup = false; savedSetupError = nil
        do {
            let result: TeamProjectSetupResult = try await store.read(.projectSharingRead, fields: ["workspace": .string(workspace.id)], context: context)
            savedSetup = result.setup
            if let setup = result.setup {
                guard setup.workspaceId == workspace.id else { throw CancellationError() }
                while !store.organizations.contains(where: { $0.id == setup.organizationId }), let offset = store.organizationsNextOffset {
                    await store.loadMoreOrganizations()
                    guard store.organizationsNextOffset != offset else { throw TeamRequestFailure(code: "teams_unreachable", message: L10n.text("common.teams.load_failed")) }
                }
                if store.organizations.contains(where: { $0.id == setup.organizationId && $0.isActive }) { organizationId = setup.organizationId }
            }
            checkedSavedSetup = true
        } catch is CancellationError {} catch { savedSetupError = error.localizedDescription }
    }

    private func discardSavedSetup() async {
        guard let savedSetup, let context = store.mutationContext, !working else { return }
        working = true; defer { working = false }
        do {
            let _: TeamProjectSetupResult = try await store.perform(.projectSharingDiscard,
                fields: ["setup": .string(savedSetup.id), "confirmDiscard": .bool(true)], context: context)
            self.savedSetup = nil; setupLocked = false; checkedSavedSetup = true
        } catch is CancellationError {} catch { savedSetupError = error.localizedDescription }
    }
}
