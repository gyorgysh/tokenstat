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
        .onChange(of: store.phase) { _, phase in if phase != .ready { working = false; setupLocked = false } }
        .task(id: organizationId) {
            guard let organization = store.organizations.first(where: { $0.id == organizationId }) else { return }
            store.select(organization)
            await store.refreshSelected()
        }
    }

    private var teamChooser: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TeamPickerField(title: L10n.text("common.teams.title"), selection: $organizationId) {
                Text(L10n.text("common.teams.choose_team")).tag(Optional<String>.none)
                ForEach(store.organizations.filter(\.isActive)) { organization in Text(organization.name).tag(Optional(organization.id)) }
            }.disabled(store.isMutating || setupLocked).accessibilityIdentifier("team.project.team")
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
}
