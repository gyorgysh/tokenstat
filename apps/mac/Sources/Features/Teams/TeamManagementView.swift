// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamManagementView: View {
    @Bindable var store: TeamStore
    var canCreateOrganization: Bool
    var onAccount: () -> Void
    var transcript: (TeamChatHistory) -> AnyView
    @State private var sheet: TeamSheet?
    @State private var query = ""
    @State private var selectedMemberId: String?
    @State private var readingSharedChat = false
    @State private var showingDrafts = false
    @Environment(\.teamCommentDraftStorage) private var commentStorage
    @Environment(\.dynamicTypeSize) private var textSize
    private var compactReader: Bool {
        #if os(iOS)
        readingSharedChat
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DetailChromeBar {
                if store.section != .chats {
                    Button(L10n.text("common.refresh"), .refresh) { refresh() }
                        .buttonStyle(TeamButtonStyle()).disabled(store.isRefreshing)
                }
                if store.localDraftPersonId != nil { draftsButton }
            }
            #endif
            if let error = store.error {
                TeamNotice(message: error, warning: true).padding(Theme.Space.m)
            }
            if let org = store.selectedOrganization, store.phase == .ready, !compactReader, !store.browsingProjects {
                organizationNavigation(org)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(store.selectedOrganization?.name ?? L10n.text("common.teams.title"))
        .onPreferenceChange(TeamChatReadingKey.self) { readingSharedChat = $0 }
        .onChange(of: store.owner) { showingDrafts = false }
        #if os(iOS)
        .navigationBarTitleDisplayMode(compactReader ? .inline : .large)
        #endif
        .sheet(item: $sheet) { route in
            TeamEditorSheet(store: store, route: route, canCreateOrganization: canCreateOrganization, onAccount: onAccount)
                #if os(macOS)
                .frame(width: 560, height: 580)
                #else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .sheet(isPresented: $showingDrafts) {
            if let owner = store.owner, let person = store.localDraftPersonId {
                TeamCommentDraftsView(origin: owner.scope.origin, person: person, storage: commentStorage, isCurrent: { store.owner == owner && store.localDraftPersonId == person })
                    .dynamicTypeSize(textSize)
                    #if os(macOS)
                    .frame(width: 640, height: 620)
                    #else
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    #endif
            }
        }
        .onChange(of: store.selectionKey) { query = ""; sheet = nil }
        .onChange(of: store.phase) {
            if store.phase == .ready { if case .authorize? = sheet { sheet = nil } }
            else { if case .authorize? = sheet {} else { sheet = nil } }
        }
        #if !os(macOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.section != .chats { Button(L10n.text("common.refresh"), systemImage: "arrow.clockwise") { refresh() }.disabled(store.isRefreshing) }
                if store.localDraftPersonId != nil { draftsButton }
            }
        }
        #endif
    }
    private var draftsButton: some View {
        Button(L10n.text("common.teams.comment_drafts"), systemImage: "square.and.pencil") { showingDrafts = true }
            .accessibilityIdentifier("team.drafts.open")
    }
    @ViewBuilder private var content: some View {
        switch store.phase {
        case .signedOut:
            EmptyState(symbol: "person.2", title: L10n.text("common.teams.title"), message: L10n.text("common.teams.sign_in_detail")) {
                Button(L10n.text("common.sign_in"), .signIn, action: onAccount).buttonStyle(TeamButtonStyle(primary: true))
            }
        case .loading: TeamLoadingView()
        case .unavailable:
            EmptyState(symbol: "person.2", title: L10n.text("common.teams.unavailable"), message: L10n.text("common.teams.unavailable_detail")) {
                Button(L10n.text("common.refresh"), .refresh) { refresh() }.buttonStyle(TeamButtonStyle())
            }
        case .authorization:
            EmptyState(symbol: "person.2", title: L10n.text("common.teams.enable_title"), message: L10n.text("common.teams.enable_detail")) {
                Button(L10n.text("common.teams.enable_action"), .team) { sheet = .authorize }.buttonStyle(TeamButtonStyle(primary: true))
            }
        case .failed:
            EmptyState(symbol: "wifi.exclamationmark", title: L10n.text("common.teams.load_failed"), message: L10n.text("common.teams.retry_detail")) {
                Button(L10n.text("common.retry"), .refresh) { refresh() }.buttonStyle(TeamButtonStyle(primary: true))
            }
        case .ready:
            if store.browsingProjects {
                TeamProjectBrowser(store: store) { store.show(.overview); store.select(nil) }
            } else if let organization = store.selectedOrganization {
                organizationContent(organization)
            } else { personalContent }
        }
    }
    private func organizationNavigation(_ organization: TeamOrganization) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            #if os(macOS)
            HStack(spacing: Theme.Space.s) {
                Text(organization.name).font(Theme.headline).lineLimit(2)
                TeamRoleBadge(text: organization.role.label)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                sectionPicker.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
                sectionPicker.pickerStyle(.menu)
            }
            #else
            HStack(spacing: Theme.Space.m) {
                TeamRoleBadge(text: organization.role.label)
                Spacer(minLength: 0)
                sectionPicker.pickerStyle(.menu)
            }
            #endif
            if !organization.eligible {
                TeamNotice(message: organization.role == .owner ? L10n.text("common.teams.owner_plan_recovery") : L10n.text("common.teams.member_plan_recovery"), warning: true)
            } else if organization.state != "active" {
                TeamNotice(message: L10n.text("common.teams.organization_paused"), warning: true)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.sidebar)
    }
    private var sectionPicker: some View {
        Picker(L10n.text("common.teams.section"), selection: $store.section) {
            ForEach(TeamSection.allCases.filter { $0 != .overview }) { section in Text(section.label).tag(section) }
        }
    }
    @ViewBuilder private func organizationContent(_ organization: TeamOrganization) -> some View {
        if store.section == .settings {
            settingsContent(organization)
        } else if !organization.eligible && organization.role != .owner {
            EmptyState(symbol: "person.2", title: L10n.text("common.teams.patron_required"), message: L10n.text("common.teams.member_plan_recovery")) {
                Button(L10n.text("common.teams.view_plan"), .plans, action: onAccount).buttonStyle(TeamButtonStyle(primary: true))
            }
        } else if store.directory == nil && store.isLoadingDirectory { TeamLoadingView() }
        else if let directory = store.directory {
            switch store.section {
            case .chats:
                if let context = store.mutationContext {
                    TeamSharedChatsView(store: store, context: context, repositories: projectChoices(directory), transcript: transcript)
                        .id(store.selectionKey)
                }
            case .members, .overview: membersContent(directory)
            case .invitations: invitationsContent(directory)
            case .repositories: repositoriesContent(directory)
            case .settings: EmptyView()
            }
        } else {
            EmptyState(symbol: "person.2", title: organization.name, message: L10n.text("common.teams.retry_detail")) {
                Button(L10n.text("common.retry"), .refresh) { Task { await store.refreshSelected() } }.buttonStyle(TeamButtonStyle())
            }
        }
    }
    private func projectChoices(_ directory: TeamDirectorySnapshot) -> [TeamRepository] {
        let rows = directory.repositories.repositories
        if let focused = store.focusedProject, focused.organizationId == directory.details.organization.id,
            !rows.contains(where: { $0.id == focused.id }) { return rows + [focused] }
        return rows
    }
    private var personalContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                TeamSectionHeader(title: L10n.text("common.teams.organizations"), subtitle: L10n.text("common.teams.directory_detail")) {
                    Button(L10n.text("common.teams.create_organization"), .create) { openCreate() }.buttonStyle(TeamButtonStyle(primary: true))
                }
                if store.organizations.isEmpty {
                    EmptyState(symbol: "person.2", title: L10n.text("common.teams.no_organizations"), message: L10n.text("common.teams.no_organizations_detail"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.organizations) { organization in
                            Button(organization.name, .team) { store.select(organization) }
                                .buttonStyle(TeamRowButtonStyle(detail: organization.role.label))
                            if organization.id != store.organizations.last?.id { ThemeRule() }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .padding(.horizontal, Theme.Space.l)
                }
                if store.organizationsNextOffset != nil {
                    Button(L10n.text("common.teams.more_organizations"), .more) { Task { await store.loadMoreOrganizations() } }
                        .buttonStyle(TeamButtonStyle()).disabled(store.isRefreshing).padding(.horizontal, Theme.Space.l)
                }
                inboxContent
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, Theme.Space.l)
        }
    }
    private var inboxContent: some View {
        Card(title: L10n.text("common.teams.your_invitations"), subtitle: L10n.text("common.teams.inbox_detail")) {
            if store.inbox.isEmpty {
                Text(L10n.text("common.teams.no_invitations")).font(Theme.body).foregroundStyle(.secondary).padding(.vertical, Theme.Space.m)
            } else {
                ForEach(store.inbox) { invitation in
                    HStack(spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(invitation.organizationName ?? L10n.text("common.teams.organization")).font(Theme.body.weight(.medium))
                            Text(invitation.role.label).font(Theme.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.m)
                        Button(L10n.text("common.teams.review_invitation"), .preview) {
                            if let context = store.mutationContext { sheet = .accept(context, invitation) }
                        }.buttonStyle(TeamButtonStyle())
                    }.padding(.vertical, Theme.Space.s)
                }
                if store.inboxNextOffset != nil {
                    Button(L10n.text("common.teams.more_invitations"), .more) { Task { await store.loadMoreInbox() } }.buttonStyle(TeamButtonStyle())
                }
            }
        }.padding(.horizontal, Theme.Space.l)
    }
    private func membersContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        let members = directory.members.members.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.handle?.localizedStandardContains(query) ?? false) }
        return VStack(spacing: 0) {
            TeamSectionHeader(title: L10n.text("common.teams.members"), subtitle: L10n.text("common.teams.member_list_detail")) {
                if organization.role.canManage {
                    Button(L10n.text("common.teams.invite_member"), .invite) { if let context = store.mutationContext { sheet = .invite(context) } }
                        .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
                }
            }
            searchField
            #if os(macOS)
            Table(members, selection: $selectedMemberId) {
                TableColumn(L10n.text("common.teams.member")) { member in person(member) }.width(min: 160, ideal: 240)
                TableColumn(L10n.text("common.teams.role")) { member in Text(member.role.label).font(Theme.body) }.width(min: 80, ideal: 100, max: 130)
                TableColumn(L10n.text("common.teams.access")) { member in
                    Text(member.eligible ? L10n.text("common.teams.active") : L10n.text("common.teams.needs_patron"))
                        .font(Theme.callout).foregroundStyle(member.eligible ? Color.secondary : TeamColors.warning)
                }.width(min: 100, ideal: 120, max: 160)
                TableColumn("") { member in memberMenu(member, organization: organization) }.width(36)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
            #else
            List(members) { member in
                HStack(spacing: Theme.Space.m) {
                    person(member)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                        Text(member.role.label).font(Theme.callout)
                        if !member.eligible { Text(L10n.text("common.teams.needs_patron")).font(Theme.callout).foregroundStyle(TeamColors.warning) }
                    }
                    memberMenu(member, organization: organization)
                }
                .padding(.vertical, Theme.Space.xs).listRowBackground(Theme.panel)
            }.listStyle(.plain).scrollContentBackground(.hidden)
            #endif
            if members.isEmpty { Text(L10n.text("common.teams.no_matching_members")).font(Theme.callout).foregroundStyle(.secondary).padding(Theme.Space.l) }
            if directory.members.nextOffset != nil { moreButton(.members) }
        }
    }
    private func person(_ member: TeamMember) -> some View {
        TeamPersonLabel(id: member.id, name: member.name, handle: member.handle, avatar: member.avatar, owner: store.owner)
            .padding(.vertical, Theme.Space.xs)
    }
    @ViewBuilder private func memberMenu(_ member: TeamMember, organization: TeamOrganization) -> some View {
        let canChangeRole = organization.role == .owner && member.role != .owner && organization.isActive
        let canRemove = member.role != .owner && (organization.role == .owner || (organization.role == .admin && member.role == .member))
        if canChangeRole || canRemove {
            Menu {
                if canChangeRole { Button(L10n.text("common.teams.change_role")) { if let context = store.mutationContext { sheet = .memberRole(context, member) } } }
                if canRemove { Button(L10n.text("common.teams.remove_member"), role: .destructive) { if let context = store.mutationContext { sheet = .remove(context, member) } } }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: Theme.Control.heightComfortable, minHeight: Theme.Control.heightComfortable)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L10n.text("common.teams.manage_member", member.name))
        }
    }
    private func invitationsContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        return VStack(spacing: 0) {
            TeamSectionHeader(title: L10n.text("common.teams.invitations"), subtitle: L10n.text("common.teams.invitation_list_detail")) {
                if organization.role.canManage {
                    Button(L10n.text("common.teams.invite_member"), .invite) { if let context = store.mutationContext { sheet = .invite(context) } }
                        .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
                }
            }
            if !organization.role.canManage {
                EmptyState(symbol: "person.badge.plus", title: L10n.text("common.teams.invitation_admin"), message: L10n.text("common.teams.invitation_admin_detail"))
            } else {
                if directory.invitations.invitations.isEmpty {
                    EmptyState(symbol: "person.badge.plus", title: L10n.text("common.teams.no_invitations"), message: L10n.text("common.teams.invite_empty_detail"))
                } else {
                    List(directory.invitations.invitations) { invitation in
                        HStack(spacing: Theme.Space.m) {
                            if let recipient = invitation.recipient {
                                TeamPersonLabel(id: recipient.id, name: recipient.name, handle: recipient.handle, avatar: recipient.avatar, owner: store.owner)
                            } else { Text(L10n.text("common.teams.member_unavailable")).font(Theme.body) }
                            Spacer(minLength: Theme.Space.s)
                            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                                Text(invitation.role.label).font(Theme.callout)
                                Text(invitationState(invitation.state)).font(Theme.callout).foregroundStyle(.secondary)
                            }
                            if (invitation.state == "pending" || invitation.state == "expired") && (invitation.role != .admin || organization.role == .owner) {
                                Menu {
                                    Button(L10n.text("common.teams.new_invitation_link")) { if let context = store.mutationContext { sheet = .invitationAction(context, invitation, renewing: true) } }
                                        .disabled(!organization.isActive)
                                    Button(L10n.text("common.teams.revoke_invitation"), role: .destructive) { if let context = store.mutationContext { sheet = .invitationAction(context, invitation, renewing: false) } }
                                } label: { Image(systemName: "ellipsis").frame(minWidth: Theme.Control.heightComfortable, minHeight: Theme.Control.heightComfortable) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(store.isMutating)
                                .accessibilityLabel(L10n.text("common.teams.manage_invitation"))
                            }
                        }.padding(.vertical, Theme.Space.xs).listRowBackground(Theme.panel)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                }
                if directory.invitations.nextOffset != nil { moreButton(.invitations) }
            }
        }
    }
    private func repositoriesContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        return VStack(spacing: 0) {
            TeamSectionHeader(title: L10n.text("common.teams.repositories"), subtitle: L10n.text("common.teams.repository_list_detail")) {
                if store.capabilities?.canPublishCheckouts == true && (organization.role.canManage || directory.repositories.repositories.contains { $0.role == .contributor || $0.role == .maintainer }) {
                    Button(L10n.text("common.teams.share_project"), .connect) { if let context = store.mutationContext { sheet = .repository(context) } }
                        .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
                }
            }
            if directory.repositories.repositories.isEmpty {
                EmptyState(symbol: "folder", title: L10n.text("common.teams.no_repositories"), message: organization.role.canManage ? L10n.text("common.teams.no_repositories_admin") : L10n.text("common.teams.no_repositories_member"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(directory.repositories.repositories) { repository in
                            if let context = store.mutationContext {
                                TeamRepositoryRow(store: store, context: context, repository: repository, organization: organization,
                                    openChats: { store.selectedRepositoryId = repository.id; store.show(.chats) },
                                    openCheckouts: { sheet = .checkouts(context, repository) },
                                    manageAccess: { sheet = .access(context, repository) },
                                    rename: { sheet = .renameRepository(context, repository) })
                            }
                            ThemeRule()
                        }
                    }
                }
            }
            if directory.repositories.nextOffset != nil { moreButton(.repositories) }
        }
    }
    private func settingsContent(_ organization: TeamOrganization) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Card(title: L10n.text("common.teams.organization_settings"), subtitle: organization.name) {
                    LabeledContent(L10n.text("common.teams.organization_address"), value: organization.slug)
                    LabeledContent(L10n.text("common.teams.your_role"), value: organization.role.label)
                    if organization.role.canManage {
                        Button(L10n.text("common.teams.rename_organization"), .edit) { if let context = store.mutationContext { sheet = .rename(context) } }
                            .buttonStyle(TeamButtonStyle()).disabled(!organization.isActive)
                    }
                }
                if let request = store.directory?.details.ownershipRequest, request.toUserId == store.capabilities?.actorId {
                    Card(title: L10n.text("common.teams.ownership_request"), subtitle: L10n.text("common.teams.ownership_accept_detail")) {
                        if !request.current { TeamNotice(message: L10n.text("common.teams.ownership_stale"), warning: true) }
                        Button(L10n.text("common.teams.review_ownership"), .approve) { if let context = store.mutationContext { sheet = .ownershipDecision(context, request, cancelling: false) } }
                            .buttonStyle(TeamButtonStyle(primary: true)).disabled(!request.current || store.isMutating)
                    }
                }
                if organization.role == .owner {
                    if let request = store.directory?.details.ownershipRequest, request.fromUserId == store.capabilities?.actorId {
                        Card(title: L10n.text("common.teams.ownership_request"), subtitle: (request.current ? L10n.text("common.teams.ownership_pending") : L10n.text("common.teams.ownership_stale"))) {
                            Button(L10n.text("common.teams.cancel_ownership_request"), .revoke) { if let context = store.mutationContext { sheet = .ownershipDecision(context, request, cancelling: true) } }.buttonStyle(TeamButtonStyle()).disabled(request.requestId == nil || store.isMutating)
                        }
                    }
                    Card(title: L10n.text("common.teams.ownership"), subtitle: L10n.text("common.teams.owner_detail")) {
                        Button(L10n.text("common.teams.transfer_ownership"), .move) { if let context = store.mutationContext { sheet = .transfer(context) } }.buttonStyle(TeamButtonStyle())
                    }
                    Card(title: L10n.text("common.teams.delete_organization"), subtitle: L10n.text("common.teams.delete_detail")) {
                        Button(L10n.text("common.teams.delete_organization"), .delete, role: .destructive) { if let context = store.mutationContext { sheet = .delete(context) } }.buttonStyle(TeamButtonStyle())
                    }
                } else {
                    Card(title: L10n.text("common.teams.leave_organization"), subtitle: L10n.text("common.teams.leave_detail")) {
                        Button(L10n.text("common.teams.leave_organization"), .signOut, role: .destructive) { if let context = store.mutationContext { sheet = .leave(context) } }.buttonStyle(TeamButtonStyle())
                    }
                }
                Button(L10n.text("common.teams.view_plan"), .plans, action: onAccount).buttonStyle(TeamButtonStyle())
            }.padding(Theme.Space.l).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var searchField: some View {
        HStack {
            TextField(L10n.text("common.search"), text: $query).textFieldStyle(ThemedFieldStyle(small: true)).frame(maxWidth: 300)
            Spacer(minLength: 0)
        }.padding(.horizontal, Theme.Space.l).padding(.bottom, Theme.Space.m)
    }
    private func moreButton(_ section: TeamSection) -> some View {
        Button(L10n.text("common.teams.load_more"), .more) { Task { await store.loadMore(section) } }
            .buttonStyle(TeamButtonStyle()).disabled(store.isLoadingDirectory).padding(Theme.Space.m)
    }
    private func openCreate() { if let context = store.mutationContext { sheet = .create(context) } }
    private func refresh() { Task { await store.reloadAfterChange() } }
    private func invitationState(_ state: String) -> String {
        switch state {
        case "pending": L10n.text("common.teams.pending")
        case "accepted": L10n.text("common.teams.accepted")
        case "revoked": L10n.text("common.teams.revoked")
        case "expired": L10n.text("common.teams.expired")
        default: L10n.text("common.teams.unavailable")
        }
    }
}
