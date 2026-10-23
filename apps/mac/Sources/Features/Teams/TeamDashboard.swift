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
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Button {
                store.select(organization)
            } label: {
                HStack(spacing: Theme.Space.m) {
                    TeamOrganizationMark(name: organization.name)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(organization.name).font(Theme.title2.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        Text("@" + organization.slug).font(Theme.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("team.organization.open.\(organization.id)")
            HStack(spacing: Theme.Space.s) {
                TeamRoleBadge(text: organization.role.label)
                if !organization.isActive { Text(L10n.text("common.teams.organization_paused")).font(Theme.caption).foregroundStyle(TeamColors.warning) }
            }
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
                    ForEach(projects.repositories.filter { $0.role != nil }.prefix(3)) { project in
                        Button {
                            store.openProject(project, in: organization)
                        } label: {
                            Label(project.name, systemImage: "folder.badge.person.crop").font(Theme.body).lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain).foregroundStyle(TeamColors.action)
                            .accessibilityIdentifier("team.project.open.\(project.id)")
                    }
                }
            } else if let error {
                Text(error).font(Theme.callout).foregroundStyle(.secondary)
                Button(L10n.text("common.retry"), .refresh) { Task { await load() } }.buttonStyle(TeamButtonStyle())
            } else if organization.isActive {
                ProgressView().controlSize(.small)
            }
        }
        .padding(Theme.Space.l).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if !projects.isEmpty {
                    TeamSectionHeader(title: L10n.text("common.teams.overview"), subtitle: L10n.text("common.teams.organization_overview_detail")) {
                        if organization.role.canManage {
                            Button(L10n.text("common.teams.invite_member"), .invite, action: invite)
                                .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if !projects.isEmpty && !textSize.isAccessibilitySize {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], spacing: Theme.Space.m) {
                            metric(L10n.text("common.teams.members"), count: directory.members.members.count, more: directory.members.nextOffset != nil, symbol: "person.2") {
                                store.show(.members)
                            }
                            metric(
                                L10n.text("common.teams.shared_projects"), count: directory.repositories.repositories.count, more: directory.repositories.nextOffset != nil,
                                symbol: "folder.badge.person.crop"
                            ) { store.show(.repositories) }
                            if organization.role.canManage {
                                metric(
                                    L10n.text("common.teams.pending_invitations"), count: directory.invitations.invitations.filter { $0.state == "pending" }.count,
                                    more: directory.invitations.nextOffset != nil, symbol: "envelope"
                                ) { store.show(.invitations) }
                            }
                        }
                    }
                    sectionHeading(L10n.text("common.teams.shared_projects"), section: .repositories)
                    if projects.isEmpty {
                        TeamGettingStarted(canManage: organization.role.canManage, addProject: addProject, invite: invite)
                            .disabled(!organization.isActive)
                    } else {
                        LazyVGrid(columns: cardColumns, spacing: Theme.Space.m) {
                            ForEach(projects.prefix(6)) { project in
                                Button {
                                    store.openProject(project, in: organization)
                                } label: {
                                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                                        Image(systemName: "folder.badge.person.crop").font(Theme.font(24)).foregroundStyle(TeamColors.action)
                                        Text(project.name).font(Theme.headline).foregroundStyle(.primary).lineLimit(2)
                                        Label(L10n.text("common.teams.open_conversations"), systemImage: "bubble.left.and.bubble.right").font(Theme.callout).foregroundStyle(
                                            .secondary)
                                    }.padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                                }.buttonStyle(.plain).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                                    .accessibilityIdentifier("team.project.open.\(project.id)")
                            }
                        }
                        Label(L10n.text("common.teams.project_collaboration_detail"), systemImage: "bubble.left.and.bubble.right")
                            .font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ThemeRule()
                    sectionHeading(L10n.text("common.teams.people"), section: .members)
                    LazyVGrid(
                        columns: textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading,
                        spacing: Theme.Space.l
                    ) {
                        ForEach(directory.members.members.prefix(6)) { member in
                            TeamMemberLabel(store: store, member: member, organization: organization.id)
                        }
                    }
                }.padding(.horizontal, Theme.Space.l).padding(.top, projects.isEmpty ? Theme.Space.l : 0)
            }.padding(.bottom, Theme.Space.l).frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    @ViewBuilder private func sectionHeading(_ title: String, section: TeamSection) -> some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title).font(Theme.headline).accessibilityAddTraits(.isHeader)
                viewAll(section)
            }
        } else {
            HStack {
                Text(title).font(Theme.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.s)
                viewAll(section)
            }
        }
    }
    private func viewAll(_ section: TeamSection) -> some View {
        Button(L10n.text("common.teams.view_all"), .next) { store.show(section) }
            .buttonStyle(.plain).font(Theme.callout).foregroundStyle(TeamColors.action)
    }
    private var cardColumns: [GridItem] {
        textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 250), alignment: .leading)]
    }
    private func metric(_ title: String, count: Int, more: Bool, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(title, systemImage: symbol).font(Theme.callout).foregroundStyle(.secondary)
                Text(count.formatted() + (more ? "+" : "")).font(Theme.title2.weight(.semibold)).foregroundStyle(.primary)
            }.padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }.buttonStyle(.plain).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
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
        }.padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }
    @ViewBuilder private var actions: some View {
        Button(L10n.text("common.teams.new_repository"), .create, action: addProject).buttonStyle(TeamButtonStyle(primary: true))
        Button(L10n.text("common.teams.invite_member"), .invite, action: invite).buttonStyle(TeamButtonStyle())
    }
}

private struct TeamOrganizationMark: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(Theme.title2.weight(.semibold)).foregroundStyle(TeamColors.action)
            .frame(width: 48, height: 48).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}
private struct TeamAvatarStack: View {
    let members: [TeamMember]
    let owner: TeamAccountOwner?
    var body: some View {
        HStack(spacing: -8) {
            ForEach(members.prefix(4)) { member in
                Avatar(url: teamAvatarURL(member.avatar, owner: owner)?.absoluteString, name: member.name, handle: member.handle, size: 28, tint: Avatar.tint(for: member.id))
                    .background(Theme.panel, in: Circle()).overlay(Circle().stroke(Theme.panel, lineWidth: 2))
            }
        }.accessibilityHidden(true)
    }
}
