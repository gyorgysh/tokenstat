// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

struct ClientWorkspacesView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientDevicesModel.self) private var devices
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ClientWorkspacesModel
    @State private var pendingClose: (peer: String, info: PtySessionInfo)?
    @State private var notificationOpen = NotificationOpen.shared
    @Environment(ClientSetupSession.self) private var setup
    @State private var customizing = false
    @State private var addingFirstProject = false
    @State private var cloningFirstProject = false
    @State private var layout = WorkspacesLayout.shared
    @State private var expandedHostFolders: Set<String> = []
    @State private var expandedHostSessions: Set<String> = []
    @State private var expandedHostList = false
    @State private var handledFolderHandoff: String?
    @State private var starting: WorkspaceSection?
    @State private var startingOnHost: String?
    private func autoConnectBinding(for peerKey: String) -> Binding<Bool> {
        Binding(
            get: { model.isAutoConnectEnabled(for: peerKey) },
            set: { model.setAutoConnect($0, for: peerKey) }
        )
    }

    private func isAutoConnectEnabled(for peerKey: String) -> Bool {
        model.isAutoConnectEnabled(for: peerKey)
    }

    private let handlesNotifications: Bool

    @MainActor
    init(model: ClientWorkspacesModel, handlesNotifications: Bool) {
        self.handlesNotifications = handlesNotifications
        _model = State(initialValue: model)
    }

    private var remoteAllowed: Bool {
        if let remote = account.account?.canRemote { return remote }
        let tier = account.account?.tier?.lowercased()
        return ["free", "supporter", "patron", "legend"].contains(tier)
    }

    private var workspaceDevicePresented: Binding<Bool> {
        Binding(
            get: { workspaceDevice != nil },
            set: { presented in
                if !presented { navigation.workspacesDeviceMachineID = nil }
            }
        )
    }

    private var pendingClosePresented: Binding<Bool> {
        Binding(
            get: { pendingClose != nil },
            set: { presented in
                if !presented { pendingClose = nil }
            }
        )
    }

    private var pendingCloseMessage: String {
        guard let peer = pendingClose?.peer,
              let host = model.hosts.first(where: { $0.peerKey == peer }) else {
            return L10n.text("apple.clientworkspacesview.stops_the_process_on_the_computer.c5651cd1")
        }
        return L10n.text("apple.clientworkspacesview.stops_the_process_on_0.7aa0b494", host.name)
    }

    private static let accessCardID = "awaiting-access"

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { scroller in
            ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if let message = model.errorMessage {
                            ClientErrorCard(message: message) {
                                Task { await model.refresh(account: account.account) }
                            }
                        }
                        if let message = model.infoMessage {
                            HStack(alignment: .top, spacing: Theme.Space.s) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                Text(message)
                                    .font(ClientType.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(Theme.Space.m)
                            .cardSurface()
                        }

                        if !remoteAllowed, account.signedIn {
                            ClientEmptyState(
                                kind: .needsAccount,
                                title: L10n.text("apple.clientworkspacesview.remote_is_on_patron.d25dea13"),
                                message: L10n.text("apple.clientworkspacesview.this_device_already_shares_the_account_and.b2e29485"),
                                actionTitle: L10n.text("common.refresh"),
                                actionIcon: .refresh,
                                action: { Task { await account.load() } },
                                art: .remoteGate
                            )
                        } else if model.hosts.isEmpty {
                            ClientEmptyState(
                                kind: .nothingYet,
                                title: L10n.text("apple.clientworkspacesview.no_machine_yet.3ea83dc9"),
                                message: L10n.text("apple.clientworkspacesview.tokenstat_runs_agents_on_a_machine_that_st.93fe9732"),
                                actionTitle: L10n.text("apple.clientworkspacesview.set_up_a_machine.43e10e13"),
                                actionIcon: .connect,
                                action: { setup.open() },
                                art: .connect
                            )
                        } else {
                            ClientSectionTitle(title: L10n.text("apple.clientworkspacesview.computers_on_your_account.232226fe"), mark: "mark_host")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)

                            if model.hosts.count > 1 {
                                compactHostList
                            } else {
                                ForEach(model.hosts) { host in
                                    hostCard(host)
                                }
                            }
                        }

                        if model.hosts.count <= 1 { thisDeviceRow }
                        ClientSecurityCard(
                            peerKey: model.hosts.count == 1 ? model.connectedKey : nil,
                            peerName: model.hosts.count == 1
                                ? model.hosts.first { $0.peerKey == model.connectedKey }?.name : nil
                        )
                        if let host = model.awaitingAccessHost {
                            ClientAwaitingAccessCard(
                                hostName: host,
                                peerKey: model.awaitingAccessPeerKey ?? "",
                                isHeadless: isHeadlessHost(named: host),
                                onGranted: {
                                    if let peer = model.awaitingAccessPeerKey,
                                       let target = model.hosts.first(where: { $0.peerKey == peer }) {
                                        Task { await model.connect(target) }
                                    }
                                }
                            )
                            .id(Self.accessCardID)
                        }
                        if model.hosts.count > 1 {
                            multiHostWork
                        } else {
                            if let peer = model.connectedKey,
                               let host = model.hosts.first(where: { $0.peerKey == peer }),
                               host.online != false {
                                if model.folders.isEmpty, model.hosts.count == 1,
                                   model.isConnecting == nil, model.errorMessage == nil {
                                    ClientEmptyState(
                                        kind: .nothingYet,
                                        title: L10n.text("common.projects.first_title"),
                                        message: L10n.text("common.projects.remote_first_message", host.name),
                                        actionTitle: L10n.text("common.add_project"),
                                        actionIcon: .create,
                                        action: { addingFirstProject = true },
                                        art: .projects,
                                        secondaryActionTitle: L10n.text("apple.clienthostworkspacesview.clone_a_repository.749e5d4d"),
                                        secondaryActionIcon: .download,
                                        secondaryAction: { cloningFirstProject = true }
                                    )
                                }
                                if layout.allTasksVisible {
                                    ClientAllTasksLink(peer: peer, hostName: host.name)
                                        .padding(Theme.Space.m).cardSurface()
                                }
                                ForEach(layout.sections) { section in
                                    workSection(section, peer: peer, host: host)
                                }
                                if layout.sections.isEmpty {
                                    clearWorkspaces
                                }
                                customizeWorkspacesButton
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
                    .padding(.bottom, 96)
                }
                .onChange(of: model.awaitingAccessHost) { _, host in
                    guard host != nil else { return }
                    withAnimation { scroller.scrollTo(Self.accessCardID) }
                }
        }
            .background(Theme.background)
            .navigationDestination(isPresented: workspaceDevicePresented) {
                if let machine = workspaceDevice {
                    ClientDeviceDetailView(
                        machine: machine,
                        isThisDevice: false,
                        onRenamed: { await account.load() }
                    )
                }
            }
            .sheet(item: $starting) { section in
                if let peer = startingOnHost ?? model.connectedKey,
                   let host = model.hosts.first(where: { $0.peerKey == peer }) {
                    ClientFolderChooserSheet(
                        hostName: host.name,
                        folders: model.folders(for: peer),
                        title: section == .chat ? L10n.text("apple.clientworkspacesview.new_chat_in.510ac43f") : L10n.text("apple.clientworkspacesview.new_session_in.30d4568b")
                    ) { folder in
                        let raw = ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
                        navigation.open(folderID: "remote:\(peer):\(raw)", section: section)
                        navigation.pushFolder(peerKey: peer, hostName: host.name, folder: folder, section: section)
                    }
                }
            }
            .sheet(isPresented: $customizing) {
                ClientWorkspacesEditor(layout: layout)
            }
            .sheet(isPresented: $addingFirstProject) {
                if let peer = model.connectedKey,
                   let host = model.hosts.first(where: { $0.peerKey == peer }) {
                    NavigationStack {
                        ClientFolderPicker(peer: peer, hostName: host.name) { _ in
                            addingFirstProject = false
                            Task { await model.refresh(account: account.account) }
                        }
                    }
                }
            }
            .sheet(isPresented: $cloningFirstProject) {
                if let peer = model.connectedKey,
                   let host = model.hosts.first(where: { $0.peerKey == peer }) {
                    NavigationStack {
                        ClientCloneRepository(peer: peer, hostName: host.name) { _ in
                            cloningFirstProject = false
                            Task { await model.refresh(account: account.account) }
                        }
                    }
                }
            }
            .onChange(of: navigation.workspacesEditorRequested, initial: true) { _, requested in
                guard requested else { return }
                navigation.workspacesEditorRequested = false
                customizing = true
            }
            .navigationTitle(L10n.text("common.projects"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("apple.clientchatview.new_chat.db18382a"), .create) { navigation.openNewChat() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await ClientRefresh.pull("workspaces") {
                    await account.load()
                    await model.refresh(account: account.account)
                }
            }
            .task {
                await model.refresh(account: account.account)
                await model.autoConnectLastHost()
                openFolderHandoff()
                if handlesNotifications { await fulfillNotification() }
            }
            .onChange(of: notificationOpen.request) { _, _ in
                guard handlesNotifications else { return }
                Task { await fulfillNotification() }
            }
            .onChange(of: model.hosts) { _, _ in
                Task { await model.autoConnectLastHost() }
            }
            .onChange(of: navigation.folderID, initial: true) { _, _ in
                openFolderHandoff()
            }
            .onChange(of: model.connectedKey) { _, _ in
                openFolderHandoff()
            }
            .onChange(of: model.folders) { _, _ in
                openFolderHandoff()
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
                guard let key = model.connectedKey ?? model.lastConnectedHost,
                      isAutoConnectEnabled(for: key) else { return }
                Task { await model.recoverAfterNetworkChange(account: account.account) }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                guard let key = model.connectedKey else {
                    Task { await model.autoConnectLastHost() }
                    return
                }
                guard isAutoConnectEnabled(for: key) else { return }
                Task { await model.recoverAfterNetworkChange(account: account.account) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tokenstatEntitlementDidChange)) { _ in
                Task { await model.refresh(account: account.account) }
            }
            .confirmationDialog(
                L10n.text("apple.clientworkspacesview.close_this_session.2b66ce2d"),
                isPresented: pendingClosePresented,
                titleVisibility: .visible
            ) {
                Button(L10n.text("common.close"), role: .destructive) {
                    if let target = pendingClose {
                        Task { await model.closeSession(target.info, expectedPeer: target.peer) }
                    }
                    pendingClose = nil
                }
                Button(L10n.text("apple.clientworkspacesview.keep_it.fdce5da2"), role: .cancel) { pendingClose = nil }
            } message: {
                Text(pendingCloseMessage)
            }
    }

    private var workspaceDevice: Machine? {
        guard let id = navigation.workspacesDeviceMachineID else { return nil }
        return account.account?.machines.first { $0.machineID == id }
    }

    private func isHeadlessHost(named host: String) -> Bool {
        let machines = account.account?.machines ?? []
        let platform = machines.first {
            ($0.label?.isEmpty == false ? $0.label : $0.machineID) == host
        }?.platform
        return isHeadlessPlatform(platform) || isHeadlessPlatform(host)
    }

    private func fulfillNotification() async {
        guard let request = NotificationOpen.shared.request,
              let scope = WorkSessionContext.shared.scope, scope.kind == .account else { return }
        guard let opened = await model.targetFromNotification(request, account: account.account) else {
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
            if NotificationOpen.shared.dropIfStale() { landAfterFailedTap() }
            return
        }
        guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
              NotificationOpen.shared.request == request else { return }
        _ = NotificationOpen.shared.take()
        switch opened {
        case let .session(session):
            model.openSession(session)
        case let .chat(peer, hostName, folder, chat):
            guard !peer.isEmpty, !chat.id.isEmpty else {
                landAfterFailedTap()
                return
            }
            if navigation.isShowing(peer: peer, workspaceID: chat.workspaceID, chatID: chat.id) {
                if navigation.destination != .workspaces {
                    navigation.destination = .workspaces
                }
                return
            }
            navigation.presentedChat = PresentedChat(
                scope: scope,
                peer: peer,
                workspaceID: chat.workspaceID,
                folderName: folder?.name ?? L10n.text("apple.clientworkspacesview.project.98595978"),
                hostName: hostName,
                chatID: chat.id
            )
        }
    }

    private func landAfterFailedTap() {
        if navigation.destination != .workspaces {
            navigation.destination = .workspaces
        }
    }

    private func openFolderHandoff() {
        guard handlesNotifications,
              let folderID = navigation.folderID,
              handledFolderHandoff != folderID,
              let peer = model.connectedKey,
              let host = model.hosts.first(where: { $0.peerKey == peer }),
              let folder = model.folders.first(where: {
                  "remote:\(peer):\(ClientRemote.rawWorkspaceID(of: $0) ?? $0.id)" == folderID
              })
        else { return }
        handledFolderHandoff = folderID
        let push = ClientFolderPush(
            peerKey: peer,
            hostName: host.name,
            folder: folder,
            section: navigation.section
        )
        guard navigation.workspacesPath.last != push else { return }
        navigation.pushFolder(
            peerKey: peer,
            hostName: host.name,
            folder: folder,
            section: navigation.section,
            restoringLayout: true
        )
    }

    @ViewBuilder
    private func workSection(
        _ section: WorkspacesSection,
        peer: String,
        host: ClientHost
    ) -> some View {
        switch section {
        case .folders:
            foldersSection(peer: peer, hostName: host.name)
        case .recentChats:
            ClientRecentChatsSection(
                peer: peer,
                hostName: host.name,
                folders: model.folders,
                chats: model.recentChats,
                onNewChat: { navigation.openNewChat() }
            )
            .padding(.top, Theme.Space.s)
        case .sessions:
            sessionsSection
        }
    }

    @ViewBuilder
    private func foldersSection(peer: String, hostName: String) -> some View {
        if !model.folders.isEmpty {
            ClientSectionTitle(title: L10n.text("common.projects"), mark: "mark_archive")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.top, Theme.Space.s)
            ClientAdaptiveCards {
            ForEach(ChatStartPage.generalFirst(model.folders)) { folder in
                NavigationLink {
                    ClientWorkspaceDetailView(
                        peer: peer,
                        hostName: hostName,
                        folder: folder
                    )
                } label: {
                    ClientFolderRow(folder: folder)
                }
                .buttonStyle(.plain)
                .modifier(ClientProjectRename(peer: peer, folder: folder,
                    onChanged: { await model.refresh(account: account.account) }))
            }
            }
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        if !model.sessions.isEmpty || !model.folders.isEmpty {
            HStack(alignment: .center) {
                Text(L10n.text("apple.clientworkspacesview.all_sessions.78648d4d"))
                    .font(ClientType.sectionTitle)
                Spacer(minLength: Theme.Space.s)
                if !model.folders.isEmpty {
                    Button(L10n.text("apple.clientworkspacesview.new_terminal.fe544556"), .create) {
                        startingOnHost = nil
                        starting = .sessions
                    }
                        .font(ClientType.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, Theme.Space.s)
            if model.sessions.isEmpty {
                Text(L10n.text("apple.clientworkspacesview.nothing_running_start_one_from_a_folder.f1d69e99"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            } else {
                List {
                    ForEach(model.sessions) { session in
                        Button {
                            model.openSession(session)
                        } label: {
                            ClientSessionRow(session: session, displayName: SidebarTerminalNames.shared.name(peer: model.connectedKey ?? "", workspaceID: session.workspaceID, sessionID: session.id))
                        }
                        .buttonStyle(.plain)
                        .modifier(ClientTerminalActions(peer: model.connectedKey ?? "", workspaceID: session.workspaceID ?? "",
                            folderName: model.folders.first { ClientRemote.rawWorkspaceID(of: $0) == session.workspaceID || $0.id == session.workspaceID }?.name ?? L10n.text("apple.clientworkspacesview.project.98595978"),
                            info: session, onDuplicate: { copied in model.openSession(copied); Task { await model.refresh(account: account.account) } }))
                        .listRowInsets(EdgeInsets(
                            top: 0, leading: 0, bottom: Theme.Space.s, trailing: 0
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(L10n.text("common.close"), role: .destructive) {
                                if let peer = model.connectedKey { pendingClose = (peer, session) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(minHeight: CGFloat(model.sessions.count) * 78)
            }
        }
    }

    private var clearWorkspaces: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(L10n.text("apple.clientworkspacesview.your_projects_are_clear.c7d87ca8"))
                .font(ClientType.label.weight(.medium))
            Text(L10n.text("apple.clientworkspacesview.folders_chats_and_sessions_are_switched_of.2757c507"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .padding(.top, Theme.Space.s)
    }

    private var customizeWorkspacesButton: some View {
        Button(L10n.text("apple.clientworkspacesview.customize_projects.00ab91c5"), .layout) { customizing = true }
            .buttonStyle(.plain)
            .font(ClientType.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.top, Theme.Space.xs)
    }

    @ViewBuilder
    private var thisDeviceRow: some View {
        if let name = model.thisDeviceName {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 9, height: 9)
                FeatureMark(name: "mark_device", tint: Theme.accent, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(ClientType.label.weight(.medium))
                    Text(L10n.text("apple.clientworkspacesview.this_device.d052579c"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.text("common.online"))
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var compactHostList: some View {
        let ordered = model.hosts
        let shown = expandedHostList ? ordered : Array(ordered.prefix(3))
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.peerKey) { index, host in
                if index > 0 { ThemeRule().padding(.leading, Theme.Space.m) }
                compactHostRow(host)
            }
            if ordered.count > 3 {
                ThemeRule()
                Button {
                    expandedHostList.toggle()
                } label: {
                    Label(
                        expandedHostList
                            ? L10n.text("apple.clientrecentchats.show_less.94ea9b1d")
                            : L10n.text("apple.clientrecentchats.show_more_0_more.c732a4ba", "\(ordered.count - 3)"),
                        systemImage: expandedHostList ? "chevron.up" : "chevron.down"
                    )
                    .font(ClientType.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            if model.thisDeviceName != nil {
                ThemeRule().padding(.leading, Theme.Space.m)
                thisDeviceRow
                    .frame(minHeight: 64)
            }
        }
        .cardSurface()
    }

    private func compactHostRow(_ host: ClientHost) -> some View {
        let connected = model.loadedHostKeys.contains(host.peerKey) &&
            !model.staleHostKeys.contains(host.peerKey) && host.online != false
        let busy = model.isBusy(with: host.peerKey)
        return HStack(spacing: 0) {
            Button {
                if connected {
                    navigation.openWorkspaceDevice(machineID: host.machineID)
                } else if host.online != false {
                    Task { await model.connect(host) }
                }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Circle()
                        .fill(host.online == false ? Color.secondary.opacity(0.35) : Theme.accent)
                        .frame(width: 9, height: 9)
                    Image(systemName: ClientDeviceIcon.symbol(name: host.name, isHost: true))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                            .font(ClientType.label.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if connected {
                            ClientHostConnectionSummary(peer: host.peerKey)
                        } else {
                            Text(host.online == false ? L10n.text("common.offline") :
                                busy ? L10n.text("apple.clientworkspacesview.connecting.72021eb7") :
                                model.deniedHostKeys.contains(host.peerKey) ? L10n.text("apple.clienthostworkspacesview.request_access.b06f1662") :
                                model.staleHostKeys.contains(host.peerKey) ? L10n.text("apple.clientworkspacesview.needs_refresh.5b783f2d") :
                                L10n.text("apple.accountview.not_connected.0303e182"))
                                .font(ClientType.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Theme.Space.xs)
                    if connected && host.machineID != nil {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || (connected && host.machineID == nil) || (!connected && host.online == false))
            .accessibilityHint(connected
                ? L10n.text("apple.clientworkspacesview.open_device.021a82bd")
                : L10n.text("common.connect"))

            Menu {
                if let machineID = host.machineID {
                    Button(L10n.text("apple.clientworkspacesview.open_device.021a82bd"), systemImage: "desktopcomputer") {
                        navigation.openWorkspaceDevice(machineID: machineID)
                    }
                }
                Button {
                    model.setAutoConnect(!model.isAutoConnectEnabled(for: host.peerKey), for: host.peerKey)
                } label: {
                    Label(L10n.text("apple.clientworkspacesview.auto_connect.45b6d201"),
                          systemImage: model.isAutoConnectEnabled(for: host.peerKey) ? "checkmark.circle.fill" : "circle")
                }
                if connected {
                    Button(L10n.text("common.disconnect"), systemImage: "xmark.circle", role: .destructive) {
                        model.disconnectHost(host.peerKey)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(ClientType.label.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(host.name), \(L10n.text("apple.clientlaunchtile.more.d47d7cb0"))")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
    }

    private var multiHostWork: some View {
        let readyHosts = model.hosts.filter {
            model.loadedHostKeys.contains($0.peerKey) &&
            !model.staleHostKeys.contains($0.peerKey) && $0.online != false
        }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !readyHosts.isEmpty && (!layout.sections.isEmpty || layout.allTasksVisible) {
                ClientSectionTitle(title: L10n.text("apple.clientworkspacesview.work_by_computer"), mark: "mark_archive")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                ForEach(readyHosts) { host in
                    multiHostGroup(host)
                }
            }
            if layout.sections.isEmpty && !layout.allTasksVisible { clearWorkspaces }
            customizeWorkspacesButton
        }
    }

    @ViewBuilder
    private func multiHostGroup(_ host: ClientHost) -> some View {
        let peer = host.peerKey
        let folders = model.folders(for: peer)
        let chats = model.chats(for: peer)
        let sessions = model.sessions(for: peer)
        let showsFolders = layout.sections.contains(.folders) && !folders.isEmpty
        let showsChats = layout.sections.contains(.recentChats) && (!chats.isEmpty || !folders.isEmpty)
        let showsSessions = layout.sections.contains(.sessions) && (!sessions.isEmpty || !folders.isEmpty)
        if showsFolders || showsChats || showsSessions || layout.allTasksVisible {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: ClientDeviceIcon.symbol(name: host.name, isHost: true))
                        .foregroundStyle(Theme.accent)
                    Text(host.name)
                        .font(ClientType.label.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: 52)
                if layout.allTasksVisible {
                    ThemeRule().padding(.leading, Theme.Space.m)
                    ClientAllTasksLink(peer: peer, hostName: host.name)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(minHeight: 52)
                }
                ForEach(layout.sections) { section in
                    multiHostSection(section, host: host)
                }
            }
            .cardSurface()
        }
    }

    @ViewBuilder
    private func multiHostSection(_ section: WorkspacesSection, host: ClientHost) -> some View {
        let peer = host.peerKey
        switch section {
        case .folders:
            let folders = model.folders(for: peer)
            if !folders.isEmpty {
                ThemeRule().padding(.leading, Theme.Space.m)
                groupedSectionTitle(.folders)
                let visible = expandedHostFolders.contains(peer) ? folders : Array(folders.prefix(2))
                ForEach(visible) { folder in
                    NavigationLink {
                        ClientWorkspaceDetailView(peer: peer, hostName: host.name, folder: folder)
                    } label: {
                        ClientFolderRow(folder: folder, grouped: true)
                    }
                    .buttonStyle(.plain)
                    .modifier(ClientProjectRename(peer: peer, folder: folder,
                        onChanged: { await model.refresh(account: account.account) }))
                    if folder.id != visible.last?.id {
                        ThemeRule().padding(.leading, Theme.Space.m)
                    }
                }
                if folders.count > 2 {
                    Button {
                        if expandedHostFolders.contains(peer) {
                            expandedHostFolders.remove(peer)
                        } else {
                            expandedHostFolders.insert(peer)
                        }
                    } label: {
                        Label(expandedHostFolders.contains(peer)
                            ? L10n.text("apple.clientrecentchats.show_less.94ea9b1d")
                            : L10n.text("apple.clientrecentchats.show_more_0_more.c732a4ba", "\(folders.count - 2)"),
                            systemImage: expandedHostFolders.contains(peer) ? "chevron.up" : "chevron.down")
                            .font(ClientType.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
        case .recentChats:
            let chats = model.chats(for: peer)
            if !chats.isEmpty || !model.folders(for: peer).isEmpty {
                ThemeRule().padding(.leading, Theme.Space.m)
                ClientRecentChatsSection(peer: peer, hostName: host.name,
                    folders: model.folders(for: peer), chats: chats,
                    onNewChat: { navigation.openNewChat(hostPeer: peer) }, grouped: true)
            }
        case .sessions:
            let sessions = model.sessions(for: peer)
            let folders = model.folders(for: peer)
            if !sessions.isEmpty || !folders.isEmpty {
                ThemeRule().padding(.leading, Theme.Space.m)
                HStack(spacing: Theme.Space.s) {
                    groupedSectionLabel(.sessions)
                    Spacer(minLength: Theme.Space.s)
                    if !folders.isEmpty {
                        Button(L10n.text("apple.clientworkspacesview.new_terminal.fe544556"), .create) {
                            startingOnHost = peer
                            starting = .sessions
                        }
                        .font(ClientType.caption.weight(.semibold))
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: 48)
                ForEach(expandedHostSessions.contains(peer) ? sessions : Array(sessions.prefix(2))) { session in
                    Button { model.openSession(session, peer: peer) } label: {
                        ClientSessionRow(session: session, showsChevron: true,
                            displayName: SidebarTerminalNames.shared.name(peer: peer,
                                workspaceID: session.workspaceID, sessionID: session.id), grouped: true)
                    }
                    .buttonStyle(.plain)
                }
                if sessions.count > 2 {
                    Button(expandedHostSessions.contains(peer)
                        ? L10n.text("apple.clientrecentchats.show_less.94ea9b1d")
                        : L10n.text("apple.clientrecentchats.show_more_0_more.c732a4ba", "\(sessions.count - 2)"),
                        expandedHostSessions.contains(peer) ? .collapse : .reveal) {
                        if expandedHostSessions.contains(peer) {
                            expandedHostSessions.remove(peer)
                        } else {
                            expandedHostSessions.insert(peer)
                        }
                    }
                    .font(ClientType.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private func groupedSectionTitle(_ section: WorkspacesSection) -> some View {
        HStack { groupedSectionLabel(section); Spacer(minLength: 0) }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 44)
    }

    private func groupedSectionLabel(_ section: WorkspacesSection) -> some View {
        Label(section.label, systemImage: section.symbol)
            .font(ClientType.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func hostCard(_ host: ClientHost) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Circle()
                    .fill(host.online == true ? Theme.accent : Color.secondary.opacity(0.35))
                    .frame(width: 9, height: 9)
                Image(systemName: ClientDeviceIcon.symbol(name: host.name, isHost: true))
                    .foregroundStyle(.secondary)
                Text(host.name)
                    .font(ClientType.label.weight(.medium))
                Spacer()
                if host.online == false {
                    Text(L10n.text("common.offline"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else if model.connectedKey == host.peerKey {
                    Button(L10n.text("common.disconnect"), .disconnect) {
                        model.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button(model.isBusy(with: host.peerKey) ? L10n.text("apple.clientworkspacesview.connecting.72021eb7") :
                        model.deniedHostKeys.contains(host.peerKey) ? L10n.text("apple.clienthostworkspacesview.request_access.b06f1662") :
                        model.staleHostKeys.contains(host.peerKey) ? L10n.text("common.refresh") :
                        model.loadedHostKeys.contains(host.peerKey) ? L10n.text("common.open") : L10n.text("common.connect"), .connect) {
                        Task { await model.connect(host) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .disabled(((model.isConnecting != nil || model.pendingPeer != nil) &&
                        !model.loadedHostKeys.contains(host.peerKey)) || host.online == false)
                }
            }
            if model.staleHostKeys.contains(host.peerKey) {
                Text(L10n.text("apple.clientworkspacesview.needs_refresh.5b783f2d"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            if host.machineID != nil {
                Button {
                    navigation.openDevice(machineID: host.machineID)
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.text("apple.clientworkspacesview.open_device.021a82bd"))
                            .font(ClientType.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(ClientType.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tint(Theme.accent)
                .foregroundStyle(Theme.accent)
            }
            if model.connectedKey == host.peerKey {
                HostStatsStrip(peer: host.peerKey)
                HStack(spacing: 6) {
                    Text(L10n.text("apple.clientworkspacesview.auto_connect.45b6d201"))
                        .font(ClientType.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Space.s)
                    Toggle("", isOn: autoConnectBinding(for: host.peerKey))
                        .labelsHidden()
                        .tint(Theme.accent)
                        .scaleEffect(0.82)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.text("apple.clientworkspacesview.auto_connect_0.3bbf847e", "\(host.name)"))
                .accessibilityValue(isAutoConnectEnabled(for: host.peerKey) ? L10n.text("apple.clientworkspacesview.on.13001175") : L10n.text("apple.clientworkspacesview.off.ca7981b4"))
            } else if model.loadedHostKeys.contains(host.peerKey) {
                HStack(spacing: Theme.Space.s) {
                    Text(L10n.text("apple.clientworkspacesview.auto_connect.45b6d201"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Space.s)
                    Toggle("", isOn: autoConnectBinding(for: host.peerKey))
                        .labelsHidden()
                        .tint(Theme.accent)
                    Button(L10n.text("common.disconnect"), .disconnect) {
                        model.disconnectHost(host.peerKey)
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

private struct ClientHostConnectionSummary: View {
    let peer: String
    @State private var route: String?
    @State private var stats: HostStats?

    private var shortRoute: String? {
        switch route {
        case "direct": L10n.text("apple.clientworkspacesview.direct_route")
        case "relay": L10n.text("apple.clientworkspacesview.relay_route")
        default: nil
        }
    }

    private var powerLabel: String? {
        guard let stats else { return nil }
        if stats.charging == true {
            return stats.percent.map { L10n.text("apple.clientworkspacesview.charging_percent", "\($0)") }
                ?? L10n.text("apple.clientworkspacesview.charging")
        }
        if stats.power == "battery" {
            return stats.percent.map { L10n.text("apple.clientworkspacesview.battery_percent", "\($0)") }
                ?? L10n.text("apple.hoststatsbar.on_battery.51d53044")
        }
        if stats.power == "ac" { return L10n.text("apple.clientworkspacesview.ac_power") }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(shortRoute ?? L10n.text("common.chat.stats.connected"))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 56, alignment: .leading)
            if powerLabel != nil {
                HStack(spacing: 6) {
                    Image(systemName: HostStatsFormat.powerSymbol(stats))
                        .foregroundStyle(stats?.power == "battery" && stats?.charging != true && (stats?.percent ?? 100) < 20
                            ? Theme.warning : Color.secondary)
                        .accessibilityHidden(true)
                    if stats?.power == "battery", stats?.charging != true, let percent = stats?.percent {
                        Text("\(percent)%")
                            .foregroundStyle(percent < 20 ? Theme.warning : Color.secondary)
                    } else if stats?.charging == true {
                        Text(L10n.text("apple.clientworkspacesview.charging"))
                            .foregroundStyle(.secondary)
                    } else if stats?.power == "ac" {
                        Text(L10n.text("apple.clientworkspacesview.ac_power"))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 84, alignment: .leading)
            }
            if let cpu = stats?.cpu, cpu.isFinite {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .accessibilityHidden(true)
                    Text(HostStatsFormat.cpuLabel(cpu))
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(ClientType.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([L10n.text("common.chat.stats.connected"), RemoteTrafficPeer.knownLabel(route), powerLabel,
            stats?.cpu.flatMap { cpu in cpu.isFinite
                ? L10n.text("apple.hoststatsbar.cpu_0.ceaa5d7d", HostStatsFormat.cpuLabel(cpu)) : nil }]
            .compactMap { $0 }.joined(separator: ", "))
        .task(id: peer) {
            while !Task.isCancelled {
                route = await HostStatsFormat.loadRoute(for: peer)
                guard !Task.isCancelled else { return }
                if let fresh = try? await Bridge.hostStats(peer: peer) {
                    guard !Task.isCancelled else { return }
                    stats = fresh
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
}

struct ClientHost: Identifiable, Hashable {
    var id: String { peerKey }
    var peerKey: String
    var name: String
    var online: Bool?
    var machineID: String?
}

@Observable
@MainActor
final class ClientWorkspacesModel {
    private struct HostSnapshot {
        let folders: [WorkspaceFolder]
        let sessions: [PtySessionInfo]
        let chats: [ChatRecentConversation]
        let loadedAt: Date
    }

    @ObservationIgnored private var hostSnapshots: [String: HostSnapshot] = [:]
    private(set) var loadedHostKeys: Set<String> = []
    private(set) var staleHostKeys: Set<String> = []
    private(set) var deniedHostKeys: Set<String> = []
    @ObservationIgnored private var backgroundSweep: Task<Void, Never>?
    @ObservationIgnored private var refreshBackgroundAfterSweep = false
    @ObservationIgnored private var backgroundTickets: [String: UUID] = [:]
    @ObservationIgnored private var backgroundFailures: [String: Int] = [:]
    @ObservationIgnored private var nextBackgroundAttempt: [String: Date] = [:]

    func folders(for peer: String) -> [WorkspaceFolder] { hostSnapshots[peer]?.folders ?? [] }
    func sessions(for peer: String) -> [PtySessionInfo] { hostSnapshots[peer]?.sessions ?? [] }
    func chats(for peer: String) -> [ChatRecentConversation] { hostSnapshots[peer]?.chats ?? [] }

    func folderReference(id: String) -> (peer: String, folder: WorkspaceFolder)? {
        for host in hosts where loadedHostKeys.contains(host.peerKey) &&
            !staleHostKeys.contains(host.peerKey) && host.online != false {
            if let folder = hostSnapshots[host.peerKey]?.folders.first(where: { $0.id == id }) {
                return (host.peerKey, folder)
            }
        }
        return nil
    }
    private(set) var hosts: [ClientHost] = []
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var sessions: [PtySessionInfo] = []
    private(set) var recentChats: [ChatRecentConversation] = []
    private(set) var connectedKey: String?
    private(set) var isConnecting: String?
    private(set) var pendingPeer: String?
    private(set) var chosenPeer: String?
    @ObservationIgnored private var remoteLoadGeneration = UUID()
    @ObservationIgnored private let ownerScope = WorkSessionContext.shared.scope
    private(set) var errorMessage: String?
    private(set) var thisDeviceName: String?
    var activeTerminal: ClientTerminalSession?
    @ObservationIgnored private var lastRecoverAt = Date.distantPast
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var remoteRefresh: (ticket: UUID, peer: String, generation: UUID, task: Task<Void, Never>)?

    func refresh(account: Account?) async {
        guard !Task.isCancelled, !retired, ownerScope != nil, ownerScope == WorkSessionContext.shared.scope else { return }
        let generation = UUID()
        refreshGeneration = generation
        let thisID = account?.thisMachineID
        let machines = account?.machines ?? []
        let identity = try? await Bridge.machineIdentity()
        guard !Task.isCancelled, !retired, refreshGeneration == generation,
              ownerScope == WorkSessionContext.shared.scope else { return }
        let selfKey = identity?.key.lowercased()
        let nextDeviceName = {
            let label = identity?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return label.isEmpty ? ClientDeviceName.marketing : label
        }()
        if thisDeviceName != nextDeviceName { thisDeviceName = nextDeviceName }
        let nextHosts = machines.compactMap { machine -> ClientHost? in
            guard machine.isHost else { return nil }
            if let thisID, let mid = machine.machineID, mid == thisID { return nil }
            if let selfKey, machine.publicIdentity?.lowercased() == selfKey { return nil }
            guard let key = machine.publicIdentity, !key.isEmpty else { return nil }
            let name: String = {
                if let label = machine.label, !label.isEmpty { return label }
                if let id = machine.machineID { return id }
                return L10n.text("apple.clientworkspacesview.computer.76ed42d2")
            }()
            return ClientHost(
                peerKey: key,
                name: name,
                online: machine.online,
                machineID: machine.machineID
            )
        }
        if hosts != nextHosts { hosts = nextHosts }
        let available = Set(nextHosts.map(\.peerKey))
        deniedHostKeys.formIntersection(available)
        for peer in hostSnapshots.keys.filter({ !available.contains($0) }) {
            dropHostSnapshot(peer)
        }
        for peer in backgroundTickets.keys.filter({ !available.contains($0) }) {
            backgroundTickets.removeValue(forKey: peer)
        }
        loadedHostKeys = Set(hostSnapshots.keys)
        if let connectedKey, !available.contains(connectedKey) { disconnect(manual: false) }
        migrateLegacyHost()
        #if os(iOS)
        let overviewNames = Dictionary(nextHosts.map { ($0.peerKey, $0.name) }, uniquingKeysWith: { first, _ in first })
        Task { await LiveWorkController.shared.refreshOverview(peers: nextHosts.map(\.peerKey), names: overviewNames) }
        #endif
        if let key = connectedKey {
            await reloadRemote(peerKey: key)
        }
    }

    private(set) var infoMessage: String?
    private(set) var awaitingAccessHost: String?
    private(set) var awaitingAccessPeerKey: String?
    private var accessWatch: Task<Void, Never>?

    func connect(_ host: ClientHost) async {
        guard !Task.isCancelled, !retired, ownerScope != nil, ownerScope == WorkSessionContext.shared.scope else { return }
        backgroundTickets.removeValue(forKey: host.peerKey)
        chosenPeer = host.peerKey
        if host.online != false, !staleHostKeys.contains(host.peerKey),
            let snapshot = hostSnapshots[host.peerKey] {
            remoteLoadGeneration = UUID()
            pendingPeer = nil
            stopWatchingForAccess()
            connectedKey = host.peerKey
            folders = snapshot.folders
            sessions = snapshot.sessions
            recentChats = snapshot.chats
            errorMessage = nil
            infoMessage = nil
            if let key = lastConnectedHostKey { UserDefaults.standard.set(host.peerKey, forKey: key) }
            rememberHost(host.peerKey)
            setAutoConnect(true, for: host.peerKey)
            Task { await reloadRemote(peerKey: host.peerKey) }
            return
        }
        if isConnecting == host.peerKey || pendingPeer == host.peerKey { return }
        pendingPeer = host.peerKey
        while !Task.isCancelled, pendingPeer == host.peerKey, isConnecting != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled, isConnecting == nil, pendingPeer == host.peerKey else {
            if pendingPeer == host.peerKey { pendingPeer = nil }
            return
        }
        await dial(host, recovering: false)
    }

    func focusLoadedHost(_ host: ClientHost) {
        guard host.online != false, !staleHostKeys.contains(host.peerKey),
              let snapshot = hostSnapshots[host.peerKey] else { return }
        remoteLoadGeneration = UUID()
        chosenPeer = host.peerKey
        pendingPeer = nil
        stopWatchingForAccess()
        connectedKey = host.peerKey
        folders = snapshot.folders
        sessions = snapshot.sessions
        recentChats = snapshot.chats
        errorMessage = nil
        infoMessage = nil
        if let key = lastConnectedHostKey { UserDefaults.standard.set(host.peerKey, forKey: key) }
    }

    private func autoDial(_ host: ClientHost) async {
        guard !Task.isCancelled, !retired, ownerScope != nil, ownerScope == WorkSessionContext.shared.scope else { return }
        guard isConnecting == nil, pendingPeer == nil else { return }
        await dial(host, recovering: false)
    }

    private var hostPreferencePrefix: String? {
        guard let scope = ownerScope else { return nil }
        return "client.host.v2.\([scope.kind.rawValue, scope.origin, scope.identity].map(WorkReferenceKey.encode).joined(separator: "|"))"
    }

    private var lastConnectedHostKey: String? {
        hostPreferencePrefix.map { "\($0).last" }
    }

    private var rememberedHostsKey: String? {
        hostPreferencePrefix.map { "\($0).remembered" }
    }

    var lastConnectedHost: String? {
        guard let key = lastConnectedHostKey else { return nil }
        return UserDefaults.standard.string(forKey: key)
    }

    var rememberedHosts: [ClientHost] {
        guard let key = rememberedHostsKey else { return [] }
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        let ordered = ([lastConnectedHost].compactMap { $0 } + saved.sorted())
        var seen = Set<String>()
        return ordered.compactMap { peer in
            guard seen.insert(peer).inserted else { return nil }
            return hosts.first { $0.peerKey == peer }
        }
    }

    private func rememberHost(_ peerKey: String) {
        guard let key = rememberedHostsKey else { return }
        let saved = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        UserDefaults.standard.set(Array(saved.union([peerKey])).sorted(), forKey: key)
    }

    private func autoConnectKey(for peerKey: String) -> String? {
        hostPreferencePrefix.map { "\($0).auto.\(WorkReferenceKey.encode(peerKey))" }
    }

    private func migrateLegacyHost() {
        guard let key = lastConnectedHostKey,
              UserDefaults.standard.object(forKey: key) == nil,
              let legacy = UserDefaults.standard.string(forKey: "client.lastConnectedHost"),
              hosts.contains(where: { $0.peerKey == legacy }) else { return }
        UserDefaults.standard.set(legacy, forKey: key)
        rememberHost(legacy)
        let oldAutoKey = "client.autoConnectHost.\(legacy)"
        if let auto = UserDefaults.standard.object(forKey: oldAutoKey) as? Bool,
           let newAutoKey = autoConnectKey(for: legacy),
           UserDefaults.standard.object(forKey: newAutoKey) == nil {
            UserDefaults.standard.set(auto, forKey: newAutoKey)
        }
        UserDefaults.standard.removeObject(forKey: "client.lastConnectedHost")
        UserDefaults.standard.removeObject(forKey: oldAutoKey)
    }

    func isAutoConnectEnabled(for peerKey: String) -> Bool {
        guard let key = autoConnectKey(for: peerKey) else { return false }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    func setAutoConnect(_ on: Bool, for peerKey: String) {
        guard let key = autoConnectKey(for: peerKey) else { return }
        UserDefaults.standard.set(on, forKey: key)
        if on { rememberHost(peerKey) }
        else { backgroundTickets.removeValue(forKey: peerKey) }
    }

    func autoConnectLastHost() async {
        warmRememberedHosts()
        guard connectedKey == nil, isConnecting == nil, pendingPeer == nil,
              awaitingAccessHost == nil else { return }
        guard let last = lastConnectedHost,
              chosenPeer == nil || chosenPeer == last,
              isAutoConnectEnabled(for: last),
              let host = hosts.first(where: { $0.peerKey == last }),
              host.online != false
        else { return }
        await autoDial(host)
    }

    func revisitRememberedHosts() {
        warmRememberedHosts()
    }

    private func warmRememberedHosts(forceRefresh: Bool = false) {
        guard !retired, ownerScope != nil, ownerScope == WorkSessionContext.shared.scope else { return }
        if backgroundSweep != nil {
            if forceRefresh { refreshBackgroundAfterSweep = true }
            return
        }
        let candidates = rememberedHosts.filter { host in
            host.peerKey != lastConnectedHost && host.peerKey != connectedKey &&
                host.online != false && isAutoConnectEnabled(for: host.peerKey) &&
                (forceRefresh || hostSnapshots[host.peerKey].map { Date().timeIntervalSince($0.loadedAt) > 60 } ?? true) &&
                (forceRefresh || Date() >= (nextBackgroundAttempt[host.peerKey] ?? .distantPast))
        }
        guard !candidates.isEmpty else { return }
        backgroundSweep = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var remaining = candidates.makeIterator()
                for _ in 0..<min(3, candidates.count) {
                    if let host = remaining.next() { group.addTask { await self.warm(host) } }
                }
                while await group.next() != nil {
                    if let host = remaining.next() { group.addTask { await self.warm(host) } }
                }
            }
            self.backgroundSweep = nil
            if self.refreshBackgroundAfterSweep {
                self.refreshBackgroundAfterSweep = false
                self.warmRememberedHosts(forceRefresh: true)
            }
        }
    }

    private func warm(_ host: ClientHost) async {
        let scope = ownerScope
        let lease = EcosystemPublisher.lease
        let ticket = UUID()
        backgroundTickets[host.peerKey] = ticket
        defer {
            if backgroundTickets[host.peerKey] == ticket { backgroundTickets.removeValue(forKey: host.peerKey) }
        }
        func current() -> Bool {
            !Task.isCancelled && !retired && scope != nil && scope == ownerScope &&
                scope == WorkSessionContext.shared.scope && lease == EcosystemPublisher.lease &&
                backgroundTickets[host.peerKey] == ticket &&
                hosts.contains(where: { $0.peerKey == host.peerKey }) &&
                isAutoConnectEnabled(for: host.peerKey) &&
                connectedKey != host.peerKey && isConnecting != host.peerKey && chosenPeer != host.peerKey
        }
        guard current() else { return }
        let delays: [UInt64] = [0, 1, 2, 4]
        for (index, delay) in delays.enumerated() {
            guard current() else { return }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard current() else { return }
            do {
                let peer = try await Bridge.pair(key: host.peerKey, label: host.name, address: "")
                _ = try await Bridge.setTunnel(true)
                guard current() else { return }
                let allowed = try await Bridge.workspaceAccessAllowed(peer: peer.key)
                guard current() else { return }
                if !allowed {
                    dropHostSnapshot(host.peerKey)
                    deniedHostKeys.insert(host.peerKey)
                    noteBackgroundFailure(host.peerKey)
                    return
                }
                deniedHostKeys.remove(host.peerKey)
                async let loadedFolders = Bridge.remoteWorkspaces(peer: peer)
                async let loadedSessions = try? ClientRemote.ptyList(peer: peer.key)
                async let loadedChats = try? ClientRemote.recentChats(peer: peer.key)
                let newFolders = try await loadedFolders
                let newSessions = await loadedSessions ?? []
                let newChats = await loadedChats ?? []
                guard current() else { return }
                hostSnapshots[host.peerKey] = HostSnapshot(folders: newFolders, sessions: newSessions, chats: newChats, loadedAt: .now)
                loadedHostKeys = Set(hostSnapshots.keys)
                staleHostKeys.remove(host.peerKey)
                deniedHostKeys.remove(host.peerKey)
                publishEcosystem(newFolders, peer: host.peerKey, host: host.name, lease: lease)
                backgroundFailures.removeValue(forKey: host.peerKey)
                nextBackgroundAttempt.removeValue(forKey: host.peerKey)
                return
            } catch {
                guard current() else { return }
                if ClientTunnelCopy.isAbsent(error.localizedDescription), index < delays.count - 1 { continue }
                noteBackgroundFailure(host.peerKey)
                return
            }
        }
    }

    private func noteBackgroundFailure(_ peer: String) {
        let failures = (backgroundFailures[peer] ?? 0) + 1
        backgroundFailures[peer] = failures
        nextBackgroundAttempt[peer] = Date().addingTimeInterval(min(60, Double(2 << min(failures - 1, 5))))
        if hostSnapshots[peer] != nil { staleHostKeys.insert(peer) }
    }

    func recoverAfterNetworkChange(account: Account?) async {
        let now = Date()
        if now.timeIntervalSince(lastRecoverAt) < 1.5 { return }
        lastRecoverAt = now
        warmRememberedHosts(forceRefresh: true)
        guard isConnecting == nil, pendingPeer == nil else { return }
        await refresh(account: account)
        guard let key = connectedKey,
              let host = hosts.first(where: { $0.peerKey == key })
        else { return }
        await dial(host, recovering: true)
        activeTerminal?.clearTransientTunnelError()
    }

    private func dial(_ host: ClientHost, recovering: Bool) async {
        guard !Task.isCancelled, !retired, ownerScope != nil, ownerScope == WorkSessionContext.shared.scope else { return }
        backgroundTickets.removeValue(forKey: host.peerKey)
        let ecosystemLease = EcosystemPublisher.lease
        let ownerScope = WorkSessionContext.shared.scope
        let loadGeneration = UUID()
        func stillCurrent() -> Bool {
            !Task.isCancelled && !retired && self.ownerScope != nil && ownerScope == self.ownerScope
                && ownerScope == WorkSessionContext.shared.scope
                && EcosystemPublisher.lease == ecosystemLease
                && remoteLoadGeneration == loadGeneration
                && (chosenPeer == nil || chosenPeer == host.peerKey)
        }
        if pendingPeer == host.peerKey { pendingPeer = nil }
        guard isConnecting == nil else { return }
        guard host.online != false else {
            errorMessage = L10n.text("apple.clientworkspacesview.0_is_asleep.18ebf568", "\(host.name)")
            infoMessage = nil
            if !recovering {
                connectedKey = nil
                folders = []
                sessions = []
                recentChats = []
            }
            return
        }
        remoteLoadGeneration = loadGeneration
        isConnecting = host.peerKey
        defer { isConnecting = nil }
        if !recovering {
            errorMessage = nil
            infoMessage = nil
            stopWatchingForAccess()
        }
        let delays: [UInt64] = [0, 1, 2, 4]
        for (index, delay) in delays.enumerated() {
            guard stillCurrent() else { return }
            if delay > 0 {
                infoMessage = ClientTunnelCopy.waiting(host.name)
                errorMessage = nil
                try? await Task.sleep(for: .seconds(delay))
            }
            do {
                await ClientDeviceName.publish()
                guard stillCurrent() else { return }
                let peer = try await Bridge.pair(
                    key: host.peerKey,
                    label: host.name,
                    address: ""
                )
                guard stillCurrent() else { return }
                _ = try await Bridge.setTunnel(true)
                guard stillCurrent() else { return }
                let allowed = try await Bridge.workspaceAccessAllowed(peer: peer.key)
                guard stillCurrent() else { return }
                if !allowed {
                    dropHostSnapshot(host.peerKey)
                    deniedHostKeys.insert(host.peerKey)
                    let request = try await Bridge.askWorkspaceAccess(peer: host.peerKey)
                    guard stillCurrent() else { return }
                    if request.granted == true { continue }
                    awaitingAccessHost = host.name
                    awaitingAccessPeerKey = host.peerKey
                    infoMessage = nil
                    errorMessage = nil
                    if !recovering || connectedKey == host.peerKey {
                        connectedKey = nil
                        folders = []
                        sessions = []
                        recentChats = []
                    }
                    watchForAccess(host)
                    return
                }
                deniedHostKeys.remove(host.peerKey)
                stopWatchingForAccess()
                async let loadedFolders = Bridge.remoteWorkspaces(peer: peer)
                async let loadedSessions = ClientRemote.ptyList(peer: peer.key)
                async let loadedChats = ClientRemote.recentChats(peer: peer.key)
                let newFolders = try await loadedFolders
                let newSessions = try? await loadedSessions
                let newChats = try? await loadedChats
                guard stillCurrent() else { return }
                publishEcosystem(newFolders, peer: host.peerKey, host: host.name, lease: ecosystemLease)
                if folders != newFolders { folders = newFolders }
                let nextSessions = newSessions ?? [], nextChats = newChats ?? []
                if sessions != nextSessions { sessions = nextSessions }
                if recentChats != nextChats { recentChats = nextChats }
                hostSnapshots[host.peerKey] = HostSnapshot(folders: newFolders, sessions: nextSessions, chats: nextChats, loadedAt: .now)
                loadedHostKeys = Set(hostSnapshots.keys)
                staleHostKeys.remove(host.peerKey)
                deniedHostKeys.remove(host.peerKey)
                connectedKey = host.peerKey
                #if os(iOS)
                let overviewPeers = hosts.map(\.peerKey)
                let overviewNames = Dictionary(hosts.map { ($0.peerKey, $0.name) }, uniquingKeysWith: { first, _ in first })
                Task { await LiveWorkController.shared.refreshOverview(peers: overviewPeers, names: overviewNames) }
                #endif
                if let key = lastConnectedHostKey {
                    UserDefaults.standard.set(host.peerKey, forKey: key)
                }
                rememberHost(host.peerKey)
                if chosenPeer == host.peerKey {
                    setAutoConnect(true, for: host.peerKey)
                }
                errorMessage = nil
                infoMessage = nil
                return
            } catch {
                guard stillCurrent() else { return }
                let text = error.localizedDescription
                if Self.isApprovalNeeded(text) {
                    infoMessage = L10n.text("apple.clientworkspacesview.approve_this_device_on_0_open_machines.fef8f93c", "\(host.name)")
                        + L10n.text("apple.clientworkspacesview.and_tap_approve_next_to_this_device_then_c.ce0bfe0d")
                    errorMessage = nil
                    if !recovering {
                        connectedKey = nil
                        folders = []
                        sessions = []
                        recentChats = []
                    }
                    return
                }
                if ClientTunnelCopy.isAbsent(text), index < delays.count - 1 {
                    continue
                }
                if ClientTunnelCopy.isAbsent(text) {
                    infoMessage = ClientTunnelCopy.waiting(host.name)
                    errorMessage = nil
                } else {
                    errorMessage = text
                    infoMessage = nil
                }
                if !recovering {
                    connectedKey = nil
                    folders = []
                    sessions = []
                    recentChats = []
                }
                return
            }
        }
    }

    private static func isApprovalNeeded(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not approved")
            || lower.contains("waiting for someone to allow")
            || lower.contains("not_approved")
    }

    private func watchForAccess(_ host: ClientHost) {
        accessWatch?.cancel()
        let ownerScope = WorkSessionContext.shared.scope
        let ecosystemLease = EcosystemPublisher.lease
        let loadGeneration = remoteLoadGeneration
        accessWatch = Task { [weak self] in
            for _ in 0..<ClientAccessWatch.attempts {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: ClientAccessWatch.interval)
                guard !Task.isCancelled, let self else { return }
                guard ownerScope == WorkSessionContext.shared.scope, ecosystemLease == EcosystemPublisher.lease,
                      self.remoteLoadGeneration == loadGeneration,
                      self.chosenPeer == nil || self.chosenPeer == host.peerKey else { return }
                guard let allowed = try? await Bridge.workspaceAccessAllowed(peer: host.peerKey),
                      allowed
                else { continue }
                guard !Task.isCancelled, !retired, self.ownerScope == ownerScope, ownerScope == WorkSessionContext.shared.scope,
                      ecosystemLease == EcosystemPublisher.lease, self.remoteLoadGeneration == loadGeneration,
                      self.chosenPeer == nil || self.chosenPeer == host.peerKey else { return }
                self.accessWatch = nil
                await self.autoDial(host)
                return
            }
        }
    }

    private func stopWatchingForAccess() {
        accessWatch?.cancel()
        accessWatch = nil
        awaitingAccessHost = nil
        awaitingAccessPeerKey = nil
    }

    func isBusy(with peerKey: String) -> Bool {
        isConnecting == peerKey || pendingPeer == peerKey
    }

    func deactivate() {
        retired = true
        refreshGeneration = UUID()
        backgroundSweep?.cancel()
        backgroundSweep = nil
        refreshBackgroundAfterSweep = false
        backgroundTickets.removeAll()
        remoteRefresh?.task.cancel()
        remoteRefresh = nil
        activeTerminal?.stop()
        activeTerminal = nil
        disconnect(manual: false)
        hostSnapshots.removeAll()
        loadedHostKeys = []
        staleHostKeys = []
        deniedHostKeys = []
    }

    func disconnect(manual: Bool = true) {
        let peer = connectedKey ?? isConnecting ?? pendingPeer ?? chosenPeer
        if manual, let peer {
            setAutoConnect(false, for: peer)
            hostSnapshots.removeValue(forKey: peer)
            loadedHostKeys = Set(hostSnapshots.keys)
            staleHostKeys.remove(peer)
            deniedHostKeys.remove(peer)
            publishEcosystem([], peer: peer, host: "", lease: EcosystemPublisher.lease)
        }
        remoteRefresh?.task.cancel()
        remoteRefresh = nil
        remoteLoadGeneration = UUID()
        pendingPeer = nil
        chosenPeer = nil
        stopWatchingForAccess()
        if let peer, activeTerminal?.peer == peer {
            activeTerminal?.stop()
            activeTerminal = nil
        }
        connectedKey = nil
        folders = []
        sessions = []
        recentChats = []
    }

    func disconnectHost(_ peer: String) {
        backgroundTickets.removeValue(forKey: peer)
        setAutoConnect(false, for: peer)
        dropHostSnapshot(peer)
        deniedHostKeys.remove(peer)
        if connectedKey == peer {
            disconnect(manual: false)
        } else if isConnecting == peer || pendingPeer == peer {
            remoteLoadGeneration = UUID()
            if pendingPeer == peer { pendingPeer = nil }
            if chosenPeer == peer { chosenPeer = nil }
        }
    }

    private func dropHostSnapshot(_ peer: String) {
        hostSnapshots.removeValue(forKey: peer)
        loadedHostKeys = Set(hostSnapshots.keys)
        staleHostKeys.remove(peer)
        publishEcosystem([], peer: peer, host: "", lease: EcosystemPublisher.lease)
        if activeTerminal?.peer == peer {
            activeTerminal?.stop()
            activeTerminal = nil
        }
    }

    func openSession(_ info: PtySessionInfo, peer: String? = nil) {
        guard ownerScope != nil, ownerScope == WorkSessionContext.shared.scope,
              let peer = peer ?? connectedKey else { return }
        activeTerminal = ClientTerminalSession(peer: peer, info: info)
    }

    func closeSession(_ info: PtySessionInfo, expectedPeer: String? = nil) async {
        guard let peer = expectedPeer ?? connectedKey,
              (peer == connectedKey || loadedHostKeys.contains(peer)), let owner = ownerScope,
              owner == WorkSessionContext.shared.scope else { return }
        let closing = activeTerminal.flatMap { $0.peer == peer && $0.hostID == info.id ? $0 : nil }
        do {
            if let closing { try await closing.close() }
            else { try await ClientRemote.ptyClose(peer: peer, id: info.id) }
            guard owner == WorkSessionContext.shared.scope else { return }
            if let closing, activeTerminal === closing { activeTerminal = nil }
            if connectedKey == peer { sessions.removeAll { $0.id == info.id } }
            if let snapshot = hostSnapshots[peer] {
                hostSnapshots[peer] = HostSnapshot(folders: snapshot.folders,
                    sessions: snapshot.sessions.filter { $0.id != info.id },
                    chats: snapshot.chats, loadedAt: snapshot.loadedAt)
            }
        } catch {
            guard owner == WorkSessionContext.shared.scope else { return }
            let host = hosts.first { $0.peerKey == peer }?.name
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: host)
        }
    }

    func refreshSessions(peer: String) async {
        let generation = remoteLoadGeneration
        guard !Task.isCancelled, !retired, ownerScope != nil,
              ownerScope == WorkSessionContext.shared.scope,
              connectedKey == peer, isConnecting == nil else { return }
        guard let snapshot = try? await ClientRemote.ptyList(peer: peer) else { return }
        guard !Task.isCancelled, !retired, ownerScope == WorkSessionContext.shared.scope,
              connectedKey == peer, remoteLoadGeneration == generation else { return }
        if sessions != snapshot { sessions = snapshot }
    }

    private func reloadRemote(peerKey: String) async {
        guard !Task.isCancelled, !retired, ownerScope != nil, ownerScope == WorkSessionContext.shared.scope else { return }
        if let flight = remoteRefresh, flight.peer == peerKey, flight.generation == remoteLoadGeneration {
            await flight.task.value
            return
        }
        let ticket = UUID()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRemoteRefresh(peerKey: peerKey)
        }
        remoteRefresh = (ticket, peerKey, remoteLoadGeneration, task)
        await task.value
        if remoteRefresh?.ticket == ticket { remoteRefresh = nil }
    }

    private func performRemoteRefresh(peerKey: String) async {
        guard !Task.isCancelled, !retired, ownerScope != nil, ownerScope == WorkSessionContext.shared.scope else { return }
        let ecosystemLease = EcosystemPublisher.lease
        let ownerScope = WorkSessionContext.shared.scope
        guard isConnecting == nil, connectedKey == peerKey, chosenPeer == nil || chosenPeer == peerKey else { return }
        let loadGeneration = remoteLoadGeneration
        guard let peer = try? await Bridge.peers().first(where: { $0.key == peerKey }) else {
            return
        }
        guard !Task.isCancelled, !retired, self.ownerScope == ownerScope, ownerScope == WorkSessionContext.shared.scope,
              EcosystemPublisher.lease == ecosystemLease, connectedKey == peerKey,
              chosenPeer == nil || chosenPeer == peerKey, remoteLoadGeneration == loadGeneration else { return }
        let accessAllowed = try? await Bridge.workspaceAccessAllowed(peer: peerKey)
        if accessAllowed == false {
            guard !Task.isCancelled, !retired, self.ownerScope == ownerScope,
                  ownerScope == WorkSessionContext.shared.scope, connectedKey == peerKey,
                  remoteLoadGeneration == loadGeneration else { return }
            _ = try? await Bridge.askWorkspaceAccess(peer: peerKey)
            guard !Task.isCancelled, !retired, self.ownerScope == ownerScope,
                  ownerScope == WorkSessionContext.shared.scope, connectedKey == peerKey,
                  remoteLoadGeneration == loadGeneration else { return }
            hostSnapshots.removeValue(forKey: peerKey)
            loadedHostKeys = Set(hostSnapshots.keys)
            deniedHostKeys.insert(peerKey)
            let host = hosts.first { $0.peerKey == peerKey }
            publishEcosystem([], peer: peerKey, host: "", lease: ecosystemLease)
            disconnect(manual: false)
            awaitingAccessHost = host?.name
            awaitingAccessPeerKey = host?.peerKey
            if let host { watchForAccess(host) }
            return
        }
        guard accessAllowed == true else {
            staleHostKeys.insert(peerKey)
            return
        }
        deniedHostKeys.remove(peerKey)
        async let loadedFolders = try? Bridge.remoteWorkspaces(peer: peer)
        async let loadedSessions = try? ClientRemote.ptyList(peer: peer.key)
        async let loadedChats = try? ClientRemote.recentChats(peer: peer.key)
        let (newFolders, newSessions, newChats) = await (loadedFolders, loadedSessions, loadedChats)
        guard !Task.isCancelled, !retired, self.ownerScope == ownerScope, ownerScope == WorkSessionContext.shared.scope,
              EcosystemPublisher.lease == ecosystemLease, connectedKey == peerKey,
              chosenPeer == nil || chosenPeer == peerKey, remoteLoadGeneration == loadGeneration else { return }
        guard newFolders != nil else {
            staleHostKeys.insert(peerKey)
            return
        }
        if let newFolders {
            publishEcosystem(newFolders, peer: peerKey, host: hosts.first { $0.peerKey == peerKey }?.name ?? "Computer", lease: ecosystemLease)
            if folders != newFolders { folders = newFolders }
        }
        if let newSessions, sessions != newSessions { sessions = newSessions }
        if let newChats, recentChats != newChats { recentChats = newChats }
        hostSnapshots[peerKey] = HostSnapshot(folders: folders, sessions: sessions, chats: recentChats, loadedAt: .now)
        loadedHostKeys = Set(hostSnapshots.keys)
        staleHostKeys.remove(peerKey)
        deniedHostKeys.remove(peerKey)
        #if os(iOS)
        let overviewPeers = hosts.map(\.peerKey)
        let overviewNames = Dictionary(hosts.map { ($0.peerKey, $0.name) }, uniquingKeysWith: { first, _ in first })
        Task { await LiveWorkController.shared.refreshOverview(peers: overviewPeers, names: overviewNames) }
        #endif
    }

    private func publishEcosystem(_ folders: [WorkspaceFolder], peer: String, host: String, lease: EcosystemPublicationLease?) {
        EcosystemPublisher.publish(projects: folders.filter { $0.exists && !$0.isGeneral }.map {
            EcosystemProject(id: $0.id, name: $0.name, host: $0.machineLabel ?? host)
        }, lease: lease, replacing: .peer(peer))
    }

    enum NotificationTarget {
        case session(PtySessionInfo)
        case chat(peer: String, hostName: String, folder: WorkspaceFolder?, chat: ChatRecentConversation)
    }

    func targetFromNotification(
        _ request: NotificationOpen.Request,
        account: Account?
    ) async -> NotificationTarget? {
        await refresh(account: account)
        for _ in 0..<20 {
            if Task.isCancelled { return nil }
            if isConnecting == nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if Task.isCancelled { return nil }
        let host: ClientHost?
        if let machineID = request.machineID {
            host = hosts.first { $0.machineID == machineID }
        } else {
            host = hosts.first { $0.peerKey == connectedKey } ?? hosts.first
        }
        guard let host, !host.peerKey.isEmpty else { return nil }
        if connectedKey != host.peerKey {
            await connect(host)
        } else {
            await reloadRemote(peerKey: host.peerKey)
        }
        if Task.isCancelled { return nil }
        guard connectedKey == host.peerKey else { return nil }
        if request.kind == .session {
            if let session = Self.pickNotificationSession(from: sessions, named: request.sessionID) {
                return .session(session)
            }
            return nil
        }
        if let sessionID = request.sessionID, !sessionID.isEmpty,
           let named = sessions.first(where: { $0.id == sessionID }) {
            return .session(named)
        }
        guard request.kind == .chat else { return nil }
        guard let chat = Self.pickNotificationChat(from: recentChats, waiting: request.waiting),
              !chat.id.isEmpty
        else {
            return nil
        }
        let folder = folders.first {
            (ClientRemote.rawWorkspaceID(of: $0) ?? $0.id) == chat.workspaceID
        }
        return .chat(peer: host.peerKey, hostName: host.name, folder: folder, chat: chat)
    }

    static func pickNotificationSession(
        from sessions: [PtySessionInfo],
        named sessionID: String? = nil
    ) -> PtySessionInfo? {
        if let sessionID, !sessionID.isEmpty,
           let named = sessions.first(where: { $0.id == sessionID })
        {
            return named
        }
        return sessions
            .filter { $0.alive && !($0.attention?.isEmpty ?? true) }
            .max { ($0.lastActivityAtMs ?? 0) < ($1.lastActivityAtMs ?? 0) }
    }

    static func pickNotificationChat(
        from recents: [ChatRecentConversation],
        waiting: Bool
    ) -> ChatRecentConversation? {
        let ranked = recents.sorted { ($0.lastMessageAtMs ?? 0) > ($1.lastMessageAtMs ?? 0) }
        if waiting {
            return ranked.first(where: { $0.needsAttention }) ?? ranked.first
        }
        return ranked.first { $0.lastMessageAuthor == "agent" } ?? ranked.first
    }
}

#endif
