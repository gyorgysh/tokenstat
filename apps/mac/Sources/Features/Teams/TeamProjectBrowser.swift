// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Projects from every team, reachable without changing the account scope.
/// Each section loads independently and keeps its own explicit next page.
struct TeamProjectBrowser: View {
    @Bindable var store: TeamStore
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
        TeamPage {
            if filterChoices.count > 1 {
                HStack(spacing: Theme.Space.s) {
                    Text(L10n.text("common.teams.organization")).font(Theme.callout).foregroundStyle(.secondary)
                    AppMenuPicker(options: [(Optional<String>.none, L10n.text("common.teams.all_organizations"))] + filterChoices.map { (Optional($0.id), $0.name) },
                        selection: $organizationId).frame(width: 240)
                        .accessibilityIdentifier("team.projects.organization-filter")
                }
            }
            if let error = store.localProjectsError { TeamNotice(message: error, warning: true) }
            if store.organizations.isEmpty {
                Card(title: L10n.text("common.teams.shared_projects"), subtitle: L10n.text("common.teams.shared_projects_detail"), mark: "mark_folder") {
                    Text(L10n.text("common.teams.no_shared_projects")).font(Theme.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(organizations) { organization in
                if let context = store.mutationContext {
                    TeamProjectGroup(store: store, context: context, organization: organization)
                        .id("\(store.selectionKey)-\(organization.id)")
                }
            }
            if store.organizationsNextOffset != nil {
                Button(L10n.text("common.teams.more_organizations"), .more) { Task { await store.loadMoreOrganizations() } }
                    .buttonStyle(TeamSmallButtonStyle()).disabled(store.isRefreshing)
            }
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
        Card(title: organization.name, subtitle: L10n.text("common.teams.shared_projects_detail"), mark: "mark_folder") {
            if !organization.isActive { TeamNotice(message: L10n.text("common.teams.organization_paused"), warning: true) }
            if let error {
                TeamNotice(message: error, warning: true)
                Button(L10n.text("common.retry"), .refresh) { Task { await load(more: false) } }.buttonStyle(TeamSmallButtonStyle())
            }
            TeamRows(items: projects) { project in
                let local = store.localProjects.first { $0.organizationId == organization.id && $0.repositoryId == project.id && $0.phase == "active" }
                Button {
                    store.openProject(project, in: organization, checkout: local?.id)
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "folder.badge.person.crop").font(Theme.font(15)).foregroundStyle(TeamColors.action)
                            .frame(width: 30, height: 30).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(Theme.body.weight(.semibold)).foregroundStyle(.primary)
                            Text(local == nil ? L10n.text("common.teams.shared_with_you") : L10n.text("common.teams.shared_from_this_computer"))
                                .font(Theme.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        if let role = project.role { TeamRoleBadge(text: role.label) }
                    }
                }.buttonStyle(TeamListRowButtonStyle())
                    .accessibilityIdentifier("team.project.open.\(project.id)")
            }
            if loaded && organization.isActive && projects.isEmpty && error == nil {
                Text(L10n.text("common.teams.no_shared_projects")).font(Theme.callout).foregroundStyle(.secondary)
            }
            if nextOffset != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await load(more: true) } }.buttonStyle(TeamSmallButtonStyle()).disabled(loading)
            }
            if loading && projects.isEmpty { ProgressView().controlSize(.small) }
        }
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
