// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamManagementView: View {
    @Bindable var store: TeamStore
    var canCreateOrganization: Bool
    var onAccount: () -> Void
    var transcript: (TeamChatHistory) -> AnyView
    @State private var sheet: TeamSheet?
    @State private var query = ""
    @State private var readingSharedChat = false
    @State private var showingDrafts = false
    @State private var showingSavedAsks = false
    @Environment(\.teamCommentDraftStorage) private var commentStorage
    @Environment(\.teamAskRecoveryStorage) private var askStorage
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
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
            DetailChromeBar(scope: chromeScope, leading: {
                if store.phase == .ready && (store.browsingProjects || store.selectedOrganization != nil) {
                    ToolbarIconButton(systemImage: "chevron.left", help: L10n.text("common.teams.all_organizations")) { leaveToHub() }
                        .accessibilityIdentifier("team.organizations.back")
                }
            }) {
                if store.phase == .ready && !store.browsingProjects {
                    ToolbarIconButton(systemImage: "folder.badge.person.crop", help: L10n.text("common.teams.shared_projects")) { store.showProjects() }
                        .accessibilityIdentifier("team.projects.open")
                }
                if store.localDraftPersonId != nil {
                    ToolbarIconButton(systemImage: "square.and.pencil", help: L10n.text("common.teams.comment_drafts")) { showingDrafts = true }
                        .accessibilityIdentifier("team.drafts.open")
                    ToolbarIconButton(systemImage: "clock.arrow.circlepath", help: L10n.text("common.teams.saved_asks")) { showingSavedAsks = true }
                        .accessibilityIdentifier("team.asks.open")
                }
                if store.browsingProjects || store.section != .chats {
                    ToolbarIconButton(systemImage: "arrow.clockwise", help: L10n.text("common.refresh"), isBusy: store.isRefreshing, isEnabled: !store.isRefreshing) { refresh() }
                }
            }
            #endif
            if let org = store.selectedOrganization, store.phase == .ready, !compactReader, !store.browsingProjects {
                organizationNavigation(org)
            }
            if let error = store.error {
                TeamNotice(message: error, warning: true).padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.m)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(store.selectedOrganization?.name ?? L10n.text("common.teams.title"))
        .onPreferenceChange(TeamChatReadingKey.self) { readingSharedChat = $0 }
        .onChange(of: store.owner) { showingDrafts = false; showingSavedAsks = false }
        #if os(iOS)
        .navigationBarTitleDisplayMode(compactReader || textSize.isAccessibilitySize ? .inline : .large)
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
        .sheet(isPresented: $showingSavedAsks) {
            if let owner = store.owner, let person = store.localDraftPersonId {
                TeamAskRecoveryView(store: store, owner: owner, person: person, storage: askStorage)
                    .dynamicTypeSize(textSize)
                    #if os(macOS)
                    .frame(width: 640, height: 620)
                    #else
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    #endif
            }
        }
        .onChange(of: store.selectionKey) { query = ""; sheet = nil }
        .task(id: store.selectionKey) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard scenePhase == .active, store.capabilities?.supportsAppPresence == true else { continue }
                await store.refreshMemberPresence()
            }
        }
        .onChange(of: store.phase) {
            if store.phase == .ready { if case .authorize? = sheet { sheet = nil } }
            else { if case .authorize? = sheet {} else { sheet = nil } }
        }
        #if !os(macOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.phase == .ready && !store.browsingProjects { projectsButton.labelStyle(.iconOnly) }
                if store.browsingProjects || store.section != .chats { Button(L10n.text("common.refresh"), systemImage: "arrow.clockwise") { refresh() }.disabled(store.isRefreshing) }
                if store.localDraftPersonId != nil { draftsButton }
            }
        }
        #endif
    }
    #if os(macOS)
    /// The organization being looked at, named where every scoped screen
    /// names its scope.
    private var chromeScope: ScopeChip? {
        guard store.phase == .ready else { return nil }
        if store.browsingProjects { return ScopeChip(label: L10n.text("common.teams.shared_projects"), symbol: "folder.fill.badge.person.crop") }
        if let organization = store.selectedOrganization { return ScopeChip(label: organization.name, symbol: "person.2.fill") }
        return nil
    }
    #endif
    private func leaveToHub() {
        if store.browsingProjects { store.show(.overview) }
        store.select(nil)
    }
    #if !os(macOS)
    private var projectsButton: some View {
        Button(L10n.text("common.teams.shared_projects"), .team) { store.showProjects() }
            .accessibilityIdentifier("team.projects.open")
    }
    private var draftsButton: some View {
        HStack(spacing: Theme.Space.s) {
            Button(L10n.text("common.teams.comment_drafts"), systemImage: "square.and.pencil") { showingDrafts = true }
                .accessibilityIdentifier("team.drafts.open")
            Button(L10n.text("common.teams.saved_asks"), systemImage: "clock.arrow.circlepath") { showingSavedAsks = true }
                .labelStyle(.iconOnly).accessibilityIdentifier("team.asks.open")
        }
    }
    #endif
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
                    .accessibilityIdentifier("team.authorization.open")
            }
        case .failed:
            EmptyState(symbol: "wifi.exclamationmark", title: L10n.text("common.teams.load_failed"), message: L10n.text("common.teams.retry_detail")) {
                Button(L10n.text("common.retry"), .refresh) { refresh() }.buttonStyle(TeamButtonStyle(primary: true))
            }
        case .ready:
            if store.browsingProjects {
                TeamProjectBrowser(store: store) { leaveToHub() }
            } else if let organization = store.selectedOrganization {
                organizationContent(organization)
            } else { hubContent }
        }
    }
    @ViewBuilder private func organizationNavigation(_ organization: TeamOrganization) -> some View {
        #if os(macOS)
        TabStrip(tabs: TeamSection.allCases.map { ($0, $0.label, $0.symbol) }, selection: $store.section)
        organizationNotice(organization)
        #else
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if textSize.isAccessibilitySize {
                sectionPicker.pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: Theme.Space.m) {
                    TeamRoleBadge(text: organization.role.label)
                    Spacer(minLength: 0)
                    sectionPicker.pickerStyle(.menu)
                }
            }
            organizationNotice(organization)
        }
        .padding(Theme.Space.m)
        .background(Theme.sidebar)
        #endif
    }
    @ViewBuilder private func organizationNotice(_ organization: TeamOrganization) -> some View {
        Group {
            if !organization.eligible {
                TeamNotice(message: organization.role == .owner ? L10n.text("common.teams.owner_plan_recovery") : L10n.text("common.teams.member_plan_recovery"), warning: true)
            } else if organization.state != "active" {
                TeamNotice(message: L10n.text("common.teams.organization_paused"), warning: true)
            }
        }
        #if os(macOS)
        .padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.m)
        #endif
    }
    #if !os(macOS)
    private var sectionPicker: some View {
        Picker(L10n.text("common.teams.section"), selection: $store.section) {
            ForEach(TeamSection.allCases) { section in Text(section.label).tag(section) }
        }
    }
    #endif
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
            case .overview:
                TeamOrganizationOverview(store: store, directory: directory,
                    invite: { if let context = store.mutationContext { sheet = .invite(context) } },
                    addProject: { if let context = store.mutationContext { sheet = .repository(context) } })
            case .members: membersContent(directory)
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
    private var hubContent: some View {
        TeamPage(title: L10n.text("common.teams.title"), subtitle: L10n.text("common.teams.hub_detail")) {
            Button(L10n.text("common.teams.create_organization"), .create) { openCreate() }.buttonStyle(TeamButtonStyle(primary: true))
        } content: {
            if !store.inbox.isEmpty { inboxContent }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TeamGroupHeading(title: L10n.text("common.teams.organizations"))
                if store.organizations.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Image(systemName: "person.2.crop.square.stack").font(Theme.font(32, weight: .light)).foregroundStyle(TeamColors.action).accessibilityHidden(true)
                        Text(L10n.text("common.teams.no_organizations")).font(Theme.title2.weight(.semibold))
                        Text(L10n.text("common.teams.no_organizations_detail")).font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Label(L10n.text("common.teams.setup_people"), systemImage: "person.badge.plus")
                            Label(L10n.text("common.teams.setup_projects"), systemImage: "folder.badge.person.crop")
                            Label(L10n.text("common.teams.setup_conversations"), systemImage: "bubble.left.and.bubble.right")
                        }.font(Theme.callout).foregroundStyle(.secondary)
                    }.padding(Theme.cardPadding).frame(maxWidth: .infinity, alignment: .leading).teamCard()
                } else {
                    LazyVGrid(columns: textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 300), spacing: Theme.Space.m, alignment: .top)], alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(store.organizations) { organization in
                            if let context = store.mutationContext {
                                TeamOrganizationCard(store: store, organization: organization, context: context)
                                    .id("\(store.selectionKey)-\(organization.id)")
                            }
                        }
                    }
                }
                if store.organizationsNextOffset != nil {
                    Button(L10n.text("common.teams.more_organizations"), .more) { Task { await store.loadMoreOrganizations() } }
                        .buttonStyle(TeamButtonStyle()).disabled(store.isRefreshing)
                }
            }
            if store.inbox.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    TeamGroupHeading(title: L10n.text("common.teams.your_invitations"))
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: "envelope").font(Theme.font(15)).foregroundStyle(.secondary).frame(width: 32).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("common.teams.no_pending_invitations")).font(Theme.body.weight(.medium))
                            Text(L10n.text("common.teams.invitation_inbox_hint")).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.teamRowPadding().teamCard()
                }
            }
        }
    }
    private var inboxContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TeamGroupHeading(title: L10n.text("common.teams.your_invitations"))
            TeamListCard(items: store.inbox) { invitation in
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "envelope.badge").font(Theme.font(15)).foregroundStyle(TeamColors.action).frame(width: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.organizationName ?? L10n.text("common.teams.organization")).font(Theme.body.weight(.medium))
                        Text(invitation.role.label).font(Theme.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.m)
                    Button(L10n.text("common.teams.review_invitation"), .preview) {
                        if let context = store.mutationContext { sheet = .accept(context, invitation) }
                    }.buttonStyle(TeamButtonStyle(primary: true))
                }.teamRowPadding()
            }
            if store.inboxNextOffset != nil {
                Button(L10n.text("common.teams.more_invitations"), .more) { Task { await store.loadMoreInbox() } }.buttonStyle(TeamButtonStyle())
            }
        }
    }
    private func membersContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        let members = directory.members.members.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.handle?.localizedStandardContains(query) ?? false) }
        return TeamPage(title: L10n.text("common.teams.members"), subtitle: L10n.text("common.teams.member_list_detail")) {
            TextField(L10n.text("common.search"), text: $query).textFieldStyle(ThemedFieldStyle(small: true)).frame(width: 200)
            if organization.role.canManage {
                Button(L10n.text("common.teams.invite_member"), .invite) { if let context = store.mutationContext { sheet = .invite(context) } }
                    .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
            }
        } content: {
            if members.isEmpty {
                Text(L10n.text("common.teams.no_matching_members")).font(Theme.callout).foregroundStyle(.secondary).teamRowPadding().teamCard()
            } else {
                TeamListCard(items: members) { member in
                    HStack(spacing: Theme.Space.m) {
                        TeamMemberLabel(store: store, member: member, organization: organization.id)
                        Spacer(minLength: Theme.Space.m)
                        if !member.eligible {
                            Label(L10n.text("common.teams.needs_patron"), systemImage: "exclamationmark.circle").font(Theme.callout).foregroundStyle(TeamColors.warning)
                        }
                        TeamRoleBadge(text: member.role.label)
                        memberMenu(member, organization: organization)
                            .frame(width: Theme.Control.heightComfortable)
                    }.teamRowPadding()
                }
            }
            if directory.members.nextOffset != nil { moreButton(.members) }
        }
    }
    @ViewBuilder private func memberMenu(_ member: TeamMember, organization: TeamOrganization) -> some View {
        let canChangeRole = organization.role == .owner && member.role != .owner && organization.isActive
        let canRemove = member.role != .owner && (organization.role == .owner || (organization.role == .admin && member.role == .member))
        if canChangeRole || canRemove {
            TeamRowMenu(label: L10n.text("common.teams.manage_member", member.name)) {
                if canChangeRole { Button(L10n.text("common.teams.change_role")) { if let context = store.mutationContext { sheet = .memberRole(context, member) } } }
                if canRemove { Button(L10n.text("common.teams.remove_member"), role: .destructive) { if let context = store.mutationContext { sheet = .remove(context, member) } } }
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
    private func invitationsContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        return TeamPage(title: L10n.text("common.teams.invitations"), subtitle: L10n.text("common.teams.invitation_list_detail")) {
            if organization.role.canManage {
                Button(L10n.text("common.teams.invite_member"), .invite) { if let context = store.mutationContext { sheet = .invite(context) } }
                    .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
            }
        } content: {
            if !organization.role.canManage {
                EmptyState(symbol: "person.badge.plus", title: L10n.text("common.teams.invitation_admin"), message: L10n.text("common.teams.invitation_admin_detail")).teamCard()
            } else if directory.invitations.invitations.isEmpty {
                EmptyState(symbol: "envelope", title: L10n.text("common.teams.no_invitations"), message: L10n.text("common.teams.invite_empty_detail")).teamCard()
            } else {
                TeamListCard(items: directory.invitations.invitations) { invitation in
                    HStack(spacing: Theme.Space.m) {
                        if let recipient = invitation.recipient {
                            TeamPersonLabel(id: recipient.id, name: recipient.name, handle: recipient.handle, avatar: recipient.avatar, owner: store.owner)
                        } else { Text(L10n.text("common.teams.member_unavailable")).font(Theme.body) }
                        Spacer(minLength: Theme.Space.m)
                        Text(invitationState(invitation.state)).font(Theme.callout)
                            .foregroundStyle(invitation.state == "pending" ? TeamColors.action : .secondary)
                        TeamRoleBadge(text: invitation.role.label)
                        Group {
                            if (invitation.state == "pending" || invitation.state == "expired") && (invitation.role != .admin || organization.role == .owner) {
                                TeamRowMenu(label: L10n.text("common.teams.manage_invitation")) {
                                    Button(L10n.text("common.teams.new_invitation_link")) { if let context = store.mutationContext { sheet = .invitationAction(context, invitation, renewing: true) } }
                                        .disabled(!organization.isActive)
                                    Button(L10n.text("common.teams.revoke_invitation"), role: .destructive) { if let context = store.mutationContext { sheet = .invitationAction(context, invitation, renewing: false) } }
                                }.disabled(store.isMutating)
                            } else { Color.clear.frame(height: 1) }
                        }.frame(width: Theme.Control.heightComfortable)
                    }.teamRowPadding()
                }
            }
            if organization.role.canManage, directory.invitations.nextOffset != nil { moreButton(.invitations) }
        }
    }
    private func repositoriesContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        return TeamPage(title: L10n.text("common.teams.repositories"), subtitle: L10n.text("common.teams.repository_list_detail")) {
            if store.capabilities?.canPublishCheckouts == true && (organization.role.canManage || directory.repositories.repositories.contains { $0.role == .contributor || $0.role == .maintainer }) {
                Button(L10n.text("common.teams.share_project"), .connect) { if let context = store.mutationContext { sheet = .repository(context) } }
                    .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
            }
        } content: {
            if directory.repositories.repositories.isEmpty {
                EmptyState(symbol: "folder", title: L10n.text("common.teams.no_repositories"), message: organization.role.canManage ? L10n.text("common.teams.no_repositories_admin") : L10n.text("common.teams.no_repositories_member")).teamCard()
            } else {
                LazyVStack(spacing: Theme.Space.m) {
                    ForEach(directory.repositories.repositories) { repository in
                        if let context = store.mutationContext {
                            TeamRepositoryRow(store: store, context: context, repository: repository, organization: organization,
                                openChats: { store.selectedRepositoryId = repository.id; store.show(.chats) },
                                openCheckouts: { sheet = .checkouts(context, repository) },
                                manageAccess: { sheet = .access(context, repository) },
                                rename: { sheet = .renameRepository(context, repository) })
                        }
                    }
                }
            }
            if directory.repositories.nextOffset != nil { moreButton(.repositories) }
        }
    }
    private func settingsContent(_ organization: TeamOrganization) -> some View {
        TeamPage(title: L10n.text("common.teams.section_settings"), subtitle: L10n.text("common.teams.settings_detail")) {
            EmptyView()
        } content: {
            settingsGroup(L10n.text("common.teams.organization")) {
                TeamSettingRow(title: L10n.text("common.teams.organization_name"), detail: organization.name) {
                    if organization.role.canManage {
                        Button(L10n.text("common.teams.rename_organization"), .edit) { if let context = store.mutationContext { sheet = .rename(context) } }
                            .buttonStyle(TeamButtonStyle()).disabled(!organization.isActive)
                    }
                }
                ThemeRule().padding(.leading, Theme.cardPadding)
                TeamSettingRow(title: L10n.text("common.teams.organization_address"), detail: "@" + organization.slug) { EmptyView() }
                ThemeRule().padding(.leading, Theme.cardPadding)
                TeamSettingRow(title: L10n.text("common.teams.your_role"), detail: nil) { TeamRoleBadge(text: organization.role.label) }
                ThemeRule().padding(.leading, Theme.cardPadding)
                TeamSettingRow(title: L10n.text("common.teams.plan"), detail: L10n.text("common.teams.plan_detail")) {
                    Button(L10n.text("common.teams.view_plan"), .plans, action: onAccount).buttonStyle(TeamButtonStyle())
                }
            }
            if let request = store.directory?.details.ownershipRequest, request.toUserId == store.capabilities?.actorId {
                settingsGroup(L10n.text("common.teams.ownership_request")) {
                    if !request.current { TeamNotice(message: L10n.text("common.teams.ownership_stale"), warning: true).padding(Theme.Space.m) }
                    TeamSettingRow(title: L10n.text("common.teams.review_ownership"), detail: L10n.text("common.teams.ownership_accept_detail")) {
                        Button(L10n.text("common.teams.review_ownership"), .approve) { if let context = store.mutationContext { sheet = .ownershipDecision(context, request, cancelling: false) } }
                            .buttonStyle(TeamButtonStyle(primary: true)).disabled(!request.current || store.isMutating)
                    }
                }
            }
            if organization.role == .owner {
                settingsGroup(L10n.text("common.teams.ownership")) {
                    if let request = store.directory?.details.ownershipRequest, request.fromUserId == store.capabilities?.actorId {
                        TeamSettingRow(title: L10n.text("common.teams.ownership_request"), detail: request.current ? L10n.text("common.teams.ownership_pending") : L10n.text("common.teams.ownership_stale")) {
                            Button(L10n.text("common.teams.cancel_ownership_request"), .revoke) { if let context = store.mutationContext { sheet = .ownershipDecision(context, request, cancelling: true) } }
                                .buttonStyle(TeamButtonStyle()).disabled(request.requestId == nil || store.isMutating)
                        }
                        ThemeRule().padding(.leading, Theme.cardPadding)
                    }
                    TeamSettingRow(title: L10n.text("common.teams.transfer_ownership"), detail: L10n.text("common.teams.owner_detail")) {
                        Button(L10n.text("common.teams.transfer_ownership"), .move) { if let context = store.mutationContext { sheet = .transfer(context) } }.buttonStyle(TeamButtonStyle())
                    }
                }
                settingsGroup(L10n.text("common.teams.danger_zone")) {
                    TeamSettingRow(title: L10n.text("common.teams.delete_organization"), detail: L10n.text("common.teams.delete_detail")) {
                        Button(L10n.text("common.teams.delete_organization"), .delete, role: .destructive) { if let context = store.mutationContext { sheet = .delete(context) } }.buttonStyle(TeamButtonStyle())
                    }
                }
            } else {
                settingsGroup(L10n.text("common.teams.danger_zone")) {
                    TeamSettingRow(title: L10n.text("common.teams.leave_organization"), detail: L10n.text("common.teams.leave_detail")) {
                        Button(L10n.text("common.teams.leave_organization"), .signOut, role: .destructive) { if let context = store.mutationContext { sheet = .leave(context) } }.buttonStyle(TeamButtonStyle())
                    }
                }
            }
        }
    }
    private func settingsGroup<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TeamGroupHeading(title: title)
            VStack(spacing: 0) { rows() }.teamCard()
        }
    }
    private func moreButton(_ section: TeamSection) -> some View {
        Button(L10n.text("common.teams.load_more"), .more) { Task { await store.loadMore(section) } }
            .buttonStyle(TeamButtonStyle()).disabled(store.isLoadingDirectory)
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
