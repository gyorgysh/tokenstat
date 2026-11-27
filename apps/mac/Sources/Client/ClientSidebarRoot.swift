// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

struct ClientSidebarRoot: View {
    @Binding var showAccount: Bool

    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientTabCustomization.self) private var tabCustomization
    @Environment(PointerKeyboardModel.self) private var input
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let workspaces: ClientWorkspacesModel
    @State private var addingFirstProject = false
    @State private var workspacesLayout = WorkspacesLayout.shared
    @State private var notificationOpen = NotificationOpen.shared
    @State private var detailPath = NavigationPath()
    @Environment(ClientProjectChats.self) private var projectChats
    @State private var pendingClose: (peer: String, info: PtySessionInfo)?
    @State private var sceneWidth: CGFloat = 0
    private var columns: NavigationSplitViewVisibility {
        get { navigation.sidebarVisible ? .all : .detailOnly }
        nonmutating set { navigation.sidebarVisible = newValue != .detailOnly }
    }
    @State private var detailGeneration = 0

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { columns },
            set: { next in
                if navigation.sidebarLayoutActive && sceneWidth >= 600 { columns = next }
            }
        )) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            NavigationStack(path: $detailPath) {
                // The width is *observed*, never used to size anything.
                //
                // This used to be a `GeometryReader` wrapping the content and
                // a `.frame(width:height:)` built from its reading, which made
                // every layout depend on a number that is wrong on the first
                // pass and again on every column resize. Three symptoms came
                // out of that one line: a short screen centred in an oversized
                // box instead of starting at the top, skeletons drawn to a
                // stale width and hanging off the side, and both settling only
                // after enough navigation to force a correct pass.
                //
                // A background reader cannot affect layout, because a
                // background is measured against its parent rather than the
                // other way round. So the content fills the column the
                // ordinary way and the number is only read, for the one
                // decision that needs it: a folder section choosing between a
                // nested split and a stacked screen on the room it has. On an
                // 820 point iPad the sidebar takes 300 of them.
                GeometryReader { geo in
                    detail(width: geo.size.width)
                        .modifier(ClientOwnedPushDestination(tab: navigation.destination))
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .toolbar {
                            if ClientKeyboardPresence.shared.isVisible {
                                ToolbarItem(placement: .topBarTrailing) {
                                    ClientKeyboardDismissButton()
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                ClientWorkSearchButton()
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                ClientConnectionChip()
                            }
                        }
                }
            }
            .onChange(of: detailIdentity) { _, _ in
                detailPath = NavigationPath()
                detailGeneration &+= 1
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                    sceneWidth = width
                    reconcileChatSpace()
                }
            }
        }
        .onChange(of: navigation.currentRoute?.reference?.kind == .conversation || navigation.chatSwitchInProgress, initial: true) { _, _ in
            reconcileChatSpace()
        }
        // `NavigationSplitView` retains its detail controller independently
        // of the `NavigationStack` declared in its closure. Re-keying only
        // that stack can therefore leave an already-presented diff or chat
        // above the newly selected root. Re-key the split subtree instead:
        // shared models live above this view, while every controller the split
        // owns is replaced.
        .id(detailGeneration)
        .environment(workspaces)
        .sheet(isPresented: $addingFirstProject) {
            if let peer = workspaces.connectedKey,
               let host = workspaces.hosts.first(where: { $0.peerKey == peer }) {
                NavigationStack {
                    ClientFolderPicker(peer: peer, hostName: host.name) { _ in
                        addingFirstProject = false
                        Task { await reload() }
                    }
                }
            }
        }
        .clientShortcuts(shortcuts)
        .task {
            await reload()
            await fulfillNotification()
        }
        .task(id: "\(workspaces.connectedKey ?? ""):\(scenePhase == .active)") {
            guard scenePhase == .active, let peer = workspaces.connectedKey else { return }
            while !Task.isCancelled {
                await workspaces.refreshSessions(peer: peer)
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .onChange(of: notificationOpen.request) { _, _ in
            Task { await fulfillNotification() }
        }
        .onChange(of: workspaces.hosts) { _, _ in
            Task { await workspaces.autoConnectLastHost() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            guard let key = workspaces.connectedKey else {
                Task { await workspaces.autoConnectLastHost() }
                return
            }
            guard workspaces.isAutoConnectEnabled(for: key) else { return }
            Task { await workspaces.recoverAfterNetworkChange(account: account.account) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await workspaces.recoverAfterNetworkChange(account: account.account) }
        }
        .confirmationDialog(L10n.text("apple.clientworkspacesview.close_this_session.2b66ce2d"),
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            titleVisibility: .visible) {
                if let target = pendingClose {
                    Button(L10n.text("common.close"), role: .destructive) {
                        pendingClose = nil
                        Task { await workspaces.closeSession(target.info, expectedPeer: target.peer) }
                    }
                }
                Button(L10n.text("apple.clientworkspacesview.keep_it.fdce5da2"), role: .cancel) { pendingClose = nil }
            } message: {
                Text(L10n.text("apple.clientworkspacesview.stops_the_process_on_the_computer.c5651cd1"))
            }
    }

    private func reconcileChatSpace() {
        guard navigation.sidebarLayoutActive else { return }
        if navigation.currentRoute?.reference?.kind != .conversation && !navigation.chatSwitchInProgress {
            if navigation.chatHandoff.pending != nil { return }
            if navigation.sidebarCollapsedForChat, columns == .detailOnly { columns = .all }
            navigation.sidebarCollapsedForChat = false
            navigation.sidebarChatReconciled = false
        } else if !navigation.sidebarChatReconciled, sceneWidth >= 600 {
            navigation.sidebarChatReconciled = true
            if sceneWidth < 900, columns != .detailOnly {
                columns = .detailOnly
                navigation.sidebarCollapsedForChat = true
            }
        }
    }

    private func reload() async {
        await account.load()
        await workspaces.refresh(account: account.account)
        await workspaces.autoConnectLastHost()
    }

    private var rowHeight: CGFloat {
        input.hasPointer ? SidebarMetrics.pointerRow : SidebarMetrics.touchRow
    }

    private func isCurrent(_ tab: ClientTab) -> Bool {
        navigation.destination == tab && navigation.folderID == nil
    }


    private var sidebar: some View {
        list
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AvatarButton(plainBadge: true) { showAccount = true }
                        .padding(.leading, 2)
                }
                .clientAvatarChrome()
                ToolbarItem(placement: .principal) {
                    Wordmark(size: 19, fills: false)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize()
                }
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var list: some View {
        List {
            Section {
                Button {
                    navigation.openNewChat()
                } label: {
                    Label(L10n.text("apple.clientchatview.new_chat.db18382a"), systemImage: "square.and.pencil")
                        .font(Theme.font(15)).frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                ForEach(tabCustomization.visibleTabs.filter { $0 != .team }) { tab in
                    Button {
                        navigation.chooseNavigation()
                        navigation.restoredRoute = nil
                        navigation.destination = tab
                        navigation.folderID = nil
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: tab.symbol)
                                .font(Theme.font(13))
                                .foregroundStyle(isCurrent(tab) ? Theme.accent : Color.secondary)
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 16)
                            Text(tab.label)
                                .font(Theme.font(15, weight: isCurrent(tab) ? .medium : .regular))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .clientSidebarRowSurface(isSelected: isCurrent(tab), height: rowHeight)
                    }
                    .buttonStyle(.plain)
                    .clientSidebarRowChrome()
                }
            }
            ClientServerRows(rowHeight: rowHeight)
            Section {
                if workspaces.hosts.isEmpty {
                    Text(L10n.text("apple.clientsidebarroot.no_computers_yet.31d00b27"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(workspaces.hosts) { host in
                    hostRow(host)
                    if workspaces.loadedHostKeys.contains(host.peerKey), host.online != false {
                        let hostFolders = workspaces.folders(for: host.peerKey)
                        if workspaces.connectedKey == host.peerKey, hostFolders.isEmpty,
                           workspaces.isConnecting == nil, workspaces.errorMessage == nil {
                            FirstProjectPrompt(compact: true) { addingFirstProject = true }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        if workspacesLayout.allTasksVisible {
                            ClientAllTasksLink(peer: host.peerKey, hostName: host.name)
                        }
                        ForEach(hostFolders) { folder in
                            folderRow(folder, peer: host.peerKey)
                            if navigation.sidebarFolderID == folder.id {
                                ForEach(sessions(in: folder, peer: host.peerKey)) { session in
                                    sessionRow(session, in: folder, peer: host.peerKey)
                                }
                                ClientProjectChatRows(peer: host.peerKey, hostName: host.name,
                                    folder: folder, rowHeight: rowHeight,
                                    entry: projectChats.entry(peer: host.peerKey,
                                        workspace: ClientRemote.rawWorkspaceID(of: folder) ?? folder.id),
                                    workspaces: workspaces)
                                    .id(ClientProjectChats.Key(peer: host.peerKey,
                                        workspace: ClientRemote.rawWorkspaceID(of: folder) ?? folder.id))
                            }
                        }
                    }
                }
            } header: {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        machinesHeading
                        machineCount
                    }
                } else {
                    HStack {
                        machinesHeading
                        Spacer()
                        machineCount
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .environment(\.defaultMinListRowHeight, rowHeight)
        .clientCompactSections()
        .refreshable {
            await ClientRefresh.pull("sidebar") { await reload() }
        }
    }

    private var machinesHeading: some View {
        Text(L10n.text("apple.clientsidebarroot.machines.c061da19"))
            .font(ClientType.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var machineCount: some View {
        if !workspaces.hosts.isEmpty {
            Text("\(workspaces.hosts.count)")
                .font(ClientType.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var shortcuts: [ClientShortcut] {
        var commands: [ClientShortcut] = []
        for (index, tab) in tabCustomization.visibleTabs.enumerated() {
            guard let key = "12345".dropFirst(index).first else { continue }
            commands.append(
                ClientShortcut(id: tab.rawValue, title: tab.label, key: KeyEquivalent(key)) {
                    navigation.chooseNavigation()
                    navigation.restoredRoute = nil
                    navigation.destination = tab
                    navigation.folderID = nil
                }
            )
        }
        commands.append(
            ClientShortcut(id: "refresh", title: L10n.text("common.refresh"), key: "r") {
                Task { await reload() }
            }
        )
        commands.append(
            ClientShortcut(id: "sidebar", title: L10n.text("apple.clientsidebarroot.toggle_sidebar.1d4c17db"), key: "\\") {
                columns = columns == .detailOnly ? .all : .detailOnly
            }
        )
        commands.append(
            ClientShortcut(id: "account", title: L10n.text("common.account"), key: ",") {
                showAccount = true
            }
        )
        return commands
    }

    private func hostRow(_ host: ClientHost) -> some View {
        Button {
            navigation.chooseNavigation()
            navigation.restoredRoute = nil
            navigation.folderID = nil
            if workspaces.connectedKey == host.peerKey {
                if let machine = account.account?.machines.first(where: { $0.publicIdentity == host.peerKey }) {
                    navigation.deviceMachineID = machine.id
                    navigation.destination = .machines
                } else {
                    navigation.destination = .workspaces
                }
            } else {
                navigation.deviceMachineID = nil
                navigation.destination = .workspaces
                Task { await workspaces.connect(host) }
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(host.online == true ? Theme.accent : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                Image(systemName: ClientDeviceIcon.symbol(name: host.name, isHost: true))
                    .foregroundStyle(.secondary)
                Text(host.name)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if workspaces.isBusy(with: host.peerKey) {
                    ProgressView().controlSize(.small)
                }
            }
            .clientSidebarRowSurface(isSelected: false, height: rowHeight)
        }
        .buttonStyle(.plain)
        .disabled(host.online == false)
        .clientSidebarRowChrome()
    }

    private func folderRow(_ folder: WorkspaceFolder, peer: String) -> some View {
        Button {
            navigation.open(
                folderID: folder.id,
                section: .sessions
            )
        } label: {
            folderLabel(folder)
                .clientSidebarRowSurface(
                    isSelected: navigation.folderID == folder.id,
                    height: rowHeight
                )
        }
        .buttonStyle(.plain)
        .clientSidebarRowChrome()
        .modifier(ClientProjectRename(peer: peer,
            folder: folder, onChanged: { await reload() }))
    }

    private func folderLabel(_ folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: "folder.fill")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(ClientType.label.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                gitLine(folder)
            }
        }
    }

    @ViewBuilder
    private func gitLine(_ folder: WorkspaceFolder) -> some View {
        let font = ClientType.caption.monospacedDigit()
        if let git = folder.git, git.isRepo {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
                Text(git.branch.map { $0.isEmpty ? "detached" : $0 } ?? L10n.text("apple.clientsidebarroot.detached.88e34e4c"))
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if git.ahead > 0 {
                    Text("⇡\(git.ahead)").font(font).foregroundStyle(Theme.accent)
                }
                if git.behind > 0 {
                    Text("⇣\(git.behind)").font(font).foregroundStyle(Theme.accent)
                }
                if !git.files.isEmpty {
                    if !git.hasLineChanges {
                        Text(git.compactChangeSummary).font(font).foregroundStyle(Theme.accent)
                    } else {
                        Text("+\(git.added)").font(font).foregroundStyle(Theme.diffAdded)
                        if git.removed > 0 {
                            Text("−\(git.removed)").font(font).foregroundStyle(Theme.diffRemoved)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        } else if let subtitle = folder.subtitle {
            Text(subtitle)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func sessionRow(_ session: PtySessionInfo, in folder: WorkspaceFolder, peer: String) -> some View {
        Button {
            workspaces.openSession(session, peer: peer)
        } label: {
            sessionLabel(session, peer: peer, workspaceID: ClientRemote.rawWorkspaceID(of: folder) ?? folder.id)
                .clientSidebarRowSurface(isSelected: false, height: rowHeight)
        }
        .buttonStyle(.plain)
        .clientSidebarRowChrome()
        .modifier(ClientTerminalActions(peer: peer,
            workspaceID: ClientRemote.rawWorkspaceID(of: folder) ?? folder.id, folderName: folder.name,
            info: session, onDuplicate: { copied in workspaces.openSession(copied, peer: peer) },
            onClose: { pendingClose = (peer, session) }))
    }

    private func sessionLabel(_ session: PtySessionInfo, peer: String, workspaceID: String) -> some View {
        Label {
            Text(sessionTitle(session, peer: peer, workspaceID: workspaceID)).lineLimit(1)
        } icon: {
            Image(systemName: session.alive ? "terminal.fill" : "terminal")
                .foregroundStyle(session.alive ? Theme.accent : .secondary)
        }
        .font(ClientType.caption)
        .padding(.leading, Theme.Space.l)
    }

    private func sessionTitle(_ session: PtySessionInfo, peer: String, workspaceID: String) -> String {
        if let name = SidebarTerminalNames.shared.name(peer: peer,
            workspaceID: workspaceID, sessionID: session.id) { return name }
        if let harness = harnessID(forCommand: session.command) { return harnessName(harness) }
        return URL(fileURLWithPath: session.command).lastPathComponent
    }

    private func fulfillNotification() async {
        guard let request = NotificationOpen.shared.request,
              let scope = WorkSessionContext.shared.scope, scope.kind == .account else { return }
        guard let opened = await workspaces.targetFromNotification(request, account: account.account) else {
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
            if NotificationOpen.shared.dropIfStale() { landAfterFailedTap() }
            return
        }
        guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
              NotificationOpen.shared.request == request else { return }
        _ = NotificationOpen.shared.take()
        switch opened {
        case let .session(session):
            workspaces.openSession(session)
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
            if let folder {
                navigation.openChat(folderID: folder.id, chatID: chat.id)
            } else {
                navigation.presentedChat = PresentedChat(
                    scope: scope,
                    peer: peer,
                    workspaceID: chat.workspaceID,
                    folderName: L10n.text("apple.clientsidebarroot.project.98595978"),
                    hostName: hostName,
                    chatID: chat.id
                )
            }
        }
    }

    private func landAfterFailedTap() {
        if navigation.destination != .workspaces {
            navigation.destination = .workspaces
        }
    }

    private func sessions(in folder: WorkspaceFolder, peer: String) -> [PtySessionInfo] {
        let workspace = ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
        return workspaces.sessions(for: peer).filter {
            guard $0.hidden != true else { return false }
            if let id = $0.workspaceID, !id.isEmpty { return id == workspace }
            return $0.cwd == folder.path || $0.cwd.hasPrefix(folder.path + "/")
        }
    }


    private var detailIdentity: String {
        "\(navigation.destination)-\(navigation.folderID ?? "")-\(navigation.projectOpenGeneration)-\(navigation.restoredRouteGeneration)"
    }

    @ViewBuilder
    private func detail(width: CGFloat) -> some View {
        if let route = navigation.restoredRoute {
            ClientRestoredRouteView(route: route)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { navigation.chooseNavigation(); navigation.restoredRoute = nil } label: {
                            ActionIcon.back.label(L10n.text("common.back"))
                        }
                    }
                }
        } else if let id = navigation.folderID,
           navigation.destination == .workspaces,
           let selected = workspaces.folderReference(id: id)
        {
            ClientFolderSplit(peer: selected.peer,
                hostName: workspaces.hosts.first { $0.peerKey == selected.peer }?.name ?? "",
                folder: selected.folder,
                selection: Binding(get: { navigation.section }, set: { navigation.section = $0 }))
        } else {
            switch navigation.destination {
            case .home: ClientHomeView()
            case .insights: ClientInsightsView()
            case .machines: ClientDevicesView()
            case .workspaces: ClientWorkspacesView(model: workspaces, handlesNotifications: false)
            case .team: ClientTeamView()
            case .ssh: ClientSSHTab()
            }
        }
    }
}

enum SidebarMetrics {
    static let macRow: CGFloat = 28
    static let pointerRow: CGFloat = macRow * 1.15
    static let touchRow: CGFloat = 44
}

extension View {
    /// Sections without the standard gap above their heading. iOS 17 and up;
    /// earlier systems keep the roomier list they already had.
    @ViewBuilder
    func clientCompactSections() -> some View {
        if #available(iOS 17, *) {
            listSectionSpacing(.compact)
        } else {
            self
        }
    }

    func clientSidebarRowSurface(isSelected: Bool, height: CGFloat) -> some View {
        padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Theme.rowSelected : Color.clear)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.accent)
                            .frame(width: 3)
                            .padding(.vertical, 3)
                    }
                }
            )
            .contentShape(.rect)
    }

    func clientSidebarRowChrome() -> some View {
        hoverEffect(.highlight)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: Theme.Space.xs,
                bottom: 0,
                trailing: Theme.Space.xs
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#endif
