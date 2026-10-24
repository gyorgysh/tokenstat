// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A directory card loads real, permission-filtered people and projects.
/// Counts remain explicit lower bounds when another page is available.
struct TeamOrganizationCard: View {
    @Bindable var store: TeamStore
    let organization: TeamOrganization
    let context: TeamMutationContext
    @State private var members: TeamMembers?
    @State private var projects: TeamRepositories?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.select(organization)
            } label: {
                HStack(spacing: Theme.Space.m) {
                    TeamOrganizationMark(name: organization.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(organization.name).font(Theme.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: Theme.Space.s) {
                            Text("@" + organization.slug).font(Theme.callout).foregroundStyle(.secondary).lineLimit(1)
                            TeamRoleBadge(text: organization.role.label)
                        }
                    }
                }
            }.buttonStyle(TeamListRowButtonStyle()).padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
                .accessibilityIdentifier("team.organization.open.\(organization.id)")
            ThemeRule()
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if !organization.isActive { Text(L10n.text("common.teams.organization_paused")).font(Theme.callout).foregroundStyle(TeamColors.warning) }
                if let members, let projects {
                    HStack(spacing: Theme.Space.l) {
                        Label(count(members.members.count, more: members.nextOffset != nil), systemImage: "person.2")
                            .accessibilityLabel(L10n.text("common.teams.member_count", count(members.members.count, more: members.nextOffset != nil)))
                        Label(count(projects.repositories.count, more: projects.nextOffset != nil), systemImage: "folder")
                            .accessibilityLabel(L10n.text("common.teams.project_count", count(projects.repositories.count, more: projects.nextOffset != nil)))
                        Spacer(minLength: 0)
                        TeamAvatarStack(members: members.members, owner: store.owner)
                    }.font(Theme.callout).foregroundStyle(.secondary)
                    if projects.repositories.isEmpty {
                        Text(L10n.text("common.teams.first_project_hint")).font(Theme.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(projects.repositories.filter { $0.role != nil }.prefix(3)) { project in
                                Button {
                                    store.openProject(project, in: organization)
                                } label: {
                                    Label(project.name, systemImage: "folder.badge.person.crop").font(Theme.body).lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(.rect)
                                }.buttonStyle(.plain).foregroundStyle(TeamColors.action)
                                    .accessibilityIdentifier("team.project.open.\(project.id)")
                            }
                        }
                    }
                } else if let error {
                    Text(error).font(Theme.callout).foregroundStyle(.secondary)
                    Button(L10n.text("common.retry"), .refresh) { Task { await load() } }.buttonStyle(TeamButtonStyle())
                } else if organization.isActive {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .teamTile()
        .task(id: store.catalogRefresh) { await load() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard scenePhase == .active else { continue }
                await load()
            }
        }
    }
    private func count(_ value: Int, more: Bool) -> String { value.formatted() + (more ? "+" : "") }
    private func load() async {
        guard organization.isActive else { return }
        let started = Date()
        do {
            let fields: [String: JSONValue] = ["organization": .string(organization.id), "page": TeamStore.page()]
            async let people: TeamMembers = store.read("members.list", fields: fields, context: context)
            async let repositories: TeamRepositories = store.read("repositories.list", fields: fields, context: context)
            let (peopleResult, projectResult) = try await (people, repositories)
            guard store.mutationContext == context else { return }
            members = peopleResult
            projects = projectResult
            error = nil
            store.observePresence(peopleResult.members, organization: organization.id, at: started)
        } catch is CancellationError {} catch {
            guard store.mutationContext == context else { return }
            self.error = error.localizedDescription
        }
    }
}

struct TeamOrganizationOverview: View {
    @Bindable var store: TeamStore
    let directory: TeamDirectorySnapshot
    let invite: () -> Void
    let addProject: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    private var organization: TeamOrganization { directory.details.organization }
    private var projects: [TeamRepository] { directory.repositories.repositories.filter { $0.role != nil } }

