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
            if store.phase == .ready, !compactReader {
                if let org = store.selectedOrganization, !store.browsingProjects { organizationNavigation(org) }
                else { hubToolbar }
            }
            if let error = store.error {
                TeamNotice(message: error, warning: true).padding([.horizontal, .top], Theme.Space.m)
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
            // One control in a phone's crowded bar. Four icons pushed the
            // app's own name into an ellipsis.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if store.phase == .ready && !store.browsingProjects {
                        Button(L10n.text("common.teams.shared_projects"), systemImage: "folder.badge.person.crop") { store.showProjects() }
                    }
                    if store.localDraftPersonId != nil {
                        Button(L10n.text("common.teams.comment_drafts"), systemImage: "square.and.pencil") { showingDrafts = true }
                        Button(L10n.text("common.teams.saved_asks"), systemImage: "clock.arrow.circlepath") { showingSavedAsks = true }
                    }
                    Button(L10n.text("common.refresh"), systemImage: "arrow.clockwise") { refresh() }.disabled(store.isRefreshing)
                } label: {
                    Label(L10n.text("common.teams.more_actions"), systemImage: "ellipsis")
                }
                .accessibilityIdentifier("team.more")
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
            // A signed-in device turns Teams on by itself. Only a device the
            // person removed from Teams lands here, so say that plainly.
            let removed = store.capabilities?.deviceRemoved == true
            EmptyState(symbol: "person.2",
                title: removed ? L10n.text("common.teams.device_removed_title") : L10n.text("common.teams.enable_title"),
                message: removed ? L10n.text("common.teams.device_removed_detail") : L10n.text("common.teams.enable_detail")) {
                Button(L10n.text("common.teams.enable_action"), .team) { sheet = .authorize }.buttonStyle(TeamButtonStyle(primary: true))
                    .accessibilityIdentifier("team.authorization.open")
            }
        case .failed:
            EmptyState(symbol: "wifi.exclamationmark", title: L10n.text("common.teams.load_failed"), message: L10n.text("common.teams.retry_detail")) {
                Button(L10n.text("common.retry"), .refresh) { refresh() }.buttonStyle(TeamButtonStyle(primary: true))
            }
        case .ready:
            if store.browsingProjects {
                TeamProjectBrowser(store: store)
            } else if let organization = store.selectedOrganization {
                organizationContent(organization)
            } else { hubContent }
        }
    }
    @ViewBuilder private func organizationNavigation(_ organization: TeamOrganization) -> some View {
        #if os(macOS)
        TeamToolbarRow {
            SegmentedTabs(options: TeamSection.allCases, selection: $store.section, title: { $0.label })
                .frame(maxWidth: 640)
                .accessibilityLabel(L10n.text("common.teams.section"))
        } trailing: {
            if let directory = store.directory { sectionActions(directory) }
        }
        organizationNotice(organization)
        #else
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if textSize.isAccessibilitySize {
                sectionPicker.pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TeamSectionChips(selection: $store.section)
            }
            if let directory = store.directory {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { Spacer(minLength: 0); sectionActions(directory) }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { sectionActions(directory) }
                }
            }
            organizationNotice(organization)
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.m)
        .background(Theme.background)
        .overlay(alignment: .bottom) { ThemeRule() }
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
        .padding([.horizontal, .top], Theme.Space.m)
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
    /// The team list and every shared project are the two views of the same
    /// place, so they are its tabs, the way Devices and Access are.
    @ViewBuilder private var hubToolbar: some View {
        #if os(macOS)
        TeamToolbarRow {
            SegmentedTabs(options: TeamHubPage.allCases, selection: Binding(
                get: { store.browsingProjects ? TeamHubPage.projects : .organizations },
                set: { $0 == .projects ? store.showProjects() : leaveToHub() }), title: { $0.label })
                .frame(maxWidth: 320)
                .accessibilityIdentifier("team.projects.open")
        } trailing: {
            if !store.browsingProjects {
                Button(L10n.text("common.teams.create_organization"), .create) { openCreate() }.buttonStyle(TeamSmallButtonStyle(primary: true))
            }
        }
        #endif
    }
    /// The trailing actions of an organization's toolbar row: what this
    /// section adds to, never navigation.
    @ViewBuilder private func sectionActions(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        switch store.section {
        case .overview, .invitations:
            if organization.role.canManage { inviteButton(organization) }
        case .members:
            TextField(L10n.text("common.search"), text: $query).textFieldStyle(ThemedFieldStyle(small: true)).frame(width: 200)
            if organization.role.canManage { inviteButton(organization) }
        case .repositories:
            if store.capabilities?.canPublishCheckouts == true && (organization.role.canManage || directory.repositories.repositories.contains { $0.role == .contributor || $0.role == .maintainer }) {
                Button(L10n.text("common.teams.share_project"), .connect) { if let context = store.mutationContext { sheet = .repository(context) } }
                    .buttonStyle(TeamSmallButtonStyle(primary: true)).disabled(!organization.isActive)
            }
        case .chats, .settings:
            EmptyView()
        }
    }
    private func inviteButton(_ organization: TeamOrganization) -> some View {
        Button(L10n.text("common.teams.invite_member"), .invite) { if let context = store.mutationContext { sheet = .invite(context) } }
            .buttonStyle(TeamSmallButtonStyle(primary: true)).disabled(!organization.isActive)
    }
    private var hubContent: some View {
        TeamPage {
            #if !os(macOS)
            Button(L10n.text("common.teams.create_organization"), .create) { openCreate() }.buttonStyle(TeamButtonStyle(primary: true))
            #endif
            if !store.inbox.isEmpty { inboxContent }
            Card(title: L10n.text("common.teams.organizations"), subtitle: L10n.text("common.teams.hub_detail"), mark: "mark_account") {
                if store.organizations.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(L10n.text("common.teams.no_organizations")).font(Theme.body.weight(.semibold))
                        Text(L10n.text("common.teams.no_organizations_detail")).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Label(L10n.text("common.teams.setup_people"), systemImage: "person.badge.plus")
                            Label(L10n.text("common.teams.setup_projects"), systemImage: "folder.badge.person.crop")
                            Label(L10n.text("common.teams.setup_conversations"), systemImage: "bubble.left.and.bubble.right")
                        }.font(Theme.callout).foregroundStyle(.secondary).padding(.top, Theme.Space.xs)
                    }
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
                        .buttonStyle(TeamSmallButtonStyle()).disabled(store.isRefreshing)
                }
            }
            if store.inbox.isEmpty {
                Card(title: L10n.text("common.teams.your_invitations"), subtitle: L10n.text("common.teams.invitation_inbox_hint"), mark: "mark_note",
                    accessory: AnyView(Text(L10n.text("common.teams.no_pending_invitations")).font(Theme.callout).foregroundStyle(.secondary)))
            }
        }
    }
    private var inboxContent: some View {
        Card(title: L10n.text("common.teams.your_invitations"), subtitle: L10n.text("common.teams.inbox_detail"), mark: "mark_note") {
            TeamRows(items: store.inbox) { invitation in
                HStack(spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.organizationName ?? L10n.text("common.teams.organization")).font(Theme.body.weight(.medium))
                        Text(invitation.role.label).font(Theme.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.m)
                    Button(L10n.text("common.teams.review_invitation"), .preview) {
                        if let context = store.mutationContext { sheet = .accept(context, invitation) }
                    }.buttonStyle(TeamSmallButtonStyle(primary: true))
                }.teamRowPadding()
            }
            if store.inboxNextOffset != nil {
                Button(L10n.text("common.teams.more_invitations"), .more) { Task { await store.loadMoreInbox() } }.buttonStyle(TeamSmallButtonStyle())
            }
        }
    }
    private func membersContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        let members = directory.members.members.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.handle?.localizedStandardContains(query) ?? false) }
        return TeamPage {
            Card(title: L10n.text("common.teams.members"), subtitle: L10n.text("common.teams.member_list_detail"), mark: "mark_account") {
                if members.isEmpty {
                    Text(L10n.text("common.teams.no_matching_members")).font(Theme.callout).foregroundStyle(.secondary)
                } else {
                    TeamRows(items: members) { member in
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
        return TeamPage {
            Card(title: L10n.text("common.teams.invitations"), subtitle: L10n.text("common.teams.invitation_list_detail"), mark: "mark_note") {
                if !organization.role.canManage {
                    EmptyState(symbol: "person.badge.plus", title: L10n.text("common.teams.invitation_admin"), message: L10n.text("common.teams.invitation_admin_detail"))
                } else if directory.invitations.invitations.isEmpty {
                    EmptyState(symbol: "envelope", title: L10n.text("common.teams.no_invitations"), message: L10n.text("common.teams.invite_empty_detail"))
                } else {
                    TeamRows(items: directory.invitations.invitations) { invitation in
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
    }
    private func repositoriesContent(_ directory: TeamDirectorySnapshot) -> some View {
        let organization = directory.details.organization
        return TeamPage {
            if directory.repositories.repositories.isEmpty {
                Card(title: L10n.text("common.teams.repositories"), subtitle: L10n.text("common.teams.repository_list_detail"), mark: "mark_folder") {
                    EmptyState(symbol: "folder", title: L10n.text("common.teams.no_repositories"), message: organization.role.canManage ? L10n.text("common.teams.no_repositories_admin") : L10n.text("common.teams.no_repositories_member"))
                }
            } else {
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
            if directory.repositories.nextOffset != nil { moreButton(.repositories) }
        }
    }
    private func settingsContent(_ organization: TeamOrganization) -> some View {
        TeamPage {
            Card(title: L10n.text("common.teams.organization"), subtitle: L10n.text("common.teams.settings_detail"), mark: "mark_account") {
                VStack(spacing: 0) {
                    TeamSettingRow(title: L10n.text("common.teams.organization_name"), detail: organization.name) {
                        if organization.role.canManage {
                            Button(L10n.text("common.teams.rename_organization"), .edit) { if let context = store.mutationContext { sheet = .rename(context) } }
                                .buttonStyle(TeamSmallButtonStyle()).disabled(!organization.isActive)
                        }
                    }
                    ThemeRule()
                    TeamSettingRow(title: L10n.text("common.teams.organization_address"), detail: "@" + organization.slug) { EmptyView() }
                    ThemeRule()
                    TeamSettingRow(title: L10n.text("common.teams.your_role"), detail: nil) { TeamRoleBadge(text: organization.role.label) }
                    ThemeRule()
                    TeamSettingRow(title: L10n.text("common.teams.plan"), detail: L10n.text("common.teams.plan_detail")) {
                        Button(L10n.text("common.teams.view_plan"), .plans, action: onAccount).buttonStyle(TeamSmallButtonStyle())
                    }
                }
            }
            if let request = store.directory?.details.ownershipRequest, request.toUserId == store.capabilities?.actorId {
                Card(title: L10n.text("common.teams.ownership_request"), subtitle: L10n.text("common.teams.ownership_accept_detail"), mark: "mark_account") {
                    if !request.current { TeamNotice(message: L10n.text("common.teams.ownership_stale"), warning: true) }
                    TeamSettingRow(title: L10n.text("common.teams.review_ownership"), detail: nil) {
                        Button(L10n.text("common.teams.review_ownership"), .approve) { if let context = store.mutationContext { sheet = .ownershipDecision(context, request, cancelling: false) } }
                            .buttonStyle(TeamSmallButtonStyle(primary: true)).disabled(!request.current || store.isMutating)
                    }
                }
            }
            if organization.role == .owner {
                Card(title: L10n.text("common.teams.ownership"), subtitle: L10n.text("common.teams.owner_detail"), mark: "mark_account") {
                    VStack(spacing: 0) {
                        if let request = store.directory?.details.ownershipRequest, request.fromUserId == store.capabilities?.actorId {
                            TeamSettingRow(title: L10n.text("common.teams.ownership_request"), detail: request.current ? L10n.text("common.teams.ownership_pending") : L10n.text("common.teams.ownership_stale")) {
                                Button(L10n.text("common.teams.cancel_ownership_request"), .revoke) { if let context = store.mutationContext { sheet = .ownershipDecision(context, request, cancelling: true) } }
                                    .buttonStyle(TeamSmallButtonStyle()).disabled(request.requestId == nil || store.isMutating)
                            }
                            ThemeRule()
                        }
                        TeamSettingRow(title: L10n.text("common.teams.transfer_ownership"), detail: nil) {
                            Button(L10n.text("common.teams.transfer_ownership"), .move) { if let context = store.mutationContext { sheet = .transfer(context) } }.buttonStyle(TeamSmallButtonStyle())
                        }
                    }
                }
                Card(title: L10n.text("common.teams.danger_zone"), subtitle: L10n.text("common.teams.delete_detail"), mark: "mark_delete", markTint: Theme.danger) {
                    TeamSettingRow(title: L10n.text("common.teams.delete_organization"), detail: nil) {
                        Button(L10n.text("common.teams.delete_organization"), .delete, role: .destructive) { if let context = store.mutationContext { sheet = .delete(context) } }.buttonStyle(TeamSmallButtonStyle())
                    }
                }
            } else {
                Card(title: L10n.text("common.teams.danger_zone"), subtitle: L10n.text("common.teams.leave_detail"), mark: "mark_delete", markTint: Theme.danger) {
                    TeamSettingRow(title: L10n.text("common.teams.leave_organization"), detail: nil) {
                        Button(L10n.text("common.teams.leave_organization"), .signOut, role: .destructive) { if let context = store.mutationContext { sheet = .leave(context) } }.buttonStyle(TeamSmallButtonStyle())
                    }
                }
            }
        }
    }
    private func moreButton(_ section: TeamSection) -> some View {
        Button(L10n.text("common.teams.load_more"), .more) { Task { await store.loadMore(section) } }
            .buttonStyle(TeamSmallButtonStyle()).disabled(store.isLoadingDirectory)
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
