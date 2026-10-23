// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Projects from every team, reachable without changing the account scope.
/// Each section loads independently and keeps its own explicit next page.
struct TeamProjectBrowser: View {
    @Bindable var store: TeamStore
    let manageTeams: () -> Void
    @State private var organizationId: String?
    @State private var filteredOrganization: TeamOrganization?
    /// A directory refresh returns its first page. Keep a chosen later-page
    /// organization until its own authorized project lookup can refresh it.
    private var filterChoices: [TeamOrganization] {
        if let filteredOrganization, !store.organizations.contains(where: { $0.id == filteredOrganization.id }) {
            return store.organizations + [filteredOrganization]
        }
        return store.organizations
    }
    private var organizations: [TeamOrganization] { filterChoices.filter { organizationId == nil || $0.id == organizationId } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
                TeamSectionHeader(title: L10n.text("common.teams.shared_projects"), subtitle: L10n.text("common.teams.shared_projects_detail")) {
                    Button(L10n.text("common.teams.manage_teams"), .team, action: manageTeams).buttonStyle(TeamButtonStyle())
                }
                TeamPickerField(title: L10n.text("common.teams.organization"), selection: $organizationId) {
                    Text(L10n.text("common.teams.all_organizations")).tag(Optional<String>.none)
                    ForEach(filterChoices) { Text($0.name).tag(Optional($0.id)) }
                }.padding(.horizontal, Theme.Space.l).accessibilityIdentifier("team.projects.organization-filter")
                if let error = store.localProjectsError { TeamNotice(message: error, warning: true).padding(.horizontal, Theme.Space.l) }
                if store.organizations.isEmpty {
                    TeamNotice(message: L10n.text("common.teams.no_shared_projects")).padding(.horizontal, Theme.Space.l)
                }
                ForEach(organizations) { organization in
                    if let context = store.mutationContext {
                        TeamProjectGroup(store: store, context: context, organization: organization)
                            .id("\(store.selectionKey)-\(organization.id)")
                    }
                }
                if store.organizationsNextOffset != nil {
                    Button(L10n.text("common.teams.more_organizations"), .more) { Task { await store.loadMoreOrganizations() } }
                        .buttonStyle(TeamButtonStyle()).disabled(store.isRefreshing).padding(.horizontal, Theme.Space.l)
                }
            }.frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Theme.Space.l)
        }
        .task { await store.reloadAfterChange() }
        .onChange(of: organizationId) { _, id in filteredOrganization = store.organizations.first { $0.id == id } }
        .onChange(of: store.owner) { organizationId = nil; filteredOrganization = nil }
    }
}

private struct TeamProjectGroup: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let organization: TeamOrganization
    @State private var projects: [TeamRepository] = []
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var request = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(organization.name).font(Theme.headline).accessibilityAddTraits(.isHeader)
            if !organization.isActive { TeamNotice(message: L10n.text("common.teams.organization_paused"), warning: true) }
            if let error {
                TeamNotice(message: error, warning: true)
                Button(L10n.text("common.retry"), .refresh) { Task { await load(more: false) } }.buttonStyle(TeamButtonStyle())
            }
            ForEach(projects) { project in
                let local = store.localProjects.first { $0.organizationId == organization.id && $0.repositoryId == project.id && $0.phase == "active" }
                Button {
                    store.openProject(project, in: organization, checkout: local?.id)
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "folder.badge.person.crop").foregroundStyle(TeamColors.action)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(project.name).font(Theme.body.weight(.semibold))
                            Text(local == nil ? L10n.text("common.teams.shared_with_you") : L10n.text("common.teams.shared_from_this_computer"))
                                .font(Theme.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        if let role = project.role { TeamRoleBadge(text: role.label) }
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(Theme.Space.m).contentShape(.rect)
                }.buttonStyle(.plain)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("team.project.open.\(project.id)")
            }
            if loaded && organization.isActive && projects.isEmpty && error == nil { TeamNotice(message: L10n.text("common.teams.no_shared_projects")) }
            if nextOffset != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await load(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading)
            }
            if loading { ProgressView().controlSize(.small) }
        }.padding(.horizontal, Theme.Space.l)
            .task(id: store.catalogRefresh) { await load(more: false) }
    }
    private func load(more: Bool) async {
        guard organization.isActive else { loaded = true; return }
        if more && loading { return }
        let id = UUID(); request = id
        loading = true; defer { if request == id { loading = false } }
        do {
            let result: TeamRepositories = try await store.read("repositories.list", fields: ["organization": .string(organization.id),
                "page": TeamStore.page(offset: more ? nextOffset ?? 0 : 0)], context: context)
            guard request == id else { return }
            let rows = result.repositories.filter { $0.organizationId == organization.id && $0.role != nil }
            projects = more ? projects + rows.filter { next in !projects.contains { $0.id == next.id } } : rows
            nextOffset = result.nextOffset; loaded = true; error = nil
        } catch is CancellationError {} catch { if request == id, store.mutationContext == context { self.error = error.localizedDescription } }
    }
}