    var body: some View {
        TeamPage {
            if !textSize.isAccessibilitySize {
                // One row, equal widths, equal heights: the tallest tile sets
                // the row and every other tile fills it.
                HStack(spacing: Theme.Space.m) {
                    TeamMetricTile(title: L10n.text("common.teams.members"), value: count(directory.members.members.count, more: directory.members.nextOffset != nil), symbol: "person.2") {
                        store.show(.members)
                    }
                    TeamMetricTile(title: L10n.text("common.teams.shared_projects"), value: count(directory.repositories.repositories.count, more: directory.repositories.nextOffset != nil), symbol: "folder.badge.person.crop") {
                        store.show(.repositories)
                    }
                    if organization.role.canManage {
                        TeamMetricTile(title: L10n.text("common.teams.pending_invitations"), value: count(directory.invitations.invitations.filter { $0.state == "pending" }.count, more: directory.invitations.nextOffset != nil), symbol: "envelope") {
                            store.show(.invitations)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            Card(title: L10n.text("common.teams.shared_projects"), subtitle: L10n.text("common.teams.project_collaboration_detail"), mark: "mark_folder",
                accessory: projects.isEmpty ? nil : AnyView(viewAll(.repositories))) {
                if projects.isEmpty {
                    TeamGettingStarted(canManage: organization.role.canManage, addProject: addProject, invite: invite)
                        .disabled(!organization.isActive)
                } else {
                    LazyVGrid(columns: cardColumns, alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(projects.prefix(6)) { project in
                            Button {
                                store.openProject(project, in: organization)
                            } label: {
                                HStack(spacing: Theme.Space.m) {
                                    Image(systemName: "folder.badge.person.crop").font(Theme.font(16)).foregroundStyle(TeamColors.action)
                                        .frame(width: 34, height: 34).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).font(Theme.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                        Text(L10n.text("common.teams.open_conversations")).font(Theme.callout).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }.buttonStyle(TeamListRowButtonStyle()).padding(.horizontal, Theme.Space.m).teamTile()
                                .accessibilityIdentifier("team.project.open.\(project.id)")
                        }
                    }
                }
            }
            Card(title: L10n.text("common.teams.people"), subtitle: L10n.text("common.teams.organization_overview_detail"), mark: "mark_account",
                accessory: AnyView(viewAll(.members))) {
                TeamRows(items: Array(directory.members.members.prefix(6))) { member in
                    HStack(spacing: Theme.Space.m) {
                        TeamMemberLabel(store: store, member: member, organization: organization.id)
                        Spacer(minLength: Theme.Space.m)
                        TeamRoleBadge(text: member.role.label)
                    }.teamRowPadding()
                }
            }
        }
    }
    private func viewAll(_ section: TeamSection) -> some View {
        Button(L10n.text("common.teams.view_all"), .next) { store.show(section) }
            .buttonStyle(.plain).font(Theme.callout).foregroundStyle(TeamColors.action)
    }
    private func count(_ value: Int, more: Bool) -> String { value.formatted() + (more ? "+" : "") }
    private var cardColumns: [GridItem] {
        textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 260), spacing: Theme.Space.m, alignment: .top)]
    }
}

struct TeamGettingStarted: View {
    let canManage: Bool
    let addProject: () -> Void
    let invite: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Image(systemName: "folder.badge.person.crop").font(Theme.font(32, weight: .light)).foregroundStyle(TeamColors.action).accessibilityHidden(true)
            Text(L10n.text("common.teams.first_project_title")).font(Theme.title2.weight(.semibold))
            Text(canManage ? L10n.text("common.teams.first_project_detail") : L10n.text("common.teams.no_repositories_member"))
                .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if canManage {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.m) { actions }
                    VStack(alignment: .leading, spacing: Theme.Space.m) { actions }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var actions: some View {
        Button(L10n.text("common.teams.new_repository"), .create, action: addProject).buttonStyle(TeamSmallButtonStyle(primary: true))
        Button(L10n.text("common.teams.invite_member"), .invite, action: invite).buttonStyle(TeamSmallButtonStyle())
    }
}

private struct TeamOrganizationMark: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(Theme.title3.weight(.semibold)).foregroundStyle(TeamColors.action)
            .frame(width: 40, height: 40).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
    }
}
private struct TeamAvatarStack: View {
    let members: [TeamMember]
    let owner: TeamAccountOwner?
    var body: some View {
        HStack(spacing: -8) {
            ForEach(members.prefix(4)) { member in
                Avatar(url: teamAvatarURL(member.avatar, owner: owner)?.absoluteString, name: member.name, handle: member.handle, size: 24, tint: Avatar.tint(for: member.id))
                    .background(Theme.panel, in: Circle()).overlay(Circle().stroke(Theme.panel, lineWidth: 2))
            }
        }.accessibilityHidden(true)
    }
}
